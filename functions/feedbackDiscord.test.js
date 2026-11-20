//
// feedbackDiscord.js の単体テスト（node:test = Node 標準・新規 npm 依存なし）。
// firebase-admin / firebase-functions には一切触れない（純粋関数のみ検証）。
//
// 実行: node --test feedbackDiscord.test.js
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const { buildFeedbackDiscordPayload } = require("./feedbackDiscord");
const { FEEDBACK_CATEGORY_LABELS } = require("./feedbackMail");

const PROJECT_ID = "soramoyou-ios";
const FEEDBACK_ID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";

// 期待する URL は関数の中の組み立てを使わず、文字そのもので書く（組み立てが壊れたら落ちるように）。
const CONSOLE_FEEDBACK_URL =
  "https://console.firebase.google.com/project/soramoyou-ios/firestore/databases/-default-/data/~2Ffeedback~2FAAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
const CONSOLE_FEEDBACK_LIST_URL =
  "https://console.firebase.google.com/project/soramoyou-ios/firestore/databases/-default-/data/~2Ffeedback";

/** Firestore Timestamp の代わり（toDate だけ持つ）。 */
function fakeTimestamp(iso) {
  return { toDate: () => new Date(iso) };
}

function baseFeedback(overrides = {}) {
  return {
    userId: "UID1",
    message: "写真が保存できません",
    category: "bug",
    appVersion: "1.18.5 (124)",
    deviceInfo: "iOS 26.1 / iPhone",
    createdAt: fakeTimestamp("2026-11-20T05:23:45.000Z"),
    ...overrides,
  };
}

function build(args = {}) {
  return buildFeedbackDiscordPayload({
    feedbackId: FEEDBACK_ID,
    feedback: baseFeedback(),
    projectId: PROJECT_ID,
    now: () => new Date("2026-12-31T00:00:00.000Z"),
    ...args,
  });
}

function field(payload, name) {
  const f = payload.embeds[0].fields.find((x) => x.name === name);
  assert.ok(f, `field ${name} がない`);
  return f.value;
}

/** Discord は空文字の field.value を拒否する。 */
function assertNoEmptyValues(payload) {
  for (const f of payload.embeds[0].fields) {
    assert.equal(typeof f.value, "string", f.name);
    assert.ok(f.value.length > 0, `field ${f.name} が空`);
    assert.ok(f.value.length <= 1024, `field ${f.name} が 1024 文字を超えた`);
  }
}

// ============================================================
// 今までと同じ部分
// ============================================================

test("種別の表: iOS の FeedbackCategory と同じ 3 種類", () => {
  // ⚠️ iOS 側に種別を足したらここが落ちる＝ Functions 側も揃えるための見張り。
  const swiftPath = path.join(__dirname, "..", "Soramoyou", "Soramoyou", "Models", "Feedback.swift");
  const swift = fs.readFileSync(swiftPath, "utf8");
  const enumBody = swift.slice(swift.indexOf("enum FeedbackCategory"), swift.indexOf("var id: String"));
  const cases = [...enumBody.matchAll(/case (\w+)/g)].map((m) => m[1]).sort();
  assert.deepEqual(cases, Object.keys(FEEDBACK_CATEGORY_LABELS).sort());
});

test("今までの欄: 種別・アプリ・端末・本文・ユーザーID・feedbackId・時刻は前と同じ形", () => {
  const payload = build();
  const embed = payload.embeds[0];
  assert.equal(payload.username, "そらもよう フィードバック");
  assert.equal(embed.title, "📮 新しいご意見・ご要望が届きました");
  assert.equal(embed.color, 0x4a90d9);
  assert.deepEqual(embed.fields.slice(0, 5), [
    { name: "種別", value: "不具合 🐛", inline: true },
    { name: "アプリ", value: "1.18.5 (124)", inline: true },
    { name: "端末", value: "iOS 26.1 / iPhone", inline: true },
    { name: "本文", value: "写真が保存できません" },
    { name: "ユーザーID", value: "UID1", inline: false },
  ]);
  assert.deepEqual(embed.footer, { text: `feedbackId: ${FEEDBACK_ID}` });
  assert.equal(embed.timestamp, "2026-11-20T05:23:45.000Z");
  assertNoEmptyValues(payload);
});

test("今までの欄: 本文は 1000 文字で切り、無いものは代わりの文字", () => {
  assert.equal(field(build({ feedback: baseFeedback({ message: "あ".repeat(1200) }) }), "本文"), "あ".repeat(1000));
  const empty = build({ feedback: { createdAt: fakeTimestamp("2026-11-20T00:00:00.000Z") } });
  assert.equal(field(empty, "種別"), "未指定");
  assert.equal(field(empty, "アプリ"), "不明");
  assert.equal(field(empty, "端末"), "不明");
  assert.equal(field(empty, "本文"), "(本文なし)");
  assert.equal(field(empty, "ユーザーID"), "不明");
  assertNoEmptyValues(empty);
});

