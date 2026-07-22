//
// そらもよう Cloud Functions（「空を動かす」β・フェーズ1a）
//
// トリガー:
//   - onSkyMotionJobCreated  livingSkyJobs/{jobId} (onDocumentCreated)
//       → livingSkyUsage/{uid} を予約 → fal.ai Kling へ submit → status="submitted"
//   - pollSkyMotionJobs      onSchedule（1分毎）
//       → status="submitted" のジョブを fal.ai に問い合わせ、完了/失敗を反映
//
// 契約の一次情報: docs/sky-motion-design.md（フィールド名・Storageパス・マスク極性・
// 回数方針はすべてそちらが正）。純粋関数（予約/返金判定・fal応答パース等）は
// skyMotionCore.js に分離し、単体テスト可能にしている（node --test）。
//
// DEBUG限定E2E検証用機能。本番導線化はしない（design doc §7）。
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

const core = require("./skyMotionCore");

// initializeApp() は index.js 側で1回だけ実行される（Admin SDK はアプリ単位でシングルトン）。
const db = getFirestore();
const storage = getStorage();
const messaging = getMessaging();

const FAL_KEY = defineSecret("FAL_KEY");

// 署名付きURLの有効期限（fal.ai がダウンロードし終えるまで十分な余裕を持たせる）。
const SIGNED_URL_EXPIRES_MS = 60 * 60 * 1000; // 1時間

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
 * livingSkyUsage/{uid} をトランザクションで予約する（reserve-on-create）。
 * @returns {Promise<boolean>} 予約できたら true、上限到達で予約できなければ false
 */
