//
// そらもよう Cloud Functions — 「そらとも」（友達グループで空を共有）の純粋関数 ⭐️
//
// 招待コードの生成と正規化・グループ名の検証・通知文・宛先の分類・間引きの判定・集計を置く。
// ここには firebase-admin / firebase-functions に触れない純粋関数だけを置き、node:test で検証する
// （soratomoCore.test.js）。トランザクション（soratomoStore.js）と配線（soratomo.js）がこれを使う。
//
// ⚠️ ログと個人情報（要件15）: ここで作る集計（summarizeNotifyOutcomes）は ID と件数だけを持つ。
//    グループ名・表示名・キャプション・招待コード・通知トークンは、集計にもログにも入れない。
//

"use strict";

const crypto = require("node:crypto");

// MARK: - 定数

/**
 * 招待コードの字種（32文字）。読み間違えやすい 0・O・1・I を除いている（要件3.1）。
 * ⚠️ iOS の SoratomoInviteCode.alphabet と一致させること（片方だけ変えると、
 *    アプリが「形が違う」と弾くコードをサーバーが発行する、またはその逆が起きる）。
 */
const INVITE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
/** 招待コードの長さ（要件3.1）。 */
const INVITE_CODE_LENGTH = 8;
/** 1グループのメンバーの上限（要件4.6）。 */
const MAX_MEMBERS = 20;
/** 1人が所属できるグループの上限（要件2.5・4.7）。 */
const MAX_GROUPS_PER_USER = 10;
/** グループ名の上限（コードポイント数・要件2.2）。 */
const GROUP_NAME_MAX = 30;
/** 通知の本文に付けるキャプションの先頭の文字数（コードポイント数・要件9.3）。 */
const CAPTION_HEAD = 30;
/** 同じ受信者へ同じグループの通知を送らない間隔（5分・要件9.4）。 */
const THROTTLE_MS = 5 * 60 * 1000;
/** users/{uid} に保存される「そらとも通知」の設定の項目名。 */
const SORATOMO_PREF_KEY = "notifySoratomo";
/**
 * 「そらとも通知」が未保存の受信者の扱い（ON・要件9.14）。
 * ⚠️ iOS の User.notifySoratomoDefault と必ず一致させること。食い違うと、設定画面には ON と出るのに
 *    通知が届かない（またはその逆）になる。index.js の PREF_DEFAULTS には足さない（要件13.7:
 *    既存の3つの通知設定とその既定値を変えないため、別の項目・別の既定値として持つ）。
 */
const SORATOMO_PREF_DEFAULT = true;
/** 表示名が空のときに通知文で使う名前（index.js の displayNameOf と同じ）。 */
const FALLBACK_NAME = "だれか";

/**
 * 招待コードの入力で区切りとして無視する文字（空白とハイフン類）。
 * - 空白: \s（全角空白 U+3000 を含む Unicode の空白）。NFKC でも U+3000 は半角空白になる。
 * - ハイフン類: 半角「-」、U+2010〜U+2015（‐‑‒–—―）、U+2212（−）、U+FE63（﹣）、U+FF0D（－）、
 *   長音符 U+30FC（ー）と半角の U+FF70（ｰ）。日本語入力のまま「-」を打つと「ー」になるため入れている。
 *   どれも字種に無い文字なので、除いても別のコードと誤って一致することはない。
 * ⚠️ iOS の SoratomoInviteCode.parse（tasks 10.3）も同じ集合で除くこと（アプリとサーバーで
 *    「同じ入力を同じコードとみなす」ため）。
 */
const INVITE_CODE_SEPARATORS = /[\s\-\u2010-\u2015\u2212\uFE63\uFF0D\u30FC\uFF70]/gu;

// MARK: - 招待コード

/**
 * 招待コードを1つ作る（要件3.1・3.2）。重複の確認はトランザクション（soratomoStore.js）が行う。
 * @param {(max: number) => number} [randomInt] 0以上 max 未満の整数を返す乱数。省略時は暗号論的に
 *   安全な crypto.randomInt（テストでだけ差し替える）。
 * @returns {string} 字種から選んだ8文字
 */
function generateInviteCode(randomInt = crypto.randomInt) {
  let code = "";
  for (let i = 0; i < INVITE_CODE_LENGTH; i++) {
    code += INVITE_ALPHABET[randomInt(INVITE_ALPHABET.length)];
  }
  return code;
}

