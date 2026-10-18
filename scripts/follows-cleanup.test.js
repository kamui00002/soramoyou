//
// follows-cleanup.js の単体テスト（node:test・firebase-admin 非依存・本番に触れない）⭐️☁️（D-1）
//
// 実行（functions/ の npm test に登録）: node --test scripts/follows-cleanup.test.js
//
// 区分の分け方・引数・出力・delete の順番（読み直す → 照らす → 写しを書く → 確認 → 1 件ずつ消す）を、
// 偽の窓口（store）で確かめる。本物の Firestore のページ分け・select・lastUpdateTime の振る舞いは
// follows-cleanup.emulator.test.js で確かめる。
// ⚠️ 台本の main（firebase-admin の初期化と本番への接続）はテストから呼ばない。export もしていない。
// ⚠️ 写しの JSON は os.tmpdir() の下の使い捨てのフォルダに書く（リポジトリの中には書かない）。
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const cleanup = require("./follows-cleanup");

// MARK: - 下ごしらえ

/** 境目（テスト用）。台本の定数（2026-10-16）とわざと違う時刻にして、定数を決め打ちで使う実装を落とす。 */
const B = Date.UTC(2026, 0, 1, 0, 0, 0);
const BEFORE = B - 60_000;
const AFTER = B + 60_000;
const NOW = Date.UTC(2026, 9, 18, 3, 0, 0);

/** Firestore の Timestamp のように見える値（秒・ナノ秒・toMillis）。 */
function ts(ms) {
  return { seconds: Math.floor(ms / 1000), nanoseconds: (ms % 1000) * 1e6, toMillis: () => ms };
}

/**
 * follows の記録（窓口が返す形）。id を省くと {followerId}_{followeeId}。
 * @param {unknown} followerId
 * @param {unknown} followeeId
 * @param {{ id?: string, at?: number }} [options]
 */
function follow(followerId, followeeId, { id, at = BEFORE } = {}) {
  return {
    id: id ?? `${followerId}_${followeeId}`,
    followerId,
    followeeId,
    createTime: ts(at),
    updateTime: ts(at + 1),
    data: { followerId, followeeId, createdAt: ts(at) },
  };
}

/** 項目が欠けた follows の記録（fields に無い項目は undefined のまま）。 */
function broken(id, fields, { at = BEFORE } = {}) {
  return {
    id,
    followerId: fields.followerId,
    followeeId: fields.followeeId,
    createTime: ts(at),
    updateTime: ts(at + 1),
    data: { ...fields },
  };
}

const user = (id, blockedUserIds) => ({ id, blockedUserIds });

/** 記録の配列を、文書 ID の昇順の配列にする。 */
const ids = (records) => records.map((r) => r.id).sort();

/** どれかの区分に入った文書 ID（重複を含む）。 */
const categorized = (result) => Object.values(result.categories).flat().map((r) => r.id).sort();

function classify(follows, users) {
  return cleanup.classifyFollows(follows, users, { deployedAtMs: B });
}

/**
 * count・delete の下ごしらえ（Emulator のテストと同じ組）。
 * U は X を、V は Y を、W は Q をブロックしている。M1 と M2 はお互いにブロックしている。
 */
function scenario() {
  const users = [user("U", ["X"]), user("M1", ["M2"]), user("M2", ["M1"]), user("V", ["Y"]), user("W", ["Q"])];
  const follows = [
    follow("X", "U"), // 1a-before
    follow("U", "X"), // 1b-before
    follow("M1", "M2"), // 1a-before と 1b-before の両方（重なり）
    follow("A", "C"), // 関係の無い組
    follow("A", "C", { id: "odd-dup" }), // 2a（A_C もある）
    follow("Q", "W", { id: "odd-uniq" }), // 2b（Q_W は無い・W が Q をブロック）
    broken("broken", { followeeId: "C" }), // 3（followerId が無い）
    follow("Y", "V", { at: AFTER }), // 1a-after
    follow("V", "Y", { at: AFTER }), // 1b-after
  ];
  return { users, follows };
}

/**
 * 偽の窓口（createFirestoreStore と同じ 4 つの口）。
 * deletes に消しに行った文書 ID と lastUpdateTime を、calls に呼ばれた口の名前を順に残す。
 * @param {{ follows: Object[], users: Object[], count?: number, deleteResult?: (id: string) => string }} args
 */
