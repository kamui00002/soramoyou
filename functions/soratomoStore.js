//
// そらもよう Cloud Functions — 「そらとも」の Admin のトランザクション ⭐️
//
// グループの作成・招待コードでの参加・招待コードの再発行（要件2・3・4）と、受信者ごとの通知の枠の確保
// （要件9.4）を置く。どれも db（firebase-admin の Firestore）を受け取り、Firestore のトランザクションの中で
// 読んで判定してから書く。上限（所属10個・メンバー20人）と招待コードの一意性は、同時の呼び出しでも
// トランザクションが守る（要件11.8・11.10）。
//
// - 判定の中身（コードの生成と正規化・名前の検証・間引き）は soratomoCore.js の純関数を使う。
// - 失敗は理由（reason）を持つ SoratomoDomainError で投げる。HttpsError への写像は配線（soratomo.js・tasks 8.1）が行う。
//   SoratomoDomainError 以外の失敗（コードの空きが見つからない・引数の型の誤り・Firestore の失敗）は想定外として internal にする。
// - 利用者の文書（users）には書かない。表示名や通知設定は users にあるが、ここでは読みも書きもしない。
// - 作成と参加は、省略できない方針（policy: 現行のガイドラインの版・NGワードの判定）を受け取り、利用停止・同意・
//   NGワードを確かめる（release-gate 2.1）。方針を省略すると、検査を黙って飛ばさないよう TypeError にする。
// - 投稿の作成（createSkyTx・release-gate 2.2）もここに置く。利用停止・メンバー・NGワードを確かめてから書く。
// - 通報の受け付け（reportSkyTx・release-gate 2.3）もここに置く。記録は soratomoReports（グループの外）に作る。
// - ガイドラインへの同意の記録（agreeGuidelineTx・release-gate 2.4）もここに置く。soratomoUsers/{uid} に merge で書く。
// - 本人のリアクション（setReactionTx・soratomo-reactions 2.2）もここに置く。投稿の文書の reactions.{uid} と reactorIds だけを書く。
// - 投稿者へのリアクションの通知の枠（claimReactionNotifySlot・soratomo-reactions 2.3）もここに置く。新着投稿の notifyState とは別に数える。
// - テストは soratomoStore.test.js（Firestore のエミュレーターに対して直接呼ぶ）。
//
// ⚠️ Firestore のトランザクションは「読みを全部終えてから書く」決まり。招待コードの重なりの確認（最大5回の読み）も
//    書き込みより前に済ませる。
// ⚠️ SoratomoDomainError には gRPC の code を持たせない。Admin SDK は code を見て再試行するかを決めるため、
//    持たせると上限の判定で投げたエラーまで再試行されてしまう。
//

"use strict";

const { FieldPath, FieldValue, Timestamp } = require("firebase-admin/firestore");
const core = require("./soratomoCore");

// MARK: - 定数

/** コレクションの名前（design.md の Physical Data Model）。 */
const GROUPS = "soratomoGroups";
const MEMBERS = "members";
const NOTIFY_STATE = "notifyState";
const INVITE_CODES = "soratomoInviteCodes";
const USERS = "soratomoUsers";
const USER_GROUPS = "groups";
const SKIES = "skies";
const REPORTS = "soratomoReports";
/** リアクションの通知の記録（soratomo-reactions design.md の Physical Data Model。書き手は Functions だけ）。 */
const REACTION_NOTIFY_STATE = "reactionNotifyState";
const REACTION_NOTICES = "reactionNotices";

/** 招待コードが既存と重なったときに作り直す最大の回数（要件3.2）。 */
const MAX_INVITE_CODE_ATTEMPTS = 5;
/** 作成の要求ID（アプリが作る UUID）の長さの上限。 */
const REQUEST_ID_MAX = 128;

// MARK: - エラー

/** 理由つきの失敗。配線（soratomo.js）が HttpsError の code と details.reason に写す。 */
class SoratomoDomainError extends Error {
  /**
   * @param {"invalid_name"|"invalid_format"|"not_found"|"group_full"|"user_limit"|"not_owner"
   *   |"suspended"|"consent_required"|"ng_word"|"invalid_input"|"not_member"|"invalid_reason"|"sky_not_found"
   *   |"self_report"|"outdated_guideline"|"leave_pending"|"self_reaction"|"invalid_reaction"} reason
   * @param {{ currentVersion: number }|null} [details] 利用者へ返してよい詳細。いまは consent_required と
   *   outdated_guideline の現行のガイドラインの版だけ（アプリが「同意が要る」と「アプリが古い」を見分けるため・
   *   release-gate 2.1・2.4）。
   *   配線が HttpsError の details に写す（tasks 4.1）。gRPC の code はここにも持たせない（上の ⚠️）。
   */
  constructor(reason, details = null) {
    super(`soratomo: ${reason}`);
    this.name = "SoratomoDomainError";
    this.reason = reason;
    this.details = details;
  }
}

