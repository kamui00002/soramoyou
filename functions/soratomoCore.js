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

// MARK: - 定数（公開前ゲート・soratomo-release-gate）

/**
 * そらともガイドラインの現行の版（release-gate 要件10.9）。
 * ⚠️ iOS の SoratomoGuideline.currentVersion と一致させること（両方の単体テストで値を固定している）。
 *    片方だけ上げると、アプリで同意しても outdated_guideline で拒否され続ける（または古い版の同意を認める）。
 */
const GUIDELINE_VERSION = 1;
/**
 * 通報の理由（release-gate 要件6.6）。iOS の ReportReason の rawValue と同じ5つ。
 * 並びは REPORT_REASON_LABELS のキーの並びと同じにする（テストで固定）。
 */
const REPORT_REASONS = Object.freeze(["inappropriate", "spam", "harassment", "copyright", "other"]);
/**
 * 通報の理由の日本語名（Discord の本文に出す・release-gate 要件7.2）。
 * ⚠️ iOS の ReportReason.displayName と同じ文にする（通報した人が選んだ名前と、開発者が見る名前をそろえる）。
 */
const REPORT_REASON_LABELS = Object.freeze({
  inappropriate: "不適切なコンテンツ",
  spam: "スパム・迷惑行為",
  harassment: "嫌がらせ・誹謗中傷",
  copyright: "著作権侵害",
  other: "その他",
});
/** 投稿の画像の幅・高さの上限（ピクセル）。旧ルールの isValidSoratomoDimension と同じ（release-gate 要件11.5）。 */
const SKY_DIMENSION_MAX = 2048;
/** 投稿のキャプションの上限（コードポイント数）。旧ルールの isValidSoratomoCaption と同じ（soratomo 要件11.11）。 */
const CAPTION_MAX = 100;

/**
 * グループID・投稿IDの形（Firestore の自動ID＝英数字。実際は20文字だが、テストの短いIDも通すため 1〜64 文字）。
 * 「_」を許さないのは、通報の記録のID（{groupId}_{skyId}_{reporterId}）を、別の組と同じにしないため。
 * グループの作成（soratomoStore.createGroupTx の doc()）も、アプリの投稿ID（SoratomoSkyService.newSkyId の
 * document().documentID）も自動IDなので、正しい要求はこの形から外れない。
 */
const AUTO_ID_PATTERN = /^[A-Za-z0-9]{1,64}$/;
/** キャプションに含めてはいけない改行類（CR・LF・U+0085・U+2028・U+2029。旧ルールと同じ5種）。 */
const CAPTION_LINE_BREAKS = /[\r\n\u0085\u2028\u2029]/u;
/** カタカナのうち、対応するひらがながあるもの（ァ〜ヶ U+30A1〜U+30F6・ヽヾ U+30FD〜U+30FE）。 */
const KATAKANA_WITH_HIRAGANA = /[\u30A1-\u30F6\u30FD\u30FE]/gu;
/** カタカナとひらがなのコードポイントの差（ア U+30A2 − あ U+3042）。 */
const KATAKANA_TO_HIRAGANA_OFFSET = 0x60;
/** Discord の本文で、読めない値の代わりに出す語。 */
const UNKNOWN_LABEL = "不明";

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

// MARK: - NGワード（公開前ゲート・release-gate 要件11.2）
//
// ⚠️ 該当した語は、戻り値・ログ・応答のどこにも出さない（要件11.9・14.2）。ここは真偽値だけを返す。

/**
 * NGワードの照合のための正規化。語と入力の両方に同じものをかける。
 * 順序: NFKC（全角英数→半角・半角カナ→全角カナ。半角の濁点も1文字に合成される）→ 小文字 →
 *       カタカナ（ひらがなのあるもの）→ ひらがな。
 * 空白と記号は取り除かない（要件11の補足。「て す と」は「てすと」と同じにしない）。
 * @param {string} text
 * @returns {string}
 */
function normalizeForNgCheck(text) {
  return text
    .normalize("NFKC")
    .toLowerCase()
    .replace(KATAKANA_WITH_HIRAGANA, (ch) => String.fromCodePoint(ch.codePointAt(0) - KATAKANA_TO_HIRAGANA_OFFSET));
}

