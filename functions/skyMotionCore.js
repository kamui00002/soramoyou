//
// そらもよう Cloud Functions（「空を動かす」β・純粋関数群）
//
// ⚠️ このファイルは firebase-admin / firebase-functions を一切 require しない。
//    `node --test` で単体テストできるようにするための意図的な分離
//    （skyMotion.js 側は getFirestore() 等を呼ぶため、素の import だけで
//    "default Firebase app does not exist" になり単体テストが書けない）。
//
// 契約の一次情報: docs/sky-motion-design.md
//

"use strict";

// ============================================================
// 調整可能な数値定数（design doc §6 と一致させること）
// ============================================================

/** 1日あたりの生成回数上限（livingSkyUsage.reservedCount の上限）。 */
const DAILY_LIMIT = 3;

/** trajectory の水平ドリフト量(px)。クライアント側で既に計算済みの値を
 *  Firestore の job.trajectory に保存して渡してくる想定のため、Functions
 *  側では実際には使わない（クライアントと合わせるための参照用定数）。 */
const DRIFT_PIXELS_RIGHT = 40;

/** ポーリングを打ち切って status="failed" / errorCode="timeout" にするまでの時間(ms)。 */
const POLL_TIMEOUT_MS = 20 * 60 * 1000;

/** fal.ai submit 失敗時の最大リトライ回数（初回 + このリトライ回数まで試す）。 */
const SUBMIT_MAX_RETRIES = 1;

// ============================================================
// fal.ai Kling リクエスト定数（PoC generate.py と同一・変更禁止）
// ============================================================

const FAL_APP_ID = "fal-ai/kling-video/v1.5/pro/image-to-video";
const FAL_QUEUE_BASE_URL = "https://queue.fal.run";
const FAL_PROMPT =
  "Clouds drift slowly and naturally across the sky. The ground, buildings " +
  "and horizon remain completely still. Fixed camera, photorealistic, " +
  "gentle motion.";
const FAL_NEGATIVE_PROMPT = "blur, distort, low quality, camera shake, ground movement, warping";
const FAL_DURATION = "5"; // 秒（APIの型は string enum "5"/"10"）
const FAL_CFG_SCALE = 0.5;

// ============================================================
// 日付（JST lazy reset）
// ============================================================

/**
 * JST（UTC+9・DST無し）の "YYYY-MM-DD" 文字列を返す。
 * @param {Date} [date] 基準日時（省略時は現在時刻）
 * @returns {string}
 */
