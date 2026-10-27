//
// notificationName.js の単体テスト（node:test = Node標準・新規npm依存なし） ⭐️
// 通知の文で人を呼ぶ形（名前あり＝「○○さん」・名前なし＝「さん」なしの「空が好きなだれか」）を固定する。
//
// 実行: node --test notificationName.test.js
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { FALLBACK_NAME, callName } = require("./notificationName");

test("FALLBACK_NAME: 名前が無い人の呼び方は「空が好きなだれか」（アプリの題と同じ言葉）", () => {
  assert.equal(FALLBACK_NAME, "空が好きなだれか");
});

test("callName: 名前があれば「○○さん」", () => {
  assert.equal(callName("そら"), "そらさん");
});

test("callName: 名前が空文字なら「さん」を付けずに「空が好きなだれか」", () => {
  assert.equal(callName(""), "空が好きなだれか");
});

test("callName: 名前が undefined・null でも「さん」を付けずに「空が好きなだれか」", () => {
  assert.equal(callName(undefined), "空が好きなだれか");
  assert.equal(callName(null), "空が好きなだれか");
});
