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

// ============================================================
// 公開前ゲート（soratomo-release-gate tasks 1.1）: 定数
// ============================================================

test("公開前ゲートの定数: 設計書（release-gate design.md soratomoCore）の値と一致する", () => {
  assert.equal(core.SKY_DIMENSION_MAX, 2048);
  assert.equal(core.CAPTION_MAX, 100);
  assert.deepEqual(core.REPORT_REASONS, ["inappropriate", "spam", "harassment", "copyright", "other"]);
});

test("GUIDELINE_VERSION は 1（iOS の SoratomoGuideline.currentVersion と一致させる規則）", () => {
  // ⚠️ ここを変えるなら iOS 側の SoratomoGuideline.currentVersion も同時に変えること。
  //    片方だけ上げると、アプリで同意しても outdated_guideline で拒否され続ける（または古い版の同意を認める）。
  assert.equal(core.GUIDELINE_VERSION, 1);
});

test("REPORT_REASON_LABELS: iOS の ReportReason.displayName と同じ日本語名（Discord に出す名前）", () => {
  assert.deepEqual(core.REPORT_REASON_LABELS, {
    inappropriate: "不適切なコンテンツ",
    spam: "スパム・迷惑行為",
    harassment: "嫌がらせ・誹謗中傷",
    copyright: "著作権侵害",
    other: "その他",
  });
  assert.deepEqual(Object.keys(core.REPORT_REASON_LABELS), core.REPORT_REASONS, "理由の並びと名前の表がずれている");
});

// ============================================================
// normalizeForNgCheck・prepareNgWords・containsNgWord（要件11.2）
// ⚠️ 実在の語はテストに書かない。ダミーの語（てすとごい・dummyng）だけを使う。
// ============================================================

/** ダミーの語（ひらがな）と、英字のダミーの語。 */
const NG_KANA = "てすとごい";
const NG_LATIN = "dummyng";

test("normalizeForNgCheck: 全角英数→半角・大文字→小文字・カタカナ（半角カナを含む）→ひらがな", () => {
  assert.equal(core.normalizeForNgCheck("ＡＢＣ１２３"), "abc123");
  assert.equal(core.normalizeForNgCheck("DummyNG"), "dummyng");
  assert.equal(core.normalizeForNgCheck("テストゴイ"), "てすとごい");
  // 半角カナ＋半角の濁点（ｺﾞ）は NFKC で1文字（ゴ）に合成されてからひらがなになる
  assert.equal(core.normalizeForNgCheck("ﾃｽﾄｺﾞｲ"), "てすとごい");
  // 小書き（ァ U+30A1）・ヴ（U+30F4）・ヵヶ（U+30F5・U+30F6）・踊り字（ヽヾ）も対応するひらがなへ
  assert.equal(core.normalizeForNgCheck("ァヴヵヶヽヾ"), "ぁゔゕゖゝゞ");
  // 長音符（ー）・中黒（・）はカタカナの範囲外なので、そのまま残す
  assert.equal(core.normalizeForNgCheck("テー・ト"), "てー・と");
});

test("normalizeForNgCheck: 空白と記号は取り除かない（要件11の補足）", () => {
  assert.equal(core.normalizeForNgCheck("て す と"), "て す と");
  assert.equal(core.normalizeForNgCheck("て-す_と!"), "て-す_と!");
});

test("prepareNgWords: 正規化し、空・空白だけ・文字列でないもの・重複を除く", () => {
  const prepared = core.prepareNgWords(["テストゴイ", NG_KANA, "ﾃｽﾄｺﾞｲ", "ＤＵＭＭＹＮＧ", "", "  ", "　", null, 42]);
  assert.deepEqual(prepared, [NG_KANA, NG_LATIN]);
});

test("prepareNgWords: 配列でなければ空のリスト", () => {
  for (const raw of [undefined, null, "てすとごい", { 0: "てすとごい" }]) {
    assert.deepEqual(core.prepareNgWords(raw), []);
  }
});

