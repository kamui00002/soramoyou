//
//  DailyPickKeyTests.swift
//  SoramoyouTests
//
//  「今日のおすすめのそらもよう」の日付の鍵（DailyPickKey.keys）の単体テスト ⭐️
//  サーバー（functions/dailyPickCore.js の dateKeyForInstant）と同じ「日本時間で 7 時に切り替わる」決め方を確かめる。
//  瞬間は UTC の ISO8601 文字列から作り、端末のタイムゾーンに依存させない。
//
//  陽性対照（2026-10-26 予定・メインが流して記録する）
//  - DailyPickKey.switchHourJST を 7 から 0 に変えると赤になるはずのテスト:
//      testJustBeforeSevenJSTIsPreviousDay / testMatchesServerExampleJustBefore /
//      testMidnightJSTIsPreviousDay / testMonthBoundaryBeforeSeven / testYearBoundaryBeforeSeven /
//      testLeapDayBoundary / testSwitchHourIsSeven
//    （7 時ちょうどを見るテストと 23:59 は 0 時切り替えでも同じ値になるので赤にならない。
//      「7 時の 1 秒前」を見るテストが切り替え時刻の変更を捕まえる）
//  - 結果（2026-10-26・iPhone 18 Pro シミュレーター）: 7 → 0 で、予言の 7 本だけが赤（14 本中 7 本。
//    ログの「12 failures」は XCTAssert の数）。ほかの 7 本は緑。壊す前（同じ中身）は 14 本すべて緑
//

@testable import Soramoyou
import XCTest

final class DailyPickKeyTests: XCTestCase {
    /// UTC の ISO8601 文字列から瞬間を作る
    private func instant(_ iso: String, file: StaticString = #filePath, line: UInt = #line) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else {
            XCTFail("ISO8601 を読めない: \(iso)", file: file, line: line)
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    // MARK: - 7 時の切り替え

    /// 07:00:00 JST（= 前日 22:00:00Z）は当日
    func testSevenOClockJSTIsToday() {
        let keys = DailyPickKey.keys(now: instant("2026-10-24T22:00:00Z"))
        XCTAssertEqual(keys.today, "2026-10-25")
    }

    /// 06:59:59 JST（= 前日 21:59:59Z）は前日
    func testJustBeforeSevenJSTIsPreviousDay() {
        let keys = DailyPickKey.keys(now: instant("2026-10-24T21:59:59Z"))
        XCTAssertEqual(keys.today, "2026-10-24")
    }

    /// サーバーと同じ値になる例（切り替えちょうど）
    func testMatchesServerExampleAtSwitch() {
        let keys = DailyPickKey.keys(now: instant("2026-10-24T22:00:00Z"))
        XCTAssertEqual(keys.today, "2026-10-25")
        XCTAssertEqual(keys.fallback, "2026-10-24")
    }

    /// サーバーと同じ値になる例（切り替えの 1 秒前）
    func testMatchesServerExampleJustBefore() {
        let keys = DailyPickKey.keys(now: instant("2026-10-24T21:59:59Z"))
        XCTAssertEqual(keys.today, "2026-10-24")
        XCTAssertEqual(keys.fallback, "2026-10-23")
    }

    /// 23:59 JST（= 14:59Z）は同じ日の鍵
    func testEndOfDayJST() {
        let keys = DailyPickKey.keys(now: instant("2026-10-25T14:59:00Z"))
        XCTAssertEqual(keys.today, "2026-10-25")
    }

    /// 00:00 JST（= 前日 15:00Z）はまだ前日の鍵（7 時まで切り替わらない）
    func testMidnightJSTIsPreviousDay() {
        let keys = DailyPickKey.keys(now: instant("2026-10-25T15:00:00Z"))
        XCTAssertEqual(keys.today, "2026-10-25")
        XCTAssertEqual(keys.fallback, "2026-10-24")
    }

    // MARK: - 月・年・うるう日のまたぎ

    /// 月またぎ: 11/1 06:59 JST は 10/31 の鍵、前日は 10/30
    func testMonthBoundaryBeforeSeven() {
        let keys = DailyPickKey.keys(now: instant("2026-10-31T21:59:00Z"))
        XCTAssertEqual(keys.today, "2026-10-31")
        XCTAssertEqual(keys.fallback, "2026-10-30")
    }

    /// 月またぎ: 11/1 07:00 JST は 11/1 の鍵、前日は 10/31
    func testMonthBoundaryAtSeven() {
        let keys = DailyPickKey.keys(now: instant("2026-10-31T22:00:00Z"))
        XCTAssertEqual(keys.today, "2026-11-01")
        XCTAssertEqual(keys.fallback, "2026-10-31")
    }

    /// 年またぎ: 1/1 06:59 JST は前年 12/31 の鍵、前日は 12/30
    func testYearBoundaryBeforeSeven() {
        let keys = DailyPickKey.keys(now: instant("2026-12-31T21:59:00Z"))
        XCTAssertEqual(keys.today, "2026-12-31")
        XCTAssertEqual(keys.fallback, "2026-12-30")
    }

    /// 年またぎ: 1/1 07:00 JST は新年の鍵、前日は 12/31
    func testYearBoundaryAtSeven() {
        let keys = DailyPickKey.keys(now: instant("2026-12-31T22:00:00Z"))
        XCTAssertEqual(keys.today, "2027-01-01")
        XCTAssertEqual(keys.fallback, "2026-12-31")
    }

    /// うるう日: 2028-02-29 07:00 JST は 2/29 の鍵、前日は 2/28
    func testLeapDayAtSeven() {
        let keys = DailyPickKey.keys(now: instant("2028-02-28T22:00:00Z"))
        XCTAssertEqual(keys.today, "2028-02-29")
        XCTAssertEqual(keys.fallback, "2028-02-28")
    }

    /// うるう日の翌日: 2028-03-01 06:59 JST はまだ 2/29 の鍵、前日は 2/28
    func testLeapDayBoundary() {
        let keys = DailyPickKey.keys(now: instant("2028-02-29T21:59:00Z"))
        XCTAssertEqual(keys.today, "2028-02-29")
        XCTAssertEqual(keys.fallback, "2028-02-28")
    }

    /// うるう日の翌日の 07:00 JST は 3/1 の鍵、前日は 2/29
    func testDayAfterLeapDayAtSeven() {
        let keys = DailyPickKey.keys(now: instant("2028-02-29T22:00:00Z"))
        XCTAssertEqual(keys.today, "2028-03-01")
        XCTAssertEqual(keys.fallback, "2028-02-29")
    }

    // MARK: - 固定値

    /// 切り替え時刻はサーバーの DAY_SWITCH_HOUR_JST と同じ 7
    func testSwitchHourIsSeven() {
        XCTAssertEqual(DailyPickKey.switchHourJST, 7)
    }
}
