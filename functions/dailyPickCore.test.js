//
// dailyPickCore.js の単体テスト（node:test = Node標準・新規npm依存なし）。
// firebase-admin/firebase-functions には一切触れない（純粋関数のみ検証）。
//
// 実行: node --test dailyPickCore.test.js
//
// ⚠️ 陽性対照（2026-10-24）:
//    ① DAY_SWITCH_HOUR_JST を 7→0（0 時切り替え）に壊して npm test → 「dateKeyForInstant: 7:00 JST で日付が切り替わる」
//       と「定数: 仕様どおりの値」が赤になることを確認 → 元に戻した。
//    ② 運営除外（excluded.has）のフィルタを外して npm test → 「運営除外は候補が尽きても緩めない」と
//       「運営の投稿しか無ければ空」が赤になることを確認 → 元に戻した。
//    どちらも戻した後に全件緑を再確認済み。
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const core = require("./dailyPickCore");

const ms = (iso) => Date.parse(iso);

/** 決まった値を順に返す rng（尽きたら先頭に戻る）。 */
function seqRng(values) {
  let i = 0;
  return () => values[i++ % values.length];
}

/** 投稿 [postId, userId] の配列から posts を作る。 */
const mk = (pairs) => pairs.map(([postId, userId]) => ({ postId, userId }));

// ============================================================
// 定数・設定
// ============================================================

test("定数: 仕様どおりの値", () => {
  assert.equal(core.DAY_SWITCH_HOUR_JST, 7);
  assert.equal(core.MAX_CANDIDATES, 5);
  assert.equal(core.RECENT_DAYS, 30);
  assert.equal(core.MAX_SCAN, 50000);
  assert.equal(core.LOG_TTL_DAYS, 90);
  assert.equal(core.NOTIFY_WINDOW_START_HOUR_JST, 7);
  assert.equal(core.NOTIFY_WINDOW_END_HOUR_JST, 21);
  assert.equal(core.NOTICE_TITLE, "そらもよう");
});

test("SCHEDULE_OPTIONS: 毎朝 7:00 JST・東京リージョン・インスタンスは 1 台まで（同時実行はありうる）", () => {
  assert.deepEqual(core.SCHEDULE_OPTIONS, {
    schedule: "0 7 * * *",
    timeZone: "Asia/Tokyo",
    region: "asia-northeast1",
    timeoutSeconds: 300,
    memory: "512MiB",
    maxInstances: 1,
    retryCount: 2,
  });
});

test("noticeBody: 承認済みの文言そのまま", () => {
  assert.equal(core.noticeBody(), "あなたの空が「今日のおすすめのそらもよう」に選ばれました");
});

// ============================================================
// dateKeyForInstant
// ============================================================

test("dateKeyForInstant: 7:00 JST で日付が切り替わる", () => {
  const table = [
    ["2026-10-25T06:59:59+09:00", "2026-10-24"],
    ["2026-10-25T07:00:00+09:00", "2026-10-25"],
    ["2026-10-25T00:00:00+09:00", "2026-10-24"],
    ["2026-10-25T23:59:59+09:00", "2026-10-25"],
    ["2027-01-01T06:59:59+09:00", "2026-12-31"],
    ["2027-01-01T07:00:00+09:00", "2027-01-01"],
  ];
  for (const [iso, key] of table) {
    assert.equal(core.dateKeyForInstant(ms(iso)), key, iso);
  }
});

test("dateKeyForInstant: 数値でない・NaN は throw", () => {
  assert.throws(() => core.dateKeyForInstant(NaN));
  assert.throws(() => core.dateKeyForInstant("1700000000000"));
  assert.throws(() => core.dateKeyForInstant(undefined));
  assert.throws(() => core.dateKeyForInstant(Infinity));
});

// ============================================================
// previousDateKeys
// ============================================================

test("previousDateKeys: 前日から新しい順・自身は含まない", () => {
  assert.deepEqual(core.previousDateKeys("2026-10-25", 3), ["2026-10-24", "2026-10-23", "2026-10-22"]);
});

