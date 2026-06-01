//
//  PersonalRecipeProfileTests.swift
//  SoramoyouTests
//
//  増分2（柱1 v1）の純関数テスト: 「あなたの定番」の統計導出。
//

import XCTest
@testable import Soramoyou

final class PersonalRecipeProfileTests: XCTestCase {

    /// テスト用エントリ生成
    private func entry(
        exposure: Double = 0,
        sky: SkyType?,
        warmth: Double? = nil,
        filter: FilterType? = nil
    ) -> RecipeCorpusEntry {
        var r = EditRecipe()
        r.exposureEV = exposure
        r.warmthNorm = warmth
        r.appliedFilter = filter
        return RecipeCorpusEntry(recipe: r, skyType: sky)
    }

    func testReturnsNilBelowMinimumSamples() {
        let entries = [entry(sky: .clear), entry(sky: .clear)] // 2 件
        let result = PersonalRecipeProfile.representative(for: nil, from: entries, minimumSamples: 3)
        XCTAssertNil(result, "サンプルが最小数未満なら定番は作らない")
    }

    func testAveragesPhysicalFields() throws {
        let entries = [
            entry(exposure: 0, sky: .clear),
            entry(exposure: 1, sky: .clear),
            entry(exposure: 2, sky: .clear)
        ]
        let result = try XCTUnwrap(
            PersonalRecipeProfile.representative(for: nil, from: entries, minimumSamples: 3)
        )
        XCTAssertEqual(result.exposureEV, 1.0, accuracy: 0.0001, "物理スケールは平均される")
    }

    func testAveragesOptionalOnlyWhenPresent() throws {
        let entries = [
            entry(sky: .clear, warmth: 0.4),
            entry(sky: .clear, warmth: 0.6),
            entry(sky: .clear, warmth: nil)   // warmth 未設定
        ]
        let result = try XCTUnwrap(
            PersonalRecipeProfile.representative(for: nil, from: entries, minimumSamples: 3)
        )
        // 設定されていた 2 件のみの平均
        XCTAssertEqual(try XCTUnwrap(result.warmthNorm), 0.5, accuracy: 0.0001)
        // 誰も設定していない項目は nil のまま
        XCTAssertNil(result.tintNorm, "未設定の正規化項目は nil のまま")
    }

    func testSkyTypeMatchPreferredWhenEnough() throws {
        var entries: [RecipeCorpusEntry] = []
        for _ in 0..<5 { entries.append(entry(exposure: 2, sky: .sunset)) }
        for _ in 0..<5 { entries.append(entry(exposure: 0, sky: .clear)) }

        let result = try XCTUnwrap(
            PersonalRecipeProfile.representative(for: .sunset, from: entries, minimumSamples: 3)
        )
        // sunset 一致サンプルのみで平均 → 2.0
        XCTAssertEqual(result.exposureEV, 2.0, accuracy: 0.0001)
    }

    func testFallbackToAllWhenSkyTypeSamplesFew() throws {
        var entries: [RecipeCorpusEntry] = [entry(exposure: 3, sky: .sunset)] // sunset 1 件のみ
        for _ in 0..<4 { entries.append(entry(exposure: 0, sky: .clear)) }

        let result = try XCTUnwrap(
            PersonalRecipeProfile.representative(for: .sunset, from: entries, minimumSamples: 3)
        )
        // sunset が最小数未満 → 全体へフォールバック → (3+0+0+0+0)/5 = 0.6
        XCTAssertEqual(result.exposureEV, 0.6, accuracy: 0.0001)
    }

    func testMostCommonFilter() throws {
        let entries = [
            entry(sky: .clear, filter: .vivid),
            entry(sky: .clear, filter: .vivid),
            entry(sky: .clear, filter: .drama)
        ]
        let result = try XCTUnwrap(
            PersonalRecipeProfile.representative(for: nil, from: entries, minimumSamples: 3)
        )
        XCTAssertEqual(result.appliedFilter, .vivid, "最頻フィルタが選ばれる")
    }
}