function fakeStore({ follows, users, count = follows.length, deleteResult = () => "deleted" }) {
  const deletes = [];
  const calls = [];
  return {
    deletes,
    calls,
    async scanFollows({ full }) {
      calls.push(full ? "scanFollows(full)" : "scanFollows");
      // full でないとき（select で読むとき）は中身を持たない。delete が select で読むと写しが空になる
      return follows.map((f) => (full ? f : { ...f, data: undefined }));
    },
    async scanUsers() {
      calls.push("scanUsers");
      return users;
    },
    async countFollows() {
      calls.push("countFollows");
      return count;
    },
    async deleteFollow(id, lastUpdateTime) {
      calls.push("deleteFollow");
      deletes.push({ id, lastUpdateTime });
      return deleteResult(id);
    },
  };
}

/** os.tmpdir() の下に使い捨てのフォルダを作る（写しの置き場）。 */
function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "d1-follows-test-"));
}

/** 写しの置き場にある JSON を 1 つ読む。無い・2 つ以上なら（TypeError でなく）アサーションで落とす。 */
function readBackup(dir) {
  const files = fs.readdirSync(dir);
  assert.equal(files.length, 1, `写しの JSON が 1 つでない: ${JSON.stringify(files)}`);
  return { file: path.join(dir, files[0]), json: JSON.parse(fs.readFileSync(path.join(dir, files[0]), "utf8")) };
}

const DELETE_ARGS = (backupDir, expect = { "1a-before": 2, "1b-before": 2 }) => ({
  ok: true,
  command: "delete",
  targets: ["1a-before", "1b-before"],
  expect,
  backupDir,
});

function deleteDeps(store, { confirm = async () => true } = {}) {
  return { store, deployedAtMs: B, confirm, nowMs: () => NOW };
}

// MARK: - 台本の作り（本番に繋ぐ口を、テストから触れない形にする）

test("require しただけでは firebase-admin を読み込まない", () => {
  const loaded = Object.keys(require.cache).filter((p) => p.includes(`${path.sep}firebase-admin${path.sep}`));
  assert.deepEqual(loaded, []);
});

test("main は export しない（テストから本番に繋ぐ口を作らない）", () => {
  assert.equal(Object.prototype.hasOwnProperty.call(cleanup, "main"), false);
});

test("接続先は soramoyou-ios に固定する", () => {
  assert.equal(cleanup.EXPECTED_PROJECT_ID, "soramoyou-ios");
});

test("境目の定数は 2026-10-16 06:43（日本時間）", () => {
  assert.equal(cleanup.DEPLOYED_AT_MS, Date.parse("2026-10-16T06:43:00+09:00"));
});

test("消せる区分は今は 1a-before と 1b-before だけ", () => {
  assert.deepEqual([...cleanup.DELETE_TARGETS], ["1a-before", "1b-before"]);
});

test("findEmulatorEnv: 名前が _EMULATOR_HOST で終わり、値が空でないものだけを名前の順に返す", () => {
  const env = {
    FIRESTORE_EMULATOR_HOST: "127.0.0.1:8080",
    FIREBASE_AUTH_EMULATOR_HOST: "127.0.0.1:9099",
    FIREBASE_STORAGE_EMULATOR_HOST: "",
    HOME: "/Users/x",
  };
  assert.deepEqual(cleanup.findEmulatorEnv(env), ["FIREBASE_AUTH_EMULATOR_HOST", "FIRESTORE_EMULATOR_HOST"]);
});

// MARK: - classifyFollows: 1a・1b と deploy の前後

test("関係の無いフォロー（A→C）はどの区分にも入らない", () => {
  assert.deepEqual(categorized(classify([follow("A", "C")], [user("U", ["X"])])), []);
});

test("1a: ブロックされた人 → ブロックした人（X→U）は 1a-before", () => {
  assert.deepEqual(ids(classify([follow("X", "U")], [user("U", ["X"])]).categories["1a-before"]), ["X_U"]);
});

test("1a の X→U は 1b には入らない（片方からのブロック）", () => {
  const r = classify([follow("X", "U")], [user("U", ["X"])]);
  assert.deepEqual(ids(r.categories["1b-before"]), []);
});

test("1b: ブロックした人 → ブロックされた人（U→X）は 1b-before", () => {
  assert.deepEqual(ids(classify([follow("U", "X")], [user("U", ["X"])]).categories["1b-before"]), ["U_X"]);
});

test("1b の U→X は 1a には入らない（片方からのブロック）", () => {
  const r = classify([follow("U", "X")], [user("U", ["X"])]);
  assert.deepEqual(ids(r.categories["1a-before"]), []);
});

test("deploy 後に作られた X→U は 1a-after", () => {
  const r = classify([follow("X", "U", { at: AFTER })], [user("U", ["X"])]);
  assert.deepEqual(ids(r.categories["1a-after"]), ["X_U"]);
});

