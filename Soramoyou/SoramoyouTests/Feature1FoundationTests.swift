//
//  Feature1FoundationTests.swift
//  SoramoyouTests
//
//  ⭐️ 機能1（気分フレーム＋気持ちコメント）共通基盤(STEP 1)のテスト
//  - Mood / MoodStyle の基本契約
//  - Post の mood / frameId Firestore 往復（toFirestoreData ↔ init(from:)）
//  - ImageCompositor の合成契約（extent 保持 / 描画可能 / caption 未入力は passthrough）
//    + キャプション配置のピクセル検証（mirror・placement をビルドでなく実描画で担保）
//

import XCTest
import CoreImage
import UIKit
import FirebaseFirestore
@testable import Soramoyou

final class Feature1FoundationTests: XCTestCase {

    // MARK: - Helpers

    /// 単色の base 画像を生成（RGBA8 / sRGB）
    private func makeSolidBase(gray: UInt8, width: Int, height: Int) -> CIImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = gray; bytes[i + 1] = gray; bytes[i + 2] = gray; bytes[i + 3] = 255
        }
        return CIImage(
            bitmapData: Data(bytes),
            bytesPerRow: width * 4,
            size: CGSize(width: width, height: height),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
    }

    /// 合成結果を実描画し、白に近い画素の数と「行（縦）方向の重心」を返す。
    /// 行 0 を上端とした座標で重心を出すため、placement(.top/.bottom) の上下を機械検証できる。
    private func whiteStats(_ image: CIImage, threshold: UInt8 = 150) -> (count: Int, centroidY: Double) {
        let ctx = CIContext()
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0, let cg = ctx.createCGImage(image, from: image.extent) else {
            return (0, 0)
        }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let c = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        c?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var count = 0
        var rowSum = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if bytes[i] > threshold, bytes[i + 1] > threshold, bytes[i + 2] > threshold {
                    count += 1
                    rowSum += Double(y)
                }
            }
        }
        return (count, count > 0 ? rowSum / Double(count) : 0)
    }

    // MARK: - Mood / MoodStyle

    func testMoodCasesAndRawValuesAreStable() {
        // raw value は Firestore 保存値。表示名変更で壊れないことを担保する。
        XCTAssertEqual(Mood.allCases.count, 5)
        XCTAssertEqual(Mood.calm.rawValue, "calm")
        XCTAssertEqual(Mood.uplifted.rawValue, "uplifted")
        XCTAssertEqual(Mood.wistful.rawValue, "wistful")
        XCTAssertEqual(Mood.dignified.rawValue, "dignified")
        XCTAssertEqual(Mood.dreamy.rawValue, "dreamy")
    }

    func testEveryMoodHasStyle() {
        for mood in Mood.allCases {
            XCTAssertFalse(mood.style.palette.isEmpty, "\(mood) の palette が空")
            XCTAssertFalse(mood.displayName.isEmpty)
            XCTAssertFalse(mood.iconName.isEmpty)
        }
    }

    func testMoodPlacementsAsDesigned() {
        XCTAssertEqual(Mood.dignified.style.captionPlacement, .top)
        XCTAssertEqual(Mood.calm.style.captionPlacement, .bottom)
        XCTAssertEqual(Mood.uplifted.style.captionPlacement, .center)
    }

    // MARK: - Post 往復

    func testPostMoodAndFrameIdRoundTrip() throws {
        let image = ImageInfo(url: "https://example.com/a.jpg", width: 100, height: 200, order: 0)
        let post = Post(
            id: "p1", userId: "u1", images: [image],
            caption: "暮れていく空", mood: .wistful, frameId: "frame_wistful_01",
            visibility: .public
        )

        let data = post.toFirestoreData()
        XCTAssertEqual(data["mood"] as? String, "wistful")
        XCTAssertEqual(data["frameId"] as? String, "frame_wistful_01")

        let restored = try Post(from: data)
        XCTAssertEqual(restored.mood, .wistful)
        XCTAssertEqual(restored.frameId, "frame_wistful_01")
        XCTAssertEqual(restored.caption, "暮れていく空")
    }

    func testPostWithoutMoodIsBackwardCompatible() throws {
        // 旧投稿（mood / frameId なし）が壊れないこと。
        let image = ImageInfo(url: "https://example.com/b.jpg", width: 100, height: 200, order: 0)
        let post = Post(id: "p2", userId: "u1", images: [image], visibility: .public)

        let data = post.toFirestoreData()
        XCTAssertNil(data["mood"])
        XCTAssertNil(data["frameId"])

        let restored = try Post(from: data)
        XCTAssertNil(restored.mood)
        XCTAssertNil(restored.frameId)
    }

    // MARK: - ImageCompositor 契約

    func testComposeKeepsCanvasExtent() {
        let base = makeSolidBase(gray: 128, width: 240, height: 360)
        let out = ImageCompositor.compose(.init(base: base, caption: "テスト", mood: .calm))
        XCTAssertEqual(out.extent.width, 240, accuracy: 1)
        XCTAssertEqual(out.extent.height, 360, accuracy: 1)
    }

    func testComposeIsRenderable() {
        let base = makeSolidBase(gray: 128, width: 240, height: 360)
        let out = ImageCompositor.compose(.init(base: base, caption: "テスト", mood: .dreamy))
        let ctx = CIContext()
        XCTAssertNotNil(ctx.createCGImage(out, from: out.extent))
    }

    func testEmptyCaptionLeavesBasePixelsUnchanged() {
        // caption 未入力 & フレームなし → 合成は base そのまま（passthrough）。
        let base = makeSolidBase(gray: 128, width: 240, height: 360)
        let passthrough = ImageCompositor.compose(.init(base: base, caption: nil, mood: .calm))
        // base 自体は白画素ゼロ（gray 128 < 150）。passthrough も同じであること。
        XCTAssertEqual(whiteStats(base).count, 0)
        XCTAssertEqual(whiteStats(passthrough).count, 0)

        // 空白のみのキャプションも passthrough 扱い。
        let blank = ImageCompositor.compose(.init(base: base, caption: "   ", mood: .calm))
        XCTAssertEqual(whiteStats(blank).count, 0)
    }

    func testCaptionAddsWhitePixels() {
        // 暗い base に白系キャプションを焼くと白画素が現れる。
        let base = makeSolidBase(gray: 30, width: 240, height: 360)
        XCTAssertEqual(whiteStats(base).count, 0, "base は暗いので白画素ゼロのはず")

        let captioned = ImageCompositor.compose(
            .init(base: base, caption: "しずかな空にひとことを", mood: .calm)
        )
        XCTAssertGreaterThan(whiteStats(captioned).count, 0, "キャプションの白画素が現れるはず")
    }

    func testCaptionPlacementTopVsBottomIsNotMirrored() {
        // .top 指定は視覚上部、.bottom 指定は視覚下部に出る（mirror していない）ことを
        // 行重心で機械検証する。dignified=.top / calm=.bottom はともに白文字。
        let base = makeSolidBase(gray: 30, width: 240, height: 360)
        let text = "しずかな空にひとことを"

        let top = ImageCompositor.compose(.init(base: base, caption: text, mood: .dignified))
        let bottom = ImageCompositor.compose(.init(base: base, caption: text, mood: .calm))

        let topStats = whiteStats(top)
        let bottomStats = whiteStats(bottom)
        XCTAssertGreaterThan(topStats.count, 0)
        XCTAssertGreaterThan(bottomStats.count, 0)

        // 行 0 = 上端。top 配置の重心は bottom 配置より十分小さい（＝上にある）。
        XCTAssertLessThan(
            topStats.centroidY, bottomStats.centroidY,
            "top 配置(\(topStats.centroidY)) が bottom 配置(\(bottomStats.centroidY)) より上に来ていない"
        )
    }

    // MARK: - フレーム生成（renderFrame）

    /// 指定座標のアルファ(0...1)を返す
    private func alpha(_ image: CIImage, x: Int, y: Int) -> Double {
        let ctx = CIContext()
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0, let cg = ctx.createCGImage(image, from: image.extent) else { return 0 }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let c = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        c?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cx = min(max(x, 0), w - 1), cy = min(max(y, 0), h - 1)
        return Double(bytes[(cy * w + cx) * 4 + 3]) / 255.0
    }

    func testRenderFrameKeepsExtent() {
        let extent = CGRect(x: 0, y: 0, width: 240, height: 360)
        guard let frame = ImageCompositor.renderFrame(mood: .wistful, in: extent) else {
            XCTFail("renderFrame が nil")
            return
        }
        XCTAssertEqual(frame.extent.width, 240, accuracy: 1)
        XCTAssertEqual(frame.extent.height, 360, accuracy: 1)
    }

    func testRenderFrameHasTransparentCenterAndColoredEdge() {
        // 最大の失敗モード=「中心くり抜き忘れ」を検出する。
        // 中心は透過(写真が見える)・縁は不透明(枠の色)であること。
        let w = 240, h = 360
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        guard let frame = ImageCompositor.renderFrame(mood: .calm, in: extent) else {
            XCTFail("renderFrame が nil")
            return
        }
        let centerAlpha = alpha(frame, x: w / 2, y: h / 2)
        // 上辺中央の枠内(border≈w*0.045≈11px なので y=4 は枠の中)
        let edgeAlpha = alpha(frame, x: w / 2, y: 4)

        XCTAssertLessThan(centerAlpha, 0.1, "中心は透過しているべき(写真が主役)。塗りつぶし=くり抜き忘れ")
        XCTAssertGreaterThan(edgeAlpha, 0.5, "縁(枠)には色が乗っているべき")
    }

    // MARK: - 焼き込み seam（composeToUIImage / orientation 往復）

    /// 単色 UIImage を指定 orientation 付きで生成（raw ピクセルは width×height）
    private func makeSolidUIImage(gray: UInt8, width: Int, height: Int, orientation: UIImage.Orientation) -> UIImage? {
        let ci = makeSolidBase(gray: gray, width: width, height: height)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: orientation)
    }

    /// 指定座標の RGB 平均輝度(0...255)
    private func brightness(_ image: CIImage, x: Int, y: Int) -> Double {
        let ctx = CIContext()
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0, let cg = ctx.createCGImage(image, from: image.extent) else { return 0 }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let c = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        c?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cx = min(max(x, 0), w - 1), cy = min(max(y, 0), h - 1)
        let i = (cy * w + cx) * 4
        return (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3.0
    }

    func testComposeToUIImageNormalizesOrientationAndBurnsIn() throws {
        // raw 240×360 を .right(横向き保存)として作る。表示時は回転して 360×240 になる。
        // 投稿フローで実際に来る「向きタグ付き画像」を模す（CIImage は向きを無視する罠の回帰）。
        let base = try XCTUnwrap(makeSolidUIImage(gray: 30, width: 240, height: 360, orientation: .right))
        XCTAssertEqual(base.imageOrientation, .right)

        let out = ImageCompositor.composeToUIImage(base: base, mood: .calm, caption: "ひとことを添えて")

        // 1) 向きが .up に正規化される（uploadImages→encodeJPEG の正規化と整合）
        XCTAssertEqual(out.imageOrientation, .up)
        // 2) .right 適用で幅高さが入れ替わる（240×360 → 360×240）
        XCTAssertEqual(out.size.width, 360, accuracy: 1)
        XCTAssertEqual(out.size.height, 240, accuracy: 1)

        let outCI = try XCTUnwrap(out.cgImage.map { CIImage(cgImage: $0) })
        // 3) キャプションの白画素が焼き込まれている
        XCTAssertGreaterThan(whiteStats(outCI).count, 0, "キャプションが焼き込まれているべき")
        // 4) 端にフレーム枠の色が乗っている（base gray30 より明るい）
        let edgeBrightness = brightness(outCI, x: Int(out.size.width) / 2, y: 4)
        XCTAssertGreaterThan(edgeBrightness, 50, "端にフレーム枠が乗っているべき(base 30 より明るい)")
    }

    func testComposeToUIImagePassthroughWhenNoMoodNoCaption() throws {
        // mood も caption も無ければ合成なし（向き正規化のみ）。白画素ゼロ。
        let base = try XCTUnwrap(makeSolidUIImage(gray: 30, width: 200, height: 300, orientation: .up))
        let out = ImageCompositor.composeToUIImage(base: base, mood: nil, caption: nil)
        let outCI = try XCTUnwrap(out.cgImage.map { CIImage(cgImage: $0) })
        XCTAssertEqual(whiteStats(outCI).count, 0, "mood/caption 無しなら白画素は出ない")
    }
}