test("containsNgWord: 全角半角・大文字小文字・ひらがなとカタカナ・半角カナの組み合わせが該当する", () => {
  const words = core.prepareNgWords([NG_KANA, NG_LATIN]);
  const hits = [
    "てすとごい",
    "テストゴイ",
    "ﾃｽﾄｺﾞｲ",
    "てストごイ",
    "ﾃｽﾄごい",
    "これはてすとごいです", // 一部に含む
    "dummyng",
    "DUMMYNG",
    "ＤＵＭＭＹＮＧ", // 全角の大文字
    "ｄｕｍｍｙｎｇ", // 全角の小文字
    "xxDummyNgxx",
  ];
  for (const text of hits) {
    assert.equal(core.containsNgWord(text, words), true, `該当すべき入力がすり抜けた: ${text}`);
  }
});

test("containsNgWord: 語をカタカナや全角で登録しても、ひらがな・半角の入力に該当する", () => {
  const words = core.prepareNgWords(["テストゴイ", "ＤＵＭＭＹＮＧ"]);
  assert.equal(core.containsNgWord("てすとごい", words), true);
  assert.equal(core.containsNgWord("dummyng", words), true);
});

test("containsNgWord: 無関係の文・間に空白を挟んだ文・濁点の無い文は該当しない", () => {
  const words = core.prepareNgWords([NG_KANA, NG_LATIN]);
  for (const text of ["今日の空はきれい", "夕焼けがすごい", "てすと ごい", "てすとこい", "dummy ng", ""]) {
    assert.equal(core.containsNgWord(text, words), false, `該当してはいけない入力が該当した: ${text}`);
  }
});

test("containsNgWord: 語が無い・空の語だけのときは、どの文も通す（全投稿の拒否にしない）", () => {
  assert.equal(core.containsNgWord("今日の空", []), false);
  assert.equal(core.containsNgWord("今日の空", core.prepareNgWords(["", "  "])), false);
  // 準備を通さずに空の語を渡されても、"".includes の常に真で全部を拒否しない
  assert.equal(core.containsNgWord("今日の空", [""]), false);
});

test("containsNgWord: 文字列でない入力（キャプション無しなど）は該当しない", () => {
  const words = core.prepareNgWords([NG_KANA]);
  for (const text of [undefined, null, 123, ["てすとごい"]]) {
    assert.equal(core.containsNgWord(text, words), false);
  }
});

// ============================================================
// validateSkyInput（旧ルール isValidSoratomoSky と同じ条件・要件11.5）
// 入力は scripts/rules_test_soratomo.py の作成とキャプションのケースから移した。
// ============================================================

/** 正しい入力（Callable soratomoCreateSky の要求）。groupId・skyId は Firestore の自動ID（英数字20文字）。 */
const VALID_SKY_INPUT = {
  groupId: "AbCdEfGhIjKlMnOpQrSt",
  skyId: "s1",
  caption: "夕焼け",
  width: 1080,
  height: 1440,
};

/** VALID_SKY_INPUT の一部を書き換えた入力（値が undefined ならキーごと消す）。 */
function skyInput(fields) {
  const data = { ...VALID_SKY_INPUT, ...fields };
  for (const [key, value] of Object.entries(fields)) {
    if (value === undefined) delete data[key];
  }
  return data;
}

const EMOJI = "\u{1F600}"; // サロゲートペア（UTF-16 で 2）
const E_ACUTE = "é"; // e＋結合文字（コードポイント 2・書記素 1）
const MIX_100 = EMOJI.repeat(20) + E_ACUTE.repeat(20) + "あ".repeat(40); // コードポイント 100・UTF-16 120

test("validateSkyInput: 正しい5項目は ok で、書く値は5つだけ", () => {
  const result = core.validateSkyInput(VALID_SKY_INPUT);
  assert.deepEqual(result, { ok: true, value: { ...VALID_SKY_INPUT } });
});

test("validateSkyInput: キャプションのキーが無ければ caption は null", () => {
  const result = core.validateSkyInput(skyInput({ caption: undefined }));
  assert.equal(result.ok, true);
  assert.equal(result.value.caption, null);
});

test("validateSkyInput: キャプションに null を明示したら拒否（旧ルールと同じく「キーが無い」だけを許す）", () => {
  assert.deepEqual(core.validateSkyInput(skyInput({ caption: null })), { ok: false });
});

