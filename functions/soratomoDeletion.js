//
// そらもよう Cloud Functions — 「そらとも」の共通の削除 ⭐️
//
// 1人のそらとものデータを、release-gate の要件1・2の規則で冪等に消す（design.md の soratomoDeletion）。
// 呼び手は4つ（本人の退会・アカウントの無い人の後始末・管理・利用停止）で、どれも同じ手順を通る。
//
// - 手順1（このファイルの leaveOrDeleteGroupTx・タスク 3.1）: グループ1つ分の「メンバーを外す・オーナーの引き継ぎ・
//   グループごとの削除」をトランザクションで行う。
// - 手順2〜4（このファイルの deleteUserDataInGroup・タスク 3.2）: 投稿と画像・通知の間引き・所属の写しを消す。
//   時間の予算（締め切り）を、グループの前・投稿300件ごと・画像100件ごとに確かめる。
// - 手順2b（このファイルの removeUserReactionsInGroup・soratomo-reactions 4.2）: 手順2の投稿の後、残るメンバーがいるときだけ、
//   本人がほかのメンバーの投稿に付けたリアクションと、送った印の中の本人を消す。本人あてのリアクションの通知の間引き
//   （reactionNotifyState/{uid}）は手順3で消す。時間の予算は300件ごとに確かめる。抜ける（leaveSoratomoGroup）も
//   手順2の後に照合つきで呼び、間引きは finishLeaveTx で消す（soratomo-reactions 4.3）。
// - 利用者単位（deleteSoratomoUserData・タスク 3.3）: 所属の写しと追加のグループIDの和について手順1〜4を繰り返し、
//   最後に利用者の文書を消す（利用停止のときだけ、停止の日時と所属数0で残す）。利用停止・解除（suspendSoratomoUser・
//   unsuspendSoratomoUser）と、投稿1件の削除（deleteSoratomoSky・開発者の運用手順から使う）もここに置く。
// - 1グループ版の抜ける（leaveSoratomoGroup・leave-group spec）: 同じ手順1の部品（readRemovalPlan・applyRemovalPlan）と
//   手順2〜3の部品を使い、片づけ中の印（soratomoPendingLeaves）と「消す前の照合」を足す。退会の手順は変えない。
// - ログは出さない。件数を返すだけで、ログは呼び手（退会の Callable・定期実行・管理スクリプト）が出す。
// - 手順1を最初に行う理由: メンバーの文書が消えると、ルール（isSoratomoMember）で画像のアップロードが止まり、
//   soratomoStore.createSkyTx のメンバーの確認で投稿の作成も止まる。以後の新しい投稿は増えない。
// - 写しを最後に消す理由: 写し（soratomoUsers/{uid}/groups/{groupId}）は「利用者→グループ」の唯一の経路。
//   手順2〜3の途中で止まっても（失敗・締め切り）、写しが残っていれば、次の呼び出しがそのグループから続ける（要件3.3）。
// - だれを外し、だれをオーナーにし、人数をいくつにするかは soratomoCore.planMembershipRemoval（純関数）が決める。
//   ここはトランザクションで読んで、その計画どおりに書くだけ。
// - テストは soratomoDeletion.test.js（Firestore のエミュレーター・画像は偽のゲートウェイ）。
//
// ⚠️ Firestore のトランザクションは「読みを全部終えてから書く」決まり（soratomoStore.js と同じ）。
// ⚠️ 招待コードには、グループごと消すときだけ触れる。引き継いでもコードは変えない（要件2.7）。
// ⚠️ グループの最新の投稿日時（lastActivityAt）は戻さない（要件2の補足）。
// ⚠️ 通報の記録（soratomoReports・グループの外）には触れない（要件6.11）。
// ⚠️ グループの下を丸ごと消してよいのは、手順1が delete_group（ほかのメンバーの文書が無い）を返したときだけ。
//    手順1が親（グループの文書）を先に消すので、すべての delete_group の経路が「recursiveDelete は親の無い子も消す」
//    ことに依存する（要確認1）。
//

"use strict";

const crypto = require("node:crypto");
const { FieldPath, FieldValue, Timestamp } = require("firebase-admin/firestore");
const core = require("./soratomoCore");

// MARK: - 定数

/** コレクションの名前（soratomoStore.js と同じ）。 */
const GROUPS = "soratomoGroups";
const MEMBERS = "members";
const INVITE_CODES = "soratomoInviteCodes";
const SKIES = "skies";
const NOTIFY_STATE = "notifyState";
const USERS = "soratomoUsers";
const USER_GROUPS = "groups";
/** 抜けるの片づけ中の印（leave-group・文書IDは「uid_グループID」）。書き手は Functions だけ。 */
const PENDING_LEAVES = "soratomoPendingLeaves";
/** リアクションの通知の記録（soratomo-reactions・soratomoStore.js と同じ）。書き手は Functions だけ。 */
const REACTION_NOTIFY_STATE = "reactionNotifyState";
const REACTION_NOTICES = "reactionNotices";

/** 投稿を1回に読んで消す件数。消し終えるたびに締め切りを確かめる（design の「投稿300件ごと」）。 */
const SKY_PAGE_SIZE = 300;
/** 画像をこの件数ずつ区切って消し、区切りごとに締め切りを確かめる（design の「画像100件ごと」）。 */
const IMAGE_CHECK_EVERY = 100;
/** 画像を同時に消す最大の件数（design の「同時に10件まで」）。 */
const IMAGE_DELETE_CONCURRENCY = 10;
/** 手順2bで、本人のリアクションを外す文書を同時に書く最大の件数（soratomo-reactions design の「同時に10件まで」）。 */
const REACTION_UPDATE_CONCURRENCY = 10;
/**
 * 手順2bで、投げずに飛ばす書き込みの失敗のコード（gRPC の NOT_FOUND＝読んだ後に消えた・FAILED_PRECONDITION＝読んだ後に
 * 書き換わった）。エミュレーター（cloud-firestore-emulator v1.20.2・2026-10-19）は、読んだ後に消えた文書への前提条件つきの
 * update も FAILED_PRECONDITION で返した。本番がどちらで返しても飛ばす。
 */
const SKIPPED_WRITE_CODES = Object.freeze([5, 9]);

/**
 * 削除の呼び手（design の DeletionTrigger）。本人の退会・アカウントの無い人の後始末・管理スクリプト・利用停止。
 * 手順は同じで、suspension だけが最後の手順（利用者の文書を残す）を変える。
 */
const TRIGGERS = Object.freeze(["self", "account_deleted", "admin", "suspension"]);

/**
 * 抜けるの呼び手（leave-group design の LeaveOrigin）。本人の Callable（self）と、定期実行の仕事C（sweep）。
 * sweep は手順1でメンバーを外さない（入り直したメンバーを外し直さないため・P3）。
 */
const LEAVE_ORIGINS = Object.freeze(["self", "sweep"]);

// MARK: - 下まわり

/**
 * uid として使えるか（空でない・「/」を含まない・Firebase Auth の上限の128文字以下）。
 * @param {unknown} value
 * @returns {boolean}
 */
function isUid(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 128 && !value.includes("/");
}

/**
 * 削除の依存（db・Storage のゲートウェイ・時計）を確かめて返す。足りなければ TypeError（何も書く前に止める）。
 * @param {unknown} deps
 * @param {{ needsClock: boolean }} options needsClock: 時計（nowMs）を使うか（投稿1件の削除は締め切りを持たない）
 * @returns {{ db: FirebaseFirestore.Firestore,
 *   storage: import("./soratomoStorage").SoratomoStorageGateway, nowMs: () => number }}
 */
