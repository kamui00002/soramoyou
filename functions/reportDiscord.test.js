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

const { REPORT_REASON_LABELS, buildReportPayload } = require("./reportDiscord");

const PROJECT_ID = "soramoyou-ios";

// 期待する URL は関数の中の組み立てを使わず、文字そのもので書く（組み立てが壊れたら落ちるように）。
const CONSOLE_POST_URL =
  "https://console.firebase.google.com/project/soramoyou-ios/firestore/databases/-default-/data/~2Fposts~2FPOST1";
const CONSOLE_REPORTS_URL =
  "https://console.firebase.google.com/project/soramoyou-ios/firestore/databases/-default-/data/~2Freports";

/** Firestore Timestamp の代わり（toDate だけ持つ）。 */
function fakeTimestamp(iso) {
  return { toDate: () => new Date(iso) };
}

/** 実際の reports の文書と同じ 5 つのキー（firestore.rules の hasAll と同じ）。 */
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

function build(args) {
  return buildReportPayload({
    report: baseReport(),
    projectId: PROJECT_ID,
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
  for (const f of embed.fields) {
    assert.equal(typeof f.value, "string");
    assert.ok(f.value.length > 0, `field ${f.name} が空`);
    assert.ok(f.value.length <= 1024, `field ${f.name} が 1024 文字を超えた`);
  }
}

/** ペイロードを Discord へ送る JSON の文字にして、指定の文字が 1 つも入っていないことを確かめる。 */
function assertNotSent(payload, needles) {
  const json = JSON.stringify(payload);
  for (const needle of needles) {
    assert.ok(!json.includes(needle), `送ってはいけない「${needle}」が本文に入っている`);
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

test("理由: 決まった 5 種類以外は生の文字を載せずに「不明」、無ければ「未指定」", () => {
  const odd = "自由に書いた理由";
  const payload = build({ report: baseReport({ reason: odd }) });
  assert.equal(field(payload, "理由"), "不明");
  assertNotSent(payload, [odd]);

  assert.equal(field(build({ report: baseReport({ reason: "newReason" }) }), "理由"), "不明");
  // Object の組み込みの名前（toString など）を理由の表示名と取り違えない。
  assert.equal(field(build({ report: baseReport({ reason: "toString" }) }), "理由"), "不明");
  assert.equal(field(build({ report: baseReport({ reason: undefined }) }), "理由"), "未指定");
  assert.equal(field(build({ report: baseReport({ reason: "" }) }), "理由"), "未指定");
  assert.equal(field(build({ report: baseReport({ reason: 123 }) }), "理由"), "未指定");
});

// ============================================================
// 送るもの
// ============================================================

test("送るもの: 通報があったこと・理由・投稿ID・Firebase コンソールへのリンクだけ", () => {
  const payload = build({});
  const embed = payload.embeds[0];
  assert.equal(payload.username, "そらもよう 通報");
  assert.equal(embed.title, "🚨 投稿が通報されました");
  assert.deepEqual(
    embed.fields.map((f) => f.name),
    ["理由", "投稿ID", "Firebase コンソール"]
  );
  assert.equal(field(payload, "理由"), "スパム・迷惑行為");
  assert.equal(field(payload, "投稿ID"), "POST1");
  assert.equal(field(payload, "Firebase コンソール"), CONSOLE_POST_URL);
  assert.equal(embed.footer.text, "24 時間以内に確認（ガイドライン 1.2）");
  // メンションが鳴る content 欄は使わず、メンションの解釈もすべて止める。
  assert.equal(payload.content, undefined);
  assert.deepEqual(payload.allowed_mentions, { parse: [] });
  assertNoEmptyValues(payload);
});

// ============================================================
// 送らないもの
// ============================================================

test("送らない: 本文・画像・時刻などの欄を作らない（キーは決めたものだけ）", () => {
  const payload = build({});
  assert.deepEqual(Object.keys(payload).sort(), ["allowed_mentions", "embeds", "username"]);
  assert.equal(payload.embeds.length, 1);
  // description（キャプション）・image / thumbnail（写真）・author・timestamp・url は作らない。
  assert.deepEqual(Object.keys(payload.embeds[0]).sort(), ["color", "fields", "footer", "title"]);
});

test("送らない: 通報データの通報した人・投稿した人の ID と時刻は載らない", () => {
  const payload = build({});
  assertNotSent(payload, ["REPORTER1", "AUTHOR1", "2026-09-30"]);
});

test("送らない: 呼び出し側が投稿・表示名・reportId を渡しても、通報データに余分な値があっても載らない", () => {
  // 古い呼び出し方（投稿と表示名を渡す形）で渡しても、関数はそれを受け取らないので Discord へ出ない。
  const payload = buildReportPayload({
    reportId: "REPORT1",
    report: baseReport({
      // 将来アプリが通報に余分な値を足しても、決めた 2 つ（理由・投稿ID）以外は使わない。
      caption: "通報データのキャプション",
      displayName: "通報データの表示名",
      thumbnail: "https://example.com/report_t.jpg",
    }),
    post: {
      userId: "AUTHOR1",
      caption: "夕焼けがきれい",
      visibility: "followers",
      images: [{ url: "https://example.com/a.jpg", thumbnail: "https://example.com/a_t.jpg", order: 0 }],
    },
    postLookup: "found",
    authorName: "そらこ",
    now: new Date("2026-10-01T00:00:00.000Z"),
    projectId: PROJECT_ID,
  });
  assertNotSent(payload, [
    "夕焼けがきれい", // 投稿のキャプション
    "そらこ", // 投稿者の表示名
    "example.com", // 写真・サムネイルの URL
    "フォロワー限定", // 公開範囲
    "REPORT1", // reportId
    "通報データのキャプション",
    "通報データの表示名",
  ]);
  assertNoEmptyValues(payload);
});

// ============================================================
// 投稿 ID が使えないとき
// ============================================================

test("投稿 ID が空（アプリが post.id ?? \"\" を送ったとき）: 「(なし)」と reports の一覧へのリンク", () => {
  for (const postId of ["", "   ", undefined, null]) {
    const payload = build({ report: baseReport({ postId }) });
    assert.equal(field(payload, "投稿ID"), "(なし)");
    assert.equal(field(payload, "Firebase コンソール"), `通報の一覧（投稿 ID が使えないため）\n${CONSOLE_REPORTS_URL}`);
    assertNoEmptyValues(payload);
  }
});

test("投稿 ID の形が合わない: 中身を載せずに「(形が正しくありません)」と reports の一覧へのリンク", () => {
  const odd = ["ID(1)", "a/b", "a~b", "a b", "あいう", "x".repeat(129)];
  for (const postId of odd) {
    const payload = build({ report: baseReport({ postId }) });
    assert.equal(field(payload, "投稿ID"), "(形が正しくありません)", postId);
    assert.equal(field(payload, "Firebase コンソール"), `通報の一覧（投稿 ID が使えないため）\n${CONSOLE_REPORTS_URL}`);
    assertNotSent(payload, [postId]);
    assertNoEmptyValues(payload);
  }
  // 文字列でない値は「無い」と同じ扱い。
  assert.equal(field(build({ report: baseReport({ postId: 123 }) }), "投稿ID"), "(なし)");
});

test("投稿 ID の前後の空白は取り除いて使う", () => {
  const payload = build({ report: baseReport({ postId: "  POST1  " }) });
  assert.equal(field(payload, "投稿ID"), "POST1");
  assert.equal(field(payload, "Firebase コンソール"), CONSOLE_POST_URL);
});

// ============================================================
// 欠けているとき
// ============================================================

test("プロジェクト ID が無い・形が合わない: リンクを作らず、欄は空にしない", () => {
  for (const projectId of [undefined, "", "Soramoyou/ios"]) {
    const payload = build({ projectId });
    assert.equal(field(payload, "Firebase コンソール"), "（プロジェクト ID が無いため、リンクを作れませんでした）");
    assert.equal(field(payload, "投稿ID"), "POST1");
    assertNoEmptyValues(payload);
  }
});

test("通報データが空・null でも落ちず、すべて代わりの文字で埋まる", () => {
  for (const report of [{}, null, undefined]) {
    const payload = build({ report });
    assert.equal(field(payload, "理由"), "未指定");
    assert.equal(field(payload, "投稿ID"), "(なし)");
    assertNoEmptyValues(payload);
  }
});