test("validateSkyInput: 余分な項目（投稿者・作成日時・画像のパスや URL）は書く値に持ち込まない", () => {
  const result = core.validateSkyInput(
    skyInput({
      authorId: "someone-else",
      createdAt: "2026-10-01T02:59:00Z",
      imagePath: "soratomo/g1/author/s1/display.jpg",
      url: "https://example.com/a.jpg",
    })
  );
  assert.equal(result.ok, true);
  assert.deepEqual(Object.keys(result.value).sort(), ["caption", "groupId", "height", "skyId", "width"]);
});

test("validateSkyInput: 幅・高さは 1〜2048 の整数（境界 1・2048 は通る）", () => {
  assert.equal(core.validateSkyInput(skyInput({ width: 1, height: 2048 })).ok, true);
  assert.equal(core.validateSkyInput(skyInput({ width: 2048, height: 1 })).ok, true);
});

test("validateSkyInput: 幅・高さの誤り（無い・0・2049・小数・文字列・負・NaN・無限大）は拒否", () => {
  const bad = [
    { width: undefined },
    { height: undefined },
    { width: 0 },
    { width: 2049 },
    { height: 0 },
    { height: 2049 },
    { width: 1080.5 },
    { height: "1440" },
    { width: -1 },
    { width: Number.NaN },
    { height: Number.POSITIVE_INFINITY },
    { width: null },
  ];
  for (const fields of bad) {
    assert.deepEqual(core.validateSkyInput(skyInput(fields)), { ok: false }, `通ってしまった: ${JSON.stringify(fields)}`);
  }
});

test("validateSkyInput: キャプションの許可（コードポイントで100まで・タブは可）", () => {
  const ok = [
    MIX_100, // 絵文字 20＋結合文字 20＋かな 40（UTF-16 120）
    "a".repeat(100),
    EMOJI.repeat(50), // UTF-16 100
    EMOJI.repeat(50) + "a", // コードポイント 51・UTF-16 101
    "あ".repeat(100), // UTF-8 300 バイト
    "a\tb",
  ];
  for (const caption of ok) {
    const result = core.validateSkyInput(skyInput({ caption }));
    assert.equal(result.ok, true, `拒否された: ${JSON.stringify(caption)}`);
    assert.equal(result.value.caption, caption, "キャプションを書き換えずにそのまま返す");
  }
});

test("validateSkyInput: キャプションの拒否（101・結合文字で120・空文字・数値・改行類5種）", () => {
  const bad = [
    MIX_100 + "a", // コードポイント 101
    "a".repeat(101),
    E_ACUTE.repeat(60), // 書記素 60・コードポイント 120
    "",
    123,
    "a\nb", // LF
    "a\nb\nc", // LF が 2 つ
    "a\rb", // CR
    "a\r\nb", // CRLF
    "a\u0085b", // NEL
    "a b", // LINE SEPARATOR
    "a b", // PARAGRAPH SEPARATOR
    "ab\n", // 末尾の LF
  ];
  for (const caption of bad) {
    assert.deepEqual(core.validateSkyInput(skyInput({ caption })), { ok: false }, `通ってしまった: ${JSON.stringify(caption)}`);
  }
});

test("validateSkyInput: groupId・skyId は英数字の自動ID（1〜64文字）だけ", () => {
  // 「_」を許すと、通報の記録のID（{groupId}_{skyId}_{reporterId}）が別の組と同じになりうる
  const bad = ["", "a/b", "a_b", ".", "..", "a b", "あ", "a".repeat(65), 123, null, undefined];
  for (const id of bad) {
    assert.deepEqual(core.validateSkyInput(skyInput({ groupId: id })), { ok: false }, `groupId が通った: ${JSON.stringify(id)}`);
    assert.deepEqual(core.validateSkyInput(skyInput({ skyId: id })), { ok: false }, `skyId が通った: ${JSON.stringify(id)}`);
  }
  assert.equal(core.validateSkyInput(skyInput({ skyId: "a".repeat(64) })).ok, true);
});

test("validateSkyInput: 要求の本文がオブジェクトでなければ拒否", () => {
  for (const data of [null, undefined, "x", 1, [VALID_SKY_INPUT]]) {
    assert.deepEqual(core.validateSkyInput(data), { ok: false });
  }
});