function assertDeps(deps, { needsClock }) {
  const { db, storage, nowMs } = deps || {};
  if (!db || typeof db.collection !== "function") throw new TypeError("soratomo: db が無い");
  if (!storage || typeof storage.listFiles !== "function" || typeof storage.deleteFile !== "function") {
    throw new TypeError("soratomo: storage（ゲートウェイ）が無い");
  }
  if (needsClock && typeof nowMs !== "function") throw new TypeError("soratomo: nowMs が関数でない");
  return { db, storage, nowMs };
}

/**
 * 締め切り（ミリ秒の時刻）が有限の数か。
 * @param {unknown} deadlineMs
 */
function assertDeadline(deadlineMs) {
  if (typeof deadlineMs !== "number" || !Number.isFinite(deadlineMs)) throw new TypeError("soratomo: deadlineMs が数値でない");
}

/**
 * Firestore の時刻をミリ秒で読む（Timestamp 以外は null）。
 * @param {unknown} value
 * @returns {number|null}
 */
function millisOf(value) {
  return value && typeof value.toMillis === "function" ? value.toMillis() : null;
}

// MARK: - 手順1: メンバーを外す・オーナーの引き継ぎ・グループごとの削除

/**
 * 手順1の読みの半分（leave-group 要件10.2・design の「共通の削除の部品」）。トランザクションの中で、グループの文書・
 * メンバーの全文書・（グループごと消すときだけ）招待コードの文書を読み、planMembershipRemoval で計画する。
 * 書きの半分（applyRemovalPlan）が要るもの（参照・読んだ文書・計画）を全部返す。
 * - 退会（leaveOrDeleteGroupTx）と抜ける（leave-group の beginLeaveTx）が、同じ読み方と同じ計画を使うために分けた
 * - 招待コードの読みもここで済ませる。書きの半分に読みを残すと「読みを全部終えてから書く」決まりが崩れる
 * @param {FirebaseFirestore.Transaction} tx
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, groupId: string }} params 形は呼び手が確かめておく
 * @returns {Promise<{ groupRef: FirebaseFirestore.DocumentReference, selfRef: FirebaseFirestore.DocumentReference,
 *   groupExisted: boolean, plan: ReturnType<typeof core.planMembershipRemoval>,
 *   codeRef: FirebaseFirestore.DocumentReference|null, codeSnap: FirebaseFirestore.DocumentSnapshot|null }>}
 */
async function readRemovalPlan(tx, db, { uid, groupId }) {
  const groupRef = db.collection(GROUPS).doc(groupId);
  const selfRef = groupRef.collection(MEMBERS).doc(uid);
  const groupSnap = await tx.get(groupRef);
  const membersSnap = await tx.get(groupRef.collection(MEMBERS));
  const members = membersSnap.docs.map((doc) => ({
    uid: doc.id,
    role: doc.get("role"),
    joinedAtMs: millisOf(doc.get("joinedAt")),
  }));
  const plan = core.planMembershipRemoval({
    uid,
    ownerId: groupSnap.exists ? groupSnap.get("ownerId") : null,
    members,
  });

  // 招待コードの文書は、グループごと消すときだけ読む（消すかどうかは書きの半分が「このグループを指しているか」で決める）
  let codeRef = null;
  let codeSnap = null;
  if (groupSnap.exists && plan.kind === "delete_group") {
    const code = groupSnap.get("inviteCode");
    codeRef = isUid(code) ? db.collection(INVITE_CODES).doc(code) : null;
    codeSnap = codeRef ? await tx.get(codeRef) : null;
  }
  return { groupRef, selfRef, groupExisted: groupSnap.exists, plan, codeRef, codeSnap };
}

/**
 * 手順1の書きの半分。readRemovalPlan の計画どおりに書くだけで、tx.get は呼ばない（読みは全部済んでいる）。
 * 分岐と書き込みは、分ける前の leaveOrDeleteGroupTx と同じ（下の leaveOrDeleteGroupTx の説明を参照）。
 * @param {FirebaseFirestore.Transaction} tx
 * @param {Awaited<ReturnType<typeof readRemovalPlan>>} read
 * @param {string} groupId 招待コードが「このグループを指しているか」の確かめに使う
 * @returns {{ kind: "leave"|"delete_group", removed: boolean, ownerTransferred: boolean, groupExisted: boolean }}
 */
function applyRemovalPlan(tx, { groupRef, selfRef, groupExisted, plan, codeRef, codeSnap }, groupId) {
  if (!groupExisted) {
    if (plan.removed) tx.delete(selfRef);
    return { kind: plan.kind, removed: plan.removed, ownerTransferred: false, groupExisted: false };
  }

  if (plan.kind === "delete_group") {
    // 招待コードの文書は、このグループを指しているときだけ消す（他のグループのコードを消さないため・再発行と同じ）
    if (codeSnap && codeSnap.exists && codeSnap.get("groupId") === groupId) tx.delete(codeRef);
    tx.delete(groupRef);
    if (plan.removed) tx.delete(selfRef);
    return { kind: "delete_group", removed: plan.removed, ownerTransferred: false, groupExisted: true };
  }

  // leave
  if (plan.removed) tx.delete(selfRef);
  tx.update(groupRef, { memberCount: plan.memberCount, ownerId: plan.ownerId });
  for (const update of plan.roleUpdates) {
    tx.update(groupRef.collection(MEMBERS).doc(update.uid), { role: update.role });
  }
  return { kind: "leave", removed: plan.removed, ownerTransferred: plan.ownerTransferred, groupExisted: true };
}

/**
 * グループ1つ分の手順1（release-gate 要件2.1・2.2・2.5・2.6・2.7・2.9・2.11・3.4）。
 * グループの文書・メンバーの全文書・（グループごと消すときは）招待コードの文書をトランザクションで読み、
 * planMembershipRemoval の計画どおりに書く。
 * - 残るメンバーがいる（leave）: 自分のメンバーの文書を消し、人数を残りの数で代入し（1減らすのではなく数え直す・2.11）、
 *   オーナーを1人にそろえる（役割が変わる人の分だけ更新）。招待コードは変えない
 * - 残るメンバーがいない（delete_group）: 招待コード（このグループを指しているときだけ）・グループの文書・
 *   自分のメンバーの文書を一緒に消す。同時の参加は、コードかグループの文書が無いので not_found になる。
 *   子（投稿・通知の間引き）と画像は手順2が消す
 * - すでにメンバーでない再実行でも、人数とオーナーを整えるだけで同じ結果になる（removed: false・3.4）
 * - グループの文書が無い（壊れた状態か、グループごとの削除の途中で止まった後）: オーナーも招待コードもわからないので、
 *   自分のメンバーの文書だけを消し、ほかには書かない（groupExisted: false）。子を消すかは手順2が kind で決める
 *   （delete_group＝ほかのメンバーがいないときだけ、子を消してよい）
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, groupId: string }} params
 * @returns {Promise<{ kind: "leave"|"delete_group", removed: boolean, ownerTransferred: boolean, groupExisted: boolean }>}
 *   removed はこの実行で自分のメンバーの文書を消したか。ownerTransferred はオーナーを別の人に替えたか
 */
async function leaveOrDeleteGroupTx(db, { uid, groupId }) {
  if (!isUid(uid)) throw new TypeError("soratomo: uid が文書IDとして使えない");
  if (!core.isAutoId(groupId)) throw new TypeError("soratomo: groupId が自動IDの形でない");

  // 読みの半分と書きの半分を、1つのトランザクションで続けて呼ぶ（戻り値と書き込みは分ける前と同じ）
  return db.runTransaction(async (tx) => {
    const read = await readRemovalPlan(tx, db, { uid, groupId });
    return applyRemovalPlan(tx, read, groupId);
  });
}

// MARK: - 手順2: 投稿と画像