/**
 * 入力された招待コードを、照合できる形（字種の8文字）にそろえる（要件4.1〜4.3）。
 * 順序: NFKC（全角→半角）→ 大文字化 → 空白とハイフン類を除去 → 8文字かつ字種内かを確かめる。
 * 0・O・1・I のような字種外の文字は、似た文字へ補正せずに無効にする（推測で別のグループに入れないため）。
 * @param {unknown} input
 * @returns {string|null} 8文字かつ字種内でなければ null
 */
function normalizeInviteCode(input) {
  if (typeof input !== "string") return null;
  const normalized = input.normalize("NFKC").toUpperCase().replace(INVITE_CODE_SEPARATORS, "");
  const chars = Array.from(normalized);
  if (chars.length !== INVITE_CODE_LENGTH) return null;
  if (!chars.every((ch) => INVITE_ALPHABET.includes(ch))) return null;
  return normalized;
}

// MARK: - グループ名

/**
 * 文字数をコードポイントで数える（iOS の unicodeScalars.count と同じ数え方）。
 * 絵文字1つは1、結合文字（例: か＋゛）は2と数える。
 * @param {string} s
 * @returns {number}
 */
function codePointLength(s) {
  return Array.from(s).length;
}

/**
 * グループ名を検証する（要件2.2・2.3・11.11）。前後の空白（全角空白を含む）を除いて1〜30文字。
 * @param {unknown} input
 * @returns {{ ok: true, name: string } | { ok: false }} ok のときは前後の空白を除いた名前
 */
function validateGroupName(input) {
  if (typeof input !== "string") return { ok: false };
  const name = input.trim();
  const length = codePointLength(name);
  if (length < 1 || length > GROUP_NAME_MAX) return { ok: false };
  return { ok: true, name };
}

// MARK: - 通知文

/**
 * 新着投稿の通知文を組み立てる（要件9.2・9.3）。
 * タイトルはグループ名。本文は「{表示名}さんが空を投稿しました」で、キャプションがあれば
 * 先頭30文字（コードポイント）を「」で囲んで末尾に付ける。表示名が空なら「だれか」。
 * @param {{ groupName: string, posterName: unknown, caption: unknown }} args
 * @returns {{ title: string, body: string }}
 */
function buildNotification({ groupName, posterName, caption }) {
  const name = typeof posterName === "string" && posterName ? posterName : FALLBACK_NAME;
  let body = `${name}さんが空を投稿しました`;
  if (typeof caption === "string" && caption.length > 0) {
    // サロゲートペア（絵文字）を割らないよう、コードポイントの配列で切る。
    body += `「${Array.from(caption).slice(0, CAPTION_HEAD).join("")}」`;
  }
  return { title: groupName, body };
}

// MARK: - 宛先の判定

/**
 * 受信者が「そらとも通知」を ON にしているか（要件9.13・9.14）。
 * 項目が無い・真偽値でないときは既定（SORATOMO_PREF_DEFAULT = ON）。既存の prefEnabled と同じ読み方。
 * @param {Object|null|undefined} userData users/{uid} の中身（文書が無ければ null）
 * @returns {boolean}
 */
function soratomoPrefEnabled(userData) {
  const v = userData ? userData[SORATOMO_PREF_KEY] : undefined;
  return typeof v === "boolean" ? v : SORATOMO_PREF_DEFAULT;
}

/**
 * 受信者1人を分類する（要件1.7・9.13・9.15）。
 * 順序は「フラグOFF → 通知設定OFF → ブロック → トークン無し」。集計（9.11）で理由を1つに決めるため、
 * 複数に当てはまる受信者は先の理由で数える。
 * @param {{ hasFlag: boolean, userData: Object|null|undefined, posterId: string }} args
 *   hasFlag は受信者に soratomoBeta のクレームがあるか（true のときだけ ON）
 * @returns {"eligible"|"flag_off"|"pref_off"|"blocked"|"no_token"}
 */