test("deploy 後に作られた U→X は 1b-after", () => {
  const r = classify([follow("U", "X", { at: AFTER })], [user("U", ["X"])]);
  assert.deepEqual(ids(r.categories["1b-after"]), ["U_X"]);
});

test("境目: ちょうど境目の時刻に作られた文書は deploy 後（消さない側）", () => {
  const r = classify([follow("X", "U", { at: B })], [user("U", ["X"])]);
  assert.deepEqual([ids(r.categories["1a-before"]), ids(r.categories["1a-after"])], [[], ["X_U"]]);
});

test("境目: 1 ミリ秒前に作られた文書は deploy 前", () => {
  const r = classify([follow("X", "U", { at: B - 1 })], [user("U", ["X"])]);
  assert.deepEqual([ids(r.categories["1a-before"]), ids(r.categories["1a-after"])], [["X_U"], []]);
});

test("境目: 1 ミリ秒後に作られた文書は deploy 後", () => {
  const r = classify([follow("X", "U", { at: B + 1 })], [user("U", ["X"])]);
  assert.deepEqual([ids(r.categories["1a-before"]), ids(r.categories["1a-after"])], [[], ["X_U"]]);
});

test("前後の判定は createTime で行い、中の createdAt は使わない", () => {
  // アプリが入れた createdAt は前の時刻だが、Firestore が付けた作成時刻（createTime）は後
  const f = follow("X", "U", { at: AFTER });
  f.data.createdAt = ts(BEFORE);
  f.createdAt = ts(BEFORE);
  const r = classify([f], [user("U", ["X"])]);
  assert.deepEqual(ids(r.categories["1a-after"]), ["X_U"]);
});

// MARK: - classifyFollows: 両方からのブロック（重なり）

test("両方からブロックしている組の文書は 1a にも 1b にも入る", () => {
  const r = classify([follow("M1", "M2")], [user("M1", ["M2"]), user("M2", ["M1"])]);
  assert.deepEqual([ids(r.categories["1a-before"]), ids(r.categories["1b-before"])], [["M1_M2"], ["M1_M2"]]);
});

test("重なり（1a と 1b の両方に入った文書）を deploy の前・後に分けて数える", () => {
  const r = classify(
    [follow("M1", "M2"), follow("M2", "M1", { at: AFTER }), follow("X", "U")],
    [user("M1", ["M2"]), user("M2", ["M1"]), user("U", ["X"])]
  );
  assert.deepEqual(r.overlap, { before: 1, after: 1 });
});

// MARK: - classifyFollows: ID のずれ（2a・2b）

test("2a: ID がずれていて、正しい ID の文書もある（重複）", () => {
  const r = classify([follow("A", "C"), follow("A", "C", { id: "odd" })], []);
  assert.deepEqual(ids(r.categories["2a"]), ["odd"]);
});

test("2a のとき、正しい ID の文書のほうはどの区分にも入らない", () => {
  const r = classify([follow("A", "C"), follow("A", "C", { id: "odd" })], []);
  assert.deepEqual(categorized(r), ["odd"]);
});

test("2b: ID がずれていて、正しい ID の文書は無い", () => {
  const r = classify([follow("A", "C", { id: "odd" })], []);
  assert.deepEqual(ids(r.categories["2b"]), ["odd"]);
});

test("ID がずれた文書は、ブロック済みの組の間でも 1a・1b には入れない", () => {
  const r = classify([follow("X", "U", { id: "odd" })], [user("U", ["X"])]);
  assert.deepEqual([ids(r.categories["1a-before"]), ids(r.categories["2b"])], [[], ["odd"]]);
});

test("ID がずれた文書のうち、ブロック済みの組（どちら向きでも）を数える", () => {
  const r = classify(
    [
      follow("X", "U", { id: "odd1" }), // 2b・ブロックされた人 → ブロックした人
      follow("U", "X", { id: "odd2" }), // 2b・ブロックした人 → ブロックされた人
      follow("A", "C"),
      follow("A", "C", { id: "odd3" }), // 2a・関係の無い組
    ],
    [user("U", ["X"])]
  );
  assert.deepEqual(r.offIdBlocked, { "2a": 0, "2b": 2 });
});

// MARK: - classifyFollows: 項目の欠け・壊れ（3）

test("3: followerId だけ無い", () => {
  const r = classify([broken("bad", { followeeId: "C" })], []);
  assert.deepEqual(ids(r.categories["3-followerId"]), ["bad"]);
});

