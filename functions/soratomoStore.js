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
// - テストは soratomoStore.test.js（Firestore のエミュレーターに対して直接呼ぶ）。
//
// ⚠️ Firestore のトランザクションは「読みを全部終えてから書く」決まり。招待コードの重なりの確認（最大5回の読み）も
//    書き込みより前に済ませる。
// ⚠️ SoratomoDomainError には gRPC の code を持たせない。Admin SDK は code を見て再試行するかを決めるため、
//    持たせると上限の判定で投げたエラーまで再試行されてしまう。
//

"use strict";

const { FieldValue, Timestamp } = require("firebase-admin/firestore");
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

/** 招待コードが既存と重なったときに作り直す最大の回数（要件3.2）。 */
const MAX_INVITE_CODE_ATTEMPTS = 5;
/** 作成の要求ID（アプリが作る UUID）の長さの上限。 */
const REQUEST_ID_MAX = 128;

// MARK: - エラー

/** 理由つきの失敗。配線（soratomo.js）が HttpsError の code と details.reason に写す。 */
class SoratomoDomainError extends Error {
  /**
   * @param {"flag_off"|"invalid_name"|"invalid_format"|"not_found"|"group_full"|"user_limit"|"not_owner"
   *   |"suspended"|"consent_required"|"ng_word"|"invalid_input"|"not_member"|"invalid_reason"|"sky_not_found"
   *   |"self_report"} reason
   * @param {{ currentVersion: number }|null} [details] 利用者へ返してよい詳細。いまは consent_required の
   *   現行のガイドラインの版だけ（アプリが「同意が要る」と「アプリが古い」を見分けるため・release-gate 2.1）。
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
  if (user.suspendedAt !== undefined && user.suspendedAt !== null) throw new SoratomoDomainError("suspended");
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
 *   NGワードより先に見るので、語のリストを変えた後の送り直しでも、作れたグループを失わない
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

    // 冪等: 前回と同じ要求IDなら、前回のグループをこのトランザクションの中で読んで返す
    if (user.lastCreateRequestId === requestId && isDocumentId(user.lastCreatedGroupId)) {
      const previous = await tx.get(db.collection(GROUPS).doc(user.lastCreatedGroupId));
      if (previous.exists) {
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
 * 判定の順（release-gate 2.1）: invalid_format（トランザクションの前）→ suspended → consent_required →
 * コードの不在 → 既存のメンバー → 所属10個 → 満員20人。
 * 利用停止と同意は、コードの有無と既存のメンバーより先に見る（停止中や同意の無い既存のメンバーも成功にしない）。
 * 既存のメンバーなら、上限とは無関係に alreadyMember: true の成功で返し、何も増やさない（要件4.8）。
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
    const [groupSnap, memberSnap] = await tx.getAll(groupRef, memberRef);

    // コードの文書が残っていても、グループの今のコードでなければ無効（再発行の後の古いコード・要件3.10）
    if (!groupSnap.exists || groupSnap.get("inviteCode") !== normalized) throw new SoratomoDomainError("not_found");
    if (memberSnap.exists) return { groupId, alreadyMember: true };

    const groupCount = countOf(user.groupCount);
    if (groupCount >= core.MAX_GROUPS_PER_USER) throw new SoratomoDomainError("user_limit");
    const memberCount = countOf(groupSnap.get("memberCount"));
    if (memberCount >= core.MAX_MEMBERS) throw new SoratomoDomainError("group_full");

    // ここから書き込み
    const now = FieldValue.serverTimestamp();
    tx.create(memberRef, { uid, role: "member", joinedAt: now });
    tx.update(groupRef, { memberCount: memberCount + 1 });
    tx.set(userRef, { groupCount: groupCount + 1, updatedAt: now }, { merge: true });
    tx.create(userRef.collection(USER_GROUPS).doc(groupId), { groupId, joinedAt: now });

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

module.exports = {
  SoratomoDomainError,
  createGroupTx,
  joinGroupTx,
  createSkyTx,
  reportSkyTx,
  regenerateInviteCodeTx,
  claimNotifySlot,
};
