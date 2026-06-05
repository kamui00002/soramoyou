//
//  SolarCalculatorTests.swift
//  SoramoyouTests
//
//  ゴールデンアワー通知の太陽計算（SolarCalculator）の純関数テスト。
//  日没の既知値（国立天文台こよみ）に対して ±3 分で一致することを確認する。
//

import XCTest
@testable import Soramoyou

final class SolarCalculatorTests: XCTestCase {

    // 東京（東京駅近辺）
    private let tokyoLatitude = 35.6762
    private let tokyoLongitude = 139.6503
    private let jst = TimeZone(identifier: "Asia/Tokyo")!

    /// JST の指定日時を生成するヘルパー
    private func jstDate(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = jst
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    // MARK: - 日没の既知値

    func testTokyoSummerSolsticeSunset() {
        // 2026-06-21（夏至ごろ）の東京の日没はおよそ 19:00 JST
        let sunset = SolarCalculator.sunset(
            latitude: tokyoLatitude,
            longitude: tokyoLongitude,
            date: jstDate(2026, 6, 21),
            timeZone: jst
        )
        let expected = jstDate(2026, 6, 21, 19, 0)
        XCTAssertNotNil(sunset)
        XCTAssertEqual(
            sunset!.timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: 180, // ±3 分
            "東京の夏至の日没は 19:00 JST ±3分のはず"
        )
    }

    func testTokyoWinterSolsticeSunset() {
        // 2026-12-22（冬至ごろ）の東京の日没はおよそ 16:32 JST
        let sunset = SolarCalculator.sunset(
            latitude: tokyoLatitude,
            longitude: tokyoLongitude,
            date: jstDate(2026, 12, 22),
            timeZone: jst
        )
        let expected = jstDate(2026, 12, 22, 16, 32)
        XCTAssertNotNil(sunset)
        XCTAssertEqual(
            sunset!.timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: 180, // ±3 分
            "東京の冬至の日没は 16:32 JST ±3分のはず"
        )
    }

    func testSunsetIsSameRegardlessOfTimeOfDayAnchor() {
        // 同じローカル日付なら、入力時刻（朝/夜）によらず同じ日没を返す
        let morning = SolarCalculator.sunset(
            latitude: tokyoLatitude, longitude: tokyoLongitude,
            date: jstDate(2026, 6, 21, 0, 5), timeZone: jst
        )
        let night = SolarCalculator.sunset(
            latitude: tokyoLatitude, longitude: tokyoLongitude,
            date: jstDate(2026, 6, 21, 23, 55), timeZone: jst
        )
        XCTAssertEqual(morning, night)
    }

    // MARK: - 白夜・極夜

    func testMidnightSunReturnsNil() {
        // 北緯 78°（スヴァールバル諸島付近）の夏至 → 白夜で日没なし
        let sunset = SolarCalculator.sunset(
            latitude: 78.0,
            longitude: 15.0,
            date: jstDate(2026, 6, 21),
            timeZone: TimeZone(secondsFromGMT: 3600)!
        )
        XCTAssertNil(sunset, "白夜では日没は存在しない")
    }

    func testPolarNightReturnsNil() {
        // 北緯 78° の冬至 → 極夜で日没なし（太陽が昇らない）
        let sunset = SolarCalculator.sunset(
            latitude: 78.0,
            longitude: 15.0,
            date: jstDate(2026, 12, 22),
            timeZone: TimeZone(secondsFromGMT: 3600)!
        )
        XCTAssertNil(sunset, "極夜では日没は存在しない")
    }

    // MARK: - 通知発火時刻の算出

    func testFireDatesCountAndOrderWhenNowIsEarlyMorning() {
        // 基準時刻が深夜 0 時 → 当日分も含めて 14 件すべて未来
        let now = jstDate(2026, 6, 1, 0, 0)
        let fireDates = SolarCalculator.goldenHourFireDates(
            latitude: tokyoLatitude,
            longitude: tokyoLongitude,
            from: now,
            days: 14,
            notifyBeforeSunsetMinutes: 75,
            timeZone: jst
        )
        XCTAssertEqual(fireDates.count, 14)
        XCTAssertTrue(fireDates.allSatisfy { $0 > now }, "全件が基準時刻より未来")
        XCTAssertEqual(fireDates, fireDates.sorted(), "昇順で返る")
    }

    func testFireDateIsNotifyMinutesBeforeSunset() {
        // 発火時刻 = 日没の notifyBeforeSunsetMinutes 分前
        let now = jstDate(2026, 6, 1, 0, 0)
        let fireDates = SolarCalculator.goldenHourFireDates(
            latitude: tokyoLatitude,
            longitude: tokyoLongitude,
            from: now,
            days: 1,
            notifyBeforeSunsetMinutes: 75,
            timeZone: jst
        )
        let sunset = SolarCalculator.sunset(
            latitude: tokyoLatitude, longitude: tokyoLongitude,
            date: now, timeZone: jst
        )!
        XCTAssertEqual(fireDates.count, 1)
        XCTAssertEqual(
            fireDates[0].timeIntervalSince1970,
            sunset.timeIntervalSince1970 - 75 * 60,
            accuracy: 1
        )
    }

    func testPastFireDateIsExcluded() {
        // 基準時刻が当日の日没後（20時）→ 当日分は除外され 13 件になる
        let now = jstDate(2026, 6, 1, 20, 0)
        let fireDates = SolarCalculator.goldenHourFireDates(
            latitude: tokyoLatitude,
            longitude: tokyoLongitude,
            from: now,
            days: 14,
            notifyBeforeSunsetMinutes: 75,
            timeZone: jst
        )
        XCTAssertEqual(fireDates.count, 13, "発火時刻を過ぎた当日分は除外される")
        XCTAssertTrue(fireDates.allSatisfy { $0 > now })
    }

    func testZeroDaysReturnsEmpty() {
        let fireDates = SolarCalculator.goldenHourFireDates(
            latitude: tokyoLatitude,
            longitude: tokyoLongitude,
            from: jstDate(2026, 6, 1),
            days: 0,
            notifyBeforeSunsetMinutes: 75,
            timeZone: jst
        )
        XCTAssertTrue(fireDates.isEmpty)
    }
}
