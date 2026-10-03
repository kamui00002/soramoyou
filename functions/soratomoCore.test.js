//
// soratomoCore.js の単体テスト（node:test = Node標準・新規npm依存なし）⭐️
// firebase-admin/firebase-functions には一切触れない（純粋関数のみ検証）。
//
// 実行: node --test soratomoCore.test.js
//
// ⚠️ package.json の lint / test への登録は tasks 8.3 でまとめて行う（それまでは単体で実行する）。
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");

const core = require("./soratomoCore");

// ============================================================
// 定数
// ============================================================

test("定数: 設計書（design.md soratomoCore）の値と一致する", () => {
  assert.equal(core.INVITE_ALPHABET, "ABCDEFGHJKLMNPQRSTUVWXYZ23456789");
  assert.equal(core.INVITE_CODE_LENGTH, 8);
  assert.equal(core.MAX_MEMBERS, 20);
  assert.equal(core.MAX_GROUPS_PER_USER, 10);
  assert.equal(core.GROUP_NAME_MAX, 30);
  assert.equal(core.CAPTION_HEAD, 30);
  assert.equal(core.THROTTLE_MS, 5 * 60 * 1000);
  assert.equal(core.SORATOMO_PREF_KEY, "notifySoratomo");
  assert.equal(core.FALLBACK_NAME, "だれか");
});

test("SORATOMO_PREF_DEFAULT は true（iOS の User.notifySoratomoDefault と一致させる規則）", () => {
  // ⚠️ ここを変えるなら iOS 側の既定値も同時に変えること（片方だけだと、
  //    アプリの設定画面の表示と、実際に届くかどうかが食い違う）。
  assert.equal(core.SORATOMO_PREF_DEFAULT, true);
});

// ============================================================
// generateInviteCode
// ============================================================

test("generateInviteCode: 字種は32文字で、0・O・1・I を含まない", () => {
  assert.equal(core.INVITE_ALPHABET.length, 32);
  assert.equal(new Set(core.INVITE_ALPHABET).size, 32, "字種に重複がある");
  for (const ch of ["0", "O", "1", "I"]) {
    assert.ok(!core.INVITE_ALPHABET.includes(ch), `字種に ${ch} が入っている`);
  }
});

test("generateInviteCode: 渡した乱数の値で、字種から8文字を選ぶ", () => {
  // 決定論的な乱数（0,1,2,…,31,0,…）で、どの位置の文字を選ぶかを固定する。
  let i = 0;
  const calls = [];
  const fakeRandomInt = (max) => {
    calls.push(max);
    return i++ % max;
  };
  assert.equal(core.generateInviteCode(fakeRandomInt), "ABCDEFGH");
  assert.deepEqual(calls, [32, 32, 32, 32, 32, 32, 32, 32], "1文字ごとに字種の数で乱数を引く");

  const last = () => 31;
  assert.equal(core.generateInviteCode(last), "99999999");
});

test("generateInviteCode: 引数を省くと crypto.randomInt を使い、字種の範囲の8文字になる", (t) => {
  const spy = t.mock.method(crypto, "randomInt");
  for (let n = 0; n < 200; n++) {
    const code = core.generateInviteCode();
    assert.match(code, /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$/);
  }
  assert.equal(spy.mock.callCount(), 200 * 8, "既定の乱数が暗号論的に安全な crypto.randomInt でない");
});

// ============================================================
// normalizeInviteCode
// ============================================================

test("normalizeInviteCode: 小文字・ハイフン・空白を無視して照合できる形にする", () => {
  assert.equal(core.normalizeInviteCode("ABCD-EFGH"), "ABCDEFGH");
  assert.equal(core.normalizeInviteCode("abcd-efgh"), "ABCDEFGH");
  assert.equal(core.normalizeInviteCode(" abcd efgh "), "ABCDEFGH");
  assert.equal(core.normalizeInviteCode("AB-CD EF-GH"), "ABCDEFGH");
});

test("normalizeInviteCode: 全角の英数字・ハイフン・空白を半角と同じに扱う", () => {
  assert.equal(core.normalizeInviteCode("ＡＢＣＤ－ＥＦＧＨ"), "ABCDEFGH");
  assert.equal(core.normalizeInviteCode("ａｂｃｄ\u3000２３４５"), "ABCD2345");
});

test("normalizeInviteCode: 日本語入力で出やすいハイフン類（ー・‐・–・—・−）も区切りとして除く", () => {
  // 日本語入力のまま「-」を打つと長音符「ー」になる。字種に無い文字なので除いても誤一致しない。
  for (const sep of ["\u30FC", "\uFF70", "\u2010", "\u2011", "\u2012", "\u2013", "\u2014", "\u2015", "\u2212", "\uFE63", "\uFF0D"]) {
    assert.equal(core.normalizeInviteCode(`ABCD${sep}EFGH`), "ABCDEFGH", `区切り ${sep} を除けない`);
  }
});

