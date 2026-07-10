//
//  FilterGraphBuilderTests.swift
//  SoramoyouTests
//
//  ⭐️ 各編集ツールの振る舞いテスト
//  B1〜B7 のバグ修正が正しく効いていることを検証する。
//

import XCTest
import CoreImage
import UIKit
@testable import Soramoyou

final class FilterGraphBuilderTests: XCTestCase {

    // MARK: - Helpers

    /// 中間グレー 128 の単色画像を生成（サイズ 64x64）
    private func makeGraySource(gray: UInt8 = 128) -> CIImage {
        let size = 64
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i]     = gray
            bytes[i + 1] = gray
            bytes[i + 2] = gray
            bytes[i + 3] = 255
        }
        let data = Data(bytes)
        return CIImage(bitmapData: data,
                       bytesPerRow: size * 4,
                       size: CGSize(width: size, height: size),
                       format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// 指定座標の RGBA 平均を取得（中央付近 4x4 を平均）
    private func sampleCenterRGB(_ image: CIImage) -> (r: Double, g: Double, b: Double) {
        let context = CIContext()
        let cropped = image.cropped(to: CGRect(x: 30, y: 30, width: 4, height: 4))
        let renderRect = CGRect(x: 30, y: 30, width: 4, height: 4)
        guard let cg = context.createCGImage(cropped, from: renderRect) else {
            XCTFail("CGImage 生成失敗")
            return (0, 0, 0)
        }
        var bytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &bytes,
                            width: 4,
                            height: 4,
                            bitsPerComponent: 8,
                            bytesPerRow: 4 * 4,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: 4, height: 4))

        var r: Double = 0, g: Double = 0, b: Double = 0
        let pixelCount = 4 * 4
        for i in stride(from: 0, to: bytes.count, by: 4) {
            r += Double(bytes[i])
            g += Double(bytes[i + 1])
            b += Double(bytes[i + 2])
        }
        return (r / Double(pixelCount), g / Double(pixelCount), b / Double(pixelCount))
    }

    /// 画像の分散（ノイズ量）を中央領域から推定
    private func centerVariance(_ image: CIImage) -> Double {
        let context = CIContext()
        let region = CGRect(x: 16, y: 16, width: 32, height: 32)
        let cropped = image.cropped(to: region)
        guard let cg = context.createCGImage(cropped, from: region) else { return 0 }
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &bytes,
                            width: 32,
                            height: 32,
                            bitsPerComponent: 8,
                            bytesPerRow: 32 * 4,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 32))

        // R チャネルの分散
        var mean: Double = 0
        let count = 32 * 32
        for i in stride(from: 0, to: bytes.count, by: 4) {
            mean += Double(bytes[i])
        }
        mean /= Double(count)

        var variance: Double = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let d = Double(bytes[i]) - mean
            variance += d * d
        }
        return variance / Double(count)
    }

    /// レシピを指定値で構築するヘルパー
    private func recipe(_ configure: (inout EditRecipe) -> Void) -> EditRecipe {
        var r = EditRecipe()
        configure(&r)
        return r
    }

    // MARK: - B1: ハイライト（正負両方向が効くか）

    func testHighlightsNegativeDarkens() {
        // Given: 明るい画像（220 のグレー）
        let src = makeGraySource(gray: 220)
        let before = sampleCenterRGB(src)

        // When: ハイライト -1（下げる）
        var r = EditRecipe()
        r.highlights = 1.0 + (-1.0) // 0.0 に相当
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)
        let after = sampleCenterRGB(out)

        // Then: 明部が暗くなる（R が減少）
        XCTAssertLessThan(after.r, before.r - 10, "ハイライト -1 で明部が暗くならない")
    }

    func testHighlightsPositiveBrightens() {
        // Given: 中〜明るい画像（180）
        let src = makeGraySource(gray: 180)
        let before = sampleCenterRGB(src)

        // When: ハイライト +1（上げる）
        var r = EditRecipe()
        r.highlights = 1.0 + 1.0
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)
        let after = sampleCenterRGB(out)

        // Then: 明部が明るくなる（旧実装ではここが頭打ちだった）
        XCTAssertGreaterThan(after.r, before.r + 2, "ハイライト +1 で明部が明るくならない（B1 回帰）")
    }

    // MARK: - B2: シャドウ（負値で暗く、正値で明るく）

    func testShadowsNegativeDarkens() {
        // Given: 暗い画像（60）
        let src = makeGraySource(gray: 60)
        let before = sampleCenterRGB(src)

        // When: シャドウ -1（暗部を更に暗く）
        var r = EditRecipe()
        r.shadowAmount = 1.0 + (-1.0) // 0.0 に相当
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)
        let after = sampleCenterRGB(out)

        // Then: 暗部が更に暗くなる（旧実装ではここが頭打ちだった）
        XCTAssertLessThan(after.r, before.r - 2, "シャドウ -1 で暗部が暗くならない（B2 回帰）")
    }

    func testShadowsPositiveBrightens() {
        // Given: 暗い画像（60）
        let src = makeGraySource(gray: 60)
        let before = sampleCenterRGB(src)

        // When: シャドウ +1（シャドウを持ち上げ）
        var r = EditRecipe()
        r.shadowAmount = 1.0 + 1.0
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)
        let after = sampleCenterRGB(out)

        // Then: 暗部が明るくなる
        XCTAssertGreaterThan(after.r, before.r + 10, "シャドウ +1 で暗部が明るくならない")
    }

    // MARK: - B3: シャープネス（負値でブラー）

    func testSharpnessNegativeBlursHighFrequency() {
        // 高周波（チェッカー模様）の画像で分散が減ることを確認
        let size = 64
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let c: UInt8 = ((x / 2 + y / 2) % 2 == 0) ? 64 : 200
                bytes[i]     = c
                bytes[i + 1] = c
                bytes[i + 2] = c
                bytes[i + 3] = 255
            }
        }
        let src = CIImage(bitmapData: Data(bytes),
                          bytesPerRow: size * 4,
                          size: CGSize(width: size, height: size),
                          format: .RGBA8,
                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let before = centerVariance(src)

        var r = EditRecipe()
        r.sharpnessNorm = -1.0
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)
        let after = centerVariance(out)

        // ブラーがかかると分散が減る
        XCTAssertLessThan(after, before * 0.8, "シャープネス -1 でブラーが効いていない（B3 回帰）")
    }

    // MARK: - B4: テクスチャ（負値で分散低下、正値で分散増加）

    func testTextureNegativeReducesDetail() {
        let size = 64
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let c: UInt8 = ((x + y) % 2 == 0) ? 80 : 180
                bytes[i]     = c
                bytes[i + 1] = c
                bytes[i + 2] = c
                bytes[i + 3] = 255
            }
        }
        let src = CIImage(bitmapData: Data(bytes),
                          bytesPerRow: size * 4,
                          size: CGSize(width: size, height: size),
                          format: .RGBA8,
                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let before = centerVariance(src)

        var r = EditRecipe()
        r.textureNorm = -1.0
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)
        let after = centerVariance(out)

        XCTAssertLessThan(after, before * 0.8, "テクスチャ -1 でディテールが減らない（B4 回帰）")
    }

    // MARK: - B5: クラリティ（負値でコントラスト低下）

    func testClarityNegativeReducesContrast() {
        // 中央グレーに対して、コントラストを下げると中央値は変わらずとも
        // 端の「黒 20 / 白 220」のサンプルで差が縮む
        let size = 64
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let c: UInt8 = x < size / 2 ? 20 : 220
                bytes[i]     = c
                bytes[i + 1] = c
                bytes[i + 2] = c
                bytes[i + 3] = 255
            }
        }
        let src = CIImage(bitmapData: Data(bytes),
                          bytesPerRow: size * 4,
                          size: CGSize(width: size, height: size),
                          format: .RGBA8,
                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        // 元画像の左右差
        func sample(_ img: CIImage, atX x: Int) -> Double {
            let ctx = CIContext()
            let region = CGRect(x: x, y: 30, width: 4, height: 4)
            guard let cg = ctx.createCGImage(img.cropped(to: region), from: region) else { return 0 }
            var b = [UInt8](repeating: 0, count: 4 * 4 * 4)
            let cs = CGColorSpaceCreateDeviceRGB()
            let c = CGContext(data: &b, width: 4, height: 4, bitsPerComponent: 8,
                              bytesPerRow: 16, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            c?.draw(cg, in: CGRect(x: 0, y: 0, width: 4, height: 4))
            var r: Double = 0
            for i in stride(from: 0, to: b.count, by: 4) { r += Double(b[i]) }
            return r / 16.0
        }
        let diffBefore = sample(src, atX: 50) - sample(src, atX: 10)

        var rcp = EditRecipe()
        rcp.clarityNorm = -1.0
        let out = FilterGraphBuilder.buildGraph(recipe: rcp, source: src)
        let diffAfter = sample(out, atX: 50) - sample(out, atX: 10)

        XCTAssertLessThan(diffAfter, diffBefore, "クラリティ -1 でコントラストが下がらない（B5 回帰）")
    }

    // MARK: - B6: ノイズリダクション（負値で no-op）

    func testNoiseReductionNegativeIsNoOp() {
        let src = makeGraySource(gray: 128)
        let before = sampleCenterRGB(src)

        var r = EditRecipe()
        r.noiseReductionNorm = -1.0
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)
        let after = sampleCenterRGB(out)

        // 負値は no-op なので元画像とほぼ一致すること
        XCTAssertEqual(after.r, before.r, accuracy: 1.0, "ノイズリダクション -1 が no-op になっていない（B6 回帰）")
        XCTAssertEqual(after.g, before.g, accuracy: 1.0)
        XCTAssertEqual(after.b, before.b, accuracy: 1.0)
    }

    // MARK: - B7: グレイン（中間調保持、全体が暗くならない）

    func testGrainPreservesMidTones() {
        // 中間グレー 128 にグレインを載せた場合、領域平均は 128 付近を維持するはず
        // （旧実装の multiplyBlend は平均が大きく暗くなる方向にシフトした）
        //
        // overlayBlendMode は中心 0.5 のグレーノイズを使うことで、
        // ノイズ平均 0.5 → 領域平均が保存される性質を持つ。
        // 4x4 だとサンプル数が少なくバラつくため、32x32 で平均を取る。
        let src = makeGraySource(gray: 128)

        var r = EditRecipe()
        r.grainNorm = 1.0
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)

        // 32x32 の中央領域から平均輝度を算出
        func regionMean(_ image: CIImage) -> Double {
            let ctx = CIContext()
            let region = CGRect(x: 16, y: 16, width: 32, height: 32)
            guard let cg = ctx.createCGImage(image.cropped(to: region), from: region) else {
                return 0
            }
            var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
            let cs = CGColorSpaceCreateDeviceRGB()
            let c = CGContext(data: &bytes, width: 32, height: 32, bitsPerComponent: 8,
                              bytesPerRow: 32 * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            c?.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            var sum: Double = 0
            for i in stride(from: 0, to: bytes.count, by: 4) { sum += Double(bytes[i]) }
            return sum / Double(32 * 32)
        }

        let beforeMean = regionMean(src)
        let afterMean  = regionMean(out)

        // 平均値は元の 128 から一方向に大きく外れないこと（multiply blend 回帰検出）
        //
        // NOTE: `CIRandomGenerator` は working color space（拡張 sRGB リニア）で生成され、
        // 画像側は sRGB ガンマで投入されるため、overlayBlend で色空間のガンマ差分だけ
        // わずかに平均が持ち上がる（＋10 前後）。旧 multiply blend では −40 以上の
        // 大幅な暗化が観測されたため、ここではその回帰だけを確実に検出できる
        // 幅（±15）で十分。
        XCTAssertEqual(afterMean, beforeMean, accuracy: 15.0,
            "グレイン適用で領域平均が大きくシフト（B7 回帰: multiply blend 同等の暗化）")

        // 一方でノイズ自体は載っている（分散が増えている）こと
        XCTAssertGreaterThan(centerVariance(out), centerVariance(src),
            "グレインでノイズが載っていない")
    }

    // MARK: - クロップ（cropRectNorm 適用）

    func testCropRectTrimsImage() {
        // Given: 64x64 のグレー画像
        let src = makeGraySource(gray: 128)
        XCTAssertEqual(src.extent.width,  64)
        XCTAssertEqual(src.extent.height, 64)

        // When: 中央 50% のクロップ
        var r = EditRecipe()
        r.cropRectNorm = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)

        // Then: 出力 extent が 32x32 に縮むこと
        XCTAssertEqual(out.extent.width,  32, accuracy: 1.0, "クロップ後の幅が期待値と異なる")
        XCTAssertEqual(out.extent.height, 32, accuracy: 1.0, "クロップ後の高さが期待値と異なる")
    }

    func testCropFullRectIsNoOp() {
        // Given: 完全矩形（フルサイズ指定）
        let src = makeGraySource(gray: 128)

        // When: クロップ無し相当
        var r = EditRecipe()
        r.cropRectNorm = CGRect(x: 0, y: 0, width: 1, height: 1)
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)

        // Then: サイズ変化なし（no-op）
        XCTAssertEqual(out.extent.width,  src.extent.width)
        XCTAssertEqual(out.extent.height, src.extent.height)
    }

    // MARK: - H-1: ハイライト + 方向の視認性回帰

    /// v=+0.5 相当でも「視認できる」量のリフトが発生すること。
    /// 旧実装では y3 が 0.855 までしか上がらず、中〜明の画素にほとんど効かなかったが、
    /// 新実装では v=+0.5 で y3 ≈ 0.89 以上になり、明部が ~15/255 以上明るくなる。
    func testHighlightsPositiveHalfIsVisible() {
        let src = makeGraySource(gray: 200) // 明部寄りのサンプル
        let before = sampleCenterRGB(src)

        var r = EditRecipe()
        r.highlights = 1.0 + 0.5 // スライダ中央から半分振った想定
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)
        let after = sampleCenterRGB(out)

        XCTAssertGreaterThan(after.r, before.r + 10,
            "ハイライト +0.5 で明部がほとんど変化していない（H-1 回帰）")
    }

    // MARK: - H-2: クラリティ + 方向の視認性回帰

    /// エッジを含む画像にクラリティ +1.0 を適用すると、分散（コントラスト）が増加する。
    /// 旧実装（radius=0.81px）では分散変化が僅かだったが、
    /// 新実装（radius=3.5px・intensity=0.75）では明確に分散が増えるはず。
    func testClarityPositiveIncreasesEdgeContrast() {
        let size = 64
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                // 左右でグラデーション（中間コントラストのエッジを作る）
                let c: UInt8 = x < size / 2 ? 80 : 180
                bytes[i]     = c
                bytes[i + 1] = c
                bytes[i + 2] = c
                bytes[i + 3] = 255
            }
        }
        let src = CIImage(bitmapData: Data(bytes),
                          bytesPerRow: size * 4,
                          size: CGSize(width: size, height: size),
                          format: .RGBA8,
                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        let before = centerVariance(src)

        var r = EditRecipe()
        r.clarityNorm = 1.0
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)
        let after = centerVariance(out)

        XCTAssertGreaterThan(after, before * 1.05,
            "クラリティ +1.0 でミッドコントラストが持ち上がっていない（H-2 回帰）")
    }

    // MARK: - M-2: ホワイトバランスの視認性回帰

    /// 中間グレーにホワイトバランス +0.5 を適用すると、targetNeutral が
    /// 6500K → 7500K に上がり、CITemperatureAndTint は「源の白点が 6500K、
    /// 目標は 7500K（= より冷たい白）」として補正するため出力は寒色寄りになる。
    /// 旧実装（scale=1000K）では +500K で肉眼では変化が見えなかった。
    /// 新実装（scale=2000K）では +1000K シフトし、B と R の差が十分生じる。
    func testWhiteBalancePositiveShiftsTowardCool() {
        let src = makeGraySource(gray: 128)

        var r = EditRecipe()
        r.whiteBalanceNorm = 0.5
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)
        let after = sampleCenterRGB(out)

        XCTAssertGreaterThan(after.b - after.r, 5,
            "ホワイトバランス +0.5 で寒色方向にシフトしていない（M-2 回帰）")
    }

    // MARK: - M-2: フェードの視認性回帰

    /// フェード +1 で黒が持ち上がり、暗部画素の値が明確に増加する。
    func testFadePositiveLiftsShadows() {
        let src = makeGraySource(gray: 20)
        let before = sampleCenterRGB(src)

        var r = EditRecipe()
        r.fadeNorm = 1.0
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)
        let after = sampleCenterRGB(out)

        // bias 0.2 → 暗部は +20% 程度（≒ +51/255）持ち上がる設計
        XCTAssertGreaterThan(after.r, before.r + 30,
            "フェード +1 で暗部が十分持ち上がっていない（M-2 回帰）")
    }

    // MARK: - ハイライト/シャドウ の新実装が両値同時適用で破綻しないか

    /// `testHighlightAndShadowApplyTogether` 専用の2バンド画像（暗バンド/明バンド）を生成する。
    /// EditToolsPhotosParityTests の makeTwoBandSource と同型だが、既存ヘルパーは変更禁止のため
    /// このテスト専用にローカル実装する。
    /// - Parameters:
    ///   - darkGray: 上半分（暗バンド）のグレー値
    ///   - brightGray: 下半分（明バンド）のグレー値
    private func makeTwoBandSourceForHighlightShadowTest(darkGray: UInt8 = 51, brightGray: UInt8 = 204) -> CIImage {
        let size = 64
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let c: UInt8 = y < size / 2 ? darkGray : brightGray
                bytes[i]     = c
                bytes[i + 1] = c
                bytes[i + 2] = c
                bytes[i + 3] = 255
            }
        }
        let data = Data(bytes)
        return CIImage(bitmapData: data,
                       bytesPerRow: size * 4,
                       size: CGSize(width: size, height: size),
                       format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// 指定 y 座標を起点とした 4x4 領域の RGBA 平均を取得
    private func sampleBand(_ image: CIImage, y: Int) -> (r: Double, g: Double, b: Double) {
        let context = CIContext()
        let region = CGRect(x: 30, y: y, width: 4, height: 4)
        guard let cg = context.createCGImage(image.cropped(to: region), from: region) else {
            XCTFail("CGImage 生成失敗")
            return (0, 0, 0)
        }
        var bytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &bytes,
                            width: 4,
                            height: 4,
                            bitsPerComponent: 8,
                            bytesPerRow: 4 * 4,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: 4, height: 4))

        var r: Double = 0, g: Double = 0, b: Double = 0
        let pixelCount = 4 * 4
        for i in stride(from: 0, to: bytes.count, by: 4) {
            r += Double(bytes[i])
            g += Double(bytes[i + 1])
            b += Double(bytes[i + 2])
        }
        return (r / Double(pixelCount), g / Double(pixelCount), b / Double(pixelCount))
    }

    /// P1 で CIHighlightShadowAdjust（局所適応・iPhone標準の写真アプリに近い挙動）に置き換えた後の
    /// ハイライト/シャドウ同時適用の検証。
    ///
    /// 旧実装（トーンカーブ近似）は中央制御点 (0.5, 0.5) 固定で「中間調不変」を保証していたが、
    /// P1 で CIHighlightShadowAdjust に置き換えたため中間調も緩やかに動くのが正しい仕様になった。
    /// 中間調固定のアサーションはそのため撤廃し、代わりに「暗部と明部の両方が同時に持ち上がる」
    /// （＝ハイライトとシャドウが同時適用されている）ことを2バンド画像で検証する。
    /// ドラッグ中（interactive）経路との見た目差の調整は P2（目視チューニング）で行う。
    func testHighlightAndShadowApplyTogether() {
        // 暗バンド（上半分）/ 明バンド（下半分）の2バンド画像
        let src = makeTwoBandSourceForHighlightShadowTest()
        let beforeDark   = sampleBand(src, y: 10) // 暗バンド
        let beforeBright = sampleBand(src, y: 50) // 明バンド

        // ハイライト +0.5、シャドウ +0.5 を同時適用
        var r = EditRecipe()
        r.highlights   = 1.0 + 0.5
        r.shadowAmount = 1.0 + 0.5
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src)
        let afterDark   = sampleBand(out, y: 10)
        let afterBright = sampleBand(out, y: 50)

        // 暗バンドの平均輝度が上がる（シャドウ持ち上げが効いている）
        XCTAssertGreaterThan(afterDark.r, beforeDark.r + 0.03 * 255,
            "シャドウ +0.5 で暗バンドが持ち上がっていない（HL/Shadow 同時適用の回帰）")

        // 明バンドの平均輝度が上がる（正のハイライトが効いている）
        XCTAssertGreaterThan(afterBright.r, beforeBright.r + 0.03 * 255,
            "ハイライト +0.5 で明バンドが持ち上がっていない（HL/Shadow 同時適用の回帰）")
    }
}
