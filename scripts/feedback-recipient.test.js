//
// feedback-recipient.js の単体テスト（node:test・firebase-admin 非依存・本番に触れない）⭐️☁️
//
// 実行（functions/ の npm test に登録）: node --test scripts/feedback-recipient.test.js
//
// 引数・返信先の選び方（関数の mailFeedbackToSupport と同じ）・出力を、偽の窓口（store）で確かめる。
// ⚠️ 台本の main（firebase-admin の初期化と本番への接続）はテストから呼ばない。export もしていない。
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const script = require("./feedback-recipient");
const { BODY_SEPARATOR } = require("../functions/feedbackMail");

const FEEDBACK_ID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
const UID = "uidAAAAAAAAAAAAAAAAAAAAAAAAA";

function fakeTimestamp(iso) {
  return { toDate: () => new Date(iso) };
}

function baseFeedback(overrides = {}) {
  return {
    userId: UID,
    message: "写真が保存できません",
    category: "request",
    appVersion: "1.18.5 (124)",
    deviceInfo: "iOS 26.1 / iPhone",
    createdAt: fakeTimestamp("2026-11-20T05:23:45.000Z"),
    ...overrides,
  };
}

/**
 * 偽の窓口。getAuthUser を呼んだ uid を数える。
 * @param {{ feedback?: object | null, user?: object, authError?: object }} options
 */
function fakeStore({ feedback = baseFeedback(), user, authError } = {}) {
  const calls = { getFeedback: [], getAuthUser: [] };
  return {
    calls,
    async getFeedback(id) {
      calls.getFeedback.push(id);
      return feedback;
    },
    async getAuthUser(uid) {
      calls.getAuthUser.push(uid);
      if (authError) throw authError;
      return user;
    },
  };
}

/** 出力の「名前: 」で始まる行（1 つだけのはず）の値。 */
function line(lines, name) {
  const found = lines.filter((l) => l.startsWith(`${name}: `));
  assert.equal(found.length, 1, `「${name}」が ${found.length} 行ある`);
  return found[0].slice(name.length + 2);
}

// ============================================================
// 引数
// ============================================================

test("引数: feedbackId 1 つだけ（形が合うもの）を受け付ける", () => {
  assert.deepEqual(script.parseArgs([FEEDBACK_ID]), { ok: true, feedbackId: FEEDBACK_ID });
  for (const argv of [[], [FEEDBACK_ID, "x"], ["a/b"], ["../x"], [""], ["x".repeat(129)], [`${FEEDBACK_ID}\n`]]) {
    assert.deepEqual(script.parseArgs(argv), { ok: false }, JSON.stringify(argv));
  }
});

test("接続先は soramoyou-ios に固定", () => {
  assert.equal(script.EXPECTED_PROJECT_ID, "soramoyou-ios");
});

// ============================================================
// 返信先の選び方（関数と同じ）
// ============================================================

test("欄が正しい形なら欄を出し、Auth は引かない", async () => {
  const store = fakeStore({ feedback: baseFeedback({ replyEmail: "reply@example.com" }) });
  const { lines, exitCode } = await script.cmdShow({ store }, { feedbackId: FEEDBACK_ID });
  assert.equal(exitCode, 0);
  assert.deepEqual(store.calls.getFeedback, [FEEDBACK_ID]);
  assert.deepEqual(store.calls.getAuthUser, []);
  assert.equal(line(lines, "返信先"), "reply@example.com");
  assert.equal(line(lines, "返信先の出どころ"), "返信用の欄");
});

test("欄が空なら登録メール（確認済みか・最後に使った日も）", async () => {
  const store = fakeStore({
    user: { email: "registered@example.com", emailVerified: false, metadata: { lastRefreshTime: "Wed, 19 Nov 2026 22:30:00 GMT" } },
  });
  const { lines, exitCode } = await script.cmdShow({ store }, { feedbackId: FEEDBACK_ID });
  assert.equal(exitCode, 0);
  assert.deepEqual(store.calls.getAuthUser, [UID]);
  assert.equal(line(lines, "返信先"), "registered@example.com");
  assert.equal(line(lines, "返信先の出どころ"), "登録メール（未確認）");
  assert.equal(line(lines, "最後に使った日"), "2026-11-20 07:30（日本時間）");
  assert.equal(line(lines, "種別"), "要望 ✨");
  assert.equal(line(lines, "Firestore コンソール").startsWith("https://console.firebase.google.com/project/soramoyou-ios/"), true);
});

