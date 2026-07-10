//
//  PersonalRecipeProfileTests.swift
//  SoramoyouTests
//
//  増分2（柱1 v1）の純関数テスト: 「あなたの定番」の統計導出。
//

import XCTest
@testable import Soramoyou

final class PersonalRecipeProfileTests: XCTestCase {

    /// `entry()` の呼び出し順を savedAt に確定的に反映するためのカウンタ。
    /// representative() は savedAt の新しさで重み付けするため、素の `Date()` に頼ると
    /// クロック分解能によって呼び出し順と savedAt 順が一致しない可能性がある。
    /// カウンタで単調増加な savedAt を割り当て、「後に呼んだ entry() ほど新しい」を保証する。
    private var entryCounter = 0

    /// テスト用エントリ生成。呼び出した順に savedAt が新しくなる（決定的な順序）。
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
        entryCounter += 1
        return RecipeCorpusEntry(recipe: r, skyType: sky, savedAt: Date(timeIntervalSince1970: Double(entryCounter)))
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
        // 物理スケールは新しさで重み付けした加重平均（欠陥3の修正）。
        // 呼び出し順に savedAt が新しくなるため、最後に作った exposure=2 の重みが最大になる。
        // 重み(0.8^i, i=新しい順の順位): exposure2→1.0, exposure1→0.8, exposure0→0.64
        // (1.0*2 + 0.8*1 + 0.64*0) / (1.0+0.8+0.64) ≈ 1.1475
        // 旧仕様（等重み平均）では 1.0 だったが、新仕様では直近の編集が強く反映される。
        XCTAssertEqual(result.exposureEV, 1.147540983606557, accuracy: 0.0001, "物理スケールは新しさで重み付けした加重平均になる")
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
        // 設定されていた 2 件（重み付き使用率 59% > 50%）のみの加重平均を採用（欠陥2の修正）。
        // 重み: warmth=0.4→0.64（最古）, warmth=0.6→0.8, nil→1.0（最新）
        // (0.64*0.4 + 0.8*0.6) / (0.64+0.8) ≈ 0.5111（旧仕様の等重み平均では 0.5 だった）
        XCTAssertEqual(try XCTUnwrap(result.warmthNorm), 0.5111111111111111, accuracy: 0.0001)
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
        // sunset が最小数未満 → 全体へフォールバックし、新しさで重み付けした加重平均を採る。
        // sunset(exposure=3)は最初に作られた最古のエントリ（重み 0.8^4=0.4096）、
        // 残り4件の clear(exposure=0)がより新しい（重み合計 1+0.8+0.64+0.512=2.952）。
        // (0.4096*3 + 0) / (0.4096+2.952) ≈ 0.3655（旧仕様の等重み平均では 0.6 だった）
        XCTAssertEqual(result.exposureEV, 0.36554021894336025, accuracy: 0.0001)
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

    // MARK: - dominantFilter の同率タイブレーク（PR #60 /review-full T1 対応）
    //
    // dominantFilter は「重み付き合計が完全に同率のとき、より新しいエントリを含む方を優先する」
    // というタイブレークを持つ。この分岐（totals の value が完全一致するケース）を実際に踏ませる
    // 入力を構成できるか検討した:
    //
    // 数学的な結論: recencyDecay = 0.8 = 4/5（既約分数）である限り、互いに素な添字集合
    // （投稿の並び順で決まる 0,1,2,... の重複しない部分集合）が持つ重み 0.8^i の総和が
    // 完全に一致することはあり得ない。
    // 証明: 互いに素な非空の添字集合 A, B（A ≠ B）が Σ_{i∈A} 0.8^i = Σ_{i∈B} 0.8^i を満たすと仮定し、
    // M = max(A ∪ B) とする（M は A, B のどちらか一方だけに属する）。両辺を 5^M 倍すると
    // Σ_{i∈A} 4^i 5^{M-i} = Σ_{i∈B} 4^i 5^{M-i} という整数の等式になる。添字 i < M の項は
    // すべて 5^{M-i}（M-i ≥ 1）を因数に持つため 5 の倍数だが、添字 M の項（4^M）は
    // gcd(4,5)=1 より 5 の倍数ではない。よって mod 5 で左右辺のいずれか一方だけが
    // 4^M ≡ {1,4}（≠0）を持ち他方は 0 となり矛盾。ゆえに完全一致は不可能。
    // （念のため、部分和が最大 2^22（約419万）通りとなる範囲を Double 演算で総当たりし、
    // 浮動小数の丸めによる偶発的な bit 一致も皆無であることを別途確認済み。）
    //
    // そのため「Σ完全一致」でタイブレーク分岐を直接踏ませるテストは構成不可能と判断し、
    // savedAt が完全同一という境界ケース（安定ソートで元の配列順が結果を左右する）で
    // representative() の結果が呼び出しのたびに変わらない（決定的である）ことの検証に留める。
    func test_dominantFilter_tieBySavedAt_isDeterministic() throws {
        let tiedSavedAt = Date(timeIntervalSince1970: 1_700_000_000)

        func makeEntries() -> [RecipeCorpusEntry] {
            var vividRecipe = EditRecipe()
            vividRecipe.appliedFilter = .vivid
            var dramaRecipe = EditRecipe()
            dramaRecipe.appliedFilter = .drama
            var fillerRecipe = EditRecipe()
            fillerRecipe.appliedFilter = .natural
            return [
                // savedAt が完全同一の2件（同率境界ケース）。安定ソートで配列順が保たれる。
                RecipeCorpusEntry(recipe: vividRecipe, skyType: nil, savedAt: tiedSavedAt),
                RecipeCorpusEntry(recipe: dramaRecipe, skyType: nil, savedAt: tiedSavedAt),
                // minimumSamples を満たすための埋め合わせ（より古い＝重みが最小）
                RecipeCorpusEntry(recipe: fillerRecipe, skyType: nil, savedAt: tiedSavedAt.addingTimeInterval(-3600))
            ]
        }

        let first = try XCTUnwrap(
            PersonalRecipeProfile.representative(for: nil, from: makeEntries(), minimumSamples: 3)
        ).appliedFilter

        for _ in 0..<20 {
            let result = try XCTUnwrap(
                PersonalRecipeProfile.representative(for: nil, from: makeEntries(), minimumSamples: 3)
            )
            XCTAssertEqual(
                result.appliedFilter,
                first,
                "savedAt が完全同一という境界ケースでも、呼び出しのたびに結果が変わってはならない（決定性）"
            )
        }
    }
}
