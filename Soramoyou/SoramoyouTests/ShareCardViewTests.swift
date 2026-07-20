//
//  ShareCardViewTests.swift
//  SoramoyouTests
//
//  空カード共有パック ⭐️: ShareCardView.renderedImage() の出力サイズを固定する回帰テスト。
//  ImageRenderer は @MainActor 前提のため、テストメソッド自体を @MainActor にして実行する。
//

import XCTest
@testable import Soramoyou

final class ShareCardViewTests: XCTestCase {

    /// 指定ピクセルサイズの単色画像（scale=1 でピクセル＝ポイント）。
    /// cf. WidgetCacheWriterTests.makeImage
    private func makeSourceImage(_ width: CGFloat, _ height: CGFloat, color: UIColor = .systemBlue) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func samplePost(location: Location? = nil) -> Post {
        Post(
            id: "post-1",
            userId: "user-1",
            images: [],
            location: location,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @MainActor
    func testRenderedImageIsExactly1080x1080PixelsWithWatermark() {
        let source = makeSourceImage(400, 300) // 非正方形の入力でも出力は正方形になるはず
        let rendered = ShareCardView.renderedImage(post: samplePost(), image: source, showWatermark: true)

        guard let cgImage = rendered?.cgImage else {
            XCTFail("renderedImage が nil または cgImage を持たない")
            return
        }
        // .size ではなく cgImage の実ピクセル数を検証する
        // （.size はポイント単位のため scale が意図せず変わっても検知できない）
        XCTAssertEqual(cgImage.width, Int(ShareCardView.cardSize))
        XCTAssertEqual(cgImage.height, Int(ShareCardView.cardSize))
    }

    @MainActor
    func testRenderedImageIsExactly1080x1080PixelsWithoutWatermark() {
        let source = makeSourceImage(1200, 1200)
        let rendered = ShareCardView.renderedImage(post: samplePost(), image: source, showWatermark: false)

        guard let cgImage = rendered?.cgImage else {
            XCTFail("renderedImage が nil または cgImage を持たない")
            return
        }
        XCTAssertEqual(cgImage.width, Int(ShareCardView.cardSize))
        XCTAssertEqual(cgImage.height, Int(ShareCardView.cardSize))
    }

    @MainActor
    func testRenderedImageWithLocationDoesNotChangeOutputSize() {
        let location = Location(latitude: 35.66, longitude: 139.70, city: "渋谷区", prefecture: "東京都")
        let source = makeSourceImage(500, 500)
        let rendered = ShareCardView.renderedImage(post: samplePost(location: location), image: source, showWatermark: true)

        guard let cgImage = rendered?.cgImage else {
            XCTFail("renderedImage が nil または cgImage を持たない")
            return
        }
        XCTAssertEqual(cgImage.width, Int(ShareCardView.cardSize))
        XCTAssertEqual(cgImage.height, Int(ShareCardView.cardSize))
    }
}