test("normalizeInviteCode: 7文字・9文字は無効", () => {
  assert.equal(core.normalizeInviteCode("ABCD-EFG"), null);
  assert.equal(core.normalizeInviteCode("ABCD-EFGHJ"), null);
  assert.equal(core.normalizeInviteCode(""), null);
});

test("normalizeInviteCode: 字種に無い文字（0・O・1・I・記号）は補正せず無効", () => {
  assert.equal(core.normalizeInviteCode("ABCD-EFG0"), null);
  assert.equal(core.normalizeInviteCode("ABCD-EFGO"), null);
  assert.equal(core.normalizeInviteCode("ABCD-EFG1"), null);
  assert.equal(core.normalizeInviteCode("ABCD-EFGI"), null);
  assert.equal(core.normalizeInviteCode("ABCD_EFGH"), null);
  assert.equal(core.normalizeInviteCode("ABCDあEFG"), null);
});

test("normalizeInviteCode: 文字列以外は無効", () => {
  for (const bad of [undefined, null, 12345678, {}, ["ABCDEFGH"]]) {
    assert.equal(core.normalizeInviteCode(bad), null);
  }
});

test("normalizeInviteCode: 生成したコードはそのまま有効", () => {
  for (let n = 0; n < 50; n++) {
    const code = core.generateInviteCode();
    assert.equal(core.normalizeInviteCode(code), code);
  }
});

// ============================================================
// validateGroupName
// ============================================================

test("validateGroupName: 前後の空白を除いて1〜30文字なら受け付け、除いた名前を返す", () => {
  assert.deepEqual(core.validateGroupName("  空の会  "), { ok: true, name: "空の会" });
  assert.deepEqual(core.validateGroupName("あ"), { ok: true, name: "あ" });
  assert.deepEqual(core.validateGroupName("あ".repeat(30)), { ok: true, name: "あ".repeat(30) });
});

test("validateGroupName: 全角空白（U+3000）も前後の空白として除く", () => {
  assert.deepEqual(core.validateGroupName("\u3000空の会\u3000"), { ok: true, name: "空の会" });
});

test("validateGroupName: 空・空白だけ・31文字は無効", () => {
  assert.deepEqual(core.validateGroupName(""), { ok: false });
  assert.deepEqual(core.validateGroupName("   "), { ok: false });
  assert.deepEqual(core.validateGroupName("\u3000\u3000"), { ok: false });
  assert.deepEqual(core.validateGroupName("あ".repeat(31)), { ok: false });
});

test("validateGroupName: 文字数はコードポイントで数える（絵文字1つ=1・結合文字は別に数える）", () => {
  // 🌤 は UTF-16 では2単位だが、コードポイントでは1文字。30個ちょうどは通る。
  assert.deepEqual(core.validateGroupName("🌤".repeat(30)), { ok: true, name: "🌤".repeat(30) });
  assert.deepEqual(core.validateGroupName("🌤".repeat(31)), { ok: false });
  // 「か」＋結合用の濁点（U+3099）は見た目1文字だが、コードポイントでは2文字（iOS の unicodeScalars.count と同じ）。
  const ga = "\u304B\u3099";
  assert.deepEqual(core.validateGroupName(ga.repeat(15)), { ok: true, name: ga.repeat(15) });
  assert.deepEqual(core.validateGroupName(ga.repeat(15) + "あ"), { ok: false });
});

test("validateGroupName: 文字列以外は無効", () => {
  for (const bad of [undefined, null, 1, {}, ["空"]]) {
    assert.deepEqual(core.validateGroupName(bad), { ok: false });
  }
});

// ============================================================
// buildNotification
// ============================================================

test("buildNotification: タイトルはグループ名・本文は「{表示名}さんが空を投稿しました」", () => {
  assert.deepEqual(core.buildNotification({ groupName: "空の会", posterName: "はると", caption: undefined }), {
    title: "空の会",
    body: "はるとさんが空を投稿しました",
  });
});

test("buildNotification: キャプションがあれば「」で囲んで末尾に付ける", () => {
  assert.deepEqual(core.buildNotification({ groupName: "空の会", posterName: "はると", caption: "夕焼け" }), {
    title: "空の会",
    body: "はるとさんが空を投稿しました「夕焼け」",
  });
});

test("buildNotification: キャプションが空文字・文字列以外なら付けない", () => {
  for (const caption of ["", null, undefined, 3]) {
    assert.equal(
      core.buildNotification({ groupName: "空の会", posterName: "はると", caption }).body,
      "はるとさんが空を投稿しました"
    );
  }
});