test("previousDateKeys: 月またぎ・年またぎ・うるう日", () => {
  assert.deepEqual(core.previousDateKeys("2026-03-02", 3), ["2026-03-01", "2026-02-28", "2026-02-27"]);
  assert.deepEqual(core.previousDateKeys("2027-01-02", 3), ["2027-01-01", "2026-12-31", "2026-12-30"]);
  assert.deepEqual(core.previousDateKeys("2028-03-01", 2), ["2028-02-29", "2028-02-28"]);
});

test("previousDateKeys: 30 日分は 30 件で重複なし", () => {
  const keys = core.previousDateKeys("2026-10-25", core.RECENT_DAYS);
  assert.equal(keys.length, 30);
  assert.equal(new Set(keys).size, 30);
  assert.equal(keys[29], "2026-09-25");
});

test("previousDateKeys: n が 0 以下なら空・不正な鍵は throw", () => {
  assert.deepEqual(core.previousDateKeys("2026-10-25", 0), []);
  assert.throws(() => core.previousDateKeys("2026-10-5", 3));
  assert.throws(() => core.previousDateKeys("2026-02-30", 3));
  assert.throws(() => core.previousDateKeys(undefined, 3));
  assert.throws(() => core.previousDateKeys("abcd-ef-gh", 3));
});

// ============================================================
// isWithinNotifyWindow
// ============================================================

test("isWithinNotifyWindow: 07:00 以上 21:00 未満（日本時間）だけ true", () => {
  const key = "2026-10-25";
  assert.equal(core.isWithinNotifyWindow(ms("2026-10-25T06:59:59+09:00"), key), false);
  assert.equal(core.isWithinNotifyWindow(ms("2026-10-25T07:00:00+09:00"), key), true);
  assert.equal(core.isWithinNotifyWindow(ms("2026-10-25T20:59:59+09:00"), key), true);
  assert.equal(core.isWithinNotifyWindow(ms("2026-10-25T21:00:00+09:00"), key), false);
});

test("isWithinNotifyWindow: 別の日・不正な入力は false / throw", () => {
  assert.equal(core.isWithinNotifyWindow(ms("2026-10-24T12:00:00+09:00"), "2026-10-25"), false);
  assert.equal(core.isWithinNotifyWindow(ms("2026-10-26T12:00:00+09:00"), "2026-10-25"), false);
  assert.equal(core.isWithinNotifyWindow(NaN, "2026-10-25"), false);
  assert.throws(() => core.isWithinNotifyWindow(ms("2026-10-25T12:00:00+09:00"), "bad"));
});

// ============================================================
// normalizeConfig
// ============================================================

test("normalizeConfig: 正常系（除外あり・通知あり）", () => {
  assert.deepEqual(core.normalizeConfig({ excludedUserIds: ["a", "b"], notifyEnabled: true }), {
    ok: true,
    excludedUserIds: ["a", "b"],
    notifyEnabled: true,
  });
});

test("normalizeConfig: 空配列は ok（除外なし）・notifyEnabled は真偽値以外なら false", () => {
  assert.deepEqual(core.normalizeConfig({ excludedUserIds: [] }), {
    ok: true,
    excludedUserIds: [],
    notifyEnabled: false,
  });
  assert.equal(core.normalizeConfig({ excludedUserIds: [], notifyEnabled: "true" }).notifyEnabled, false);
  assert.equal(core.normalizeConfig({ excludedUserIds: [], notifyEnabled: 1 }).notifyEnabled, false);
  assert.equal(core.normalizeConfig({ excludedUserIds: [], notifyEnabled: false }).notifyEnabled, false);
});

test("normalizeConfig: 読めない形は ok:false（安全側）", () => {
  for (const bad of [
    null,
    undefined,
    "x",
    42,
    [],
    {},
    { excludedUserIds: "a" },
    { excludedUserIds: ["a", 3] },
    { excludedUserIds: ["a", ""] },
    { excludedUserIds: [null] },
  ]) {
    const r = core.normalizeConfig(bad);
    assert.equal(r.ok, false, JSON.stringify(bad));
    assert.equal(typeof r.reason, "string");
  }
});

test("normalizeConfig: 入力配列を共有しない（コピーを返す）", () => {
  const ids = ["a"];
  const r = core.normalizeConfig({ excludedUserIds: ids });
  r.excludedUserIds.push("z");
  assert.deepEqual(ids, ["a"]);
});

// ============================================================
// pickCandidates
// ============================================================

