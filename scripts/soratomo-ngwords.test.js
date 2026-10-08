//
// soratomo-ngwords.js の単体テスト（node:test・firebase-admin 非依存）☁️⭐️
//
// 実行: node --test scripts/soratomo-ngwords.test.js
//
// 語のファイルの読み方・書かずに止める条件・リポジトリの中のパスの拒否（シンボリックリンク経由を含む）を確かめる。
// 本番には触れない。語はダミー（「てすとごい」など）だけを使い、実在の語は書かない。
// ファイルはすべて OS の一時ディレクトリに作り、終わったら消す（リポジトリの中には何も作らない）。
// ⚠️ package.json の test への登録は release-gate のタスク 7 で行う。
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const ng = require("./soratomo-ngwords");

// MARK: - 一時ディレクトリ

/** 一時ディレクトリの下に、外のファイル・偽のリポジトリ・偽の worktree・リンクを作る。 */
function makeTree() {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "soratomo-ngwords-test-"));
  const outside = path.join(base, "outside");
  const fakeRepo = path.join(base, "fakeRepo");
  const fakeWorktree = path.join(base, "fakeWorktree");
  const plainRoot = path.join(base, "plainRoot");
  for (const dir of [outside, path.join(fakeRepo, ".git"), path.join(fakeRepo, "sub"), fakeWorktree, plainRoot]) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(path.join(fakeWorktree, ".git"), "gitdir: /somewhere/else\n"); // worktree の .git はファイル
  const write = (p) => {
    fs.writeFileSync(p, "てすとごい\n");
    return p;
  };
  return {
    base,
    outsideFile: write(path.join(outside, "words.txt")),
    repoFile: write(path.join(fakeRepo, "sub", "words.txt")),
    worktreeFile: write(path.join(fakeWorktree, "words.txt")),
    plainRoot,
    plainRootFile: write(path.join(plainRoot, "words.txt")),
    outside,
    fakeRepoSub: path.join(fakeRepo, "sub"),
  };
}

let tree;
test.before(() => {
  tree = makeTree();
});
test.after(() => {
  fs.rmSync(tree.base, { recursive: true, force: true });
});

// MARK: - parseArgs

test("parseArgs: 語のファイル1つと --dry-run だけを受け付ける", () => {
  assert.deepEqual(ng.parseArgs(["words.txt"]), { ok: true, file: "words.txt", dryRun: false });
  assert.deepEqual(ng.parseArgs(["--dry-run", "words.txt"]), { ok: true, file: "words.txt", dryRun: true });
  for (const bad of [[], ["a.txt", "b.txt"], ["--dry-run"], ["-x"], [""], ["a.txt", "--force"]]) {
    assert.deepEqual(ng.parseArgs(bad), { ok: false }, `通ってしまった: ${JSON.stringify(bad)}`);
  }
});

// MARK: - parseWordList

test("parseWordList: 前後の空白（全角・タブ・BOM）を除き、空行・コメント・重複を飛ばす。改行は LF・CRLF・CR", () => {
  const text = [
    "﻿てすとごい", // 先頭の BOM
    "  だみーの語\t",
    "　ダミー２　",
    "",
    "   ",
    "# コメントの行",
    "  # 字下げしたコメント",
    "てすとごい", // 重複
    "だみー#の語", // 途中の # は語の一部
  ].join("\r\n") + "\rさいごの語\n";
  const { words, stats } = ng.parseWordList(text);
  assert.deepEqual(words, ["てすとごい", "だみーの語", "ダミー２", "だみー#の語", "さいごの語"]);
  assert.deepEqual(stats, { lines: 11, blank: 3, comments: 2, duplicates: 1 });
});

test("parseWordList: 正規化は書く前にはかけない（表記の違う語は別の語として残し、照合の側で同一視する）", () => {
  const { words } = ng.parseWordList("てすとごい\nテストゴイ\nＴＥＳＴ\ntest\n");
  assert.deepEqual(words, ["てすとごい", "テストゴイ", "ＴＥＳＴ", "test"]);
  const result = ng.validateWordList(words);
  assert.deepEqual(result, { ok: true, matchable: 2 });
});

// MARK: - validateWordList

test("validateWordList: 0個は書かない・5,000個までは書く・5,001個は書かない", () => {
  assert.deepEqual(ng.validateWordList([]), { ok: false, reason: "empty", count: 0 });
  const many = (n) => Array.from({ length: n }, (_, i) => `だみー${i}`);
  assert.deepEqual(ng.validateWordList(many(ng.MAX_WORDS)), { ok: true, matchable: ng.MAX_WORDS });
  assert.deepEqual(ng.validateWordList(many(ng.MAX_WORDS + 1)), { ok: false, reason: "too_many", count: ng.MAX_WORDS + 1 });
});