/**
 * 語のリスト（soratomoConfig/ngWords の words）を照合に使える形にする。
 * 正規化し、文字列でないもの・空・空白だけの語・重複を除く。
 * 空や空白だけの語を残すと「どの文にも含まれる」と判定され、すべての作成と投稿を拒否してしまうため除く。
 * @param {unknown} rawWords
 * @returns {string[]} 正規化済みの語（元の並びで、重複は最初の1つだけ）
 */
function prepareNgWords(rawWords) {
  if (!Array.isArray(rawWords)) return [];
  const prepared = new Set();
  for (const raw of rawWords) {
    if (typeof raw !== "string") continue;
    const word = normalizeForNgCheck(raw);
    if (word.trim().length === 0) continue;
    prepared.add(word);
  }
  return [...prepared];
}

/**
 * 入力が、語のいずれかを一部に含むか（正規化した部分一致）。
 * @param {unknown} text グループ名やキャプション。文字列でなければ（キャプション無しなど）該当しない
 * @param {string[]} preparedWords prepareNgWords の戻り値
 * @returns {boolean}
 */
function containsNgWord(text, preparedWords) {
  if (typeof text !== "string" || text.length === 0) return false;
  const normalized = normalizeForNgCheck(text);
  // 空の語は "".includes ではなく text.includes("") で常に真になる。準備を通さずに渡されても全部を拒否しない。
  return preparedWords.some((word) => word.length > 0 && normalized.includes(word));
}

// MARK: - 投稿の入力の検査（公開前ゲート・release-gate 要件11.5）

/**
 * グループID・投稿IDの形か（英数字の自動ID）。
 * @param {unknown} value
 * @returns {boolean}
 */
function isAutoId(value) {
  return typeof value === "string" && AUTO_ID_PATTERN.test(value);
}

/**
 * 画像の幅・高さとして正しいか（1〜2048 の整数）。旧ルールの isValidSoratomoDimension と同じ。
 * @param {unknown} value
 * @returns {boolean}
 */
function isValidDimension(value) {
  return Number.isInteger(value) && value >= 1 && value <= SKY_DIMENSION_MAX;
}

/**
 * キャプションとして正しいか（1〜100 コードポイントの文字列で、改行類5種を含まない）。旧ルールの
 * isValidSoratomoCaption と同じ。長さは UTF-16 の単位でなくコードポイントで数える（絵文字1つが1）。
 * @param {unknown} value
 * @returns {boolean}
 */
function isValidCaption(value) {
  if (typeof value !== "string") return false;
  const length = codePointLength(value);
  return length >= 1 && length <= CAPTION_MAX && !CAPTION_LINE_BREAKS.test(value);
}

/**
 * 投稿の作成の要求（Callable soratomoCreateSky）を検査する。条件は、作成を閉じる前のルール
 * （firestore.rules の isValidSoratomoSky）と同じ（幅と高さは 1〜2048 の整数、キャプションは無いか
 * 1〜100 コードポイントで改行類5種を含まない）。投稿者と作成日時はサーバーが決めるので、要求からは受け取らない。
 * - キャプションは「キーが無い」ときだけ省略を認める（旧ルールの !('caption' in data) と同じ）。null は拒否する。
 * - 余分な項目（画像のパスや URL など）は拒否せず、書く値に持ち込まない（書く項目はサーバーが5つに固定する）。
 * @param {unknown} data 要求の本文
 * @returns {{ ok: true, value: { groupId: string, skyId: string, caption: string|null, width: number, height: number } }
 *   | { ok: false }}
 */
function validateSkyInput(data) {
  if (!data || typeof data !== "object" || Array.isArray(data)) return { ok: false };
  const { groupId, skyId, width, height } = data;
  if (!isAutoId(groupId) || !isAutoId(skyId)) return { ok: false };
  if (!isValidDimension(width) || !isValidDimension(height)) return { ok: false };
  const hasCaption = Object.prototype.hasOwnProperty.call(data, "caption");
  if (hasCaption && !isValidCaption(data.caption)) return { ok: false };
  return { ok: true, value: { groupId, skyId, caption: hasCaption ? data.caption : null, width, height } };
}

// MARK: - 利用停止（公開前ゲート・release-gate 要件8.6）

