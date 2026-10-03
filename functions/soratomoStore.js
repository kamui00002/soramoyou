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

/** 招待コードが既存と重なったときに作り直す最大の回数（要件3.2）。 */
const MAX_INVITE_CODE_ATTEMPTS = 5;
/** 作成の要求ID（アプリが作る UUID）の長さの上限。 */
const REQUEST_ID_MAX = 128;

/** ドメインのエラーの理由（design.md の SoratomoErrorDetails）。 */
const SORATOMO_ERROR_REASONS = Object.freeze([
  "flag_off",
  "invalid_name",
  "invalid_format",
  "not_found",
  "group_full",
  "user_limit",
  "not_owner",
]);

// MARK: - エラー

/** 理由つきの失敗。配線（soratomo.js）が HttpsError の code と details.reason に写す。 */
class SoratomoDomainError extends Error {
  /** @param {"flag_off"|"invalid_name"|"invalid_format"|"not_found"|"group_full"|"user_limit"|"not_owner"} reason */
  constructor(reason) {
    super(`soratomo: ${reason}`);
    this.name = "SoratomoDomainError";
    this.reason = reason;
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
 * - 同じ要求IDの再送では、前回作ったグループを返す（冪等。タイムアウトの後の再試行で2つ目を作らない）
 * - 所属がすでに10個なら user_limit
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, name: unknown, requestId: unknown }} params
 * @param {{ randomInt?: (max: number) => number }} [options] テストでだけ使う
 * @returns {Promise<{ groupId: string, name: string, inviteCode: string, memberCount: number }>}
 */
async function createGroupTx(db, { uid, name, requestId }, { randomInt } = {}) {
  assertUid(uid);
  const validated = core.validateGroupName(name);
  if (!validated.ok) throw new SoratomoDomainError("invalid_name");
  if (typeof requestId !== "string" || requestId.length === 0 || requestId.length > REQUEST_ID_MAX) {
    throw new TypeError("soratomo: requestId が不正");
  }

  return db.runTransaction(async (tx) => {
    const userRef = db.collection(USERS).doc(uid);
    const userSnap = await tx.get(userRef);
    const user = userSnap.exists ? userSnap.data() : {};

    // 冪等: 前回と同じ要求IDなら、前回のグループをこのトランザクションの中で読んで返す
    if (user.lastCreateRequestId === requestId && isDocumentId(user.lastCreatedGroupId)) {
      const previous = await tx.get(db.collection(GROUPS).doc(user.lastCreatedGroupId));
      if (previous.exists) {
        const g = previous.data();
        return { groupId: previous.id, name: g.name, inviteCode: g.inviteCode, memberCount: g.memberCount };
      }
    }

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
 * 判定の順: コードの不在 → 既存のメンバー → 所属10個 → 満員20人。
 * 既存のメンバーなら、上限とは無関係に alreadyMember: true の成功で返し、何も増やさない（要件4.8）。
 * メンバーの文書・メンバー数・所属の写し・所属数は、同じトランザクションでそろって増やす（要件11.8）。
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, code: unknown }} params
 * @returns {Promise<{ groupId: string, alreadyMember: boolean }>}
 */
async function joinGroupTx(db, { uid, code }) {
  assertUid(uid);
  const normalized = core.normalizeInviteCode(code);
  if (normalized === null) throw new SoratomoDomainError("invalid_format");

  return db.runTransaction(async (tx) => {
    const codeSnap = await tx.get(db.collection(INVITE_CODES).doc(normalized));
    const groupId = codeSnap.exists ? codeSnap.get("groupId") : null;
    if (!isDocumentId(groupId)) throw new SoratomoDomainError("not_found");

    const groupRef = db.collection(GROUPS).doc(groupId);
    const memberRef = groupRef.collection(MEMBERS).doc(uid);
    const userRef = db.collection(USERS).doc(uid);
    const [groupSnap, memberSnap, userSnap] = await tx.getAll(groupRef, memberRef, userRef);

    // コードの文書が残っていても、グループの今のコードでなければ無効（再発行の後の古いコード・要件3.10）
    if (!groupSnap.exists || groupSnap.get("inviteCode") !== normalized) throw new SoratomoDomainError("not_found");
    if (memberSnap.exists) return { groupId, alreadyMember: true };

    const groupCount = countOf(userSnap.exists ? userSnap.get("groupCount") : 0);
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
  SORATOMO_ERROR_REASONS,
  SoratomoDomainError,
  createGroupTx,
  joinGroupTx,
  regenerateInviteCodeTx,
  claimNotifySlot,
};
