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

/** ポーリングを打ち切って status="failed" / errorCode="timeout" にするまでの時間(ms)。 */
const POLL_TIMEOUT_MS = 20 * 60 * 1000;

/** fal.ai submit 失敗時の最大リトライ回数（初回 + このリトライ回数まで試す）。 */
const SUBMIT_MAX_RETRIES = 1;

// ============================================================
// fal.ai Kling リクエスト定数（PoC generate.py と同一・変更禁止）
// ============================================================

const FAL_APP_ID = "fal-ai/kling-video/v1.5/pro/image-to-video";
const FAL_QUEUE_BASE_URL = "https://queue.fal.run";
// ⚠️ fal.ai キューAPIの仕様: submit はモデルのフルパス（FAL_APP_ID）へ POST するが、
//    status/result（GET /requests/{id}/status ・ GET /requests/{id}）は
//    「owner/app」までの短いアプリ名前空間に対して叩かなければならない。
//    フルパスで status/result を叩くと 405 Method Not Allowed になり、fal の完了状態を
//    一度も読めず全ジョブが偽タイムアウトする（2026-07-22 の B62B197C 事故の真因）。
const FAL_STATUS_APP_ID = "fal-ai/kling-video";

/** fal キューの status 問い合わせURL（短いアプリ名前空間を使う）。 */
function buildFalStatusUrl(requestId) {
  return `${FAL_QUEUE_BASE_URL}/${FAL_STATUS_APP_ID}/requests/${requestId}/status`;
}

/** fal キューの result 取得URL（短いアプリ名前空間を使う）。 */
function buildFalResultUrl(requestId) {
  return `${FAL_QUEUE_BASE_URL}/${FAL_STATUS_APP_ID}/requests/${requestId}`;
}

/**
 * タイムアウト付き fetch。timeoutMs を過ぎると TimeoutError で reject する。
 * ⚠️ AbortSignal.timeout を使うのが要点。手動の AbortController+clearTimeout 方式だと
 *    fetch() の解決（＝レスポンスヘッダー到達）時点でタイマーを消してしまい、その後の
 *    body 読み取り（res.json()/res.arrayBuffer()）フェーズが無防備になる
 *    （相手がヘッダーだけ返して body 転送をスタールさせると無限に待つ）。
 *    AbortSignal.timeout はシグナルがレスポンスの生存期間中ずっと有効なため、
 *    body 読み取り中にタイムアウトしても中断できる。Node20 の global 実装を使う。
 * @param {string} url
 * @param {object} [options] fetch のオプション（signal は上書きされる）
 * @param {number} timeoutMs
 * @returns {Promise<Response>}
 */
function fetchWithTimeout(url, options, timeoutMs) {
  return fetch(url, { ...(options || {}), signal: AbortSignal.timeout(timeoutMs) });
}
const FAL_PROMPT =
  "Clouds drift slowly and continuously across the sky in one steady " +
  "direction, flowing smoothly and naturally like a calm river. The ground, " +
  "buildings, utility poles and power lines remain completely still and " +
  "perfectly fixed. Fixed camera, photorealistic, smooth continuous gentle " +
  "motion.";
const FAL_NEGATIVE_PROMPT = "blur, distort, low quality, camera shake, ground movement, warping";
// ⚠️ 必ず "5"。kling-v1.5-pro の Motion Control（static_mask_url + dynamic_masks）は
//    duration="10" だと fal が 422 feature_not_supported を返す（マスクは5秒専用）。
//    2026-07-23 に "10" を試して2件失敗させた実績あり。地上固定に静止マスクを使う限り5秒固定。
const FAL_DURATION = "5"; // 秒（APIの型は string enum "5"/"10"。マスク併用時は "5" のみ）
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
 * submit（fal.aiへのキュー投入）成功からの経過時間がポーリングタイムアウトを超えたか。
 * ⚠️ 基準は job.submittedAt（Cloud Functionsがsubmit成功時に serverTimestamp() で記録）。
 *    job.createdAt（クライアントが作成時に設定）は偽装可能なため使わない。
 * @param {number} startMillis job.submittedAt のミリ秒
 * @param {number} nowMillis 現在時刻のミリ秒
 * @param {number} [timeoutMs] 既定 POLL_TIMEOUT_MS
 * @returns {boolean}
 */
function isPollTimedOut(startMillis, nowMillis, timeoutMs) {
  const limit = typeof timeoutMs === "number" ? timeoutMs : POLL_TIMEOUT_MS;
  return nowMillis - startMillis >= limit;
}

/**
 * HTTPステータスが「恒久的な失敗」（リトライしても無意味）かを判定する。
 * 4xx（クライアントエラー）は基本恒久として即失敗させる。ただし 408(Request Timeout) /
 * 429(Too Many Requests) は一時的なのでリトライ対象に残す。5xx・ネットワーク断は
 * 呼び出し側で別途「一時的異常（タイムアウトまでリトライ）」として扱うため、ここでは false。
 * 例: 422 feature_not_supported（duration=10 でマスク非対応）はこの関数で true になり、
 *     20分リトライせず即 failJob される（2026-07-23 の20分待たせ事故の再発防止）。
 * @param {number} status
 * @returns {boolean}
 */
function isPermanentHttpStatus(status) {
  return status >= 400 && status < 500 && status !== 408 && status !== 429;
}