/**
 * クエリに当たる投稿を、SKY_PAGE_SIZE 件ずつ読んで消す。1ページ消すたびに締め切りを確かめる。
 * - 読むのは文書の参照だけ（select() で項目を読まない）
 * - 1ページは WriteBatch で消す（300件は1回の上限500件に収まり、失敗はページごと投げる）
 * - 消した文書はクエリに再び当たらないので、カーソルは要らない
 * - beforeDelete（省略できる・leave-group の照合）: 1ページを読んだ後、消す前に呼ぶ。偽なら消さずに stopped: true で返す。
 *   「読む→照合→消す」の順なので、照合が通れば、消すのは照合より前に読んだものだけ。省略したとき（退会・利用停止・
 *   後始末）は、分ける前と同じく確かめずに消す
 * @param {FirebaseFirestore.Firestore} db
 * @param {FirebaseFirestore.Query} query 消す投稿のクエリ（退会者の投稿か、グループの全投稿）
 * @param {() => boolean} pastDeadline
 * @param {(() => Promise<boolean>)|undefined} [beforeDelete]
 * @returns {Promise<{ done: boolean, deleted: number, stopped?: true }>}
 */
async function deleteSkiesByQuery(db, query, pastDeadline, beforeDelete) {
  let deleted = 0;
  for (;;) {
    const snap = await query.select().limit(SKY_PAGE_SIZE).get();
    if (snap.empty) return { done: true, deleted };
    if (beforeDelete && !(await beforeDelete())) return { done: true, deleted, stopped: true };
    const batch = db.batch();
    for (const doc of snap.docs) batch.delete(doc.ref);
    await batch.commit();
    deleted += snap.size;
    if (pastDeadline()) return { done: false, deleted };
  }
}

/**
 * 区切った画像を、同時に IMAGE_DELETE_CONCURRENCY 件まで消す。"deleted" だけを数える（404＝"absent" は数えない・3.3）。
 * 失敗が出ても、走っている削除を全部待ってから最初の失敗を投げる（返った後に裏で削除が続かないように）。
 * @param {import("./soratomoStorage").SoratomoStorageGateway} storage
 * @param {string[]} paths
 * @returns {Promise<number>} 消した数
 */
async function deleteImageChunk(storage, paths) {
  let next = 0;
  let deleted = 0;
  const worker = async () => {
    while (next < paths.length) {
      const path = paths[next];
      next += 1;
      if ((await storage.deleteFile(path)) === "deleted") deleted += 1;
    }
  };
  const workers = Array.from({ length: Math.min(IMAGE_DELETE_CONCURRENCY, paths.length) }, worker);
  const failed = (await Promise.allSettled(workers)).find((r) => r.status === "rejected");
  if (failed) throw failed.reason;
  return deleted;
}

/**
 * 接頭辞の下の画像を一覧し、IMAGE_CHECK_EVERY 件ずつ区切って消す。区切りごとに締め切りを確かめる。
 * 投稿の文書の無い取り残しの画像も、接頭辞で拾うので一緒に消える（要件1.3）。
 * - beforeDelete（省略できる・leave-group の照合）: 区切り（100件と、最後の端数）を一覧した後、消す前に呼ぶ。偽なら
 *   その区切りを消さずに stopped: true で返す。省略したとき（退会・利用停止・後始末・投稿1件）は、分ける前と同じ
 * @param {import("./soratomoStorage").SoratomoStorageGateway} storage
 * @param {string} prefix 末尾が "/" の接頭辞（soratomo/{groupId}/{uid}/ か soratomo/{groupId}/）
 * @param {() => boolean} pastDeadline
 * @param {(() => Promise<boolean>)|undefined} [beforeDelete]
 * @returns {Promise<{ done: boolean, deleted: number, stopped?: true }>}
 */
async function deleteImagesByPrefix(storage, prefix, pastDeadline, beforeDelete) {
  let deleted = 0;
  let chunk = [];
  for await (const path of storage.listFiles(prefix)) {
    chunk.push(path);
    if (chunk.length < IMAGE_CHECK_EVERY) continue;
    // 途中で返すと for await が一覧（ジェネレーター）を閉じる
    if (beforeDelete && !(await beforeDelete())) return { done: true, deleted, stopped: true };
    deleted += await deleteImageChunk(storage, chunk);
    chunk = [];
    if (pastDeadline()) return { done: false, deleted };
  }
  if (chunk.length > 0) {
    if (beforeDelete && !(await beforeDelete())) return { done: true, deleted, stopped: true };
    deleted += await deleteImageChunk(storage, chunk);
  }
  return { done: true, deleted };
}

// MARK: - 手順2b: 本人が付けたリアクション（soratomo-reactions）

/**
 * 1区切りの文書を、同時に REACTION_UPDATE_CONCURRENCY 件まで write で書く。書けた数を返す。
 * - write には前提条件 { lastUpdateTime: 読んだ文書の updateTime } を渡す（読んだ後に書き換わった文書には書かない）
 * - SKIPPED_WRITE_CODES（読んだ後に消えた・書き換わった）は投げずに飛ばし、数えない
 * - ほかの失敗が出ても、走っている書き込みを全部待ってから最初の失敗を投げる（deleteImageChunk と同じ）
 * @param {FirebaseFirestore.QueryDocumentSnapshot[]} docs
 * @param {(ref: FirebaseFirestore.DocumentReference, precondition: FirebaseFirestore.Precondition) => Promise<unknown>} write
 * @returns {Promise<number>}
 */
async function updateDocChunk(docs, write) {
  let next = 0;
  let written = 0;
  const worker = async () => {
    while (next < docs.length) {
      const doc = docs[next];
      next += 1;
      try {
        await write(doc.ref, { lastUpdateTime: doc.updateTime });
        written += 1;
      } catch (err) {
        if (!(err && SKIPPED_WRITE_CODES.includes(err.code))) throw err;
      }
    }
  };
  const workers = Array.from({ length: Math.min(REACTION_UPDATE_CONCURRENCY, docs.length) }, worker);
  const failed = (await Promise.allSettled(workers)).find((r) => r.status === "rejected");
  if (failed) throw failed.reason;
  return written;
}

/**
 * クエリに当たる文書を SKY_PAGE_SIZE 件ずつ読み、updateDocChunk で書く。1区切り書くたびに締め切りを確かめる。
 * - 読むのは文書の参照と updateTime だけ（select() で項目を読まない）
 * - クエリは毎回先頭から読む。書けた文書は本人を含まなくなり、消えた文書も当たらないので、カーソルは要らない。
 *   書き換わって飛ばした文書は、まだ本人を含んでいれば次の区切りで読み直し、照合を通ってから書く
 * - beforeDelete（省略できる・leave-group の照合）: 1区切りを読んだ後、書く前に呼ぶ。偽なら書かずに stopped: true
 *   （deleteSkiesByQuery と同じ「読む→照合→書く」の順）
 * @param {FirebaseFirestore.Query} query
 * @param {(ref: FirebaseFirestore.DocumentReference, precondition: FirebaseFirestore.Precondition) => Promise<unknown>} write
 * @param {() => boolean} pastDeadline
 * @param {(() => Promise<boolean>)|undefined} [beforeDelete]
 * @returns {Promise<{ done: boolean, written: number, stopped?: true }>}
 */
async function updateEachByQuery(query, write, pastDeadline, beforeDelete) {
  let written = 0;
  for (;;) {
    const snap = await query.select().limit(SKY_PAGE_SIZE).get();
    if (snap.empty) return { done: true, written };
    if (beforeDelete && !(await beforeDelete())) return { done: true, written, stopped: true };
    written += await updateDocChunk(snap.docs, write);
    if (pastDeadline()) return { done: false, written };
  }
}

