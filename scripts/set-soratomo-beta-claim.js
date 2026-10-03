#!/usr/bin/env node

/**
 * そらともの機能フラグ（カスタムクレーム soratomoBeta）を、1人の利用者に付与・取り消しするスクリプト ☁️
 *
 * なぜ「合成」するのか:
 *   Admin SDK の setCustomUserClaims は、その利用者のクレームを丸ごと上書きする。
 *   soratomoBeta だけを渡すと、すでに付いている skyMotionBeta（空を動かすβ）などが消える。
 *   そのため、既存のクレームを読んでから soratomoBeta だけを足す（消す）合成をして書く。
 *   書いたあとに読み返し、soratomoBeta の有無と既存のクレームが残っていることを照合する。
 *
 * ⚠️ 一般の利用者には付けない（要件1.3・17.1: 公開前ゲートが揃うまで、開発者とテスト用アカウントだけ）。
 * ⚠️ 本番での実行は tasks 9.2 で、ユーザーの GO を取ってから。
 *
 * 認証: Application Default Credentials（ADC）を使う。鍵ファイルはリポジトリに置かない。
 *   1. gcloud auth application-default login
 *   2. Auth の Admin API で quota project を求められたら（"requires a quota project" のエラー）:
 *        gcloud auth application-default set-quota-project soramoyou-ios
 *   接続先は EXPECTED_PROJECT_ID（soramoyou-ios）に固定している（ADC の既定のプロジェクトに頼らない）。
 *
 * 実行方法（リポジトリ直下で）:
 *   firebase-admin は functions/ の依存を借りる（functions で npm install 済みであること）。
 *     NODE_PATH=functions/node_modules node scripts/set-soratomo-beta-claim.js <uid>            # 付与
 *     NODE_PATH=functions/node_modules node scripts/set-soratomo-beta-claim.js <uid> --revoke   # 取り消し
 *
 * 出力: 利用者IDと、クレームの「名前」だけ（付与前と付与後）。クレームの値・トークン・メールアドレスは出さない。
 *   付与前の名前は、9.2 で「既存のクレームが消えていないか」を後から比べるための記録。
 *
 * 付与されたテスターは、アプリの次の起動（ID トークンの更新）で入口が出る。
 *
 * テスト: node --test scripts/set-soratomo-beta-claim.test.js（firebase-admin 非依存。本番には触れない）
 */

"use strict";

/** 書き込み先として唯一許可する Firebase プロジェクト（.firebaserc が空のため、ここで固定する）。 */
const EXPECTED_PROJECT_ID = "soramoyou-ios";
/** そらともの機能フラグのクレーム名（firestore.rules・storage.rules・Functions が読む名前）。 */
const CLAIM_KEY = "soratomoBeta";

const USAGE = "使い方: node scripts/set-soratomo-beta-claim.js <uid> [--revoke]";

/**
 * 既存のクレームに soratomoBeta だけを足す（revoke なら消す）。渡したオブジェクトは書き換えない。
 * @param {Object|null|undefined} existing 既存のカスタムクレーム（無ければ null / undefined）
 * @param {{ revoke: boolean }} options
 * @returns {Object} 書き込むクレーム（合成後）
 */
function mergeSoratomoClaim(existing, { revoke }) {
  const merged = { ...(existing || {}) };
  if (revoke) {
    delete merged[CLAIM_KEY];
  } else {
    merged[CLAIM_KEY] = true;
  }
  return merged;
}

/**
 * コマンドラインの引数を読む。利用者IDはちょうど1つ、オプションは --revoke だけを受け付ける。
 * @param {string[]} argv process.argv.slice(2)
 * @returns {{ ok: true, uid: string, revoke: boolean } | { ok: false }}
 */
function parseArgs(argv) {
  const revoke = argv.includes("--revoke");
  const rest = argv.filter((a) => a !== "--revoke");
  if (rest.length !== 1) return { ok: false };
  const uid = rest[0];
  if (!uid || uid.startsWith("-")) return { ok: false };
  return { ok: true, uid, revoke };
}

/**
 * クレームの名前を並べ替えて「, 」でつなぐ（値は出さない）。
 * @param {Object|null|undefined} claims
 * @returns {string}
 */
function claimNames(claims) {
  const names = Object.keys(claims || {}).sort();
  return names.length > 0 ? names.join(", ") : "（なし）";
}

/**
 * 画面に出す結果。利用者IDとクレームの名前だけ（要件15と同じく、値や個人情報を出さない）。
 * @param {string} uid
 * @param {Object|null|undefined} before 付与前のクレーム
 * @param {Object|null|undefined} after 書いたあとに読み返したクレーム
 * @returns {string}
 */
function formatResult(uid, before, after) {
  return [`uid: ${uid}`, `付与前のクレーム名: ${claimNames(before)}`, `付与後のクレーム名: ${claimNames(after)}`].join(
    "\n"
  );
}

/**
 * 読み返したクレームが期待どおりかを照合する。
 * - 付与: soratomoBeta が true。取り消し: soratomoBeta が無い
 * - soratomoBeta 以外の既存のクレームが、同じ値のまま残っている（合成し忘れの事故を検出する）
 * @param {Object|null|undefined} before 付与前のクレーム
 * @param {Object|null|undefined} after 読み返したクレーム
 * @param {{ revoke: boolean }} options
 * @returns {boolean}
 */
function verifyAfter(before, after, { revoke }) {
  const b = before || {};
  const a = after || {};
  const flagOk = revoke ? !(CLAIM_KEY in a) : a[CLAIM_KEY] === true;
  const othersKept = Object.keys(b)
    .filter((k) => k !== CLAIM_KEY)
    .every((k) => k in a && JSON.stringify(a[k]) === JSON.stringify(b[k]));
  return flagOk && othersKept;
}

/**
 * 本体。firebase-admin はここでだけ読み込む（テストと引数の確認に依存を持ち込まないため）。
 * @param {string[]} argv
 */
async function main(argv) {
  const parsed = parseArgs(argv);
  if (!parsed.ok) {
    console.error(USAGE);
    process.exitCode = 2;
    return;
  }
  const { uid, revoke } = parsed;

  const { initializeApp, applicationDefault } = require("firebase-admin/app");
  const { getAuth } = require("firebase-admin/auth");
  initializeApp({ credential: applicationDefault(), projectId: EXPECTED_PROJECT_ID });
  const auth = getAuth();

  console.log(`🔌 接続先 Firebase プロジェクト: ${EXPECTED_PROJECT_ID}`);
  console.log(revoke ? "操作: soratomoBeta を取り消す" : "操作: soratomoBeta を付与する");

  const before = (await auth.getUser(uid)).customClaims || {};
  await auth.setCustomUserClaims(uid, mergeSoratomoClaim(before, { revoke }));
  const after = (await auth.getUser(uid)).customClaims || {};

  console.log(formatResult(uid, before, after));
  if (!verifyAfter(before, after, { revoke })) {
    console.error("❌ 読み返したクレームが期待と一致しません（soratomoBeta の有無か、既存のクレームを確認してください）");
    process.exitCode = 1;
    return;
  }
  console.log("✅ 読み返して一致しました");
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((err) => {
    // エラーの中身（資格情報のパスなど）をそのまま出さず、コードと要約だけにする。
    console.error(`❌ 失敗しました: ${(err && (err.code || err.message)) || "不明なエラー"}`);
    process.exitCode = 1;
  });
}

module.exports = {
  EXPECTED_PROJECT_ID,
  CLAIM_KEY,
  mergeSoratomoClaim,
  parseArgs,
  claimNames,
  formatResult,
  verifyAfter,
};
