#!/usr/bin/env node

/**
 * ブロック済みなのに残るフォロー・ID のずれ・項目の欠けを数え、決めた区分だけを消す運用の台本 ☁️⭐️（D-1）
 *
 * ■ なぜ要るか
 *   PR-B（#190）の Functions（onUserBlockListChanged）は、これから増えるブロックに合わせて両方向のフォローを片付ける。
 *   それより前からあるブロック済みの組の follows は、この台本で運用として数えて片付ける。
 *   また Functions は文書 ID を決め打ちで消す（中身は読まない）一方、数え直し・あなた向けフィード・新着通知は
 *   項目（followerId・followeeId）で探すので、ID がずれた文書と項目の欠けた文書も別に数える。
 *
 * ■ 区分（U＝ブロックした人・X＝ブロックされた人）
 *   「ブロック済み」は functions/followBlock.js の normalizeBlockedIds で正規化した一覧で判定する（Functions と同じ基準）。
 *   1a  X_U（ID も項目も正しい）  ブロックされた人が、ブロックした人をフォローしている
 *   1b  U_X（同上）               ブロックした本人が、相手をフォローしている
 *       1a・1b は文書の createTime（Firestore が付ける作成時刻。アプリから書き換えられない）で、deploy の前（-before）と
 *       後（-after）に分ける。中の createdAt はアプリが入れる値なので使わない。境目ちょうどは後（消さない側）。
 *       両方からブロックしている組の文書は 1a にも 1b にも数え、「うち重なり n 件」を出す
 *   2a  ID ≠ {followerId}_{followeeId}（項目は正しい）で、正しい ID の文書もある（重複）
 *   2b  ID がずれていて、正しい ID の文書は無い
 *   3   followerId か followeeId が無い・文字列でない・空・「/」を含む（followerId だけ・followeeId だけ・両方に分ける）
 *
 * ■ コマンド
 *   count [--list]
 *     各区分の件数・走査した件数と follows.count()（集計の問い合わせ）の一致・blockedUserIds の捨てた値の件数を出す。
 *     --list を付けたときだけ、文書 ID と uid を並べる。完全性が一致しなければ終了コード 1
 *     （「本当に 0 件」と「ページングで読み落とした」を見分ける唯一の手がかりなので）
 *   delete --targets <区分,...> --expect <区分=件数,...> --backup-dir <フォルダ>
 *     消せる区分は今は 1a-before・1b-before だけ（ほかの区分は決めた後で、この台本を直して足す）。
 *     1. 写しの置き場を確かめる（あるフォルダで、リポジトリの外。違えば何も読まずに止める）
 *     2. follows を中身ごと読み直して、今の状態で分け直す（count から時間が経っていても、今の状態で判定する）
 *     3. 完全性と --expect を照らす。どちらかが違えば、何も書かず・消さずに止める
 *     4. 消す文書の写しを JSON で置き場に書く（chmod 600・同じ名前があれば上書きせずに失敗する）
 *     5. 件数を出して yes を打たせる
 *     6. 1 件ずつ lastUpdateTime 付きで消す（読んだ後に変わった文書は消さずに「飛ばした」に数える。
 *        失敗は 1 件ごとに閉じ込めて残りを続ける＝batch にしない。backfill-follow-counters.js と同じ理由）
 *   戻すとき: 写しの JSON の data を Admin SDK で作り直す（__type: "timestamp" は Timestamp(seconds, nanoseconds)）。
 *   ⚠️ 作り直すと onFollowCreated が「フォローされました」の通知を飛ばす
 *   消した後: onFollowDeleted が両方の uid を数え直す。念のため backfill-follow-counters.js の --dry-run で Changed: 0 を見る
 *
 * ■ 出力の約束
 *   画面に出すのは件数だけ。--list のときだけ文書 ID と uid を出し、ID の形（英数字と「_」「-」）に合わない値は
 *   「（壊れた値）」と出す（soratomo-admin.js と同じ）。users は blockedUserIds だけを select で読む
 *   （FCM のトークン・メールなどは、メモリにもエラー本文にも入れない）。
 *   エラーは code（無ければ名前）だけを出す（本文に資格情報のパスなどが入るため）。自前の「follows-cleanup: 」で
 *   始まるエラー（固定の文言で、利用者の値を含まない）だけ本文を出す。
 *
 * ■ 境目: DEPLOYED_AT_MS（2026-10-16 06:43 JST の firestore.rules と onUserBlockListChanged の deploy）。
 *   ⚠️ 正確な時刻は要確認（Google Cloud コンソールの関数の「最終デプロイ」と、ルールの deploy の遅い方）。
 *   count・delete の出力の 1 行目に出るので、違っていたら流す前に直す。
 *
 * ■ 認証: Application Default Credentials（ADC）。鍵ファイルはリポジトリに置かない（soratomo-admin.js と同じ）。
 *   1. gcloud auth application-default login
 *   2. quota project を求められたら: gcloud auth application-default set-quota-project soramoyou-ios
 *   接続先は EXPECTED_PROJECT_ID（soramoyou-ios）に固定している（.firebaserc が空のため。ADC の既定に頼らない）。
 *
 * ■ 実行方法（リポジトリ直下で。firebase-admin は functions/ の依存を借りる＝functions で npm install 済みであること）
 *     node scripts/follows-cleanup.js count
 *     node scripts/follows-cleanup.js count --list
 *     node scripts/follows-cleanup.js delete --targets 1a-before,1b-before --expect 1a-before=<n>,1b-before=<n> \
 *       --backup-dir <リポジトリの外のフォルダ>
 *   ⚠️ エミュレーターを指す環境変数（名前が _EMULATOR_HOST で終わるもの）が1つでもあれば、何もせずに止める
 *      （エミュレーターでの確かめは follows-cleanup.emulator.test.js で cmd* を直接呼ぶ）。
 *   ⚠️ 本番に対する実行は、利用者が自分のターミナルで行う（読み取りだけの count を含む）。
 *
 * ■ 作り（scripts/soratomo-admin.js と同じ）
 *   - 区分の判定（classifyFollows）・引数の解釈・出力の組み立ては純関数。処理は cmd*(deps, args) → { lines, exitCode } で、
 *     deps に Firestore の窓口（createFirestoreStore）・境目・確認・時計を差し込む。
 *   - firebase-admin は main の中でだけ読み込む。main は export しない（テストから本番に繋ぐ口を作らない）。
 *
 * ■ テスト
 *   単体: node --test scripts/follows-cleanup.test.js（偽の窓口・firebase-admin 非依存。本番には触れない）
 *   エミュレーター: scripts/follows-cleanup.emulator.test.js の冒頭を参照
 */

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { createRequire } = require("node:module");
const { normalizeBlockedIds } = require("../functions/followBlock");

