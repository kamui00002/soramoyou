//
// そらもよう Cloud Functions（「空を動かす」β・フェーズ1a）
//
// トリガー:
//   - onSkyMotionJobCreated  livingSkyJobs/{jobId} (onDocumentCreated)
//       → allowlist(custom claim skyMotionBeta)再検証 → livingSkyUsage/{uid} を予約
//         （+ status="submitting" claim。同一トランザクション） → fal.ai Kling へ submit
//         → status="submitted"（submittedAt記録）
//   - pollSkyMotionJobs      onSchedule（1分毎・maxInstances=1）
//       → status="submitted" のジョブを fal.ai に問い合わせ、完了/失敗を反映
//         （タイムアウト判定は submittedAt 基準）
//
// 契約の一次情報: docs/sky-motion-design.md（フィールド名・Storageパス・マスク極性・
// 回数方針はすべてそちらが正）。純粋関数（予約/返金判定・fal応答パース等）は
// skyMotionCore.js に分離し、単体テスト可能にしている（node --test）。
//
// アクセス制御: この機能はDEBUG限定E2E検証用だが、rules/Functions自体は本番デプロイされ
// 全認証ユーザー（匿名認証・セルフサインアップ含む）に開く。そのため custom claim
// `skyMotionBeta==true` の allowlist で締める（firestore.rules/storage.rules で一次防御、
// このファイルの isBetaAllowed() で Admin SDK 経由の多層防御）。本番導線化はしない（design doc §7）。
//
// ⚠️ デプロイ前提:
//   1. `firebase functions:secrets:set FAL_KEY`（対話で fal.ai の API Key を入力）
//   2. Cloud Scheduler API の有効化（onSchedule の初回 deploy で案内される）
//   3. Functions 実行サービスアカウントに Storage 署名付きURL発行権限
//      （IAM ロール「サービス アカウント トークン作成者」/ signBlob 権限）が無いと
//      getSignedUrl() が実行時に失敗する。Admin SDK 初期化だけでは付与されない。
//

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getStorage } = require("firebase-admin/storage");
const { getMessaging } = require("firebase-admin/messaging");
const { getAuth } = require("firebase-admin/auth");

const core = require("./skyMotionCore");

const { execFile } = require("node:child_process");
const os = require("node:os");
const path = require("node:path");
const fsp = require("node:fs/promises");
const ffmpegPath = require("ffmpeg-static");
const ffprobePath = require("ffprobe-static").path;

// initializeApp() は index.js 側で1回だけ実行される（Admin SDK はアプリ単位でシングルトン）。
const db = getFirestore();
const storage = getStorage();
const messaging = getMessaging();
const auth = getAuth();

const FAL_KEY = defineSecret("FAL_KEY");

// 署名付きURLの有効期限（fal.ai がダウンロードし終えるまで十分な余裕を持たせる）。
const SIGNED_URL_EXPIRES_MS = 60 * 60 * 1000; // 1時間

// fal.ai への各 fetch のタイムアウト（ms）。core.fetchWithTimeout に渡す。
// Node20 の global fetch は既定タイムアウトが無く、相手がハングすると無限に待つ。
// maxInstances:1 のポーラーでは1回のハングがインスタンスを占有し続け、以降の周期起動が
// 一切走らなくなる恐れがあるため必ず付ける。合計予算（status+result+動画DL）が関数の
// timeoutSeconds を超えないように pollSkyMotionJobs 側で timeoutSeconds を明示している。
const FAL_API_TIMEOUT_MS = 25 * 1000; // submit / status / result（軽いJSON）
const FAL_VIDEO_TIMEOUT_MS = 50 * 1000; // mp4 ダウンロード（数MB）

