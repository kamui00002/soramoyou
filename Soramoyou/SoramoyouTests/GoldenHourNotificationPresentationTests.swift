//
//  GoldenHourNotificationPresentationTests.swift
//  SoramoyouTests
//
//  アプリが前面にあるときに届いた通知の出し方のテスト ⭐️（そらとも 要件 10.13）
//
//  `willPresent` は UNNotification を作れないので直接は呼ばず、返す値の元の定数を確かめる。
//

@testable import Soramoyou
import UserNotifications
import XCTest

@MainActor
final class GoldenHourNotificationPresentationTests: XCTestCase {
    /// 前面でもバナーと音で知らせる（既存の挙動を変えない）
    func testForegroundOptionsKeepBannerAndSound() {
        let options = GoldenHourNotificationManager.foregroundPresentationOptions
        XCTAssertTrue(options.contains(.banner))
        XCTAssertTrue(options.contains(.sound))
    }

    /// 前面で受けた通知も通知センターに残す（バナーが消えたあとに見返せるように）
    func testForegroundOptionsKeepNotificationInList() {
        XCTAssertTrue(GoldenHourNotificationManager.foregroundPresentationOptions.contains(.list))
    }
}