// ============================================================
// isSuspended（要件8.6・レビュー #2: 停止の判定を1か所にまとめる）
// ============================================================

test("isSuspended: 未設定と null だけが「停止していない」。値があれば型を問わず停止中（止める側に倒す）", () => {
  assert.equal(core.isSuspended(undefined), false);
  assert.equal(core.isSuspended(null), false);
  for (const value of [{ toMillis: () => 1 }, 0, "", false, "2026-10-08", 1]) {
    assert.equal(core.isSuspended(value), true, `${JSON.stringify(value)} は停止中`);
  }
});

// ============================================================
// isReportReason・reportDocId（要件6.6・6.7）
// ============================================================

test("isReportReason: 5つの理由だけを認める", () => {
  for (const reason of ["inappropriate", "spam", "harassment", "copyright", "other"]) {
    assert.equal(core.isReportReason(reason), true);
  }
  for (const value of ["Spam", "", " spam", "toString", "__proto__", "constructor", null, undefined, 1, ["spam"]]) {
    assert.equal(core.isReportReason(value), false, `認めてしまった: ${JSON.stringify(value)}`);
  }
});

test("reportDocId: グループID・投稿ID・通報者から1つに決まる", () => {
  assert.equal(core.reportDocId("g1", "s1", "uidA"), "g1_s1_uidA");
  assert.equal(core.reportDocId("g1", "s1", "uidA"), core.reportDocId("g1", "s1", "uidA"));
  assert.notEqual(core.reportDocId("g1", "s1", "uidA"), core.reportDocId("g1", "s1", "uidB"));
});

test("reportDocId: 区切りの「_」を含む ID・文書IDに使えない通報者は TypeError（別の組と同じIDにしない）", () => {
  // 関数が無いときの「is not a function」の TypeError で緑にならないよう、実装のメッセージの頭まで見る
  const expected = { name: "TypeError", message: /^soratomo: reportDocId/ };
  assert.throws(() => core.reportDocId("g_1", "s1", "uidA"), expected);
  assert.throws(() => core.reportDocId("g1", "s_1", "uidA"), expected);
  assert.throws(() => core.reportDocId("g1", "s1", "a/b"), expected);
  assert.throws(() => core.reportDocId("g1", "s1", ""), expected);
  assert.throws(() => core.reportDocId("g1", "s1", null), expected);
});

// ============================================================
// pickNextOwner・planMembershipRemoval（要件2.1・2.2・2.5・2.6・2.7・2.9・3.4）
// ============================================================

/** メンバーの写し（参加日時はミリ秒・無いときは null）。 */
function member(uid, joinedAtMs, role = "member") {
  return { uid, role, joinedAtMs };
}

test("pickNextOwner: 参加日時の古い順で1人", () => {
  assert.equal(core.pickNextOwner([member("c", 300), member("a", 200), member("b", 100)]), "b");
});

test("pickNextOwner: 参加日時が同じなら uid の昇順（メンバー一覧の並びと同じ規則）", () => {
  // 入力の先頭（"b"）を返す実装・同点の並びを決めない実装では "b" になる
  assert.equal(core.pickNextOwner([member("b", 100), member("a", 100), member("c", 100)]), "a");
});

test("pickNextOwner: 参加日時が無いものは最後（全員無ければ uid の昇順）", () => {
  assert.equal(core.pickNextOwner([member("a", null), member("z", 500)]), "z");
  assert.equal(core.pickNextOwner([member("b", null), member("a", null)]), "a");
  // 数値でない・有限でない参加日時は「無い」と同じに扱う
  assert.equal(core.pickNextOwner([member("a", Number.NaN), member("b", "100"), member("c", 900)]), "c");
});

test("pickNextOwner: 0人なら null・入力の配列を並べ替えない", () => {
  assert.equal(core.pickNextOwner([]), null);
  const members = [member("b", 100), member("a", 100)];
  core.pickNextOwner(members);
  assert.deepEqual(members.map((m) => m.uid), ["b", "a"]);
});

