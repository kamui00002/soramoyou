//
//  CommentRowTests.swift
//  SoramoyouTests
//
//  コメントの日時の文字（CommentRow.timeText）の検証 ⭐️
//

import XCTest
@testable import Soramoyou

final class CommentRowTests: XCTestCase {

    /// 日本語を渡すと「〜分前」「昨日」と出る
    func testTimeTextIsRelativeInJapanese() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ja = Locale(identifier: "ja_JP")

        let fiveMinutes = CommentRow.timeText(for: now.addingTimeInterval(-300), now: now, locale: ja)
        XCTAssertTrue(fiveMinutes.contains("5") && fiveMinutes.contains("分前"), "実際: \(fiveMinutes)")

        XCTAssertEqual(CommentRow.timeText(for: now.addingTimeInterval(-86400), now: now, locale: ja), "昨日")
    }

    /// 言語を渡さない（画面と同じ呼び方の）ときも日本語で出る
    ///
    /// アプリは日本語のローカライズを持たない（developmentRegion = en）ため、
    /// `Locale.current` は端末を日本語にしても英語になる（2026-10-07 実機でコメントの時刻が英語）。
    /// 既定値のまま呼んで確かめる
    func testTimeTextDefaultsToJapanese() {
        let now = Date()

        XCTAssertEqual(CommentRow.timeText(for: now.addingTimeInterval(-86400), now: now), "昨日")

        let fiveMinutes = CommentRow.timeText(for: now.addingTimeInterval(-300), now: now)
        XCTAssertTrue(fiveMinutes.contains("5") && fiveMinutes.contains("分前"), "実際: \(fiveMinutes)")
    }

    /// コメントした人の時計が進んでいて未来の時刻でも「〜後」とは出さない
    func testTimeTextDoesNotSayFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ja = Locale(identifier: "ja_JP")

        let future = CommentRow.timeText(for: now.addingTimeInterval(30), now: now, locale: ja)
        XCTAssertFalse(future.contains("後"), "実際: \(future)")
        XCTAssertEqual(future, CommentRow.timeText(for: now, now: now, locale: ja))
    }
}
