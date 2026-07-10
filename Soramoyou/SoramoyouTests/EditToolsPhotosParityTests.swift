//
//  EditToolsPhotosParityTests.swift
//  SoramoyouTests
//
//  ⭐️ P1: 編集ツールを iPhone 標準「写真」アプリに近づける改善のテスト
//
//  ハイライト・シャドウ・ブリリアンスの「確定後・書き出し用」局所適応版 (.final) と
//  従来の軽量トーンカーブ近似版 (.interactive) の振る舞いを検証する。
//  ヘルパーは FilterGraphBuilderTests と同型のものをこのファイル内に個別実装する
//  （既存テストファイルは変更しない）。
//

import XCTest
import CoreImage
import UIKit
@testable import Soramoyou

final class EditToolsPhotosParityTests: XCTestCase {

    // MARK: - Helpers（FilterGraphBuilderTests と同型）

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

    /// 上半分=暗いグレー(0.15 ≒ 38)・下半分=明るいグレー(0.85 ≒ 217) の2バンド画像を
    /// 生成する（64x64）。
    ///
    /// ハイライト/シャドウ・ブリリアンスの局所適応版 (.final) は暗部・明部で別方向の
    /// 処理を行うため、単色画像ではなく明暗差のある画像でないと方向性を検証できない
    /// （`CIHighlightShadowAdjust` は局所解析を行う適応フィルタのため）。
    private func makeTwoBandSource(darkGray: UInt8 = 38, brightGray: UInt8 = 217) -> CIImage {
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

    /// `makeTwoBandSource()` の暗バンド（darkGray 側）をサンプリングする CIImage 上の Y 座標
    private let darkBandY = 50
    /// `makeTwoBandSource()` の明バンド（brightGray 側）をサンプリングする CIImage 上の Y 座標
    private let brightBandY = 10

    /// 指定座標の RGBA 平均を取得（中央付近 4x4 を平均）
    private func sampleCenterRGB(_ image: CIImage) -> (r: Double, g: Double, b: Double) {
        sampleRegion(image, x: 30, y: 30)
    }

    /// 指定 x, y 起点の 4x4 領域の RGBA 平均を取得
    private func sampleRegion(_ image: CIImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        let context = CIContext()
        let region = CGRect(x: x, y: y, width: 4, height: 4)
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

    // MARK: - 1. シャドウ持ち上げ（.final・局所適応版）

    func test_final_shadowLift_brightensDarkBand() {
        let src = makeTwoBandSource()
        let beforeDark   = sampleRegion(src, x: 30, y: darkBandY)
        let beforeBright = sampleRegion(src, x: 30, y: brightBandY)

        var r = EditRecipe()
        r.shadowAmount = 1.6 // v = +0.6
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .final)
        let afterDark   = sampleRegion(out, x: 30, y: darkBandY)
        let afterBright = sampleRegion(out, x: 30, y: brightBandY)

        XCTAssertGreaterThan(afterDark.r, beforeDark.r,
            "シャドウ+0.6 (.final) で暗バンドの輝度が上がらない")
        XCTAssertEqual(afterBright.r, beforeBright.r, accuracy: 0.06 * 255,
            "シャドウ+0.6 (.final) で明バンドが許容(±0.06)以上に変化した")
    }

    // MARK: - 2. シャドウを下げる（.final・局所適応版）

    /// CIHighlightShadowAdjust が負の shadowAmount を無視する可能性を実測確認するテスト。
    /// もし変化しない場合は実装を変更せず、実測値を報告として残す。
    func test_final_shadowNegative_darkensDarkBand() {
        let src = makeTwoBandSource()
        let beforeDark = sampleRegion(src, x: 30, y: darkBandY)

        var r = EditRecipe()
        r.shadowAmount = 0.4 // v = -0.6
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .final)
        let afterDark = sampleRegion(out, x: 30, y: darkBandY)

        XCTAssertLessThan(afterDark.r, beforeDark.r,
            "シャドウ-0.6 (.final) で暗バンドが暗くならない（実測: before=\(beforeDark.r) after=\(afterDark.r)）")
    }

