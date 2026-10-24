//
// そらもよう Cloud Functions — 「今日のおすすめのそらもよう」を選んで書き、選ばれた人へ 1 回だけ知らせる ⭐️☁️
//
// 毎朝 7:00（日本時間）の定期実行（index.js の publishDailyPick）から runDailyPick(db, deps) を呼ぶ。
//   1. dailyPickConfig/settings を読む。無い・壊れていたら何も選ばない（soratomoNgWords.js と同じ安全側）
//   2. dailyPickLog/{dateKey} が既にあれば「選ぶ」だけを飛ばして通知の段へ進む
//      （⚠️「ログがあれば return」にしない。選んだ直後に落ちた回の再試行が、永久に通知しなくなるため）
//   3. 無ければ公開投稿・通報・過去 30 日のログを読み、dailyPickCore.pickCandidates で候補を選ぶ。
//      dailyPicks/{dateKey}（アプリが読む）と dailyPickLog/{dateKey}（候補の uid・通知の結果。誰も読めない）を
//      1 つの batch の create で書く＝両方が一緒に現れる。先に書かれていたら（ALREADY_EXISTS）その回を使う
//   4. 通知: notifyEnabled がオフ・時間帯の外なら送らない。dailyPickLog をトランザクションで読み、
//      notifyClaimedAt（送る権利の印）を先に書いてから送る（index.js の recommendationNotices と同じ「印を先に作る型」）
//      ＝何回起き直しても、同時に 2 本走っても、送るのは多くて 1 回
//      印を取る前（トランザクション）に落ちたら投げる＝再試行に任せる。印を取った後の失敗は投げない
// ここには firebase-admin / firebase-functions を require しない（db と依存は呼び出し側から渡す。followBlock.js と同じ型）。
// ⚠️ 「私のおすすめの空」（recommendationCore.js の通知）とは別物。名前は必ず dailyPick 系にする。
// ⚠️ logger には uid・postId・名前を出さない（件数・dateKey・status だけ）。
//

"use strict";

const dailyPickCore = require("./dailyPickCore");
const { isAlreadyExistsError } = require("./recommendationCore");

/** アプリが鍵で get する「今日の候補」（postIds だけ）。 */
const PICKS_COLLECTION = "dailyPicks";
/** 選んだ記録（候補の uid・件数・通知の印と結果）。ルールで誰も読めない。TTL で消す。 */
const LOG_COLLECTION = "dailyPickLog";
/** 運営・テスト用の除外一覧と通知のオン/オフ。ルールで誰も読めない。 */
const CONFIG_COLLECTION = "dailyPickConfig";
const CONFIG_DOC_ID = "settings";

const DAY_MS = 24 * 3600 * 1000;

function isNonEmptyString(v) {
  return typeof v === "string" && v.length > 0;
}