// ============================================================
// at-least-once 再配信対策（ジョブのclaim可否判定）
// ============================================================

/**
 * onDocumentCreated の at-least-once 再配信で、このジョブをまだ処理してよいか
 * （＝初回配信で、まだ誰も予約・submitを開始していないか）を判定する。
 * status が pending のときだけ claim してよい。呼び出し側（reserveAndClaimJob）は
 * この判定をトランザクション内のライブ読み取りに対して行うことで、固定スナップショット
 * 判定（再配信で無効化される）ではない排他性を保証する。
 * @param {{status?: string}|null|undefined} jobData トランザクション内で読んだ最新の job データ
 * @returns {boolean} true なら claim して処理を進めてよい
 */
function isClaimableJob(jobData) {
  return !!jobData && jobData.status === "pending";
}

// ============================================================
// ループ化（スロー係数 / クロスフェードの切り出し窓）
// ============================================================

/** クロスフェード秒数。ループの継ぎ目を溶かす区間の長さ。 */
const LOOP_XFADE_DURATION = 1;

/**
 * setpts スロー係数の上限。**この値を超えると「雲が動いて見えない」に戻る。**
 *
 * ⚠️ 実測の根拠（同一写真・同一マスクでの対照実験 2026-08-02。
 *    指標＝隣接フレーム平均絶対差×fps・継ぎ目1.2秒を除いた本体中央値）:
 *      - 係数1.3（尺5.64秒）→ 動き量 10.48 …… 実機OK
 *      - 係数2.3（尺10.64秒）→ 動き量  3.04 …… 実機NG「動いてない」
 *    ドリフト量(trajectory)は 44px→63px と**増やしたのに** 3.45倍遅くなった。
 *    ＝ 体感速度を決めているのは trajectory ではなく**この係数**である。
 */
const LOOP_SLOW_FACTOR_MAX = 1.8;

/**
 * client の loopDuration → setpts スロー係数。尺と体感速度の両方がここで決まる。
 * 全て LOOP_SLOW_FACTOR_MAX 以下に収めること（上の実測コメント参照）。
 */
const LOOP_DURATION_FACTORS = { short: 1.3, medium: 1.5, long: 1.7 };
/** 旧 build(79以前) の loopSpeed 後方互換。同じく上限以下に丸めてある。 */
const LOOP_SPEED_FACTORS = { fast: 1.3, normal: 1.5, slow: 1.7 };
/** loopDuration も loopSpeed も無い/未知のジョブのフォールバック。 */
const LOOP_SLOW_FACTOR_DEFAULT = 1.5;

/**
 * ジョブから setpts スロー係数を決める。
 * @param {{loopDuration?: string, loopSpeed?: string}} job
 * @returns {number} setpts 係数
 */
function slowFactorForJob(job) {
  return LOOP_DURATION_FACTORS[job.loopDuration]
    || LOOP_SPEED_FACTORS[job.loopSpeed]
    || LOOP_SLOW_FACTOR_DEFAULT;
}

/**
 * クロスフェードループの切り出し窓を求める（純関数）。
 *
 * 素材 A（長さ L）を、末尾D秒が先頭へ溶ける長さ L-D のループにする。
 *   body = A[D, L-D]  … 先頭は A(D)
 *   xo   = A[L-D, L]  … フェードアウト（body の続きなので連続）
 *   xi   = A[0, D]    … フェードイン（終端で A(D) になる）
 * 結果、出力の**先頭も末尾も A(D)** に揃うのでシームレスに巻き戻る。
 *
 * ⚠️ body を A[0, L-2D] から始めてはいけない（build 83 以前のバグ）。
 *    その場合 先頭=A(0) / 末尾=A(D) となりD秒ぶん巻き戻って見える。
 *    ffmpeg 6.0 実測: 継ぎ目の差分が本体中央値の **15.4倍 → 2.2倍** に改善（2026-08-02）。
 *
 * @param {number} L 素材の長さ（秒）
 * @param {number} D クロスフェード秒数
 * @returns {{bodyStart:number, bodyEnd:number, xoStart:number, xoEnd:number, xiEnd:number, outDuration:number}|null}
 *          クロスフェード区間が取れない短さなら null
 */
function loopTrimWindows(L, D) {
  if (!(L > 0) || !(D > 0) || !(L - 2 * D > 0)) return null;
  return {
    bodyStart: D,
    bodyEnd: L - D,
    xoStart: L - D,
    xoEnd: L,
    xiEnd: D,
    outDuration: L - D,
  };
}

module.exports = {
  LOOP_XFADE_DURATION,
  LOOP_SLOW_FACTOR_MAX,
  LOOP_DURATION_FACTORS,
  LOOP_SPEED_FACTORS,
  LOOP_SLOW_FACTOR_DEFAULT,
  slowFactorForJob,
  loopTrimWindows,
  DAILY_LIMIT,
  POLL_TIMEOUT_MS,
  SUBMIT_MAX_RETRIES,
  FAL_APP_ID,
  FAL_QUEUE_BASE_URL,
  FAL_STATUS_APP_ID,
  buildFalStatusUrl,
  buildFalResultUrl,
  fetchWithTimeout,
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
  isPermanentHttpStatus,
  isClaimableJob,
};