// MARK: - 定数

/** 接続先として唯一許可する Firebase プロジェクト（.firebaserc が空のため、ここで固定する）。 */
const EXPECTED_PROJECT_ID = "soramoyou-ios";

/**
 * deploy の境目（firestore.rules と onUserBlockListChanged の deploy・記録は「10/16 06:43 JST」）。
 * ⚠️ 正確な時刻は要確認。これより前に作られた 1a・1b を「deploy 前」として消す。
 */
const DEPLOYED_AT_MS = Date.parse("2026-10-16T06:43:00+09:00");

/** コレクションの名前（iOS の FirestoreService と同じ綴り）。 */
const FOLLOWS = "follows";
const USERS = "users";

/** 1 回の問い合わせで読む文書の数（ページの大きさ）。 */
const PAGE_SIZE = 500;

/** delete の --targets に受け付ける区分（10/18 の決定。ほかの区分は決めた後で足す）。 */
const DELETE_TARGETS = Object.freeze(["1a-before", "1b-before"]);

/** 区分の並び（出力と --list の順）。 */
const CATEGORY_KEYS = Object.freeze([
  "1a-before",
  "1a-after",
  "1b-before",
  "1b-after",
  "2a",
  "2b",
  "3-followerId",
  "3-followeeId",
  "3-both",
]);

/** リポジトリの直下（写しの置き場をこの中にさせないため）。 */
const REPO_ROOT = path.join(__dirname, "..");

/** functions/ を起点にした require。firebase-admin はこれで読む（main の中でだけ・soratomo-admin.js と同じ）。 */
const functionsRequire = createRequire(path.join(__dirname, "..", "functions", "package.json"));

/** 出力してよい ID の形（英数字と「_」「-」）。Firebase が作る uid と自動 ID はここに入る。 */
const PRINTABLE_ID = /^[A-Za-z0-9_-]{1,128}$/;

/** 日本時間のずれ（出力の境目の行で使う）。 */
const JST_OFFSET_MS = 9 * 60 * 60 * 1000;

