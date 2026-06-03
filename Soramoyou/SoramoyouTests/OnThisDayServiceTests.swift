//
//  OnThisDayServiceTests.swift
//  SoramoyouTests
//
//  増分4 On This Day（1年前の空）の純関数テスト。
//

import XCTest
@testable import Soramoyou

final class OnThisDayServiceTests: XCTestCase {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testIncludesSameMonthDayPastYearsSortedNewestFirst() {
        let today = date(2026, 6, 4)
        let posts = [
            Post(id: "a", userId: "u", images: [], capturedAt: date(2025, 6, 4)), // 1年前
            Post(id: "b", userId: "u", images: [], capturedAt: date(2024, 6, 4)), // 2年前
            Post(id: "c", userId: "u", images: [], capturedAt: date(2025, 6, 5)), // 別日 → 除外
            Post(id: "d", userId: "u", images: [], capturedAt: date(2026, 6, 4))  // 今年 → 除外
        ]
        let memories = OnThisDayService.memories(from: posts, today: today)
        XCTAssertEqual(memories.map { $0.post.id }, ["a", "b"], "同月日・過去年のみ、新しい順")
        XCTAssertEqual(memories.map { $0.yearsAgo }, [1, 2])
    }

    func testExcludesCurrentAndFutureYears() {
        let today = date(2026, 6, 4)
        let posts = [
            Post(id: "now", userId: "u", images: [], capturedAt: date(2026, 6, 4)),
            Post(id: "future", userId: "u", images: [], capturedAt: date(2027, 6, 4))
        ]
        XCTAssertTrue(OnThisDayService.memories(from: posts, today: today).isEmpty)
    }

    func testEmptyWhenNoMatch() {
        let today = date(2026, 6, 4)
        let posts = [Post(id: "x", userId: "u", images: [], capturedAt: date(2025, 1, 1))]
        XCTAssertTrue(OnThisDayService.memories(from: posts, today: today).isEmpty)
    }

    func testFallsBackToCreatedAtWhenNoCapturedAt() {
        let today = date(2026, 6, 4)
        // capturedAt 無し → createdAt(2025-06-04) で判定
        let post = Post(id: "y", userId: "u", images: [], capturedAt: nil, createdAt: date(2025, 6, 4))
        let memories = OnThisDayService.memories(from: [post], today: today)
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories.first?.yearsAgo, 1)
    }

    func testCapturedAtTakesPriorityOverCreatedAt() {
        let today = date(2026, 6, 4)
        // 撮影日(2025-06-04)は一致するが投稿日(2025-01-01)は不一致 → capturedAt 優先で一致
        let post = Post(id: "z", userId: "u", images: [], capturedAt: date(2025, 6, 4), createdAt: date(2025, 1, 1))
        XCTAssertEqual(OnThisDayService.memories(from: [post], today: today).count, 1)
    }

    func testEmptyInput() {
        XCTAssertTrue(OnThisDayService.memories(from: [], today: date(2026, 6, 4)).isEmpty)
    }
}
