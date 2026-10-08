//
// そらもよう Cloud Functions — 「そらとも」の配線（Callable 3本と onSoratomoSkyCreated）⭐️☁️
//
// - soratomoCreateGroup・soratomoJoinGroup・soratomoRegenerateInviteCode（tasks 8.1）:
//   ログインと soratomoBeta のクレームを確かめ、soratomoStore.js のトランザクションを呼び、
//   ドメインのエラー（SoratomoDomainError）を理由つきの HttpsError（code と details.reason）に写す。
//   グループ名の検証と招待コードの正規化は、トランザクション（soratomoStore.js）の入口でも必ず通る。
// - onSoratomoSkyCreated（tasks 8.2）: グループの新しい投稿を、投稿者以外のメンバーへ知らせる。
//   既存の onPostCreated とは名前も対象（soratomoGroups/{groupId}/skies/{skyId}）も別。
//
// index.js の末尾の Object.assign(exports, require("./soratomo")) で公開する（tasks 8.3）。
// ここで公開するのは Cloud Functions の 4 本だけにする（ほかの値を exports に混ぜない）。
//
// ⚠️ ログと個人情報（要件15.2・15.3）: ログに出すのは uid・groupId・skyId・結果の理由・件数だけ。
//    グループ名・表示名・キャプション・招待コード・通知トークン・エラーの本文（文書のパスに招待コードが
//    含まれることがある）は出さない。
// ⚠️ テストは soratomo.test.js（Firestore のエミュレーター＋Auth・送信・ログの偽物）。
//

"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const { getFirestore } = require("firebase-admin/firestore");
const { getAuth } = require("firebase-admin/auth");
const core = require("./soratomoCore");
const store = require("./soratomoStore");
const { createNgWordProvider } = require("./soratomoNgWords");
const { sendToTokenGrouped } = require("./pushHelpers");

/** 既存の Functions と同じリージョン（index.js の setGlobalOptions と同じ値を明示する）。 */
const REGION = "asia-northeast1";

const db = getFirestore();

/** NGワードの語のリスト。関数のインスタンスごとに1つで、5分キャッシュする（release-gate 1.3・要件11.11）。 */
const ngWords = createNgWordProvider({ db });

// MARK: - Callable の共通部分

/**
 * ドメインのエラーの理由 → HttpsError の code（design.md の API Contract）。
 * ⚠️ release-gate 2.1 で足した理由（suspended・consent_required・ng_word）と details の写しは、まだ無い。
 *    それまでは toHttpsError が internal にする。tasks 4.1 で足す。
 */
const REASON_TO_CODE = Object.freeze({
  flag_off: "permission-denied",
  invalid_name: "invalid-argument",
  invalid_format: "invalid-argument",
  not_found: "not-found",
  group_full: "resource-exhausted",
  user_limit: "resource-exhausted",
  not_owner: "permission-denied",
});

/**
 * ログインと soratomoBeta のクレームを確かめ、呼び出し元の uid を返す（要件1.6）。
 * @param {import("firebase-functions/v2/https").CallableRequest} request
 * @returns {string}
 */
function requireSoratomoUser(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "ログインが必要です");
  }
  if (!request.auth.token || request.auth.token.soratomoBeta !== true) {
    throw new HttpsError("permission-denied", "flag_off", { reason: "flag_off" });
  }
  return request.auth.uid;
}

/**
 * 失敗を HttpsError に写す。理由を持つドメインのエラーは code と details.reason に、それ以外は internal にする。
 * @param {unknown} err
 * @returns {HttpsError}
 */
function toHttpsError(err) {
  if (err instanceof HttpsError) return err;
  if (err instanceof store.SoratomoDomainError && REASON_TO_CODE[err.reason]) {
    return new HttpsError(REASON_TO_CODE[err.reason], err.reason, { reason: err.reason });
  }
  return new HttpsError("internal", "internal");
}

/**
 * Callable の本体を包む: クレームの確認 → 本体 → 結果のログ。失敗は HttpsError に写して投げ直す。
 * @param {string} name ログに出す Callable の名前
 * @param {(uid: string, data: Object) => Promise<Object>} body
 */
