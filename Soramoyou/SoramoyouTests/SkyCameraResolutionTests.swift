//
//  SkyCameraResolutionTests.swift ⭐️
//  SoramoyouTests
//
//  撮影解像度の型を検証する。
//  ⚠️ AVFoundation の既定は「端末が出せる**最小**」なので、指定を忘れると
//     4800万画素センサーの端末でも最小で撮れてしまう。ここは静かに壊れる類の設定。
//

import XCTest
@testable import SkyCamera

final class SkyCameraResolutionTests: XCTestCase {

    func testMegapixelsMatchAppleLabels() {
        // ⭐️ 四捨五入ではなく**切り捨て**。センサーの実画素数は宣伝値より必ず少し多いので、
        //    四捨五入すると 1 つ大きい数字が出る（実機で「49MP」と表示されて発覚した）。
        // 4032×3024 = 12.19MP → 12
        XCTAssertEqual(SkyCameraPhotoResolution(width: 4032, height: 3024).megapixels, 12)
        // 5712×4284 = 24.47MP → 24
        XCTAssertEqual(SkyCameraPhotoResolution(width: 5712, height: 4284).megapixels, 24)
        // 8064×6048 = 48.77MP → 48（四捨五入だと 49 になる）
        XCTAssertEqual(SkyCameraPhotoResolution(width: 8064, height: 6048).megapixels, 48)
    }

    func testLabel() {
        XCTAssertEqual(SkyCameraPhotoResolution(width: 4032, height: 3024).label, "12MP")
    }

    func testTwentyFourMegapixelNeedsDeferredDelivery() {
        // ⭐️ SDK ヘッダー明記: 24MP (5712×4284) は遅延写真配信を有効にしたときだけ
        //    24MP として提供される。うちは撮影直後にデータを受け取って編集へ渡すので、
        //    代理（proxy）が返る遅延配信とは噛み合わない。選べる一覧から外す対象。
        XCTAssertTrue(
            SkyCameraPhotoResolution(width: 5712, height: 4284).requiresDeferredDelivery)
    }

    func testOtherResolutionsDoNotNeedDeferredDelivery() {
        XCTAssertFalse(
            SkyCameraPhotoResolution(width: 4032, height: 3024).requiresDeferredDelivery)
        XCTAssertFalse(
            SkyCameraPhotoResolution(width: 8064, height: 6048).requiresDeferredDelivery)
    }
}
