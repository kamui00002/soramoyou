//
// skyMotionCore.js の単体テスト（node:test = Node標準・新規npm依存なし）。
// firebase-admin/firebase-functions には一切触れない（純粋関数のみ検証）。
//
// 実行: node --test skyMotionCore.test.js
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const core = require("./skyMotionCore");

// ============================================================
// jstDateString
// ============================================================

test("jstDateString: UTC日付をまたぐJST変換（UTC 15:00 = JST翌 0:00）", () => {
  // 2026-07-21T15:00:00Z は JST 2026-07-22T00:00:00
  const d = new Date("2026-07-21T15:00:00Z");
  assert.equal(core.jstDateString(d), "2026-07-22");
});

test("jstDateString: JST日付が変わらない時刻（UTC 14:59）", () => {
  const d = new Date("2026-07-21T14:59:00Z");
  assert.equal(core.jstDateString(d), "2026-07-21");
});

// ============================================================
// decideReservation（予約 = reserve-on-create）
// ============================================================

test("decideReservation: usageドキュメントが存在しない（初回利用）→ 予約可・count=1", () => {
  const result = core.decideReservation(null, "2026-07-22", 3);
  assert.deepEqual(result, { allowed: true, day: "2026-07-22", reservedCount: 1 });
});

test("decideReservation: 同日で上限未満 → 予約可・count+1", () => {
  const usage = { day: "2026-07-22", reservedCount: 1 };
  const result = core.decideReservation(usage, "2026-07-22", 3);
  assert.deepEqual(result, { allowed: true, day: "2026-07-22", reservedCount: 2 });
});

test("decideReservation: 同日で上限到達 → 予約不可（fal未呼び出し=非課金）", () => {
  const usage = { day: "2026-07-22", reservedCount: 3 };
  const result = core.decideReservation(usage, "2026-07-22", 3);
  assert.deepEqual(result, { allowed: false, day: "2026-07-22", reservedCount: 3 });
});

test("decideReservation: 日付が変わっている（lazy reset）→ 0から予約可", () => {
  const usage = { day: "2026-07-21", reservedCount: 3 }; // 前日は上限到達していた
  const result = core.decideReservation(usage, "2026-07-22", 3);
  assert.deepEqual(result, { allowed: true, day: "2026-07-22", reservedCount: 1 });
});

test("decideReservation: 既定の上限(DAILY_LIMIT=3)が使われる", () => {
  const usage = { day: "2026-07-22", reservedCount: 3 };
  const result = core.decideReservation(usage, "2026-07-22");
  assert.equal(result.allowed, false);
});

// ============================================================
// decideRefund（返金 = refund-on-failure）
// ============================================================

test("decideRefund: 同日ならcount-1（成功時は呼ばれない前提）", () => {
  const usage = { day: "2026-07-22", reservedCount: 2 };
  const result = core.decideRefund(usage, "2026-07-22");
  assert.deepEqual(result, { day: "2026-07-22", reservedCount: 1 });
});

test("decideRefund: count=0を下回らない（0未満防止）", () => {
  const usage = { day: "2026-07-22", reservedCount: 0 };
  const result = core.decideRefund(usage, "2026-07-22");
  assert.deepEqual(result, { day: "2026-07-22", reservedCount: 0 });
});

test("decideRefund: 予約後に日付が変わっていた（lazy reset）→ 二重適用にならず0のまま", () => {
  const usage = { day: "2026-07-21", reservedCount: 1 };
  const result = core.decideRefund(usage, "2026-07-22");
  assert.deepEqual(result, { day: "2026-07-22", reservedCount: 0 });
});

// ============================================================
// buildFalRequestPayload
// ============================================================

test("buildFalRequestPayload: マスク一式が揃っている場合、極性通りに組み立てる", () => {
  const trajectory = [{ x: 100, y: 200 }, { x: 140, y: 200 }];
  const payload = core.buildFalRequestPayload({
    imageUrl: "https://example.com/source.jpg",
    aspectRatio: "16:9",
    groundMaskUrl: "https://example.com/ground_mask.png",
    skyMaskUrl: "https://example.com/sky_mask.png",
    trajectory,
  });
  assert.equal(payload.image_url, "https://example.com/source.jpg");
  assert.equal(payload.aspect_ratio, "16:9");
  assert.equal(payload.duration, core.FAL_DURATION);
  assert.equal(payload.prompt, core.FAL_PROMPT);
  // 極性: static_mask_url=ground_mask（白=地上）, dynamic_masks[0].mask_url=sky_mask（白=空）
  assert.equal(payload.static_mask_url, "https://example.com/ground_mask.png");
  assert.equal(payload.dynamic_masks.length, 1);
  assert.equal(payload.dynamic_masks[0].mask_url, "https://example.com/sky_mask.png");
  assert.deepEqual(payload.dynamic_masks[0].trajectories, trajectory);
});

