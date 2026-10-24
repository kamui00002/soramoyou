//
// そらもよう Cloud Functions — 「今日のおすすめのそらもよう」の純粋関数と定数 ⭐️
//
// 毎朝 7:00（日本時間）にサーバーが公開投稿の中から候補を最大 5 件ランダムに選び、全員に同じ「今日の 1 枚」を出す。
// ここには firebase-admin / firebase-functions に触れない純粋関数と定数だけを置き、node:test で検証する。
// Firestore の読み書き（dailyPick.js）と index.js の配線は別ファイルの担当。
// ⚠️ 「私のおすすめの空」（recommendationCore.js）とは別物。名前は必ず dailyPick 系にする。
//

"use strict";

/** 「1 日」の切り替わり時刻（日本時間の時）。7 時より前は前日の扱い。 */
const DAY_SWITCH_HOUR_JST = 7;

/** 1 日に用意する候補の最大数（1 件目が主役）。 */
const MAX_CANDIDATES = 5;

/** 「最近主役になった投稿者」を避ける日数。 */
const RECENT_DAYS = 30;

/** 公開投稿を走査する最大件数。 */
const MAX_SCAN = 50000;

/** 選定ログを残しておく日数。 */
const LOG_TTL_DAYS = 90;

/** 通知を送ってよい時間帯（日本時間の時・開始は含み、終了は含まない）。 */
const NOTIFY_WINDOW_START_HOUR_JST = 7;
const NOTIFY_WINDOW_END_HOUR_JST = 21;

/** 通知のタイトル。 */
const NOTICE_TITLE = "そらもよう";

/** 毎朝 7:00（日本時間）に走らせる定期実行の設定。 */
const SCHEDULE_OPTIONS = {
  schedule: "0 7 * * *",
  timeZone: "Asia/Tokyo",
  region: "asia-northeast1",
  timeoutSeconds: 300,
  memory: "512MiB",
  maxInstances: 1,
  retryCount: 2,
};

const HOUR_MS = 3600 * 1000;
const DAY_MS = 24 * HOUR_MS;
/** 日本時間は UTC+9 で夏時間が無い。 */
const JST_OFFSET_HOURS = 9;

/**
 * 通知本文（利用者承認済みの文言。変えない）。
 * @returns {string}
 */
function noticeBody() {
  return "あなたの空が「今日のおすすめのそらもよう」に選ばれました";
}

/**
 * dateKey（yyyy-MM-dd）を検証し、その日の UTC 0 時のミリ秒を返す。不正なら throw。
 * @param {unknown} dateKey
 * @returns {number}
 */
function parseDateKey(dateKey) {
  const m = typeof dateKey === "string" ? /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateKey) : null;
  if (!m) throw new Error(`dateKey が不正: ${String(dateKey)}`);
  const ms = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  // 2026-02-30 のような存在しない日は Date が繰り上げるので、書き戻して一致を見る
  if (Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 10) !== dateKey) {
    throw new Error(`dateKey が不正: ${dateKey}`);
  }
  return ms;
}

/**
 * ある瞬間が属する「おすすめの日」の鍵（yyyy-MM-dd）。
 * 日本時間で「その時刻 − 7 時間」の日付（6:59:59 までは前日、7:00 から当日）。
 * @param {number} ms エポックミリ秒
 * @returns {string}
 */
function dateKeyForInstant(ms) {
  if (typeof ms !== "number" || !Number.isFinite(ms)) {
    throw new Error(`ms が数値でない: ${String(ms)}`);
  }
  // UTC に (9 − 7) 時間足して日付部分を取る = JST の (時刻 − 7 時間) の日付
  return new Date(ms + (JST_OFFSET_HOURS - DAY_SWITCH_HOUR_JST) * HOUR_MS)
    .toISOString()
    .slice(0, 10);
}

/**
 * dateKey の前日から n 日分の鍵（新しい順・dateKey 自身は含まない）。
 * @param {string} dateKey
 * @param {number} n
 * @returns {string[]}
 */
function previousDateKeys(dateKey, n) {
  const base = parseDateKey(dateKey);
  const count = Number.isInteger(n) && n > 0 ? n : 0;
  const keys = [];
  for (let i = 1; i <= count; i++) {
    keys.push(new Date(base - i * DAY_MS).toISOString().slice(0, 10));
  }
  return keys;
}

/**
 * nowMs が「dateKey の日の 07:00 以上 21:00 未満（日本時間）」か。通知を送ってよい時間帯の判定。
 * @param {number} nowMs
 * @param {string} dateKey
 * @returns {boolean}
 */
function isWithinNotifyWindow(nowMs, dateKey) {
  const dayStartUtc = parseDateKey(dateKey) - JST_OFFSET_HOURS * HOUR_MS; // 日本時間 0:00 の瞬間
  const start = dayStartUtc + NOTIFY_WINDOW_START_HOUR_JST * HOUR_MS;
  const end = dayStartUtc + NOTIFY_WINDOW_END_HOUR_JST * HOUR_MS;
  return typeof nowMs === "number" && nowMs >= start && nowMs < end;
}