function soratomoCallable(name, body) {
  return onCall({ region: REGION }, async (request) => {
    let uid = null;
    const data = request.data && typeof request.data === "object" ? request.data : {};
    try {
      uid = requireSoratomoUser(request);
      const result = await body(uid, data);
      logger.info(`${name}: ok`, { uid, groupId: result.groupId || data.groupId || null });
      return result;
    } catch (err) {
      const httpsError = toHttpsError(err);
      const reason = (httpsError.details && httpsError.details.reason) || httpsError.code;
      const fields = { uid, reason };
      if (httpsError.code === "internal") {
        // 想定外の失敗。本文は出さない（文書のパスに招待コードが含まれることがあるため）。名前と code だけ。
        logger.error(`${name}: internal`, { ...fields, errorName: err && err.name, errorCode: err && err.code });
      } else {
        logger.info(`${name}: rejected`, fields);
      }
      throw httpsError;
    }
  });
}

// MARK: - Callable 3本（8.1）

/**
 * グループを作る。{ name, requestId } → { groupId, name, inviteCode, memberCount }
 * 方針として、現行のガイドラインの版と語のリストの判定を渡す（release-gate 2.1）。語のリストが一度も読めていなければ
 * matcher() が失敗し、internal で止まる（検査を飛ばさない・要件11.5）。
 */
const soratomoCreateGroup = soratomoCallable("soratomoCreateGroup", async (uid, data) =>
  store.createGroupTx(db, {
    uid,
    name: data.name,
    requestId: data.requestId,
    policy: { guidelineVersion: core.GUIDELINE_VERSION, containsNgWord: await ngWords.matcher() },
  })
);

/**
 * 招待コードで参加する。{ code } → { groupId, alreadyMember }
 * 方針は現行のガイドラインの版だけ（参加は NGワードを検査しないので、語のリストが読めなくても止めない）。
 */
const soratomoJoinGroup = soratomoCallable("soratomoJoinGroup", (uid, data) =>
  store.joinGroupTx(db, { uid, code: data.code, policy: { guidelineVersion: core.GUIDELINE_VERSION } })
);

/** 招待コードを再発行する（オーナーだけ）。{ groupId } → { inviteCode } */
const soratomoRegenerateInviteCode = soratomoCallable("soratomoRegenerateInviteCode", (uid, data) =>
  store.regenerateInviteCodeTx(db, { uid, groupId: data.groupId })
);

// MARK: - 新着投稿の通知（8.2）

/**
 * 宛先の soratomoBeta のクレームを、getUsers でまとめて1回で確かめる（要件1.7）。
 * 失敗したら全員を「フラグOFF」とみなす（送らない側に倒す。集計の flagOff に出る）。
 * @param {string[]} uids 最大19人（メンバーの上限20人から投稿者を除く）
 * @returns {Promise<Set<string>>} クレームが true の uid
 */
async function fetchFlaggedUids(uids) {
  const flagged = new Set();
  if (uids.length === 0) return flagged;
  try {
    const { users } = await getAuth().getUsers(uids.map((uid) => ({ uid })));
    for (const user of users) {
      if (user.customClaims && user.customClaims.soratomoBeta === true) flagged.add(user.uid);
    }
  } catch (err) {
    logger.warn("onSoratomoSkyCreated: フラグの確認に失敗", { errorName: err && err.name, errorCode: err && err.code });
  }
  return flagged;
}

/**
 * Firestore の時刻をミリ秒で読む（Timestamp 以外は null）。
 * @param {unknown} value
 * @returns {number|null}
 */
function millisOf(value) {
  return value && typeof value.toMillis === "function" ? value.toMillis() : null;
}

/**
 * グループの最新の活動時刻を、投稿の作成日時との大きいほうにする（要件5.3・一覧の並び順）。
 * 同時の投稿で古い値に戻さないよう、トランザクションで読んで比べてから書く。
 */
async function bumpLastActivity(groupRef, createdAt) {
  const createdMs = millisOf(createdAt);
  if (createdMs === null) return;
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(groupRef);
    if (!snap.exists) return;
    const currentMs = millisOf(snap.get("lastActivityAt"));
    if (currentMs === null || currentMs < createdMs) tx.update(groupRef, { lastActivityAt: createdAt });
  });
}