test("buildNotification: キャプションは先頭30文字（コードポイント）で切り詰める・30文字ちょうどはそのまま", () => {
  const c30 = "あ".repeat(30);
  assert.equal(
    core.buildNotification({ groupName: "g", posterName: "n", caption: c30 }).body,
    `nさんが空を投稿しました「${c30}」`
  );
  assert.equal(
    core.buildNotification({ groupName: "g", posterName: "n", caption: c30 + "いうえ" }).body,
    `nさんが空を投稿しました「${c30}」`
  );
  // 絵文字はサロゲートペアを割らずに、1文字として数える。
  const e31 = "🌤".repeat(31);
  assert.equal(
    core.buildNotification({ groupName: "g", posterName: "n", caption: e31 }).body,
    `nさんが空を投稿しました「${"🌤".repeat(30)}」`
  );
});

test("buildNotification: 表示名が空・無いときは「だれか」", () => {
  for (const posterName of ["", null, undefined]) {
    assert.equal(
      core.buildNotification({ groupName: "空の会", posterName, caption: undefined }).body,
      "だれかさんが空を投稿しました"
    );
  }
});

// ============================================================
// soratomoPrefEnabled
// ============================================================

test("soratomoPrefEnabled: 項目が無い（旧ユーザー）・文書が無いときは既定の ON", () => {
  assert.equal(core.soratomoPrefEnabled({}), true);
  assert.equal(core.soratomoPrefEnabled(null), true);
  assert.equal(core.soratomoPrefEnabled(undefined), true);
  assert.equal(core.soratomoPrefEnabled({ notifySoratomo: "false" }), true, "真偽値以外は欠落と同じに扱う");
});

test("soratomoPrefEnabled: 保存された真偽値に従う", () => {
  assert.equal(core.soratomoPrefEnabled({ notifySoratomo: false }), false);
  assert.equal(core.soratomoPrefEnabled({ notifySoratomo: true }), true);
});

test("soratomoPrefEnabled: 既存の3つの通知設定は見ない（そらとも通知は別の項目）", () => {
  const userData = { notifyReactions: false, notifyNewPostsFromFollowing: false, notifyNewPostsFromEveryone: false };
  assert.equal(core.soratomoPrefEnabled(userData), true);
});

// ============================================================
// classifyRecipient
// ============================================================

/** すべての「送らない理由」に当てはまる宛先（分類の順序を見るための土台）。 */
function worstUser(posterId) {
  return { notifySoratomo: false, blockedUserIds: [posterId] /* fcmToken 無し */ };
}

test("classifyRecipient: 送れる宛先は eligible", () => {
  assert.equal(
    core.classifyRecipient({ hasFlag: true, userData: { fcmToken: "t" }, posterId: "P" }),
    "eligible"
  );
});

test("classifyRecipient: 順序は フラグOFF → 設定OFF → ブロック → トークン無し", () => {
  // すべてに当てはまるときは、最初の理由（フラグOFF）になる。
  assert.equal(core.classifyRecipient({ hasFlag: false, userData: worstUser("P"), posterId: "P" }), "flag_off");
  // フラグを満たすと、次の理由（設定OFF）になる。
  assert.equal(core.classifyRecipient({ hasFlag: true, userData: worstUser("P"), posterId: "P" }), "pref_off");
  // 設定も満たすと、ブロック。
  assert.equal(
    core.classifyRecipient({ hasFlag: true, userData: { blockedUserIds: ["P"] }, posterId: "P" }),
    "blocked"
  );
  // ブロックも外すと、トークン無し。
  assert.equal(core.classifyRecipient({ hasFlag: true, userData: { blockedUserIds: ["X"] }, posterId: "P" }), "no_token");
});

test("classifyRecipient: 利用者の文書が無ければ（設定は既定ON・ブロック無し）トークン無し", () => {
  assert.equal(core.classifyRecipient({ hasFlag: true, userData: null, posterId: "P" }), "no_token");
});

test("classifyRecipient: blockedUserIds が配列でなければブロックとみなさない（既存の isBlocked と同じ規則）", () => {
  assert.equal(
    core.classifyRecipient({ hasFlag: true, userData: { blockedUserIds: "P", fcmToken: "t" }, posterId: "P" }),
    "eligible"
  );
});

test("classifyRecipient: hasFlag は true のときだけフラグ ON（truthy の値では通さない）", () => {
  assert.equal(
    core.classifyRecipient({ hasFlag: "true", userData: { fcmToken: "t" }, posterId: "P" }),
    "flag_off"
  );
});

// ============================================================
// decideThrottle
// ============================================================

const T0 = 1_700_000_000_000;

test("decideThrottle: 状態が無ければ送る", () => {
  assert.equal(core.decideThrottle(null, "s1", T0), "send");
  assert.equal(core.decideThrottle(undefined, "s1", T0), "send");
  assert.equal(core.decideThrottle({}, "s1", T0), "send");
});

