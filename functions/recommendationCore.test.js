//
// recommendationCore.js の単体テスト（node:test = Node標準・新規npm依存なし）。
// firebase-admin/firebase-functions には一切触れない（純粋関数のみ検証）。
//
// 実行: node --test recommendationCore.test.js
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const core = require("./recommendationCore");

// ============================================================
// normalizePostIds
// ============================================================

test("normalizePostIds: 旧データ（フィールド無し）・型違いは空配列", () => {
  assert.deepEqual(core.normalizePostIds(undefined), []);
  assert.deepEqual(core.normalizePostIds(null), []);
  assert.deepEqual(core.normalizePostIds("A"), []);
});

test("normalizePostIds: 重複・空文字・文字列以外を落とし、順番は保つ", () => {
  assert.deepEqual(core.normalizePostIds(["B", "A", "B", "", 3, "C"]), ["B", "A", "C"]);
});

// ============================================================
// addedRecommendationIds
// ============================================================

test("addedRecommendationIds: 新しく入った投稿だけを返す", () => {
  assert.deepEqual(core.addedRecommendationIds(["A"], ["A", "B"]), ["B"]);
});

test("addedRecommendationIds: 初めて選んだとき（更新前にフィールド無し）", () => {
  assert.deepEqual(core.addedRecommendationIds(undefined, ["A"]), ["A"]);
});

test("addedRecommendationIds: 並べ替えだけなら通知しない", () => {
  assert.deepEqual(core.addedRecommendationIds(["A", "B", "C"], ["C", "A", "B"]), []);
});

test("addedRecommendationIds: 外しただけなら通知しない", () => {
  assert.deepEqual(core.addedRecommendationIds(["A", "B"], ["A"]), []);
});

test("addedRecommendationIds: 他フィールドの更新（おすすめ欄が無い）なら通知しない", () => {
  assert.deepEqual(core.addedRecommendationIds(undefined, undefined), []);
});

test("addedRecommendationIds: 入れ替え（外して別の投稿を入れた）は新しい方だけ", () => {
  assert.deepEqual(core.addedRecommendationIds(["A", "B", "C"], ["A", "B", "D"]), ["D"]);
});

test("addedRecommendationIds: 上限を超える配列でも通知は最大件数まで", () => {
  assert.deepEqual(core.addedRecommendationIds([], ["A", "B", "C", "D", "E"]), ["A", "B", "C"]);
  assert.equal(core.MAX_RECOMMENDATIONS, 3);
});

// ============================================================
// noticeId / noticeBody / isAlreadyExistsError
// ============================================================

test("noticeId: おすすめした人と投稿の組で一意", () => {
  assert.equal(core.noticeId("u1", "p1"), "u1_p1");
});

test("noticeBody: 表示名を入れた本文", () => {
  assert.equal(core.noticeBody("そら"), "そらさんがあなたの空を「おすすめの空」に選びました");
});

test("isAlreadyExistsError: Admin SDK の ALREADY_EXISTS（コード 6）を判定できる", () => {
  assert.equal(core.isAlreadyExistsError({ code: 6 }), true);
  assert.equal(core.isAlreadyExistsError({ code: "already-exists" }), true);
  assert.equal(core.isAlreadyExistsError({ code: 7 }), false);
  assert.equal(core.isAlreadyExistsError(undefined), false);
});
