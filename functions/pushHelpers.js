//
// そらもよう Cloud Functions — プッシュ通知送信の共通ヘルパー ☀️
//
// index.js（likes/comments/posts のリアクション通知）と skyMotion.js（空を動かすの完了/失敗通知）で
// **同一の送信・無効トークン掃除ロジックがコピーされていた**のを1箇所に集約したもの。
// 「FCM 無効トークンの判定・掃除」はアプリ全体で1つの規則であるべきで、2箇所化すると
// 片方だけ直す事故が起きる（PREF_DEFAULTS の「iOSとfunctionsで一致必須」と同種の教訓）。
//
// ⚠️ initializeApp() は index.js が先に1回実行する前提（Admin SDK はアプリ単位でシングルトン）。
//    このファイルを index.js の initializeApp() より前に require してはいけない。
//

"use strict";

const logger = require("firebase-functions/logger");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");

const db = getFirestore();
const messaging = getMessaging();

/**
 * FCM の「このトークンはもう無効」系エラーか。
 * これらを受けたら users/{uid}.fcmToken を削除してよい（次回起動時に再登録される）。
 * @param {string|undefined} code err.code
 * @returns {boolean}
 */
function isInvalidTokenError(code) {
  return (
    code === "messaging/registration-token-not-registered" ||
    code === "messaging/invalid-registration-token" ||
    code === "messaging/invalid-argument"
  );
}

/**
 * 取得済みトークンへ1通送る。無効トークンなら users/{uid}.fcmToken を掃除する。
 * 送信失敗は throw しない（通知は best-effort。呼び出し側の主処理に影響させない）。
 * @param {string} uid トークンの持ち主（無効トークン掃除のドキュメント特定に使う）
 * @param {string|null|undefined} token users/{uid}.fcmToken の値
 * @param {{title: string, body: string}} notification
 * @param {Object<string, string>} data
 */
async function sendToToken(uid, token, notification, data) {
  if (!token) return;
  try {
    await messaging.send({
      token,
      notification,
      data,
      apns: { payload: { aps: { sound: "default" } } },
    });
  } catch (err) {
    const code = err && err.code;
    if (isInvalidTokenError(code)) {
      await db
        .collection("users")
        .doc(uid)
        .update({ fcmToken: FieldValue.delete() })
        .catch((e) => logger.warn("fcmTokenクリーンアップ失敗", { uid, code: String(e && e.code) }));
    } else {
      logger.error("FCM送信に失敗しました", { uid, code: String(code) });
    }
  }
}

/**
 * uid の users ドキュメントを読んでから送る（トークン未取得の呼び出し側用）。
 * @param {string} uid
 * @param {{title: string, body: string}} notification
 * @param {Object<string, string>} data
 */
async function sendToUid(uid, notification, data) {
  const userSnap = await db.collection("users").doc(uid).get();
  const userData = userSnap.exists ? userSnap.data() : null;
  await sendToToken(uid, userData && userData.fcmToken, notification, data);
}

module.exports = { isInvalidTokenError, sendToToken, sendToUid };
