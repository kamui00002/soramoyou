//
//  EditToolsPhotosParityTests.swift
//  SoramoyouTests
//
//  ⭐️ P1: 編集ツールを iPhone 標準「写真」アプリに近づける改善のテスト
//
//  ハイライト・シャドウ・ブリリアンスの「確定後・書き出し用」局所適応版 (.final) と
//  従来の軽量トーンカーブ近似版 (.interactive) の振る舞いを検証する。
//  画像生成・サンプリングヘルパーは CIImageTestHelpers.swift（FilterGraphBuilderTests と共有）を使用する。
//

import XCTest
import CoreImage
import UIKit
@testable import Soramoyou

final class EditToolsPhotosParityTests: XCTestCase {

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

    /// `CIImageTestHelpers.makeTwoBandCIImage()` の暗バンド（darkGray 側）をサンプリングする CIImage 上の Y 座標
    private let darkBandY = 50
    /// `CIImageTestHelpers.makeTwoBandCIImage()` の明バンド（brightGray 側）をサンプリングする CIImage 上の Y 座標
    private let brightBandY = 10

    /// 指定座標の RGBA 平均を取得（中央付近 4x4 を平均）
    private func sampleCenterRGB(_ image: CIImage) -> (r: Double, g: Double, b: Double) {
        CIImageTestHelpers.sampleRegionRGB(image, x: 30, y: 30)
    }

    // MARK: - 1. シャドウ持ち上げ（.final・局所適応版）