test("pickCandidates: 空入力・入力なしは空配列", () => {
  assert.deepEqual(core.pickCandidates({ posts: [] }), { candidates: [], relaxedCount: 0 });
  assert.deepEqual(core.pickCandidates({}), { candidates: [], relaxedCount: 0 });
  assert.deepEqual(core.pickCandidates(), { candidates: [], relaxedCount: 0 });
});

test("pickCandidates: postId / userId が空・文字列以外の投稿は捨てる", () => {
  const posts = [
    { postId: "", userId: "u1" },
    { postId: "p2", userId: "" },
    { postId: 3, userId: "u3" },
    { postId: "p4", userId: null },
    null,
    { postId: "p5", userId: "u5" },
  ];
  const r = core.pickCandidates({ posts, rng: seqRng([0]) });
  assert.deepEqual(r.candidates, [{ postId: "p5", userId: "u5" }]);
});

test("pickCandidates: 運営除外は候補が尽きても緩めない", () => {
  const posts = mk([["p1", "admin"], ["p2", "admin"], ["p3", "u3"]]);
  const r = core.pickCandidates({
    posts,
    excludedUserIds: ["admin"],
    recentPrimaries: new Map([["u3", "2026-10-01"]]), // 緩め段階でも admin は出ない
    rng: seqRng([0]),
  });
  assert.deepEqual(r.candidates, [{ postId: "p3", userId: "u3" }]);
  assert.equal(r.relaxedCount, 1);
  assert.ok(!r.candidates.some((c) => c.userId === "admin"));
});

test("pickCandidates: 運営の投稿しか無ければ空（緩めても出さない）", () => {
  const r = core.pickCandidates({
    posts: mk([["p1", "admin"]]),
    excludedUserIds: ["admin"],
    recentPrimaries: new Map(),
  });
  assert.deepEqual(r, { candidates: [], relaxedCount: 0 });
});

test("pickCandidates: 通報された投稿は緩め段階でも出さず、同じ投稿者の別投稿は使える", () => {
  const posts = mk([["bad", "u1"], ["ok", "u1"], ["bad2", "u2"]]);
  const r = core.pickCandidates({
    posts,
    reportedPostIds: ["bad", "bad2"],
    recentPrimaries: { u2: "2026-10-01" },
    rng: seqRng([0]),
  });
  assert.deepEqual(r.candidates, [{ postId: "ok", userId: "u1" }]);
  assert.equal(r.relaxedCount, 0);
});

test("pickCandidates: 30 日以内に主役だった投稿者は、足りるかぎり選ばない", () => {
  const posts = mk([["p1", "a"], ["p2", "b"], ["p3", "c"]]);
  const r = core.pickCandidates({
    posts,
    count: 2,
    recentPrimaries: new Map([["a", "2026-10-20"]]),
    rng: seqRng([0.1, 0.9]),
  });
  assert.equal(r.candidates.length, 2);
  assert.deepEqual(r.candidates.map((c) => c.userId).sort(), ["b", "c"]);
  assert.equal(r.relaxedCount, 0);
});

test("pickCandidates: 足りなければ主役になった日が古い順に緩める", () => {
  const posts = mk([["pn", "new"], ["po", "old"], ["pm", "mid"], ["pf", "fresh"]]);
  const recentPrimaries = new Map([
    ["new", "2026-10-24"],
    ["old", "2026-09-26"],
    ["mid", "2026-10-10"],
  ]);
  const r = core.pickCandidates({ posts, count: 3, recentPrimaries, rng: seqRng([0]) });
  // きびしい組は fresh の 1 人 → 緩めで old（最古）→ mid の順
  assert.deepEqual(r.candidates.map((c) => c.userId), ["fresh", "old", "mid"]);
  assert.equal(r.relaxedCount, 2);
});

test("pickCandidates: 緩めるときは残っている投稿から rng で 1 件取る", () => {
  const posts = mk([["a1", "a"], ["a2", "a"], ["a3", "a"]]);
  const recentPrimaries = new Map([["a", "2026-10-01"]]);
  assert.equal(core.pickCandidates({ posts, recentPrimaries, rng: seqRng([0]) }).candidates[0].postId, "a1");
  assert.equal(core.pickCandidates({ posts, recentPrimaries, rng: seqRng([0.5]) }).candidates[0].postId, "a2");
  assert.equal(core.pickCandidates({ posts, recentPrimaries, rng: seqRng([0.99]) }).candidates[0].postId, "a3");
});

