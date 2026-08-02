//
// そらもよう Cloud Functions — App Store の購入JWS検証（Apple公式ライブラリの薄いラッパー）
//
// ⚠️ このファイルは firebase-admin / firebase-functions を一切 require しない。
//    `node --test` で単体テストできるようにするための意図的な分離
//    （skyMotionCore.js と同じ流儀。skyMotionPurchase.js は getFirestore() を
//     モジュール先頭で呼ぶため、素の require では単体テストが書けない）。
//

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { SignedDataVerifier, Environment } = require("@apple/app-store-server-library");

/** アプリの Bundle ID（pbxproj の PRODUCT_BUNDLE_IDENTIFIER と一致させること）。 */
const BUNDLE_ID = "com.yoshidometoru.Soramoyou";

/**
 * App Store 上の数値ID（そらもよう）。Production 環境の検証で必須。
 * 取得元: `https://itunes.apple.com/lookup?bundleId=<BUNDLE_ID>` の trackId。
 */
const APP_APPLE_ID = 6758070979;

/**
 * Apple ルートCA（公開情報）。`certs/` に DER 形式で同梱している。
 * 取得元: https://www.apple.com/certificateauthority/
 * 3種入れているのは、Apple がどの世代のルートで署名してくるかを固定できないため。
 */
const APPLE_ROOT_CA_FILES = [
  "AppleRootCA-G3.cer",
  "AppleRootCA-G2.cer",
  "AppleIncRootCertificate.cer",
];

let rootCAsCache = null;
/** ルートCAを読み込む（初回のみ・以降はキャッシュ）。 */
function loadRootCAs() {
  if (rootCAsCache) return rootCAsCache;
  rootCAsCache = APPLE_ROOT_CA_FILES.map((name) =>
    fs.readFileSync(path.join(__dirname, "certs", name))
  );
  return rootCAsCache;
}

/** 検証器は環境ごとに1個作って使い回す（証明書読み込みのコストを毎回払わない）。 */
const verifierCache = new Map();
function verifierFor(environment, enableOnlineChecks) {
  const key = `${environment}:${enableOnlineChecks}`;
  if (verifierCache.has(key)) return verifierCache.get(key);
  const v = new SignedDataVerifier(
    loadRootCAs(),
    enableOnlineChecks,
    environment,
    BUNDLE_ID,
    APP_APPLE_ID
  );
  verifierCache.set(key, v);
  return v;
}

/**
 * 購入トランザクションのJWSを検証して中身を返す。
 *
 * ⚠️ **Production → Sandbox の順に両方試す**。クライアントは自分がどちらの環境かを
 *    確実には知り得ないし、client 申告を信用するとそこが偽装点になる。サーバー側で
 *    両方試して通った方の環境を記録するのが公式に推奨される作法。
 *    Production 決め打ちにすると TestFlight の購入が全部検証失敗し、
 *    「コードのバグに見える幻のバグ」を追うことになる。
 *
 * @param {string} jws signedTransactionInfo（クライアントの `Transaction.jsonRepresentation` ではなく署名付きJWS）
 * @param {{enableOnlineChecks?: boolean, verifierFactory?: Function}} [options]
 *   verifierFactory はテストで差し替えるためのフック（本番では渡さない）。
 * @returns {Promise<{transaction: object, environment: string}>}
 * @throws {Error} どちらの環境でも検証できなかった場合（メッセージに両方の理由を含む）
 */
async function verifyTransactionJWS(jws, options) {
  if (typeof jws !== "string" || jws.length === 0) {
    throw new Error("JWS検証に失敗しました (jwsが空です)");
  }
  const opts = options || {};
  const online = opts.enableOnlineChecks !== false; // 既定で失効確認あり
  const factory = opts.verifierFactory || ((env) => verifierFor(env, online));

  const errors = [];
  for (const env of [Environment.PRODUCTION, Environment.SANDBOX]) {
    try {
      const transaction = await factory(env).verifyAndDecodeTransaction(jws);
      return { transaction, environment: env };
    } catch (err) {
      errors.push(`${env}: ${err && err.message ? err.message : String(err)}`);
    }
  }
  throw new Error(`JWS検証に失敗しました (${errors.join(" / ")})`);
}

module.exports = {
  BUNDLE_ID,
  APP_APPLE_ID,
  APPLE_ROOT_CA_FILES,
  Environment,
  loadRootCAs,
  verifyTransactionJWS,
};