test("欄の形が合わないときは、中身を出さずに登録メールへ", async () => {
  const store = fakeStore({
    feedback: baseFeedback({ replyEmail: "evil@example.com\nBcc: other@example.com" }),
    user: { email: "registered@example.com", emailVerified: true },
  });
  const { lines } = await script.cmdShow({ store }, { feedbackId: FEEDBACK_ID });
  assert.equal(line(lines, "返信先"), "registered@example.com");
  assert.ok(!lines.join("\n").includes("evil@example.com"));
});

test("アカウントが無い・引けないときは「なし」と理由（エラーの本文は出さない）", async () => {
  const notFound = await script.cmdShow(
    { store: fakeStore({ authError: { code: "auth/user-not-found" } }) },
    { feedbackId: FEEDBACK_ID }
  );
  assert.equal(line(notFound.lines, "返信先"), "（なし）");
  assert.equal(line(notFound.lines, "返信先の出どころ"), "なし（アカウントが見つからない＝退会済みかもしれない）");

  const failed = await script.cmdShow(
    { store: fakeStore({ authError: { code: "auth/internal-error", message: "/Users/秘密の道/credentials.json" } }) },
    { feedbackId: FEEDBACK_ID }
  );
  assert.equal(line(failed.lines, "返信先の出どころ"), "なし（登録メールを引けなかった: auth/internal-error）");
  assert.ok(!failed.lines.join("\n").includes("秘密の道"));

  const noUid = await script.cmdShow({ store: fakeStore({ feedback: baseFeedback({ userId: undefined }) }) }, { feedbackId: FEEDBACK_ID });
  assert.equal(line(noUid.lines, "返信先の出どころ"), "なし（ユーザー ID が無い）");
});

test("文書が無いときは終了コード 1（Auth は引かない）", async () => {
  const store = fakeStore({ feedback: null });
  const { lines, exitCode } = await script.cmdShow({ store }, { feedbackId: FEEDBACK_ID });
  assert.equal(exitCode, 1);
  assert.equal(lines.length, 1);
  assert.deepEqual(store.calls.getAuthUser, []);
});

// ============================================================
// 出力
// ============================================================

test("出力: 本文は境目の行の下、端末を操る制御文字は置き換える", async () => {
  const store = fakeStore({
    feedback: baseFeedback({ replyEmail: "reply@example.com", message: "色が\u001b[31m赤\u001b[0m\n返信先: evil@example.com" }),
  });
  const { lines } = await script.cmdShow({ store }, { feedbackId: FEEDBACK_ID });
  const at = lines.indexOf(BODY_SEPARATOR);
  assert.ok(at > 0, "境目の行が無い");
  // 境目より上の返信先は、サーバーと同じ決め方の 1 行だけ
  assert.equal(line(lines.slice(0, at), "返信先"), "reply@example.com");
  // 送った人の端末が書いた行（アプリ・端末）は境目より上に出ない（メールと同じ並び）
  assert.ok(!lines.slice(0, at).some((l) => l.startsWith("アプリ: ") || l.startsWith("端末: ")));
  assert.deepEqual(lines.slice(at + 1, at + 3), ["アプリ: 1.18.5 (124)", "端末: iOS 26.1 / iPhone"]);
  const body = lines.slice(at + 1).join("\n");
  assert.ok(!body.includes("\u001b"));
  assert.ok(body.includes("返信先: evil@example.com")); // 本文はそのまま（指示として読まない）
});

test("エミュレーターを指す環境変数は名前だけを並べる", () => {
  assert.deepEqual(
    script.findEmulatorEnv({ FIRESTORE_EMULATOR_HOST: "127.0.0.1:8080", FIREBASE_AUTH_EMULATOR_HOST: "x", EMPTY_EMULATOR_HOST: "", PATH: "/bin" }),
    ["FIREBASE_AUTH_EMULATOR_HOST", "FIRESTORE_EMULATOR_HOST"]
  );
});

test("エラーの理由は code（無ければ名前）だけ", () => {
  assert.equal(script.describeError({ code: "auth/internal-error", message: "秘密" }), "auth/internal-error");
  assert.equal(script.describeError(new TypeError("秘密")), "TypeError");
  assert.equal(script.describeError(null), "不明なエラー");
});