// 「約10秒・一方向・継ぎ目なしループ」への変換パラメータ（ローカル実写検証で確定）。
// 2.3倍スロー + minterpolate(補間で滑らかな30fps) → 一方向クロスフェードループ。
const LOOP_SLOW_FACTOR = 2.3; // setpts 係数（5秒素材→約11.5秒スロー）
const LOOP_XFADE_DURATION = 1; // クロスフェード秒数
// ⚠️ minterpolate は重い。子プロセスに独自タイムアウトを設け、超過/失敗時は元の5秒mp4に
//    フォールバックする（関数ごと SIGKILL される「詰まり」を防ぐ＝fetch と同じ設計思想）。
const FFMPEG_TIMEOUT_MS = 90 * 1000;

// ============================================================
// 共通ヘルパー
// ============================================================

/** Storage パスから読み取り用の署名付きURLを発行する。 */
async function getReadSignedUrl(path) {
  const [url] = await storage
    .bucket()
    .file(path)
    .getSignedUrl({ action: "read", expires: Date.now() + SIGNED_URL_EXPIRES_MS });
  return url;
}

/** 無効トークンエラーか（index.js の同名ロジックと同じ判定基準）。 */
function isInvalidTokenError(code) {
  return (
    code === "messaging/registration-token-not-registered" ||
    code === "messaging/invalid-registration-token" ||
    code === "messaging/invalid-argument"
  );
}

/**
 * 単一ユーザーへプッシュ通知を送る（index.js の sendToUser と同じ流儀）。
 * 「空を動かす」の完了/失敗通知専用。fcmToken が無ければ何もしない。
 * 無効トークンは users/{uid}.fcmToken を掃除する。
 */
async function sendSkyMotionNotification(uid, notification, data) {
  const userSnap = await db.collection("users").doc(uid).get();
  const userData = userSnap.exists ? userSnap.data() : null;
  const token = userData && userData.fcmToken;
  if (!token) return;
  try {
    await messaging.send({
      token,
      notification,
      data,
      apns: { payload: { aps: { sound: "default" } } },
    });
  } catch (err) {
    const code = err && err.code;
    if (isInvalidTokenError(code)) {
      await db
        .collection("users")
        .doc(uid)
        .update({ fcmToken: FieldValue.delete() })
        .catch((e) => logger.warn("fcmTokenクリーンアップ失敗", { uid, code: String(e && e.code) }));
    } else {
      logger.error("空を動かす通知の送信に失敗しました", { uid, code: String(code) });
    }
  }
}

/** Firestore Timestamp/Date/数値いずれでもミリ秒に正規化する。 */
function toMillis(value) {
  if (!value) return 0;
  if (typeof value.toMillis === "function") return value.toMillis();
  if (value instanceof Date) return value.getTime();
  if (typeof value === "number") return value;
  return 0;
}

/**
 * uid が「空を動かす」βの allowlist（custom claim `skyMotionBeta==true`）に
 * 入っているかを Admin SDK 経由で最新の状態から確認する（多層防御）。
 * firestore.rules は client がジョブを *作成* した時点のトークンしか見ないため、
 * ここでも独立に確認する（トークンrefresh前のrevoke等をすり抜けさせないため）。
 * 取得自体に失敗した場合は安全側（拒否）に倒す。
 * @param {string} uid
 * @returns {Promise<boolean>}
 */
async function isBetaAllowed(uid) {
  try {
    const userRecord = await auth.getUser(uid);
    return !!(userRecord.customClaims && userRecord.customClaims.skyMotionBeta === true);
  } catch (err) {
    logger.error("空を動かす: allowlist確認（Admin SDK）に失敗しました", { uid, error: err.message });
    return false;
  }
}