/**
 * 手順2b（soratomo-reactions design の removeUserReactionsInGroup・要件9.1〜9.3・9.5〜9.11）。そのグループで本人が
 * ほかのメンバーの投稿に付けたリアクションと、送った印の中の本人を消す。
 * 1. 投稿を reactorIds に本人を含むもので読み、各投稿の reactions.{uid}（FieldPath で本人のキーだけを指す）を消し、
 *    reactorIds から本人を外す。同じ update で書くので、reactions のキーと reactorIds がそろったまま（I1）
 * 2. 送った印（reactionNotices）を notifiedReactorIds に本人を含むもので読み、本人を外す。印の文書は消さない
 *    （空の配列で残っても、投稿の削除のトリガーかグループごとの削除が消す）
 * - 書き方・飛ばし方・照合・締め切りは updateEachByQuery のとおり。update だけで書き、set(merge) は使わない
 *   （読んだ後に消えた投稿を作り直さないため）
 * - 手順1の後なので、本人のメンバーの文書は無い。setReactionTx はメンバーの文書を読むので、本人の新しいリアクションは
 *   増えない（入り直した場合は、抜けるの照合と前提条件で止める・design の Implementation Notes）
 * - 本人の投稿は手順2で消えている（そのリアクションと印は、投稿と削除のトリガーが消す）。数えるのは、ほかのメンバーの
 *   投稿から外した本人のリアクションの数だけ
 * - 冪等: 外した分はクエリに再び当たらないので、何度呼んでも1回で成功した場合と同じ（9.10）
 * - 呼び手は残るメンバーがいる（leave）ときだけ呼ぶ。delete_group は全投稿の削除と recursiveDelete で消える
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, groupId: string }} params 形は呼び手が確かめておく
 * @param {() => boolean} pastDeadline
 * @param {(() => Promise<boolean>)|undefined} [beforeDelete]
 * @returns {Promise<{ done: boolean, deleted: number, stopped?: true }>} deleted は外したリアクションの数
 */
async function removeUserReactionsInGroup(db, { uid, groupId }, pastDeadline, beforeDelete) {
  const groupRef = db.collection(GROUPS).doc(groupId);
  const ownPath = new FieldPath("reactions", uid);
  const skies = await updateEachByQuery(
    groupRef.collection(SKIES).where("reactorIds", "array-contains", uid),
    (ref, precondition) => ref.update(ownPath, FieldValue.delete(), "reactorIds", FieldValue.arrayRemove(uid), precondition),
    pastDeadline,
    beforeDelete
  );
  if (skies.stopped) return { done: true, deleted: skies.written, stopped: true };
  if (!skies.done) return { done: false, deleted: skies.written };

  const notices = await updateEachByQuery(
    groupRef.collection(REACTION_NOTICES).where("notifiedReactorIds", "array-contains", uid),
    (ref, precondition) => ref.update("notifiedReactorIds", FieldValue.arrayRemove(uid), precondition),
    pastDeadline,
    beforeDelete
  );
  if (notices.stopped) return { done: true, deleted: skies.written, stopped: true };
  return { done: notices.done, deleted: skies.written };
}

// MARK: - 手順4: 所属の写し

/**
 * 写しを消し、所属数を残りの写しの件数で数え直して代入する（トランザクション・要件2.11・3.4）。
 * - 利用者の文書を必ず読む。参加と作成も同じ文書を読んで書くので、所属数の書き込みが直列になる
 *   （クエリの範囲のロックには頼らない・design の「人数の正しさ」）
 * - 写しが無くても（管理スクリプトが足したグループ・再実行）失敗しない。所属数は読めた件数で代入する
 * - 利用者の文書が無ければ作らない（写しだけを消す）。利用者の文書の扱いは 3.3 の最後の手順が決める
 * - このグループに自分のメンバーの文書があれば、写しを消さずに何もしない（レビュー #16）。手順1の後に同じグループへ
 *   入り直していた（並行した別の削除が先に終わり、本人が同意し直して参加した等）ということで、ここで写しを消すと、
 *   メンバーの文書と投稿が「利用者→グループ」の唯一の経路を失って残り続ける（所属数とメンバー数が食い違い、定期実行も拾えない）。
 *   写しが残るので、呼び手（deleteSoratomoUserData）の最後の確認が見つけて、このグループをもう一度処理する
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, groupId: string }} params
 * @returns {Promise<void>}
 */
async function removeMembershipCopyTx(db, { uid, groupId }) {
  const userRef = db.collection(USERS).doc(uid);
  const copyRef = userRef.collection(USER_GROUPS).doc(groupId);
  const memberRef = db.collection(GROUPS).doc(groupId).collection(MEMBERS).doc(uid);
  await db.runTransaction(async (tx) => {
    const userSnap = await tx.get(userRef);
    const copiesSnap = await tx.get(userRef.collection(USER_GROUPS));
    const memberSnap = await tx.get(memberRef);
    if (memberSnap.exists) return;
    const remaining = copiesSnap.docs.filter((doc) => doc.id !== groupId).length;

    // ここから書き込み
    tx.delete(copyRef);
    if (userSnap.exists) {
      tx.update(userRef, { groupCount: remaining, updatedAt: FieldValue.serverTimestamp() });
    }
  });
}

// MARK: - グループ1つ分の手順1〜4

/**
 * 1人の利用者の、グループ1つ分のデータを消す（release-gate 要件1.1〜1.3・1.5・2.4・2.9・3.3・6.11）。
 * 手順はグループの前の締め切りの確認 → 手順1（leaveOrDeleteGroupTx）→ 手順2 → 手順2b（leave のときだけ）→ 手順3 →
 * 手順4（写しは最後）。
 * - leave（ほかのメンバーが残る）: 退会者の投稿（authorId の一致）を消した後、退会者がほかのメンバーの投稿に付けた
 *   リアクションと、送った印の中の退会者を外し（手順2b・removeUserReactionsInGroup・soratomo-reactions 要件9.5〜9.8）、
 *   soratomo/{groupId}/{uid}/ の画像を消し、退会者あての通知の間引きの状態（notifyState/{uid}）とリアクションの通知の
 *   間引き（reactionNotifyState/{uid}）を消す。ほかのメンバーの投稿と画像には触れない（1.5。リアクションは退会者の
 *   キーだけを外す）
 * - delete_group（ほかのメンバーの文書が無い）: グループの全投稿と soratomo/{groupId}/ の画像を消し、
 *   残り（メンバー・通知の間引き）を recursiveDelete で消す。グループの文書が無い再実行でも、手順1がほかのメンバーの
 *   文書の無いことを確かめて delete_group を返したときだけ、ここへ来る。グループの文書と招待コードが無いので、
 *   この後に参加や投稿で子が増えることはない
 * - 締め切りを過ぎたら done: false で返す。写しは残っているので、次の呼び出しがこのグループから続ける
 * - 途中の失敗（Firestore・Storage）は投げる。写しは残る
 * @param {{ db: FirebaseFirestore.Firestore,
 *   storage: import("./soratomoStorage").SoratomoStorageGateway, nowMs: () => number }} deps
 * @param {{ uid: string, groupId: string, deadlineMs: number }} request
 * @returns {Promise<{ done: boolean, kind: "leave"|"delete_group"|null, removed: boolean, ownerTransferred: boolean,
 *   groupDeleted: boolean, skiesDeleted: number, imagesDeleted: number, reactionsDeleted: number }>}
 *   kind はグループの前に締め切りを過ぎたときだけ null。groupDeleted はこの実行でグループの文書を消したか
 *   （再実行で二重に数えない）。reactionsDeleted は手順2bで外したリアクションの数（delete_group では0）
 */