test("validateWordList: 正規化すると空白だけになる語があれば、数だけを返して書かない", () => {
  assert.deepEqual(ng.validateWordList(["てすとごい", " ", "　"]), { ok: false, reason: "unusable", count: 2 });
});

test("validateWordList: 置換文字（U+FFFD）や制御文字を含む語は、文字化けとして数だけを返して書かない", () => {
  // 置換文字は、別の文字コードのファイルを UTF-8 として一度読み、保存し直したときに残る。制御文字は UTF-16 などの名残り
  for (const bad of ["てす�と", "だみ\u0000ー", "だみ\u001Fー", "だみ\u007Fー", "だみ\u0085ー", "だみ\u009Fー"]) {
    assert.deepEqual(ng.validateWordList(["てすとごい", bad]), { ok: false, reason: "unusable", count: 1 }, JSON.stringify(bad));
  }
});

// MARK: - readWordFile（文字コード）

/** バイト列を一時ディレクトリのファイルにして、readWordFile で読む。 */
function readBytes(name, bytes) {
  const file = path.join(tree.outside, name);
  fs.writeFileSync(file, bytes);
  return ng.readWordFile(file);
}

test("readWordFile: UTF-8（BOM の有無を問わない）は本文を返す", () => {
  assert.deepEqual(readBytes("utf8.txt", Buffer.from("てすとごい\nだみー\n", "utf8")), { ok: true, text: "てすとごい\nだみー\n" });
  const withBom = readBytes("utf8-bom.txt", Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from("てすとごい\n", "utf8")]));
  assert.equal(withBom.ok, true);
  assert.deepEqual(ng.parseWordList(withBom.text).words, ["てすとごい"]);
});

test("readWordFile: UTF-8 として正しくないバイト列（Shift_JIS・BOM つき UTF-16）は、置き換えずに拒否する", () => {
  // 「てすと」「だみー」の Shift_JIS（82 C4 82 B7 82 C6 / 82 BE 82 DD 81 5B）
  const sjis = Buffer.from([0x82, 0xc4, 0x82, 0xb7, 0x82, 0xc6, 0x0a, 0x82, 0xbe, 0x82, 0xdd, 0x81, 0x5b, 0x0a]);
  assert.deepEqual(readBytes("sjis.txt", sjis), { ok: false, reason: "not_utf8" });
  const utf16le = Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from("てすと\nだみー\n", "utf16le")]);
  assert.deepEqual(readBytes("utf16le-bom.txt", utf16le), { ok: false, reason: "not_utf8" });
  assert.match(ng.describeRejection({ ok: false, reason: "not_utf8" }), /UTF-8/);
});

test("readWordFile→parseWordList→validateWordList: BOM の無い UTF-16 は UTF-8 として読めてしまうが、制御文字で止める", () => {
  // 「て」U+3066 は 66 30（"f0"）になり、改行の 0A 00 が NUL を残す。字の下位バイトが 0x80 未満なら UTF-8 としては
  // 正しいので、読む段では止まらない（「ー」U+30FC の FC のように 0x80 以上を含めば、読む段で not_utf8 になる）。
  // ⚠️ 改行の無い1行だけのファイルは NUL が残らないので見分けられない
  const read = readBytes("utf16le-nobom.txt", Buffer.from("てすと\nだみ\n", "utf16le"));
  assert.equal(read.ok, true);
  const { words } = ng.parseWordList(read.text);
  assert.equal(ng.validateWordList(words).ok, false);
  assert.equal(ng.validateWordList(words).reason, "unusable");
});

test("describeRejection・formatStats: 件数と理由だけで、語の中身を含まない", () => {
  const messages = [
    ng.describeRejection(ng.validateWordList([])),
    ng.describeRejection(ng.validateWordList(["てすとごい", " "])),
    ng.describeRejection({ ok: false, reason: "too_many", count: 5001 }),
    ng.describeRejection({ ok: false, reason: "inside_repository" }),
    ng.formatStats({ lines: 3, blank: 1, comments: 1, duplicates: 0 }, 1),
  ];
  assert.match(messages[1], /1 個/);
  assert.match(messages[2], /5001/);
  assert.equal(messages[4], "読んだ行: 3・空行: 1・コメント: 1・重複: 0・語: 1");
  for (const m of messages) assert.equal(m.includes("てすとごい"), false);
});

// MARK: - checkWordFilePath

