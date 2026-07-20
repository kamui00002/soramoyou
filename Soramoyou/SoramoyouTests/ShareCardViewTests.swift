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

    private func samplePost(location: Location? = nil, capturedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000),
                            frameId: String? = nil) -> Post {
        Post(
            id: "post-1",
            userId: "user-1",
            images: [],
            frameId: frameId,
            location: location,
            capturedAt: capturedAt,
            createdAt: Date(timeIntervalSince1970: 1_650_000_000)
        )
    }

    @MainActor
    func testRenderedImageIsExactly1080x1080PixelsWithWatermark() {
        let source = makeSourceImage(400, 300) // 非正方形の入力でも出力は正方形になるはず
        let rendered = ShareCardView.renderedImage(post: samplePost(), image: source, showWatermark: true, showLocation: true)

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
        let rendered = ShareCardView.renderedImage(post: samplePost(), image: source, showWatermark: false, showLocation: true)

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
        let rendered = ShareCardView.renderedImage(
            post: samplePost(location: location), image: source, showWatermark: true, showLocation: true
        )

        guard let cgImage = rendered?.cgImage else {
            XCTFail("renderedImage が nil または cgImage を持たない")
            return
        }
        XCTAssertEqual(cgImage.width, Int(ShareCardView.cardSize))
        XCTAssertEqual(cgImage.height, Int(ShareCardView.cardSize))
    }

    /// 修正1（P3保全）の回帰テスト: 書き出し画像は CIContextPool の outputColorSpace
    /// （Display P3）で明示的に createCGImage されているため、出力 cgImage の colorSpace は
    /// 常に Display P3 のはず。旧実装（View 全体を ImageRenderer でラスタライズ）では
    /// ここが sRGB 系に劣化していた。
    @MainActor
    func testRenderedImageColorSpaceIsDisplayP3() {
        let source = makeSourceImage(800, 800)
        let rendered = ShareCardView.renderedImage(post: samplePost(), image: source, showWatermark: true, showLocation: true)

        guard let colorSpace = rendered?.cgImage?.colorSpace else {
            XCTFail("renderedImage が nil または colorSpace を持たない")
            return
        }
        let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)
        XCTAssertEqual(colorSpace.name as String?, displayP3?.name as String?)
    }

    /// 修正1（P3保全）の再設計: frameId 付き投稿（aspect-fit＋ぼかし背景の経路）でも
    /// 出力サイズは常に 1080×1080 を維持する（fit 配置後の letterbox 分がキャンバスから
    /// はみ出したり縮んだりしていないことの回帰テスト）。
    @MainActor
    func testRenderedImageWithFrameIdIsExactly1080x1080Pixels() {
        // 縦長写真（気分フレーム付き投稿の典型: 縦位置撮影 + 下部プレート焼き込み済み）
        let source = makeSourceImage(600, 1400)
        let rendered = ShareCardView.renderedImage(
            post: samplePost(frameId: "calm_matte"), image: source, showWatermark: true, showLocation: true
        )

        guard let cgImage = rendered?.cgImage else {
            XCTFail("renderedImage が nil または cgImage を持たない")
            return
        }
        XCTAssertEqual(cgImage.width, Int(ShareCardView.cardSize))
        XCTAssertEqual(cgImage.height, Int(ShareCardView.cardSize))
    }

    /// 修正1の回帰テスト: capturedAt が nil の投稿（旧データ想定）でも createdAt に
    /// フォールバックしてクラッシュせず、出力サイズが変わらないことを確認する。
    @MainActor
    func testRenderedImageWithNilCapturedAtFallsBackWithoutCrash() {
        let source = makeSourceImage(500, 500)
        let rendered = ShareCardView.renderedImage(
            post: samplePost(capturedAt: nil), image: source, showWatermark: true, showLocation: true
        )

        guard let cgImage = rendered?.cgImage else {
            XCTFail("renderedImage が nil または cgImage を持たない")
            return
        }
        XCTAssertEqual(cgImage.width, Int(ShareCardView.cardSize))
        XCTAssertEqual(cgImage.height, Int(ShareCardView.cardSize))
    }

    /// 修正4/5の回帰テスト: 透かしON/OFFで出力ピクセルに差が出る（合成が実際に効いている）
    /// ことを検証する。差分は透かし文字が描かれる右下領域に限定されるはず
    /// （左上や中央の写真領域まで変わっていたらオーバーレイの向き・位置がずれている疑い）。
    @MainActor
    func testWatermarkToggleChangesBottomRightPixelsOnly() throws {
        let source = makeSourceImage(1080, 1080, color: .black)
        let withWatermark = try XCTUnwrap(
            ShareCardView.renderedImage(post: samplePost(), image: source, showWatermark: true, showLocation: true)?.cgImage
        )
        let withoutWatermark = try XCTUnwrap(
            ShareCardView.renderedImage(post: samplePost(), image: source, showWatermark: false, showLocation: true)?.cgImage
        )

        XCTAssertTrue(pixelsDiffer(withWatermark, withoutWatermark, in: bottomRightRegion))
        XCTAssertFalse(pixelsDiffer(withWatermark, withoutWatermark, in: topLeftRegion))
    }

    /// 修正5の回帰テスト: showLocation=false のときは locationText の有無に関わらず
    /// 出力ピクセルが同じ（=場所が実際に描かれていない）ことを検証する。
    @MainActor
    func testShowLocationFalseSuppressesLocationRegardlessOfPostData() throws {
        let location = Location(latitude: 35.66, longitude: 139.70, city: "渋谷区", prefecture: "東京都")
        let source = makeSourceImage(1080, 1080, color: .black)

        let hiddenWithLocationData = try XCTUnwrap(
            ShareCardView.renderedImage(
                post: samplePost(location: location), image: source, showWatermark: true, showLocation: false
            )?.cgImage
        )
        let noLocationData = try XCTUnwrap(
            ShareCardView.renderedImage(
                post: samplePost(location: nil), image: source, showWatermark: true, showLocation: true
            )?.cgImage
        )

        XCTAssertFalse(pixelsDiffer(hiddenWithLocationData, noLocationData, in: bottomLeftRegion))
    }

    // MARK: - Pixel Diff Helpers

    private var bottomRightRegion: CGRect {
        CGRect(x: Int(ShareCardView.cardSize) - 260, y: Int(ShareCardView.cardSize) - 120, width: 220, height: 80)
    }

    private var bottomLeftRegion: CGRect {
        CGRect(x: 40, y: Int(ShareCardView.cardSize) - 140, width: 320, height: 100)
    }

    private var topLeftRegion: CGRect {
        CGRect(x: 0, y: 0, width: 200, height: 200)
    }

    /// 2枚の cgImage の指定領域内に、無視できない画素差があるかを返す。
    private func pixelsDiffer(_ a: CGImage, _ b: CGImage, in region: CGRect) -> Bool {
        guard let dataA = pixelData(a, in: region), let dataB = pixelData(b, in: region) else { return true }
        guard dataA.count == dataB.count else { return true }
        var diffCount = 0
        for i in 0..<dataA.count where abs(Int(dataA[i]) - Int(dataB[i])) > 8 {
            diffCount += 1
        }
        return diffCount > 0
    }

    /// 指定領域（top-left 原点・CGImage.cropping(to:) と同じ座標系）を RGBA8 でラスタライズして
    /// バイト列を返す（sRGB に正規化して単純比較する）。
    /// - Note: `cropping(to:)` はビットマップの生ピクセル座標系（top-left 原点）を使う
    ///   （CGContext 描画の bottom-left 原点とは異なる）。先に crop してから同サイズの
    ///   context へそのまま描くため、上下反転の混乱を避けられる。
    private func pixelData(_ image: CGImage, in region: CGRect) -> [UInt8]? {
        guard let cropped = image.cropping(to: region) else { return nil }
        let width = cropped.width, height = cropped.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &buffer, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