// MARK: - 下まわり

/**
 * 文書IDとして使える文字列か（空でない・「/」を含まない・「.」「..」でない）。
 * @param {unknown} value
 * @returns {boolean}
 */
function isDocumentId(value) {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= 1500 &&
    !value.includes("/") &&
    value !== "." &&
    value !== ".."
  );
}

/**
 * 呼び出し元の uid を確かめる。配線が request.auth.uid を渡すので、ここで外れるのは実装の誤り（internal）。
 * @param {unknown} uid
 */
function assertUid(uid) {
  if (!isDocumentId(uid)) throw new TypeError("soratomo: uid が文書IDとして使えない");
}

/**
 * 作成・参加・投稿の方針を確かめる（release-gate 2.1・2.2）。省略や形の誤りは、検査を黙って飛ばさないよう TypeError
 * （配線では internal）にする。
 * - guidelineVersion: 現行のガイドラインの版（1以上の整数）。同意を確かめる作成と参加に要る（投稿は同意を確かめない）
 * - containsNgWord: NGワードの判定。グループ名を検査する作成と、キャプションを検査する投稿に要る。参加は求めない
 *   （求めると、語のリストが読めないときに参加まで止まる。design の API Contract で参加は語のリストに依存しない）
 * @param {unknown} policy
 * @param {{ needsVersion: boolean, needsNgWord: boolean }} options
 */
function assertPolicy(policy, { needsVersion, needsNgWord }) {
  if (!policy || typeof policy !== "object") throw new TypeError("soratomo: policy が無い");
  if (needsVersion && (!Number.isInteger(policy.guidelineVersion) || policy.guidelineVersion < 1)) {
    throw new TypeError("soratomo: policy.guidelineVersion が1以上の整数でない");
  }
  if (needsNgWord && typeof policy.containsNgWord !== "function") {
    throw new TypeError("soratomo: policy.containsNgWord が関数でない");
  }
}

/**
 * 利用停止を確かめる（release-gate 8.6）。作成・参加・投稿のトランザクションの中で、ほかの判定より先に呼ぶ。
 * suspendedAt に null 以外の値があれば停止中（停止中だけ持つ項目。型は問わず、値があれば止める側に倒す）。
 * @param {Object} user soratomoUsers/{uid} の中身（文書が無ければ {}）
 */
function assertNotSuspended(user) {
  if (core.isSuspended(user.suspendedAt)) throw new SoratomoDomainError("suspended");
}

/**
 * 利用停止と同意を、この順で確かめる（release-gate 8.6・10.9・10.10）。作成と参加のトランザクションの中で呼ぶ。
 * - 同意: guidelineVersion が現行の版と等しいときだけ認める。古い版も、現行より新しい版も認めない
 * 利用停止を先に見るのは、停止中の人に同意の全文を出しても作成・参加はできないため（アプリは停止の案内を出す）。
 * @param {Object} user soratomoUsers/{uid} の中身（文書が無ければ {}）
 * @param {number} guidelineVersion 現行のガイドラインの版（方針から）
 */
function assertNotSuspendedAndAgreed(user, guidelineVersion) {
  assertNotSuspended(user);
  if (user.guidelineVersion !== guidelineVersion) {
    throw new SoratomoDomainError("consent_required", { currentVersion: guidelineVersion });
  }
}

/**
 * 所属数・メンバー数を読む。欠落や壊れた値は 0 とみなす。
 * @param {unknown} value
 * @returns {number}
 */
function countOf(value) {
  return Number.isInteger(value) && value >= 0 ? value : 0;
}

/**
 * まだ使われていない招待コードを、トランザクションの中で選ぶ（要件3.1・3.2）。
 * 不在を読んだ文書はトランザクションの対象になるので、同時に同じコードを選んだ別の作成とは衝突して再試行になる。
 * @param {FirebaseFirestore.Transaction} tx
 * @param {FirebaseFirestore.Firestore} db
 * @param {((max: number) => number)|undefined} randomInt テストでだけ差し替える乱数
 * @returns {Promise<string>}
 */
async function pickUnusedInviteCode(tx, db, randomInt) {
  for (let attempt = 0; attempt < MAX_INVITE_CODE_ATTEMPTS; attempt++) {
    const code = core.generateInviteCode(randomInt);
    const snap = await tx.get(db.collection(INVITE_CODES).doc(code));
    if (!snap.exists) return code;
  }
  // 32文字の8桁（約1兆通り）で5回続けて重なるのは、乱数か保存の異常。コードはログに出さない。
  throw new Error("soratomo: 招待コードの空きが5回続けて見つからなかった");
}

// MARK: - 作成

