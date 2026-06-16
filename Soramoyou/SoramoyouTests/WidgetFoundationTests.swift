//
//  WidgetFoundationTests.swift
//  SoramoyouTests
//
//  ホーム画面ウィジェットの共有土台（SolarCalculator 拡張 / SkyPhase / WidgetIndex）の純関数テスト。
//  - SolarCalculator: 新規イベント（日の出/南中/薄明）が既存 sunset() と整合するかを相互検証する。
//  - SkyPhase: 境界比較の純関数を、手組みの太陽イベントで決定的に検証する。
//  - WidgetIndex: Codable のラウンドトリップ。
//

import XCTest
@testable import Soramoyou

final class WidgetFoundationTests: XCTestCase {

    // 東京（東京駅近辺）
    private let tokyoLatitude = 35.6762
    private let tokyoLongitude = 139.6503
    private let jst = TimeZone(identifier: "Asia/Tokyo")!

    private func jstDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = jst
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: - SolarCalculator 新規イベント

    /// 南中は日の出と日没のちょうど中間にあるはず（同一時角の対称性）。
    /// これにより、新規 helper が既存 `sunset()` と同じ幾何を使っていることを相互検証する。
    func testSunriseSunsetAreSymmetricAroundSolarNoon() {
        let date = jstDate(2026, 6, 21)
        let sunrise = SolarCalculator.sunrise(latitude: tokyoLatitude, longitude: tokyoLongitude, date: date, timeZone: jst)
        let sunset = SolarCalculator.sunset(latitude: tokyoLatitude, longitude: tokyoLongitude, date: date, timeZone: jst)
        let noon = SolarCalculator.solarNoon(longitude: tokyoLongitude, date: date, timeZone: jst)
        XCTAssertNotNil(sunrise); XCTAssertNotNil(sunset); XCTAssertNotNil(noon)
        let beforeNoon = noon!.timeIntervalSince1970 - sunrise!.timeIntervalSince1970
        let afterNoon = sunset!.timeIntervalSince1970 - noon!.timeIntervalSince1970
        XCTAssertEqual(beforeNoon, afterNoon, accuracy: 1.0, "南中は日の出と日没の中間（±1秒）")
    }

    /// 日の出 < 南中 < 日没、かつ薄明が外側に来る順序。
    func testSolarEventOrdering() {
        let date = jstDate(2026, 3, 20) // 春分ごろ
        let dawn = SolarCalculator.civilDawn(latitude: tokyoLatitude, longitude: tokyoLongitude, date: date, timeZone: jst)!
        let sunrise = SolarCalculator.sunrise(latitude: tokyoLatitude, longitude: tokyoLongitude, date: date, timeZone: jst)!
        let noon = SolarCalculator.solarNoon(longitude: tokyoLongitude, date: date, timeZone: jst)!
        let sunset = SolarCalculator.sunset(latitude: tokyoLatitude, longitude: tokyoLongitude, date: date, timeZone: jst)!
        let dusk = SolarCalculator.civilDusk(latitude: tokyoLatitude, longitude: tokyoLongitude, date: date, timeZone: jst)!
        XCTAssertLessThan(dawn, sunrise, "薄明開始 < 日の出")
        XCTAssertLessThan(sunrise, noon, "日の出 < 南中")
        XCTAssertLessThan(noon, sunset, "南中 < 日没")
        XCTAssertLessThan(sunset, dusk, "日没 < 薄明終了")
    }

    /// 東京の夏至の日の出はおよそ 04:25 JST（±3分）。
    func testTokyoSummerSunriseKnownValue() {
        let sunrise = SolarCalculator.sunrise(latitude: tokyoLatitude, longitude: tokyoLongitude, date: jstDate(2026, 6, 21), timeZone: jst)
        XCTAssertNotNil(sunrise)
        XCTAssertEqual(sunrise!.timeIntervalSince1970, jstDate(2026, 6, 21, 4, 25).timeIntervalSince1970, accuracy: 180)
    }

    /// 白夜（北緯78°夏至）は日の出が無く nil。
    func testPolarDayHasNoSunrise() {
        let sunrise = SolarCalculator.sunrise(latitude: 78.0, longitude: 15.0, date: jstDate(2026, 6, 21), timeZone: TimeZone(secondsFromGMT: 3600)!)
        XCTAssertNil(sunrise, "白夜では日の出は存在しない")
    }

    // MARK: - SkyPhase 純関数（手組みの境界で決定的に検証）

