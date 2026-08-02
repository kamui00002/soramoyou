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

// ============================================================
// isClaimableJob（at-least-once 再配信対策）
// ============================================================

test("isClaimableJob: status=pending なら claim してよい（初回配信）", () => {
  assert.equal(core.isClaimableJob({ status: "pending" }), true);
});

test("isClaimableJob: status=submitting/submitted/completed/failed は claim不可（処理済み・処理中）", () => {
  assert.equal(core.isClaimableJob({ status: "submitting" }), false);
  assert.equal(core.isClaimableJob({ status: "submitted" }), false);
  assert.equal(core.isClaimableJob({ status: "completed" }), false);
  assert.equal(core.isClaimableJob({ status: "failed" }), false);
});

test("isClaimableJob: jobDataがnull/undefined（ドキュメント消失等）は claim不可", () => {
  assert.equal(core.isClaimableJob(null), false);
  assert.equal(core.isClaimableJob(undefined), false);
});

// ============================================================
// fal status/result URL（2026-07-22 B62B197C 事故の再発防止）
// ============================================================

test("buildFalStatusUrl: 短いアプリ名前空間を使う（フルパスだと405になる）", () => {
  const url = core.buildFalStatusUrl("abc-123");
  // submit のフルパス（.../v1.5/pro/image-to-video）ではなく owner/app まで。
  assert.equal(url, "https://queue.fal.run/fal-ai/kling-video/requests/abc-123/status");
  assert.ok(!url.includes("image-to-video"), "status URL にフルパスが混入してはいけない");
});

test("buildFalResultUrl: 短いアプリ名前空間を使う（/status は付かない）", () => {
  const url = core.buildFalResultUrl("abc-123");
  assert.equal(url, "https://queue.fal.run/fal-ai/kling-video/requests/abc-123");
  assert.ok(!url.includes("image-to-video"), "result URL にフルパスが混入してはいけない");
});

// ============================================================
// isPermanentHttpStatus（恒久エラーは即失敗・2026-07-23 の20分待たせ事故の再発防止）
// ============================================================

test("isPermanentHttpStatus: 4xxは恒久(true)、408/429と5xx/2xxは一時(false)", () => {
  assert.equal(core.isPermanentHttpStatus(422), true, "422 feature_not_supported は恒久");
  assert.equal(core.isPermanentHttpStatus(400), true);
  assert.equal(core.isPermanentHttpStatus(404), true);
  assert.equal(core.isPermanentHttpStatus(403), true);
  assert.equal(core.isPermanentHttpStatus(408), false, "408 Request Timeout は一時");
  assert.equal(core.isPermanentHttpStatus(429), false, "429 Too Many Requests は一時");
  assert.equal(core.isPermanentHttpStatus(500), false, "5xx は一時");
  assert.equal(core.isPermanentHttpStatus(503), false);
  assert.equal(core.isPermanentHttpStatus(200), false);
});

// ============================================================
// fetchWithTimeout（ヘッダー到達後の body スタールも中断できるか）
// 旧実装（手動 controller+clearTimeout）は fetch() 解決＝ヘッダー到達でタイマーを消し、
// その後の body 読み取り（arrayBuffer/json）が無防備で永久ハングしていた（レビュー A）。
// この回帰テストは AbortSignal.timeout 版が body 段でも中断することを検証する。
// ============================================================

const http = require("node:http");

test("fetchWithTimeout: ヘッダー到達後に body が止まっても timeoutMs で中断する", async () => {
  // ヘッダーだけ返して body を送らない（res.end しない）＝body 転送スタールを再現。
  const server = http.createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "application/octet-stream" });
    // 意図的に body を書かず放置。
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;

  // fetchWithTimeout(300ms) → arrayBuffer() を watchdog(2s) と race。
  // 正しく中断されれば ~300ms で reject、旧実装なら arrayBuffer が無限ハングし watchdog が先着。
  const bodyRead = (async () => {
    const res = await core.fetchWithTimeout(url, {}, 300);
    await res.arrayBuffer();
  })();
  bodyRead.catch(() => {}); // race で負けた側の遅延 reject を unhandled にしない

  let watchdogTimer;
  const watchdog = new Promise((_, reject) => {
    watchdogTimer = setTimeout(() => reject(new Error("WATCHDOG")), 2000);
  });

  let abortedInTime = false;
  try {
    await Promise.race([bodyRead, watchdog]);
  } catch (err) {
    // fetchWithTimeout による中断なら WATCHDOG 以外のエラー（TimeoutError 等）になる。
    abortedInTime = err.message !== "WATCHDOG";
  } finally {
    clearTimeout(watchdogTimer);
    server.closeAllConnections?.();
    server.close();
  }

  assert.ok(
    abortedInTime,
    "body スタール時は timeoutMs で reject されるべき（watchdog 先着＝ハング＝A の欠陥が再発）"
  );
});