/**
 * グループを作る（要件2.4・2.5・3.1・3.2・3.13）。作成者はオーナーかつ最初のメンバーになる。
 * 判定の順（release-gate 2.1）: invalid_name（トランザクションの前）→ suspended → consent_required →
 * 同じ要求IDの再送 → ng_word → user_limit。
 * - 同じ要求IDの再送では、前回作ったグループを返す（冪等。タイムアウトの後の再試行で2つ目を作らない）。
 *   NGワードより先に見るので、語のリストを変えた後の送り直しでも、作れたグループを失わない。
 *   ただし、いまもそのグループのメンバーのときだけ返す。利用停止の削除は利用者の文書（前回の要求IDの記録）を残すので、
 *   解除の後に同じ要求IDを送ると、外されたグループの今の招待コードを取り戻せてしまう（要件8.8・レビュー #9）。
 *   メンバーでなければ、ふつうの作成に進む
 * - 所属がすでに10個なら user_limit
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, name: unknown, requestId: unknown,
 *   policy: { guidelineVersion: number, containsNgWord: (text: string) => boolean } }} params
 *   policy は省略できない（assertPolicy）
 * @param {{ randomInt?: (max: number) => number }} [options] テストでだけ使う
 * @returns {Promise<{ groupId: string, name: string, inviteCode: string, memberCount: number }>}
 */
async function createGroupTx(db, { uid, name, requestId, policy }, { randomInt } = {}) {
  assertUid(uid);
  assertPolicy(policy, { needsVersion: true, needsNgWord: true });
  const validated = core.validateGroupName(name);
  if (!validated.ok) throw new SoratomoDomainError("invalid_name");
  if (typeof requestId !== "string" || requestId.length === 0 || requestId.length > REQUEST_ID_MAX) {
    throw new TypeError("soratomo: requestId が不正");
  }

  return db.runTransaction(async (tx) => {
    const userRef = db.collection(USERS).doc(uid);
    const userSnap = await tx.get(userRef);
    const user = userSnap.exists ? userSnap.data() : {};

    assertNotSuspendedAndAgreed(user, policy.guidelineVersion);

    // 冪等: 前回と同じ要求IDなら、前回のグループと自分のメンバーの文書をこのトランザクションの中で読み、
    // いまもメンバーなら前回のグループを返す
    if (user.lastCreateRequestId === requestId && isDocumentId(user.lastCreatedGroupId)) {
      const previousRef = db.collection(GROUPS).doc(user.lastCreatedGroupId);
      const [previous, previousMember] = await tx.getAll(previousRef, previousRef.collection(MEMBERS).doc(uid));
      if (previous.exists && previousMember.exists) {
        const g = previous.data();
        return { groupId: previous.id, name: g.name, inviteCode: g.inviteCode, memberCount: g.memberCount };
      }
    }

    // 該当した語は、どこにも出さない（理由だけ・要件11.9）
    if (policy.containsNgWord(validated.name)) throw new SoratomoDomainError("ng_word");

    const groupCount = countOf(user.groupCount);
    if (groupCount >= core.MAX_GROUPS_PER_USER) throw new SoratomoDomainError("user_limit");

    const inviteCode = await pickUnusedInviteCode(tx, db, randomInt);

    // ここから書き込み（読みはすべて終わっている）
    const groupRef = db.collection(GROUPS).doc();
    const now = FieldValue.serverTimestamp();
    tx.create(groupRef, {
      name: validated.name,
      ownerId: uid,
      inviteCode,
      memberCount: 1,
      createdAt: now,
      lastActivityAt: now,
    });
    tx.create(groupRef.collection(MEMBERS).doc(uid), { uid, role: "owner", joinedAt: now });
    tx.create(db.collection(INVITE_CODES).doc(inviteCode), { groupId: groupRef.id, createdAt: now });
    tx.set(
      userRef,
      { groupCount: groupCount + 1, lastCreateRequestId: requestId, lastCreatedGroupId: groupRef.id, updatedAt: now },
      { merge: true }
    );
    tx.create(userRef.collection(USER_GROUPS).doc(groupRef.id), { groupId: groupRef.id, joinedAt: now });

    return { groupId: groupRef.id, name: validated.name, inviteCode, memberCount: 1 };
  });
}

// MARK: - 参加

