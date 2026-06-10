//
//  SkyStitchViewModelTests.swift
//  SoramoyouTests
//
//  ⭐️ 広角合成(v2)の状態機械を検証する（無料化後）。
//  - 合成成功 → previewReady（合成画像を保持）
//  - 合成失敗 → failed（プレビューに到達しない）
//  - status=.ok でも画像が nil の異常系 → failed
//  実 OpenCV には依存せず、stitch を注入する。
//
//  ※ 課金（PaymentService）は広角合成の無料化に伴い本 ViewModel から外したため、
//    購入系テスト・MockPayment は削除した。StoreKit 本体テストは将来の AI 補正課金で再導入する。
//

import XCTest
import UIKit
@testable import Soramoyou

final class SkyStitchViewModelTests: XCTestCase {

    private func dummyImage() -> UIImage {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return r.image { ctx in UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
    }

    @MainActor
    private func makeVM(stitchStatus: SkyStitchStatus, image: UIImage?) -> SkyStitchViewModel {
        SkyStitchViewModel(
            stitch: { _ in SkyStitchResult(status: stitchStatus, image: image) }
        )
    }

    // MARK: - 合成

    @MainActor
    func testStitchOkLeadsToPreviewReady() async {
        let vm = makeVM(stitchStatus: .ok, image: dummyImage())
        await vm.runStitch([dummyImage(), dummyImage()])
        guard case .previewReady = vm.state else { return XCTFail("ok なら previewReady。実際: \(vm.state)") }
        XCTAssertNotNil(vm.stitchedImage)
    }

    @MainActor
    func testStitchFailureLeadsToFailedNotPreview() async {
        let vm = makeVM(stitchStatus: .needMoreImages, image: nil)
        await vm.runStitch([dummyImage(), dummyImage()])
        guard case .failed = vm.state else { return XCTFail("失敗時は failed。実際: \(vm.state)") }
    }

    @MainActor
    func testStitchOkButNilImageIsFailure() async {
        // status=.ok でも image=nil の異常系は failed（プレビューに進ませない）
        let vm = makeVM(stitchStatus: .ok, image: nil)
        await vm.runStitch([dummyImage(), dummyImage()])
        guard case .failed = vm.state else { return XCTFail("ok+nil画像は failed。実際: \(vm.state)") }
    }
}