test("3: followeeId だけ文字列でない（数字）", () => {
  // 文字列でない値を見逃すと、ID「X_123」は `${X}_${123}` と一致して正しい文書に見えてしまう
  const r = classify([broken("X_123", { followerId: "X", followeeId: 123 })], []);
  assert.deepEqual(ids(r.categories["3-followeeId"]), ["X_123"]);
});

test("3: 両方無い", () => {
  const r = classify([broken("bad", {})], []);
  assert.deepEqual(ids(r.categories["3-both"]), ["bad"]);
});

test("3: followerId が空文字", () => {
  const r = classify([broken("_C", { followerId: "", followeeId: "C" })], []);
  assert.deepEqual(ids(r.categories["3-followerId"]), ["_C"]);
});

test("3: followeeId が「/」を含む", () => {
  const r = classify([broken("slash", { followerId: "A", followeeId: "b/c" })], []);
  assert.deepEqual(ids(r.categories["3-followeeId"]), ["slash"]);
});

test("3 の文書は 2a・2b には入れない", () => {
  const r = classify([broken("bad", { followeeId: "C" })], []);
  assert.deepEqual([ids(r.categories["2a"]), ids(r.categories["2b"])], [[], []]);
});

// MARK: - classifyFollows: blockedUserIds を Functions と同じに読む（normalizeBlockedIds）

test("blockedUserIds に自分がいても、自分 → 自分のフォローは 1a・1b に入らない", () => {
  assert.deepEqual(categorized(classify([follow("S", "S")], [user("S", ["S"])])), []);
});

test("blockedUserIds が配列でない（文字列）なら、ブロックしていない扱い", () => {
  assert.deepEqual(categorized(classify([follow("X", "U")], [user("U", "X")])), []);
});

test("blockedUserIds の数字は、同じ綴りの uid とは見なさない", () => {
  assert.deepEqual(categorized(classify([follow("123", "U")], [user("U", [123])])), []);
});

test("blockedUserIds の捨てた値を数える（配列でない・文字列でない／空／「/」・自分・重複）", () => {
  const r = classify(
    [],
    [user("U", ["X", "X", 7, "", "a/b", "U"]), user("W", "not-an-array"), user("Z", undefined), user("N", null)]
  );
  assert.deepEqual(r.dropped, { notArray: 1, invalid: 3, self: 1, duplicate: 1 });
});

test("走査した件数（scanned）は渡した follows の件数", () => {
  const { follows, users } = scenario();
  assert.equal(classify(follows, users).scanned, 9);
});

// MARK: - parseArgs

test("parseArgs: count", () => {
  assert.deepEqual(cleanup.parseArgs(["count"]), { ok: true, command: "count", list: false });
});

test("parseArgs: count --list", () => {
  assert.deepEqual(cleanup.parseArgs(["count", "--list"]), { ok: true, command: "count", list: true });
});

test("parseArgs: delete（--targets・--expect・--backup-dir の 3 つ）", () => {
  assert.deepEqual(
    cleanup.parseArgs([
      "delete",
      "--targets",
      "1a-before,1b-before",
      "--expect",
      "1a-before=3,1b-before=0",
      "--backup-dir",
      "/Users/x/Documents/d1",
    ]),
    {
      ok: true,
      command: "delete",
      targets: ["1a-before", "1b-before"],
      expect: { "1a-before": 3, "1b-before": 0 },
      backupDir: "/Users/x/Documents/d1",
    }
  );
});

test("parseArgs: delete の引数の順番は問わない・区分は 1 つでもよい", () => {
  assert.deepEqual(
    cleanup.parseArgs(["delete", "--backup-dir", "/tmp/d1", "--expect", "1b-before=4", "--targets", "1b-before"]),
    { ok: true, command: "delete", targets: ["1b-before"], expect: { "1b-before": 4 }, backupDir: "/tmp/d1" }
  );
});

