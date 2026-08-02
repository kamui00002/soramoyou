// ⭐️ SkyMotionCreditService.swift
// 「空を動かす」回数パック（消費型IAP）の購入 → サーバー検証待ち → 残高監視
//
//  設計: docs/sky-motion-billing-plan.md
//
//  ■ このサービスが守る不変条件（＝ユーザーの金を落とさないための約束）
//
//  1. **サーバーが加算し終えてから `transaction.finish()` する。**
//     順番を逆にすると、加算が durable になる前にアプリが落ちた場合に
//     「課金されたのにクレジットが増えない」＝金銭喪失になる。
//     finish していない購入は Apple 側に残るので、起動時に拾い直して再送できる。
//
//  2. **起動時に未完了トランザクションを必ず流し込む。**
//     `Transaction.unfinished` と `Transaction.updates` の両方を回す。
//     サーバー側は doc ID = transactionId で冪等なので、再送が二重加算になることはない。
//
//  3. **残高はサーバーが真実源。** ここで持つ `balance` は表示用キャッシュに過ぎない。
//     生成できるかどうかの判定は必ずサーバー（`reserveAndClaimJob`）が行う。
//     ローカルの残高で生成ボタンを出し分けるのは「表示の親切」であって認可ではない。
//
//  ⚠️ 既存の `PaymentService` は非消耗型（広角合成）用に「購入したら即 finish」で作られている。
//     消費型でそれを使うと不変条件1を破るため、**このサービスは購入フローを自前で持つ**
//     （フラグ1つで分岐させると、その boolean が「金を失うかどうか」を決めることになる）。
//

import FirebaseAuth
import FirebaseFirestore
import Foundation
import os
import StoreKit

/// 購入の進行状態（UI 表示用）
enum SkyMotionPurchaseState: Equatable {
    case idle
    /// Apple の購入シート表示中〜購入完了まで
    case purchasing
    /// 購入は完了したが、サーバーの検証・加算待ち（ここで finish していない）
    case verifying
    case success(credits: Int)
    case cancelled
    case failed(message: String)
}

@MainActor
final class SkyMotionCreditService: ObservableObject {
    static let shared = SkyMotionCreditService()

    /// 購入済みクレジット残高（**表示用キャッシュ**。認可には使わない）。
    @Published private(set) var balance: Int = 0
    /// 購入フローの状態。
    @Published private(set) var purchaseState: SkyMotionPurchaseState = .idle
    /// 取得済みプロダクト（価格表示用）。
    @Published private(set) var products: [Product] = []

    private let db = Firestore.firestore()
    private var balanceListener: ListenerRegistration?
    private var updatesTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.soramoyou", category: "SkyMotionCredit")

    /// サーバーの検証完了を待つ上限。超えても購入自体は Apple 側に残るので、
    /// 次回起動時の未完了トランザクション再送で拾い直せる（金銭喪失にはならない）。
    private let verificationTimeout: Duration = .seconds(60)

    private init() {}

    // MARK: - ライフサイクル

    /// アプリ起動時（またはシート表示時）に1度だけ呼ぶ。
    /// 残高の購読と、**未完了トランザクションの再送**を開始する。
    func start() {
        observeBalance()
        startTransactionListener()
        Task { await drainUnfinishedTransactions() }
    }

    func stop() {
        balanceListener?.remove()
        balanceListener = nil
        updatesTask?.cancel()
        updatesTask = nil
    }