/**
 * 利用者の文書の suspendedAt から、停止中かを判定する。未設定（undefined）と null 以外の値があれば停止中。
 * 型は問わず、値があれば止める側に倒す。作成・参加・投稿の検査（soratomoStore）と、削除で利用者の文書を残すか・
 * 停止の日時を書くかの判定（soratomoDeletion）が、この1つを使う（判定がずれると停止をすり抜けられるため）。
 * @param {unknown} suspendedAt
 * @returns {boolean}
 */
function isSuspended(suspendedAt) {
  return suspendedAt !== undefined && suspendedAt !== null;
}

// MARK: - 通報（公開前ゲート・release-gate 要件6.6・6.7・7.2）

/**
 * 通報の理由として認める値か（5つ）。
 * @param {unknown} value
 * @returns {boolean}
 */
function isReportReason(value) {
  return typeof value === "string" && REPORT_REASONS.includes(value);
}

/**
 * 通報の記録の文書ID（{groupId}_{skyId}_{reporterId}）。同じ人が同じ投稿を2回通報しても、同じ ID になる（6.7）。
 * groupId と skyId は「_」を含まない自動IDに限るので、区切りの位置が1つに決まり、別の組と同じ ID にならない。
 * 呼び手は先に検査しているので、ここで外れるのは実装の誤り（TypeError・配線で internal になる）。
 * @param {string} groupId
 * @param {string} skyId
 * @param {string} reporterId 通報者の uid（認証から取る）
 * @returns {string}
 */
function reportDocId(groupId, skyId, reporterId) {
  if (!isAutoId(groupId) || !isAutoId(skyId)) {
    throw new TypeError("soratomo: reportDocId の groupId・skyId が自動IDの形でない");
  }
  if (typeof reporterId !== "string" || reporterId.length === 0 || reporterId.length > 128 || reporterId.includes("/")) {
    throw new TypeError("soratomo: reportDocId の reporterId が文書IDとして使えない");
  }
  return `${groupId}_${skyId}_${reporterId}`;
}

/**
 * Discord の本文で、ID をコードの書式（`…`）で囲む。ID の「_」が斜体の印として読まれて消えるのを防ぎ、
 * コピーしやすくする。文字列でない・空なら「不明」。
 * @param {unknown} id
 * @returns {string}
 */
function idField(id) {
  return typeof id === "string" && id.length > 0 && !id.includes("`") ? `\`${id}\`` : UNKNOWN_LABEL;
}

/**
 * 通報を Discord へ送る本文（Webhook の JSON）を組み立てる（要件7.1・7.2）。
 * 載せるのは、理由（日本語の名前と値）・通報の記録のID・グループID・投稿ID・投稿者と通報者の uid・受け付けた時刻だけ。
 * 記録に別の項目が混ざっていても、決まった項目だけを拾うので、キャプション・グループ名・表示名・招待コード・
 * 画像とその URL は本文に出ない。知らない理由は入力の文字列を出さずに「不明」にする。
 * @param {{ reportId?: unknown, groupId?: unknown, skyId?: unknown, authorId?: unknown, reporterId?: unknown,
 *   reason?: unknown, createdAt?: unknown }} report 通報の記録（createdAt は Timestamp かミリ秒）
 * @returns {Object}
 */
function buildReportForwardPayload(report) {
  const reason = isReportReason(report.reason) ? `${REPORT_REASON_LABELS[report.reason]}（${report.reason}）` : UNKNOWN_LABEL;
  const embed = {
    title: "そらともの通報が届きました",
    color: 0xd9534f, // 通報（赤系）。フィードバックの空色と見分ける
    fields: [
      { name: "理由", value: reason, inline: false },
      { name: "reportId", value: idField(report.reportId), inline: false },
      { name: "groupId", value: idField(report.groupId), inline: true },
      { name: "skyId", value: idField(report.skyId), inline: true },
      { name: "投稿者のuid", value: idField(report.authorId), inline: false },
      { name: "通報者のuid", value: idField(report.reporterId), inline: false },
    ],
  };
  const createdMs = toMillisOrNull(report.createdAt);
  if (createdMs !== null) embed.timestamp = new Date(createdMs).toISOString();
  return {
    username: "そらとも 通報",
    embeds: [embed],
    // 本文の文字列から @ の通知を飛ばさない（ID だけなので通常は起きないが、念のため止めておく）
    allowed_mentions: { parse: [] },
  };
}

