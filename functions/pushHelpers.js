//
// そらもよう Cloud Functions — プッシュ通知送信の共通ヘルパー ☀️
//
// index.js（likes/comments/posts のリアクション通知）と skyMotion.js（空を動かすの完了/失敗通知）で
// **同一の送信・無効トークン掃除ロジックがコピーされていた**のを1箇所に集約したもの。
// soratomo.js（そらともの新着投稿の通知）は、まとめ指定つきの sendToTokenGrouped を使う ⭐️。
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

/**
 * そらとも用: APNs のまとめ指定（スレッドID・置き換えキー）つきで1通送り、結果を返す（要件9.5・9.7・9.8・9.12）。
 * sendToToken の兄弟。違いは ① thread-id と apns-collapse-id を付ける ② 結果を返す（投稿ごとの集計に使う）の 2 点。
 * - 音は既定の音。バッジは付けない（アプリのバッジ数を変えない）
 * - データの値はすべて文字列にする（FCM の data は文字列しか受け付けない）。null / undefined の項目は送らない
 * - 無効なトークンは sendToToken と同じ規則（isInvalidTokenError）・同じ update で消す。
 *   update は文書が無ければ失敗するだけで、文書を作り直さない
 * - 例外を投げない（1人の失敗で残りの受信者への送信を止めないため）
 * @param {string} uid トークンの持ち主（無効トークン掃除のドキュメント特定に使う）
 * @param {string|null|undefined} token users/{uid}.fcmToken の値
 * @param {{title: string, body: string}} notification
 * @param {Object<string, unknown>} data
 * @param {{threadId: string, collapseId: string}} grouping グループごとの値（soratomo-{groupId}）
 * @returns {Promise<"sent"|"no_token"|"invalid_token"|"failed">}
 */
async function sendToTokenGrouped(uid, token, notification, data, grouping) {
  if (!token) return "no_token";
  try {
    const stringData = {};
    for (const [key, value] of Object.entries(data || {})) {
      if (value !== null && value !== undefined) stringData[key] = String(value);
    }
    await messaging.send({
      token,
      notification,
      data: stringData,
      apns: {
        headers: { "apns-collapse-id": grouping.collapseId },
        payload: { aps: { sound: "default", threadId: grouping.threadId } },
      },
    });
    return "sent";
  } catch (err) {
    const code = err && err.code;
    if (isInvalidTokenError(code)) {
      // ⚠️ 無効トークンの掃除は sendToToken と同じ。変えるときは両方を直す
      //    （既存の sendToToken を触らない方針〈要件13.7〉のため、共通の関数には切り出していない）
      await db
        .collection("users")
        .doc(uid)
        .update({ fcmToken: FieldValue.delete() })
        .catch((e) => logger.warn("fcmTokenクリーンアップ失敗", { uid, code: String(e && e.code) }));
      return "invalid_token";
    }
    logger.error("FCM送信に失敗しました（まとめ指定つき）", { uid, code: String(code) });
    return "failed";
  }
}

module.exports = { isInvalidTokenError, sendToToken, sendToUid, sendToTokenGrouped };