/**
 * 招待コードでグループに参加する（要件4.5〜4.8）。
 * 判定の順（release-gate 2.1・leave-group 2.1）: invalid_format（トランザクションの前）→ suspended → consent_required →
 * コードの不在 → 既存のメンバー → 片づけ中 → 所属10個 → 満員20人。
 * 利用停止と同意は、コードの有無と既存のメンバーより先に見る（停止中や同意の無い既存のメンバーも成功にしない）。
 * 既存のメンバーなら、上限とは無関係に alreadyMember: true の成功で返し、何も増やさない（要件4.8）。
 * 片づけ中（このグループの所属の写しが残り、メンバーの文書が無い＝抜けるか退会の途中）なら leave_pending で断る
 * （leave-group 要件8.4）。写しは create で作るので、断らないとコミットが ALREADY_EXISTS になり internal に化ける。
 * 所属10個より先に見るのは、片づけ中のグループが所属数に数えられたままで、user_limit と誤って案内しないため。
 * 片づけ中の印（soratomoPendingLeaves）の有無は見ない（退会の途中の写しも同じく断る）。
 * メンバーの文書・メンバー数・所属の写し・所属数は、同じトランザクションでそろって増やす（要件11.8）。
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, code: unknown, policy: { guidelineVersion: number } }} params
 *   policy は省略できない（assertPolicy）。参加は NGワードを検査しないので containsNgWord は使わない
 * @returns {Promise<{ groupId: string, alreadyMember: boolean }>}
 */
async function joinGroupTx(db, { uid, code, policy }) {
  assertUid(uid);
  assertPolicy(policy, { needsVersion: true, needsNgWord: false });
  const normalized = core.normalizeInviteCode(code);
  if (normalized === null) throw new SoratomoDomainError("invalid_format");

  return db.runTransaction(async (tx) => {
    const userRef = db.collection(USERS).doc(uid);
    const [codeSnap, userSnap] = await tx.getAll(db.collection(INVITE_CODES).doc(normalized), userRef);
    const user = userSnap.exists ? userSnap.data() : {};

    assertNotSuspendedAndAgreed(user, policy.guidelineVersion);

    const groupId = codeSnap.exists ? codeSnap.get("groupId") : null;
    if (!isDocumentId(groupId)) throw new SoratomoDomainError("not_found");

    const groupRef = db.collection(GROUPS).doc(groupId);
    const memberRef = groupRef.collection(MEMBERS).doc(uid);
    const copyRef = userRef.collection(USER_GROUPS).doc(groupId);
    const [groupSnap, memberSnap, copySnap] = await tx.getAll(groupRef, memberRef, copyRef);

    // コードの文書が残っていても、グループの今のコードでなければ無効（再発行の後の古いコード・要件3.10）
    if (!groupSnap.exists || groupSnap.get("inviteCode") !== normalized) throw new SoratomoDomainError("not_found");
    if (memberSnap.exists) return { groupId, alreadyMember: true };
    // メンバーの文書が無いのに写しが残っている＝片づけ中（上の説明）
    if (copySnap.exists) throw new SoratomoDomainError("leave_pending");

    const groupCount = countOf(user.groupCount);
    if (groupCount >= core.MAX_GROUPS_PER_USER) throw new SoratomoDomainError("user_limit");
    const memberCount = countOf(groupSnap.get("memberCount"));
    if (memberCount >= core.MAX_MEMBERS) throw new SoratomoDomainError("group_full");

    // ここから書き込み
    const now = FieldValue.serverTimestamp();
    tx.create(memberRef, { uid, role: "member", joinedAt: now });
    tx.update(groupRef, { memberCount: memberCount + 1 });
    tx.set(userRef, { groupCount: groupCount + 1, updatedAt: now }, { merge: true });
    tx.create(copyRef, { groupId, joinedAt: now });

    return { groupId, alreadyMember: false };
  });
}

// MARK: - 投稿の作成

/**
 * そらとも投稿の文書を作る（release-gate 8.6・11.1・11.4・11.5）。投稿の作成はこの関数だけが行う
 * （ルールの skies の create は閉じる・tasks 5）。どのクライアントの要求もここを通る。
 * 判定の順: invalid_input（トランザクションの前）→ suspended → not_member → 既存の文書 → ng_word → 作成。
 * - 同意は確かめない（投稿は拒否しない・決定事項14・要件10の補足）
 * - 既存の文書が同じ投稿者なら created: false の成功で返す（同じ投稿IDの送り直しが1件で済む）。NGワードより先に
 *   見るので、語のリストを変えた後の送り直しでも、作れた投稿を失敗にしない。違う投稿者なら想定外の失敗（internal）
 * - メンバーの文書を読むので、退会の削除（メンバーの文書を消す手順）とは直列になる（design の「共通の削除の手順」）
 * - 書く項目は旧ルール（isValidSoratomoSky）と同じ5つ。投稿者は認証の uid、作成日時はサーバーの時刻にする。
 *   キャプションが無ければ項目ごと省く（null を書くと、アプリの decodeSky が壊れた文書として扱う）
 * - NGワードで拒否した投稿は文書を作らないので、onSoratomoSkyCreated は発火せず、通知も送られない（要件11.4）
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, input: unknown, policy: { containsNgWord: (text: string) => boolean } }} params
 *   input は要求の本文（soratomoCore.validateSkyInput で確かめる）。policy は省略できない（assertPolicy）
 * @returns {Promise<{ skyId: string, created: boolean }>}
 */
