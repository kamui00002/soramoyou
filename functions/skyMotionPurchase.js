//
// そらもよう Cloud Functions —「空を動かす」回数パック（消費型IAP）の購入検証とクレジット付与
//
// 設計の一次情報: docs/sky-motion-billing-plan.md
// JWS検証そのものは skyMotionPurchaseVerify.js（firebase-admin非依存＝単体テスト可）に分離。
//
// ■ この関数群が守る不変条件
//   1. **検証はサーバーで行う**。クライアントが送った JWS をここで検証してから付与する。
//   2. **付与数は必ず JWS 側の productId から引く**。
//   3. **冪等**。doc ID = StoreKit の transactionId ＋ status=credited なら no-op。
//   4. クライアントは **credited を観測してから transaction.finish()** する。
//   5. 🔴 **クライアントは `status="failed"` を観測したときも transaction.finish() する**。
//      failed にするのは恒久失敗と判断したときだけ:
//      - JWS検証の**一時的**失敗（OCSP失効確認のネットワーク不調等）→ pending のまま残す
//      - pending のまま詰まった購入は reconcilePendingSkyMotionPurchases が拾い直す
//   6. 🔴 **付与先はJWSの appAccountToken で確定する**（購入 doc の userId との突き合わせは verifyAndCredit の 3) を参照）。
//

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const logger = require("firebase-functions/logger");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

const core = require("./skyMotionCore");
const verify = require("./skyMotionPurchaseVerify");

const db = getFirestore();

/** リコンサイラが pending を拾い始めるまでの猶予(ms)。onDocumentCreated の正常処理と競合させない。 */
const RECONCILE_MIN_AGE_MS = 5 * 60 * 1000;
/** リコンサイラの再検証上限。超えたら恒久失敗にする（無限リトライでコストを溶かさない）。 */
const MAX_VERIFY_ATTEMPTS = 10;
/** リコンサイラ1回あたりの処理上限（暴走ガード。通常 pending は0〜数件）。 */
const RECONCILE_BATCH_LIMIT = 50;

/**
 * 購入ドキュメントを恒久失敗にする（クレジットは付与しない）。
 *
 * ⚠️ **トランザクションで「まだ pending のときだけ」書く。**
 *    トランザクションの中で doc を読み、doc が無いか status が pending 以外なら何も書かない。
 */
