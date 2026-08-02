//
// skyMotionPurchaseVerify.js の単体テスト（firebase-admin 非依存）
//
// 実行: node --test skyMotionPurchaseVerify.test.js
//
// ⚠️ 本物の署名済みJWSはサンドボックス購入をしないと手に入らないため、ここでは
//    「検証器に何を渡し、失敗をどう扱うか」の配線だけを verifierFactory の差し替えで検証する。
//    署名検証そのものは Apple 公式ライブラリの責務なので二重にテストしない。
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const verify = require("./skyMotionPurchaseVerify");

test("アプリ識別子が pbxproj / App Store と一致している", () => {
  assert.equal(verify.BUNDLE_ID, "com.yoshidometoru.Soramoyou");
  assert.equal(verify.APP_APPLE_ID, 6758070979);
});

test("Apple ルートCA が3種とも同梱され、DER として読める", () => {
  const cas = verify.loadRootCAs();
  assert.equal(cas.length, 3, "世代違いのルートで署名されても通せるよう3種入れている");
  for (const buf of cas) {
    assert.ok(Buffer.isBuffer(buf) && buf.length > 100, "証明書が空・欠落している");
    assert.equal(buf[0], 0x30, "DER形式(SEQUENCE)ではない＝取得に失敗したファイル");
  }
});

test("空のJWSは検証器を呼ぶ前に弾く", async () => {
  for (const bad of ["", null, undefined, 123]) {
    await assert.rejects(() => verify.verifyTransactionJWS(bad), /JWS検証に失敗/);
  }
});

test("Production で通れば Sandbox を試さない（環境が記録される）", async () => {
  const calls = [];
  const factory = (env) => {
    calls.push(env);
    return { verifyAndDecodeTransaction: async () => ({ transactionId: "1", productId: "p" }) };
  };
  const r = await verify.verifyTransactionJWS("dummy", { verifierFactory: factory });
  assert.equal(calls.length, 1);
  assert.equal(calls[0], verify.Environment.PRODUCTION);
  assert.equal(r.environment, verify.Environment.PRODUCTION);
  assert.equal(r.transaction.transactionId, "1");
});

test("Production で落ちたら Sandbox にフォールバックする（TestFlight購入の生命線）", async () => {
  const calls = [];
  const factory = (env) => {
    calls.push(env);
    return {
      verifyAndDecodeTransaction: async () => {
        if (env === verify.Environment.PRODUCTION) throw new Error("wrong environment");
        return { transactionId: "2", productId: "p" };
      },
    };
  };
  const r = await verify.verifyTransactionJWS("dummy", { verifierFactory: factory });
  assert.deepEqual(calls, [verify.Environment.PRODUCTION, verify.Environment.SANDBOX]);
  assert.equal(r.environment, verify.Environment.SANDBOX,
    "Production決め打ちにするとTestFlight購入が全部検証失敗する");
});

test("両環境で落ちたら throw し、両方の理由をメッセージに残す（原因追跡のため）", async () => {
  const factory = (env) => ({
    verifyAndDecodeTransaction: async () => {
      throw new Error(`boom-${env}`);
    },
  });
  await assert.rejects(
    () => verify.verifyTransactionJWS("dummy", { verifierFactory: factory }),
    (err) => {
      assert.match(err.message, /JWS検証に失敗/);
      assert.match(err.message, /boom-/, "個別の失敗理由が消えていると原因が追えない");
      return true;
    }
  );
});

test("本物の検証器に壊れたJWSを渡すと必ず失敗する（配線の実弾スモーク）", async () => {
  // verifierFactory を差し替えず、実際の SignedDataVerifier を通す。
  // ネットワーク失効確認を切って、署名検証だけで落ちることを確かめる。
  await assert.rejects(
    () => verify.verifyTransactionJWS("not.a.valid.jws", { enableOnlineChecks: false }),
    /JWS検証に失敗/
  );
});