/**
 * 設定文書 dailyPickConfig/settings を正規化する。
 * 読めない・形が違うときは ok:false（安全側＝何も選ばない）。空配列は ok（除外なし）。
 * @param {unknown} data
 * @returns {{ok: true, excludedUserIds: string[], notifyEnabled: boolean} | {ok: false, reason: string}}
 */
function normalizeConfig(data) {
  if (data === null || typeof data !== "object" || Array.isArray(data)) {
    return { ok: false, reason: "設定文書が無い、またはオブジェクトでない" };
  }
  const ids = data.excludedUserIds;
  if (!Array.isArray(ids)) {
    return { ok: false, reason: "excludedUserIds が配列でない" };
  }
  if (!ids.every((id) => typeof id === "string" && id.length > 0)) {
    return { ok: false, reason: "excludedUserIds に文字列以外または空文字がある" };
  }
  return {
    ok: true,
    excludedUserIds: [...ids],
    notifyEnabled: data.notifyEnabled === true,
  };
}

function isNonEmptyString(v) {
  return typeof v === "string" && v.length > 0;
}

/** Fisher-Yates（コピーを混ぜる。rng は [0,1) を返す）。 */
function shuffled(items, rng) {
  const a = [...items];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.min(i, Math.floor(rng() * (i + 1)));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

/**
 * 今日の候補（最大 count 件・投稿者は全員別人）を選ぶ。1 件目が主役。
 * - excludedUserIds（運営・テスト用）と reportedPostIds（通報された投稿）は、どの段階でも緩めずに除く。
 * - きびしい組: recentPrimaries に入っていない投稿者の投稿を混ぜ、まだ選んでいない投稿者のものを前から拾う。
 * - 足りなければ緩める: 最近主役になった投稿者を「主役になった日が古い順」に、残りの投稿から rng で 1 件ずつ足す。
 * @param {object} args
 * @param {{postId: string, userId: string}[]} args.posts
 * @param {string[]} [args.excludedUserIds]
 * @param {string[]} [args.reportedPostIds]
 * @param {Map<string,string>|Object<string,string>} [args.recentPrimaries] userId → 最後に主役になった dateKey
 * @param {number} [args.count]
 * @param {() => number} [args.rng]
 * @returns {{candidates: {postId: string, userId: string}[], relaxedCount: number}}
 */
function pickCandidates({
  posts,
  excludedUserIds,
  reportedPostIds,
  recentPrimaries,
  count = MAX_CANDIDATES,
  rng = Math.random,
} = {}) {
  const excluded = new Set(Array.isArray(excludedUserIds) ? excludedUserIds : []);
  const reported = new Set(Array.isArray(reportedPostIds) ? reportedPostIds : []);
  const recent =
    recentPrimaries instanceof Map
      ? recentPrimaries
      : new Map(
          recentPrimaries && typeof recentPrimaries === "object"
            ? Object.entries(recentPrimaries)
            : []
        );

  const eligible = (Array.isArray(posts) ? posts : [])
    .filter(
      (p) =>
        p &&
        isNonEmptyString(p.postId) &&
        isNonEmptyString(p.userId) &&
        !excluded.has(p.userId) &&
        !reported.has(p.postId)
    )
    .map((p) => ({ postId: p.postId, userId: p.userId }));

  const candidates = [];
  const usedUsers = new Set();

  // きびしい組
  const strict = eligible.filter((p) => !recent.has(p.userId));
  for (const p of shuffled(strict, rng)) {
    if (candidates.length >= count) break;
    if (usedUsers.has(p.userId)) continue;
    usedUsers.add(p.userId);
    candidates.push(p);
  }

  // 緩める: 主役になった日が古い順（同じ日は userId 順で決まった並びにする）
  let relaxedCount = 0;
  if (candidates.length < count) {
    const byUser = new Map();
    for (const p of eligible) {
      if (!recent.has(p.userId) || usedUsers.has(p.userId)) continue;
      if (!byUser.has(p.userId)) byUser.set(p.userId, []);
      byUser.get(p.userId).push(p);
    }
    const order = [...byUser.keys()].sort((a, b) => {
      const da = String(recent.get(a));
      const db = String(recent.get(b));
      if (da !== db) return da < db ? -1 : 1;
      return a < b ? -1 : a > b ? 1 : 0;
    });
    for (const userId of order) {
      if (candidates.length >= count) break;
      const own = byUser.get(userId);
      const pick = own[Math.min(own.length - 1, Math.floor(rng() * own.length))];
      candidates.push(pick);
      relaxedCount++;
    }
  }

  return { candidates, relaxedCount };
}

module.exports = {
  DAY_SWITCH_HOUR_JST,
  MAX_CANDIDATES,
  RECENT_DAYS,
  MAX_SCAN,
  LOG_TTL_DAYS,
  NOTIFY_WINDOW_START_HOUR_JST,
  NOTIFY_WINDOW_END_HOUR_JST,
  NOTICE_TITLE,
  SCHEDULE_OPTIONS,
  noticeBody,
  dateKeyForInstant,
  previousDateKeys,
  isWithinNotifyWindow,
  normalizeConfig,
  pickCandidates,
};