// MARK: - オーナーの決定とメンバーを外す計画（公開前ゲート・release-gate 要件2）

/**
 * 参加日時（ミリ秒）として読める値か。数値で有限のときだけ読み、それ以外は「無い」とみなす。
 * @param {unknown} value
 * @returns {number|null}
 */
function joinedAtOrNull(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

/**
 * メンバーの並び: 参加日時の古い順（無いものは最後）、同じなら uid の昇順。
 * iOS の SoratomoGroupService.sortedForMembers（メンバー一覧の並び）と同じ規則（要件2の補足）。
 * uid は英数字なので、JS の < と Swift の < は同じ順になる。
 * @param {{ uid: string, joinedAtMs: unknown }} a
 * @param {{ uid: string, joinedAtMs: unknown }} b
 * @returns {number}
 */
function compareByJoinOrder(a, b) {
  const ta = joinedAtOrNull(a.joinedAtMs);
  const tb = joinedAtOrNull(b.joinedAtMs);
  if (ta !== tb) {
    if (ta === null) return 1;
    if (tb === null) return -1;
    return ta - tb;
  }
  if (a.uid === b.uid) return 0;
  return a.uid < b.uid ? -1 : 1;
}

/**
 * 次のオーナーを1人選ぶ（要件2.5）。参加日時の古い順（無いものは最後）、同じなら uid の昇順で先頭の人。
 * 入力の配列は並べ替えない。
 * @param {Array<{ uid: string, role?: string, joinedAtMs: unknown }>} members
 * @returns {string|null} 0人なら null
 */
function pickNextOwner(members) {
  if (members.length === 0) return null;
  return [...members].sort(compareByJoinOrder)[0].uid;
}

/**
 * 退会者をグループから外す計画を立てる（要件2.1・2.2・2.5・2.6・2.7・2.9・3.4）。書き込みは呼び手
 * （soratomoDeletion のトランザクション）が行う。招待コードには触れない（2.7）。
 * - 残りが0人: グループごと削除（delete_group）
 * - 残りがいる: 人数を残りの数にし（数え直して代入・2.11）、オーナーが残りにいなければ選び直し（2.5）、
 *   残りの全員の役割を「オーナー1人・ほかは member」にそろえる更新を返す（2.6）。更新は変わる人の分だけ。
 * - 退会者がすでにメンバーでない再実行でも、同じ整え方を返す（removed が false になるだけ・3.4）。
 * @param {{ uid: string, ownerId: unknown, members: Array<{ uid: string, role?: string, joinedAtMs: unknown }> }} args
 *   members はトランザクションで読んだメンバーの全文書（退会者を含んでいてもよい）
 * @returns {{ kind: "delete_group", removed: boolean }
 *   | { kind: "leave", removed: boolean, memberCount: number, ownerId: string, ownerTransferred: boolean,
 *       roleUpdates: Array<{ uid: string, role: "owner"|"member" }> }}
 */
function planMembershipRemoval({ uid, ownerId, members }) {
  const removed = members.some((m) => m.uid === uid);
  const remaining = members.filter((m) => m.uid !== uid);
  if (remaining.length === 0) return { kind: "delete_group", removed };

  const ownerStays = typeof ownerId === "string" && remaining.some((m) => m.uid === ownerId);
  const nextOwnerId = ownerStays ? ownerId : pickNextOwner(remaining);
  const roleUpdates = [];
  for (const m of remaining) {
    const role = m.uid === nextOwnerId ? "owner" : "member";
    if (m.role !== role) roleUpdates.push({ uid: m.uid, role });
  }
  return {
    kind: "leave",
    removed,
    memberCount: remaining.length,
    ownerId: nextOwnerId,
    ownerTransferred: nextOwnerId !== ownerId,
    roleUpdates,
  };
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
  // 公開前ゲート（soratomo-release-gate）
  GUIDELINE_VERSION,
  REPORT_REASONS,
  REPORT_REASON_LABELS,
  SKY_DIMENSION_MAX,
  CAPTION_MAX,
  normalizeForNgCheck,
  prepareNgWords,
  containsNgWord,
  isAutoId,
  validateSkyInput,
  isSuspended,
  isReportReason,
  reportDocId,
  buildReportForwardPayload,
  pickNextOwner,
  planMembershipRemoval,
};
