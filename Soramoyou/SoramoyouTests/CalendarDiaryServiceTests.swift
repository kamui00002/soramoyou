//
//  CalendarDiaryServiceTests.swift
//  SoramoyouTests
//
//  空カレンダー日記 CalendarDiaryService の純関数テスト。
//

import XCTest
@testable import Soramoyou

final class CalendarDiaryServiceTests: XCTestCase {

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testGroupsPostsByCapturedAtDay() {
        let posts = [
            Post(id: "a", userId: "u", images: [], capturedAt: date(2026, 6, 1)),
            Post(id: "b", userId: "u", images: [], capturedAt: date(2026, 6, 2))
        ]
        let grouped = CalendarDiaryService.groupByDay(posts: posts)
        XCTAssertEqual(grouped[SkyStreakDay(year: 2026, month: 6, day: 1)]?.map { $0.id }, ["a"])
        XCTAssertEqual(grouped[SkyStreakDay(year: 2026, month: 6, day: 2)]?.map { $0.id }, ["b"])
    }

    func testSameDayMultiplePostsSortedNewestFirst() {
        let posts = [
            Post(
                id: "older", userId: "u", images: [],
                capturedAt: date(2026, 6, 1, hour: 8), createdAt: date(2026, 6, 1, hour: 8)
            ),
            Post(
                id: "newer", userId: "u", images: [],
                capturedAt: date(2026, 6, 1, hour: 20), createdAt: date(2026, 6, 1, hour: 20)
            )
        ]
        let grouped = CalendarDiaryService.groupByDay(posts: posts)
        let day = SkyStreakDay(year: 2026, month: 6, day: 1)
        XCTAssertEqual(grouped[day]?.map { $0.id }, ["newer", "older"], "同日複数投稿は新しい順")
    }

    func testFallsBackToCreatedAtWhenCapturedAtNil() {
        // capturedAt 無し → createdAt(2026-06-15) で判定
        let post = Post(id: "x", userId: "u", images: [], capturedAt: nil, createdAt: date(2026, 6, 15))
        let grouped = CalendarDiaryService.groupByDay(posts: [post])
        XCTAssertEqual(grouped[SkyStreakDay(year: 2026, month: 6, day: 15)]?.map { $0.id }, ["x"])
    }

    func testCapturedAtTakesPriorityOverCreatedAt() {
        // 撮影日(2026-06-15)と投稿日(2026-01-01)が異なる → 撮影日のキーに入る
        let post = Post(id: "y", userId: "u", images: [], capturedAt: date(2026, 6, 15), createdAt: date(2026, 1, 1))
        let grouped = CalendarDiaryService.groupByDay(posts: [post])
        XCTAssertEqual(grouped[SkyStreakDay(year: 2026, month: 6, day: 15)]?.map { $0.id }, ["y"])
        XCTAssertNil(grouped[SkyStreakDay(year: 2026, month: 1, day: 1)])
    }

    func testMonthBoundaryPostsGoToDistinctKeys() {
        let posts = [
            Post(id: "may31", userId: "u", images: [], capturedAt: date(2026, 5, 31)),
            Post(id: "jun1", userId: "u", images: [], capturedAt: date(2026, 6, 1))
        ]
        let grouped = CalendarDiaryService.groupByDay(posts: posts)
        XCTAssertEqual(grouped.keys.count, 2, "月をまたぐ投稿は別キーに分かれる")
        XCTAssertEqual(grouped[SkyStreakDay(year: 2026, month: 5, day: 31)]?.map { $0.id }, ["may31"])
        XCTAssertEqual(grouped[SkyStreakDay(year: 2026, month: 6, day: 1)]?.map { $0.id }, ["jun1"])
    }

    func testEmptyInputReturnsEmptyDictionary() {
        XCTAssertTrue(CalendarDiaryService.groupByDay(posts: []).isEmpty)
    }

    // MARK: - 暦識別子の回帰（和暦端末で全セル空白になるバグの再発防止）

    /// 既定の calendar（.soramoyouGregorian）は西暦キーを生成する。
    /// 和暦の Calendar.current を持つ端末でも、この既定値のおかげでグリッド描画・空月判定と
    /// 同じ西暦キー（令和8年=8 ではなく 2026）になることを固定する。
    func testDefaultCalendarProducesGregorianYearKey() {
        let post = Post(id: "a", userId: "u", images: [], capturedAt: date(2026, 6, 1))
        let grouped = CalendarDiaryService.groupByDay(posts: [post])
        XCTAssertNotNil(grouped[SkyStreakDay(year: 2026, month: 6, day: 1)], "既定は西暦（2026）のキーになる")
    }

    /// 和暦（Calendar(identifier: .japanese)）を明示的に注入しても、日ごとのグルーピング（＝どの投稿が
    /// 同じ日にまとまるか）はグレゴリオ暦注入時と変わらない。和暦と西暦は年の数え方が違うだけで
    /// 月/日の暦上の境界は共通のため、年の表現以外の「グルーピング結果」自体は一致する。
    /// ⚠️ この一致は「和暦Calendarを明示的に渡した場合」に限る。実機の `Calendar.current` を
    ///   和暦にモックすることは Foundation の制約上できないため、本テストは意図の固定であり、
    ///   実際の和暦端末バグは Calendar+Soramoyou.swift の既定値（.soramoyouGregorian）で防いでいる。
    func testGroupingIsInvariantAcrossCalendarIdentifiers() {
        var japaneseCalendar = Calendar(identifier: .japanese)
        japaneseCalendar.timeZone = .current

        let posts = [
            Post(id: "a", userId: "u", images: [], capturedAt: date(2026, 6, 1)),
            Post(id: "b", userId: "u", images: [], capturedAt: date(2026, 6, 2)),
            Post(id: "c", userId: "u", images: [], capturedAt: date(2026, 12, 31))
        ]

        let groupedGregorian = CalendarDiaryService.groupByDay(posts: posts, calendar: .soramoyouGregorian)
        let groupedJapanese = CalendarDiaryService.groupByDay(posts: posts, calendar: japaneseCalendar)

        // 「同じ日にまとまる投稿の組」を年の表現に依存しない形（月/日 + 投稿ID集合）で比較する
        func partitions(_ grouped: [SkyStreakDay: [Post]]) -> Set<Set<String>> {
            Set(grouped.values.map { Set($0.map { $0.id }) })
        }
        XCTAssertEqual(
            partitions(groupedGregorian), partitions(groupedJapanese),
            "暦の識別子が違っても、日ごとのグルーピング（どの投稿が同じ日にまとまるか）は変わらない"
        )
        XCTAssertEqual(groupedGregorian.count, groupedJapanese.count)
    }
}