function classifyRecipient({ hasFlag, userData, posterId }) {
  if (hasFlag !== true) return "flag_off";
  if (!soratomoPrefEnabled(userData)) return "pref_off";
  // ブロックの規則は index.js の isBlocked と同じ（配列のときだけ見る）。
  if (userData && Array.isArray(userData.blockedUserIds) && userData.blockedUserIds.includes(posterId)) {
    return "blocked";
  }
  if (!(userData && userData.fcmToken)) return "no_token";
  return "eligible";
}

/**
 * notifyState の lastSentAt をミリ秒で読む。数値（ミリ秒）か Firestore の Timestamp（toMillis）を受け付ける。
 * @param {unknown} value
 * @returns {number|null} 読めなければ null
 */
function toMillisOrNull(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (value && typeof value.toMillis === "function") return value.toMillis();
  return null;
}

/**
 * 受信者への通知を送るかを決める（要件9.4）。
 * - 同じ投稿ID: 重複（トリガーの再配信。直前に送った投稿と同じなら、時刻に関係なく送らない。
 *   間に別の投稿を送った後に届いた、遅い再配信は見分けられない＝受け入れ済み・レビューで文言を狭めた）
 * - 最後に送ってから5分以内: 間引き。「以内」なので5分ちょうども間引きに含める
 * - それ以外（記録が無い・時刻が読めない・5分を過ぎた）: 送る
 * @param {{ lastSentAt?: unknown, lastSkyId?: unknown }|null|undefined} state notifyState/{uid} の中身
 * @param {string} skyId 今回の投稿ID
 * @param {number} nowMs 今の時刻（ミリ秒）
 * @returns {"send"|"throttled"|"duplicate"}
 */
function decideThrottle(state, skyId, nowMs) {
  if (!state) return "send";
  if (state.lastSkyId === skyId) return "duplicate";
  const last = toMillisOrNull(state.lastSentAt);
  if (last === null) return "send";
  return nowMs - last <= THROTTLE_MS ? "throttled" : "send";
}

// MARK: - 集計

/**
 * 宛先ごとの結果（分類・間引きの判定・送信の結果）から、集計のキーへの対応。
 * invalid_token は「送ろうとして失敗した」（トークンは掃除済み）ので送信失敗に数える。
 */
const OUTCOME_TO_SUMMARY_KEY = {
  sent: "sent",
  throttled: "throttled",
  duplicate: "duplicate",
  no_token: "noToken",
  failed: "sendFailed",
  invalid_token: "sendFailed",
  pref_off: "prefOff",
  blocked: "blocked",
  flag_off: "flagOff",
};

/**
 * 投稿1件ぶんの集計（要件9.11）。ログの1行にそのまま渡せる形で、ID と件数だけを持つ（15.2・15.3）。
 * 想定外の結果は送信失敗に数える（合計を宛先の数と一致させ、数え漏れをログで気づけるようにする）。
 * @param {string} groupId
 * @param {string} skyId
 * @param {Array<string|undefined>} outcomes 宛先ごとの結果
 * @returns {{ groupId: string, skyId: string, sent: number, throttled: number, duplicate: number,
 *   noToken: number, sendFailed: number, prefOff: number, blocked: number, flagOff: number }}
 */
function summarizeNotifyOutcomes(groupId, skyId, outcomes) {
  const summary = {
    groupId,
    skyId,
    sent: 0,
    throttled: 0,
    duplicate: 0,
    noToken: 0,
    sendFailed: 0,
    prefOff: 0,
    blocked: 0,
    flagOff: 0,
  };
  for (const outcome of outcomes) {
    const key = Object.prototype.hasOwnProperty.call(OUTCOME_TO_SUMMARY_KEY, outcome)
      ? OUTCOME_TO_SUMMARY_KEY[outcome]
      : "sendFailed";
    summary[key] += 1;
  }
  return summary;
}

module.exports = {
  INVITE_ALPHABET,
  INVITE_CODE_LENGTH,
  MAX_MEMBERS,
  MAX_GROUPS_PER_USER,
  GROUP_NAME_MAX,
  CAPTION_HEAD,
  THROTTLE_MS,
  SORATOMO_PREF_KEY,
  SORATOMO_PREF_DEFAULT,
  FALLBACK_NAME,
  generateInviteCode,
  normalizeInviteCode,
  validateGroupName,
  buildNotification,
  soratomoPrefEnabled,
  classifyRecipient,
  decideThrottle,
  summarizeNotifyOutcomes,
};
