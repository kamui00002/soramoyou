//
// そらもよう Cloud Functions — 「そらとも」の共通の削除 ⭐️
//
// 1人のそらとものデータを、release-gate の要件1・2の規則で冪等に消す（design.md の soratomoDeletion）。
// 呼び手は4つ（本人の退会・アカウントの無い人の後始末・管理・利用停止）で、どれも同じ手順を通る。
//
// - 手順1（このファイルの leaveOrDeleteGroupTx・タスク 3.1）: グループ1つ分の「メンバーを外す・オーナーの引き継ぎ・
//   グループごとの削除」をトランザクションで行う。
// - 手順2〜4（このファイルの deleteUserDataInGroup・タスク 3.2）: 投稿と画像・通知の間引き・所属の写しを消す。
//   時間の予算（締め切り）を、グループの前・投稿300件ごと・画像100件ごとに確かめる。利用者単位の束ねはタスク 3.3 で足す。
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

const { FieldValue } = require("firebase-admin/firestore");
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

/** 投稿を1回に読んで消す件数。消し終えるたびに締め切りを確かめる（design の「投稿300件ごと」）。 */
const SKY_PAGE_SIZE = 300;
/** 画像をこの件数ずつ区切って消し、区切りごとに締め切りを確かめる（design の「画像100件ごと」）。 */
const IMAGE_CHECK_EVERY = 100;
/** 画像を同時に消す最大の件数（design の「同時に10件まで」）。 */
const IMAGE_DELETE_CONCURRENCY = 10;

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
 * Firestore の時刻をミリ秒で読む（Timestamp 以外は null）。
 * @param {unknown} value
 * @returns {number|null}
 */
function millisOf(value) {
  return value && typeof value.toMillis === "function" ? value.toMillis() : null;
}

// MARK: - 手順1: メンバーを外す・オーナーの引き継ぎ・グループごとの削除

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

  const groupRef = db.collection(GROUPS).doc(groupId);
  const selfRef = groupRef.collection(MEMBERS).doc(uid);

  return db.runTransaction(async (tx) => {
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

    if (!groupSnap.exists) {
      if (plan.removed) tx.delete(selfRef);
      return { kind: plan.kind, removed: plan.removed, ownerTransferred: false, groupExisted: false };
    }

    if (plan.kind === "delete_group") {
      // 招待コードの文書は、このグループを指しているときだけ消す（他のグループのコードを消さないため・再発行と同じ）
      const code = groupSnap.get("inviteCode");
      const codeRef = isUid(code) ? db.collection(INVITE_CODES).doc(code) : null;
      const codeSnap = codeRef ? await tx.get(codeRef) : null;

      // ここから書き込み
      if (codeSnap && codeSnap.exists && codeSnap.get("groupId") === groupId) tx.delete(codeRef);
      tx.delete(groupRef);
      if (plan.removed) tx.delete(selfRef);
      return { kind: "delete_group", removed: plan.removed, ownerTransferred: false, groupExisted: true };
    }

    // ここから書き込み（leave）
    if (plan.removed) tx.delete(selfRef);
    tx.update(groupRef, { memberCount: plan.memberCount, ownerId: plan.ownerId });
    for (const update of plan.roleUpdates) {
      tx.update(groupRef.collection(MEMBERS).doc(update.uid), { role: update.role });
    }
    return { kind: "leave", removed: plan.removed, ownerTransferred: plan.ownerTransferred, groupExisted: true };
  });
}

// MARK: - 手順2: 投稿と画像

/**
 * クエリに当たる投稿を、SKY_PAGE_SIZE 件ずつ読んで消す。1ページ消すたびに締め切りを確かめる。
 * - 読むのは文書の参照だけ（select() で項目を読まない）
 * - 1ページは WriteBatch で消す（300件は1回の上限500件に収まり、失敗はページごと投げる）
 * - 消した文書はクエリに再び当たらないので、カーソルは要らない
 * @param {FirebaseFirestore.Firestore} db
 * @param {FirebaseFirestore.Query} query 消す投稿のクエリ（退会者の投稿か、グループの全投稿）
 * @param {() => boolean} pastDeadline
 * @returns {Promise<{ done: boolean, deleted: number }>}
 */