async function deleteUserDataInGroup(deps, { uid, groupId, deadlineMs }) {
  const { db, storage, nowMs } = assertDeps(deps, { needsClock: true });
  if (!isUid(uid)) throw new TypeError("soratomo: uid が文書IDとして使えない");
  if (!core.isAutoId(groupId)) throw new TypeError("soratomo: groupId が自動IDの形でない");
  assertDeadline(deadlineMs);

  const pastDeadline = () => nowMs() >= deadlineMs;
  const result = {
    done: false,
    kind: null,
    removed: false,
    ownerTransferred: false,
    groupDeleted: false,
    skiesDeleted: 0,
    imagesDeleted: 0,
    reactionsDeleted: 0,
  };
  if (pastDeadline()) return result;

  // 手順1
  const step1 = await leaveOrDeleteGroupTx(db, { uid, groupId });
  result.kind = step1.kind;
  result.removed = step1.removed;
  result.ownerTransferred = step1.ownerTransferred;
  result.groupDeleted = step1.kind === "delete_group" && step1.groupExisted;

  // 手順2（と、グループごとのときは手順3もここで済む）
  const groupRef = db.collection(GROUPS).doc(groupId);
  const wholeGroup = step1.kind === "delete_group";
  const skies = await deleteSkiesByQuery(
    db,
    wholeGroup ? groupRef.collection(SKIES) : groupRef.collection(SKIES).where("authorId", "==", uid),
    pastDeadline
  );
  result.skiesDeleted = skies.deleted;
  if (!skies.done) return result;

  // 手順2b（残るメンバーがいるときだけ。グループごとのときは、全投稿と recursiveDelete でリアクションと印も消える）
  if (!wholeGroup) {
    const reactions = await removeUserReactionsInGroup(db, { uid, groupId }, pastDeadline);
    result.reactionsDeleted = reactions.deleted;
    if (!reactions.done) return result;
  }

  const prefix = wholeGroup ? `soratomo/${groupId}/` : `soratomo/${groupId}/${uid}/`;
  const images = await deleteImagesByPrefix(storage, prefix, pastDeadline);
  result.imagesDeleted = images.deleted;
  if (!images.done) return result;

  if (wholeGroup) {
    // 残りの子（メンバー・通知の間引き・リアクションの通知の記録）を消す。親の文書は手順1で消えている（要確認1）
    await db.recursiveDelete(groupRef);
  } else {
    // 手順3: 退会者あての通知の間引きの状態と、リアクションの通知の間引き（どちらも無くても失敗しない）
    await groupRef.collection(NOTIFY_STATE).doc(uid).delete();
    await groupRef.collection(REACTION_NOTIFY_STATE).doc(uid).delete();
  }

  // 手順4（最後）
  await removeMembershipCopyTx(db, { uid, groupId });
  result.done = true;
  return result;
}

// MARK: - 1グループ版の抜ける（leave-group）

/** 片づけ中の印の参照（文書IDは「uid_グループID」。groupId は英数字の自動IDなので「_」と混ざらない）。 */
function pendingLeaveRef(db, uid, groupId) {
  return db.collection(PENDING_LEAVES).doc(`${uid}_${groupId}`);
}

/**
 * 抜けるの手順1（leave-group design の beginLeaveTx・要件3.1・3.2・3.6〜3.8・3.10・3.14）。
 * 1つのトランザクションで、本人のメンバーの文書・所属の写し・印を先に読み、design の「手順1の判定」の表どおりに動く。
 * | メンバー | 印   | 写し | origin | 動き                                                  | state        |
 * | 無い     | 無い | 無い | どちら | 何も書かない（人数とオーナーも書き直さない・P1）      | nothing      |
 * | ある     | —    | —    | self   | メンバーから外し、人数とオーナーを整え、新しい印を書く | started      |
 * | ある     | ある | —    | sweep  | 印だけを消す（入り直した後の古い印）                  | stale_marker |
 * | 無い     | ある | —    | どちら | 人数とオーナーを整える。印はそのまま                  | continued    |
 * | 無い     | 無い | ある | self   | 同上。印を新しく書く（写しだけが残った状態を引き取る） | continued    |
 * | ある     | 無い | —    | sweep  | 起きない（定期実行は印から来る）。何も書かない        | nothing      |
 * - sweep で印も写しも無い（終わった後の再実行）も、写しだけがある（印が先に消えた）も、何も書かずに nothing
 * - 外し方（人数は残りの数で代入・オーナーは参加の古い順で1人・招待コードは変えない・最後の1人ならグループと招待コードを
 *   消す）は、退会と同じ readRemovalPlan と applyRemovalPlan を使う
 * - 通報の記録・利用者の文書・ほかのグループの写し・users/{uid} には触れない
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, groupId: string, origin: "self"|"sweep", nowMs: () => number, newEpisodeId: () => string }} params
 * @returns {Promise<{ state: "nothing"|"started"|"continued"|"stale_marker", kind: "leave"|"delete_group"|null,
 *   removed: boolean, ownerTransferred: boolean, groupExisted: boolean, episodeId: string|null, leftAtMs: number|null }>}
 *   episodeId・leftAtMs はコミットした印の値（nothing と stale_marker では null）
 */
async function beginLeaveTx(db, { uid, groupId, origin, nowMs, newEpisodeId }) {
  const memberRef = db.collection(GROUPS).doc(groupId).collection(MEMBERS).doc(uid);
  const copyRef = db.collection(USERS).doc(uid).collection(USER_GROUPS).doc(groupId);
  const markerRef = pendingLeaveRef(db, uid, groupId);
  const untouched = { kind: null, removed: false, ownerTransferred: false, groupExisted: false, episodeId: null, leftAtMs: null };

  return db.runTransaction(async (tx) => {
    const [memberSnap, copySnap, markerSnap] = await tx.getAll(memberRef, copyRef, markerRef);

    if (memberSnap.exists && origin === "sweep") {
      // 入り直した後に残った古い印。メンバーは外さない（遅れた片づけが入り直した人を外し直さないため・8.6）
      if (!markerSnap.exists) return { state: "nothing", ...untouched };
      tx.delete(markerRef);
      return { state: "stale_marker", ...untouched };
    }

    // ここに来るのは「self でメンバー」か「メンバーでない」だけ
    const continuing = !memberSnap.exists;
    if (continuing && !markerSnap.exists && !(copySnap.exists && origin === "self")) {
      // メンバーでなく、片づけ中の印も（self の）写しも無い。グループの人数とオーナーを書き直さない（P1・3.14）
      return { state: "nothing", ...untouched };
    }

    // 読みの半分（書きより前に済ませる）
    const read = await readRemovalPlan(tx, db, { uid, groupId });

    // ここから書き込み
    const step1 = applyRemovalPlan(tx, read, groupId);
    let episodeId;
    let leftAtMs;
    if (continuing && markerSnap.exists) {
      // 続き: 印はそのまま（同じ回のまま照合する）
      episodeId = markerSnap.get("episodeId");
      leftAtMs = millisOf(markerSnap.get("leftAt"));
    } else {
      // 新しい回（古い印があれば上書きする）
      episodeId = newEpisodeId();
      leftAtMs = nowMs();
      tx.set(markerRef, { uid, groupId, episodeId, leftAt: Timestamp.fromMillis(leftAtMs) });
    }
    return { state: continuing ? "continued" : "started", ...step1, episodeId, leftAtMs };
  });
}

/**
 * 照合の規則（leave-group design の isLeaveEpisodeCurrent）: 印があり、episodeId が同じ回で、メンバーの文書が無いか。
 * 手順2〜3の「消す前」（isLeaveEpisodeCurrent）と、手順4のトランザクション（finishLeaveTx）が、同じこの規則を使う。
 * - 印が無い: 別の実行が手順4まで終えた（その後に入り直したかもしれない）
 * - episodeId が違う: 抜けて、入り直して、また抜けた（新しい回の片づけは、その回の実行が進める）
 * - メンバーの文書がある: 入り直した後（このときの投稿と画像は、入り直した後のものかもしれない）
 * @param {FirebaseFirestore.DocumentSnapshot} markerSnap
 * @param {FirebaseFirestore.DocumentSnapshot} memberSnap
 * @param {string} episodeId この実行の回の札（beginLeaveTx がコミットした値）
 * @returns {boolean}
 */
function episodeMatches(markerSnap, memberSnap, episodeId) {
  return markerSnap.exists && markerSnap.get("episodeId") === episodeId && !memberSnap.exists;
}

