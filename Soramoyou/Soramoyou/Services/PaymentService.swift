// ⭐️ PaymentService.swift
// StoreKit2 課金ファサード
//
//  Created on 2026-06-10.
//
//  ⚠️ 温存中（未配線）: 当初 広角合成(v2) を有料にする想定で実装したが、広角合成は無料化した。
//  この StoreKit2 ファサード一式は将来の「AI 補正」課金で再利用するため温存している。
//  現在どこからも参照していない（ContentView の起動配線・SettingsView の復元行・購入フローは外した）。
//  再有効化時: ① ContentView でリスナー開始＋loadProducts、② 機能側で purchase/isEntitled、
//             ③ SettingsView に「購入を復元」行を復活（ガイドライン 3.1.1）、④ .storekit / ASC を整備。
//
//  AdService と同じ流儀（static let shared + protocol + os.Logger）で StoreKit2 を薄く包む。
//  設計の要点:
//  - **購入状態の真実源は常に `Transaction.currentEntitlements`**（署名検証付き・StoreKit 管理）。
//    UserDefaults 等のローカルフラグだけを信頼しない（改ざん/再インストールで不整合になるため）。
//  - `VerificationResult` は必ず unwrap し、`.unverified` は機能解放しない・購入成功扱いにしない。
//  - 効果は端末内画像処理（サーバー副作用なし）なので receipt のサーバー検証は v1 では行わない
//    （currentEntitlements の署名検証で十分）。
//  - プロダクトは ASC 上の Non-Consumable。.storekit テスト構成があればローカルでも購入を再現できる。
//

import StoreKit
import os.log

/// 購入結果（UI 側で分岐するための分類）
enum PurchaseOutcome: Equatable {
    case success        // 購入成功（entitlement 付与済み）
    case userCancelled  // ユーザーがキャンセル
    case pending        // 承認待ち（ファミリー共有の購入承認等）
}

/// 課金ファサードのプロトコル（テストで Mock 差し替え可能にする）。
protocol PaymentServiceProtocol {
    /// 価格表示用のローカライズ価格文字列（未ロード時は nil）。
    func displayPrice(for productID: String) -> String?
    /// プロダクト情報をロードする。
    func loadProducts() async
    /// 指定プロダクトを購入する。
    func purchase(productID: String) async throws -> PurchaseOutcome
    /// 指定プロダクトを購入済み（entitlement あり）か。真実源は currentEntitlements。
    func isEntitled(to productID: String) async -> Bool
    /// 購入の復元（AppStore.sync）。
    func restore() async throws
}

@MainActor
final class PaymentService: ObservableObject, PaymentServiceProtocol {
    static let shared = PaymentService()

    /// ロード済みプロダクト（価格表示などに使う）。
    @Published private(set) var products: [Product] = []

    private var updatesTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.soramoyou", category: "PaymentService")

    private init() {}

    // MARK: - Transaction 監視（起動時に開始）

    /// 外部（App Store 側の購入承認・別端末での購入など）からの Transaction 更新を購読し finish する。
    /// アプリ起動時（ContentView 表示後）に一度だけ呼ぶ。
    func startTransactionListener() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.finishIfVerified(update)
            }
        }
    }

    private func finishIfVerified(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            logger.error("未検証の Transaction 更新を無視")
            return
        }
        await transaction.finish()
        logger.info("Transaction finished: \(transaction.productID, privacy: .public)")
    }

    // MARK: - PaymentServiceProtocol

    func displayPrice(for productID: String) -> String? {
        products.first { $0.id == productID }?.displayPrice
    }

    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: SkyStitchProduct.allProductIDs)
            self.products = fetched
            logger.info("Loaded \(fetched.count, privacy: .public) products")
        } catch {
            logger.error("loadProducts 失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    func purchase(productID: String) async throws -> PurchaseOutcome {
        // 未ロードなら取りに行く（初回購入で products が空のケースに備える）
        if products.first(where: { $0.id == productID }) == nil {
            await loadProducts()
        }
        guard let product = products.first(where: { $0.id == productID }) else {
            throw PaymentError.productNotFound
        }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            // 署名検証を必ず通す。未検証は購入成功扱いにしない。
            guard case .verified(let transaction) = verification else {
                throw PaymentError.unverified
            }
            await transaction.finish()
            logger.info("Purchase success: \(productID, privacy: .public)")
            return .success
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            return .pending
        }
    }

    func isEntitled(to productID: String) async -> Bool {
        // 真実源 = currentEntitlements（署名検証付き）。未検証は false 扱い。
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == productID {
                return true
            }
        }
        return false
    }

    func restore() async throws {
        try await AppStore.sync()
    }
}

// MARK: - PaymentError

enum PaymentError: LocalizedError {
    case productNotFound
    case unverified

    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return "購入アイテムを取得できませんでした。時間をおいて再度お試しください"
        case .unverified:
            return "購入の検証に失敗しました"
        }
    }
}