    /// 残高ドキュメントを購読する（サーバーが加算・減算するのをそのまま反映する）。
    private func observeBalance() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        balanceListener?.remove()
        balanceListener = db.collection("skyMotionBalance").document(uid)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    logger.error("残高の購読に失敗: \(error.localizedDescription, privacy: .public)")
                    return
                }
                let value = snapshot?.data()?["balance"] as? Int ?? 0
                Task { @MainActor in self.balance = max(0, value) }
            }
    }

    /// 外部（別端末での購入・承認待ちの解決など）からの Transaction 更新を購読する。
    private func startTransactionListener() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await submitAndFinish(update)
            }
        }
    }

    /// **finish していない購入**を拾い直してサーバーへ再送する。
    /// 前回の起動でサーバー加算の確認前に落ちた購入は、ここで復活する。
    private func drainUnfinishedTransactions() async {
        for await result in Transaction.unfinished {
            await submitAndFinish(result)
        }
    }

    // MARK: - プロダクト取得

    func loadProducts() async {
        do {
            products = try await Product.products(for: Array(SkyMotionProduct.allProductIDs))
            logger.info("回数パック: \(self.products.count, privacy: .public)件のプロダクトを取得")
        } catch {
            logger.error("回数パック: プロダクト取得に失敗 \(error.localizedDescription, privacy: .public)")
        }
    }

    /// ローカライズ済み価格文字列（未ロードなら nil）。
    func displayPrice(for productID: String) -> String? {
        products.first { $0.id == productID }?.displayPrice
    }

    // MARK: - 購入

    /// 回数パックを購入する。
    /// 成功時は **サーバーがクレジットを加算し終えてから** finish する（不変条件1）。
    func purchase(productID: String = SkyMotionProduct.pack5) async {
        guard Auth.auth().currentUser?.uid != nil else {
            purchaseState = .failed(message: "ログインが必要です")
            return
        }
        purchaseState = .purchasing

        if products.first(where: { $0.id == productID }) == nil {
            await loadProducts()
        }
        guard let product = products.first(where: { $0.id == productID }) else {
            purchaseState = .failed(message: "購入アイテムを取得できませんでした。時間をおいて再度お試しください")
            return
        }

        do {
            let result = try await product.purchase()
            switch result {
            case let .success(verification):
                purchaseState = .verifying
                await submitAndFinish(verification, reportToUI: true)
            case .userCancelled:
                purchaseState = .cancelled
            case .pending:
                // ファミリー共有の承認待ちなど。承認されたら Transaction.updates に流れてくる。
                purchaseState = .failed(message: "購入の承認待ちです。承認されると自動で反映されます")
            @unknown default:
                purchaseState = .failed(message: "購入の状態を判定できませんでした")
            }
        } catch {
            logger.error("回数パック: 購入に失敗 \(error.localizedDescription, privacy: .public)")
            purchaseState = .failed(message: "購入に失敗しました: \(error.localizedDescription)")
        }
    }

    // MARK: - サーバー検証（購入フローの心臓部）

    /// 検証済みトランザクションを Firestore に投げ、**サーバーが加算し終えるのを待ってから** finish する。
    ///
    /// - Parameter reportToUI: 購入直後の呼び出しなら true（`purchaseState` を更新する）。
    ///   起動時の再送では false（バックグラウンドで静かに片付ける）。
    private func submitAndFinish(
        _ verification: VerificationResult<StoreKit.Transaction>, reportToUI: Bool = false
    ) async {
        // 署名検証を通らないものは絶対に扱わない。finish もしない
        // （finish すると Apple 側から消え、正当な購入だった場合に復元できなくなる）。
        guard case let .verified(transaction) = verification else {
            logger.error("回数パック: 未検証のトランザクションを無視")
            if reportToUI { purchaseState = .failed(message: "購入の検証に失敗しました") }
            return
        }
        // 「空を動かす」の回数パック以外（＝広角合成の非消耗型など）はこのサービスの担当外。
        guard SkyMotionProduct.allProductIDs.contains(transaction.productID) else { return }

        guard let uid = Auth.auth().currentUser?.uid else {
            // 未ログイン。finish せずに残す＝ログイン後の起動で再送される。
            logger.error("回数パック: 未ログインのため検証を保留（finishしない）")
            if reportToUI { purchaseState = .failed(message: "ログインが必要です") }
            return
        }

        let transactionId = String(transaction.id)
        let docRef = db.collection("skyMotionPurchases").document(transactionId)

        do {
            try await submitPurchaseDocumentIfNeeded(
                docRef: docRef, uid: uid, transaction: transaction,
                jws: verification.jwsRepresentation
            )
            let credited = try await waitForCredit(docRef: docRef)

            switch credited {
            case let .credited(count):
                // ✅ サーバーの加算が durable に完了した。ここで初めて finish してよい。
                await transaction.finish()
                logger.info("回数パック: 加算完了→finish (tx=\(transactionId, privacy: .public))")
                if reportToUI { purchaseState = .success(credits: count) }
            case let .failed(message):
                // サーバーが「この購入は無効」と判断した。finish しないと Apple が
                // 延々と再送してくるので finish する（残高は増えない）。
                await transaction.finish()
                logger.error("回数パック: サーバー検証NG→finish (tx=\(transactionId, privacy: .public))")
                if reportToUI { purchaseState = .failed(message: message) }
            }
        } catch {
            // ネットワーク断・タイムアウト等。**finish しない**のが正解。
            // 購入は Apple 側に残り、次回起動の未完了トランザクション再送で拾い直せる。
            logger.error("回数パック: 検証待ちで中断（finishせず保留）: \(error.localizedDescription, privacy: .public)")
            if reportToUI {
                purchaseState = .failed(
                    message: "購入は完了しています。反映は自動で再試行されるので、少し待ってからアプリを開き直してください"
                )
            }
        }
    }

    /// 購入ドキュメントを作成する。既にあれば何もしない（再送時の二重作成を避ける）。
    /// - Parameter jws: `VerificationResult.jwsRepresentation`（**署名付き**）。
    ///   `Transaction.jsonRepresentation`（署名なし）を送ってはいけない。サーバーが
    ///   Apple ルートCA で検証できるのは前者だけで、後者は誰でも捏造できる。
    private func submitPurchaseDocumentIfNeeded(
        docRef: DocumentReference, uid: String, transaction: StoreKit.Transaction, jws: String
    ) async throws {
        let existing = try await docRef.getDocument()
        if existing.exists { return }
        try await docRef.setData([
            "userId": uid,
            "status": "pending",
            "productId": transaction.productID,
            "jws": jws,
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    private enum CreditOutcome {
        case credited(count: Int)
        case failed(message: String)
    }

    /// サーバーが `status` を `credited` / `failed` にするのを待つ。
    /// タイムアウトしたら throw する（呼び出し側は finish せずに保留する）。
    ///
    /// ⚠️ snapshot listener ではなく**ポーリング**にしている。listener は複数回発火するので
    ///    continuation の二重 resume を防ぐロックが要り、その正しさが読み取りにくくなる。
    ///    購入は稀なイベントなので、2秒ごとの単純な読み取りで十分かつ明らかに正しい。
    private func waitForCredit(docRef: DocumentReference) async throws -> CreditOutcome {
        let deadline = ContinuousClock.now.advanced(by: verificationTimeout)
        while ContinuousClock.now < deadline {
            let snapshot = try await docRef.getDocument()
            if let data = snapshot.data(), let status = data["status"] as? String {
                switch status {
                case "credited":
                    return .credited(count: data["creditedCount"] as? Int ?? 0)
                case "failed":
                    return .failed(message: (data["error"] as? String) ?? "購入を確認できませんでした")
                default:
                    break // pending のまま。次のポーリングへ
                }
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw SkyMotionCreditError.verificationTimedOut
    }

    /// UI 側で購入結果の表示をリセットする。
    func clearPurchaseState() {
        purchaseState = .idle
    }
}

enum SkyMotionCreditError: LocalizedError {
    case verificationTimedOut

    var errorDescription: String? {
        switch self {
        case .verificationTimedOut:
            "購入の反映を確認できませんでした（通信状況をご確認ください）"
        }
    }
}
