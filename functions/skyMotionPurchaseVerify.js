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
const {
  SignedDataVerifier,
  Environment,
  VerificationStatus,
} = require("@apple/app-store-server-library");

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
 * ⚠️ **失敗には「一時的」と「恒久的」の2種類があり、混同すると金銭喪失になる。**
 *    Apple 公式ライブラリは OCSP（証明書失効確認）のネットワーク失敗・非200応答を
 *    `VerificationException(status = RETRYABLE_VERIFICATION_FAILURE)` として区別している。
 *    これを恒久失敗として扱い `status="failed"` を書くと、クライアントは
 *    「サーバーが無効と判断した」と解釈して `transaction.finish()` してしまい、
 *    **正当な購入が Apple 側からも消えて再送経路が完全に断たれる**。
 *    そのため throw する Error に `retryable` プロパティを載せ、呼び出し側は
 *    retryable のとき status を書かず pending のまま残す（リコンサイラが後で再試行する）。
 *    片方の環境だけ retryable だった場合も**安全側＝retryable 扱い**にする
 *    （恒久と断定できないものを恒久扱いする方が取り返しがつかない）。
 *
 * @param {string} jws signedTransactionInfo（クライアントの `Transaction.jsonRepresentation` ではなく署名付きJWS）
 * @param {{enableOnlineChecks?: boolean, verifierFactory?: Function}} [options]
 *   verifierFactory はテストで差し替えるためのフック（本番では渡さない）。
 * @returns {Promise<{transaction: object, environment: string}>}
 * @throws {Error & {retryable: boolean}} どちらの環境でも検証できなかった場合
 *   （メッセージに両方の理由・retryable に再試行可否を含む）
 */
async function verifyTransactionJWS(jws, options) {
  if (typeof jws !== "string" || jws.length === 0) {
    const err = new Error("JWS検証に失敗しました (jwsが空です)");
    err.retryable = false; // 入力不正は再試行しても直らない
    throw err;
  }
  const opts = options || {};
  const online = opts.enableOnlineChecks !== false; // 既定で失効確認あり
  const factory = opts.verifierFactory || ((env) => verifierFor(env, online));

  const results = [];
  for (const env of [Environment.PRODUCTION, Environment.SANDBOX]) {
    try {
      const transaction = await factory(env).verifyAndDecodeTransaction(jws);
      return { transaction, environment: env };
    } catch (err) {
      results.push({
        env,
        // ⚠️ VerificationException は message が空文字列（super()を引数なしで呼ぶ実装）。
        //    status が唯一の判定材料なので、message ではなく status を見る。
        message: err && err.message ? err.message : `VerificationStatus=${err && err.status}`,
        retryable: !!(err && err.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE),
      });
    }
  }
  const combined = new Error(
    `JWS検証に失敗しました (${results.map((r) => `${r.env}: ${r.message}`).join(" / ")})`
  );
  combined.retryable = results.some((r) => r.retryable);
  throw combined;
}

module.exports = {
  BUNDLE_ID,
  APP_APPLE_ID,
  APPLE_ROOT_CA_FILES,
  Environment,
  VerificationStatus,
  loadRootCAs,
  verifyTransactionJWS,
};