/** 数値の項目を読む（無い・数でないときは 0）。 */
function numberOr0(v) {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

/**
 * 既にあるログから戻り値の数値の項目を作る（選ばなかった回＝already_picked 用）。
 * @param {object} data dailyPickLog の中身
 */
function summaryFromLog(data) {
  const d = data && typeof data === "object" ? data : {};
  return {
    status: "already_picked",
    candidatesCount: Array.isArray(d.candidates) ? d.candidates.length : 0,
    relaxedCount: numberOr0(d.relaxedCount),
    scanned: numberOr0(d.scanned),
    total: numberOr0(d.total),
    truncated: d.truncated === true,
    reportedCount: numberOr0(d.reportedCount),
  };
}

/** 何も選ばなかった回（no_config など）の数値の項目。 */
function emptySummary(status) {
  return { status, candidatesCount: 0, relaxedCount: 0, scanned: 0, total: 0, truncated: false, reportedCount: 0 };
}

/**
 * 過去のログ（新しい順でも古い順でもよい）から「userId → 最後に主役（candidates[0]）になった dateKey」を作る。
 * 同じ人が 2 回以上主役なら新しい方の日付を残す（yyyy-MM-dd は文字列の大小がそのまま日付の前後）。
 * candidates[1] 以降だっただけの人は入れない。candidates が無い・壊れたログは飛ばす。
 * @param {FirebaseFirestore.DocumentSnapshot[]} snaps
 * @returns {Map<string, string>}
 */
function recentPrimariesFromLogs(snaps) {
  const recent = new Map();
  for (const snap of snaps) {
    if (!snap.exists) continue;
    const candidates = snap.get("candidates");
    const first = Array.isArray(candidates) ? candidates[0] : null;
    const userId = first && typeof first === "object" ? first.userId : null;
    if (!isNonEmptyString(userId)) continue;
    const dateKey = snap.id; // ログの文書 ID は dateKey
    const prev = recent.get(userId);
    if (prev === undefined || dateKey > prev) recent.set(userId, dateKey);
  }
  return recent;
}

/**
 * 候補を選んで dailyPicks と dailyPickLog を書く。
 * Firestore が投げたらそのまま投げる（index.js の retryCount に任せる）。ALREADY_EXISTS だけは「先に書かれた」扱い。
 * @returns {Promise<{summary: object} | {done: object}>} summary は通知の段へ進む・done はそのまま返す
 */
async function pickAndWrite(db, { now, dateKey, config, logRef, rng, maxScan, logger }) {
  // 公開投稿を投稿者の uid だけ読む。⚠️ orderBy を足さない（複合インデックスが要るようになる）
  const publicPosts = db.collection("posts").where("visibility", "==", "public");
  const postsSnap = await publicPosts.select("userId").limit(maxScan).get();
  const countSnap = await publicPosts.count().get();
  const posts = postsSnap.docs.map((doc) => ({ postId: doc.id, userId: doc.get("userId") }));
  const scanned = postsSnap.size;
  const total = numberOr0(countSnap.data().count);
  const truncated = scanned >= maxScan;
  if (truncated) {
    logger.warn("dailyPick: 公開投稿の走査が上限に届いた（一部だけから選ぶ）", { dateKey, scanned, total, maxScan });
  }

  // 通報された投稿（上限なし）。postId が文字列のものだけ
  const reportsSnap = await db.collection("reports").select("postId").get();
  const reportedPostIds = [
    ...new Set(reportsSnap.docs.map((doc) => doc.get("postId")).filter(isNonEmptyString)),
  ];
  const reportedCount = reportedPostIds.length;

  // 過去 30 日に主役になった投稿者
  const recentRefs = dailyPickCore
    .previousDateKeys(dateKey, dailyPickCore.RECENT_DAYS)
    .map((key) => db.collection(LOG_COLLECTION).doc(key));
  const recentSnaps = await db.getAll(...recentRefs);
  const recentPrimaries = recentPrimariesFromLogs(recentSnaps);

  const { candidates, relaxedCount } = dailyPickCore.pickCandidates({
    posts,
    excludedUserIds: config.excludedUserIds,
    reportedPostIds,
    recentPrimaries,
    rng,
  });

  if (candidates.length === 0) {
    logger.warn("dailyPick: 候補が 0 件（何も書かない）", {
      dateKey,
      scanned,
      total,
      reportedCount,
      excludedCount: config.excludedUserIds.length,
    });
    return {
      done: { ...emptySummary("no_candidates"), relaxedCount, scanned, total, truncated, reportedCount, notify: "not_run" },
    };
  }

  // 2 つを 1 つの batch で create する＝両方が一緒に現れる（片方だけ見えることが無い）。
  // 通知の印（notifyClaimedAt）と結果（notifyResult）はここでは書かない（通知の段で書く）
  const createdAt = now;
  const expireAt = new Date(now.getTime() + dailyPickCore.LOG_TTL_DAYS * DAY_MS);
  const batch = db.batch();
  batch.create(db.collection(PICKS_COLLECTION).doc(dateKey), {
    dateKey,
    postIds: candidates.map((c) => c.postId),
    createdAt,
  });
  batch.create(logRef, {
    dateKey,
    candidates: candidates.map((c) => ({ postId: c.postId, userId: c.userId })),
    relaxedCount,
    scanned,
    total,
    truncated,
    reportedCount,
    createdAt,
    expireAt,
  });
  try {
    await batch.commit();
  } catch (err) {
    if (!isAlreadyExistsError(err)) throw err;
    // 同時に走った別の回が先に書いた。その回のログを使って通知の段へ進む
    logger.info("dailyPick: 先に書かれていた（ALREADY_EXISTS）", { dateKey });
    const again = await logRef.get();
    if (!again.exists) {
      // batch で両方を作るので、dailyPicks があって log が無いのは手で作った・消したときだけ
      logger.error("dailyPick: dailyPicks はあるのにログが無い", { dateKey });
      return { done: { ...emptySummary("already_picked"), notify: "no_log" } };
    }
    return { summary: summaryFromLog(again.data()) };
  }

  return {
    summary: {
      status: "picked",
      candidatesCount: candidates.length,
      relaxedCount,
      scanned,
      total,
      truncated,
      reportedCount,
    },
  };
}

/**
 * 送る権利（notifyClaimedAt）をトランザクションで取ってから、主役（candidates[0]）の投稿者へ 1 回知らせる。
 * 主役は「トランザクションで読んだログ」から取る（already_picked の回は手元に候補が無いため）。
 * 権利を取る前（トランザクション）の失敗は投げる＝定期実行の再試行に任せる
 * （再試行の回もトランザクションで印を見るので、送るのは多くて 1 回）。
 * 権利を取った後（notifyOwner・notifyResult の書き込み）の失敗は投げない（再試行しても送らないため）。
 * @returns {Promise<string>} notify の値。権利を取る前（トランザクション）に失敗したら投げる
 */
async function claimAndNotify(db, logRef, dateKey, deps) {
  const { logger } = deps;
  let claim;
  try {
    claim = await db.runTransaction(async (tx) => {
      const snap = await tx.get(logRef);
      if (!snap.exists) return { outcome: "no_log" };
      const data = snap.data();
      if (data.notifyClaimedAt !== undefined && data.notifyClaimedAt !== null) return { outcome: "already_claimed" };
      const first = Array.isArray(data.candidates) ? data.candidates[0] : null;
      if (!first || typeof first !== "object" || !isNonEmptyString(first.userId) || !isNonEmptyString(first.postId)) {
        return { outcome: "no_candidate" };
      }
      tx.update(logRef, { notifyClaimedAt: deps.now() });
      return { outcome: "claimed", ownerId: first.userId, postId: first.postId };
    });
  } catch (err) {
    // 読んで書く文書は dailyPickLog/{dateKey} だけなので、メッセージに uid は入らない
    logger.warn("dailyPick: 送る権利のトランザクションが失敗した（投げ直す＝再試行に任せる）", {
      dateKey,
      code: err && err.code,
      error: String(err && err.message),
    });
    // ⚠️ "error" を返さない。返すと定期実行が成功扱いになって再試行されず、権利を取れないままその日の通知が消える。
    //    再試行の回もトランザクションで印を見る（取れていれば already_claimed）ので、送るのは多くて 1 回のまま
    throw err;
  }
  if (claim.outcome !== "claimed") return claim.outcome;

  let result;
  try {
    result = await deps.notifyOwner({ ownerId: claim.ownerId, postId: claim.postId, dateKey });
  } catch (err) {
    // notifyOwner の例外のメッセージには users/{uid} などのパスが入りうるので、code だけ残す
    logger.warn("dailyPick: notifyOwner が投げた", { dateKey, code: err && err.code });
    result = "error";
  }

  try {
    await logRef.update({ notifyResult: result });
  } catch (err) {
    logger.warn("dailyPick: notifyResult を書けなかった", { dateKey, code: err && err.code });
  }
  return result;
}

/**
 * 「今日のおすすめのそらもよう」を 1 回分動かす（定期実行の中身）。
 * @param {FirebaseFirestore.Firestore} db
 * @param {{
 *   now: () => Date,
 *   rng?: () => number,
 *   logger: { info: Function, warn: Function, error: Function },
 *   notifyOwner: (args: { ownerId: string, postId: string, dateKey: string }) => Promise<string>,
 *   maxScan?: number,
 * }} deps now・logger・notifyOwner は必須。rng は省略時 Math.random、maxScan は省略時 dailyPickCore.MAX_SCAN（テスト用）
 * @returns {Promise<{dateKey: string, status: string, candidatesCount: number, relaxedCount: number,
 *   scanned: number, total: number, truncated: boolean, reportedCount: number, notify: string}>}
 *   uid・postId は入れない（index.js がそのまま logger.info に渡す）
 * @throws Firestore の失敗（設定・ログの読み込みと選ぶ段。ALREADY_EXISTS を除く）と、送る権利を取る前のトランザクションの失敗
 *   ＝index.js の retryCount に任せる。権利を取った後（notifyOwner・notifyResult の書き込み）の失敗は投げない
 */
async function runDailyPick(db, deps) {
  if (!deps || typeof deps.now !== "function" || typeof deps.notifyOwner !== "function" || !deps.logger) {
    throw new TypeError("runDailyPick: deps.now・deps.notifyOwner・deps.logger は必須");
  }
  const { logger } = deps;
  const rng = typeof deps.rng === "function" ? deps.rng : Math.random;
  const maxScan = Number.isInteger(deps.maxScan) && deps.maxScan > 0 ? deps.maxScan : dailyPickCore.MAX_SCAN;

  // 1. 今の時刻と、その瞬間が属する日の鍵
  const now = deps.now();
  const dateKey = dailyPickCore.dateKeyForInstant(now.getTime());

  // 2. 設定。無い・壊れていたら何も書かずに止める（投げない）
  const configSnap = await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC_ID).get();
  const config = dailyPickCore.normalizeConfig(configSnap.exists ? configSnap.data() : null);
  if (!config.ok) {
    logger.error("dailyPick: 設定が無い・壊れているので選ばない", { dateKey, reason: config.reason });
    return { dateKey, ...emptySummary("no_config"), notify: "not_run" };
  }

  // 3. 既に選んであれば「選ぶ」だけを飛ばす（通知の段へは進む）
  const logRef = db.collection(LOG_COLLECTION).doc(dateKey);
  const logSnap = await logRef.get();
  let summary;
  if (logSnap.exists) {
    summary = summaryFromLog(logSnap.data());
  } else {
    // 4. 選んで書く
    const picked = await pickAndWrite(db, { now, dateKey, config, logRef, rng, maxScan, logger });
    if (picked.done) return { dateKey, ...picked.done };
    summary = picked.summary;
  }

  // 5. 通知の段
  let notify;
  if (!config.notifyEnabled) {
    notify = "skipped_disabled";
  } else if (!dailyPickCore.isWithinNotifyWindow(deps.now().getTime(), dateKey)) {
    // 時刻はここで取り直す（選ぶのに時間がかかった・再試行が遅れて届いた回でも、夜中に鳴らさない）
    notify = "skipped_window";
  } else {
    notify = await claimAndNotify(db, logRef, dateKey, deps);
  }

  // 6. 戻り値（uid・postId を入れない）
  return { dateKey, ...summary, notify };
}

module.exports = {
  runDailyPick,
  PICKS_COLLECTION,
  LOG_COLLECTION,
  CONFIG_COLLECTION,
  CONFIG_DOC_ID,
};