/**
 * livingSkyUsage/{uid} の予約と、ジョブの status claim（pending→submitting）を
 * 単一トランザクションで行う。at-least-once 再配信対策を兼ねる: job の最新状態を
 * トランザクション内でライブに読み、pending でなければ何もしない（＝「1ジョブ＝1予約＝
 * 1submit」を保証する。固定スナップショット判定だと再配信時に予約が二重発生しうる）。
 * @param {string} uid
 * @param {FirebaseFirestore.DocumentReference} jobRef
 * @returns {Promise<{claimed: boolean, reserved: boolean}>}
 *   claimed=false             : 既に pending 以外だった（再配信・処理不要。何もしていない）
 *   claimed=true, reserved=false: 上限到達。トランザクション内で status="failed"/
 *                                 errorCode="quota_exceeded" まで書き込み済み（fal.ai未呼び出し=非課金）
 *   claimed=true, reserved=true : 予約成功。status="submitting" まで書き込み済み
 *                                 （呼び出し側は fal.ai へ進んでよい）
 */
async function reserveAndClaimJob(uid, jobRef) {
  const usageRef = db.collection("livingSkyUsage").doc(uid);
  const today = core.jstDateString();
  return db.runTransaction(async (tx) => {
    // Firestoreトランザクションは読み取りが書き込みより先である必要がある。
    // job/usageは独立ドキュメントなので並列に読んでよい。
    const [jobSnap, usageSnap] = await Promise.all([tx.get(jobRef), tx.get(usageRef)]);
    const jobData = jobSnap.exists ? jobSnap.data() : null;
    if (!core.isClaimableJob(jobData)) {
      return { claimed: false, reserved: false };
    }

    const usageData = usageSnap.exists ? usageSnap.data() : null;
    const decision = core.decideReservation(usageData, today);
    if (!decision.allowed) {
      tx.update(jobRef, {
        status: "failed",
        errorCode: "quota_exceeded",
        error: "本日の生成回数の上限に達しました",
        updatedAt: FieldValue.serverTimestamp(),
      });
      return { claimed: true, reserved: false };
    }

    tx.update(jobRef, { status: "submitting", updatedAt: FieldValue.serverTimestamp() });
    tx.set(
      usageRef,
      { day: decision.day, reservedCount: decision.reservedCount, updatedAt: FieldValue.serverTimestamp() },
      { merge: true }
    );
    return { claimed: true, reserved: true };
  });
}

/**
 * ジョブの入力3ファイル（source.jpg/sky_mask.png/ground_mask.png）を削除する
 * （best-effort。個々の削除失敗はログのみでスローしない）。
 * 全ての失敗・quota_exceeded経路（allowlist外・予約失敗・submit失敗・timeout・
 * downstream不可）で呼ぶ。完了経路では completed 確定後に別途呼ぶ（output.mp4は残す）。
 * @param {string} uid
 * @param {string} jobId
 */
async function deleteJobInputFiles(uid, jobId) {
  await Promise.all(
    ["source.jpg", "sky_mask.png", "ground_mask.png"].map((name) =>
      storage
        .bucket()
        .file(`livingSky/${uid}/${jobId}/${name}`)
        .delete()
        .catch((e) => logger.warn("空を動かす: 入力ファイル削除失敗", { jobId, name, error: e.message }))
    )
  );
}

/** livingSkyUsage/{uid} をトランザクションで返金する（refund-on-failure）。 */
async function refundUsage(uid) {
  const usageRef = db.collection("livingSkyUsage").doc(uid);
  const today = core.jstDateString();
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(usageRef);
    const current = snap.exists ? snap.data() : null;
    const decision = core.decideRefund(current, today);
    tx.set(
      usageRef,
      { day: decision.day, reservedCount: decision.reservedCount, updatedAt: FieldValue.serverTimestamp() },
      { merge: true }
    );
  });
}