test("pickCandidates: 候補の投稿者は全員別人（1 人が大量投稿していても）", () => {
  const posts = mk([
    ["a1", "a"], ["a2", "a"], ["a3", "a"], ["a4", "a"],
    ["b1", "b"], ["b2", "b"],
    ["c1", "c"],
  ]);
  for (const seed of [0, 0.2, 0.5, 0.8, 0.99]) {
    const r = core.pickCandidates({ posts, rng: seqRng([seed, 1 - seed, 0.3]) });
    const users = r.candidates.map((c) => c.userId);
    assert.equal(new Set(users).size, users.length);
    assert.equal(users.length, 3);
  }
});

test("pickCandidates: count を超えない・既定は 5 件", () => {
  const posts = mk(Array.from({ length: 20 }, (_, i) => [`p${i}`, `u${i}`]));
  assert.equal(core.pickCandidates({ posts }).candidates.length, 5);
  assert.equal(core.pickCandidates({ posts, count: 2 }).candidates.length, 2);
});

test("pickCandidates: どの投稿も 1 件目になりうる（rng を全域に振って各投稿が先頭に来る）", () => {
  const posts = mk([["p1", "a"], ["p2", "b"], ["p3", "c"]]);
  const heads = new Set();
  for (let i = 0; i < 30; i++) {
    const r = core.pickCandidates({ posts, rng: seqRng([i / 30, (i * 7 % 30) / 30]) });
    heads.add(r.candidates[0].postId);
  }
  assert.deepEqual([...heads].sort(), ["p1", "p2", "p3"]);
});

test("pickCandidates: 同じ rng なら同じ結果", () => {
  const posts = mk(Array.from({ length: 12 }, (_, i) => [`p${i}`, `u${i % 7}`]));
  const recentPrimaries = new Map([["u1", "2026-10-01"], ["u2", "2026-10-02"]]);
  const a = core.pickCandidates({ posts, recentPrimaries, rng: seqRng([0.13, 0.77, 0.42, 0.9]) });
  const b = core.pickCandidates({ posts, recentPrimaries, rng: seqRng([0.13, 0.77, 0.42, 0.9]) });
  assert.deepEqual(a, b);
});

test("pickCandidates: rng が固定なら決まった並びになる（Fisher-Yates の値を固定）", () => {
  const posts = mk([["p1", "a"], ["p2", "b"], ["p3", "c"]]);
  // 常に 0 を返す rng: i=2→j=0 で [p3,p2,p1]、i=1→j=0 で [p2,p3,p1]
  const r = core.pickCandidates({ posts, rng: () => 0 });
  assert.deepEqual(r.candidates.map((c) => c.postId), ["p2", "p3", "p1"]);
});

test("pickCandidates: 入力（posts・除外・通報・recentPrimaries）を書き換えない", () => {
  const posts = mk([["p1", "a"], ["p2", "b"], ["p3", "c"], ["p4", "a"]]);
  const excluded = ["x"];
  const reported = ["p9"];
  const recent = new Map([["a", "2026-10-01"]]);
  const snap = JSON.stringify({ posts, excluded, reported, recent: [...recent] });
  core.pickCandidates({
    posts,
    excludedUserIds: excluded,
    reportedPostIds: reported,
    recentPrimaries: recent,
    rng: seqRng([0.3, 0.6]),
  });
  assert.equal(JSON.stringify({ posts, excluded, reported, recent: [...recent] }), snap);
});

test("pickCandidates: recentPrimaries はオブジェクト形式でも Map と同じ結果", () => {
  const posts = mk([["p1", "a"], ["p2", "b"]]);
  const viaMap = core.pickCandidates({ posts, recentPrimaries: new Map([["a", "2026-10-01"]]), rng: () => 0 });
  const viaObj = core.pickCandidates({ posts, recentPrimaries: { a: "2026-10-01" }, rng: () => 0 });
  assert.deepEqual(viaObj, viaMap);
  assert.deepEqual(viaMap.candidates.map((c) => c.userId), ["b", "a"]);
  assert.equal(viaMap.relaxedCount, 1);
});
