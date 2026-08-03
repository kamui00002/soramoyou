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
    /// 今日まだ使える無料枠の残り。サーバーが `livingSkyUsage` に書いた値から算出する。
    /// ⚠️ 上限は client にハードコードしない（β=3回 / 一般=1回で変わるうえ、
    ///    サーバーと二重管理すると必ずどちらかがズレる）。未取得の間は nil。
    @Published private(set) var freeRemainingToday: Int?
    /// 購入フローの状態。
    @Published private(set) var purchaseState: SkyMotionPurchaseState = .idle
    /// 取得済みプロダクト（価格表示用）。
    @Published private(set) var products: [Product] = []

    private let db = Firestore.firestore()
    private var balanceListener: ListenerRegistration?
    private var usageListener: ListenerRegistration?
    /// 現在購読中の uid。ログインし直しで別ユーザーの残高を出し続けないための見張り。
    private var observedUid: String?
    private var updatesTask: Task<Void, Never>?
    /// 購入処理の Task。**View ではなくこのサービスが所有する**（画面を閉じても走り切らせる）。
    private var purchaseTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.soramoyou", category: "SkyMotionCredit")

    /// サーバーの検証完了を待つ上限。超えても購入自体は Apple 側に残るので、
    /// 次回起動時の未完了トランザクション再送で拾い直せる（金銭喪失にはならない）。
    private let verificationTimeout: Duration = .seconds(60)

    private init() {}

    // MARK: - ライフサイクル

    /// 認証済みになったタイミングで呼ぶ（`ContentView` の `.task(id:)`）。
    /// 残高の購読と、**未完了トランザクションの再送**を開始する。
    ///
    /// 何度呼んでも安全:
    /// - 残高購読は uid が変わった時だけ張り直す
    /// - Transaction 監視は uid 非依存なので1本だけ維持する
    /// - 未完了トランザクションの再送はサーバーが冪等（doc ID = transactionId）
    func start() {
        observeBalance()
        startTransactionListener()
        Task { await drainUnfinishedTransactions() }
    }

    /// サインアウト時に呼ぶ。残高表示を持ち越さない。
    /// ⚠️ Transaction 監視は**止めない**。サインアウト中に確定した購入も、次回ログイン後の
    ///    再送で拾えるようにしておく（止めると取りこぼす）。
    func handleSignOut() {
        balanceListener?.remove()
        balanceListener = nil
        usageListener?.remove()
        usageListener = nil
        observedUid = nil
        balance = 0
        freeRemainingToday = nil
        purchaseState = .idle
    }

    /// 残高と無料枠の使用状況を購読する（どちらもサーバーが書いた値をそのまま反映する）。
    private func observeBalance() {
        guard let uid = Auth.auth().currentUser?.uid else {
            handleSignOut()
            return
        }
        // 同じ uid を二重購読しない（起動のたびに listener が積み上がるのを防ぐ）。
        guard uid != observedUid else { return }
        balanceListener?.remove()
        usageListener?.remove()
        observedUid = uid
        balance = 0 // 前のユーザーの残高を一瞬でも見せない
        freeRemainingToday = nil

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

        usageListener = db.collection("livingSkyUsage").document(uid)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    logger.error("無料枠の購読に失敗: \(error.localizedDescription, privacy: .public)")
                    return
                }
                let remaining = Self.freeRemaining(from: snapshot?.data())
                Task { @MainActor in self.freeRemainingToday = remaining }
            }
    }

    /// `livingSkyUsage` から「今日あと何回無料で作れるか」を求める。
    ///
    /// - 日付が今日でなければ lazy reset されるので上限まるごと残っている
    /// - `freeLimit` はサーバーが書いた当日の上限（β=3 / 一般=1）。無い場合は表示しない（nil）
    /// - β時代の legacy `reservedCount` は無料使用数として読む（サーバーの applyLazyReset と同じ規則）
    nonisolated static func freeRemaining(from data: [String: Any]?) -> Int? {
        guard let data, let limit = data["freeLimit"] as? Int else { return nil }
        let today = jstDateString()
        guard (data["day"] as? String) == today else { return max(0, limit) }
        let legacy = data["reservedCount"] as? Int ?? 0
        let used = data["freeUsedToday"] as? Int ?? legacy
        return max(0, limit - used)
    }

    /// JST の "YYYY-MM-DD"（サーバー `skyMotionCore.jstDateString` と同じ規則）。
    nonisolated static func jstDateString(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600) ?? .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
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
            let fetched = try await Product.products(for: Array(SkyMotionProduct.allProductIDs))
            products = fetched
            logger.info("回数パック: \(fetched.count, privacy: .public)件のプロダクトを取得")
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
    ///
    /// ⚠️ 実処理は**このサービスが所有する Task** で回す。View の `Task { }` に直接
    ///    書くと、シートを閉じた瞬間に Task が破棄され、`purchaseState` が `.verifying` の
    ///    まま二度と解決しない＝**購入ボタンが永久に押せなくなる**（2026-08-03 実機で発生）。
    ///    購入は「画面を閉じても最後まで走り切る」べき処理なので、寿命を View から切り離す。
    func purchase(productID: String = SkyMotionProduct.pack5) {
        guard purchaseTask == nil else {
            logger.info("回数パック: 購入処理が進行中のため無視")
            return
        }
        purchaseTask = Task { [weak self] in
            await self?.runPurchase(productID: productID)
            self?.purchaseTask = nil
        }
    }

    private func runPurchase(productID: String) async {
        guard let uid = Auth.auth().currentUser?.uid else {
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
            // 🔴 購入に appAccountToken（このuidに紐づく安定UUID）を埋め込む。
            //    これが無いと、「Aが購入 → finish前に落ちる → 同じ端末でBがログイン →
            //    起動時の未完了再送がその時点のuid=Bで購入docを作る」経路で
            //    **Bに誤付与**される（共有端末で現実に起こる）。サーバーはJWS内の
            //    このトークンで本当の購入者を確定する（skyMotionPurchase.js 参照）。
            let token = try await resolveAppAccountToken(uid: uid)
            let result = try await product.purchase(options: [.appAccountToken(token)])
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

    /// このユーザーの購入用 appAccountToken（安定UUID）を取得する。
    ///
    /// 初回に1度だけ生成して `users/{uid}.iapAccountToken` へ永続化し、以後は同じ値を返す
    /// （端末をまたいでも・再購入でも同一）。**uid から決定的にUUIDを計算する方式は採らない**
    /// —— Swift と Node で同じハッシュを実装して完全一致させるのは脆く、
    /// 保存された1つの値を双方が参照する方が確実（Fable設計）。
    ///
    /// ⚠️ 保存は**小文字**規約。Swift の `UUID().uuidString` は大文字だが、Apple のJWSに
    ///    載って返る appAccountToken は小文字になる。サーバーの逆引き（Firestoreの文字列
    ///    完全一致）が壊れないよう、書く時点で小文字に揃える。
    private func resolveAppAccountToken(uid: String) async throws -> UUID {
        let ref = db.collection("users").document(uid)
        let snap = try await ref.getDocument()
        if let str = snap.data()?["iapAccountToken"] as? String, let existing = UUID(uuidString: str) {
            return existing
        }
        let token = UUID()
        try await ref.setData(["iapAccountToken": token.uuidString.lowercased()], merge: true)
        return token
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
        // 既存確認は「二重送信を避ける」ための最適化に過ぎない。
        // ⚠️ **読めなかったからといって書き込みを諦めてはいけない。**
        //    ここで throw すると購入がサーバーに一度も届かず、ユーザーは払ったのに増えない。
        //    重複しても doc ID = transactionId なのでサーバー側が冪等に吸収する。
        if let existing = try? await docRef.getDocument(), existing.exists { return }
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