async function createSkyTx(db, { uid, input, policy }) {
  assertUid(uid);
  assertPolicy(policy, { needsVersion: false, needsNgWord: true });
  const validated = core.validateSkyInput(input);
  if (!validated.ok) throw new SoratomoDomainError("invalid_input");
  const { groupId, skyId, caption, width, height } = validated.value;

  return db.runTransaction(async (tx) => {
    const groupRef = db.collection(GROUPS).doc(groupId);
    const skyRef = groupRef.collection(SKIES).doc(skyId);
    const [userSnap, memberSnap, skySnap] = await tx.getAll(
      db.collection(USERS).doc(uid),
      groupRef.collection(MEMBERS).doc(uid),
      skyRef
    );

    assertNotSuspended(userSnap.exists ? userSnap.data() : {});
    if (!memberSnap.exists) throw new SoratomoDomainError("not_member");
    if (skySnap.exists) {
      if (skySnap.get("authorId") === uid) return { skyId, created: false };
      // 投稿IDはアプリが作る自動IDなので、別の人と重なるのは異常。上書きせずに止める（ID はログに出さない）
      throw new Error("soratomo: 同じ投稿IDの文書が別の投稿者で既にある");
    }
    // 該当した語は、どこにも出さない（理由だけ・要件11.9）。キャプションが無ければ検査しない
    if (caption !== null && policy.containsNgWord(caption)) throw new SoratomoDomainError("ng_word");

    // ここから書き込み
    const sky = { authorId: uid, width, height, createdAt: FieldValue.serverTimestamp() };
    if (caption !== null) sky.caption = caption;
    tx.create(skyRef, sky);
    return { skyId, created: true };
  });
}

// MARK: - 通報の受け付け

/**
 * そらとも投稿の通報を受け付けて記録する（release-gate 5.9・6.1〜6.9）。
 * 判定の順: invalid_input（ID の形・トランザクションの前）→ invalid_reason（前）→ not_member → sky_not_found →
 * self_report → 記録がある → 作る。
 * - 通報者は認証の uid（6.2）。投稿者は投稿の文書の authorId から取り、要求の値は使わない（6.8）
 * - 記録の文書IDは soratomoCore.reportDocId（groupId_skyId_reporterId）。同じ人の同じ投稿への2回目は、記録を作り直さず
 *   （転送の状態も戻さず）、受け付けと同じ結果を返す（6.7）。作らないので、転送のトリガーも動かない
 * - 記録の項目は ID・理由・サーバーの時刻・転送の状態の8つだけ。キャプション・グループ名・表示名・招待コード・
 *   画像の場所は書かない（6.9）。通報者・投稿者・ほかのメンバーには何も送らない（5.9）
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, input: unknown }} params input は要求の本文（{ groupId, skyId, reason }）
 * @returns {Promise<{ accepted: true, reportId: string, duplicate: boolean }>}
 *   利用者へ返すのは accepted だけにする（配線・tasks 4.2）。reportId と duplicate はログ用（design の Monitoring）
 */
async function reportSkyTx(db, { uid, input }) {
  assertUid(uid);
  const data = input && typeof input === "object" && !Array.isArray(input) ? input : {};
  if (!core.isAutoId(data.groupId) || !core.isAutoId(data.skyId)) throw new SoratomoDomainError("invalid_input");
  if (!core.isReportReason(data.reason)) throw new SoratomoDomainError("invalid_reason");
  const { groupId, skyId, reason } = data;
  const reportId = core.reportDocId(groupId, skyId, uid);

  return db.runTransaction(async (tx) => {
    const groupRef = db.collection(GROUPS).doc(groupId);
    const reportRef = db.collection(REPORTS).doc(reportId);
    const [memberSnap, skySnap, reportSnap] = await tx.getAll(
      groupRef.collection(MEMBERS).doc(uid),
      groupRef.collection(SKIES).doc(skyId),
      reportRef
    );

    if (!memberSnap.exists) throw new SoratomoDomainError("not_member");
    if (!skySnap.exists) throw new SoratomoDomainError("sky_not_found");
    const authorId = skySnap.get("authorId");
    if (!isDocumentId(authorId)) throw new Error("soratomo: 通報の対象の投稿の authorId が壊れている");
    if (authorId === uid) throw new SoratomoDomainError("self_report");
    if (reportSnap.exists) return { accepted: true, reportId, duplicate: true };

    // ここから書き込み
    tx.create(reportRef, {
      groupId,
      skyId,
      authorId,
      reporterId: uid,
      reason,
      createdAt: FieldValue.serverTimestamp(),
      forwardStatus: "pending",
      forwardAttempts: 0,
    });
    return { accepted: true, reportId, duplicate: false };
  });
}

