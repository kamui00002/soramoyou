//
//  PersonalDefaultCandidateProviderTests.swift
//  SoramoyouTests
//
//  ⭐️ パーソナルAI編集（柱1 v2）の純関数テスト:
//  「AIで自動編集」候補シートに並べる編集パターン一覧（PersonalDefaultCandidateProvider）の仕様検証。
//
//  ⚠️ アサーションは実装の実挙動ではなく、依頼元が定義した仕様（候補の種類・件数・順序・重複除外）
//  に対して書く。実装と食い違って落ちた場合はテスト側を直さず、呼び出し元に仕様との齟齬を報告する。
//

@testable import Soramoyou
import XCTest

final class PersonalDefaultCandidateProviderTests: XCTestCase {
    /// `entry()` の呼び出し順を savedAt に確定的に反映するためのカウンタ。
    /// `PersonalRecipeProfileTests` と同じパターン: representative() は savedAt の新しさで
    /// 重み付けするため、呼び出し順＝savedAt順を保証してテストを決定的にする。
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

    // MARK: - candidatePool(from:) の件数・種類

    /// 新規ユーザー（履歴 0 件）ではプールが固定プリセット5件のみになる
    /// （`FixedPresetKind.allCases` と同じ順）。
    /// ⚠️ 旧仕様（4件で打ち切り）ではなく、プール化により全5件が入ることを検証する。
    func testCandidatePool_presetsOnlyWhenNoHistory() {
        let result = PersonalDefaultCandidateProvider.candidatePool(from: [])

        let expectedKinds: [PersonalDefaultCandidate.Kind] = FixedPresetKind.allCases.map { .preset($0) }
        XCTAssertEqual(result.map(\.kind), expectedKinds, "履歴 0 件のプールは FixedPresetKind.allCases と同じ順で全件入る")
    }

    /// 履歴が十分（3件以上）あれば、先頭候補は必ず全体の「あなたの定番」になる。
    func testCandidatePool_firstIsOverallDefaultWhenAvailable() {
        let entries = [
            entry(exposure: 0.5, sky: nil),
            entry(exposure: 0.6, sky: nil),
            entry(exposure: 0.7, sky: nil),
        ]
        let result = PersonalDefaultCandidateProvider.candidatePool(from: entries)

        XCTAssertEqual(result.first?.kind, .overallDefault, "履歴3件以上なら先頭は全体の定番")
        XCTAssertEqual(result.first?.label, "あなたの定番")
    }

    /// 特定空タイプのサンプルが十分（minimumSamples 以上）あれば、その空タイプの「〇〇の定番」候補が含まれる。
    /// exposureEV を空タイプ間で明確に変え、全体平均と衝突（isSimilar で重複除外）しないようにする。
    func testCandidatePool_includesSkyTypeWhenEnoughSamples() {
        var entries: [RecipeCorpusEntry] = []
        for _ in 0 ..< 5 {
            entries.append(entry(exposure: 3.0, sky: .sunset))
        }
        for _ in 0 ..< 5 {
            entries.append(entry(exposure: 0.0, sky: .clear))
        }

        let result = PersonalDefaultCandidateProvider.candidatePool(from: entries)

        let sunsetCandidate = result.first { candidate in
            if case .skyType(.sunset) = candidate.kind { return true }
            return false
        }
        XCTAssertNotNil(sunsetCandidate, "sunset が5件（minimumSamples以上）あれば sunset の定番候補が含まれる")
        XCTAssertEqual(sunsetCandidate?.label, "\(SkyType.sunset.displayName)の定番")
    }

    /// 空タイプのサンプルが `PersonalRecipeProfile.minimumSamples` 未満なら、
    /// その空タイプはプールに一切含まれない（打ち切りではなく、そもそも条件を満たさない）。
    func testCandidatePool_excludesSkyTypeBelowMinimumSamples() {
        // clear は minimumSamples 未満（1件）なので候補に含まれないはず。
        // sunset は minimumSamples 以上（5件）なので含まれる。
        var entries: [RecipeCorpusEntry] = []
        entries.append(entry(exposure: -3.0, sky: .clear))
        for _ in 0 ..< 5 {
            entries.append(entry(exposure: 3.0, sky: .sunset))
        }

        let result = PersonalDefaultCandidateProvider.candidatePool(from: entries)

        let hasClearSkyTypeCandidate = result.contains { candidate in
            if case .skyType(.clear) = candidate.kind { return true }
            return false
        }
        XCTAssertFalse(hasClearSkyTypeCandidate, "minimumSamples未満の空タイプ(clear:1件)はプールに含まれない")

        let hasSunsetSkyTypeCandidate = result.contains { candidate in
            if case .skyType(.sunset) = candidate.kind { return true }
            return false
        }
        XCTAssertTrue(hasSunsetSkyTypeCandidate, "minimumSamples以上の空タイプ(sunset:5件)はプールに含まれる")
    }

