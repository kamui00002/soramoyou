//
//  SoratomoDaySectionTests.swift
//  SoramoyouTests
//
//  そらとものタイムラインの日付の見出し（SoratomoDaySection）のテスト ⭐️（tasks 10.3）
//

@testable import Soramoyou
import XCTest

final class SoratomoDaySectionTests: XCTestCase {
    // MARK: - Helpers

    /// タイムゾーンを固定したグレゴリオ暦（テストの結果を実行する端末の設定に左右させない）
    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    /// 指定したカレンダーでの日時を作る
    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
        in calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    private lazy var tokyo = calendar("Asia/Tokyo")

    // MARK: - 今日・昨日

    func testTodayCoversWholeDay() {
        let now = date(2026, 10, 4, 12, 0, 0, in: tokyo)
        XCTAssertEqual(SoratomoDaySection.title(for: date(2026, 10, 4, 0, 0, 0, in: tokyo), now: now, calendar: tokyo), "今日")
        XCTAssertEqual(SoratomoDaySection.title(for: date(2026, 10, 4, 23, 59, 59, in: tokyo), now: now, calendar: tokyo), "今日")
    }

    func testYesterdayBoundaries() {
        let now = date(2026, 10, 4, 0, 0, 1, in: tokyo)
        // 昨日の 23:59:59 と 0:00:00 はどちらも「昨日」
        XCTAssertEqual(SoratomoDaySection.title(for: date(2026, 10, 3, 23, 59, 59, in: tokyo), now: now, calendar: tokyo), "昨日")
        XCTAssertEqual(SoratomoDaySection.title(for: date(2026, 10, 3, 0, 0, 0, in: tokyo), now: now, calendar: tokyo), "昨日")
        // おとといの 23:59:59 は日付の見出し
        XCTAssertEqual(SoratomoDaySection.title(for: date(2026, 10, 2, 23, 59, 59, in: tokyo), now: now, calendar: tokyo), "10月2日")
    }

    // MARK: - 今年・去年

    func testThisYearUsesMonthAndDay() {
        let now = date(2026, 10, 4, 12, 0, 0, in: tokyo)
        XCTAssertEqual(SoratomoDaySection.title(for: date(2026, 10, 1, 9, 0, 0, in: tokyo), now: now, calendar: tokyo), "10月1日")
        // 月・日は 0 で埋めない（要件 8.4 の例「10月1日」）
        XCTAssertEqual(SoratomoDaySection.title(for: date(2026, 1, 1, 0, 0, 0, in: tokyo), now: now, calendar: tokyo), "1月1日")
    }

    func testOtherYearIncludesYear() {
        let now = date(2026, 10, 4, 12, 0, 0, in: tokyo)
        XCTAssertEqual(
            SoratomoDaySection.title(for: date(2025, 12, 31, 23, 59, 59, in: tokyo), now: now, calendar: tokyo),
            "2025年12月31日"
        )
        XCTAssertEqual(
            SoratomoDaySection.title(for: date(2024, 2, 29, 8, 0, 0, in: tokyo), now: now, calendar: tokyo),
            "2024年2月29日"
        )
    }

    func testYesterdayWinsOverYearOnNewYearsDay() {
        // 1月1日に見た 12月31日の投稿は、年が違っても「昨日」
        let now = date(2026, 1, 1, 0, 30, 0, in: tokyo)
        XCTAssertEqual(SoratomoDaySection.title(for: date(2025, 12, 31, 23, 0, 0, in: tokyo), now: now, calendar: tokyo), "昨日")
        // 12月30日は去年の日付の見出し
        XCTAssertEqual(
            SoratomoDaySection.title(for: date(2025, 12, 30, 23, 0, 0, in: tokyo), now: now, calendar: tokyo),
            "2025年12月30日"
        )
    }

    // MARK: - タイムゾーン

    func testDayBoundaryFollowsCalendarTimeZone() {
        // 同じ 2 つの瞬間でも、タイムゾーンが違えば「今日」か「昨日」かが変わる。
        // 投稿 = 東京 10月3日 23:30（UTC 10月3日 14:30）、現在 = 東京 10月4日 0:30（UTC 10月3日 15:30）
        let utc = calendar("UTC")
        let post = date(2026, 10, 3, 23, 30, 0, in: tokyo)
        let now = date(2026, 10, 4, 0, 30, 0, in: tokyo)

        // 東京では日付をまたいでいるので「昨日」
        XCTAssertEqual(SoratomoDaySection.title(for: post, now: now, calendar: tokyo), "昨日")
        // UTC ではどちらも 10月3日なので「今日」
        XCTAssertEqual(SoratomoDaySection.title(for: post, now: now, calendar: utc), "今日")
        // 年が変わる境目も同じ: 東京 1月1日 0:30 に見た 12月31日 23:30 の投稿は東京で「昨日」、UTC で「今日」
        let newYearPost = date(2025, 12, 31, 23, 30, 0, in: tokyo)
        let newYearNow = date(2026, 1, 1, 0, 30, 0, in: tokyo)
        XCTAssertEqual(SoratomoDaySection.title(for: newYearPost, now: newYearNow, calendar: tokyo), "昨日")
        XCTAssertEqual(SoratomoDaySection.title(for: newYearPost, now: newYearNow, calendar: utc), "今日")
    }

    func testStartOfDayUsesCalendarTimeZone() {
        let post = date(2026, 10, 4, 1, 0, 0, in: tokyo)
        XCTAssertEqual(SoratomoDaySection.startOfDay(for: post, calendar: tokyo), date(2026, 10, 4, 0, 0, 0, in: tokyo))
        // 同じ日の別の時刻は同じ鍵
        XCTAssertEqual(
            SoratomoDaySection.startOfDay(for: date(2026, 10, 4, 23, 59, 59, in: tokyo), calendar: tokyo),
            SoratomoDaySection.startOfDay(for: post, calendar: tokyo)
        )
    }

    func testDeviceCalendarIsGregorianWithCurrentTimeZone() {
        // 端末の設定が和暦でも、年は西暦で出す（要件 8.5 の例「2025年12月31日」）
        let device = SoratomoDaySection.deviceCalendar
        XCTAssertEqual(device.identifier, .gregorian)
        XCTAssertEqual(device.timeZone, TimeZone.current)
    }
}