/** 使い方のエラー（{ ok: false }）になるべき引数。 */
const BAD_ARGS = [
  ["コマンドが無い", []],
  ["知らないコマンド", ["fix"]],
  ["count の後ろに知らない引数", ["count", "--all"]],
  ["delete に --targets が無い", ["delete", "--expect", "1a-before=1", "--backup-dir", "/tmp/d1"]],
  ["delete に --expect が無い", ["delete", "--targets", "1a-before", "--backup-dir", "/tmp/d1"]],
  ["delete に --backup-dir が無い", ["delete", "--targets", "1a-before", "--expect", "1a-before=1"]],
  ["--targets が空", ["delete", "--targets", "", "--expect", "1a-before=1", "--backup-dir", "/tmp/d1"]],
  ["--targets に知らない区分", ["delete", "--targets", "zz", "--expect", "zz=1", "--backup-dir", "/tmp/d1"]],
  ["--targets に 1b-after（数えるだけの区分）", ["delete", "--targets", "1b-after", "--expect", "1b-after=1", "--backup-dir", "/tmp/d1"]],
  ["--targets に 1a-after（まだ決めていない区分）", ["delete", "--targets", "1a-after", "--expect", "1a-after=1", "--backup-dir", "/tmp/d1"]],
  ["--targets に 2a", ["delete", "--targets", "2a", "--expect", "2a=1", "--backup-dir", "/tmp/d1"]],
  ["--targets に同じ区分が 2 回", ["delete", "--targets", "1a-before,1a-before", "--expect", "1a-before=1", "--backup-dir", "/tmp/d1"]],
  ["--expect の区分が足りない", ["delete", "--targets", "1a-before,1b-before", "--expect", "1a-before=1", "--backup-dir", "/tmp/d1"]],
  ["--expect に --targets に無い区分", ["delete", "--targets", "1a-before", "--expect", "1a-before=1,1b-before=0", "--backup-dir", "/tmp/d1"]],
  ["--expect が数字でない", ["delete", "--targets", "1a-before", "--expect", "1a-before=x", "--backup-dir", "/tmp/d1"]],
  ["--expect が負の数", ["delete", "--targets", "1a-before", "--expect", "1a-before=-1", "--backup-dir", "/tmp/d1"]],
  ["--expect が小数", ["delete", "--targets", "1a-before", "--expect", "1a-before=1.5", "--backup-dir", "/tmp/d1"]],
  ["--expect の値が空", ["delete", "--targets", "1a-before", "--expect", "1a-before=", "--backup-dir", "/tmp/d1"]],
  ["--backup-dir の値が - で始まる（引数の取り違え）", ["delete", "--targets", "1a-before", "--expect", "1a-before=1", "--backup-dir", "--list"]],
  ["同じ引数が 2 回", ["delete", "--targets", "1a-before", "--targets", "1b-before", "--expect", "1a-before=1", "--backup-dir", "/tmp/d1"]],
  ["delete に知らない引数", ["delete", "--targets", "1a-before", "--expect", "1a-before=1", "--backup-dir", "/tmp/d1", "--yes"]],
];

for (const [name, argv] of BAD_ARGS) {
  test(`parseArgs: ${name} → 使い方のエラー`, () => {
    assert.deepEqual(cleanup.parseArgs(argv), { ok: false });
  });
}

// MARK: - cmdCount

/** scenario() を count したときの行（--list なし）。 */
const COUNT_LINES = [
  "境目（deploy の時刻）: 2026-01-01T00:00:00.000Z（日本時間 2026-01-01 09:00:00）",
  "走査した follows: 9 件・follows.count(): 9 件 → 一致",
  "走査した users: 5 人",
  "1a ブロックされた人 → ブロックした人: deploy 前 2 件・deploy 後 1 件",
  "1b ブロックした人 → ブロックされた人: deploy 前 2 件・deploy 後 1 件",
  "  うち重なり 1 件（1a と 1b の両方に数えた＝両方からブロックしている組の文書。deploy 前 1 件・deploy 後 0 件）",
  "2a ID がずれた重複（正しい ID の文書もある）: 1 件（うちブロック済みの組 0 件）",
  "2b ID がずれていて、正しい ID の文書は無い: 1 件（うちブロック済みの組 1 件）",
  "3 項目が欠けた・壊れた: followerId だけ 1 件・followeeId だけ 0 件・両方 0 件",
  "blockedUserIds の捨てた値: 配列でない 0 人・文字列でない／空／「/」を含む 0 件・自分自身 0 件・重複 0 件",
];

test("count: 区分ごとの件数・重なり・完全性を出す", async () => {
  const { follows, users } = scenario();
  const out = await cleanup.cmdCount({ store: fakeStore({ follows, users }), deployedAtMs: B }, { list: false });
  assert.deepEqual(out.lines, COUNT_LINES);
});

test("count: 完全性が一致すれば終了コード 0", async () => {
  const { follows, users } = scenario();
  const out = await cleanup.cmdCount({ store: fakeStore({ follows, users }), deployedAtMs: B }, { list: false });
  assert.equal(out.exitCode, 0);
});

test("count: 走査した件数と follows.count() が違えば、一致しないと出して終了コード 1", async () => {
  const { follows, users } = scenario();
  const out = await cleanup.cmdCount({ store: fakeStore({ follows, users, count: 10 }), deployedAtMs: B }, { list: false });
  assert.deepEqual(
    [out.exitCode, out.lines[1]],
    [1, "走査した follows: 9 件・follows.count(): 10 件 → ❌ 一致しない（読み落としか、走査の間に増減した。もう一度 count を流す）"]
  );
});