// MARK: - ガイドラインへの同意の記録

/**
 * そらともガイドラインへの同意を記録する（release-gate 10.6・10.9・10.14）。
 * 判定の順: 方針（TypeError）→ invalid_input（版が整数でない・トランザクションの前）→
 * outdated_guideline（現行の版と違う。古い版も、新しすぎる版も）→ 記録。
 * - 書くのは認証の uid の文書だけ（要求に uid を書かせない）。項目は同意した版・サーバー時刻の同意日時・更新日時の3つで、
 *   merge で書き、所属数・所属の写し・作成の要求IDなどの既存の項目は壊さない
 * - 拒否では何も書かない（文書の無い人に文書を作らない）。outdated_guideline には現行の版を details に付ける
 *   （アプリが「アプリが古い」を案内するため）
 * - 利用者の文書を読んでから書くトランザクションにする。退会の削除の最後の確認（同じ文書を読んで消す）と直列にするため
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, input: unknown, policy: { guidelineVersion: number } }} params
 *   input は要求の本文（{ version }）。policy は省略できない（assertPolicy）
 * @returns {Promise<{ version: number }>}
 */
async function agreeGuidelineTx(db, { uid, input, policy }) {
  assertUid(uid);
  assertPolicy(policy, { needsVersion: true, needsNgWord: false });
  const version = input && typeof input === "object" && !Array.isArray(input) ? input.version : undefined;
  if (!Number.isInteger(version)) throw new SoratomoDomainError("invalid_input");
  if (version !== policy.guidelineVersion) {
    throw new SoratomoDomainError("outdated_guideline", { currentVersion: policy.guidelineVersion });
  }

  const userRef = db.collection(USERS).doc(uid);
  return db.runTransaction(async (tx) => {
    await tx.get(userRef);
    const now = FieldValue.serverTimestamp();
    tx.set(userRef, { guidelineVersion: version, guidelineAgreedAt: now, updatedAt: now }, { merge: true });
    return { version };
  });
}

// MARK: - 再発行

/**
 * 招待コードを再発行する（要件3.9・3.10）。オーナーのときだけ。
 * 古いコードの文書を消し、新しいコードの文書を作り、グループの inviteCode を書き換える。
 * 古いコードでの参加は以後「見つからない」になる。
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, groupId: unknown }} params
 * @param {{ randomInt?: (max: number) => number }} [options] テストでだけ使う
 * @returns {Promise<{ inviteCode: string }>}
 */
async function regenerateInviteCodeTx(db, { uid, groupId }, { randomInt } = {}) {
  assertUid(uid);
  if (!isDocumentId(groupId)) throw new SoratomoDomainError("not_found");

  return db.runTransaction(async (tx) => {
    const groupRef = db.collection(GROUPS).doc(groupId);
    const groupSnap = await tx.get(groupRef);
    if (!groupSnap.exists) throw new SoratomoDomainError("not_found");
    if (groupSnap.get("ownerId") !== uid) throw new SoratomoDomainError("not_owner");

    // 古いコードの文書は、このグループを指しているときだけ消す（他のグループのコードを消さないため）
    const oldCode = groupSnap.get("inviteCode");
    const oldCodeRef = isDocumentId(oldCode) ? db.collection(INVITE_CODES).doc(oldCode) : null;
    const oldCodeSnap = oldCodeRef ? await tx.get(oldCodeRef) : null;

    const inviteCode = await pickUnusedInviteCode(tx, db, randomInt);

    // ここから書き込み
    const now = FieldValue.serverTimestamp();
    if (oldCodeSnap && oldCodeSnap.exists && oldCodeSnap.get("groupId") === groupId) tx.delete(oldCodeRef);
    tx.create(db.collection(INVITE_CODES).doc(inviteCode), { groupId, createdAt: now });
    tx.update(groupRef, { inviteCode });

    return { inviteCode };
  });
}

// MARK: - リアクション（soratomo-reactions）

/**
 * 投稿の文書の reactions.{uid} の今の値を読む（setReactionTx の判定用）。
 * - 値が無い（undefined）: 付いていない
 * - 物で、kind が7つの名前のどれか: その名前が付いている
 * - それ以外（物でない・null・配列・kind が無い・知らない名前）: 壊れた値。「付いている」とみなし、kind は null にする
 *   （付ける要求で正しい形に書き直し、外す要求で消す。壊れた値を残さない）
 * @param {unknown} entry
 * @returns {{ present: boolean, kind: string|null }}
 */
function readOwnReaction(entry) {
  if (entry === undefined) return { present: false, kind: null };
  const valid = entry !== null && typeof entry === "object" && !Array.isArray(entry) && core.isReactionKind(entry.kind);
  return { present: true, kind: valid ? entry.kind : null };
}

