//
// reportDiscord.js の単体テスト（node:test = Node標準・新規npm依存なし）。
// firebase-admin/firebase-functions には一切触れない（純粋関数のみ検証）。
//
// 実行: node --test reportDiscord.test.js
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const {
  REPORT_REASON_LABELS,
  POST_LOOKUP,
  buildReportPayload,
  firstThumbnailUrl,
} = require("./reportDiscord");

const NOW = new Date("2026-10-01T00:00:00.000Z");

/** Firestore Timestamp の代わり（toDate だけ持つ）。 */
function fakeTimestamp(iso) {
  return { toDate: () => new Date(iso) };
}

function baseReport(overrides = {}) {
  return {
    postId: "POST1",
    reporterId: "REPORTER1",
    reportedUserId: "AUTHOR1",
    reason: "spam",
    createdAt: fakeTimestamp("2026-09-30T12:34:56.000Z"),
    ...overrides,
  };
}

function basePost(overrides = {}) {
  return {
    userId: "AUTHOR1",
    caption: "夕焼けがきれい",
    visibility: "public",
    images: [
      { url: "https://example.com/b.jpg", thumbnail: "https://example.com/b_t.jpg", order: 1 },
      { url: "https://example.com/a.jpg", thumbnail: "https://example.com/a_t.jpg", order: 0 },
    ],
    ...overrides,
  };
}

function build(args) {
  return buildReportPayload({
    reportId: "REPORT1",
    report: baseReport(),
    post: basePost(),
    postLookup: POST_LOOKUP.found,
    authorName: "そらこ",
    now: NOW,
    ...args,
  });
}

function field(payload, name) {
  const f = payload.embeds[0].fields.find((x) => x.name === name);
  assert.ok(f, `field ${name} がない`);
  return f.value;
}

/** Discord は空文字の field.value を拒否する。すべてのペイロードで確かめる。 */
function assertNoEmptyValues(payload) {
  const embed = payload.embeds[0];
  assert.ok(embed.description && embed.description.length > 0);
  for (const f of embed.fields) {
    assert.equal(typeof f.value, "string");
    assert.ok(f.value.length > 0, `field ${f.name} が空`);
    assert.ok(f.value.length <= 1024, `field ${f.name} が 1024 文字を超えた`);
  }
}

// ============================================================
// 理由の表示名
// ============================================================

test("REPORT_REASON_LABELS: iOS の ReportReason.displayName と文言が一致する", () => {
  // ⚠️ iOS 側の文言を変えたらここが落ちる＝ Functions 側も揃えるための見張り。
  const swiftPath = path.join(__dirname, "..", "Soramoyou", "Soramoyou", "Models", "ReportReason.swift");
  const swift = fs.readFileSync(swiftPath, "utf8");
  const fromSwift = {};
  for (const m of swift.matchAll(/case \.(\w+):\s*return "([^"]+)"/g)) {
    fromSwift[m[1]] = m[2];
  }
  assert.equal(Object.keys(fromSwift).length, 5, "Swift 側から 5 つ読めなかった（書き方が変わった？）");
  assert.deepEqual(REPORT_REASON_LABELS, fromSwift);
});

test("理由: 5 種類とも日本語の表示名になる", () => {
  for (const [raw, label] of Object.entries(REPORT_REASON_LABELS)) {
    const payload = build({ report: baseReport({ reason: raw }) });
    assert.equal(field(payload, "理由"), label);
  }
});

test("理由: 未知の値はそのまま、無ければ「未指定」", () => {
  assert.equal(field(build({ report: baseReport({ reason: "newReason" }) }), "理由"), "newReason");
  assert.equal(field(build({ report: baseReport({ reason: undefined }) }), "理由"), "未指定");
  assert.equal(field(build({ report: baseReport({ reason: "" }) }), "理由"), "未指定");
});

// ============================================================
// 投稿が見つかったとき
// ============================================================

test("投稿あり: キャプション・公開範囲・表示名・表示順が先頭の画像が載る", () => {
  const payload = build({});
  const embed = payload.embeds[0];
  assert.equal(payload.username, "そらもよう 通報");
  assert.equal(embed.title, "🚨 投稿が通報されました");
  assert.equal(embed.description, "夕焼けがきれい");
  assert.equal(field(payload, "公開範囲"), "公開");
  assert.equal(field(payload, "投稿者"), "そらこ\nAUTHOR1");
  assert.equal(field(payload, "投稿ID"), "POST1");
  assert.equal(field(payload, "通報した人"), "REPORTER1");
  assert.deepEqual(embed.image, { url: "https://example.com/a_t.jpg" });
  assert.equal(embed.footer.text, "reportId: REPORT1 ・ 24 時間以内に確認（ガイドライン 1.2）");
  assert.equal(embed.timestamp, "2026-09-30T12:34:56.000Z");
  assertNoEmptyValues(payload);
});

