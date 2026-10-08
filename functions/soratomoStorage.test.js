//
// soratomoStorage.js のテスト（偽の bucket で回す純粋な単体テスト。エミュレーター不要）⭐️
//
// 実行: cd functions && node --test soratomoStorage.test.js
//
// ここで確かめるのは、ゲートウェイが bucket の API（getFiles・file().delete()）を正しく包んでいること:
//   - 一覧: ページ送り（nextQuery が無くなるまで）・接頭辞と maxResults の渡し方・空の一覧
//   - 削除: 成功は "deleted"・404 は "absent"・それ以外のエラーは投げ直す
//   - 「接頭辞の下を全部消して、消した数を返す」手順に載せたとき、消した数が置いた枚数と一致し、
//     404（一覧の後で消えていたもの）は数から除かれること（design.md: imagesDeleted は実際に消した数）
// 本物の Storage（エミュレーター）に対する確認は soratomoStorage.emulator.test.js。
//
// ⚠️ 偽の bucket は @google-cloud/storage の形（getFiles が [files, nextQuery, apiResponse] を返す・
//    404 は code が数値の 404 のエラー）を真似ている。形の根拠は soratomoStorage.js の冒頭コメントと、
//    エミュレーターのテストでの実測を参照。
//
// ⚠️ package.json の lint / test への登録は tasks 7 で行う。
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const path = require("node:path");

const { createStorageGateway } = require("./soratomoStorage");

// MARK: - 偽物

/**
 * @google-cloud/storage の ApiError に似せたエラー。本物は code が数値で、errors に理由を持つ。
 * @param {number} code HTTP ステータス
 * @param {string} message
 */
function apiError(code, message = `fake error ${code}`) {
  const err = new Error(message);
  err.code = code;
  err.errors = [{ message, domain: "global", reason: code === 404 ? "notFound" : "fake" }];
  return err;
}

/**
 * 偽の bucket。getFiles は接頭辞で絞り、maxResults ごとにページを切って [files, nextQuery, apiResponse] を返す
 * （autoPaginate: false のときの本物と同じ形。最後のページの nextQuery は null）。
 * file(path).delete(opts) は、vanished に入っているパスは 404、failWith にあるパスはそのエラー、それ以外は成功して一覧から消える。
 *
 * @param {object} [config]
 * @param {string[]} [config.names] 置いてあるファイルのパス
 * @param {string[]} [config.vanished] 一覧には出るが、delete すると 404（一覧と削除の間に誰かが消した状況）
 * @param {Record<string, Error>} [config.failWith] パス → delete が投げるエラー
 */
function makeFakeBucket({ names = [], vanished = [], failWith = {} } = {}) {
  const present = new Set(names);
  const gone = new Set(vanished);
  const calls = { getFiles: [], delete: [] };
  return {
    calls,
    present,
    async getFiles(query = {}) {
      calls.getFiles.push(query);
      // pageToken は「直前のページの最後の名前」。続きはそれより後の名前から始まる（本物の一覧も辞書順の位置で続くので、
      // 一覧の途中で読み終えた分を消しても、続きが飛ばない）。
      const matched = [...present]
        .filter((n) => n.startsWith(query.prefix ?? ""))
        .filter((n) => !query.pageToken || n > query.pageToken)
        .sort();
      const size = query.maxResults ?? 1000;
      const page = matched.slice(0, size);
      const nextQuery =
        matched.length > size ? { ...query, pageToken: page[page.length - 1] } : null;
      return [page.map((name) => ({ name })), nextQuery, {}];
    },
    file(filePath) {
      return {
        name: filePath,
        async delete(opts) {
          calls.delete.push({ path: filePath, opts });
          if (failWith[filePath]) throw failWith[filePath];
          if (gone.has(filePath) || !present.has(filePath)) {
            throw apiError(404, `No such object: ${filePath}`);
          }
          present.delete(filePath);
        },
      };
    },
  };
}

/** AsyncIterable を配列に集める。 */
async function collect(iterable) {
  const out = [];
  for await (const item of iterable) out.push(item);
  return out;
}

/**
 * 「接頭辞の下を全部消して、消した数（"deleted" の数）を返す」手順の最小形。
 * 本番では soratomoDeletion.js が同じことを（同時に10件までで）行う。ここではゲートウェイの
 * listFiles → deleteFile を素直に回して、"deleted" を数えるだけにしている（absent は数に入れない）。
 */
async function deleteAllUnder(gateway, prefix) {
  let deleted = 0;
  for await (const name of gateway.listFiles(prefix)) {
    if ((await gateway.deleteFile(name)) === "deleted") deleted += 1;
  }
  return deleted;
}