const USAGE = [
  "使い方: node scripts/follows-cleanup.js <コマンド> ...",
  "  count [--list]",
  "  delete --targets 1a-before[,1b-before] --expect 1a-before=<件数>[,1b-before=<件数>] --backup-dir <リポジトリの外のフォルダ>",
].join("\n");

// MARK: - 値の形

/**
 * follows の項目として使える uid か（文字列・空でない・「/」を含まない）。normalizeBlockedIds が捨てる値と同じ基準。
 * @param {unknown} value
 * @returns {boolean}
 */
function isUidField(value) {
  return typeof value === "string" && value.length > 0 && !value.includes("/");
}

/**
 * 出力してよい ID か（--list で文書 ID と uid を出す前に確かめる）。
 * @param {unknown} value
 * @returns {boolean}
 */
function isPrintableId(value) {
  return typeof value === "string" && PRINTABLE_ID.test(value);
}

/**
 * 値を、ID の形のときだけそのまま、無ければ「（無い）」、それ以外は「（壊れた値）」にする（出力に名前などを混ぜない）。
 * @param {unknown} value
 * @returns {string}
 */
function shown(value) {
  if (value === undefined || value === null) return "（無い）";
  return isPrintableId(value) ? value : "（壊れた値）";
}

/** Firestore の時刻か（Timestamp・偽物は toMillis と秒・ナノ秒を持つ）。 */
function isTimestamp(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    typeof value.toMillis === "function" &&
    typeof value.seconds === "number" &&
    typeof value.nanoseconds === "number"
  );
}

/**
 * 区分の判定に使う作成時刻（ミリ秒）。無ければ推測で前後を決めずに投げる（消す側に倒さないため）。
 * @param {unknown} time 文書の createTime
 * @returns {number}
 */
function createMillisOf(time) {
  if (!time || typeof time.toMillis !== "function") {
    throw new Error("follows-cleanup: createTime が取れない文書がある（読み方を見直すまで、前後を判定しない）");
  }
  return time.toMillis();
}

/** 時刻を ISO 8601 の文字列にする。無ければ「（無い）」。 */
function isoOf(time) {
  return time && typeof time.toMillis === "function" ? new Date(time.toMillis()).toISOString() : "（無い）";
}

/** 時刻を写しの JSON の形にする（戻すときは Timestamp(seconds, nanoseconds)）。 */
function timeJson(time) {
  if (!isTimestamp(time)) return null;
  return { __type: "timestamp", seconds: time.seconds, nanoseconds: time.nanoseconds, iso: new Date(time.toMillis()).toISOString() };
}

/**
 * 文書の中身を JSON に書ける形にする（Timestamp は timeJson、配列とただのオブジェクトは中まで）。
 * follows に入らないはずの型（参照・位置など）は、型の名前だけを残す（循環する中身を書き出さない）。
 * @param {unknown} value
 * @returns {unknown}
 */
function toJsonValue(value) {
  if (isTimestamp(value)) return timeJson(value);
  if (Array.isArray(value)) return value.map(toJsonValue);
  if (value !== null && typeof value === "object") {
    const proto = Object.getPrototypeOf(value);
    if (proto !== Object.prototype && proto !== null) {
      return { __type: "unsupported", constructor: (value.constructor && value.constructor.name) || "不明" };
    }
    return Object.fromEntries(Object.entries(value).map(([key, v]) => [key, toJsonValue(v)]));
  }
  return value;
}

// MARK: - 区分の判定

/**
 * blockedUserIds の捨てた値を数える（normalizeBlockedIds が黙って捨てる値を、件数だけ見えるようにする）。
 * 項目が無い（undefined・null）人は数えない（ブロックしたことの無い人）。
 * @param {Array<{ id: string, blockedUserIds: unknown }>} users
 * @returns {{ notArray: number, invalid: number, self: number, duplicate: number }}
 */
function countDropped(users) {
  const dropped = { notArray: 0, invalid: 0, self: 0, duplicate: 0 };
  for (const u of users) {
    const value = u.blockedUserIds;
    if (value === undefined || value === null) continue;
    if (!Array.isArray(value)) {
      dropped.notArray += 1;
      continue;
    }
    const seen = new Set();
    for (const id of value) {
      if (!isUidField(id)) dropped.invalid += 1;
      else if (id === u.id) dropped.self += 1;
      else if (seen.has(id)) dropped.duplicate += 1;
      else seen.add(id);
    }
  }
  return dropped;
}