test("投稿あり: キャプション空・表示名なし・公開範囲なしでも空文字にならない", () => {
  const payload = build({ post: basePost({ caption: "  ", visibility: undefined }), authorName: null });
  assert.equal(payload.embeds[0].description, "（キャプションなし）");
  assert.equal(field(payload, "公開範囲"), "不明");
  assert.equal(field(payload, "投稿者"), "（表示名なし）\nAUTHOR1");
  assertNoEmptyValues(payload);
});

test("投稿あり: 通報データの投稿者 ID が実際の持ち主と違えば注記する", () => {
  const payload = build({ report: baseReport({ reportedUserId: "SOMEONE_ELSE" }) });
  assert.equal(field(payload, "投稿者"), "そらこ\nAUTHOR1\n⚠️ 通報データ上の投稿者ID: SOMEONE_ELSE");
});

test("キャプションに @everyone があっても、メンションは一切鳴らさない指定になっている", () => {
  const payload = build({ post: basePost({ caption: "@everyone みて <@123>" }) });
  assert.deepEqual(payload.allowed_mentions, { parse: [] });
  assert.equal(payload.content, undefined); // メンションが鳴る content 欄は使わない
});

test("投稿あり: 長いキャプションは丸める", () => {
  const payload = build({ post: basePost({ caption: "あ".repeat(5000) }) });
  assert.equal(payload.embeds[0].description.length, 1000);
});

// ============================================================
// 投稿が取れなかったとき
// ============================================================

test("投稿なし（削除済み）: 注意書きを出し、画像は載せず、投稿者は通報データの ID", () => {
  const payload = build({ post: null, postLookup: POST_LOOKUP.missing, authorName: null });
  const embed = payload.embeds[0];
  assert.match(embed.description, /投稿が見つかりません/);
  assert.equal(embed.image, undefined);
  assert.equal(field(payload, "公開範囲"), "不明");
  assert.equal(field(payload, "投稿者"), "（表示名なし）\nAUTHOR1");
  assertNoEmptyValues(payload);
});

test("postId が空（アプリが post.id ?? \"\" を送ったとき）: 注意書きと「(なし)」", () => {
  const payload = build({ report: baseReport({ postId: "" }), post: null, postLookup: POST_LOOKUP.noId });
  assert.match(payload.embeds[0].description, /投稿IDが入っていません/);
  assert.equal(field(payload, "投稿ID"), "(なし)");
  assertNoEmptyValues(payload);
});

test("投稿の読み取り失敗: ログを見るよう案内する", () => {
  const payload = build({ post: null, postLookup: POST_LOOKUP.error });
  assert.match(payload.embeds[0].description, /読み取りに失敗/);
  assertNoEmptyValues(payload);
});

test("postLookup が found でも post が null なら、投稿なしとして扱う（落ちない）", () => {
  const payload = build({ post: null, postLookup: POST_LOOKUP.found });
  assert.equal(payload.embeds[0].image, undefined);
  assertNoEmptyValues(payload);
});

// ============================================================
// 通報データ自体が欠けているとき
// ============================================================

test("createdAt が無い・壊れているときは now を使う", () => {
  assert.equal(build({ report: baseReport({ createdAt: undefined }) }).embeds[0].timestamp, NOW.toISOString());
  const broken = { toDate: () => { throw new Error("boom"); } };
  assert.equal(build({ report: baseReport({ createdAt: broken }) }).embeds[0].timestamp, NOW.toISOString());
});

test("通報データが空でも落ちず、すべて代わりの文字で埋まる", () => {
  const payload = build({ report: {}, post: null, postLookup: POST_LOOKUP.noId, authorName: null });
  assert.equal(field(payload, "理由"), "未指定");
  assert.equal(field(payload, "投稿者"), "（表示名なし）\n不明");
  assert.equal(field(payload, "通報した人"), "不明");
  assertNoEmptyValues(payload);
});

// ============================================================
// firstThumbnailUrl
// ============================================================

test("firstThumbnailUrl: thumbnail が無ければ url、https 以外は使わない", () => {
  assert.equal(firstThumbnailUrl(undefined), null);
  assert.equal(firstThumbnailUrl([]), null);
  assert.equal(firstThumbnailUrl([{ url: "https://x/a.jpg" }]), "https://x/a.jpg");
  assert.equal(firstThumbnailUrl([{ thumbnail: "http://x/t.jpg", url: "http://x/a.jpg" }]), null);
  assert.equal(
    firstThumbnailUrl([{ thumbnail: "gs://x", order: 0 }, { thumbnail: "https://x/2.jpg", order: 1 }]),
    "https://x/2.jpg"
  );
});
