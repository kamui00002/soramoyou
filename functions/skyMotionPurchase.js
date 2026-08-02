//
// そらもよう Cloud Functions —「空を動かす」回数パック（消費型IAP）の購入検証とクレジット付与
//
// 設計の一次情報: docs/sky-motion-billing-plan.md
// JWS検証そのものは skyMotionPurchaseVerify.js（firebase-admin非依存＝単体テスト可）に分離。
//
// ■ この関数が守る不変条件（＝ユーザーの金を落とさないための約束）
//   1. **検証はサーバーで行う**。クライアントの「買いました」を信用しない。
//      Apple 公式の App Store Server Library で JWS を Apple ルートCA に対し検証する
//      （非推奨の /verifyReceipt は使わない）。
//   2. **付与数は必ず JWS 側の productId から引く**。client 申告の productId を信じると
//      「pack5 を買って pack100 と自己申告」が通ってしまう。
//   3. **冪等**。doc ID = StoreKit の transactionId なので同じ購入は同じドキュメントになり、
//      さらに status=credited なら no-op にする（onDocumentCreated は at-least-once）。
//   4. クライアントは **credited を観測してから transaction.finish()** する。
//      この関数が durable に加算を終えるまで、購入は Apple 側で「未完了」のまま残るので、
//      アプリが落ちても起動時の Transaction.unfinished で再送できる。
//

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

const core = require("./skyMotionCore");
const verify = require("./skyMotionPurchaseVerify");

const db = getFirestore();

/**
 * 購入ドキュメントを失敗にする（クレジットは付与しない）。
 * クライアントはこれを観測したら transaction.finish() してよい
 * （＝Apple 側で有効でない購入を延々と再送し続けない）。
 */
async function failPurchase(ref, errorCode, message) {
  await ref.update({
    status: "failed",
    errorCode,
    error: message,
    updatedAt: FieldValue.serverTimestamp(),
  });
}

/**
 * 購入検証＋クレジット付与
 *
 * client が `skyMotionPurchases/{transactionId}` を `status="pending"` ＋ JWS 付きで作成 →
 * この関数が JWS を検証し、`skyMotionBalance/{uid}.balance` に加算して `status="credited"`。
 */
const onSkyMotionPurchaseCreated = onDocumentCreated(
  {
    document: "skyMotionPurchases/{transactionId}",
    region: "asia-northeast1",
    // 検証は軽いが、証明書の失効確認でネットワークに出るので少し余裕を持たせる。
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async (event) => {
    const transactionId = event.params.transactionId;
    const snap = event.data;
    if (!snap) {
      logger.warn("回数パック: スナップショットが空", { transactionId });
      return;
    }
    const ref = snap.ref;
    const data = snap.data();
    const uid = data.userId;

    if (!uid || typeof data.jws !== "string" || !data.jws) {
      await failPurchase(ref, "invalid_request", "userId または jws がありません");
      return;
    }

    // 1) JWS 検証（Production → Sandbox の順に試す）
    let verified;
    try {
      verified = await verify.verifyTransactionJWS(data.jws);
    } catch (err) {
      logger.error("回数パック: JWS検証に失敗", { transactionId, uid, error: err.message });
      await failPurchase(ref, "verification_failed", err.message);
      return;
    }
    const tx = verified.transaction;

    // 2) doc ID（＝冪等キー）と JWS の transactionId が一致していることを確認する。
    //    ここがズレていると「別の購入のJWSを使い回して何度も加算」が成立してしまう。
    if (String(tx.transactionId) !== String(transactionId)) {
      logger.error("回数パック: transactionId 不一致", {
        transactionId, uid, jwsTransactionId: String(tx.transactionId),
      });
      await failPurchase(
        ref, "transaction_id_mismatch",
        `ドキュメントIDとJWSのtransactionIdが一致しません`
      );
      return;
    }

    // 3) クレジット数の決定＋加算（冪等・トランザクション内で残高と購入状態を読み直す）
    const balanceRef = db.collection("skyMotionBalance").doc(uid);
    const result = await db.runTransaction(async (t) => {
      const [purchaseSnap, balanceSnap] = await Promise.all([t.get(ref), t.get(balanceRef)]);
      const purchaseData = purchaseSnap.exists ? purchaseSnap.data() : null;
      // ⚠️ productId は **検証済みJWS の値**で上書きしてから判定する（不変条件2）。
      const decision = core.decidePurchaseCredit(
        { ...(purchaseData || {}), productId: tx.productId },
        balanceSnap.exists ? balanceSnap.data() : null
      );
      if (!decision.credit) return decision;

      t.set(
        balanceRef,
        { balance: decision.newBalance, updatedAt: FieldValue.serverTimestamp() },
        { merge: true }
      );
      t.update(ref, {
        status: "credited",
        productId: tx.productId,
        creditedCount: decision.credits,
        environment: verified.environment,
        updatedAt: FieldValue.serverTimestamp(),
      });
      return decision;
    });

    if (!result.credit) {
      if (result.reason === "already_credited") {
        // 再配信。何もしないのが正解（二重加算しない）。
        logger.info("回数パック: 既に付与済みのため no-op", { transactionId, uid });
        return;
      }
      logger.error("回数パック: 付与できませんでした", {
        transactionId, uid, productId: tx.productId, reason: result.reason,
      });
      await failPurchase(ref, result.reason, `クレジットを付与できませんでした (${result.reason})`);
      return;
    }

    logger.info("回数パック: クレジット付与", {
      transactionId, uid, productId: tx.productId,
      credits: result.credits, newBalance: result.newBalance,
      environment: verified.environment,
    });
  }
);

module.exports = { onSkyMotionPurchaseCreated };