test("decideThrottle: 同じ投稿IDは、時刻に関係なく重複", () => {
  assert.equal(core.decideThrottle({ lastSentAt: T0, lastSkyId: "s1" }, "s1", T0 + 1), "duplicate");
  assert.equal(core.decideThrottle({ lastSentAt: T0, lastSkyId: "s1" }, "s1", T0 + 60 * 60 * 1000), "duplicate");
});

test("decideThrottle: 5分以内は間引き・5分ちょうども間引き（「以内」は含む）・5分を1ミリ秒でも過ぎれば送る", () => {
  const state = { lastSentAt: T0, lastSkyId: "s1" };
  assert.equal(core.decideThrottle(state, "s2", T0), "throttled");
  assert.equal(core.decideThrottle(state, "s2", T0 + 299_999), "throttled");
  assert.equal(core.decideThrottle(state, "s2", T0 + 300_000), "throttled");
  assert.equal(core.decideThrottle(state, "s2", T0 + 300_001), "send");
});

test("decideThrottle: lastSentAt は Firestore の Timestamp（toMillis を持つ値）でも読める", () => {
  const ts = { toMillis: () => T0 };
  assert.equal(core.decideThrottle({ lastSentAt: ts, lastSkyId: "s1" }, "s2", T0 + 300_000), "throttled");
  assert.equal(core.decideThrottle({ lastSentAt: ts, lastSkyId: "s1" }, "s2", T0 + 300_001), "send");
});

test("decideThrottle: 時刻が読めない状態は、記録が無いものとして送る（ただし同じ投稿IDなら重複）", () => {
  assert.equal(core.decideThrottle({ lastSentAt: "昨日", lastSkyId: "s1" }, "s2", T0), "send");
  assert.equal(core.decideThrottle({ lastSentAt: "昨日", lastSkyId: "s1" }, "s1", T0), "duplicate");
});

// ============================================================
// summarizeNotifyOutcomes（投稿1件ごとの集計）
// ============================================================

const SUMMARY_KEYS = [
  "groupId",
  "skyId",
  "sent",
  "throttled",
  "duplicate",
  "noToken",
  "sendFailed",
  "prefOff",
  "blocked",
  "flagOff",
];

test("summarizeNotifyOutcomes: 宛先ごとの結果を理由別に数える", () => {
  const summary = core.summarizeNotifyOutcomes("g1", "s1", [
    "sent",
    "sent",
    "throttled",
    "duplicate",
    "no_token",
    "failed",
    "invalid_token",
    "pref_off",
    "blocked",
    "flag_off",
    "flag_off",
  ]);
  assert.deepEqual(summary, {
    groupId: "g1",
    skyId: "s1",
    sent: 2,
    throttled: 1,
    duplicate: 1,
    noToken: 1,
    sendFailed: 2, // invalid_token は「送ろうとして失敗した」ので送信失敗に数える
    prefOff: 1,
    blocked: 1,
    flagOff: 2,
  });
});

test("summarizeNotifyOutcomes: 宛先が0人でも全キーが0で揃う", () => {
  const summary = core.summarizeNotifyOutcomes("g1", "s1", []);
  assert.deepEqual(Object.keys(summary).sort(), [...SUMMARY_KEYS].sort());
  for (const k of SUMMARY_KEYS.slice(2)) assert.equal(summary[k], 0);
});

test("summarizeNotifyOutcomes: 想定外の結果は送信失敗に数え、合計が宛先の数と一致する", () => {
  const outcomes = ["sent", "???", undefined];
  const summary = core.summarizeNotifyOutcomes("g1", "s1", outcomes);
  const total = SUMMARY_KEYS.slice(2).reduce((acc, k) => acc + summary[k], 0);
  assert.equal(total, outcomes.length);
  assert.equal(summary.sendFailed, 2);
});

test("summarizeNotifyOutcomes: キーは固定で、名前・キャプション・コード・トークンを含まない（15.2・15.3）", () => {
  const summary = core.summarizeNotifyOutcomes("g1", "s1", ["sent"]);
  assert.deepEqual(Object.keys(summary).sort(), [...SUMMARY_KEYS].sort());
  const forbidden = /name|caption|code|token|title|body|display/i;
  for (const k of Object.keys(summary)) {
    // noToken は「トークン無しの件数」でトークンの値ではないので、件数（数値）であることで許す。
    if (k === "noToken") {
      assert.equal(typeof summary[k], "number");
      continue;
    }
    assert.doesNotMatch(k, forbidden, `集計のキー ${k} が個人情報を連想させる`);
  }
  // 値は ID（文字列）と件数（数値）だけ。
  for (const [k, v] of Object.entries(summary)) {
    if (k === "groupId" || k === "skyId") assert.equal(typeof v, "string");
    else assert.equal(typeof v, "number");
  }
});