test("buildFalRequestPayload: マスクが欠けている場合はマスク関連フィールドを省略する", () => {
  const payload = core.buildFalRequestPayload({
    imageUrl: "https://example.com/source.jpg",
    aspectRatio: "1:1",
    groundMaskUrl: null,
    skyMaskUrl: null,
    trajectory: null,
  });
  assert.equal("static_mask_url" in payload, false);
  assert.equal("dynamic_masks" in payload, false);
});

test("buildFalRequestPayload: trajectoryが空配列の場合もマスク関連フィールドを省略する", () => {
  const payload = core.buildFalRequestPayload({
    imageUrl: "https://example.com/source.jpg",
    aspectRatio: "9:16",
    groundMaskUrl: "https://example.com/ground_mask.png",
    skyMaskUrl: "https://example.com/sky_mask.png",
    trajectory: [],
  });
  assert.equal("static_mask_url" in payload, false);
  assert.equal("dynamic_masks" in payload, false);
});

// ============================================================
// normalizeFalStatusPayload
// ============================================================

test("normalizeFalStatusPayload: IN_QUEUE → PENDING", () => {
  const result = core.normalizeFalStatusPayload({ status: "IN_QUEUE", queue_position: 2 });
  assert.deepEqual(result, { state: "PENDING" });
});

test("normalizeFalStatusPayload: IN_PROGRESS → PENDING", () => {
  const result = core.normalizeFalStatusPayload({ status: "IN_PROGRESS" });
  assert.deepEqual(result, { state: "PENDING" });
});

test("normalizeFalStatusPayload: COMPLETEDでerror無し → READY（結果取得エンドポイントへ進む）", () => {
  const result = core.normalizeFalStatusPayload({ status: "COMPLETED", metrics: { inference_time: 3.4 } });
  assert.deepEqual(result, { state: "READY" });
});

test("normalizeFalStatusPayload: COMPLETEDでerror/error_typeあり → FAILED", () => {
  const result = core.normalizeFalStatusPayload({
    status: "COMPLETED",
    error: "Request timed out",
    error_type: "request_timeout",
  });
  assert.deepEqual(result, {
    state: "FAILED",
    errorType: "request_timeout",
    errorMessage: "Request timed out",
  });
});

test("normalizeFalStatusPayload: 想定外の形 → UNKNOWN（一時的異常として何もしない）", () => {
  const result = core.normalizeFalStatusPayload({ foo: "bar" });
  assert.deepEqual(result, { state: "UNKNOWN" });
  assert.deepEqual(core.normalizeFalStatusPayload(null), { state: "UNKNOWN" });
});

// ============================================================
// extractVideoUrl
// ============================================================

test("extractVideoUrl: video.urlを取り出す", () => {
  const url = core.extractVideoUrl({ video: { url: "https://cdn.example.com/out.mp4" } });
  assert.equal(url, "https://cdn.example.com/out.mp4");
});

test("extractVideoUrl: video.urlが無ければ例外を投げる", () => {
  assert.throws(() => core.extractVideoUrl({}), /video\.url/);
  assert.throws(() => core.extractVideoUrl(null), /video\.url/);
  assert.throws(() => core.extractVideoUrl({ video: {} }), /video\.url/);
});

// ============================================================
// isPollTimedOut
// ============================================================

test("isPollTimedOut: タイムアウト未満はfalse", () => {
  const created = 1000;
  const now = created + core.POLL_TIMEOUT_MS - 1;
  assert.equal(core.isPollTimedOut(created, now), false);
});

test("isPollTimedOut: タイムアウトちょうど・超過はtrue", () => {
  const created = 1000;
  assert.equal(core.isPollTimedOut(created, created + core.POLL_TIMEOUT_MS), true);
  assert.equal(core.isPollTimedOut(created, created + core.POLL_TIMEOUT_MS + 1), true);
});

test("isPollTimedOut: timeoutMsを明示指定できる", () => {
  assert.equal(core.isPollTimedOut(0, 500, 1000), false);
  assert.equal(core.isPollTimedOut(0, 1000, 1000), true);
});