/**
 * 消す前の照合（leave-group design の isLeaveEpisodeCurrent・要件8.6）。印とメンバーの文書を getAll で2件読む。
 * 「読む（クエリか一覧）→照合→消す」の順で呼ぶ。照合が通った時点で入り直しが起きていなければ、それより前に読んだ
 * 投稿と画像は、すべて入り直す前のもの（メンバーの文書が無い間は、新しい投稿も画像も作れない・P4）。
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, groupId: string, episodeId: string }} params
 * @returns {Promise<boolean>}
 */
async function isLeaveEpisodeCurrent(db, { uid, groupId, episodeId }) {
  const memberRef = db.collection(GROUPS).doc(groupId).collection(MEMBERS).doc(uid);
  const [markerSnap, memberSnap] = await db.getAll(pendingLeaveRef(db, uid, groupId), memberRef);
  return episodeMatches(markerSnap, memberSnap, episodeId);
}

/**
 * 抜けるの手順4（leave-group design の finishLeaveTx・要件3.3・3.4・3.5・3.12）。removeMembershipCopyTx を型にした
 * トランザクションで、利用者の文書・写しの全件・メンバーの文書・印を読む。
 * - 照合（episodeMatches）が通ったときだけ、写し・印・（残るメンバーがいれば）通知の間引き notifyState/{uid} と
 *   リアクションの通知の間引き reactionNotifyState/{uid}（soratomo-reactions 4.3）を消し、所属数を残りの写しの数で代入する
 *   （1減らすのではなく数え直す）。delete_group の通知の間引きとリアクションの通知の記録は recursiveDelete が消した
 * - 照合が通らなければ、何も書かずに false（別の実行が終えた・入り直した。呼び手は superseded にする）
 * - 写しが既に無くても（退会の手順4が先に消した）失敗しない。利用者の文書が無ければ作らない
 * - finishUserTx は呼ばない（抜けるは利用者の文書を消さない・同意と停止の項目を残す）
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, groupId: string, episodeId: string, kind: "leave"|"delete_group" }} params
 * @returns {Promise<boolean>} 片づけを終えたら true
 */
async function finishLeaveTx(db, { uid, groupId, episodeId, kind }) {
  const userRef = db.collection(USERS).doc(uid);
  const copyRef = userRef.collection(USER_GROUPS).doc(groupId);
  const groupRef = db.collection(GROUPS).doc(groupId);
  const memberRef = groupRef.collection(MEMBERS).doc(uid);
  const markerRef = pendingLeaveRef(db, uid, groupId);
  return db.runTransaction(async (tx) => {
    const [userSnap, memberSnap, markerSnap] = await tx.getAll(userRef, memberRef, markerRef);
    const copiesSnap = await tx.get(userRef.collection(USER_GROUPS));
    if (!episodeMatches(markerSnap, memberSnap, episodeId)) return false;
    const remaining = copiesSnap.docs.filter((doc) => doc.id !== groupId).length;

    // ここから書き込み
    tx.delete(copyRef);
    tx.delete(markerRef);
    if (kind === "leave") {
      tx.delete(groupRef.collection(NOTIFY_STATE).doc(uid));
      tx.delete(groupRef.collection(REACTION_NOTIFY_STATE).doc(uid));
    }
    if (userSnap.exists) {
      tx.update(userRef, { groupCount: remaining, updatedAt: FieldValue.serverTimestamp() });
    }
    return true;
  });
}

/**
 * 1人の1グループ分の抜けるを、印つきで冪等に進める（leave-group design の leaveSoratomoGroup）。
 * 退会の deleteUserDataInGroup を直接は呼ばない（メンバーでない人の要求で人数とオーナーを書き直す P1・
 * 入り直しを見ない P3 のため）。同じ部品を使い、印と照合を足す。
 * - 手順0: 締め切りを過ぎていれば、何もせずに done: false
 * - 手順1: beginLeaveTx（nothing・stale_marker なら done: true で終える）
 * - 手順2: 残るメンバーがいれば本人の投稿（authorId の一致）を、最後の1人ならグループの全投稿を、300件ずつ読み、照合し、消す
 * - 手順2b: 残るメンバーがいれば、本人がほかのメンバーの投稿に付けたリアクションと印の中の本人を、removeUserReactionsInGroup
 *   で300件ずつ読み、照合し、外す（soratomo-reactions 4.3）。照合の後・書く前に入り直して付け直したリアクションは、書き込みの
 *   前提条件（読んだ文書の updateTime）で消さず、次の区切りの照合で止まる。最後の1人なら行わない
 * - 手順3: 残るメンバーがいれば soratomo/{groupId}/{uid}/ の下（取り残しの画像を含む）を、最後の1人なら
 *   soratomo/{groupId}/ の下を、100件ずつ一覧し、照合し、消す。最後の1人なら、照合の後に残りの記録を recursiveDelete で消す
 * - 手順4: finishLeaveTx（写し・印・通知の間引き・リアクションの通知の間引き・所属数）
 * - 照合（isLeaveEpisodeCurrent）が外れたら、その区切りを消さずに state: "superseded"・done: true で止める（8.6）。
 *   それまでに消した件数は結果に残す
 * - 締め切りは、手順0・投稿300件ごと・画像100件ごとに確かめる（deleteUserDataInGroup と同じ位置）。過ぎたら done: false で
 *   返し、印と写しが残る。次の呼び出し（アプリの繰り返しか定期実行）が、印の回のまま続きから進める
 * - 途中の失敗（Firestore・Storage）は投げる。印と写しは残る
 * - 引数の誤りは TypeError で、何も書かない。ログは出さない（呼び手が出す）
 * @param {{ db: FirebaseFirestore.Firestore, storage: import("./soratomoStorage").SoratomoStorageGateway,
 *   nowMs: () => number, newEpisodeId?: () => string,
 *   wrapReactionCheck?: (check: () => Promise<boolean>) => () => Promise<boolean> }} deps
 *   newEpisodeId は省略したら crypto.randomUUID。wrapReactionCheck はテスト用の口（soratomo-reactions 4.3）で、手順2bに渡す
 *   照合を包む（照合の前後で別の実行や入り直しを走らせるため）。省略したら何もしない形（照合をそのまま渡す）
 * @param {{ uid: string, groupId: string, deadlineMs: number, origin: "self"|"sweep" }} request
 * @returns {Promise<{ done: boolean, state: "nothing"|"started"|"continued"|"stale_marker"|"superseded",
 *   kind: "leave"|"delete_group"|null, removed: boolean, ownerTransferred: boolean, groupDeleted: boolean,
 *   skiesDeleted: number, imagesDeleted: number, reactionsDeleted: number }>}
 *   state は手順0で止まったときだけ null。started・continued は、締め切りで止まれば done: false、終えれば done: true。
 *   removed・ownerTransferred・groupDeleted は手順1の値（この実行でメンバーの文書・グループの文書を消したか）。
 *   reactionsDeleted はこの実行の手順2bで外したリアクションの数（delete_group では0）
 */
