//
// そらもよう Cloud Functions — 通報（reports）→ Discord 通知の本文を組み立てる純粋関数 ⭐️☁️
//
// アプリの「通報」は reports コレクションに書き込まれる（FirestoreService.reportPost）。
// App Store ガイドライン 1.2（UGC）は「通報に 24 時間以内に対応する」ことを求めるため、
// 届いた通報を開発者の Discord へ即時に流す（index.js の notifyReportToDiscord）。
// Discord は外部のサービスなので、送るのは「通報があったこと・理由・投稿の ID・Firebase コンソールへのリンク」だけにする。
// 投稿のキャプション・写真（サムネイル）・公開範囲・投稿者の表示名・通報した人や投稿した人の ID・時刻は送らない。
// 投稿の中身は、リンクから Firebase コンソール（開発者のログインが要る）を開いて確かめる。
//
// 理由は決まった 5 種類だけを表示名にして、それ以外は「不明」にする。
// 投稿 ID は形を確かめてから載せ、形が合わないときは載せずに、リンクを reports の一覧へ向ける。
//
// ここには firebase-admin / firebase-functions に触れない純粋関数だけを置き、node:test で検証する。
//

"use strict";

/**
 * 通報理由 rawValue → 日本語表示名。
 * ⚠️ iOS の ReportReason.displayName（Models/ReportReason.swift）と文言を一致させること。
 */
const REPORT_REASON_LABELS = {
  inappropriate: "不適切なコンテンツ",
  spam: "スパム・迷惑行為",
  harassment: "嫌がらせ・誹謗中傷",
  copyright: "著作権侵害",
  other: "その他",
};

/** 理由が入っていないときの表示。 */
const MISSING_REASON_LABEL = "未指定";

/** 理由が決まった 5 種類のどれでもないときの表示（そらともの通報の UNKNOWN_LABEL と同じ文字）。 */
const UNKNOWN_REASON_LABEL = "不明";

/**
 * Discord に載せてよい投稿 ID の形。アプリの投稿 ID は Firestore の自動 ID（英数字 20 文字）なので、
 * 英数字・ハイフン・アンダースコアの 128 文字までに限る。これに合わない ID は載せない（コンソールの URL にも同じ ID を使う）。
 */
const POST_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

/** Firebase のプロジェクト ID の形（英小文字・数字・ハイフン）。URL に入れる前に確かめる。 */
const PROJECT_ID_PATTERN = /^[a-z0-9-]{1,64}$/;

/**
 * 値を「空でない文字列」に正規化する。文字列以外・空白だけの文字列は null。
 * @param {unknown} value
 * @returns {string | null}
 */
function nonEmptyString(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

/**
 * Firebase コンソールの Firestore の画面の URL を作る。
 * コンソールは URL の中の「/」を「~2F」と書く（例: posts/abc → ~2Fposts~2Fabc）。
 * @param {string} projectId 形を確かめ済みのプロジェクト ID
 * @param {string[]} segments ["posts", "<投稿ID>"] や ["reports"]。どれも形を確かめ済みの文字列
 * @returns {string}
 */
function firestoreConsoleUrl(projectId, segments) {
  const dataPath = segments.map((s) => `~2F${s}`).join("");
  return `https://console.firebase.google.com/project/${projectId}/firestore/databases/-default-/data/${dataPath}`;
}

/**
 * 通報 1 件ぶんの Discord Webhook ペイロードを組み立てる。
 * 引数に投稿や投稿者の情報を受け取らない（＝渡しようがない）ことで、それらが Discord へ出ないことを保証する。
 * @param {object} args
 * @param {object} args.report reports/{reportId} のデータ。使うのは postId と reason だけ
 * @param {string} args.projectId コンソールのリンクに使う Firebase のプロジェクト ID
 * @returns {object} Discord Webhook の JSON 本文
 */
function buildReportPayload({ report, projectId }) {
  const data = report && typeof report === "object" ? report : {};

  // 理由: 決まった 5 種類なら日本語、それ以外は「不明」、無ければ「未指定」。
  const reasonRaw = nonEmptyString(data.reason);
  let reason;
  if (!reasonRaw) {
    reason = MISSING_REASON_LABEL;
  } else if (Object.prototype.hasOwnProperty.call(REPORT_REASON_LABELS, reasonRaw)) {
    reason = REPORT_REASON_LABELS[reasonRaw];
  } else {
    reason = UNKNOWN_REASON_LABEL;
  }

  // 投稿 ID: 形が合うものだけを載せる。合わないものは中身を載せずに、合わなかったことだけを書く。
  const postIdRaw = nonEmptyString(data.postId);
  const postId = postIdRaw && POST_ID_PATTERN.test(postIdRaw) ? postIdRaw : null;
  let postIdValue;
  if (postId) {
    postIdValue = postId;
  } else if (postIdRaw) {
    postIdValue = "(形が正しくありません)";
  } else {
    postIdValue = "(なし)";
  }

  // コンソールのリンク: 投稿 ID があれば投稿の文書、無ければ reports の一覧（新しい通報を探す）。
  const project = nonEmptyString(projectId);
  let consoleValue;
  if (!project || !PROJECT_ID_PATTERN.test(project)) {
    consoleValue = "（プロジェクト ID が無いため、リンクを作れませんでした）";
  } else if (postId) {
    consoleValue = firestoreConsoleUrl(project, ["posts", postId]);
  } else {
    consoleValue = `通報の一覧（投稿 ID が使えないため）\n${firestoreConsoleUrl(project, ["reports"])}`;
  }

  const embed = {
    title: "🚨 投稿が通報されました",
    color: 0xd94a4a, // 通報はフィードバック（空色）と見分けがつくよう赤
    fields: [
      { name: "理由", value: reason, inline: true },
      { name: "投稿ID", value: postIdValue, inline: true },
      { name: "Firebase コンソール", value: consoleValue, inline: false },
    ],
    footer: { text: "24 時間以内に確認（ガイドライン 1.2）" },
  };

  return {
    username: "そらもよう 通報",
    embeds: [embed],
    // メンションの解釈をすべて止める。
    allowed_mentions: { parse: [] },
  };
}

module.exports = {
  REPORT_REASON_LABELS,
  buildReportPayload,
};