/** fal.ai へ submit する（成功したら request_id を返す。失敗したら throw する）。 */
async function submitToFal(payload, falKeyValue) {
  const res = await core.fetchWithTimeout(
    `${core.FAL_QUEUE_BASE_URL}/${core.FAL_APP_ID}`,
    {
      method: "POST",
      headers: {
        Authorization: `Key ${falKeyValue}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    },
    FAL_API_TIMEOUT_MS
  );
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    // HTTPエラー応答＝fal はこのリクエストをキュー投入していない（サーバー生成は始まっていない）。
    // この場合に限り再送は安全なので retryableSubmit を立てる（下の submitToFalWithRetry が参照）。
    const err = new Error(`fal submit failed: status=${res.status} body=${body.slice(0, 300)}`);
    err.retryableSubmit = true;
    throw err;
  }
  const json = await res.json();
  if (!json || typeof json.request_id !== "string") {
    throw new Error("fal submit のレスポンスに request_id がありません");
  }
  return json.request_id;
}

/** submit を最大 SUBMIT_MAX_RETRIES 回リトライする（課金前なので安全）。 */
async function submitToFalWithRetry(payload, falKeyValue) {
  let lastError;
  for (let attempt = 0; attempt <= core.SUBMIT_MAX_RETRIES; attempt++) {
    try {
      return await submitToFal(payload, falKeyValue);
    } catch (err) {
      lastError = err;
      logger.warn("fal submit失敗", { attempt, error: err.message, retryable: !!err.retryableSubmit });
      // タイムアウト/ネットワーク断など「fal が受理したか不明」な失敗は再送しない。
      // fal はクライアント中断後もサーバー側の生成を継続しうるため、再POST すると二重投入＝
      // 二重課金になる（codex D-2）。再送してよいのは HTTPエラー応答（!res.ok・retryableSubmit）で
      // fal が明確に受理していない場合のみ。
      if (!err.retryableSubmit) throw err;
    }
  }
  throw lastError;
}

// ============================================================
// A. onSkyMotionJobCreated — livingSkyJobs/{jobId} 作成トリガー
// ============================================================

exports.onSkyMotionJobCreated = onDocumentCreated(
  // timeoutSeconds は既定60sだと署名URL発行＋submit(最大25s)で余裕が乏しいため明示的に広げる。
  // submit の fetch タイムアウト(FAL_API_TIMEOUT_MS=25s)が必ず関数タイムアウトより内側に収まる。
  { document: "livingSkyJobs/{jobId}", secrets: [FAL_KEY], timeoutSeconds: 180 },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) {
      logger.warn("空を動かす: ジョブのスナップショットが空でした");
      return;
    }
    const jobId = event.params.jobId;
    const jobRef = snapshot.ref;
    const job = snapshot.data() || {};

    // 高速パス: 固定スナップショットで明らかに処理済み（再配信）なら、allowlist確認や
    // トランザクション開始前にスキップする（無駄なAPI呼び出しを避ける最適化）。
    // ⚠️ これは非厳密なチェック。実際の排他性保証は reserveAndClaimJob() 内の
    //    トランザクション（ライブ読み取り）で行う。
    if (job.status !== "pending") {
      logger.info("空を動かす: 既に処理済みのためスキップ（再配信・高速パス）", { jobId, status: job.status });
      return;
    }

    const uid = job.userId;
    if (!uid) {
      logger.error("空を動かす: userId が無いジョブです", { jobId });
      return;
    }

    // --- 0. allowlist再検証（多層防御。firestore.rules は create 時点のトークンしか
    //     見ないため、Admin SDK で最新の custom claims を取り直して確認する） ---
    const allowed = await isBetaAllowed(uid);
    if (!allowed) {
      await jobRef.update({
        status: "failed",
        errorCode: "forbidden",
        error: "この機能は許可されたユーザーのみ利用できます",
        updatedAt: FieldValue.serverTimestamp(),
      });
      await deleteJobInputFiles(uid, jobId);
      logger.warn("空を動かす: allowlist外のためスキップ（非課金）", { jobId, uid });
      return;
    }

    // --- 1. 予約 + status claim（pending→submitting）を単一トランザクションで実施。
    //     上限到達なら fal.ai を一切呼ばない（非課金）。既に処理済み（再配信）なら
    //     トランザクション内で何もしない。 ---
    const claim = await reserveAndClaimJob(uid, jobRef);
    if (!claim.claimed) {
      logger.info("空を動かす: 既に処理済みのためスキップ（再配信・トランザクション判定）", { jobId, uid });
      return;
    }
    if (!claim.reserved) {
      await deleteJobInputFiles(uid, jobId);
      logger.info("空を動かす: 上限到達のためスキップ（非課金）", { jobId, uid });
      return;
    }

    try {
      // --- 2. Storage 3ファイルの署名付きURLを発行 ---
      const [imageUrl, skyMaskUrl, groundMaskUrl] = await Promise.all([
        getReadSignedUrl(job.sourcePath),
        getReadSignedUrl(job.skyMaskPath),
        getReadSignedUrl(job.groundMaskPath),
      ]);

      const payload = core.buildFalRequestPayload({
        imageUrl,
        aspectRatio: job.aspectRatio,
        groundMaskUrl,
        skyMaskUrl,
        trajectory: job.trajectory,
      });

      // --- 3. fal.ai Kling キューへ submit（失敗時は最大1回リトライ） ---
      const falRequestId = await submitToFalWithRetry(payload, FAL_KEY.value());

      // --- 4a. submit成功 ---
      await jobRef.update({
        status: "submitted",
        falRequestId,
        submittedAt: FieldValue.serverTimestamp(),
        pollAttempts: 0,
        updatedAt: FieldValue.serverTimestamp(),
      });
      logger.info("空を動かす: submit成功", { jobId, uid, falRequestId });
    } catch (err) {
      // --- 4b. submit失敗（リトライも失敗）→ 予約返金・入力ファイル削除・失敗通知 ---
      logger.error("空を動かす: submit失敗（リトライも失敗）", { jobId, uid, error: err.message });
      await failJob(jobRef, uid, "submit_failed", err.message);
    }
  }
);

// ============================================================
// シームレスループ変換（ffmpeg / ffprobe を子プロセスで実行）
// ============================================================

/** ffprobe で動画の尺（秒）を返す。 */
function probeDuration(file) {
  return new Promise((resolve, reject) => {
    execFile(
      ffprobePath,
      ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file],
      { timeout: 15000 },
      (err, stdout) => (err ? reject(err) : resolve(parseFloat(String(stdout).trim())))
    );
  });
}

/** ffmpeg を子プロセスで実行する（FFMPEG_TIMEOUT_MS 超過で kill＝reject＝呼び出し側でフォールバック）。 */
function runFfmpeg(args) {
  return new Promise((resolve, reject) => {
    execFile(
      ffmpegPath,
      args,
      { timeout: FFMPEG_TIMEOUT_MS, maxBuffer: 16 * 1024 * 1024 },
      (err) => (err ? reject(err) : resolve())
    );
  });
}

/**
 * Kling の5秒mp4を「約10秒・一方向・継ぎ目なしループ」に変換して返す。
 *  1) setpts で 2.3倍スロー + minterpolate で滑らかな30fpsに
 *  2) 一方向クロスフェードループ（末尾を先頭に溶け込ませる。xfade offset は実尺から動的計算）
 * ⚠️ 失敗/タイムアウト時は throw する（呼び出し側が元の5秒mp4で続行＝graceful degrade）。
 * @param {Buffer} inputBuffer 元の mp4
 * @param {string} jobId 一時ファイル名の衝突回避用
 * @returns {Promise<Buffer>} 変換後の mp4
 */
async function makeSeamlessLoop(inputBuffer, jobId) {
  const dir = os.tmpdir();
  const inPath = path.join(dir, `sky_${jobId}_in.mp4`);
  const slowPath = path.join(dir, `sky_${jobId}_slow.mp4`);
  const outPath = path.join(dir, `sky_${jobId}_out.mp4`);
  try {
    await fsp.writeFile(inPath, inputBuffer);

    // 1) スロー + 補間（30fps）。
    //    ⚠️ mi_mode=mci(動き補償) は Cloud Function の弱いCPUで ~0.035x と激遅→90秒で
    //       タイムアウトした（2026-07-23 実測）。mi_mode=blend(フレームブレンド・動き推定なし)は
    //       ~17倍速く、ゆるい雲では十分滑らか。サーバー実行可能なのは blend。
    await runFfmpeg([
      "-y", "-i", inPath,
      "-filter:v",
      `setpts=${LOOP_SLOW_FACTOR}*PTS,minterpolate=fps=30:mi_mode=blend`,
      "-an", "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", slowPath,
    ]);

    // 2) 一方向クロスフェードループ。main=先頭1秒を落とした本体、fade=先頭1秒。
    //    末尾で fade をクロスフェードして先頭へ繋ぐ。xfade offset は「main尺 - D - マージン」で
    //    動的計算（実測: マージン0.067は "Invalid argument"・0.6+で安定）。
    const slowedDur = await probeDuration(slowPath);
    const mainDur = slowedDur - LOOP_XFADE_DURATION; // trim=start=1 後の尺
    const offset = Math.max(0, mainDur - LOOP_XFADE_DURATION - 0.6);
    await runFfmpeg([
      "-y", "-i", slowPath,
      "-filter_complex",
      `[0]trim=start=${LOOP_XFADE_DURATION},setpts=PTS-STARTPTS[main];` +
      `[0]trim=end=${LOOP_XFADE_DURATION},setpts=PTS-STARTPTS[fade];` +
      `[main][fade]xfade=transition=fade:duration=${LOOP_XFADE_DURATION}:offset=${offset.toFixed(2)}[v]`,
      "-map", "[v]", "-an", "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", outPath,
    ]);

    return await fsp.readFile(outPath);
  } finally {
    // 一時ファイルは best-effort で削除（/tmp は tmpfs＝メモリなので放置しない）。
    await Promise.all(
      [inPath, slowPath, outPath].map((p) => fsp.unlink(p).catch(() => {}))
    );
  }
}

// ============================================================
// B. pollSkyMotionJobs — 1分毎に submitted ジョブを確認
// ============================================================

exports.pollSkyMotionJobs = onSchedule(
  // maxInstances: 1 で周期跨ぎの多重起動を防ぐ（簡易排他。完全な per-job lease は公開β送り）。
  // timeoutSeconds/memory は「シームレスループ化(ffmpeg minterpolate)」を賄うため広げる:
  //   - status(25s)+result(25s)+動画DL(50s)+ffmpeg(子プロセス最大90s)+Storage保存 が既定60sを超える。
  //   - minterpolate は ~1GB メモリ + CPU を要するため 4GiB（gen2 は memory 増で vCPU も増える）。
  //   - 各 fetch/ffmpeg の個別タイムアウトは必ずこの関数 timeoutSeconds の内側に収まる。
  //   - maxInstances:1 のため ffmpeg 実行中は次周期が待つが、3回/日 のβ規模では許容。
  {
    schedule: "every 1 minutes",
    secrets: [FAL_KEY],
    maxInstances: 1,
    timeoutSeconds: 300,
    memory: "4GiB",
  },
  async () => {
    const snap = await db
      .collection("livingSkyJobs")
      .where("status", "==", "submitted")
      .orderBy("createdAt", "asc")
      .get();

    if (snap.empty) return;

    const now = Date.now();
    const falKeyValue = FAL_KEY.value();

    // ジョブ間は独立しているため並列に処理する（1分周期の間隔に収めるため）。
    await Promise.all(
      snap.docs.map((doc) => pollOneJob(doc, now, falKeyValue).catch((err) => {
        logger.error("空を動かす: ジョブのポーリング中に予期しないエラー", {
          jobId: doc.id,
          error: err.message,
        });
      }))
    );
  }
);

/** 1件のジョブをポーリングする（1回の実行内でリトライループはしない）。 */
async function pollOneJob(doc, now, falKeyValue) {
  const jobId = doc.id;
  const job = doc.data() || {};
  const jobRef = doc.ref;
  const uid = job.userId;
  const falRequestId = job.falRequestId;

  if (!uid || !falRequestId) {
    logger.error("空を動かす: userId/falRequestId が無いジョブ（データ不整合）", { jobId });
    return;
  }

  // ⚠️ タイムアウト判定は submittedAt（Cloud Functionsがsubmit成功時に記録）基準。
  //    createdAt（client設定・偽装可能）は使わない。
  const submittedAtMillis = toMillis(job.submittedAt);
  const timedOut = submittedAtMillis > 0 && core.isPollTimedOut(submittedAtMillis, now);

  let statusPayload;
  try {
    const res = await core.fetchWithTimeout(
      core.buildFalStatusUrl(falRequestId),
      { headers: { Authorization: `Key ${falKeyValue}` } },
      FAL_API_TIMEOUT_MS
    );
    if (!res.ok) {
      // 4xx（恒久エラー: 400/422/不正リクエスト等）はリトライしても無意味なので即失敗させる
      // （2026-07-23 の「20分待たせて失敗」事故の再発防止）。
      // 5xx等の一時的なdownstream不調はタイムアウト経由の回復（次回周期リトライ）に委ねる。
      if (core.isPermanentHttpStatus(res.status)) {
        await failJob(jobRef, uid, "downstream_unavailable", `poll status 恒久HTTPエラー: ${res.status}`);
      } else if (timedOut) {
        await failJob(jobRef, uid, "timeout", `poll status HTTPエラー: ${res.status}`);
      } else {
        await jobRef.update({ pollAttempts: FieldValue.increment(1) }).catch(() => {});
      }
      return;
    }
    statusPayload = await res.json();
  } catch (err) {
    // fetch自体の失敗（ネットワーク等）も同様に一時的異常として扱う。
    if (timedOut) {
      await failJob(jobRef, uid, "timeout", `poll status取得失敗: ${err.message}`);
    } else {
      await jobRef.update({ pollAttempts: FieldValue.increment(1) }).catch(() => {});
    }
    return;
  }

  const normalized = core.normalizeFalStatusPayload(statusPayload);

  if (normalized.state === "PENDING" || normalized.state === "UNKNOWN") {
    if (timedOut) {
      await failJob(jobRef, uid, "timeout", "20分以内に完了しませんでした");
    } else {
      await jobRef.update({ pollAttempts: FieldValue.increment(1) }).catch(() => {});
    }
    return;
  }

  if (normalized.state === "FAILED") {
    await failJob(
      jobRef,
      uid,
      "downstream_unavailable",
      `${normalized.errorType || "unknown"}: ${normalized.errorMessage}`
    );
    return;
  }

  // normalized.state === "READY" → 結果を取得してStorageへ書き込む。
  // ⚠️ completed巻き戻し防止: ここではまだ status="completed" を確定していないため、
  //    結果取得・mp4ダウンロード・Storage保存のいずれかが失敗しても、タイムアウト超過で
  //    なければ submitted のまま次周期に再試行させる（failedにしない。一時的異常として扱う。
  //    fal側は既にCOMPLETEDなので、再試行時も同じ結果を取得できる想定）。
  let downloadUrl;
  try {
    const resultRes = await core.fetchWithTimeout(
      core.buildFalResultUrl(falRequestId),
      { headers: { Authorization: `Key ${falKeyValue}` } },
      FAL_API_TIMEOUT_MS
    );
    if (!resultRes.ok) {
      const body = await resultRes.text().catch(() => "");
      // 4xx（例: 422 feature_not_supported = duration=10でマスク非対応）は恒久エラー。
      // 20分リトライせず即失敗＋返金する（一時的異常の throw 経路には乗せない）。
      if (core.isPermanentHttpStatus(resultRes.status)) {
        await failJob(
          jobRef, uid, "downstream_unavailable",
          `fal result 恒久エラー: status=${resultRes.status} body=${body.slice(0, 300)}`
        );
        return;
      }
      // 5xx等は一時的異常として throw → 下の catch でリトライ/タイムアウト処理に委ねる。
      throw new Error(`fal result取得失敗: status=${resultRes.status} body=${body.slice(0, 300)}`);
    }
    const resultJson = await resultRes.json();
    const videoUrl = core.extractVideoUrl(resultJson);

    const outputPath = `livingSky/${uid}/${jobId}/output.mp4`;
    const videoRes = await core.fetchWithTimeout(videoUrl, {}, FAL_VIDEO_TIMEOUT_MS);
    if (!videoRes.ok) {
      throw new Error(`mp4ダウンロード失敗: status=${videoRes.status}`);
    }
    let videoBuffer = Buffer.from(await videoRes.arrayBuffer());
    // Kling の5秒素材を「約10秒・一方向・継ぎ目なしループ」に変換する。
    // ⚠️ ffmpeg 失敗/タイムアウト時は詰まらせず、元の5秒mp4で続行する（graceful degrade）。
    try {
      videoBuffer = await makeSeamlessLoop(videoBuffer, jobId);
    } catch (loopErr) {
      logger.warn("空を動かす: シームレスループ化に失敗、元の5秒mp4で続行", {
        jobId,
        error: loopErr.message,
      });
    }
    const file = storage.bucket().file(outputPath);
    await file.save(videoBuffer, { contentType: "video/mp4" });
    const [url] = await file.getSignedUrl({
      action: "read",
      expires: Date.now() + 7 * 24 * 60 * 60 * 1000, // 7日間
    });
    downloadUrl = url;
  } catch (err) {
    logger.error("空を動かす: 結果取得/保存に失敗（一時的異常として扱う）", { jobId, uid, error: err.message });
    if (timedOut) {
      await failJob(jobRef, uid, "downstream_unavailable", err.message);
    } else {
      await jobRef.update({ pollAttempts: FieldValue.increment(1) }).catch(() => {});
    }
    return;
  }

  // --- ここから先で status="completed" を確定する。以降（入力ファイル削除・完了通知）が
  //     失敗しても job を failed に巻き戻さない（terminal状態からの再遷移をしない）。 ---
  await jobRef.update({
    status: "completed",
    videoURL: downloadUrl,
    updatedAt: FieldValue.serverTimestamp(),
  });
  logger.info("空を動かす: 完了", { jobId, uid, falRequestId });

  // 入力3ファイル（source/sky_mask/ground_mask）を削除（output.mp4は残す）。best-effort。
  await deleteJobInputFiles(uid, jobId);

  // 完了プッシュ通知もbest-effort（失敗してもjob状態には影響させない）。
  try {
    await sendSkyMotionNotification(
      uid,
      { title: "そらもよう", body: "空を動かす動画が完成しました" },
      { type: "livingSkyCompleted", jobId }
    );
  } catch (err) {
    logger.warn("空を動かす: 完了通知の送信に失敗しました（job状態には影響しません）", { jobId, uid, error: err.message });
  }
}

/**
 * ジョブを失敗にし、予約を返金し、入力ファイルを削除し、失敗プッシュ通知を送る。
 * このヘルパーが呼ばれる時点で reserveAndClaimJob() による予約は必ず成立している
 * （submit_failed/timeout/downstream_unavailable はいずれも予約成立後にしか起こらない経路）。
 * 通知はbest-effort（失敗してもjob状態の更新自体には影響させない）。
 */
async function failJob(jobRef, uid, errorCode, errorMessage) {
  await refundUsage(uid);
  await jobRef.update({
    status: "failed",
    errorCode,
    error: errorMessage,
    updatedAt: FieldValue.serverTimestamp(),
  });
  await deleteJobInputFiles(uid, jobRef.id);
  try {
    await sendSkyMotionNotification(
      uid,
      { title: "そらもよう", body: "空を動かす動画の生成に失敗しました" },
      { type: "livingSkyFailed", errorCode }
    );
  } catch (err) {
    logger.warn("空を動かす: 失敗通知の送信に失敗しました", { uid, errorCode, error: err.message });
  }
}