async function leaveSoratomoGroup(deps, { uid, groupId, deadlineMs, origin }) {
  const { db, storage, nowMs } = assertDeps(deps, { needsClock: true });
  const newEpisodeId = deps.newEpisodeId === undefined ? () => crypto.randomUUID() : deps.newEpisodeId;
  if (typeof newEpisodeId !== "function") throw new TypeError("soratomo: newEpisodeId が関数でない");
  const wrapReactionCheck = deps.wrapReactionCheck === undefined ? (check) => check : deps.wrapReactionCheck;
  if (typeof wrapReactionCheck !== "function") throw new TypeError("soratomo: wrapReactionCheck が関数でない");
  if (!isUid(uid)) throw new TypeError("soratomo: uid が文書IDとして使えない");
  if (!core.isAutoId(groupId)) throw new TypeError("soratomo: groupId が自動IDの形でない");
  assertDeadline(deadlineMs);
  if (!LEAVE_ORIGINS.includes(origin)) throw new TypeError("soratomo: origin が self と sweep のどちらでもない");

  const pastDeadline = () => nowMs() >= deadlineMs;
  const result = {
    done: false,
    state: null,
    kind: null,
    removed: false,
    ownerTransferred: false,
    groupDeleted: false,
    skiesDeleted: 0,
    imagesDeleted: 0,
    reactionsDeleted: 0,
  };
  // 手順0
  if (pastDeadline()) return result;

  // 手順1
  const step1 = await beginLeaveTx(db, { uid, groupId, origin, nowMs, newEpisodeId });
  result.state = step1.state;
  if (step1.state === "nothing" || step1.state === "stale_marker") {
    result.done = true;
    return result;
  }
  result.kind = step1.kind;
  result.removed = step1.removed;
  result.ownerTransferred = step1.ownerTransferred;
  result.groupDeleted = step1.kind === "delete_group" && step1.groupExisted;

  // 照合が外れたら、その区切りを消さずに止める（別の実行が終えた・入り直した）
  const episode = { uid, groupId, episodeId: step1.episodeId };
  const stillCurrent = () => isLeaveEpisodeCurrent(db, episode);
  const superseded = () => {
    result.state = "superseded";
    result.done = true;
    return result;
  };

  // 手順2
  const groupRef = db.collection(GROUPS).doc(groupId);
  const wholeGroup = step1.kind === "delete_group";
  const skies = await deleteSkiesByQuery(
    db,
    wholeGroup ? groupRef.collection(SKIES) : groupRef.collection(SKIES).where("authorId", "==", uid),
    pastDeadline,
    stillCurrent
  );
  result.skiesDeleted = skies.deleted;
  if (skies.stopped) return superseded();
  if (!skies.done) return result;

  // 手順2b（残るメンバーがいるときだけ・soratomo-reactions 4.3）。読んだ後・書く前に照合し、入り直した後のリアクションを
  // 消さない（書き込みの前提条件が、照合の後・書く前の入り直しを止める）。最後の1人なら、全投稿と recursiveDelete で消える
  if (!wholeGroup) {
    const reactions = await removeUserReactionsInGroup(db, { uid, groupId }, pastDeadline, wrapReactionCheck(stillCurrent));
    result.reactionsDeleted = reactions.deleted;
    if (reactions.stopped) return superseded();
    if (!reactions.done) return result;
  }

  // 手順3
  const prefix = wholeGroup ? `soratomo/${groupId}/` : `soratomo/${groupId}/${uid}/`;
  const images = await deleteImagesByPrefix(storage, prefix, pastDeadline, stillCurrent);
  result.imagesDeleted = images.deleted;
  if (images.stopped) return superseded();
  if (!images.done) return result;

  if (wholeGroup) {
    // 残りの子（メンバー・通知の間引き）を消す。親の文書は手順1で消えている（要確認1）
    if (!(await stillCurrent())) return superseded();
    await db.recursiveDelete(groupRef);
  }

  // 手順4（最後）
  if (!(await finishLeaveTx(db, { ...episode, kind: step1.kind }))) return superseded();
  result.done = true;
  return result;
}

// MARK: - 利用者単位の削除

/**
 * 写しがすべて消えたことを確かめて、利用者の文書を片づける（トランザクション・要件2.3・8.5）。
 * - 利用者の文書を必ず読む。参加と作成も同じ文書を読んで書くので、ここと直列になる
 * - 写しが1件でも残っていれば（途中で参加が入った）何も書かずに false を返し、呼び手が続ける
 * - 写しが無ければ、suspension 以外は利用者の文書を消す（無ければ何もしない）。suspension は文書を残し、
 *   所属数を0にそろえる（停止の日時は suspendSoratomoUser が先に書いている。ここでは触らない）
 * - ただし停止中（suspendedAt がある）の人の文書は、account_deleted 以外では消さずに suspension と同じく残す
 *   （本人の退会の削除をアカウントを消さずに呼んで、停止を解くことを防ぐ）
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, trigger: string }} params
 * @returns {Promise<boolean>} 片づけたら true
 */
async function finishUserTx(db, { uid, trigger }) {
  const userRef = db.collection(USERS).doc(uid);
  return db.runTransaction(async (tx) => {
    const userSnap = await tx.get(userRef);
    const copySnap = await tx.get(userRef.collection(USER_GROUPS).limit(1));
    if (!copySnap.empty) return false;

    // 停止中の人の文書は、アカウントの無い人の後始末（account_deleted）のときだけ消す。本人の退会の削除（self）は
    // アカウントを消さずにも呼べるので、ここで消すと停止の記録が消えて、同意し直せば作成・参加・投稿ができてしまう
    // （停止のすり抜け）。管理（admin）も、スクリプトの検査に頼らず同じ側に倒す。アカウントを消した後は定期実行が
    // account_deleted で文書ごと消すので、要件2.3（停止の記録も消す）は数時間遅れて満たされる
    const suspendedAt = userSnap.exists ? userSnap.get("suspendedAt") : undefined;
    const keepSuspension = trigger !== "account_deleted" && core.isSuspended(suspendedAt);

    // ここから書き込み
    if (trigger === "suspension" || keepSuspension) {
      if (userSnap.exists) tx.update(userRef, { groupCount: 0, updatedAt: FieldValue.serverTimestamp() });
    } else if (userSnap.exists) {
      tx.delete(userRef);
    }
    return true;
  });
}

/**
 * 1人のそらとものデータを消す（design の deleteSoratomoUserData・release-gate 要件1・2・3.3・3.4・3.8・8.5・14.4）。
 * - グループは、所属の写しのグループIDと、管理スクリプトが渡す extraGroupIds の和（同じIDは1回だけ）。
 *   写しの無い孤児のグループ（文書か子だけが残ったもの）は写しから見つからないので、管理スクリプトが渡す
 * - 各グループで deleteUserDataInGroup（手順1〜4）を行う。1つでも未完了（締め切り）なら、その時点の件数で
 *   done: false を返す。写しが残るので、次の呼び出しが続ける。途中の失敗は投げる
 * - 全部を処理した後、finishUserTx で写しが空なのを確かめて利用者の文書を片づける。途中で参加が入って写しが
 *   増えていれば、もう一度写しを読んで続ける。参加が続く限り繰り返すが、各グループの前と、写しの増加を見つけた後に
 *   締め切りを確かめるので、予算で必ず切れる（無限には回らない）
 * - そらともを使っていない人（匿名を含む・文書も写しも無い）は、何も書かずに done: true（3.8）
 * - 写しの文書IDが自動IDの形でなければ deleteUserDataInGroup が TypeError を投げ、削除は失敗のまま止まる。
 *   黙って飛ばすと、そのグループの投稿が残ったまま完了と扱うことになるため（壊れた文書を無言で落とさない）
 * - 件数（14.4）: groupsLeft はこの実行でメンバーの文書を消したグループの数、ownersTransferred はそのうちオーナーを
 *   引き継いだ数。groupsDeleted はこの実行でグループの文書を消した数。ふつうは groupsLeft の内訳だが、
 *   extraGroupIds で渡したメンバーのいない孤児のグループの文書を消したときは、groupsLeft に数えずに数える
 *   （運用の出力で「消したのに0」と見えないように）。reactionsDeleted は各グループの手順2bで外したリアクションの数の和
 *   （soratomo-reactions D4・14.5）
 * @param {{ db: FirebaseFirestore.Firestore,
 *   storage: import("./soratomoStorage").SoratomoStorageGateway, nowMs: () => number }} deps
 * @param {{ uid: string, trigger: "self"|"account_deleted"|"admin"|"suspension", deadlineMs: number,
 *   extraGroupIds?: string[] }} request
 * @returns {Promise<{ done: boolean, skiesDeleted: number, imagesDeleted: number,
 *   groupsLeft: number, ownersTransferred: number, groupsDeleted: number, reactionsDeleted: number }>}
 */
