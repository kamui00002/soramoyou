//
//  SkyCollectionTests.swift
//  SoramoyouTests
//
//  増分3a（空コレクション図鑑の中核）の純関数テスト:
//  Season / JapanPrefecture / SkyCollectionAggregator / SkyBadge。
//

import XCTest
@testable import Soramoyou

final class SkyCollectionTests: XCTestCase {

    // MARK: - Helpers

    private func date(year: Int, month: Int, day: Int = 15) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Season

    func testSeasonFromMonth() {
        XCTAssertEqual(Season.from(date: date(year: 2026, month: 4)), .spring)
        XCTAssertEqual(Season.from(date: date(year: 2026, month: 7)), .summer)
        XCTAssertEqual(Season.from(date: date(year: 2026, month: 10)), .autumn)
        XCTAssertEqual(Season.from(date: date(year: 2026, month: 1)), .winter)
        XCTAssertEqual(Season.from(date: date(year: 2026, month: 12)), .winter)
    }

    // MARK: - JapanPrefecture

    func testPrefectureCountIs47() {
        XCTAssertEqual(JapanPrefecture.allNames.count, 47)
        XCTAssertEqual(Set(JapanPrefecture.allNames).count, 47, "重複なし")
    }

    func testPrefectureFromExactMatchOnly() {
        XCTAssertEqual(JapanPrefecture.from(name: "東京都")?.name, "東京都")
        XCTAssertEqual(JapanPrefecture.from(name: "北海道")?.name, "北海道")
        XCTAssertNil(JapanPrefecture.from(name: "東京"), "部分一致は採用しない")
        XCTAssertNil(JapanPrefecture.from(name: "Tokyo"), "英語名は非該当")
        XCTAssertNil(JapanPrefecture.from(name: nil))
    }

    // MARK: - Aggregator

    func testAggregateEmpty() {
        let state = SkyCollectionAggregator.aggregate([])
        XCTAssertEqual(state.totalPosts, 0)
        XCTAssertTrue(state.skyTypes.isEmpty)
        XCTAssertTrue(state.skyTimeCells.isEmpty)
    }

    func testAggregateBasicAndNilSkipped() {
        let metas = [
            PostCollectionMeta(skyType: .sunset, timeOfDay: .evening, season: .summer, prefecture: JapanPrefecture(name: "東京都")),
            PostCollectionMeta(skyType: .clear,  timeOfDay: .morning, season: .spring, prefecture: JapanPrefecture(name: "大阪府")),
            PostCollectionMeta(skyType: nil,     timeOfDay: nil,      season: nil,     prefecture: nil) // 全 nil
        ]
        let state = SkyCollectionAggregator.aggregate(metas)

        XCTAssertEqual(state.totalPosts, 3, "総数は全件（nilメタも数える）")
        XCTAssertEqual(state.skyTypes, [.sunset, .clear])
        XCTAssertEqual(state.timeOfDays, [.evening, .morning])
        XCTAssertEqual(state.seasons, [.summer, .spring])
        XCTAssertEqual(state.prefectures.count, 2)
        XCTAssertTrue(state.isCollected(skyType: .sunset, timeOfDay: .evening))
        XCTAssertFalse(state.isCollected(skyType: .sunset, timeOfDay: .morning))
    }

    func testAggregateDeduplicates() {
        let metas = Array(repeating: PostCollectionMeta(skyType: .clear, timeOfDay: .afternoon, season: .summer), count: 5)
        let state = SkyCollectionAggregator.aggregate(metas)
        XCTAssertEqual(state.totalPosts, 5)
        XCTAssertEqual(state.skyTypes, [.clear], "同じ空タイプは集合で1つに集約")
        XCTAssertEqual(state.skyTimeCells.count, 1)
    }

    // MARK: - PostCollectionMeta(from: Post)

    func testMetaSeasonFromCapturedAt() {
        let post = Post(id: "p1", userId: "u1", images: [],
                        capturedAt: date(year: 2026, month: 7), // 夏
                        timeOfDay: .evening, skyType: .sunset)
        let meta = PostCollectionMeta(from: post)
        XCTAssertEqual(meta.skyType, .sunset)
        XCTAssertEqual(meta.timeOfDay, .evening)
        XCTAssertEqual(meta.season, .summer)
        XCTAssertNil(meta.prefecture, "位置なしなら都道府県は nil")
    }

    func testMetaSeasonFallsBackToCreatedAt() {
        // capturedAt 無し → createdAt（冬）から季節を導出
        let post = Post(id: "p2", userId: "u1", images: [],
                        capturedAt: nil,
                        createdAt: date(year: 2026, month: 1))
        let meta = PostCollectionMeta(from: post)
        XCTAssertEqual(meta.season, .winter)
    }

    func testMetaTimeOfDayFallsBackToDate() {
        // timeOfDay 未設定 → 撮影日時（無ければ投稿日時）の時刻から導出。
        // これにより EXIF時刻が無い投稿でも「空×時間帯」マトリクスが埋まる。
        let morning = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 8))!
        let post = Post(id: "p4", userId: "u1", images: [], capturedAt: morning)
        let meta = PostCollectionMeta(from: post)
        XCTAssertEqual(meta.timeOfDay, .morning, "8時 → 朝")
    }

    func testMetaTimeOfDayPrefersStoredValue() {
        // 保存済み timeOfDay があればそれを優先（フォールバックしない）。
        let morning = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 8))!
        let post = Post(id: "p5", userId: "u1", images: [], capturedAt: morning, timeOfDay: .night)
        let meta = PostCollectionMeta(from: post)
        XCTAssertEqual(meta.timeOfDay, .night, "保存済みの値が優先される")
    }

    // MARK: - Badges

    func testAllSkyTypesBadgeUnlocksWhenAllFive() throws {
        let metas = SkyType.allCases.map { PostCollectionMeta(skyType: $0, timeOfDay: .afternoon) }
        let state = SkyCollectionAggregator.aggregate(metas)
        let badge = try XCTUnwrap(SkyBadge.all.first { $0.id == "all_sky_types" })
        XCTAssertTrue(badge.isUnlocked(state))
        XCTAssertEqual(badge.progress(state), BadgeProgress(current: 5, total: 5))
    }

    func testAllSkyTypesBadgeLockedWhenPartial() throws {
        let state = SkyCollectionAggregator.aggregate([
            PostCollectionMeta(skyType: .clear, timeOfDay: .morning),
            PostCollectionMeta(skyType: .sunset, timeOfDay: .evening)
        ])
        let badge = try XCTUnwrap(SkyBadge.all.first { $0.id == "all_sky_types" })
        XCTAssertFalse(badge.isUnlocked(state))
        XCTAssertEqual(badge.progress(state).current, 2)
        XCTAssertEqual(badge.progress(state).total, 5)
    }
}