test("checkWordFilePath: リポジトリと Git の作業ツリーの外のファイルは通し、実体のパスを返す", () => {
  const result = ng.checkWordFilePath(tree.outsideFile);
  assert.equal(result.ok, true);
  assert.equal(result.realPath, fs.realpathSync(tree.outsideFile));
});

test("checkWordFilePath: このリポジトリの中のファイルは拒否する", () => {
  assert.deepEqual(ng.checkWordFilePath(__filename), { ok: false, reason: "inside_repository" });
  assert.deepEqual(ng.checkWordFilePath(path.join(ng.REPOSITORY_ROOT, "firestore.rules")), {
    ok: false,
    reason: "inside_repository",
  });
});

test("checkWordFilePath: 根に .git の無い場所でも、指定したリポジトリの根の中なら拒否する", () => {
  assert.deepEqual(ng.checkWordFilePath(tree.plainRootFile, { repositoryRoot: tree.plainRoot }), {
    ok: false,
    reason: "inside_repository",
  });
  assert.equal(ng.checkWordFilePath(tree.plainRootFile).ok, true);
});

test("checkWordFilePath: ほかの Git の作業ツリー（.git がディレクトリ・worktree のファイル）の中も拒否する", () => {
  assert.deepEqual(ng.checkWordFilePath(tree.repoFile), { ok: false, reason: "inside_repository" });
  assert.deepEqual(ng.checkWordFilePath(tree.worktreeFile), { ok: false, reason: "inside_repository" });
});

test("checkWordFilePath: 外に置いたシンボリックリンク（ファイル・ディレクトリ）から中を指しても拒否する", () => {
  const fileLink = path.join(tree.outside, "link-to-file.txt");
  const dirLink = path.join(tree.outside, "link-to-dir");
  const repoLink = path.join(tree.outside, "link-to-this-repo.txt");
  fs.symlinkSync(tree.repoFile, fileLink);
  fs.symlinkSync(tree.fakeRepoSub, dirLink, "dir");
  fs.symlinkSync(__filename, repoLink);
  assert.deepEqual(ng.checkWordFilePath(fileLink), { ok: false, reason: "inside_repository" });
  assert.deepEqual(ng.checkWordFilePath(path.join(dirLink, "words.txt")), { ok: false, reason: "inside_repository" });
  assert.deepEqual(ng.checkWordFilePath(repoLink), { ok: false, reason: "inside_repository" });
});

test("checkWordFilePath: 無いパスと、ファイルでないもの（ディレクトリ）は拒否する", () => {
  assert.deepEqual(ng.checkWordFilePath(path.join(tree.outside, "nothing.txt")), { ok: false, reason: "not_found" });
  assert.deepEqual(ng.checkWordFilePath(tree.outside), { ok: false, reason: "not_file" });
});

// MARK: - writeWordList（読み返しの比較。書く経路そのものは soratomo-ngwords.emulator.test.js）

/** 書いたものと違う値を読み返す偽の db。 */
function fakeDbReadingBack(storedWords) {
  const writes = [];
  const ref = {
    set: async (value) => writes.push(value),
    get: async () => ({ get: (key) => (key === "words" ? storedWords : undefined) }),
  };
  return { writes, collection: () => ({ doc: () => ref }) };
}

test("writeWordList: 読み返した語が、数・順・中身のどれか1つでも違えば false", async () => {
  const words = ["てすとごい", "だみー"];
  const ts = () => "SERVER_TIMESTAMP";
  assert.equal(await ng.writeWordList(fakeDbReadingBack(["てすとごい", "だみー"]), words, ts), true);
  for (const stored of [["だみー", "てすとごい"], ["てすとごい"], ["てすとごい", "だみー", "よぶん"], ["てすとごい", "だみ"], undefined, "てすとごい"]) {
    assert.equal(await ng.writeWordList(fakeDbReadingBack(stored), words, ts), false, JSON.stringify(stored));
  }
  // 長さの合う文字列（配列でない値）も false
  assert.equal(await ng.writeWordList(fakeDbReadingBack("てす"), ["て", "す"], ts), false);
  const db = fakeDbReadingBack(words);
  await ng.writeWordList(db, words, ts);
  assert.deepEqual(db.writes, [{ words, updatedAt: "SERVER_TIMESTAMP" }]);
});

// MARK: - 読み込み・固定している接続先（scripts/set-soratomo-beta-claim.test.js と同じ守り）

test("読み込むだけでは firebase-admin を読まない（テストと --dry-run に依存を持ち込まない）", () => {
  const loaded = Object.keys(require.cache).filter((p) => p.includes(`${path.sep}firebase-admin${path.sep}`));
  assert.deepEqual(loaded, []);
});

