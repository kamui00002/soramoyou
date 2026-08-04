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

    // MARK: - selectableSkyTypes(from:)

    /// 履歴ゼロなら選べる空タイプは空配列。
    func testSelectableSkyTypes_emptyWhenNoHistory() {
        XCTAssertEqual(PersonalDefaultCandidateProvider.selectableSkyTypes(from: []), [])
    }

    /// `PersonalRecipeProfile.minimumSamples`（3件）以上ある空タイプだけが選べる。
    /// サンプル数降順で返り、同数のタイブレークは `SkyType.allCases` の宣言順になる。
    func testSelectableSkyTypes_onlyThoseWithEnoughSamplesSortedByCountThenDeclarationOrder() {
        var entries: [RecipeCorpusEntry] = []
        entries.append(entry(exposure: -3.0, sky: .clear)) // 1件 → minimumSamples未満で対象外
        for _ in 0 ..< 3 {
            entries.append(entry(exposure: 1.0, sky: .storm))
        } // 3件
        for _ in 0 ..< 3 {
            entries.append(entry(exposure: 2.0, sky: .cloudy))
        } // 3件（storm と同数 → SkyType.allCases の宣言順で cloudy が storm より先）
        for _ in 0 ..< 7 {
            entries.append(entry(exposure: 3.0, sky: .sunset))
        } // 7件（最多）

        let result = PersonalDefaultCandidateProvider.selectableSkyTypes(from: entries)

        // SkyType.allCases = [clear, cloudy, sunset, sunrise, storm] の宣言順で
        // cloudy(index 1) は storm(index 4) より手前なので、同数タイブレークで cloudy が先。
        XCTAssertEqual(result, [.sunset, .cloudy, .storm], "サンプル数降順・同数は宣言順（cloudyがstormより先）")
    }

    // MARK: - candidatePool(from:skyType:) の先頭候補・件数

    /// 新規ユーザー（履歴 0 件）ではプールが固定プリセット5件のみになる
    /// （`FixedPresetKind.allCases` と同じ順）。skyType を指定していても履歴が無ければ変わらない。
    func testCandidatePool_presetsOnlyWhenNoHistory() {
        let result = PersonalDefaultCandidateProvider.candidatePool(from: [], skyType: .sunset)

        let expectedKinds: [PersonalDefaultCandidate.Kind] = FixedPresetKind.allCases.map { .preset($0) }
        XCTAssertEqual(result.map(\.kind), expectedKinds, "履歴 0 件のプールは FixedPresetKind.allCases と同じ順で全件入る")
    }

    /// skyType: nil を渡した場合は、履歴が十分（3件以上）あれば先頭候補は必ず全体の「あなたの定番」になる。
    func testCandidatePool_firstIsOverallDefaultWhenSkyTypeIsNil() {
        let entries = [
            entry(exposure: 0.5, sky: nil),
            entry(exposure: 0.6, sky: nil),
            entry(exposure: 0.7, sky: nil),
        ]
        let result = PersonalDefaultCandidateProvider.candidatePool(from: entries, skyType: nil)

        XCTAssertEqual(result.first?.kind, .overallDefault, "skyType: nil かつ履歴3件以上なら先頭は全体の定番")
        XCTAssertEqual(result.first?.label, "あなたの定番")
    }

    /// 指定した空タイプの履歴が `PersonalRecipeProfile.minimumSamples` 以上あれば、
    /// 先頭候補はその空タイプの「〇〇の定番」になる。
    func testCandidatePool_firstIsSkyTypeDefaultWhenEnoughSamples() {
        var entries: [RecipeCorpusEntry] = []
        for _ in 0 ..< 5 {
            entries.append(entry(exposure: 3.0, sky: .sunset))
        }
        for _ in 0 ..< 5 {
            entries.append(entry(exposure: 0.0, sky: .clear))
        }

        let result = PersonalDefaultCandidateProvider.candidatePool(from: entries, skyType: .sunset)

        XCTAssertEqual(result.first?.kind, .skyType(.sunset), "sunset を指定し5件（minimumSamples以上）あれば先頭は sunset の定番")
        XCTAssertEqual(result.first?.label, "\(SkyType.sunset.displayName)の定番")
    }

    /// 指定した空タイプの履歴が `PersonalRecipeProfile.minimumSamples` 未満なら、
    /// 「あなたの定番」（全体）へフォールバックする（`.skyType` ラベルにはならない）。
    func testCandidatePool_fallsBackToOverallWhenSkyTypeSamplesInsufficient() {
        // clear は 1件のみ（minimumSamples未満）。全体では clear + sunset で6件あり overall は成立する。
        var entries: [RecipeCorpusEntry] = []
        entries.append(entry(exposure: -3.0, sky: .clear))
        for _ in 0 ..< 5 {
            entries.append(entry(exposure: 3.0, sky: .sunset))
        }

        let result = PersonalDefaultCandidateProvider.candidatePool(from: entries, skyType: .clear)

        XCTAssertEqual(result.first?.kind, .overallDefault, "指定空タイプの履歴不足時は全体の定番へフォールバックする")
        XCTAssertEqual(result.first?.label, "あなたの定番")
    }

    /// プールは「先頭=定番系1件、続いて固定プリセット全件」という並びになる。
    /// 固定プリセットは打ち切られず常に全件（5件）が末尾に入ることを検証する。
    func testCandidatePool_orderIsHeadThenAllPresets() {
        var entries: [RecipeCorpusEntry] = []
        for _ in 0 ..< 7 {
            entries.append(entry(exposure: 10.0, sky: .sunset))
        } // 7件

        let result = PersonalDefaultCandidateProvider.candidatePool(from: entries, skyType: .sunset)

        let expectedKinds: [PersonalDefaultCandidate.Kind] =
            [.skyType(.sunset)] + FixedPresetKind.allCases.map { .preset($0) }
        XCTAssertEqual(
            result.map(\.kind),
            expectedKinds,
            "プールは 先頭(定番系1件)→固定プリセット全件 の順で、打ち切られず全て入る（実際\(result.count)件）"
        )
    }

    /// ⚠️ 今回の変更の要点の回帰テスト: どの呼び方でも、プールに定番系（overallDefault/skyType）が
    /// 2件以上入ることはない（先頭候補は常に最大1件）。
    func testCandidatePool_neverContainsMoreThanOneDefaultLikeCandidate() {
        var entries: [RecipeCorpusEntry] = []
        for _ in 0 ..< 5 {
            entries.append(entry(exposure: -4.0, sky: .clear))
        }
        for _ in 0 ..< 5 {
            entries.append(entry(exposure: 3.0, sky: .cloudy))
        }
        for _ in 0 ..< 5 {
            entries.append(entry(exposure: 10.0, sky: .sunset))
        }

        func countDefaultLikeCandidates(_ result: [PersonalDefaultCandidate]) -> Int {
            result.filter { candidate in
                switch candidate.kind {
                case .overallDefault, .skyType:
                    true
                case .preset:
                    false
                }
            }.count
        }

        // skyType: nil / .clear / .cloudy / .sunset いずれの呼び方でも定番系は最大1件。
        XCTAssertLessThanOrEqual(countDefaultLikeCandidates(
            PersonalDefaultCandidateProvider.candidatePool(from: entries, skyType: nil)
        ), 1)
        XCTAssertLessThanOrEqual(countDefaultLikeCandidates(
            PersonalDefaultCandidateProvider.candidatePool(from: entries, skyType: .clear)
        ), 1)
        XCTAssertLessThanOrEqual(countDefaultLikeCandidates(
            PersonalDefaultCandidateProvider.candidatePool(from: entries, skyType: .cloudy)
        ), 1)
        XCTAssertLessThanOrEqual(countDefaultLikeCandidates(
            PersonalDefaultCandidateProvider.candidatePool(from: entries, skyType: .sunset)
        ), 1)
        // 旧シグネチャ（委譲先）でも同様。
        XCTAssertLessThanOrEqual(countDefaultLikeCandidates(
            PersonalDefaultCandidateProvider.candidatePool(from: entries)
        ), 1)
    }

    // MARK: - candidatePool(from:) 旧シグネチャ（skyType: nil への委譲）

    /// 旧シグネチャ（skyType 指定なし）は `candidatePool(from:skyType: nil)` と同じ結果になる
    /// （呼び出し側の移行を壊さないための委譲オーバーロード）。
    func testCandidatePool_legacySignatureDelegatesToSkyTypeNil() {
        let entries = [
            entry(exposure: 0.5, sky: nil),
            entry(exposure: 0.6, sky: nil),
            entry(exposure: 0.7, sky: nil),
        ]

        let legacyResult = PersonalDefaultCandidateProvider.candidatePool(from: entries)
        let explicitResult = PersonalDefaultCandidateProvider.candidatePool(from: entries, skyType: nil)

        XCTAssertEqual(legacyResult, explicitResult)
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