test("count: --list が無ければ、文書 ID も uid も出さない", async () => {
  const { follows, users } = scenario();
  const out = await cleanup.cmdCount({ store: fakeStore({ follows, users }), deployedAtMs: B }, { list: false });
  const text = out.lines.join("\n");
  assert.deepEqual(["X_U", "M1_M2", "odd-dup", "broken"].filter((s) => text.includes(s)), []);
});

test("count --list: 区分ごとに文書 ID・uid・作成時刻を並べる", async () => {
  const { follows, users } = scenario();
  const out = await cleanup.cmdCount({ store: fakeStore({ follows, users }), deployedAtMs: B }, { list: true });
  assert.deepEqual(out.lines.slice(COUNT_LINES.length), [
    "一覧（--list）:",
    "  [1a-before] M1_M2  M1 → M2  作成 2025-12-31T23:59:00.000Z",
    "  [1a-before] X_U  X → U  作成 2025-12-31T23:59:00.000Z",
    "  [1a-after] Y_V  Y → V  作成 2026-01-01T00:01:00.000Z",
    "  [1b-before] M1_M2  M1 → M2  作成 2025-12-31T23:59:00.000Z",
    "  [1b-before] U_X  U → X  作成 2025-12-31T23:59:00.000Z",
    "  [1b-after] V_Y  V → Y  作成 2026-01-01T00:01:00.000Z",
    "  [2a] odd-dup  A → C  作成 2025-12-31T23:59:00.000Z",
    "  [2b] odd-uniq  Q → W  作成 2025-12-31T23:59:00.000Z",
    "  [3-followerId] broken  （無い） → C  作成 2025-12-31T23:59:00.000Z",
  ]);
});

test("count --list: ID の形でない値は出さずに「（壊れた値）」と出す", async () => {
  const follows = [follow("ひみつ の名前", "C", { id: "weird" }), broken("ひみつの文書", { followerId: 5, followeeId: "C" })];
  const out = await cleanup.cmdCount({ store: fakeStore({ follows, users: [] }), deployedAtMs: B }, { list: true });
  const text = out.lines.join("\n");
  assert.deepEqual(
    [text.includes("ひみつ"), text.includes("  [2b] weird  （壊れた値） → C"), text.includes("  [3-followerId] （壊れた値）  （壊れた値） → C")],
    [false, true, true]
  );
});

// MARK: - cmdDelete

test("delete: 見込みの件数どおりなら、1a-before と 1b-before の文書だけを消す（重なりは 1 回だけ）", async () => {
  const { follows, users } = scenario();
  const store = fakeStore({ follows, users });
  await cleanup.cmdDelete(deleteDeps(store), DELETE_ARGS(tmpDir()));
  assert.deepEqual(store.deletes.map((d) => d.id).sort(), ["M1_M2", "U_X", "X_U"]);
});

test("delete: 消すときは読んだときの updateTime を lastUpdateTime に渡す", async () => {
  const { follows, users } = scenario();
  const store = fakeStore({ follows, users });
  await cleanup.cmdDelete(deleteDeps(store), DELETE_ARGS(tmpDir()));
  const byId = new Map(follows.map((f) => [f.id, f]));
  // 消した ID も一緒に照らす（1 件も消さない実装が「空と空で一致」して緑にならないように）
  assert.deepEqual(
    store.deletes.map((d) => [d.id, d.lastUpdateTime === byId.get(d.id).updateTime]).sort(),
    [
      ["M1_M2", true],
      ["U_X", true],
      ["X_U", true],
    ]
  );
});

test("delete: 消し終われば件数を出して終了コード 0", async () => {
  const { follows, users } = scenario();
  const out = await cleanup.cmdDelete(deleteDeps(fakeStore({ follows, users })), DELETE_ARGS(tmpDir()));
  assert.deepEqual(
    [out.exitCode, out.lines.includes("消した: 3 件・読んだ後に変わっていたので飛ばした: 0 件・失敗: 0 件")],
    [0, true]
  );
});

test("delete: 消す文書の件数と重なりを出す", async () => {
  const { follows, users } = scenario();
  const out = await cleanup.cmdDelete(deleteDeps(fakeStore({ follows, users })), DELETE_ARGS(tmpDir()));
  assert.ok(
    out.lines.includes("消す文書: 3 件（1a-before 2 件・1b-before 2 件・うち重なり 1 件は 1 回だけ消す）"),
    out.lines.join("\n")
  );
});