// ============================================================
// ループ化（スロー係数 / クロスフェード窓）
// ============================================================

test("slowFactorForJob: loopDuration が最優先で使われる", () => {
  assert.equal(core.slowFactorForJob({ loopDuration: "short" }), 1.3);
  assert.equal(core.slowFactorForJob({ loopDuration: "medium" }), 1.5);
  assert.equal(core.slowFactorForJob({ loopDuration: "long" }), 1.7);
});

test("slowFactorForJob: 旧build の loopSpeed も受ける（後方互換）", () => {
  assert.equal(core.slowFactorForJob({ loopSpeed: "fast" }), 1.3);
  assert.equal(core.slowFactorForJob({ loopSpeed: "slow" }), 1.7);
});

test("slowFactorForJob: どちらも無い/未知なら既定値", () => {
  assert.equal(core.slowFactorForJob({}), core.LOOP_SLOW_FACTOR_DEFAULT);
  assert.equal(core.slowFactorForJob({ loopDuration: "unknown" }), core.LOOP_SLOW_FACTOR_DEFAULT);
});

test("スロー係数は全て上限以下（超えると『雲が動いて見えない』に戻る回帰ガード）", () => {
  for (const [key, factor] of Object.entries(core.LOOP_DURATION_FACTORS)) {
    assert.ok(
      factor <= core.LOOP_SLOW_FACTOR_MAX,
      `loopDuration=${key} の係数 ${factor} が上限 ${core.LOOP_SLOW_FACTOR_MAX} を超えている`
        + "（実測: 係数2.3は実機NG『動いてない』/ 係数1.3はOK）"
    );
  }
  for (const [key, factor] of Object.entries(core.LOOP_SPEED_FACTORS)) {
    assert.ok(factor <= core.LOOP_SLOW_FACTOR_MAX, `loopSpeed=${key} の係数 ${factor} が上限超え`);
  }
  assert.ok(core.LOOP_SLOW_FACTOR_DEFAULT <= core.LOOP_SLOW_FACTOR_MAX);
});

test("スロー係数は尺の順序（short < medium < long）を保つ", () => {
  const f = core.LOOP_DURATION_FACTORS;
  assert.ok(f.short < f.medium, "short は medium より短いはず");
  assert.ok(f.medium < f.long, "medium は long より短いはず");
});

test("loopTrimWindows: 先頭と末尾が同じ位置 A(D) に揃う（シームレスの必要条件）", () => {
  const D = 1;
  const L = 6.5;
  const w = core.loopTrimWindows(L, D);
  // 出力の先頭フレーム = body の開始 = A(bodyStart)
  // 出力の末尾フレーム = xi の終端   = A(xiEnd)
  assert.equal(w.bodyStart, w.xiEnd, "先頭と末尾が同じソース位置を指していないとループが飛ぶ");
  assert.equal(w.bodyStart, D);
});

test("loopTrimWindows: body の終端と xo の開始が連続している（つなぎ目に飛びが無い）", () => {
  const w = core.loopTrimWindows(6.5, 1);
  assert.equal(w.bodyEnd, w.xoStart);
});

test("loopTrimWindows: xo は素材の末尾まで使い切る / 出力尺は L-D", () => {
  const L = 6.5;
  const D = 1;
  const w = core.loopTrimWindows(L, D);
  assert.equal(w.xoEnd, L);
  assert.equal(w.outDuration, L - D);
  // 各区間の長さ: body=L-2D, xo=D → 合計 L-D
  assert.ok(Math.abs((w.bodyEnd - w.bodyStart) + (w.xoEnd - w.xoStart) - w.outDuration) < 1e-9);
});

test("loopTrimWindows: 旧実装（body を 0 から取る）に戻していないことの回帰ガード", () => {
  const w = core.loopTrimWindows(6.5, 1);
  assert.notEqual(w.bodyStart, 0,
    "body を A[0,...] から取ると先頭A(0)/末尾A(D)がD秒ズレて巻き戻りが飛ぶ（build83以前のバグ）");
});

test("loopTrimWindows: クロスフェード区間が取れない短さなら null", () => {
  assert.equal(core.loopTrimWindows(2, 1), null);   // L - 2D = 0
  assert.equal(core.loopTrimWindows(1.5, 1), null); // L - 2D < 0
  assert.equal(core.loopTrimWindows(0, 1), null);
  assert.equal(core.loopTrimWindows(6.5, 0), null);
});
