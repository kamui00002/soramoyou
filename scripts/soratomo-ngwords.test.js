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
