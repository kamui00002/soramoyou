//
// set-soratomo-beta-claim.js の単体テスト（node:test・firebase-admin 非依存）☁️
//
// 実行: node --test scripts/set-soratomo-beta-claim.test.js
//
// クレームの合成・引数の読み方・出力の形・読み返しの照合だけを確かめる（本番には触れない）。
// 本番での実行は tasks 9.2（ユーザーの GO を取ってから）。
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const claim = require("./set-soratomo-beta-claim");

// MARK: - mergeSoratomoClaim

test("mergeSoratomoClaim: 付与は既存のクレームを残したまま soratomoBeta だけを足す", () => {
  const existing = { skyMotionBeta: true, admin: false };
  assert.deepEqual(claim.mergeSoratomoClaim(existing, { revoke: false }), {
    skyMotionBeta: true,
    admin: false,
    soratomoBeta: true,
  });
});

test("mergeSoratomoClaim: 取り消しは soratomoBeta だけを消し、ほかは残す", () => {
  const existing = { skyMotionBeta: true, soratomoBeta: true };
  assert.deepEqual(claim.mergeSoratomoClaim(existing, { revoke: true }), { skyMotionBeta: true });
});

test("mergeSoratomoClaim: クレームが無い（null / undefined）利用者にも付与・取り消しできる", () => {
  assert.deepEqual(claim.mergeSoratomoClaim(null, { revoke: false }), { soratomoBeta: true });
  assert.deepEqual(claim.mergeSoratomoClaim(undefined, { revoke: false }), { soratomoBeta: true });
  assert.deepEqual(claim.mergeSoratomoClaim(null, { revoke: true }), {});
});

test("mergeSoratomoClaim: 付与済みの人への付与・未付与の人への取り消しは、内容が変わらない", () => {
  assert.deepEqual(claim.mergeSoratomoClaim({ soratomoBeta: true, x: 1 }, { revoke: false }), { soratomoBeta: true, x: 1 });
  assert.deepEqual(claim.mergeSoratomoClaim({ x: 1 }, { revoke: true }), { x: 1 });
});

test("mergeSoratomoClaim: soratomoBeta が true 以外の値で入っていても、付与で true にする", () => {
  assert.deepEqual(claim.mergeSoratomoClaim({ soratomoBeta: "yes" }, { revoke: false }), { soratomoBeta: true });
});

test("mergeSoratomoClaim: 渡したオブジェクトを書き換えない", () => {
  const existing = Object.freeze({ skyMotionBeta: true, soratomoBeta: true });
  claim.mergeSoratomoClaim(existing, { revoke: true });
  claim.mergeSoratomoClaim(existing, { revoke: false });
  assert.deepEqual(existing, { skyMotionBeta: true, soratomoBeta: true });
});

// MARK: - parseArgs

test("parseArgs: 利用者IDだけなら付与", () => {
  assert.deepEqual(claim.parseArgs(["uid-1"]), { ok: true, uid: "uid-1", revoke: false });
});

test("parseArgs: --revoke は前後どちらに置いても取り消し", () => {
  assert.deepEqual(claim.parseArgs(["uid-1", "--revoke"]), { ok: true, uid: "uid-1", revoke: true });
  assert.deepEqual(claim.parseArgs(["--revoke", "uid-1"]), { ok: true, uid: "uid-1", revoke: true });
});

test("parseArgs: 利用者IDが無い・2つ以上・知らないオプション・空文字は受け付けない", () => {
  // ["--force"] のように知らないオプションだけを渡すと、利用者IDが1つに見える。これも弾く。
  for (const argv of [[], ["--revoke"], ["uid-1", "uid-2"], ["uid-1", "--force"], ["uid-1", "-r"], [""], ["--force"], ["-r", "--revoke"]]) {
    assert.equal(claim.parseArgs(argv).ok, false, JSON.stringify(argv));
  }
});

// MARK: - formatResult（出力）

test("formatResult: 利用者IDとクレームの名前だけを出し、クレームの値は出さない", () => {
  const before = { skyMotionBeta: true, note: "taro@example.com" };
  const after = { skyMotionBeta: true, note: "taro@example.com", soratomoBeta: true };
  const out = claim.formatResult("uid-1", before, after);
  assert.match(out, /uid-1/);
  assert.match(out, /skyMotionBeta/);
  assert.match(out, /soratomoBeta/);
  assert.doesNotMatch(out, /taro@example\.com/, "クレームの値（メールアドレスなど）を出している");
  assert.doesNotMatch(out, /true/, "クレームの値を出している");
});

test("formatResult: 名前は並べ替えて出す（実行のたびに順序が変わらない）・クレームが無ければ（なし）", () => {
  const out = claim.formatResult("uid-1", {}, { zeta: 1, alpha: 2 });
  assert.match(out, /alpha, zeta/);
  assert.match(out, /（なし）/);
});

// MARK: - verifyAfter（読み返しの照合）

test("verifyAfter: 付与後に soratomoBeta が true で、既存のクレームが残っていれば一致", () => {
  assert.equal(claim.verifyAfter({ skyMotionBeta: true }, { skyMotionBeta: true, soratomoBeta: true }, { revoke: false }), true);
});

test("verifyAfter: 既存のクレームが消えていたら不一致（合成しなかった事故を検出する）", () => {
  assert.equal(claim.verifyAfter({ skyMotionBeta: true }, { soratomoBeta: true }, { revoke: false }), false);
});

test("verifyAfter: 既存のクレームの値が変わっていても不一致", () => {
  assert.equal(claim.verifyAfter({ skyMotionBeta: true }, { skyMotionBeta: false, soratomoBeta: true }, { revoke: false }), false);
});

test("verifyAfter: 付与したのに soratomoBeta が無ければ不一致", () => {
  assert.equal(claim.verifyAfter({}, {}, { revoke: false }), false);
});

test("verifyAfter: 取り消し後に soratomoBeta が残っていれば不一致・消えていれば一致", () => {
  assert.equal(claim.verifyAfter({ soratomoBeta: true, x: 1 }, { soratomoBeta: true, x: 1 }, { revoke: true }), false);
  assert.equal(claim.verifyAfter({ soratomoBeta: true, x: 1 }, { x: 1 }, { revoke: true }), true);
});

test("verifyAfter: 読み返したクレームが null でも落ちずに判定する", () => {
  assert.equal(claim.verifyAfter(null, null, { revoke: true }), true);
  assert.equal(claim.verifyAfter(null, null, { revoke: false }), false);
});

// MARK: - 読み込み

test("読み込むだけでは firebase-admin を読まない（テストと引数の確認に依存を持ち込まない）", () => {
  const loaded = Object.keys(require.cache).filter((p) => p.includes(`${require("node:path").sep}firebase-admin${require("node:path").sep}`));
  assert.deepEqual(loaded, []);
});

test("プロジェクトは soramoyou-ios に固定している（ADC の取り違えで別プロジェクトへ書かないため）", () => {
  assert.equal(claim.EXPECTED_PROJECT_ID, "soramoyou-ios");
});