/**
 * 本人のリアクションを付ける・選び直す・外す（soratomo-reactions 要件4.1〜4.11・4.14・5.5・12.1・12.7）。
 * 判定の順: invalid_input（トランザクションの前）→ invalid_reaction（前）→ トランザクションで soratomoUsers/{uid}・
 * members/{uid}・投稿の文書を getAll で読む → suspended → not_member → sky_not_found → self_reaction。
 * - invalid_input: 本文が物でない・groupId か skyId が自動IDの形でない・kind の鍵が無い（外すときは kind: null を送る契約。
 *   iOS の FirebaseFunctions が NSNull を JSON の null で送ることは、エミュレーターで確かめた・要確認Q3）
 * - invalid_reaction: kind が null でなく、7つの名前のどれでもない（絵文字そのもの・FE0F の無い形も・4.4〜4.6）
 * - self_reaction: 投稿者が本人。外す要求も拒否する（自分の投稿にリアクションは存在しない・4.3）
 * - 同意（guidelineVersion）とブロックの一覧（users/{uid}.blockedUserIds）は読まない（4.14・5.5）
 * 書き方: FieldPath で本人のキーだけを指す（uid に「.」が含まれても、ほかの人のキーに触れない）。
 * - 付ける・選び直す: reactions.{uid} に { kind, at: サーバーの時刻 }、reactorIds に arrayUnion(uid)
 * - 外す: reactions.{uid} を消し、reactorIds から arrayRemove(uid)
 * - 同じ kind を付ける・付いていないものを外す要求は、書かずに unchanged
 * - 今の値が壊れているときは「付いている」とみなし、付けると replaced・外すと removed（readOwnReaction）
 * - 投稿のほかの項目（authorId・createdAt・caption・width・height）とグループの文書には書かない（12.7。lastActivityAt を
 *   動かさない）。数は保存せず、読む側が数える（4.10）
 * - 同じ人の同時の要求は投稿の文書のトランザクションで直列になり、地図のキーが1つなので2つ残らない（4.9）
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, input: unknown }} params input は要求の本文（{ groupId, skyId, kind }。kind は名前か null）
 * @returns {Promise<{ outcome: "added"|"replaced"|"removed"|"unchanged", kind: string|null, authorId: string }>}
 *   kind は書いた後の本人のリアクション。authorId は通知の宛先で、利用者へは返さない（配線・tasks 3.1）
 */
async function setReactionTx(db, { uid, input }) {
  assertUid(uid);
  const data = input && typeof input === "object" && !Array.isArray(input) ? input : null;
  if (!data || !core.isAutoId(data.groupId) || !core.isAutoId(data.skyId) || !Object.prototype.hasOwnProperty.call(data, "kind")) {
    throw new SoratomoDomainError("invalid_input");
  }
  const { groupId, skyId, kind } = data;
  if (kind !== null && !core.isReactionKind(kind)) throw new SoratomoDomainError("invalid_reaction");

  return db.runTransaction(async (tx) => {
    const groupRef = db.collection(GROUPS).doc(groupId);
    const skyRef = groupRef.collection(SKIES).doc(skyId);
    const [userSnap, memberSnap, skySnap] = await tx.getAll(
      db.collection(USERS).doc(uid),
      groupRef.collection(MEMBERS).doc(uid),
      skyRef
    );

    assertNotSuspended(userSnap.exists ? userSnap.data() : {});
    if (!memberSnap.exists) throw new SoratomoDomainError("not_member");
    if (!skySnap.exists) throw new SoratomoDomainError("sky_not_found");
    const authorId = skySnap.get("authorId");
    if (!isDocumentId(authorId)) throw new Error("soratomo: リアクションの対象の投稿の authorId が壊れている");
    if (authorId === uid) throw new SoratomoDomainError("self_reaction");

    const ownPath = new FieldPath("reactions", uid);
    const current = readOwnReaction(skySnap.get(ownPath));

    // ここから書き込み（読みはすべて終わっている）
    if (kind === null) {
      if (!current.present) return { outcome: "unchanged", kind: null, authorId };
      tx.update(skyRef, ownPath, FieldValue.delete(), "reactorIds", FieldValue.arrayRemove(uid));
      return { outcome: "removed", kind: null, authorId };
    }
    if (current.present && current.kind === kind) return { outcome: "unchanged", kind, authorId };
    tx.update(skyRef, ownPath, { kind, at: FieldValue.serverTimestamp() }, "reactorIds", FieldValue.arrayUnion(uid));
    return { outcome: current.present ? "replaced" : "added", kind, authorId };
  });
}

// MARK: - 通知の枠

