//
//  SkyStitchViewModelTests.swift
//  SoramoyouTests
//
//  ⭐️ 広角合成(v2)の「成功時のみ課金」ロジックを Mock で検証する。
//  - 合成成功 → previewReady（ここで初めて購入可能）
//  - 合成失敗 → failed（購入に到達しない）
//  - 既購入(非消耗型) → 課金せず解放（purchase は呼ばれない＝二重課金防止）
//  - 購入成功 → purchased / キャンセル → previewReady へ戻す（料金なし）
//  実 StoreKit / 実 OpenCV には依存せず、PaymentService と stitch を注入する。
//

import XCTest
import UIKit
@testable import Soramoyou

final class SkyStitchViewModelTests: XCTestCase {

    /// PaymentServiceProtocol の Mock。entitled / 購入結果 / 例外を制御し、purchase 呼び出し回数を記録。
    final class MockPayment: PaymentServiceProtocol {
        var entitled = false
        var outcome: PurchaseOutcome = .success
        var purchaseError: Error?
        var purchaseCallCount = 0

        func displayPrice(for productID: String) -> String? { "¥300" }
        func loadProducts() async {}
        func purchase(productID: String) async throws -> PurchaseOutcome {
            purchaseCallCount += 1
            if let purchaseError { throw purchaseError }
            return outcome
        }
        func isEntitled(to productID: String) async -> Bool { entitled }
        func restore() async throws {}
    }

    private func dummyImage() -> UIImage {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return r.image { ctx in UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
    }

    @MainActor
    private func makeVM(payment: MockPayment, stitchStatus: SkyStitchStatus, image: UIImage?) -> SkyStitchViewModel {
        SkyStitchViewModel(
            payment: payment,
            stitch: { _ in SkyStitchResult(status: stitchStatus, image: image) }
        )
    }

    // MARK: - 合成

    @MainActor
    func testStitchOkLeadsToPreviewReady() async {
        let vm = makeVM(payment: MockPayment(), stitchStatus: .ok, image: dummyImage())
        await vm.runStitch([dummyImage(), dummyImage()])
        guard case .previewReady = vm.state else { return XCTFail("ok なら previewReady。実際: \(vm.state)") }
        XCTAssertNotNil(vm.stitchedImage)
    }

    @MainActor
    func testStitchFailureLeadsToFailedNotPreview() async {
        let vm = makeVM(payment: MockPayment(), stitchStatus: .needMoreImages, image: nil)
        await vm.runStitch([dummyImage(), dummyImage()])
        guard case .failed = vm.state else { return XCTFail("失敗時は failed。実際: \(vm.state)") }
    }

    @MainActor
    func testStitchOkButNilImageIsFailure() async {
        // status=.ok でも image=nil の異常系は failed（プレビュー＝購入に進ませない）
        let vm = makeVM(payment: MockPayment(), stitchStatus: .ok, image: nil)
        await vm.runStitch([dummyImage(), dummyImage()])
        guard case .failed = vm.state else { return XCTFail("ok+nil画像は failed。実際: \(vm.state)") }
    }

    // MARK: - 課金（成功時のみ）

    @MainActor
    func testAlreadyEntitledSkipsPurchase() async {
        let payment = MockPayment()
        payment.entitled = true
        let vm = makeVM(payment: payment, stitchStatus: .ok, image: dummyImage())
        await vm.runStitch([dummyImage(), dummyImage()])
        await vm.purchaseAndProceed()
        guard case .purchased = vm.state else { return XCTFail("既購入なら purchased。実際: \(vm.state)") }
        XCTAssertEqual(payment.purchaseCallCount, 0, "既購入なら purchase を呼ばない（二重課金防止）")
    }

    @MainActor
    func testPurchaseSuccessLeadsToPurchased() async {
        let payment = MockPayment()
        payment.entitled = false
        payment.outcome = .success
        let vm = makeVM(payment: payment, stitchStatus: .ok, image: dummyImage())
        await vm.runStitch([dummyImage(), dummyImage()])
        await vm.purchaseAndProceed()
        guard case .purchased = vm.state else { return XCTFail("購入成功なら purchased。実際: \(vm.state)") }
        XCTAssertEqual(payment.purchaseCallCount, 1)
    }

    @MainActor
    func testPurchaseCancelReturnsToPreview() async {
        let payment = MockPayment()
        payment.outcome = .userCancelled
        let vm = makeVM(payment: payment, stitchStatus: .ok, image: dummyImage())
        await vm.runStitch([dummyImage(), dummyImage()])
        await vm.purchaseAndProceed()
        guard case .previewReady = vm.state else { return XCTFail("キャンセルは previewReady へ戻す。実際: \(vm.state)") }
    }

    @MainActor
    func testPurchaseFromIdleIsNoOp() async {
        // previewReady でない状態（idle）からの購入は無視（合成前に課金させない）
        let payment = MockPayment()
        let vm = makeVM(payment: payment, stitchStatus: .ok, image: dummyImage())
        await vm.purchaseAndProceed()
        guard case .idle = vm.state else { return XCTFail("idle からは購入に進まない。実際: \(vm.state)") }
        XCTAssertEqual(payment.purchaseCallCount, 0, "合成前は purchase を呼ばない")
    }
}
