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

    // MARK: - candidates(from:) の件数・種類

    /// 新規ユーザー（履歴 0 件）でも固定プリセットだけで候補を出す確定仕様の直接検証。
    func testCandidates_presetsOnlyWhenNoHistory() {
        let result = PersonalDefaultCandidateProvider.candidates(from: [])

        XCTAssertEqual(result.count, 4, "履歴が無くても minCandidateCount(4) 件は固定プリセットで埋まる")
        for candidate in result {
            guard case .preset = candidate.kind else {
                XCTFail("履歴 0 件のときは全候補が .preset のはず: \(candidate.kind)")
                continue
            }
        }
    }

    /// 空タイプの偏り・均等分散のどちらでも、候補件数は常に 4〜5 件に収まる
    /// （下限=固定プリセットによる補充、上限=maxCandidateCount による打ち切り、という設計の直接検証）。
    func testCandidates_countIsAlwaysFourOrFive() {
        // データセット1: 空タイプが偏ったデータセット（sunset が支配的、clear/storm は1件ずつの外れ値）。
        // sunset(8件) は minimumSamples(3) を満たすが clear/storm(各1件)は満たさないので、
        // 空タイプ候補は sunset のみ成立し得る想定。
        var skewedEntries: [RecipeCorpusEntry] = []
        for _ in 0 ..< 8 {
            skewedEntries.append(entry(exposure: 2.0, sky: .sunset))
        }
        skewedEntries.append(entry(exposure: -3.0, sky: .clear))
        skewedEntries.append(entry(exposure: -3.0, sky: .storm))

        let skewedResult = PersonalDefaultCandidateProvider.candidates(from: skewedEntries)
        XCTAssertTrue(
            (4 ... 5).contains(skewedResult.count),
            "偏ったデータセットでも件数は4〜5件に収まる（実際: \(skewedResult.count)）"
        )

        // データセット2: 空タイプが均等分散したデータセット（clear/cloudy/sunset/sunrise 各3件）。
        // 全タイプが minimumSamples(3) を満たすため、空タイプ候補が複数成立し得る想定。
        entryCounter = 0 // カウンタをリセットしてこのデータセット内で savedAt 順を作り直す
        var evenEntries: [RecipeCorpusEntry] = []
        for _ in 0 ..< 3 {
            evenEntries.append(entry(exposure: 0.0, sky: .clear))
        }
        for _ in 0 ..< 3 {
            evenEntries.append(entry(exposure: 1.5, sky: .cloudy))
        }
        for _ in 0 ..< 3 {
            evenEntries.append(entry(exposure: -1.5, sky: .sunset))
        }
        for _ in 0 ..< 3 {
            evenEntries.append(entry(exposure: 3.0, sky: .sunrise))
        }

        let evenResult = PersonalDefaultCandidateProvider.candidates(from: evenEntries)
        XCTAssertTrue(
            (4 ... 5).contains(evenResult.count),
            "均等分散データセットでも件数は4〜5件に収まる（実際: \(evenResult.count)）"
        )
    }

    /// 履歴が十分（3件以上）あれば、先頭候補は必ず全体の「あなたの定番」になる。
    func testCandidates_firstIsOverallDefaultWhenAvailable() {
        let entries = [
            entry(exposure: 0.5, sky: nil),
            entry(exposure: 0.6, sky: nil),
            entry(exposure: 0.7, sky: nil),
        ]
        let result = PersonalDefaultCandidateProvider.candidates(from: entries)

        XCTAssertEqual(result.first?.kind, .overallDefault, "履歴3件以上なら先頭は全体の定番")
        XCTAssertEqual(result.first?.label, "あなたの定番")
    }

    /// 特定空タイプのサンプルが十分（minimumSamples 以上）あれば、その空タイプの「〇〇の定番」候補が含まれる。
    /// exposureEV を空タイプ間で明確に変え、全体平均と衝突（isSimilar で重複除外）しないようにする。
    func testCandidates_includesSkyTypeWhenEnoughSamples() {
        var entries: [RecipeCorpusEntry] = []
        for _ in 0 ..< 5 {
            entries.append(entry(exposure: 3.0, sky: .sunset))
        }
        for _ in 0 ..< 5 {
            entries.append(entry(exposure: 0.0, sky: .clear))
        }

        let result = PersonalDefaultCandidateProvider.candidates(from: entries)

        let sunsetCandidate = result.first { candidate in
            if case .skyType(.sunset) = candidate.kind { return true }
            return false
        }
        XCTAssertNotNil(sunsetCandidate, "sunset が5件（minimumSamples以上）あれば sunset の定番候補が含まれる")
        XCTAssertEqual(sunsetCandidate?.label, "\(SkyType.sunset.displayName)の定番")
    }

    /// 空タイプ別候補が全体の定番とほぼ同一値になる場合（全エントリが同一空タイプ・同一値）、
    /// isSimilar による重複除外で空タイプ候補は追加されず、固定プリセットで4件まで埋まる。
    func testCandidates_dedupesNearIdenticalSkyTypeAndOverall() {
        // 全5件が同一 skyType(.clear)・同一 exposure のため、
        // representative(for: nil, ...) と representative(for: .clear, ...) は
        // 同じサンプル集合・同じ重み付けから導かれ、完全に同一のレシピになる。
        var entries: [RecipeCorpusEntry] = []
        for _ in 0 ..< 5 {
            entries.append(entry(exposure: 0.3, sky: .clear))
        }

        let result = PersonalDefaultCandidateProvider.candidates(from: entries)

        // 期待される内訳: 全体の定番(1) + 固定プリセット上位3件(vivid/warm/cool)で計4件。
        // skyType(.clear) は overall と isSimilar のため追加されない
        // （全候補のフィルターが nil のところに vivid/warm/cool は appliedFilter が異なるため
        //   isSimilar の最初のガードで確実に non-similar 判定される＝追加される）。
        let expectedKinds: [PersonalDefaultCandidate.Kind] = [
            .overallDefault,
            .preset(.vivid),
            .preset(.warm),
            .preset(.cool),
        ]
        XCTAssertEqual(result.map(\.kind), expectedKinds)

        let hasClearSkyTypeCandidate = result.contains { candidate in
            if case .skyType(.clear) = candidate.kind { return true }
            return false
        }
        XCTAssertFalse(hasClearSkyTypeCandidate, "overallとほぼ同一のskyType候補は重複除外される")
    }

    /// サンプル数が異なる複数の空タイプが候補になるとき、サンプル数の多い順に並ぶ。
    func testCandidates_sortsSkyTypeBySampleCountDescending() {
        // 作成順（＝savedAt昇順）で clear→cloudy→sunset。exposure は空タイプ間で大きく離し、
        // 全体平均・空タイプ間のどの組み合わせでも isSimilar(重複除外)に引っかからないようにする。
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

        let result = PersonalDefaultCandidateProvider.candidates(from: entries)

        let skyTypeOrder: [SkyType] = result.compactMap { candidate in
            if case let .skyType(skyType) = candidate.kind { return skyType }
            return nil
        }
        XCTAssertEqual(
            skyTypeOrder,
            [.sunset, .cloudy, .clear],
            "サンプル数（sunset:7 > cloudy:4 > clear:3）の降順で並ぶ"
        )
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