/**
 * 受信者ごとに通知の枠を確保する（要件9.4・9.9）。soratomoCore の decideThrottle で
 * 「送る・間引き・重複」を決め、送る場合は送る前に notifyState/{uid} を書く。
 * - 同じ受信者への同時の確保はトランザクションで直列になり、5分以内に送るのは1通だけになる
 * - 送信が後で失敗しても、書いた状態は戻さない（その受信者が最大5分の間に1通を取りこぼすのを受け入れる）
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ groupId: string, uid: string, skyId: string, nowMs: number }} params
 * @returns {Promise<"send"|"throttled"|"duplicate">}
 */
async function claimNotifySlot(db, { groupId, uid, skyId, nowMs }) {
  if (!isDocumentId(groupId) || !isDocumentId(uid) || !isDocumentId(skyId)) {
    throw new TypeError("soratomo: groupId・uid・skyId が文書IDとして使えない");
  }
  if (typeof nowMs !== "number" || !Number.isFinite(nowMs)) throw new TypeError("soratomo: nowMs が数値でない");

  const ref = db.collection(GROUPS).doc(groupId).collection(NOTIFY_STATE).doc(uid);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const decision = core.decideThrottle(snap.exists ? snap.data() : null, skyId, nowMs);
    if (decision === "send") {
      tx.set(ref, { lastSentAt: Timestamp.fromMillis(nowMs), lastSkyId: skyId });
    }
    return decision;
  });
}

// MARK: - リアクションの通知の枠（soratomo-reactions）

/**
 * 投稿者へのリアクションの通知を送るかを、間引きと「同じ人の同じ投稿で1通まで」の両方で1回だけ決める
 * （soratomo-reactions 要件6.5・6.6・6.8）。
 * - 1つのトランザクションで、投稿の文書・reactionNotices/{skyId}・reactionNotifyState/{authorId} を読む
 * - 投稿が無ければ何も書かずに sky_gone（付けた直後に消された投稿へは送らない）
 * - 判定は soratomoCore.decideReactionNotify（印に付けた人がいれば duplicate → 5分以内なら throttled → send）
 * - send のときだけ、送る前に reactionNotifyState/{authorId} の lastSentAt と、reactionNotices/{skyId} の
 *   notifiedReactorIds（arrayUnion・無ければ作る）を書く。間引き・重複のときは書かない（間引かれた人は印に入らないので、
 *   5分を過ぎて付け直せば届く）
 * - 新着投稿の notifyState/{uid} には触れない（別に数え、リアクションのせいで新着投稿の通知を間引かない・6.6）
 * - 同じ投稿者への同時の確保はトランザクションで直列になる。送信が後で失敗しても、書いた記録は戻さない（claimNotifySlot と同じ）
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ groupId: string, skyId: string, authorId: string, reactorUid: string, nowMs: number }} params
 *   authorId は受信者（投稿者）、reactorUid は付けた人
 * @returns {Promise<"send"|"throttled"|"duplicate"|"sky_gone">}
 */
async function claimReactionNotifySlot(db, { groupId, skyId, authorId, reactorUid, nowMs }) {
  if (![groupId, skyId, authorId, reactorUid].every((id) => isDocumentId(id))) {
    throw new TypeError("soratomo: groupId・skyId・authorId・reactorUid が文書IDとして使えない");
  }
  if (typeof nowMs !== "number" || !Number.isFinite(nowMs)) throw new TypeError("soratomo: nowMs が数値でない");

  const groupRef = db.collection(GROUPS).doc(groupId);
  const skyRef = groupRef.collection(SKIES).doc(skyId);
  const noticeRef = groupRef.collection(REACTION_NOTICES).doc(skyId);
  const stateRef = groupRef.collection(REACTION_NOTIFY_STATE).doc(authorId);
  return db.runTransaction(async (tx) => {
    const [skySnap, noticeSnap, stateSnap] = await tx.getAll(skyRef, noticeRef, stateRef);
    if (!skySnap.exists) return "sky_gone";
    const decision = core.decideReactionNotify({
      state: stateSnap.exists ? stateSnap.data() : null,
      notifiedReactorIds: noticeSnap.exists ? noticeSnap.get("notifiedReactorIds") : undefined,
      reactorUid,
      nowMs,
    });
    if (decision === "send") {
      tx.set(stateRef, { lastSentAt: Timestamp.fromMillis(nowMs) });
      tx.set(noticeRef, { notifiedReactorIds: FieldValue.arrayUnion(reactorUid) }, { merge: true });
    }
    return decision;
  });
}

module.exports = {
  SoratomoDomainError,
  createGroupTx,
  joinGroupTx,
  createSkyTx,
  reportSkyTx,
  agreeGuidelineTx,
  regenerateInviteCodeTx,
  claimNotifySlot,
  // リアクション（soratomo-reactions）
  setReactionTx,
  claimReactionNotifySlot,
};