    /// 固定の太陽イベントを手で組み、各時刻の局面を検証する。
    private func fixedTransitions() -> SkyPhase.SolarTransitions {
        SkyPhase.SolarTransitions(
            civilDawn: jstDate(2026, 6, 21, 5, 0),
            sunrise: jstDate(2026, 6, 21, 5, 30),
            solarNoon: jstDate(2026, 6, 21, 12, 0),
            sunset: jstDate(2026, 6, 21, 18, 30),
            civilDusk: jstDate(2026, 6, 21, 19, 0),
            noonHalfWidth: 90 * 60,   // 南中帯は 10:30〜
            goldenHourLead: 75 * 60   // 黄金時間は 17:15〜
        )
    }

    func testPhaseClassificationAcrossDay() {
        let tr = fixedTransitions()
        func phaseAt(_ h: Int, _ m: Int) -> SkyPhase {
            SkyPhase.phase(at: jstDate(2026, 6, 21, h, m), transitions: tr)
        }
        XCTAssertEqual(phaseAt(4, 0), .night, "薄明開始前は夜")
        XCTAssertEqual(phaseAt(5, 10), .dawn, "薄明開始〜日の出は夜明け")
        XCTAssertEqual(phaseAt(6, 0), .morning, "日の出〜南中帯手前は朝")
        XCTAssertEqual(phaseAt(11, 0), .day, "南中帯〜黄金時間手前は日中")
        XCTAssertEqual(phaseAt(17, 30), .goldenHour, "黄金時間開始以降は黄金時間")
        XCTAssertEqual(phaseAt(18, 45), .dusk, "日没〜薄明終了は夕暮れ")
        XCTAssertEqual(phaseAt(20, 0), .night, "薄明終了以降は夜")
    }

    func testPhaseBoundaryInclusivity() {
        let tr = fixedTransitions()
        // ちょうど日没は dusk 側に含まれる（t >= sunset）。
        XCTAssertEqual(SkyPhase.phase(at: jstDate(2026, 6, 21, 18, 30), transitions: tr), .dusk)
        // ちょうど南中帯開始（10:30）は day。
        XCTAssertEqual(SkyPhase.phase(at: jstDate(2026, 6, 21, 10, 30), transitions: tr), .day)
    }

    /// 6 局面 → 4 区分 TimeOfDay の写像。
    func testPhaseToTimeOfDayMapping() {
        XCTAssertEqual(SkyPhase.night.timeOfDay, .night)
        XCTAssertEqual(SkyPhase.dawn.timeOfDay, .morning)
        XCTAssertEqual(SkyPhase.morning.timeOfDay, .morning)
        XCTAssertEqual(SkyPhase.day.timeOfDay, .afternoon)
        XCTAssertEqual(SkyPhase.goldenHour.timeOfDay, .evening)
        XCTAssertEqual(SkyPhase.dusk.timeOfDay, .evening)
    }

    /// current(...) は東京の通常日で太陽ベースの妥当な局面を返す（フォールバックに落ちない）。
    func testCurrentUsesSolarPathForTokyo() {
        // 正午すぎ → 日中のはず。
        let phase = SkyPhase.current(at: jstDate(2026, 6, 21, 12, 30), latitude: tokyoLatitude, longitude: tokyoLongitude, timeZone: jst)
        XCTAssertEqual(phase, .day)
    }

    // MARK: - WidgetIndex Codable

    func testWidgetIndexRoundTrip() throws {
        let index = WidgetIndex(
            schemaVersion: WidgetIndex.currentSchemaVersion,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: [
                WidgetIndex.Entry(postId: "ABC123", imageFileName: "ABC123.jpg", timeOfDay: "evening", skyColors: ["#ff8a00", "#3a2a4d"], createdAt: Date(timeIntervalSince1970: 1_699_990_000)),
                WidgetIndex.Entry(postId: "DEF456", imageFileName: "DEF456.jpg", timeOfDay: nil, skyColors: [], createdAt: Date(timeIntervalSince1970: 1_699_980_000))
            ]
        )
        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(WidgetIndex.self, from: data)
        XCTAssertEqual(index, decoded)
        XCTAssertEqual(decoded.entries.first?.id, "ABC123", "Identifiable の id は postId")
    }

    func testWidgetIndexEmptyDefault() {
        XCTAssertTrue(WidgetIndex.empty.entries.isEmpty)
        XCTAssertEqual(WidgetIndex.empty.schemaVersion, WidgetIndex.currentSchemaVersion)
    }
}