    // MARK: - 3. ハイライト回復（明部を下げる, .final）

    func test_final_highlightRecovery_darkensBrightBand() {
        let src = makeTwoBandSource()
        let beforeDark   = sampleRegion(src, x: 30, y: darkBandY)
        let beforeBright = sampleRegion(src, x: 30, y: brightBandY)

        var r = EditRecipe()
        r.highlights = 0.4 // v = -0.6
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .final)
        let afterDark   = sampleRegion(out, x: 30, y: darkBandY)
        let afterBright = sampleRegion(out, x: 30, y: brightBandY)

        XCTAssertLessThan(afterBright.r, beforeBright.r,
            "ハイライト-0.6 (.final) で明バンドが暗くならない")
        XCTAssertEqual(afterDark.r, beforeDark.r, accuracy: 0.06 * 255,
            "ハイライト-0.6 (.final) で暗バンドが許容(±0.06)以上に変化した")
    }

    // MARK: - 4. ハイライトを上げる（トーンカーブ側の経路, .final）

    func test_final_highlightPositive_brightensBrightBand() {
        let src = makeTwoBandSource()
        let beforeBright = sampleRegion(src, x: 30, y: brightBandY)

        var r = EditRecipe()
        r.highlights = 1.6 // v = +0.6
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .final)
        let afterBright = sampleRegion(out, x: 30, y: brightBandY)

        XCTAssertGreaterThan(afterBright.r, beforeBright.r,
            "ハイライト+0.6 (.final) で明バンドが明るくならない（トーンカーブ側経路の回帰）")
    }

    // MARK: - 5. .interactive 経路が引き続き機能すること

    func test_interactive_pathStillWorks() {
        let src = makeTwoBandSource()
        let beforeDark = sampleRegion(src, x: 30, y: darkBandY)

        var r = EditRecipe()
        r.shadowAmount = 1.6 // v = +0.6
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .interactive)
        let afterDark = sampleRegion(out, x: 30, y: darkBandY)

        XCTAssertGreaterThan(afterDark.r, beforeDark.r,
            ".interactive 経路でシャドウ+0.6 の暗バンド上昇方向が壊れている")
    }

    // MARK: - 6. ブリリアンス（局所適応版, .final）

    func test_brillianceFinal_liftsShadowsWithoutBlowingHighlights() {
        let src = makeTwoBandSource()
        let beforeDark   = sampleRegion(src, x: 30, y: darkBandY)
        let beforeBright = sampleRegion(src, x: 30, y: brightBandY)

        var r = EditRecipe()
        r.brillianceNorm = 0.7
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .final)
        let afterDark   = sampleRegion(out, x: 30, y: darkBandY)
        let afterBright = sampleRegion(out, x: 30, y: brightBandY)

        let darkDelta   = afterDark.r - beforeDark.r
        let brightDelta = afterBright.r - beforeBright.r

        XCTAssertGreaterThan(darkDelta, 0,
            "ブリリアンス+0.7 (.final) で暗バンドが上がらない")
        XCTAssertLessThan(brightDelta, darkDelta,
            "ブリリアンス+0.7 (.final) で明バンドの上昇幅が暗バンドの上昇幅以上になっている")
    }

    // MARK: - 7. 中立レシピはパススルー

    func test_neutralRecipe_isPassthrough() {
        let src = makeGraySource(gray: 128)
        let before = sampleCenterRGB(src)

        let r = EditRecipe()
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .final)
        let after = sampleCenterRGB(out)

        XCTAssertEqual(after.r, before.r, accuracy: 0.01 * 255,
            "中立レシピの .final 出力が入力とほぼ一致しない（R）")
        XCTAssertEqual(after.g, before.g, accuracy: 0.01 * 255,
            "中立レシピの .final 出力が入力とほぼ一致しない（G）")
        XCTAssertEqual(after.b, before.b, accuracy: 0.01 * 255,
            "中立レシピの .final 出力が入力とほぼ一致しない（B）")
    }
}