test("delete: --expect と今の件数が違えば、何も消さない", async () => {
  const { follows, users } = scenario();
  const store = fakeStore({ follows, users });
  await cleanup.cmdDelete(deleteDeps(store), DELETE_ARGS(tmpDir(), { "1a-before": 1, "1b-before": 2 }));
  assert.deepEqual(store.deletes, []);
});

test("delete: --expect と違えば、違う区分を出して終了コード 1", async () => {
  const { follows, users } = scenario();
  const out = await cleanup.cmdDelete(
    deleteDeps(fakeStore({ follows, users })),
    DELETE_ARGS(tmpDir(), { "1a-before": 1, "1b-before": 2 })
  );
  assert.deepEqual(
    [out.exitCode, out.lines.includes("1a-before: 見込み 1 件・今 2 件 → ❌ 違うので、何も消さずに止めた")],
    [1, true]
  );
});

test("delete: --expect と違えば、写しも書かない", async () => {
  const { follows, users } = scenario();
  const dir = tmpDir();
  await cleanup.cmdDelete(deleteDeps(fakeStore({ follows, users })), DELETE_ARGS(dir, { "1a-before": 1, "1b-before": 2 }));
  assert.deepEqual(fs.readdirSync(dir), []);
});

test("delete: 完全性が一致しなければ、何も消さない", async () => {
  const { follows, users } = scenario();
  const store = fakeStore({ follows, users, count: 10 });
  await cleanup.cmdDelete(deleteDeps(store), DELETE_ARGS(tmpDir()));
  assert.deepEqual(store.deletes, []);
});

test("delete: 完全性が一致しなければ、終了コード 1", async () => {
  const { follows, users } = scenario();
  const out = await cleanup.cmdDelete(deleteDeps(fakeStore({ follows, users, count: 10 })), DELETE_ARGS(tmpDir()));
  assert.equal(out.exitCode, 1);
});

test("delete: 写しの置き場がリポジトリの中なら、何も読まず・消さずに終了コード 1", async () => {
  const { follows, users } = scenario();
  const store = fakeStore({ follows, users });
  const out = await cleanup.cmdDelete(deleteDeps(store), DELETE_ARGS(__dirname));
  assert.deepEqual([out.exitCode, store.calls], [1, []]);
});

test("delete: 写しの置き場がリポジトリの直下そのものでも止める", async () => {
  const { follows, users } = scenario();
  const store = fakeStore({ follows, users });
  const out = await cleanup.cmdDelete(deleteDeps(store), DELETE_ARGS(path.join(__dirname, "..")));
  assert.deepEqual([out.exitCode, store.calls], [1, []]);
});

test("delete: 写しの置き場が無ければ、何も読まず・消さずに終了コード 1", async () => {
  const { follows, users } = scenario();
  const store = fakeStore({ follows, users });
  const out = await cleanup.cmdDelete(deleteDeps(store), DELETE_ARGS(path.join(tmpDir(), "no-such-dir")));
  assert.deepEqual([out.exitCode, store.calls], [1, []]);
});

test("delete: 写しは確認（yes）より前に書く", async () => {
  const { follows, users } = scenario();
  const dir = tmpDir();
  let filesAtConfirm = null;
  const confirm = async () => {
    filesAtConfirm = fs.readdirSync(dir).length;
    return true;
  };
  await cleanup.cmdDelete(deleteDeps(fakeStore({ follows, users }), { confirm }), DELETE_ARGS(dir));
  assert.equal(filesAtConfirm, 1);
});

test("delete: 確認に渡す行に、消す文書の件数と写しの場所が入っている", async () => {
  const { follows, users } = scenario();
  const dir = tmpDir();
  let shown = [];
  const confirm = async (lines) => {
    shown = [...lines];
    return true;
  };
  await cleanup.cmdDelete(deleteDeps(fakeStore({ follows, users }), { confirm }), DELETE_ARGS(dir));
  const text = shown.join("\n");
  assert.deepEqual([text.includes("消す文書: 3 件"), text.includes(dir)], [true, true]);
});

test("delete: 写しには消す文書だけが、文書 ID の順に入る", async () => {
  const { follows, users } = scenario();
  const dir = tmpDir();
  await cleanup.cmdDelete(deleteDeps(fakeStore({ follows, users })), DELETE_ARGS(dir));
  assert.deepEqual(readBackup(dir).json.docs.map((d) => d.id), ["M1_M2", "U_X", "X_U"]);
});