test("今までの欄: 表に無い種別は生の文字のまま（Object の組み込みの名前と取り違えない）", () => {
  assert.equal(field(build({ feedback: baseFeedback({ category: "newKind" }) }), "種別"), "newKind");
  assert.equal(field(build({ feedback: baseFeedback({ category: "toString" }) }), "種別"), "toString");
});

// ============================================================
// 受け側の守り（種別・アプリ・端末は Rules が型も長さも見ていない）
// ============================================================

test("受け側の守り: 種別・アプリ・端末が文字列でないときは、落ちずに「未指定／不明」", () => {
  // 手で組んだ書き込みでも、その人の通知を落とさない（メール側の oneLine と同じ扱い）。
  for (const bad of [{ toString: "x" }, { a: 1 }, ["a"], 123, true]) {
    const payload = build({ feedback: baseFeedback({ category: bad, appVersion: bad, deviceInfo: bad }) });
    assert.equal(field(payload, "種別"), "未指定", JSON.stringify(bad));
    assert.equal(field(payload, "アプリ"), "不明", JSON.stringify(bad));
    assert.equal(field(payload, "端末"), "不明", JSON.stringify(bad));
    assertNoEmptyValues(payload);
  }
});

test("受け側の守り: 長い値は 100 文字で切り、改行は空白にする（Discord の 1024 文字を超えない）", () => {
  const long = "あ".repeat(2000);
  const payload = build({ feedback: baseFeedback({ category: long, appVersion: long, deviceInfo: long }) });
  assert.equal(field(payload, "種別"), `${"あ".repeat(100)}…`);
  assert.equal(field(payload, "アプリ"), `${"あ".repeat(100)}…`);
  assert.equal(field(payload, "端末"), `${"あ".repeat(100)}…`);
  assertNoEmptyValues(payload);
  assert.equal(field(build({ feedback: baseFeedback({ deviceInfo: "iOS 26.1\n/ iPhone" }) }), "端末"), "iOS 26.1 / iPhone");
});

test("今までの欄: createdAt が無い・読めないときは now の時刻", () => {
  assert.equal(build({ feedback: baseFeedback({ createdAt: undefined }) }).embeds[0].timestamp, "2026-12-31T00:00:00.000Z");
  const broken = { toDate: () => { throw new Error("x"); } };
  assert.equal(build({ feedback: baseFeedback({ createdAt: broken }) }).embeds[0].timestamp, "2026-12-31T00:00:00.000Z");
});

// ============================================================
// 足した欄（返信用アドレス・Firebase コンソール）
// ============================================================

test("足した欄: 返信用アドレスは「あり／なし」だけ、Firebase コンソールは文書の URL", () => {
  const payload = build({ feedback: baseFeedback({ replyEmail: "reply@example.com" }) });
  assert.deepEqual(
    payload.embeds[0].fields.map((f) => f.name),
    ["種別", "アプリ", "端末", "本文", "ユーザーID", "返信用アドレス", "Firebase コンソール"]
  );
  assert.equal(field(payload, "返信用アドレス"), "あり");
  assert.equal(field(payload, "Firebase コンソール"), CONSOLE_FEEDBACK_URL);
  assertNoEmptyValues(payload);
});

test("足した欄: 返信用のアドレスそのものは Discord に出ない", () => {
  for (const replyEmail of ["reply@example.com", "evil@example.com\nBcc: other@example.com"]) {
    const json = JSON.stringify(build({ feedback: baseFeedback({ replyEmail }) }));
    assert.ok(!json.includes("example.com"), replyEmail);
  }
});

test("足した欄: 欄が無い・null は「なし」、形が合わないものは「なし（欄の形が合わない）」", () => {
  assert.equal(field(build({ feedback: baseFeedback() }), "返信用アドレス"), "なし");
  assert.equal(field(build({ feedback: baseFeedback({ replyEmail: null }) }), "返信用アドレス"), "なし");
  for (const replyEmail of ["", "sora", "a b@c.d", 123]) {
    assert.equal(field(build({ feedback: baseFeedback({ replyEmail }) }), "返信用アドレス"), "なし（欄の形が合わない）");
  }
});

test("足した欄: ID の形が合わないときは、URL に入れずに feedback の一覧へ", () => {
  for (const feedbackId of ["a/b", "a~b", "ID(1)", "x".repeat(129)]) {
    const payload = build({ feedbackId });
    assert.equal(field(payload, "Firebase コンソール"), `${CONSOLE_FEEDBACK_LIST_URL} （ID の形が合わないので一覧）`, feedbackId);
    assertNoEmptyValues(payload);
  }
});

test("足した欄: プロジェクト ID が無いときはリンクを作らず、欄は空にしない", () => {
  for (const projectId of [undefined, "", "Soramoyou/ios"]) {
    assert.equal(field(build({ projectId }), "Firebase コンソール"), "（プロジェクト ID が無いため、リンクを作れませんでした）");
  }
});