async function failPurchase(ref, errorCode, message) {
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists || snap.data().status !== "pending") return; // 既に終端 → no-op
    tx.update(ref, {
      status: "failed",
      errorCode,
      error: message,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

/**
 * 購入1件を検証してクレジットを付与する（onDocumentCreated とリコンサイラの共通本体）。
 *
 * @param {FirebaseFirestore.DocumentReference} ref skyMotionPurchases/{transactionId}
 * @param {object} data ドキュメントの現在値
 * @param {string} transactionId doc ID
 * @returns {Promise<"credited"|"failed"|"retryable"|"noop">} 処理結果（ログ・テスト用）
 */
async function verifyAndCredit(ref, data, transactionId) {
  const uid = data.userId;

  if (!uid || typeof data.jws !== "string" || !data.jws) {
    await failPurchase(ref, "invalid_request", "userId または jws がありません");
    return "failed";
  }

  // 1) JWS 検証（Production → Sandbox の順に試す）
  let verified;
  try {
    verified = await verify.verifyTransactionJWS(data.jws);
  } catch (err) {
    if (err.retryable) {
      // 🔴 一時的失敗（OCSP不調等）。status を書かない＝pending のまま残す。
      //    クライアントは finish せずタイムアウト表示になり、リコンサイラが後で再試行する。
      logger.warn("回数パック: JWS検証が一時的に失敗（pendingのまま残す）", {
        transactionId, uid, error: err.message,
      });
      return "retryable";
    }
    logger.error("回数パック: JWS検証に失敗（恒久）", { transactionId, uid, error: err.message });
    await failPurchase(ref, "verification_failed", err.message);
    return "failed";
  }
  const tx = verified.transaction;

  // 2) doc ID（＝冪等キー）と JWS の transactionId の一致確認。
  //    一致しなければ transaction_id_mismatch で failed にする。
  if (String(tx.transactionId) !== String(transactionId)) {
    logger.error("回数パック: transactionId 不一致", {
      transactionId, uid, jwsTransactionId: String(tx.transactionId),
    });
    await failPurchase(ref, "transaction_id_mismatch", "ドキュメントIDとJWSのtransactionIdが一致しません");
    return "failed";
  }

  // 3) クレジット付与（冪等・付与先の確定を含めて1トランザクション）
  const claimedUserRef = db.collection("users").doc(uid);
  const result = await db.runTransaction(async (t) => {
    // Firestoreトランザクションは全ての読み取りが書き込みより先である必要がある。
    const [purchaseSnap, claimedUserSnap] = await Promise.all([
      t.get(ref), t.get(claimedUserRef),
    ]);
    const purchaseData = purchaseSnap.exists ? purchaseSnap.data() : null;

    // 🔴 付与先の確定（不変条件6）。JWSの appAccountToken と、自己申告uidの iapAccountToken を比べる。
    //    - token無し: 旧クライアント/βの既存トランザクション互換 → 自己申告uidへ付与
    //    - token一致: 自己申告どおり
    //    - token不一致: 本来の購入者を iapAccountToken の逆引きで探して**付け替える**。
    //      逆引きで見つからない場合は自己申告uidへ付与し、ログを残す（どちらの場合も failed にはしない）。
    // ⚠️ UUID の大文字小文字: Swift の `UUID().uuidString` は大文字、JWS の appAccountToken は
    //    小文字で返ることがある。client 側は **小文字で保存する規約**（resolveAppAccountToken）
    //    とし、サーバーは両辺を小文字化して比較・逆引きする。
    const jwsToken = typeof tx.appAccountToken === "string" ? tx.appAccountToken.toLowerCase() : null;
    const claimedTokenRaw = claimedUserSnap.exists ? claimedUserSnap.data().iapAccountToken : null;
    const claimedToken = typeof claimedTokenRaw === "string" ? claimedTokenRaw.toLowerCase() : null;

    let ownerUid = null;
    if (core.needsTokenOwnerLookup(jwsToken, claimedToken)) {
      // 逆引きは保存規約（小文字）に合わせた完全一致で行う。
      const ownerQuery = db.collection("users")
        .where("iapAccountToken", "==", jwsToken)
        .limit(1);
      const ownerSnap = await t.get(ownerQuery);
      if (!ownerSnap.empty) {
        ownerUid = ownerSnap.docs[0].id;
      } else {
        logger.error("回数パック: appAccountToken不一致だが本来の購入者を特定できず（自己申告uidへ付与・要監査）", {
          transactionId, uid, claimedTokenPresent: claimedToken !== null,
        });
      }
    }
    const { creditUid, creditedUidBasis } = core.decideCreditRecipient({
      claimedUid: uid, jwsToken, claimedToken, ownerUid,
    });

    const balanceRef = db.collection("skyMotionBalance").doc(creditUid);
    const balanceSnap = await t.get(balanceRef);

    // ⚠️ productId は **検証済みJWS の値**で上書きしてから判定する（不変条件2）。
    const decision = core.decidePurchaseCredit(
      { ...(purchaseData || {}), productId: tx.productId },
      balanceSnap.exists ? balanceSnap.data() : null
    );
    if (!decision.credit) return { ...decision, creditUid, creditedUidBasis };

    t.set(
      balanceRef,
      { balance: decision.newBalance, updatedAt: FieldValue.serverTimestamp() },
      { merge: true }
    );
    t.update(ref, {
      status: "credited",
      productId: tx.productId,
      creditedCount: decision.credits,
      // 監査用: userId（自己申告）と creditedUid（実際の付与先）を区別できるようにする
      creditedUid: creditUid,
      // creditedUid をどう決めたか（値は skyMotionCore.decideCreditRecipient の JSDoc を参照）
      creditedUidBasis,
      environment: verified.environment,
      updatedAt: FieldValue.serverTimestamp(),
    });
    return { ...decision, creditUid, creditedUidBasis };
  });

  if (!result.credit) {
    if (result.reason === "already_credited") {
      logger.info("回数パック: 既に付与済みのため no-op", { transactionId, uid });
      return "noop";
    }
    logger.error("回数パック: 付与できませんでした", {
      transactionId, uid, productId: tx.productId, reason: result.reason,
    });
    await failPurchase(ref, result.reason, `クレジットを付与できませんでした (${result.reason})`);
    return "failed";
  }

  if (result.creditedUidBasis === "token_owner") {
    logger.warn("回数パック: appAccountToken不一致→本来の購入者へ付け替え", {
      transactionId, claimedUid: uid, creditUid: result.creditUid,
    });
  }
  logger.info("回数パック: クレジット付与", {
    transactionId, uid, creditUid: result.creditUid, productId: tx.productId,
    credits: result.credits, newBalance: result.newBalance,
    environment: verified.environment,
  });
  return "credited";
}

/**
 * A. 購入検証＋クレジット付与（作成イベント起点）
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
    await verifyAndCredit(snap.ref, snap.data(), transactionId);
  }
);

/**
 * B. pending 詰まりのリコンサイラ（5分毎）
 *
 * 作成から RECONCILE_MIN_AGE_MS 以上たった pending の購入 doc について、verifyAttempts を
 * 1 増やして verifyAndCredit をやり直す。MAX_VERIFY_ATTEMPTS を超えた doc は failPurchase で
 * failed にする。
 *
 * `pollSkyMotionJobs`（ジョブ側のポーラー）と同じ思想の、購入側の対称物。
 */
const reconcilePendingSkyMotionPurchases = onSchedule(
  {
    schedule: "every 5 minutes",
    region: "asia-northeast1",
    timeoutSeconds: 300,
    memory: "256MiB",
  },
  async () => {
    // status の単一フィールドクエリ（自動インデックスで足りる）。pending は通常0〜数件なので
    // orderBy を付けず複合インデックスを増やさない。年齢判定はメモリ上で行う。
    const snap = await db.collection("skyMotionPurchases")
      .where("status", "==", "pending")
      .limit(RECONCILE_BATCH_LIMIT)
      .get();
    if (snap.empty) return;

    const cutoff = Date.now() - RECONCILE_MIN_AGE_MS;
    for (const doc of snap.docs) {
      const data = doc.data();
      const createdAtMs = data.createdAt && typeof data.createdAt.toMillis === "function"
        ? data.createdAt.toMillis() : 0;
      if (createdAtMs > cutoff) continue; // まだ猶予中（onDocumentCreated が処理中かもしれない）

      const attempts = (typeof data.verifyAttempts === "number" ? data.verifyAttempts : 0) + 1;
      if (attempts > MAX_VERIFY_ATTEMPTS) {
        // 再試行回数が MAX_VERIFY_ATTEMPTS を超えた購入を恒久失敗にする（≒50分以上）。
        // failed を見たクライアントは finish する。
        await failPurchase(doc.ref, "verification_timeout", "検証を規定回数再試行しましたが確定できませんでした");
        logger.error("回数パック: 再試行上限に達し恒久失敗化", { transactionId: doc.id, attempts });
        continue;
      }
      await doc.ref.update({
        verifyAttempts: attempts,
        updatedAt: FieldValue.serverTimestamp(),
      }).catch(() => {});

      const outcome = await verifyAndCredit(doc.ref, data, doc.id);
      logger.info("回数パック: リコンサイラ処理", { transactionId: doc.id, attempts, outcome });
    }
  }
);

module.exports = { onSkyMotionPurchaseCreated, reconcilePendingSkyMotionPurchases };
