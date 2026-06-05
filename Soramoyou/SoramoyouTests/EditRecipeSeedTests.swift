//
//  EditRecipeSeedTests.swift
//  SoramoyouTests
//
//  レシピ共有のシード化（EditRecipe.preparedAsSharedSeed）の純関数テスト。
//  写真固有フィールド（クロップ・ダイナミックレンジ）だけが除去され、
//  作風（フィルター・norm 値・物理値・トーンカーブ）が保持されることを確認する。
//

import XCTest
@testable import Soramoyou

final class EditRecipeSeedTests: XCTestCase {

    /// 全種類のフィールドに編集を入れたレシピを生成するヘルパー
    private func makeEditedRecipe() -> EditRecipe {
        var recipe = EditRecipe()
        // 物理スケール値
        recipe.exposureEV = 1.2
        recipe.brightnessCI = 0.1
        recipe.contrastCI = 1.3
        recipe.saturationCI = 1.8
        // 正規化値
        recipe.warmthNorm = 0.5
        recipe.vignetteNorm = -0.3
        recipe.clarityNorm = 0.7
        // 2D スタイルパッド
        recipe.style2DToneNorm = 0.2
        recipe.style2DColorNorm = -0.4
        // フィルター
        recipe.appliedFilter = .vivid
        // トーンカーブ（非恒等）
        var curve = ToneCurvePoints()
        curve.point2 = CurvePoint(x: 0.5, y: 0.6)
        recipe.toneCurvePoints = curve
        // 写真固有フィールド
        recipe.cropRectNorm = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        recipe.targetDynamicRange = .hdr
        // タイムスタンプ
        recipe.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        recipe.lastModifiedAt = Date(timeIntervalSince1970: 1_700_000_100)
        return recipe
    }

    func testStripsCropRect() {
        let seed = makeEditedRecipe().preparedAsSharedSeed()
        XCTAssertNil(seed.cropRectNorm, "クロップは写真固有のため除去される")
    }

    func testStripsTargetDynamicRange() {
        let seed = makeEditedRecipe().preparedAsSharedSeed()
        XCTAssertNil(seed.targetDynamicRange, "HDR/SDR は適用先写真のデフォルトを優先するため除去される")
    }

    func testKeepsToneCurve() {
        let original = makeEditedRecipe()
        let seed = original.preparedAsSharedSeed()
        XCTAssertEqual(seed.toneCurvePoints, original.toneCurvePoints, "トーンカーブは作風の一部として保持される")
        XCTAssertEqual(seed.toneCurvePoints?.point2.y, 0.6)
    }

    func testKeepsFilterAndAdjustments() {
        let original = makeEditedRecipe()
        let seed = original.preparedAsSharedSeed()
        XCTAssertEqual(seed.appliedFilter, .vivid)
        XCTAssertEqual(seed.exposureEV, 1.2)
        XCTAssertEqual(seed.brightnessCI, 0.1)
        XCTAssertEqual(seed.contrastCI, 1.3)
        XCTAssertEqual(seed.saturationCI, 1.8)
        XCTAssertEqual(seed.warmthNorm, 0.5)
        XCTAssertEqual(seed.vignetteNorm, -0.3)
        XCTAssertEqual(seed.clarityNorm, 0.7)
        XCTAssertEqual(seed.style2DToneNorm, 0.2)
        XCTAssertEqual(seed.style2DColorNorm, -0.4)
    }

    func testSeedEqualsOriginalExceptPhotoSpecificFields() {
        // シード = 元レシピから写真固有2フィールドだけを除いたもの（他は一切変わらない）
        let original = makeEditedRecipe()
        var expected = original
        expected.cropRectNorm = nil
        expected.targetDynamicRange = nil
        XCTAssertEqual(original.preparedAsSharedSeed(), expected)
    }

    func testNeutralRecipeStaysNeutral() {
        // 中立レシピをシード化しても中立のまま（クラッシュや余計な変化が無い）
        let seed = EditRecipe().preparedAsSharedSeed()
        XCTAssertTrue(seed.isNeutral)
    }

    func testSeedWithoutPhotoSpecificFieldsIsIdentity() {
        // 写真固有フィールドが元々無いレシピでは恒等変換になる
        var recipe = EditRecipe()
        recipe.exposureEV = 0.5
        recipe.appliedFilter = .warm
        XCTAssertEqual(recipe.preparedAsSharedSeed(), recipe)
    }
}