async function reserveUsage(uid) {
  const usageRef = db.collection("livingSkyUsage").doc(uid);
  const today = core.jstDateString();
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(usageRef);
    const current = snap.exists ? snap.data() : null;
    const decision = core.decideReservation(current, today);
    if (!decision.allowed) return false;
    tx.set(
      usageRef,
      { day: decision.day, reservedCount: decision.reservedCount, updatedAt: FieldValue.serverTimestamp() },
      { merge: true }
    );
    return true;
  });
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
  const res = await fetch(`${core.FAL_QUEUE_BASE_URL}/${core.FAL_APP_ID}`, {
    method: "POST",
    headers: {
      Authorization: `Key ${falKeyValue}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`fal submit failed: status=${res.status} body=${body.slice(0, 300)}`);
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
      logger.warn("fal submit失敗", { attempt, error: err.message });
    }
  }
  throw lastError;
}

// ============================================================
// A. onSkyMotionJobCreated — livingSkyJobs/{jobId} 作成トリガー
// ============================================================

exports.onSkyMotionJobCreated = onDocumentCreated(
  { document: "livingSkyJobs/{jobId}", secrets: [FAL_KEY] },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) {
      logger.warn("空を動かす: ジョブのスナップショットが空でした");
      return;
    }
    const jobId = event.params.jobId;
    const jobRef = snapshot.ref;
    const job = snapshot.data() || {};

    // at-least-once 再配信対策: pending 以外（既に処理済み）なら何もしない。
    if (job.status !== "pending") {
      logger.info("空を動かす: 既に処理済みのためスキップ", { jobId, status: job.status });
      return;
    }

    const uid = job.userId;
    if (!uid) {
      logger.error("空を動かす: userId が無いジョブです", { jobId });
      return;
    }

    // --- 1. 予約（トランザクション）。上限到達なら fal.ai を一切呼ばない（非課金） ---
    const reserved = await reserveUsage(uid);
    if (!reserved) {
      await jobRef.update({
        status: "failed",
        errorCode: "quota_exceeded",
        error: "本日の生成回数の上限に達しました",
        updatedAt: FieldValue.serverTimestamp(),
      });
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
        pollAttempts: 0,
        updatedAt: FieldValue.serverTimestamp(),
      });
      logger.info("空を動かす: submit成功", { jobId, uid, falRequestId });
    } catch (err) {
      // --- 4b. submit失敗（リトライも失敗）→ 予約を返金してfailedに ---
      logger.error("空を動かす: submit失敗（リトライも失敗）", { jobId, uid, error: err.message });
      await refundUsage(uid);
      await jobRef.update({
        status: "failed",
        errorCode: "submit_failed",
        error: err.message,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
  }
);

// ============================================================
// B. pollSkyMotionJobs — 1分毎に submitted ジョブを確認
// ============================================================

exports.pollSkyMotionJobs = onSchedule(
  { schedule: "every 1 minutes", secrets: [FAL_KEY] },
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

  const createdAtMillis = toMillis(job.createdAt);
  const timedOut = createdAtMillis > 0 && core.isPollTimedOut(createdAtMillis, now);

  let statusPayload;
  try {
    const res = await fetch(
      `${core.FAL_QUEUE_BASE_URL}/${core.FAL_APP_ID}/requests/${falRequestId}/status`,
      { headers: { Authorization: `Key ${falKeyValue}` } }
    );
    if (!res.ok) {
      // 5xx等の一時的なdownstream不調。ここでは判定を進めず、タイムアウト経由の
      // 回復（次回周期でのリトライ）に委ねる。ただしタイムアウト超過なら打ち切る。
      if (timedOut) {
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

  // normalized.state === "READY" → 結果を取得してStorageへ書き込む
  try {
    const resultRes = await fetch(
      `${core.FAL_QUEUE_BASE_URL}/${core.FAL_APP_ID}/requests/${falRequestId}`,
      { headers: { Authorization: `Key ${falKeyValue}` } }
    );
    if (!resultRes.ok) {
      const body = await resultRes.text().catch(() => "");
      throw new Error(`fal result取得失敗: status=${resultRes.status} body=${body.slice(0, 300)}`);
    }
    const resultJson = await resultRes.json();
    const videoUrl = core.extractVideoUrl(resultJson);

    const outputPath = `livingSky/${uid}/${jobId}/output.mp4`;
    const videoRes = await fetch(videoUrl);
    if (!videoRes.ok) {
      throw new Error(`mp4ダウンロード失敗: status=${videoRes.status}`);
    }
    const videoBuffer = Buffer.from(await videoRes.arrayBuffer());
    const file = storage.bucket().file(outputPath);
    await file.save(videoBuffer, { contentType: "video/mp4" });
    const [downloadUrl] = await file.getSignedUrl({
      action: "read",
      expires: Date.now() + 7 * 24 * 60 * 60 * 1000, // 7日間
    });

    await jobRef.update({
      status: "completed",
      videoURL: downloadUrl,
      updatedAt: FieldValue.serverTimestamp(),
    });

    // 入力3ファイル（source/sky_mask/ground_mask）を削除（output.mp4は残す）。
    await Promise.all(
      ["source.jpg", "sky_mask.png", "ground_mask.png"].map((name) =>
        storage
          .bucket()
          .file(`livingSky/${uid}/${jobId}/${name}`)
          .delete()
          .catch((e) => logger.warn("空を動かす: 一時ファイル削除失敗", { jobId, name, error: e.message }))
      )
    );

    await sendSkyMotionNotification(
      uid,
      { title: "そらもよう", body: "空を動かす動画が完成しました" },
      { type: "livingSkyCompleted", jobId }
    );
    logger.info("空を動かす: 完了", { jobId, uid, falRequestId });
  } catch (err) {
    logger.error("空を動かす: 結果取得/保存に失敗", { jobId, uid, error: err.message });
    await failJob(jobRef, uid, "downstream_unavailable", err.message);
  }
}

/** ジョブを失敗にし、予約を返金し、失敗プッシュ通知を送る。 */
async function failJob(jobRef, uid, errorCode, errorMessage) {
  await refundUsage(uid);
  await jobRef.update({
    status: "failed",
    errorCode,
    error: errorMessage,
    updatedAt: FieldValue.serverTimestamp(),
  });
  await sendSkyMotionNotification(
    uid,
    { title: "そらもよう", body: "空を動かす動画の生成に失敗しました" },
    { type: "livingSkyFailed", errorCode }
  );
}
