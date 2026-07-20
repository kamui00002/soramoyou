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
}