/**
 * 新しいそらとも投稿を、投稿者以外のメンバーへ知らせる（要件9.1〜9.15）。
 * 分類の順は「フラグOFF→通知設定OFF→ブロック→トークン無し→（枠の確保で）重複か間引き→送信」。
 * 1人の失敗で残りを止めず、例外を投げずに終える（再試行で二重に送らないため）。投稿は消さない。
 * @param {{ params: { groupId: string, skyId: string }, data?: FirebaseFirestore.DocumentSnapshot }} event
 */
async function handleSoratomoSkyCreated(event) {
  const { groupId, skyId } = event.params;
  const sky = event.data ? event.data.data() : null;
  if (!sky) return;

  const groupRef = db.collection("soratomoGroups").doc(groupId);
  try {
    const posterId = typeof sky.authorId === "string" ? sky.authorId : "";
    const [groupSnap, membersSnap] = await Promise.all([groupRef.get(), groupRef.collection("members").get()]);
    if (!groupSnap.exists) {
      logger.warn("onSoratomoSkyCreated: グループが無い", { groupId, skyId });
      return;
    }

    const recipientIds = membersSnap.docs.map((doc) => doc.id).filter((uid) => uid !== posterId);
    const posterSnap = posterId ? await db.collection("users").doc(posterId).get() : null;
    const notification = core.buildNotification({
      groupName: groupSnap.get("name"),
      posterName: posterSnap && posterSnap.exists ? posterSnap.get("displayName") : null,
      caption: sky.caption,
    });
    const flagged = await fetchFlaggedUids(recipientIds);
    const userSnaps =
      recipientIds.length > 0 ? await db.getAll(...recipientIds.map((uid) => db.collection("users").doc(uid))) : [];

    // FCM の data の値はすべて文字列
    const data = { type: "soratomoPost", groupId, postId: skyId };
    const grouping = { threadId: `soratomo-${groupId}`, collapseId: `soratomo-${groupId}` };
    const nowMs = Date.now();

    const outcomes = await Promise.all(
      recipientIds.map(async (uid, i) => {
        try {
          const userData = userSnaps[i].exists ? userSnaps[i].data() : null;
          const kind = core.classifyRecipient({ hasFlag: flagged.has(uid), userData, posterId });
          if (kind !== "eligible") return kind;
          const slot = await store.claimNotifySlot(db, { groupId, uid, skyId, nowMs });
          if (slot !== "send") return slot;
          return await sendToTokenGrouped(uid, userData.fcmToken, notification, data, grouping);
        } catch (err) {
          logger.warn("onSoratomoSkyCreated: 宛先1人の処理に失敗", {
            groupId,
            skyId,
            uid,
            errorName: err && err.name,
            errorCode: err && err.code,
          });
          return "failed";
        }
      })
    );

    // 投稿1件ごとの集計（IDと件数だけ・要件9.11）
    logger.info("onSoratomoSkyCreated: summary", core.summarizeNotifyOutcomes(groupId, skyId, outcomes));
  } catch (err) {
    logger.error("onSoratomoSkyCreated: 失敗", { groupId, skyId, errorName: err && err.name, errorCode: err && err.code });
  } finally {
    // 通知の準備（投稿者・宛先の読み取りなど）のどこで失敗しても、一覧の並び順（要件5.3）のために必ず更新する。
    // 最新の活動時刻を書くのはこのトリガーだけなので、ここで飛ばすと次の投稿まで古いままになる（レビューで直した）。
    // グループが無いときは bumpLastActivity の中で何もしない。
    try {
      await bumpLastActivity(groupRef, sky.createdAt);
    } catch (err) {
      logger.warn("onSoratomoSkyCreated: 最新の活動時刻の更新に失敗", { groupId, skyId, errorName: err && err.name });
    }
  }
}

const onSoratomoSkyCreated = onDocumentCreated(
  { document: "soratomoGroups/{groupId}/skies/{skyId}", region: REGION },
  handleSoratomoSkyCreated
);

module.exports = {
  soratomoCreateGroup,
  soratomoJoinGroup,
  soratomoRegenerateInviteCode,
  onSoratomoSkyCreated,
};