/** 5 枚（u1 の 2 つの投稿の display / thumb と、u1 の取り残し 1 枚）。 */
const FIVE = [
  "soratomo/g1/u1/s1/display.jpg",
  "soratomo/g1/u1/s1/thumb.jpg",
  "soratomo/g1/u1/s2/display.jpg",
  "soratomo/g1/u1/s2/thumb.jpg",
  "soratomo/g1/u1/orphan/display.jpg",
];

// MARK: - listFiles

test("listFiles: 5件を pageSize 2 で 3 ページに分けて返す偽物から、5件すべてが順に取れる", async () => {
  const bucket = makeFakeBucket({ names: FIVE });
  const gateway = createStorageGateway(bucket, { pageSize: 2 });
  const names = await collect(gateway.listFiles("soratomo/g1/u1/"));
  assert.deepEqual(names, [...FIVE].sort());
  assert.equal(bucket.calls.getFiles.length, 3, "2+2+1 の 3 ページ");
});

test("listFiles: getFiles には autoPaginate:false・接頭辞・maxResults を渡し、続きは nextQuery をそのまま渡す", async () => {
  const bucket = makeFakeBucket({ names: FIVE });
  const gateway = createStorageGateway(bucket, { pageSize: 2 });
  await collect(gateway.listFiles("soratomo/g1/u1/"));
  const [q1, q2, q3] = bucket.calls.getFiles;
  assert.deepEqual(q1, { prefix: "soratomo/g1/u1/", autoPaginate: false, maxResults: 2 });
  const sorted = [...FIVE].sort();
  assert.equal(q2.pageToken, sorted[1], "2 ページ目は 1 ページ目が返した nextQuery");
  assert.equal(q3.pageToken, sorted[3], "3 ページ目は 2 ページ目が返した nextQuery");
  for (const q of [q2, q3]) {
    assert.equal(q.prefix, "soratomo/g1/u1/");
    assert.equal(q.autoPaginate, false);
  }
});

test("listFiles: 取れた分だけ先に返す（全ページを読み切ってから返さない）", async () => {
  const bucket = makeFakeBucket({ names: FIVE });
  const gateway = createStorageGateway(bucket, { pageSize: 2 });
  const it = gateway.listFiles("soratomo/g1/u1/")[Symbol.asyncIterator]();
  await it.next();
  assert.equal(bucket.calls.getFiles.length, 1, "最初の 1 件を取るのに読んだのは 1 ページだけ");
  await it.return();
});

test("listFiles: 該当が無ければ何も返さない（getFiles は 1 回）", async () => {
  const bucket = makeFakeBucket({ names: FIVE });
  const gateway = createStorageGateway(bucket, { pageSize: 2 });
  assert.deepEqual(await collect(gateway.listFiles("soratomo/g9/")), []);
  assert.equal(bucket.calls.getFiles.length, 1);
});

test("listFiles: pageSize を省略したときの既定は 1000（Cloud Storage の一覧の既定と同じ）", async () => {
  const bucket = makeFakeBucket({ names: FIVE });
  const gateway = createStorageGateway(bucket);
  await collect(gateway.listFiles("soratomo/g1/u1/"));
  assert.equal(bucket.calls.getFiles[0].maxResults, 1000);
});

test("listFiles: 空・末尾が / でない接頭辞は拒否する（u1 が u10 を拾う事故と、バケット全体の一覧を防ぐ）", async () => {
  const bucket = makeFakeBucket({ names: FIVE });
  const gateway = createStorageGateway(bucket);
  for (const bad of ["", "soratomo/g1/u1", "soratomo", undefined, null, 123]) {
    await assert.rejects(collect(gateway.listFiles(bad)), TypeError, `拒否されるべき: ${String(bad)}`);
  }
  assert.equal(bucket.calls.getFiles.length, 0, "拒否したときは bucket に触れない");
});

test("createStorageGateway: pageSize が正の整数でなければ作る時点で拒否する", () => {
  const bucket = makeFakeBucket();
  for (const bad of [0, -1, 1.5, "2", NaN]) {
    assert.throws(() => createStorageGateway(bucket, { pageSize: bad }), TypeError, `拒否されるべき: ${String(bad)}`);
  }
});

// MARK: - deleteFile

test("deleteFile: 成功したら \"deleted\"（ignoreNotFound は使わない）", async () => {
  const bucket = makeFakeBucket({ names: FIVE });
  const gateway = createStorageGateway(bucket);
  assert.equal(await gateway.deleteFile(FIVE[0]), "deleted");
  assert.equal(bucket.present.has(FIVE[0]), false);
  assert.equal(bucket.calls.delete.length, 1);
  // ignoreNotFound:true だと本物は 404 でも成功を返し、deleted と absent を区別できなくなる。
  const opts = bucket.calls.delete[0].opts;
  assert.ok(opts === undefined || opts.ignoreNotFound !== true, "ignoreNotFound:true を渡していない");
});