test("プロジェクトは soramoyou-ios に固定している（ADC の取り違えで別プロジェクトへ書かないため）", () => {
  assert.equal(ng.EXPECTED_PROJECT_ID, "soramoyou-ios");
});

// MARK: - main（--dry-run だけ。Firestore に触れない）

/** main を走らせ、出力と終了コードを集める（process.exitCode は元に戻す）。 */
async function runMain(t, argv) {
  const out = [];
  t.mock.method(console, "log", (...args) => out.push(args.join(" ")));
  t.mock.method(console, "error", (...args) => out.push(args.join(" ")));
  const before = process.exitCode;
  try {
    await ng.main(argv);
    return { out, exitCode: process.exitCode };
  } finally {
    process.exitCode = before;
  }
}

test("main --dry-run: UTF-8 として正しくないファイルは、数える前に止める（語の中身を出さない）", async (t) => {
  const file = path.join(tree.outside, "main-sjis.txt");
  fs.writeFileSync(file, Buffer.from([0x82, 0xc4, 0x82, 0xb7, 0x82, 0xc6, 0x0a]));
  const { out, exitCode } = await runMain(t, [file, "--dry-run"]);
  assert.equal(exitCode, 1);
  assert.deepEqual(out, [ng.describeRejection({ ok: false, reason: "not_utf8" })]);
});

test("main --dry-run: UTF-8 のファイルは数えて、書かずに終わる", async (t) => {
  const { out, exitCode } = await runMain(t, [tree.outsideFile, "--dry-run"]);
  assert.equal(exitCode, undefined);
  assert.equal(out.at(-1), "--dry-run: 書いていない");
  assert.equal(out.join("\n").includes("てすとごい"), false);
});

/**
 * firebase-admin を読もうとしたら、その場で投げる。柵が外れたときに、ネットワークへ出る前（再試行で固まる前）に赤にするため。
 * createRequire の require も Module._load を通る。差し替えはテストの終わりに戻る（t.mock）。
 */
function forbidFirebaseAdmin(t) {
  const Module = require("node:module");
  const original = Module._load;
  t.mock.method(Module, "_load", function load(request, ...rest) {
    if (String(request).startsWith("firebase-admin")) throw new Error("test: firebase-admin を読もうとした（柵が効いていない）");
    return original.call(this, request, ...rest);
  });
}

test("main: エミュレーターを指す環境変数があれば、書く直前で firebase-admin を読まずに止める（名前だけを出す）", async (t) => {
  // 柵が外れても本番へ届かないよう、宛先は閉じたポート・資格情報は存在しないファイルにしておく
  const env = { FIRESTORE_EMULATOR_HOST: "127.0.0.1:9", GOOGLE_APPLICATION_CREDENTIALS: "/nonexistent/soratomo-ngwords-test.json" };
  forbidFirebaseAdmin(t);
  const saved = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
  Object.assign(process.env, env);
  let result;
  try {
    result = await runMain(t, [tree.outsideFile]);
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
  assert.equal(result.exitCode, 1);
  assert.match(result.out.at(-1), /エミュレーター.*FIRESTORE_EMULATOR_HOST$/);
  assert.equal(result.out.join("\n").includes("127.0.0.1"), false);
  assert.deepEqual(Object.keys(require.cache).filter((p) => p.includes(`${path.sep}firebase-admin${path.sep}`)), []);
});

test("main --dry-run: エミュレーターを指す環境変数があっても、Firestore に触れないので数えて終わる", async (t) => {
  const saved = process.env.FIRESTORE_EMULATOR_HOST;
  process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:9";
  try {
    const { out, exitCode } = await runMain(t, [tree.outsideFile, "--dry-run"]);
    assert.equal(exitCode, undefined);
    assert.equal(out.at(-1), "--dry-run: 書いていない");
  } finally {
    if (saved === undefined) delete process.env.FIRESTORE_EMULATOR_HOST;
    else process.env.FIRESTORE_EMULATOR_HOST = saved;
  }
});

test("firebase-admin は functions/ から解決し、素の require（NODE_PATH 頼み）で読まない", () => {
  const { createRequire } = require("node:module");
  const fromFunctions = createRequire(require.resolve("../functions/soratomoNgWords"));
  assert.equal(ng.functionsRequire.resolve("firebase-admin/firestore"), fromFunctions.resolve("firebase-admin/firestore"));
  const source = fs.readFileSync(path.join(__dirname, "soratomo-ngwords.js"), "utf8");
  assert.doesNotMatch(source, /\brequire\(\s*["']firebase-admin/);
});