/** roleUpdates を uid の順に並べる（比べるため）。 */
function sortedUpdates(plan) {
  return [...plan.roleUpdates].sort((x, y) => (x.uid < y.uid ? -1 : 1));
}

test("planMembershipRemoval: 他にメンバーがいるオーナーの退会は、参加の最も古い人へ引き継ぐ", () => {
  const plan = core.planMembershipRemoval({
    uid: "owner",
    ownerId: "owner",
    members: [member("owner", 100, "owner"), member("m1", 300), member("m2", 200)],
  });
  assert.equal(plan.kind, "leave");
  assert.equal(plan.removed, true);
  assert.equal(plan.memberCount, 2);
  assert.equal(plan.ownerId, "m2");
  assert.equal(plan.ownerTransferred, true);
  assert.deepEqual(sortedUpdates(plan), [{ uid: "m2", role: "owner" }]);
});

test("planMembershipRemoval: ただのメンバーの退会は、オーナーも役割も変えない", () => {
  const plan = core.planMembershipRemoval({
    uid: "m1",
    ownerId: "owner",
    members: [member("owner", 100, "owner"), member("m1", 300), member("m2", 200)],
  });
  assert.deepEqual(
    { ...plan, roleUpdates: sortedUpdates(plan) },
    { kind: "leave", removed: true, memberCount: 2, ownerId: "owner", ownerTransferred: false, roleUpdates: [] }
  );
});

test("planMembershipRemoval: 最後の1人ならグループごと削除", () => {
  const plan = core.planMembershipRemoval({ uid: "owner", ownerId: "owner", members: [member("owner", 100, "owner")] });
  assert.deepEqual(plan, { kind: "delete_group", removed: true });
});

test("planMembershipRemoval: すでに外れている再実行でも、同じ整え方を返す", () => {
  // 1回目の後の状態（m2 がオーナー・人数2）から、同じ退会をもう一度流す
  const plan = core.planMembershipRemoval({
    uid: "owner",
    ownerId: "m2",
    members: [member("m1", 300), member("m2", 200, "owner")],
  });
  assert.deepEqual(
    { ...plan, roleUpdates: sortedUpdates(plan) },
    { kind: "leave", removed: false, memberCount: 2, ownerId: "m2", ownerTransferred: false, roleUpdates: [] }
  );
  // メンバーが誰も残っていない再実行（グループの文書だけが残った）も、グループごと削除にする
  assert.deepEqual(core.planMembershipRemoval({ uid: "owner", ownerId: "owner", members: [] }), {
    kind: "delete_group",
    removed: false,
  });
});

test("planMembershipRemoval: 壊れた状態（オーナーの記録が残りにいない・オーナーが2人）は1人にそろえる", () => {
  const plan = core.planMembershipRemoval({
    uid: "m9",
    ownerId: "ghost", // メンバーにいない
    members: [member("m1", 300, "owner"), member("m2", 200), member("m3", 400, "owner")],
  });
  assert.equal(plan.kind, "leave");
  assert.equal(plan.removed, false);
  assert.equal(plan.memberCount, 3);
  assert.equal(plan.ownerId, "m2");
  assert.equal(plan.ownerTransferred, true);
  assert.deepEqual(sortedUpdates(plan), [
    { uid: "m1", role: "member" },
    { uid: "m2", role: "owner" },
    { uid: "m3", role: "member" },
  ]);
});

test("planMembershipRemoval: オーナーの記録が文字列でなくても、残りから選び直す", () => {
  const plan = core.planMembershipRemoval({
    uid: "m1",
    ownerId: undefined,
    members: [member("m1", 100), member("m2", 200)],
  });
  assert.equal(plan.ownerId, "m2");
  assert.equal(plan.ownerTransferred, true);
  assert.deepEqual(sortedUpdates(plan), [{ uid: "m2", role: "owner" }]);
});

test("planMembershipRemoval: 人数は残りの数で決める（保存された人数に依らない）", () => {
  const members = Array.from({ length: 20 }, (_, i) => member(`m${String(i).padStart(2, "0")}`, i));
  const plan = core.planMembershipRemoval({ uid: "m05", ownerId: "m00", members });
  assert.equal(plan.memberCount, 19);
});