/**
 * follows を区分に分ける（純関数）。
 * @param {Array<{ id: string, followerId: unknown, followeeId: unknown, createTime: unknown }>} follows
 * @param {Array<{ id: string, blockedUserIds: unknown }>} users
 * @param {{ deployedAtMs: number }} options 境目（これより前に作られた文書が -before）
 * @returns {{ scanned: number, categories: Record<string, Object[]>, overlap: { before: number, after: number },
 *   offIdBlocked: { "2a": number, "2b": number }, dropped: { notArray: number, invalid: number, self: number, duplicate: number } }}
 */
function classifyFollows(follows, users, { deployedAtMs }) {
  const categories = Object.fromEntries(CATEGORY_KEYS.map((key) => [key, []]));
  const overlap = { before: 0, after: 0 };
  const offIdBlocked = { "2a": 0, "2b": 0 };

  // uid → その人がブロックしている相手（Functions と同じ正規化。自分自身・文字列でない値などは落ちる）
  const blockedBy = new Map(users.map((u) => [u.id, new Set(normalizeBlockedIds(u.blockedUserIds, u.id))]));
  const blocks = (blocker, blocked) => {
    const set = blockedBy.get(blocker);
    return set !== undefined && set.has(blocked);
  };
  const docIds = new Set(follows.map((f) => f.id));

  for (const f of follows) {
    const followerOk = isUidField(f.followerId);
    const followeeOk = isUidField(f.followeeId);
    if (!followerOk || !followeeOk) {
      const key = !followerOk && !followeeOk ? "3-both" : !followerOk ? "3-followerId" : "3-followeeId";
      categories[key].push(f);
      continue;
    }

    // 1a の向き: フォローされている人（followee）が、フォローしている人（follower）をブロックしている
    const followeeBlocksFollower = blocks(f.followeeId, f.followerId);
    // 1b の向き: フォローしている人（follower）が、フォローされている人（followee）をブロックしている
    const followerBlocksFollowee = blocks(f.followerId, f.followeeId);

    const expectedId = `${f.followerId}_${f.followeeId}`;
    if (f.id !== expectedId) {
      // ID がずれた文書は Functions のブロック時の削除でも Storage Rules でも ID で引かれないので、1a・1b には入れない
      const key = docIds.has(expectedId) ? "2a" : "2b";
      categories[key].push(f);
      if (followeeBlocksFollower || followerBlocksFollowee) offIdBlocked[key] += 1;
      continue;
    }

    if (!followeeBlocksFollower && !followerBlocksFollowee) continue;
    // 境目ちょうどは「後」（消さない側）
    const when = createMillisOf(f.createTime) < deployedAtMs ? "before" : "after";
    if (followeeBlocksFollower) categories[`1a-${when}`].push(f);
    if (followerBlocksFollowee) categories[`1b-${when}`].push(f);
    if (followeeBlocksFollower && followerBlocksFollowee) overlap[when] += 1;
  }

  for (const key of CATEGORY_KEYS) categories[key].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return { scanned: follows.length, categories, overlap, offIdBlocked, dropped: countDropped(users) };
}

// MARK: - 引数の解釈

/**
 * コマンドラインの引数を読む。足りない・余る・形の違う引数は、何も読み書きする前に { ok: false } で止める。
 * @param {string[]} argv process.argv.slice(2)
 * @returns {{ ok: false } | { ok: true, command: "count", list: boolean }
 *   | { ok: true, command: "delete", targets: string[], expect: Record<string, number>, backupDir: string }}
 */
function parseArgs(argv) {
  const [command, ...rest] = argv;
  if (command === "count") {
    if (rest.length === 0) return { ok: true, command, list: false };
    if (rest.length === 1 && rest[0] === "--list") return { ok: true, command, list: true };
    return { ok: false };
  }
  // delete は 3 つの引数（名前と値の組）を、順番を問わずにちょうど 1 回ずつ
  if (command !== "delete" || rest.length !== 6) return { ok: false };
  const options = {};
  for (let i = 0; i < rest.length; i += 2) {
    const name = rest[i];
    const value = rest[i + 1];
    if (!["--targets", "--expect", "--backup-dir"].includes(name) || Object.hasOwn(options, name)) return { ok: false };
    // 値が「-」で始まるのは引数の取り違え（--backup-dir --list など）
    if (typeof value !== "string" || value.length === 0 || value.startsWith("-")) return { ok: false };
    options[name] = value;
  }

  const targets = options["--targets"].split(",");
  if (targets.some((t) => !DELETE_TARGETS.includes(t)) || new Set(targets).size !== targets.length) return { ok: false };

  const expect = {};
  for (const pair of options["--expect"].split(",")) {
    const m = /^([^=]+)=(\d+)$/.exec(pair);
    if (!m || Object.hasOwn(expect, m[1])) return { ok: false };
    expect[m[1]] = Number(m[2]);
  }
  // --expect の区分は --targets とちょうど同じ（足りない・余るは打ち間違い）
  if (Object.keys(expect).length !== targets.length || targets.some((t) => !Object.hasOwn(expect, t))) return { ok: false };

  return { ok: true, command, targets, expect, backupDir: options["--backup-dir"] };
}

