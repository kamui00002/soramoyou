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

    func testMegapixelsAreRounded() {
        // 4032×3024 = 12,192,768 → 12MP
        XCTAssertEqual(SkyCameraPhotoResolution(width: 4032, height: 3024).megapixels, 12)
        // 8064×6048 = 48,771,072 → 49MP（切り上げではなく四捨五入なので 49）
        XCTAssertEqual(SkyCameraPhotoResolution(width: 8064, height: 6048).megapixels, 49)
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