// ============================================================
// buildReportForwardPayload（要件7.1・7.2）
// ============================================================

/** 通報の記録（禁止の項目を、わざと混ぜてある）。 */
function reportRecord(overrides = {}) {
  return {
    reportId: "g1_s1_reporterUid",
    groupId: "g1",
    skyId: "s1",
    authorId: "authorUid",
    reporterId: "reporterUid",
    reason: "spam",
    createdAt: { toMillis: () => Date.UTC(2026, 9, 8, 0, 0, 0) },
    // ↓ 本文に載せてはいけない値（記録には無い項目だが、混ざっても本文に出ないことを確かめる）
    caption: "SECRET_CAPTION",
    groupName: "SECRET_GROUP",
    displayName: "SECRET_NAME",
    inviteCode: "SECRETCD",
    imagePath: "soratomo/g1/authorUid/s1/display.jpg",
    imageUrl: "https://example.com/secret.jpg",
    ...overrides,
  };
}

test("buildReportForwardPayload: ユーザー名・題名・理由（日本語の名前と値）・ID・時刻を載せる", () => {
  const payload = core.buildReportForwardPayload(reportRecord());
  assert.equal(payload.username, "そらとも 通報");
  assert.equal(payload.embeds.length, 1);
  const embed = payload.embeds[0];
  assert.equal(embed.title, "そらともの通報が届きました");
  assert.equal(embed.timestamp, "2026-10-08T00:00:00.000Z");
  const fields = Object.fromEntries(embed.fields.map((f) => [f.name, f.value]));
  assert.deepEqual(fields, {
    理由: "スパム・迷惑行為（spam）",
    reportId: "`g1_s1_reporterUid`",
    groupId: "`g1`",
    skyId: "`s1`",
    投稿者のuid: "`authorUid`",
    通報者のuid: "`reporterUid`",
  });
  // 本文の ID で誰かへの @ 通知が飛ばないようにする
  assert.deepEqual(payload.allowed_mentions, { parse: [] });
});

test("buildReportForwardPayload: キーは決まったものだけで、キャプション・名前・コード・画像とURLが出ない（7.2）", () => {
  const payload = core.buildReportForwardPayload(reportRecord());
  assert.deepEqual(Object.keys(payload).sort(), ["allowed_mentions", "embeds", "username"]);
  assert.deepEqual(Object.keys(payload.embeds[0]).sort(), ["color", "fields", "timestamp", "title"]);
  for (const field of payload.embeds[0].fields) {
    assert.deepEqual(Object.keys(field).sort(), ["inline", "name", "value"]);
  }
  const json = JSON.stringify(payload);
  for (const secret of ["SECRET_CAPTION", "SECRET_GROUP", "SECRET_NAME", "SECRETCD", "display.jpg", "soratomo/", "http"]) {
    assert.ok(!json.includes(secret), `本文に載せてはいけない値が出た: ${secret}`);
  }
});

test("buildReportForwardPayload: 知らない理由は「不明」で、入力の文字列をそのまま出さない", () => {
  const payload = core.buildReportForwardPayload(reportRecord({ reason: "<@everyone> 自由記述" }));
  const reasonField = payload.embeds[0].fields.find((f) => f.name === "理由");
  assert.equal(reasonField.value, "不明");
  assert.ok(!JSON.stringify(payload).includes("everyone"));
});

test("buildReportForwardPayload: 文字列でない ID は「不明」・時刻が読めなければ timestamp を付けない", () => {
  const payload = core.buildReportForwardPayload(reportRecord({ authorId: null, skyId: 123, createdAt: undefined }));
  const fields = Object.fromEntries(payload.embeds[0].fields.map((f) => [f.name, f.value]));
  assert.equal(fields.投稿者のuid, "不明");
  assert.equal(fields.skyId, "不明");
  assert.ok(!("timestamp" in payload.embeds[0]));
  // 時刻はミリ秒の数値でも受け付ける
  const withMs = core.buildReportForwardPayload(reportRecord({ createdAt: Date.UTC(2026, 0, 2, 3, 4, 5) }));
  assert.equal(withMs.embeds[0].timestamp, "2026-01-02T03:04:05.000Z");
});