test("deleteFile: 404（code が数値の 404）は \"absent\"", async () => {
  const bucket = makeFakeBucket({ names: [] });
  const gateway = createStorageGateway(bucket);
  assert.equal(await gateway.deleteFile("soratomo/g1/u1/s1/display.jpg"), "absent");
});

test("deleteFile: 403・500・429・code の無いエラーは投げ直す（同じエラーのまま）", async () => {
  const errors = {
    "soratomo/g1/u1/s1/display.jpg": apiError(403, "forbidden"),
    "soratomo/g1/u1/s1/thumb.jpg": apiError(500, "backend error"),
    "soratomo/g1/u1/s2/display.jpg": apiError(429, "too many requests"),
    "soratomo/g1/u1/s2/thumb.jpg": new Error("socket hang up"),
  };
  const bucket = makeFakeBucket({ names: Object.keys(errors), failWith: errors });
  const gateway = createStorageGateway(bucket);
  for (const [filePath, err] of Object.entries(errors)) {
    await assert.rejects(
      gateway.deleteFile(filePath),
      (thrown) => {
        assert.equal(thrown, err, "握りつぶさず、同じエラーを投げ直す");
        return true;
      },
      filePath
    );
  }
});

test("deleteFile: code が文字列の \"404\" は 404 とみなさない（本物のライブラリの判定 err.code === 404 と同じ）", async () => {
  const err = new Error("string code");
  err.code = "404";
  const bucket = makeFakeBucket({ names: ["a/b.jpg"], failWith: { "a/b.jpg": err } });
  const gateway = createStorageGateway(bucket);
  await assert.rejects(gateway.deleteFile("a/b.jpg"), (thrown) => thrown === err);
});

test("deleteFile: 空のパスは拒否する", async () => {
  const bucket = makeFakeBucket();
  const gateway = createStorageGateway(bucket);
  for (const bad of ["", undefined, null, 1]) {
    await assert.rejects(gateway.deleteFile(bad), TypeError);
  }
  assert.equal(bucket.calls.delete.length, 0);
});

// MARK: - 一覧 → 削除の手順に載せる（消した数）

test("接頭辞の下を全部消すと、\"deleted\" の数が置いた枚数と一致し、もう一度一覧すると空", async () => {
  const bucket = makeFakeBucket({ names: [...FIVE, "soratomo/g1/u2/s1/display.jpg"] });
  const gateway = createStorageGateway(bucket, { pageSize: 2 });
  const deleted = await deleteAllUnder(gateway, "soratomo/g1/u1/");
  assert.equal(deleted, FIVE.length);
  assert.deepEqual(await collect(gateway.listFiles("soratomo/g1/u1/")), []);
  assert.deepEqual([...bucket.present], ["soratomo/g1/u2/s1/display.jpg"], "ほかの人の分は残る");
});

test("404 が混じると、その分は消した数から除かれる（一覧の後で消えていた 2 枚）", async () => {
  const vanished = [FIVE[1], FIVE[3]];
  const bucket = makeFakeBucket({ names: FIVE, vanished });
  const gateway = createStorageGateway(bucket, { pageSize: 2 });
  const deleted = await deleteAllUnder(gateway, "soratomo/g1/u1/");
  assert.equal(deleted, FIVE.length - vanished.length);
});

test("2 回目の実行は 0 枚（冪等）", async () => {
  const bucket = makeFakeBucket({ names: FIVE });
  const gateway = createStorageGateway(bucket, { pageSize: 2 });
  assert.equal(await deleteAllUnder(gateway, "soratomo/g1/u1/"), FIVE.length);
  assert.equal(await deleteAllUnder(gateway, "soratomo/g1/u1/"), 0);
});

// MARK: - 読み込みの副作用

test("require しただけで firebase-admin を読み込まず、bucket 省略で作っても使うまで触らない", () => {
  // 別プロセスで確かめる（このテストプロセスは他のテストが何を読んだか分からないため）。
  const here = path.join(__dirname, "soratomoStorage.js");
  const script = `
    const m = require(${JSON.stringify(here)});
    const afterRequire = Object.keys(require.cache).filter((k) => k.includes("firebase-admin"));
    m.createStorageGateway();
    const afterCreate = Object.keys(require.cache).filter((k) => k.includes("firebase-admin"));
    process.stdout.write(JSON.stringify({ afterRequire, afterCreate }));
  `;
  const out = JSON.parse(execFileSync(process.execPath, ["-e", script], { encoding: "utf8" }));
  assert.deepEqual(out.afterRequire, [], "require しただけでは firebase-admin を読まない");
  assert.deepEqual(out.afterCreate, [], "bucket 省略で作っただけでも firebase-admin を読まない");
});
