//
// そらもよう Cloud Functions — 通報（reports）→ Discord 通知の本文を組み立てる純粋関数 ⭐️☁️
//
// アプリの「通報」は reports コレクションに書き込まれる（FirestoreService.reportPost）。
// App Store ガイドライン 1.2（UGC）は「通報に 24 時間以内に対応する」ことを求めるため、
// 届いた通報を開発者の Discord へ即時に流す（index.js の notifyReportToDiscord）。
// 開発者が Discord を見ただけで「消すべきか」を判断できるよう、通報された投稿の
// キャプション・サムネイル・公開範囲・投稿者の表示名まで載せる。
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

/** 公開範囲 rawValue → 日本語表示名（posts.visibility）。 */
const VISIBILITY_LABELS = {
  public: "公開",
  followers: "フォロワー限定",
  private: "非公開",
};

/**
 * 投稿の取得結果。index.js が posts/{postId} を読んだ結果をこの 4 つのどれかで渡す。
 * - found:   投稿があった
 * - missing: 投稿が無かった（通報のあとに削除された可能性）
 * - noId:    通報に postId が入っていなかった（アプリは post.id が nil のとき "" を送る）
 * - error:   読み取りに失敗した
 */
const POST_LOOKUP = Object.freeze({
  found: "found",
  missing: "missing",
  noId: "noId",
  error: "error",
});

// Discord Embed の上限: description 4096 文字・field.value 1024 文字。どちらも空文字は不可。
const MAX_DESCRIPTION = 1000;
const MAX_FIELD = 1000;

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
 * 投稿の画像のうち、表示順（order）がいちばん小さい 1 枚のサムネイル URL を返す。
 * Discord は https の画像しか表示しないので、それ以外は null。
 * @param {unknown} images posts.images
 * @returns {string | null}
 */
function firstThumbnailUrl(images) {
  if (!Array.isArray(images) || images.length === 0) return null;
  const sorted = images
    .filter((img) => img && typeof img === "object")
    .slice()
    .sort((a, b) => (Number(a.order) || 0) - (Number(b.order) || 0));
  for (const img of sorted) {
    const url = nonEmptyString(img.thumbnail) || nonEmptyString(img.url);
    if (url && url.startsWith("https://")) return url;
  }
  return null;
}

/**
 * createdAt（Firestore Timestamp）を ISO 文字列にする。無い・壊れているときは now を使う。
 * @param {unknown} createdAt
 * @param {Date} now
 * @returns {string}
 */
function toIsoTimestamp(createdAt, now) {
  try {
    if (createdAt && typeof createdAt.toDate === "function") {
      return createdAt.toDate().toISOString();
    }
  } catch (_e) {
    // 下の now にフォールバックする
  }
  return now.toISOString();
}

/**
 * 通報 1 件ぶんの Discord Webhook ペイロードを組み立てる。
 * @param {object} args
 * @param {string} args.reportId reports のドキュメント ID
 * @param {object} args.report reports/{reportId} のデータ（postId / reporterId / reportedUserId / reason / createdAt）
 * @param {object | null} args.post posts/{postId} のデータ（postLookup が found のときだけ）
 * @param {string} args.postLookup POST_LOOKUP のどれか
 * @param {string | null} args.authorName 投稿者の表示名（publicProfiles/{uid}.displayName）。取れなければ null
 * @param {Date} args.now createdAt が無いときの時刻（テストで固定するため外から渡す）
 * @returns {object} Discord Webhook の JSON 本文
 */
function buildReportPayload({ reportId, report, post, postLookup, authorName, now }) {
  const data = report && typeof report === "object" ? report : {};

  // 理由: 既知なら日本語、未知の値はそのまま、無ければ「未指定」。
  const reasonRaw = nonEmptyString(data.reason);
  const reason = reasonRaw ? REPORT_REASON_LABELS[reasonRaw] || reasonRaw : "未指定";

  const postId = nonEmptyString(data.postId) || "(なし)";
  const reporterId = nonEmptyString(data.reporterId) || "不明";
  const reportedUserId = nonEmptyString(data.reportedUserId);

  // 投稿者: 投稿があれば投稿側の userId を正とする（通報データの reportedUserId は通報者の端末が送った値）。
  const found = postLookup === POST_LOOKUP.found && post && typeof post === "object";
  const authorId = (found && nonEmptyString(post.userId)) || reportedUserId || "不明";
  const name = nonEmptyString(authorName) || "（表示名なし）";
  let authorValue = `${name}\n${authorId}`;
  if (found && reportedUserId && nonEmptyString(post.userId) && reportedUserId !== post.userId) {
    // 通報データの投稿者 ID と、実際の投稿の持ち主が食い違う（改ざん・古い端末の可能性）。
    authorValue += `\n⚠️ 通報データ上の投稿者ID: ${reportedUserId}`;
  }

  // 本文（description）: 投稿のキャプション。投稿が取れなかったときは理由を書く。
  let description;
  if (found) {
    description = nonEmptyString(post.caption) || "（キャプションなし）";
  } else if (postLookup === POST_LOOKUP.missing) {
    description = "⚠️ 投稿が見つかりません（通報のあとに削除された可能性があります）";
  } else if (postLookup === POST_LOOKUP.noId) {
    description = "⚠️ 通報に投稿IDが入っていません";
  } else {
    description = "⚠️ 投稿の読み取りに失敗しました（Functions のログを確認してください）";
  }

  const visibilityRaw = found ? nonEmptyString(post.visibility) : null;
  const visibility = visibilityRaw ? VISIBILITY_LABELS[visibilityRaw] || visibilityRaw : "不明";

  const embed = {
    title: "🚨 投稿が通報されました",
    description: description.slice(0, MAX_DESCRIPTION),
    color: 0xd94a4a, // 通報はフィードバック（空色）と見分けがつくよう赤
    fields: [
      { name: "理由", value: reason.slice(0, MAX_FIELD), inline: true },
      { name: "公開範囲", value: visibility, inline: true },
      { name: "投稿者", value: authorValue.slice(0, MAX_FIELD), inline: false },
      { name: "投稿ID", value: postId.slice(0, MAX_FIELD), inline: false },
      { name: "通報した人", value: reporterId.slice(0, MAX_FIELD), inline: false },
    ],
    footer: { text: `reportId: ${reportId} ・ 24 時間以内に確認（ガイドライン 1.2）` },
    timestamp: toIsoTimestamp(data.createdAt, now),
  };

  const thumbnail = found ? firstThumbnailUrl(post.images) : null;
  if (thumbnail) {
    embed.image = { url: thumbnail };
  }

  return {
    username: "そらもよう 通報",
    embeds: [embed],
    // キャプションはユーザーが自由に書ける文字列。`@everyone` などが入っていても誰にも通知が飛ばないよう、
    // メンションの解釈をすべて止める（Embed 内のメンションは元々鳴らないが、念のための二重の守り）。
    allowed_mentions: { parse: [] },
  };
}

module.exports = {
  REPORT_REASON_LABELS,
  VISIBILITY_LABELS,
  POST_LOOKUP,
  buildReportPayload,
  firstThumbnailUrl,
};