    func test_final_shadowLift_brightensDarkBand() {
        let src = CIImageTestHelpers.makeTwoBandCIImage()
        let beforeDark   = CIImageTestHelpers.sampleRegionRGB(src, x: 30, y: darkBandY)
        let beforeBright = CIImageTestHelpers.sampleRegionRGB(src, x: 30, y: brightBandY)

        var r = EditRecipe()
        r.shadowAmount = 1.6 // v = +0.6
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .final)
        let afterDark   = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: darkBandY)
        let afterBright = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: brightBandY)

        XCTAssertGreaterThan(afterDark.r, beforeDark.r,
            "シャドウ+0.6 (.final) で暗バンドの輝度が上がらない")
        XCTAssertEqual(afterBright.r, beforeBright.r, accuracy: 0.06 * 255,
            "シャドウ+0.6 (.final) で明バンドが許容(±0.06)以上に変化した")
    }

    // MARK: - 2. シャドウを下げる（.final・局所適応版）

    /// 負のshadowAmountが暗部を締めることの回帰ガード（実測で有効性確認済み）。
    func test_final_shadowNegative_darkensDarkBand() {
        let src = CIImageTestHelpers.makeTwoBandCIImage()
        let beforeDark = CIImageTestHelpers.sampleRegionRGB(src, x: 30, y: darkBandY)

        var r = EditRecipe()
        r.shadowAmount = 0.4 // v = -0.6
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .final)
        let afterDark = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: darkBandY)

        XCTAssertLessThan(afterDark.r, beforeDark.r,
            "シャドウ-0.6 (.final) で暗バンドが暗くならない（実測: before=\(beforeDark.r) after=\(afterDark.r)）")
    }

    // MARK: - 3. ハイライト回復（明部を下げる, .final）

    func test_final_highlightRecovery_darkensBrightBand() {
        let src = CIImageTestHelpers.makeTwoBandCIImage()
        let beforeDark   = CIImageTestHelpers.sampleRegionRGB(src, x: 30, y: darkBandY)
        let beforeBright = CIImageTestHelpers.sampleRegionRGB(src, x: 30, y: brightBandY)

        var r = EditRecipe()
        r.highlights = 0.4 // v = -0.6
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .final)
        let afterDark   = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: darkBandY)
        let afterBright = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: brightBandY)

        XCTAssertLessThan(afterBright.r, beforeBright.r,
            "ハイライト-0.6 (.final) で明バンドが暗くならない")
        XCTAssertEqual(afterDark.r, beforeDark.r, accuracy: 0.06 * 255,
            "ハイライト-0.6 (.final) で暗バンドが許容(±0.06)以上に変化した")
    }

    // MARK: - 4. ハイライトを上げる（トーンカーブ側の経路, .final）

    func test_final_highlightPositive_brightensBrightBand() {
        let src = CIImageTestHelpers.makeTwoBandCIImage()
        let beforeBright = CIImageTestHelpers.sampleRegionRGB(src, x: 30, y: brightBandY)

        var r = EditRecipe()
        r.highlights = 1.6 // v = +0.6
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .final)
        let afterBright = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: brightBandY)

        XCTAssertGreaterThan(afterBright.r, beforeBright.r,
            "ハイライト+0.6 (.final) で明バンドが明るくならない（トーンカーブ側経路の回帰）")
    }

    // MARK: - 5. .interactive 経路が引き続き機能すること

    func test_interactive_pathStillWorks() {
        let src = CIImageTestHelpers.makeTwoBandCIImage()
        let beforeDark = CIImageTestHelpers.sampleRegionRGB(src, x: 30, y: darkBandY)

        var r = EditRecipe()
        r.shadowAmount = 1.6 // v = +0.6
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .interactive)
        let afterDark = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: darkBandY)

        XCTAssertGreaterThan(afterDark.r, beforeDark.r,
            ".interactive 経路でシャドウ+0.6 の暗バンド上昇方向が壊れている")
    }

    // MARK: - 5.1. interactive 経路の数値固定テスト（R1: 回帰スナップショット）

    /// interactive経路（トーンカーブ近似）の回帰防止。この期待値は現実装の実測スナップショット。
    ///
    /// 対応2 (G1/R2) でガード閾値を統一したことにより、interactive/final 双方の
    /// 有効判定は揃ったが、interactive 経路自体の数値（トーンカーブ近似の出力値）は
    /// 本 PR 以前の quality 未指定テストでしか間接的に検証されていなかった。
    /// quality 未指定 = .final のデフォルトへ変わったため、interactive 経路の
    /// 数値検証が空白化していた穴を埋める。
    func test_interactive_highlightShadow_matchesLegacyValues() {
        let src = CIImageTestHelpers.makeTwoBandCIImage()

        var r = EditRecipe()
        r.highlights   = 1.5 // v = +0.5
        r.shadowAmount = 1.5 // v = +0.5
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .interactive)
        let dark   = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: darkBandY)
        let bright = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: brightBandY)

        XCTAssertEqual(dark.r, 76.0, accuracy: 0.02 * 255,
            "interactive経路（ハイライト/シャドウ）の暗バンド出力値が変化（回帰の可能性）")
        XCTAssertEqual(bright.r, 247.0, accuracy: 0.02 * 255,
            "interactive経路（ハイライト/シャドウ）の明バンド出力値が変化（回帰の可能性）")
    }

    /// interactive経路（トーンカーブ近似）の回帰防止。この期待値は現実装の実測スナップショット。
    func test_interactive_brilliance_matchesLegacyValues() {
        let src = CIImageTestHelpers.makeTwoBandCIImage()

        var r = EditRecipe()
        r.brillianceNorm = 0.5
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .interactive)
        let dark   = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: darkBandY)
        let bright = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: brightBandY)

        XCTAssertEqual(dark.r, 11.0, accuracy: 0.02 * 255,
            "interactive経路（ブリリアンス）の暗バンド出力値が変化（回帰の可能性）")
        XCTAssertEqual(bright.r, 217.0, accuracy: 0.02 * 255,
            "interactive経路（ブリリアンス）の明バンド出力値が変化（回帰の可能性）")
    }

    // MARK: - 6. ブリリアンス（局所適応版, .final）

    func test_brillianceFinal_liftsShadowsWithoutBlowingHighlights() {
        let src = CIImageTestHelpers.makeTwoBandCIImage()
        let beforeDark   = CIImageTestHelpers.sampleRegionRGB(src, x: 30, y: darkBandY)
        let beforeBright = CIImageTestHelpers.sampleRegionRGB(src, x: 30, y: brightBandY)

        var r = EditRecipe()
        r.brillianceNorm = 0.7
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .final)
        let afterDark   = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: darkBandY)
        let afterBright = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: brightBandY)

        let darkDelta   = afterDark.r - beforeDark.r
        let brightDelta = afterBright.r - beforeBright.r

        XCTAssertGreaterThan(darkDelta, 0,
            "ブリリアンス+0.7 (.final) で暗バンドが上がらない")
        XCTAssertLessThan(brightDelta, darkDelta,
            "ブリリアンス+0.7 (.final) で明バンドの上昇幅が暗バンドの上昇幅以上になっている")
    }

    // MARK: - 6.1. ブリリアンス（負方向・.final、G3）

    /// ブリリアンス負方向の回帰ガード。負の v は shadowAmount のみ負に効き、
    /// highlightAmount は中立（1.0）のまま据え置かれる設計（`applyBrillianceLocal` 参照）。
    func test_brillianceFinal_negative_darkensShadows() {
        let src = CIImageTestHelpers.makeTwoBandCIImage()
        let beforeDark   = CIImageTestHelpers.sampleRegionRGB(src, x: 30, y: darkBandY)
        let beforeBright = CIImageTestHelpers.sampleRegionRGB(src, x: 30, y: brightBandY)

        var r = EditRecipe()
        r.brillianceNorm = -0.7
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .final)
        let afterDark   = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: darkBandY)
        let afterBright = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: brightBandY)

        XCTAssertLessThan(afterDark.r, beforeDark.r,
            "ブリリアンス-0.7 (.final) で暗バンドが下がらない")
        XCTAssertEqual(afterBright.r, beforeBright.r, accuracy: 0.02 * 255,
            "ブリリアンス-0.7 (.final) で明バンドが変化した（負方向は highlightAmount 中立のはず）")
    }

    /// ブリリアンス + ハイライト/シャドウの同時適用の回帰ガード（G3）。
    /// `CIHighlightShadowAdjust` が applyBrillianceLocal → applyHighlightShadowLocal の
    /// 2連スタックで呼ばれてもクラッシュせず、方向性（暗部上昇・明部下降）が維持されることを確認する。
    func test_brillianceWithHighlightShadow_stacksSafely() {
        let src = CIImageTestHelpers.makeTwoBandCIImage()
        let beforeDark   = CIImageTestHelpers.sampleRegionRGB(src, x: 30, y: darkBandY)
        let beforeBright = CIImageTestHelpers.sampleRegionRGB(src, x: 30, y: brightBandY)

        var r = EditRecipe()
        r.brillianceNorm = 0.5
        r.highlights      = 0.6 // v = -0.4
        r.shadowAmount     = 1.4 // v = +0.4
        let out = FilterGraphBuilder.buildGraph(recipe: r, source: src, quality: .final)
        let afterDark   = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: darkBandY)
        let afterBright = CIImageTestHelpers.sampleRegionRGB(out, x: 30, y: brightBandY)

        XCTAssertGreaterThan(afterDark.r, beforeDark.r,
            "ブリリアンス+HS同時適用で暗バンドが上昇しない（CIHighlightShadowAdjust 2連スタックの回帰）")
        XCTAssertLessThan(afterBright.r, beforeBright.r,
            "ブリリアンス+HS同時適用で明バンドが下降しない（CIHighlightShadowAdjust 2連スタックの回帰）")
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