// MARK: - 出力の組み立て

/** 境目の行（count・delete の 1 行目）。 */
function boundaryLine(deployedAtMs) {
  const jst = new Date(deployedAtMs + JST_OFFSET_MS).toISOString().slice(0, 19).replace("T", " ");
  return `境目（deploy の時刻）: ${new Date(deployedAtMs).toISOString()}（日本時間 ${jst}）`;
}

/** 完全性の行（走査した件数と follows.count() の一致）。 */
function completenessLine(scanned, total) {
  const verdict =
    scanned === total ? "一致" : "❌ 一致しない（読み落としか、走査の間に増減した。もう一度 count を流す）";
  return `走査した follows: ${scanned} 件・follows.count(): ${total} 件 → ${verdict}`;
}

/**
 * count の件数の行。
 * @param {ReturnType<typeof classifyFollows>} result
 * @param {{ deployedAtMs: number, total: number, usersCount: number }} context
 * @returns {string[]}
 */
function summaryLines(result, { deployedAtMs, total, usersCount }) {
  const n = (key) => result.categories[key].length;
  const { overlap, offIdBlocked, dropped } = result;
  return [
    boundaryLine(deployedAtMs),
    completenessLine(result.scanned, total),
    `走査した users: ${usersCount} 人`,
    `1a ブロックされた人 → ブロックした人: deploy 前 ${n("1a-before")} 件・deploy 後 ${n("1a-after")} 件`,
    `1b ブロックした人 → ブロックされた人: deploy 前 ${n("1b-before")} 件・deploy 後 ${n("1b-after")} 件`,
    `  うち重なり ${overlap.before + overlap.after} 件（1a と 1b の両方に数えた＝両方からブロックしている組の文書。` +
      `deploy 前 ${overlap.before} 件・deploy 後 ${overlap.after} 件）`,
    `2a ID がずれた重複（正しい ID の文書もある）: ${n("2a")} 件（うちブロック済みの組 ${offIdBlocked["2a"]} 件）`,
    `2b ID がずれていて、正しい ID の文書は無い: ${n("2b")} 件（うちブロック済みの組 ${offIdBlocked["2b"]} 件）`,
    `3 項目が欠けた・壊れた: followerId だけ ${n("3-followerId")} 件・followeeId だけ ${n("3-followeeId")} 件・` +
      `両方 ${n("3-both")} 件`,
    `blockedUserIds の捨てた値: 配列でない ${dropped.notArray} 人・文字列でない／空／「/」を含む ${dropped.invalid} 件・` +
      `自分自身 ${dropped.self} 件・重複 ${dropped.duplicate} 件`,
  ];
}

/** count --list の行（区分ごとに、文書 ID・uid・作成時刻）。 */
function listLines(result) {
  const lines = ["一覧（--list）:"];
  for (const key of CATEGORY_KEYS) {
    for (const f of result.categories[key]) {
      lines.push(`  [${key}] ${shown(f.id)}  ${shown(f.followerId)} → ${shown(f.followeeId)}  作成 ${isoOf(f.createTime)}`);
    }
  }
  return lines;
}

/**
 * 写しの JSON の中身。
 * @param {Array<{ record: Object, categories: string[] }>} docs 消す文書（文書 ID の順）
 */
function backupOf(docs, { deployedAtMs, targets, expect, nowMs }) {
  return {
    note:
      "D-1 の delete が消す前に書いた写し。戻すときは data を Admin SDK で作り直す" +
      "（__type: timestamp は Timestamp(seconds, nanoseconds)）。作り直すと onFollowCreated が通知を飛ばす",
    writtenAt: new Date(nowMs).toISOString(),
    deployedAt: new Date(deployedAtMs).toISOString(),
    targets,
    expect,
    docs: docs.map(({ record, categories }) => ({
      id: record.id,
      categories,
      data: toJsonValue(record.data),
      createTime: timeJson(record.createTime),
      updateTime: timeJson(record.updateTime),
    })),
  };
}