function jstDateString(date) {
  const base = date instanceof Date ? date : new Date();
  const jst = new Date(base.getTime() + 9 * 60 * 60 * 1000);
  const y = jst.getUTCFullYear();
  const m = String(jst.getUTCMonth() + 1).padStart(2, "0");
  const d = String(jst.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

// ============================================================
// livingSkyUsage 予約・返金（lazy reset）
// ============================================================

/**
 * usage ドキュメントを「当日基準」に正規化する（lazy reset）。
 * day が当日と異なる（または未設定）場合は reservedCount=0 として扱う。
 * @param {{day?: string, reservedCount?: number}|null|undefined} usageData
 * @param {string} todayStr jstDateString() の結果
 * @returns {{day: string, reservedCount: number}}
 */
function applyLazyReset(usageData, todayStr) {
  const sameDay = !!usageData && usageData.day === todayStr;
  const reservedCount = sameDay && typeof usageData.reservedCount === "number"
    ? usageData.reservedCount
    : 0;
  return { day: todayStr, reservedCount };
}

/**
 * 予約可否を判定する（reserve-on-create）。
 * 上限未満なら reservedCount+1 した新しい usage を返す。
 * 上限到達なら allowed=false（呼び出し側は fal.ai を一切呼ばないこと）。
 * @param {{day?: string, reservedCount?: number}|null|undefined} usageData 現在の usage ドキュメント
 * @param {string} todayStr jstDateString() の結果
 * @param {number} [dailyLimit] 既定 DAILY_LIMIT
 * @returns {{allowed: boolean, day: string, reservedCount: number}}
 */
function decideReservation(usageData, todayStr, dailyLimit) {
  const limit = typeof dailyLimit === "number" ? dailyLimit : DAILY_LIMIT;
  const { day, reservedCount } = applyLazyReset(usageData, todayStr);
  if (reservedCount >= limit) {
    return { allowed: false, day, reservedCount };
  }
  return { allowed: true, day, reservedCount: reservedCount + 1 };
}

/**
 * 返金（refund-on-failure）後の usage を計算する。0未満にはならない。
 * 予約時から日付が変わっていた場合でも lazy reset と整合する（新しい日は
 * どのみち reservedCount=0 から始まるため、返金の二重適用にはならない）。
 * @param {{day?: string, reservedCount?: number}|null|undefined} usageData 現在の usage ドキュメント
 * @param {string} todayStr jstDateString() の結果
 * @returns {{day: string, reservedCount: number}}
 */
function decideRefund(usageData, todayStr) {
  const { day, reservedCount } = applyLazyReset(usageData, todayStr);
  return { day, reservedCount: Math.max(0, reservedCount - 1) };
}

// ============================================================
// fal.ai リクエスト組み立て（PoC generate.py の build_arguments と同一仕様）
// ============================================================

/**
 * Kling image-to-video の入力JSONを組み立てる。
 * マスク一式（groundMaskUrl/skyMaskUrl/trajectory）が全部揃っていない場合は
 * 必須フィールドのみのリクエストにする（design doc の極性: static_mask_url=ground_mask
 * （白=地上）、dynamic_masks[0].mask_url=sky_mask（白=空）+ trajectories）。
 * @param {{imageUrl: string, aspectRatio: string, groundMaskUrl?: string|null,
 *          skyMaskUrl?: string|null, trajectory?: Array<{x:number,y:number}>|null}} params
 * @returns {object}
 */
function buildFalRequestPayload(params) {
  const { imageUrl, aspectRatio, groundMaskUrl, skyMaskUrl, trajectory } = params;
  const args = {
    prompt: FAL_PROMPT,
    image_url: imageUrl,
    duration: FAL_DURATION,
    aspect_ratio: aspectRatio,
    negative_prompt: FAL_NEGATIVE_PROMPT,
    cfg_scale: FAL_CFG_SCALE,
  };
  if (groundMaskUrl && skyMaskUrl && Array.isArray(trajectory) && trajectory.length > 0) {
    args.static_mask_url = groundMaskUrl;
    args.dynamic_masks = [{ mask_url: skyMaskUrl, trajectories: trajectory }];
  }
  return args;
}

// ============================================================
// fal.ai 応答パース（キューの状態は IN_QUEUE / IN_PROGRESS / COMPLETED の3種のみ。
// 「失敗」は別ステータス値ではなく COMPLETED + error/error_type というボディで表現される。
// 参照: https://fal.ai/docs/documentation/model-apis/inference/queue
//      https://fal.ai/docs/documentation/model-apis/request-errors ）
// ============================================================

/**
 * GET /requests/{id}/status のレスポンスボディを正規化する。
 * @param {any} payload 200応答のJSONボディ
 * @returns {{state: "PENDING"|"READY"|"FAILED"|"UNKNOWN", errorType?: string|null, errorMessage?: string|null}}
 *   PENDING = IN_QUEUE/IN_PROGRESS（何もしない）
 *   READY   = COMPLETED かつエラー無し（結果取得エンドポイントへ進んでよい）
 *   FAILED  = COMPLETED かつ error/error_type あり（fal側の恒久失敗。refund対象）
 *   UNKNOWN = 想定外の形（ネットワーク不調等の一時的な異常として扱い、何もしない）
 */
function normalizeFalStatusPayload(payload) {
  const status = payload && payload.status;
  if (status === "IN_QUEUE" || status === "IN_PROGRESS") {
    return { state: "PENDING" };
  }
  if (status === "COMPLETED") {
    if (payload.error || payload.error_type) {
      return {
        state: "FAILED",
        errorType: payload.error_type || null,
        errorMessage: payload.error || "fal request failed",
      };
    }
    return { state: "READY" };
  }
  return { state: "UNKNOWN" };
}

/**
 * GET /requests/{id}（結果取得）のレスポンスボディから mp4 の URL を取り出す。
 * @param {any} resultPayload
 * @returns {string} video.url
 * @throws {Error} video.url が無い形の場合
 */
function extractVideoUrl(resultPayload) {
  const url = resultPayload && resultPayload.video && resultPayload.video.url;
  if (!url || typeof url !== "string") {
    throw new Error("fal result payload に video.url がありません");
  }
  return url;
}

/**
 * ジョブ作成からの経過時間がポーリングタイムアウトを超えたか。
 * @param {number} createdAtMillis job.createdAt のミリ秒
 * @param {number} nowMillis 現在時刻のミリ秒
 * @param {number} [timeoutMs] 既定 POLL_TIMEOUT_MS
 * @returns {boolean}
 */
function isPollTimedOut(createdAtMillis, nowMillis, timeoutMs) {
  const limit = typeof timeoutMs === "number" ? timeoutMs : POLL_TIMEOUT_MS;
  return nowMillis - createdAtMillis >= limit;
}

module.exports = {
  DAILY_LIMIT,
  DRIFT_PIXELS_RIGHT,
  POLL_TIMEOUT_MS,
  SUBMIT_MAX_RETRIES,
  FAL_APP_ID,
  FAL_QUEUE_BASE_URL,
  FAL_PROMPT,
  FAL_NEGATIVE_PROMPT,
  FAL_DURATION,
  FAL_CFG_SCALE,
  jstDateString,
  applyLazyReset,
  decideReservation,
  decideRefund,
  buildFalRequestPayload,
  normalizeFalStatusPayload,
  extractVideoUrl,
  isPollTimedOut,
};
