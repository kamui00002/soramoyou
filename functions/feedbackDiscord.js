//
// そらもよう Cloud Functions — ご意見（feedback）→ Discord 通知の本文を組み立てる純粋関数 ⭐️☁️
//
// アプリ内「ご意見・ご要望」が feedback コレクションに作成されたら、index.js の notifyFeedbackToDiscord が
// 開発者の Discord へ即時に知らせる。その本文（Webhook の JSON）をここで組み立てる。
//
// 返信用のメールアドレス（replyEmail）は個人情報なので Discord に出さない。出すのは「あり／なし」だけ
// （2026-11-20 の決定。アドレスと返信先は mailFeedbackToSupport が開発者の Gmail へ送る＝feedbackMail.js）。
// Firebase コンソールの文書へのリンクを付け、手で確かめるときに URL 1 つで開けるようにする。
//
// ここには firebase-admin / firebase-functions に触れない純粋関数だけを置き、node:test で検証する。
//

"use strict";

const { FEEDBACK_CATEGORY_LABELS, replyFieldState, consoleLinkOf, oneLine } = require("./feedbackMail");

/** 「返信用アドレス」の欄の文（アドレスそのものは載せない）。 */
const REPLY_FIELD_LABELS = {
  valid: "あり",
  absent: "なし",
  invalid: "なし（欄の形が合わない）",
};

/**
 * Firestore の時刻（toDate を持つ）を ISO 文字列にする。無い・読めないときは now の時刻。
 * @param {unknown} createdAt
 * @param {() => Date} now
 * @returns {string}
 */
function timestampOf(createdAt, now) {
  try {
    if (createdAt && typeof createdAt.toDate === "function") return createdAt.toDate().toISOString();
  } catch (_e) {
    // 読めない時刻は now にする（落とさない）
  }
  return now().toISOString();
}

/**
 * ご意見 1 件ぶんの Discord Webhook ペイロードを組み立てる。
 * @param {object} args
 * @param {string} args.feedbackId 文書 ID
 * @param {object} args.feedback feedback/{feedbackId} のデータ
 * @param {string} args.projectId コンソールのリンクに使う Firebase のプロジェクト ID
 * @param {() => Date} [args.now] createdAt が無いときの時刻
 * @returns {object} Discord Webhook の JSON 本文
 */
function buildFeedbackDiscordPayload({ feedbackId, feedback, projectId, now = () => new Date() }) {
  const data = feedback && typeof feedback === "object" ? feedback : {};

  // 各フィールドを取り出す（任意項目は未設定なら代替表記）。message は rules で 1〜1000 文字保証済み。
  const message = (data.message || "(本文なし)").toString();
  // 種別・アプリ・端末は Rules が型も長さも見ていない（hasAll のまま）。メールと同じ oneLine で、
  // 文字列以外は捨て、1 行にして長さを切る（.toString() を直に呼ぶと値によっては落ちる・
  // Discord の field.value は 1024 文字まで）。
  const categoryRaw = oneLine(data.category);
  let category = "未指定";
  if (categoryRaw) {
    category = Object.prototype.hasOwnProperty.call(FEEDBACK_CATEGORY_LABELS, categoryRaw)
      ? FEEDBACK_CATEGORY_LABELS[categoryRaw]
      : categoryRaw;
  }
  const appVersion = oneLine(data.appVersion) || "不明";
  const deviceInfo = oneLine(data.deviceInfo) || "不明";
  const userId = data.userId ? data.userId.toString() : "不明";

  // Discord Embed を組み立てる。field.value は最大 1024 文字なので本文は 1000 文字に丸める。
  return {
    username: "そらもよう フィードバック",
    embeds: [
      {
        title: "📮 新しいご意見・ご要望が届きました",
        color: 0x4a90d9, // そらもようの空色
        fields: [
          { name: "種別", value: category, inline: true },
          { name: "アプリ", value: appVersion, inline: true },
          { name: "端末", value: deviceInfo, inline: true },
          { name: "本文", value: message.slice(0, 1000) },
          { name: "ユーザーID", value: userId, inline: false },
          // 返信用のアドレスは「あり／なし」だけ（アドレスは Discord に出さない）
          { name: "返信用アドレス", value: REPLY_FIELD_LABELS[replyFieldState(data.replyEmail)], inline: true },
          // 文書の ID は形を確かめてから URL に入れる（合わなければ feedback の一覧へ）
          { name: "Firebase コンソール", value: consoleLinkOf(feedbackId, projectId), inline: false },
        ],
        footer: { text: `feedbackId: ${feedbackId}` },
        timestamp: timestampOf(data.createdAt, now),
      },
    ],
  };
}

module.exports = {
  buildFeedbackDiscordPayload,
};