/**
 * 写しの置き場の問題（無ければ null）。あるフォルダで、リポジトリの外でなければならない。
 * シンボリックリンクで中を指していないよう、実体のパス同士で比べる。
 * @param {string} dir
 * @returns {string|null}
 */
function backupDirProblem(dir) {
  let real;
  try {
    real = fs.realpathSync(path.resolve(dir));
  } catch {
    return "が無い（先に mkdir -m 700 で作る）";
  }
  if (!fs.statSync(real).isDirectory()) return "がフォルダでない";
  const root = fs.realpathSync(REPO_ROOT);
  if (real === root || real.startsWith(root + path.sep)) {
    return "がリポジトリの中（写しをコミットしないよう、リポジトリの外を指す）";
  }
  return null;
}

/** 写しのファイル名に使う時刻（ファイル名に使えない「:」「.」を「-」にする）。 */
function stampOf(ms) {
  return new Date(ms).toISOString().replace(/[:.]/g, "-");
}

// MARK: - 読み取り

/**
 * follows（full なら中身ごと）と users を読み、最後に follows.count() を取る（走査の後に数えて、読み落としを見つける）。
 * @param {ReturnType<typeof createFirestoreStore>} store
 * @param {{ full: boolean }} options
 */
async function readAll(store, { full }) {
  const follows = await store.scanFollows({ full });
  const users = await store.scanUsers();
  const total = await store.countFollows();
  return { follows, users, total };
}

/**
 * Firestore の窓口（本物）。テストでは同じ 4 つの口を持つ偽物を差し込む。
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ pageSize?: number }} [options]
 */
function createFirestoreStore(db, { pageSize = PAGE_SIZE } = {}) {
  /** コレクションを文書 ID の順にページに分けて全部読む（fields を渡すと select で項目を絞る）。 */
  async function scanAll(collection, fields) {
    const docs = [];
    let last = null;
    for (;;) {
      let query = db.collection(collection);
      if (fields) query = query.select(...fields);
      query = query.orderBy("__name__").limit(pageSize);
      if (last) query = query.startAfter(last);
      const snap = await query.get();
      docs.push(...snap.docs);
      if (snap.docs.length < pageSize) return docs;
      last = snap.docs[snap.docs.length - 1];
    }
  }

  return {
    /** follows を読む。full でなければ followerId・followeeId だけを select で読む（count 用）。 */
    async scanFollows({ full }) {
      const docs = await scanAll(FOLLOWS, full ? null : ["followerId", "followeeId"]);
      return docs.map((doc) => ({
        id: doc.id,
        followerId: doc.get("followerId"),
        followeeId: doc.get("followeeId"),
        createTime: doc.createTime,
        updateTime: doc.updateTime,
        ...(full ? { data: doc.data() } : {}),
      }));
    },
    /** users を blockedUserIds だけ読む（FCM のトークン・メールなどはメモリに入れない）。 */
    async scanUsers() {
      const docs = await scanAll(USERS, ["blockedUserIds"]);
      return docs.map((doc) => ({ id: doc.id, blockedUserIds: doc.get("blockedUserIds") }));
    },
    /** follows の件数（集計の問い合わせ）。 */
    async countFollows() {
      return (await db.collection(FOLLOWS).count().get()).data().count;
    },
    /**
     * 読んだときから変わっていなければ消す。前提の条件が合わない（書き換えられた・作り直された・消された）ときは
     * 消さずに "changed" を返す。gRPC の FAILED_PRECONDITION（9）がそれに当たる（Emulator で、書き換え・作り直し・
     * 消されただけ、のどれも 9 になるのを確かめた）。ほかの code は「失敗」に数える（消していない側に倒す）。
     * @returns {Promise<"deleted"|"changed">}
     */
    async deleteFollow(id, lastUpdateTime) {
      try {
        await db.collection(FOLLOWS).doc(id).delete({ lastUpdateTime });
        return "deleted";
      } catch (err) {
        if (err && err.code === 9) return "changed";
        throw err;
      }
    },
  };
}

// MARK: - コマンド

/**
 * count: 区分ごとに数える（読み取りだけ）。
 * @param {{ store: ReturnType<typeof createFirestoreStore>, deployedAtMs: number }} deps
 * @param {{ list: boolean }} args
 * @returns {Promise<{ lines: string[], exitCode: number }>}
 */