async function deleteSkiesByQuery(db, query, pastDeadline) {
  let deleted = 0;
  for (;;) {
    const snap = await query.select().limit(SKY_PAGE_SIZE).get();
    if (snap.empty) return { done: true, deleted };
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
 * @param {import("./soratomoStorage").SoratomoStorageGateway} storage
 * @param {string} prefix 末尾が "/" の接頭辞（soratomo/{groupId}/{uid}/ か soratomo/{groupId}/）
 * @param {() => boolean} pastDeadline
 * @returns {Promise<{ done: boolean, deleted: number }>}
 */
async function deleteImagesByPrefix(storage, prefix, pastDeadline) {
  let deleted = 0;
  let chunk = [];
  for await (const path of storage.listFiles(prefix)) {
    chunk.push(path);
    if (chunk.length < IMAGE_CHECK_EVERY) continue;
    deleted += await deleteImageChunk(storage, chunk);
    chunk = [];
    if (pastDeadline()) return { done: false, deleted };
  }
  if (chunk.length > 0) deleted += await deleteImageChunk(storage, chunk);
  return { done: true, deleted };
}

// MARK: - 手順4: 所属の写し

/**
 * 写しを消し、所属数を残りの写しの件数で数え直して代入する（トランザクション・要件2.11・3.4）。
 * - 利用者の文書を必ず読む。参加と作成も同じ文書を読んで書くので、所属数の書き込みが直列になる
 *   （クエリの範囲のロックには頼らない・design の「人数の正しさ」）
 * - 写しが無くても（管理スクリプトが足したグループ・再実行）失敗しない。所属数は読めた件数で代入する
 * - 利用者の文書が無ければ作らない（写しだけを消す）。利用者の文書の扱いは 3.3 の最後の手順が決める
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, groupId: string }} params
 * @returns {Promise<void>}
 */
async function removeMembershipCopyTx(db, { uid, groupId }) {
  const userRef = db.collection(USERS).doc(uid);
  const copyRef = userRef.collection(USER_GROUPS).doc(groupId);
  await db.runTransaction(async (tx) => {
    const userSnap = await tx.get(userRef);
    const copiesSnap = await tx.get(userRef.collection(USER_GROUPS));
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
 * 手順はグループの前の締め切りの確認 → 手順1（leaveOrDeleteGroupTx）→ 手順2 → 手順3 → 手順4（写しは最後）。
 * - leave（ほかのメンバーが残る）: 退会者の投稿（authorId の一致）と soratomo/{groupId}/{uid}/ の画像を消し、
 *   退会者あての通知の間引きの状態（notifyState/{uid}）を消す。ほかのメンバーの投稿と画像には触れない（1.5）
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
 *   groupDeleted: boolean, skiesDeleted: number, imagesDeleted: number }>}
 *   kind はグループの前に締め切りを過ぎたときだけ null。groupDeleted はこの実行でグループの文書を消したか
 *   （再実行で二重に数えない）
 */
async function deleteUserDataInGroup(deps, { uid, groupId, deadlineMs }) {
  const { db, storage, nowMs } = deps || {};
  if (!db || typeof db.collection !== "function") throw new TypeError("soratomo: db が無い");
  if (!storage || typeof storage.listFiles !== "function" || typeof storage.deleteFile !== "function") {
    throw new TypeError("soratomo: storage（ゲートウェイ）が無い");
  }
  if (typeof nowMs !== "function") throw new TypeError("soratomo: nowMs が関数でない");
  if (!isUid(uid)) throw new TypeError("soratomo: uid が文書IDとして使えない");
  if (!core.isAutoId(groupId)) throw new TypeError("soratomo: groupId が自動IDの形でない");
  if (typeof deadlineMs !== "number" || !Number.isFinite(deadlineMs)) throw new TypeError("soratomo: deadlineMs が数値でない");

  const pastDeadline = () => nowMs() >= deadlineMs;
  const result = {
    done: false,
    kind: null,
    removed: false,
    ownerTransferred: false,
    groupDeleted: false,
    skiesDeleted: 0,
    imagesDeleted: 0,
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

  const prefix = wholeGroup ? `soratomo/${groupId}/` : `soratomo/${groupId}/${uid}/`;
  const images = await deleteImagesByPrefix(storage, prefix, pastDeadline);
  result.imagesDeleted = images.deleted;
  if (!images.done) return result;

  if (wholeGroup) {
    // 残りの子（メンバー・通知の間引き）を消す。親の文書は手順1で消えている（要確認1）
    await db.recursiveDelete(groupRef);
  } else {
    // 手順3: 退会者あての通知の間引きの状態（無くても失敗しない）
    await groupRef.collection(NOTIFY_STATE).doc(uid).delete();
  }

  // 手順4（最後）
  await removeMembershipCopyTx(db, { uid, groupId });
  result.done = true;
  return result;
}

module.exports = {
  SKY_PAGE_SIZE,
  IMAGE_CHECK_EVERY,
  IMAGE_DELETE_CONCURRENCY,
  leaveOrDeleteGroupTx,
  deleteUserDataInGroup,
};