test("delete: 写しには文書の中身を丸ごと・時刻は秒とナノ秒と ISO で入る", async () => {
  const { follows, users } = scenario();
  const dir = tmpDir();
  await cleanup.cmdDelete(deleteDeps(fakeStore({ follows, users })), DELETE_ARGS(dir));
  const entry = readBackup(dir).json.docs.find((d) => d.id === "X_U");
  const time = (ms) => ({ __type: "timestamp", seconds: Math.floor(ms / 1000), nanoseconds: (ms % 1000) * 1e6, iso: new Date(ms).toISOString() });
  assert.deepEqual(entry, {
    id: "X_U",
    categories: ["1a-before"],
    data: { followerId: "X", followeeId: "U", createdAt: time(BEFORE) },
    createTime: time(BEFORE),
    updateTime: time(BEFORE + 1),
  });
});

test("delete: 重なりの文書は、写しに両方の区分を書く", async () => {
  const { follows, users } = scenario();
  const dir = tmpDir();
  await cleanup.cmdDelete(deleteDeps(fakeStore({ follows, users })), DELETE_ARGS(dir));
  assert.deepEqual(readBackup(dir).json.docs.find((d) => d.id === "M1_M2").categories, ["1a-before", "1b-before"]);
});

test("delete: 写しは本人だけが読み書きできる（600）", async () => {
  const { follows, users } = scenario();
  const dir = tmpDir();
  await cleanup.cmdDelete(deleteDeps(fakeStore({ follows, users })), DELETE_ARGS(dir));
  assert.equal(fs.statSync(readBackup(dir).file).mode & 0o777, 0o600);
});

test("delete: 確認で yes でなければ、何も消さない", async () => {
  const { follows, users } = scenario();
  const store = fakeStore({ follows, users });
  await cleanup.cmdDelete(deleteDeps(store, { confirm: async () => false }), DELETE_ARGS(tmpDir()));
  assert.deepEqual(store.deletes, []);
});

test("delete: 読んだ後に変わっていた文書は、飛ばしたと数える", async () => {
  const { follows, users } = scenario();
  const store = fakeStore({ follows, users, deleteResult: (id) => (id === "X_U" ? "changed" : "deleted") });
  const out = await cleanup.cmdDelete(deleteDeps(store), DELETE_ARGS(tmpDir()));
  assert.ok(out.lines.includes("消した: 2 件・読んだ後に変わっていたので飛ばした: 1 件・失敗: 0 件"), out.lines.join("\n"));
});

test("delete: 1 件が失敗しても止めずに残りを消しに行く", async () => {
  const { follows, users } = scenario();
  const deleteResult = (id) => {
    if (id === "M1_M2") throw Object.assign(new Error("unavailable"), { code: 14 });
    return "deleted";
  };
  const store = fakeStore({ follows, users, deleteResult });
  await cleanup.cmdDelete(deleteDeps(store), DELETE_ARGS(tmpDir()));
  assert.deepEqual(store.deletes.map((d) => d.id).sort(), ["M1_M2", "U_X", "X_U"]);
});

test("delete: 失敗が 1 件でもあれば終了コード 1・理由は code だけ（本文は出さない）", async () => {
  const { follows, users } = scenario();
  const deleteResult = (id) => {
    if (id === "M1_M2") throw Object.assign(new Error("/Users/x/secret-key.json"), { code: 14 });
    return "deleted";
  };
  const out = await cleanup.cmdDelete(deleteDeps(fakeStore({ follows, users, deleteResult })), DELETE_ARGS(tmpDir()));
  const text = out.lines.join("\n");
  assert.deepEqual(
    [out.exitCode, text.includes("失敗: 1 件"), text.includes("secret-key"), text.includes("失敗の理由: 14 が 1 件")],
    [1, true, false, true]
  );
});

test("delete: 消すものが無ければ、写しも確認も無しで終了コード 0", async () => {
  const dir = tmpDir();
  let asked = false;
  const confirm = async () => {
    asked = true;
    return true;
  };
  const store = fakeStore({ follows: [follow("A", "C")], users: [user("U", ["X"])] });
  const out = await cleanup.cmdDelete(deleteDeps(store, { confirm }), DELETE_ARGS(dir, { "1a-before": 0, "1b-before": 0 }));
  assert.deepEqual([out.exitCode, asked, fs.readdirSync(dir), store.deletes], [0, false, [], []]);
});

test("delete: 写しのために follows を中身ごと（select なしで）読む", async () => {
  const { follows, users } = scenario();
  const store = fakeStore({ follows, users });
  await cleanup.cmdDelete(deleteDeps(store), DELETE_ARGS(tmpDir()));
  assert.equal(store.calls[0], "scanFollows(full)");
});