async function deleteSoratomoUserData(deps, { uid, trigger, deadlineMs, extraGroupIds = [] }) {
  const { db, nowMs } = assertDeps(deps, { needsClock: true });
  if (!isUid(uid)) throw new TypeError("soratomo: uid が文書IDとして使えない");
  if (!TRIGGERS.includes(trigger)) throw new TypeError("soratomo: trigger が呼び手の4つのどれでもない");
  assertDeadline(deadlineMs);
  if (!Array.isArray(extraGroupIds) || !extraGroupIds.every((id) => core.isAutoId(id))) {
    throw new TypeError("soratomo: extraGroupIds が自動IDの配列でない");
  }

  const totals = {
    done: false,
    skiesDeleted: 0,
    imagesDeleted: 0,
    groupsLeft: 0,
    ownersTransferred: 0,
    groupsDeleted: 0,
    reactionsDeleted: 0,
  };
  const userRef = db.collection(USERS).doc(uid);
  // 追加のグループIDは最初の1周だけ（未完了で返ったときは、呼び手が同じ要求で呼び直す）
  let extras = extraGroupIds;
  for (;;) {
    const copies = await userRef.collection(USER_GROUPS).get();
    const groupIds = [...new Set([...copies.docs.map((doc) => doc.id), ...extras])];
    extras = [];
    for (const groupId of groupIds) {
      const r = await deleteUserDataInGroup(deps, { uid, groupId, deadlineMs });
      totals.skiesDeleted += r.skiesDeleted;
      totals.imagesDeleted += r.imagesDeleted;
      totals.reactionsDeleted += r.reactionsDeleted;
      if (r.removed) totals.groupsLeft += 1;
      if (r.ownerTransferred) totals.ownersTransferred += 1;
      if (r.groupDeleted) totals.groupsDeleted += 1;
      if (!r.done) return totals;
    }
    if (await finishUserTx(db, { uid, trigger })) {
      totals.done = true;
      return totals;
    }
    // 写しが増えていた。続ける前にも締め切りを見る（写しを読み直す間にまた消えるような競合でも、空回りし続けないように）
    if (nowMs() >= deadlineMs) return totals;
  }
}

// MARK: - 利用停止・解除

/**
 * 利用停止の日時を書く（まだ無いときだけ。再実行で最初の日時を上書きしない）。文書が無ければ作る
 * （そらともを使っていない人も、以後の作成・参加・投稿を止めるため・8.6）。
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} uid
 */
async function markSuspendedTx(db, uid) {
  const userRef = db.collection(USERS).doc(uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const current = snap.exists ? snap.get("suspendedAt") : undefined;
    if (core.isSuspended(current)) return;
    tx.set(userRef, { suspendedAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp() }, { merge: true });
  });
}

/**
 * 利用者を停止する（release-gate 要件8.5・8.6）。停止の日時を先に書いてから、trigger "suspension" で消す。
 * 先に書くので、削除の途中の参加・作成・投稿は、soratomoStore の検査で suspended として拒否される。
 * 終わると、利用者の文書は停止の日時と所属数0で残る。未完了で返ったときは、同じ呼び出しを繰り返せば続きから消える。
 * @param {{ db: FirebaseFirestore.Firestore,
 *   storage: import("./soratomoStorage").SoratomoStorageGateway, nowMs: () => number }} deps
 * @param {{ uid: string, deadlineMs: number }} params
 * @returns {Promise<{ done: boolean, skiesDeleted: number, imagesDeleted: number,
 *   groupsLeft: number, ownersTransferred: number, groupsDeleted: number, reactionsDeleted: number }>}
 */
async function suspendSoratomoUser(deps, { uid, deadlineMs }) {
  // 停止の日時を書く前に、削除の引数を確かめる（引数の誤りで停止だけが書かれないように）
  const { db } = assertDeps(deps, { needsClock: true });
  if (!isUid(uid)) throw new TypeError("soratomo: uid が文書IDとして使えない");
  assertDeadline(deadlineMs);

  await markSuspendedTx(db, uid);
  return deleteSoratomoUserData(deps, { uid, trigger: "suspension", deadlineMs });
}

/**
 * 利用停止を解く（release-gate 要件8.8）。停止の日時だけを消し、消した投稿と所属は戻さない。
 * 文書が無ければ何もしない（作らない）。
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string }} params
 * @returns {Promise<void>}
 */
async function unsuspendSoratomoUser(db, { uid }) {
  if (!db || typeof db.collection !== "function") throw new TypeError("soratomo: db が無い");
  if (!isUid(uid)) throw new TypeError("soratomo: uid が文書IDとして使えない");
  const userRef = db.collection(USERS).doc(uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    if (!snap.exists) return;
    tx.update(userRef, { suspendedAt: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() });
  });
}

// MARK: - 投稿1件の削除

/**
 * 投稿1件の文書と画像（soratomo/{groupId}/{authorId}/{skyId}/ の下・display.jpg と thumb.jpg）を消す
 * （release-gate 要件8.4・開発者の運用手順から使う）。
 * - 画像を先に、文書を後に消す。文書を先に消すと、画像の削除が失敗した後の再実行で投稿者（画像の場所）がわからなくなる
 * - 文書が無ければ何もしない（{ skyDeleted: false, imagesDeleted: 0 }）
 * - 投稿者の記録が壊れていれば、推測で消さずに投げる
 * - 通報の記録・グループの最新の投稿日時には触れない
 * @param {{ db: FirebaseFirestore.Firestore, storage: import("./soratomoStorage").SoratomoStorageGateway }} deps
 * @param {{ groupId: string, skyId: string }} params
 * @returns {Promise<{ skyDeleted: boolean, imagesDeleted: number }>}
 */
async function deleteSoratomoSky(deps, { groupId, skyId }) {
  const { db, storage } = assertDeps(deps, { needsClock: false });
  if (!core.isAutoId(groupId) || !core.isAutoId(skyId)) throw new TypeError("soratomo: groupId・skyId が自動IDの形でない");

  const skyRef = db.collection(GROUPS).doc(groupId).collection(SKIES).doc(skyId);
  const snap = await skyRef.get();
  if (!snap.exists) return { skyDeleted: false, imagesDeleted: 0 };
  const authorId = snap.get("authorId");
  if (!isUid(authorId)) throw new Error("soratomo: 投稿の authorId が壊れている");

  // 締め切りは持たない（1件の画像は2枚だけ）
  const images = await deleteImagesByPrefix(storage, `soratomo/${groupId}/${authorId}/${skyId}/`, () => false);
  await skyRef.delete();
  return { skyDeleted: true, imagesDeleted: images.deleted };
}

module.exports = {
  SKY_PAGE_SIZE,
  IMAGE_CHECK_EVERY,
  IMAGE_DELETE_CONCURRENCY,
  TRIGGERS,
  leaveOrDeleteGroupTx,
  deleteUserDataInGroup,
  deleteSoratomoUserData,
  suspendSoratomoUser,
  unsuspendSoratomoUser,
  deleteSoratomoSky,
  // soratomo-reactions
  removeUserReactionsInGroup, // テストで、読んだ後・書く前に投稿を消す・書き換える場面を照合の口から作るため
  updateDocChunk, // テストで、偽の write から NOT_FOUND(5) を飛ばす枝と 5・9 以外を投げ直す枝を通すため（エミュレーターは消えた文書にも 9 を返す）
  // leave-group
  PENDING_LEAVES,
  LEAVE_ORIGINS,
  isUid, // 定期実行の仕事C（soratomo.js）が、印の uid の形を同じ規則で確かめるため
  beginLeaveTx, // テストで手順1の印（episodeId・leftAt）を直接見るため（leaveOrDeleteGroupTx と同じ扱い）
  leaveSoratomoGroup,
};