    /// プールは「先頭=全体の定番、続いて空タイプ別（サンプル数降順）、末尾に固定プリセット全件」
    /// という並びになる。固定プリセットは打ち切られず常に全件（5件）が末尾に入ることを検証する。
    func testCandidatePool_orderIsOverallThenSkyTypeThenAllPresets() {
        // 作成順（＝savedAt昇順）で clear→cloudy→sunset。exposure は空タイプ間・全体平均との
        // どの組み合わせでも isSimilar(重複除外)に引っかからないよう大きく離す。
        var entries: [RecipeCorpusEntry] = []
        for _ in 0 ..< 3 {
            entries.append(entry(exposure: -4.0, sky: .clear))
        } // 3件
        for _ in 0 ..< 4 {
            entries.append(entry(exposure: 3.0, sky: .cloudy))
        } // 4件
        for _ in 0 ..< 7 {
            entries.append(entry(exposure: 10.0, sky: .sunset))
        } // 7件

        let result = PersonalDefaultCandidateProvider.candidatePool(from: entries)

        let skyTypeOrder: [SkyType] = result.compactMap { candidate in
            if case let .skyType(skyType) = candidate.kind { return skyType }
            return nil
        }
        XCTAssertEqual(
            skyTypeOrder,
            [.sunset, .cloudy, .clear],
            "サンプル数（sunset:7 > cloudy:4 > clear:3）の降順で並ぶ"
        )

        // 先頭 = overallDefault、続く3件 = skyType(降順)、末尾5件 = FixedPresetKind.allCases 全件。
        let expectedKinds: [PersonalDefaultCandidate.Kind] =
            [.overallDefault, .skyType(.sunset), .skyType(.cloudy), .skyType(.clear)]
                + FixedPresetKind.allCases.map { .preset($0) }
        XCTAssertEqual(
            result.map(\.kind),
            expectedKinds,
            "プールは 全体定番→空タイプ別(降順)→固定プリセット全件 の順で、打ち切られず全て入る（実際\(result.count)件）"
        )
    }

    /// 空タイプ別候補が全体の定番とほぼ同一値になる場合（全エントリが同一空タイプ・同一値）、
    /// isSimilar による重複除外で空タイプ候補は追加されない。固定プリセットは打ち切られず全件が入る。
    func testCandidatePool_dedupesNearIdenticalSkyTypeAndOverall() {
        // 全5件が同一 skyType(.clear)・同一 exposure のため、
        // representative(for: nil, ...) と representative(for: .clear, ...) は
        // 同じサンプル集合・同じ重み付けから導かれ、完全に同一のレシピになる。
        var entries: [RecipeCorpusEntry] = []
        for _ in 0 ..< 5 {
            entries.append(entry(exposure: 0.3, sky: .clear))
        }

        let result = PersonalDefaultCandidateProvider.candidatePool(from: entries)

        // 期待される内訳: 全体の定番(1) + 固定プリセット全5件(vivid/warm/cool/drama/natural)で計6件。
        // skyType(.clear) は overall と isSimilar のため追加されない
        // （プリセット群は appliedFilter が overall(nil) と異なるため isSimilar の最初のガードで
        //   確実に non-similar 判定される＝全件追加される。打ち切りが無いので5件とも入る）。
        let expectedKinds: [PersonalDefaultCandidate.Kind] =
            [.overallDefault] + FixedPresetKind.allCases.map { .preset($0) }
        XCTAssertEqual(result.map(\.kind), expectedKinds)

        let hasClearSkyTypeCandidate = result.contains { candidate in
            if case .skyType(.clear) = candidate.kind { return true }
            return false
        }
        XCTAssertFalse(hasClearSkyTypeCandidate, "overallとほぼ同一のskyType候補は重複除外される")
    }

    // MARK: - isSimilar

    func testIsSimilar_trueForNearIdenticalRecipes() {
        var a = EditRecipe()
        a.appliedFilter = .vivid
        a.exposureEV = 0.5
        a.saturationCI = 1.1
        a.contrastCI = 1.05
        a.warmthNorm = 0.2

        var b = a
        b.exposureEV = 0.55 // diff 0.05 < 0.15 の閾値
        b.saturationCI = 1.13 // diff 0.03 < 0.08 の閾値
        b.contrastCI = 1.08 // diff 0.03 < 0.08 の閾値
        b.warmthNorm = 0.25 // diff 0.05 < 0.10 の閾値

        XCTAssertTrue(
            PersonalDefaultCandidateProvider.isSimilar(a, b),
            "全項目が閾値未満の差なら見た目上ほぼ同じと判定される"
        )
    }

    func testIsSimilar_falseWhenFilterDiffers() {
        var a = EditRecipe()
        a.appliedFilter = .vivid

        var b = EditRecipe()
        b.appliedFilter = .warm
        // 数値項目は両者ともデフォルト（完全一致）だが、フィルターが異なる。

        XCTAssertFalse(
            PersonalDefaultCandidateProvider.isSimilar(a, b),
            "他の項目が一致していてもフィルターが異なれば非類似と判定される"
        )
    }

    func testIsSimilar_falseWhenStyle2DDiffers() {
        var a = EditRecipe()
        a.appliedFilter = .natural
        a.style2DToneNorm = 0.0

        var b = a
        b.style2DToneNorm = 0.5 // diff 0.5 >= 0.15 の閾値（フィルター・他項目は a と同一）

        XCTAssertFalse(
            PersonalDefaultCandidateProvider.isSimilar(a, b),
            "style2DToneNorm の差が閾値以上なら非類似と判定される"
        )
    }
}
