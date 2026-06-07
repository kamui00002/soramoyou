//
//  SkyStreakCalculatorTests.swift
//  SoramoyouTests
//
//  ストリーク計算（SkyStreakCalculator）の純関数テスト。
//  「1日 = 投稿日（createdAt）のローカル暦日」という製品判断を回帰で固定する。
//

import XCTest
@testable import Soramoyou

final class SkyStreakCalculatorTests: XCTestCase {

    private let calendar = Calendar.current

    /// 指定日時の Date を生成するヘルパー
    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// createdAt 指定で投稿を生成するヘルパー
    private func post(_ id: String, createdAt: Date, capturedAt: Date? = nil) -> Post {
        Post(id: id, userId: "u", images: [], capturedAt: capturedAt, createdAt: createdAt)
    }

    // MARK: - 基本

    func testEmptyPostsReturnsEmptyState() {
        let state = SkyStreakCalculator.calculate(posts: [], today: date(2026, 6, 7))
        XCTAssertEqual(state, .empty)
    }

    func testSinglePostTodayGivesStreakOne() {
        let today = date(2026, 6, 7)
        let state = SkyStreakCalculator.calculate(
            posts: [post("a", createdAt: date(2026, 6, 7, hour: 8))],
            today: today
        )
        XCTAssertEqual(state.currentStreak, 1)
        XCTAssertEqual(state.longestStreak, 1)
        XCTAssertTrue(state.didPostToday)
    }

    // MARK: - 現在ストリーク（終端の扱い）

    func testThreeConsecutiveDaysEndingTodayGivesStreakThree() {
        let today = date(2026, 6, 7)
        let posts = [
            post("a", createdAt: date(2026, 6, 5)),
            post("b", createdAt: date(2026, 6, 6)),
            post("c", createdAt: date(2026, 6, 7))
        ]
        let state = SkyStreakCalculator.calculate(posts: posts, today: today)
        XCTAssertEqual(state.currentStreak, 3)
        XCTAssertTrue(state.didPostToday)
    }

    func testStreakEndingYesterdayStillCountsAsOngoing() {
        // 今日まだ投稿していなくても、昨日まで連続なら「継続中」（今日が終わるまで切れない）
        let today = date(2026, 6, 7)
        let posts = [
            post("a", createdAt: date(2026, 6, 4)),
            post("b", createdAt: date(2026, 6, 5)),
            post("c", createdAt: date(2026, 6, 6))
        ]
        let state = SkyStreakCalculator.calculate(posts: posts, today: today)
        XCTAssertEqual(state.currentStreak, 3, "昨日終端の連続は継続中として数える")
        XCTAssertFalse(state.didPostToday)
    }

    func testStreakEndedTwoDaysAgoIsBroken() {
        // 一昨日で止まっていたら現在ストリークは 0（最長には残る）
        let today = date(2026, 6, 7)
        let posts = [
            post("a", createdAt: date(2026, 6, 3)),
            post("b", createdAt: date(2026, 6, 4)),
            post("c", createdAt: date(2026, 6, 5))
        ]
        let state = SkyStreakCalculator.calculate(posts: posts, today: today)
        XCTAssertEqual(state.currentStreak, 0)
        XCTAssertEqual(state.longestStreak, 3)
    }

    // MARK: - 最長ストリーク

    func testLongestStreakSurvivesGaps() {
        // 6/1,6/2,6/3（3連続）→ 6/5（単発）→ 今日6/7（単発）
        let today = date(2026, 6, 7)
        let posts = [
            post("a", createdAt: date(2026, 6, 1)),
            post("b", createdAt: date(2026, 6, 2)),
            post("c", createdAt: date(2026, 6, 3)),
            post("d", createdAt: date(2026, 6, 5)),
            post("e", createdAt: date(2026, 6, 7))
        ]
        let state = SkyStreakCalculator.calculate(posts: posts, today: today)
        XCTAssertEqual(state.longestStreak, 3)
        XCTAssertEqual(state.currentStreak, 1)
    }

    func testSameDayMultiplePostsCountOnce() {
        // 同じ日に3回投稿しても1日として数える
        let today = date(2026, 6, 7)
        let posts = [
            post("a", createdAt: date(2026, 6, 7, hour: 6)),
            post("b", createdAt: date(2026, 6, 7, hour: 12)),
            post("c", createdAt: date(2026, 6, 7, hour: 20))
        ]
        let state = SkyStreakCalculator.calculate(posts: posts, today: today)
        XCTAssertEqual(state.currentStreak, 1)
        XCTAssertEqual(state.longestStreak, 1)
    }

    func testMonthBoundaryIsConsecutive() {
        // 5/31 → 6/1 は連続として数える（月跨ぎ）
        let today = date(2026, 6, 1)
        let posts = [
            post("a", createdAt: date(2026, 5, 31)),
            post("b", createdAt: date(2026, 6, 1))
        ]
        let state = SkyStreakCalculator.calculate(posts: posts, today: today)
        XCTAssertEqual(state.currentStreak, 2)
        XCTAssertEqual(state.longestStreak, 2)
    }

    // MARK: - 製品判断の固定: 撮影日は無視する

    func testCapturedAtIsIgnoredForStreak() {
        // 撮影日（capturedAt）が3日連続でも、投稿日（createdAt）が同じ1日なら 1日分
        // （過去写真の一括アップロードでストリークが遡って成立しないことの回帰）
        let today = date(2026, 6, 7)
        let posts = [
            post("a", createdAt: date(2026, 6, 7, hour: 9),  capturedAt: date(2026, 6, 1)),
            post("b", createdAt: date(2026, 6, 7, hour: 10), capturedAt: date(2026, 6, 2)),
            post("c", createdAt: date(2026, 6, 7, hour: 11), capturedAt: date(2026, 6, 3))
        ]
        let state = SkyStreakCalculator.calculate(posts: posts, today: today)
        XCTAssertEqual(state.currentStreak, 1, "撮影日ではなく投稿日で数える")
        XCTAssertEqual(state.longestStreak, 1)
    }

    // MARK: - カレンダー用の日集合

    func testPostedDaysContainsCorrectCalendarDays() {
        let today = date(2026, 6, 7)
        let posts = [
            post("a", createdAt: date(2026, 6, 5)),
            post("b", createdAt: date(2026, 6, 7))
        ]
        let state = SkyStreakCalculator.calculate(posts: posts, today: today)
        XCTAssertEqual(state.postedDays.count, 2)
        XCTAssertTrue(state.postedDays.contains(SkyStreakDay(year: 2026, month: 6, day: 5)))
        XCTAssertTrue(state.postedDays.contains(SkyStreakDay(year: 2026, month: 6, day: 7)))
        XCTAssertFalse(state.postedDays.contains(SkyStreakDay(year: 2026, month: 6, day: 6)))
    }
}