async function cmdCount(deps, { list }) {
  const { follows, users, total } = await readAll(deps.store, { full: false });
  const result = classifyFollows(follows, users, { deployedAtMs: deps.deployedAtMs });
  const lines = summaryLines(result, { deployedAtMs: deps.deployedAtMs, total, usersCount: users.length });
  if (list) lines.push(...listLines(result));
  return { lines, exitCode: result.scanned === total ? 0 : 1 };
}

/**
 * delete: 決めた区分の文書を、写しを書いて確かめてから、1 件ずつ消す（順番はファイル冒頭の「コマンド」）。
 * @param {{ store: ReturnType<typeof createFirestoreStore>, deployedAtMs: number,
 *   confirm: (lines: string[]) => Promise<boolean>, nowMs: () => number }} deps
 * @param {{ targets: string[], expect: Record<string, number>, backupDir: string }} args
 * @returns {Promise<{ lines: string[], exitCode: number }>}
 */
async function cmdDelete(deps, { targets, expect, backupDir }) {
  // 1. 写しの置き場（何かを読む前に確かめる）
  const problem = backupDirProblem(backupDir);
  if (problem !== null) {
    return { lines: [`❌ 写しの置き場 ${backupDir} ${problem}。何も読まずに止めた`], exitCode: 1 };
  }

  // 2. 中身ごと読み直して、今の状態で分け直す
  const { follows, users, total } = await readAll(deps.store, { full: true });
  const result = classifyFollows(follows, users, { deployedAtMs: deps.deployedAtMs });
  const lines = [boundaryLine(deps.deployedAtMs), completenessLine(result.scanned, total)];

  // 3. 完全性と --expect
  if (result.scanned !== total) {
    lines.push("❌ 完全性が一致しないので、何も書かず・消さずに止めた");
    return { lines, exitCode: 1 };
  }
  let expectOk = true;
  for (const target of targets) {
    const now = result.categories[target].length;
    if (now === expect[target]) {
      lines.push(`${target}: 見込み ${expect[target]} 件・今 ${now} 件 → 一致`);
    } else {
      expectOk = false;
      lines.push(`${target}: 見込み ${expect[target]} 件・今 ${now} 件 → ❌ 違うので、何も消さずに止めた`);
    }
  }
  if (!expectOk) return { lines, exitCode: 1 };

  // 区分をまたいで同じ文書（重なり）は 1 回だけ消す。写しには入っていた区分を全部書く
  const byId = new Map();
  for (const target of targets) {
    for (const record of result.categories[target]) {
      if (!byId.has(record.id)) byId.set(record.id, { record, categories: [] });
      byId.get(record.id).categories.push(target);
    }
  }
  const docs = [...byId.values()].sort((a, b) => (a.record.id < b.record.id ? -1 : a.record.id > b.record.id ? 1 : 0));
  const overlapping = docs.filter((d) => d.categories.length > 1).length;
  const perTarget = targets.map((t) => `${t} ${result.categories[t].length} 件`).join("・");
  lines.push(`消す文書: ${docs.length} 件（${perTarget}・うち重なり ${overlapping} 件は 1 回だけ消す）`);
  if (docs.length === 0) {
    lines.push("消すものは無い（写しも書かず、何もしていない）");
    return { lines, exitCode: 0 };
  }

  // 4. 写し（本人だけが読める・同じ名前があれば上書きせずに失敗する）
  const nowMs = deps.nowMs();
  const file = path.join(backupDir, `d1-follows-backup-${stampOf(nowMs)}.json`);
  const backup = backupOf(docs, { deployedAtMs: deps.deployedAtMs, targets, expect, nowMs });
  await fs.promises.writeFile(file, `${JSON.stringify(backup, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  lines.push(`写し: ${file}（${docs.length} 件・chmod 600）`);

  // 5. 確認
  if (!(await deps.confirm([...lines]))) {
    lines.push("やめた（何も消していない。写しは残してある）");
    return { lines, exitCode: 0 };
  }

  // 6. 1 件ずつ、読んだときの updateTime を条件に消す
  let deleted = 0;
  let skipped = 0;
  const failures = new Map();
  for (const { record } of docs) {
    try {
      const outcome = await deps.store.deleteFollow(record.id, record.updateTime);
      if (outcome === "deleted") deleted += 1;
      else skipped += 1;
    } catch (err) {
      const code = String((err && (err.code ?? err.name)) || "不明");
      failures.set(code, (failures.get(code) || 0) + 1);
    }
  }
  const failed = [...failures.values()].reduce((sum, n) => sum + n, 0);
  lines.push(`消した: ${deleted} 件・読んだ後に変わっていたので飛ばした: ${skipped} 件・失敗: ${failed} 件`);
  if (failed > 0) {
    const reasons = [...failures].map(([code, n]) => `${code} が ${n} 件`).join("・");
    lines.push(`失敗の理由: ${reasons}（もう一度 count で今の件数を見てから、--expect を直して流す）`);
  }
  if (skipped > 0) lines.push("飛ばした文書は、もう一度 count で今の状態を見る");
  lines.push("数え直しは onFollowDeleted が行う。終わったら scripts/backfill-follow-counters.js --dry-run で Changed: 0 を見る");
  return { lines, exitCode: failed > 0 ? 1 : 0 };
}

// MARK: - 本体

/**
 * エミュレーターを指す環境変数（名前が _EMULATOR_HOST で終わり、値が空でないもの）の名前を並べる。
 * @param {Record<string, string|undefined>} env
 * @returns {string[]} 名前の昇順
 */
function findEmulatorEnv(env) {
  return Object.keys(env)
    .filter((name) => name.endsWith("_EMULATOR_HOST") && env[name])
    .sort();
}

/** 端末で yes を打たせる（yes のときだけ true）。 */
function askYes(question) {
  const readline = require("node:readline");
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.trim() === "yes");
    });
  });
}

/**
 * 本体。firebase-admin はここでだけ読み込む。export しない（テストから本番に繋ぐ口を作らない）。
 * @param {string[]} argv
 */
async function main(argv) {
  const parsed = parseArgs(argv);
  if (!parsed.ok) {
    console.error(USAGE);
    process.exitCode = 2;
    return;
  }
  const emulatorEnv = findEmulatorEnv(process.env);
  if (emulatorEnv.length > 0) {
    // 値（ホストとポート）は出さず、名前だけ
    console.error(`❌ エミュレーターを指す環境変数があるので止めた（本番専用の台本。外してから実行する）: ${emulatorEnv.join(" ")}`);
    process.exitCode = 1;
    return;
  }

  const { initializeApp, applicationDefault } = functionsRequire("firebase-admin/app");
  const { getFirestore } = functionsRequire("firebase-admin/firestore");
  const app = initializeApp({ credential: applicationDefault(), projectId: EXPECTED_PROJECT_ID });

  // 確認の前に、それまでの行を出す（確認の後で同じ行を二度出さない）
  let printed = 0;
  const print = (lines) => {
    for (const line of lines.slice(printed)) console.log(line);
    printed = lines.length;
  };
  const deps = {
    store: createFirestoreStore(getFirestore(app)),
    deployedAtMs: DEPLOYED_AT_MS,
    nowMs: Date.now,
    confirm: async (lines) => {
      print(lines);
      return askYes(`本番（${EXPECTED_PROJECT_ID}）の follows から上の文書を消す。続けるなら yes と打つ: `);
    },
  };

  console.log(`🔌 接続先 Firebase プロジェクト: ${EXPECTED_PROJECT_ID}`);
  const { lines, exitCode } = parsed.command === "count" ? await cmdCount(deps, parsed) : await cmdDelete(deps, parsed);
  print(lines);
  process.exitCode = exitCode;
}

/**
 * 失敗を1行の理由にする。自前の「follows-cleanup: 」で始まるエラー（固定の文言）は本文を、
 * それ以外は code（無ければ名前）だけを返す（本文に資格情報のパスなどが入りうるため）。
 * @param {unknown} err
 * @returns {string}
 */
function describeError(err) {
  if (err instanceof Error && err.message.startsWith("follows-cleanup: ")) return err.message;
  return String((err && (err.code || err.name)) || "不明なエラー");
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((err) => {
    console.error(`❌ 失敗しました: ${describeError(err)}`);
    process.exitCode = 1;
  });
}

module.exports = {
  EXPECTED_PROJECT_ID,
  DEPLOYED_AT_MS,
  PAGE_SIZE,
  DELETE_TARGETS,
  isUidField,
  isPrintableId,
  classifyFollows,
  parseArgs,
  cmdCount,
  cmdDelete,
  createFirestoreStore,
  findEmulatorEnv,
  describeError,
};
