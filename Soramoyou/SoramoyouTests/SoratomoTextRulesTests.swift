//
//  SoratomoTextRulesTests.swift
//  SoramoyouTests
//
//  そらともの文字数の規則（SoratomoTextRules）のテスト ⭐️（tasks 10.3）
//

@testable import Soramoyou
import XCTest

final class SoratomoTextRulesTests: XCTestCase {
    // MARK: - 数え方（コードポイント）

    func testLengthCountsUnicodeScalars() {
        // 絵文字 1 つ（サロゲートペア）は 1。UTF-16 なら 2 になる
        XCTAssertEqual(SoratomoTextRules.length("🌅"), 1)
        // 3 人の絵文字を結合文字（ZWJ）でつないだものは、見た目は 1 文字でもコードポイントは 5
        XCTAssertEqual(SoratomoTextRules.length("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"), 5)
        // 「か」＋結合用の濁点（U+3099）は 2。合成済みの「が」は 1
        XCTAssertEqual(SoratomoTextRules.length("\u{304B}\u{3099}"), 2)
        XCTAssertEqual(SoratomoTextRules.length("が"), 1)
        // 「e」＋結合用のアクセント（U+0301）は 2
        XCTAssertEqual(SoratomoTextRules.length("e\u{0301}"), 2)
    }

    // MARK: - グループ名（1〜30 文字）

    func testGroupNameAccepts30AndRejects31() {
        let thirty = String(repeating: "空", count: 30)
        XCTAssertEqual(SoratomoTextRules.validateGroupName(thirty), .success(thirty))
        XCTAssertEqual(
            SoratomoTextRules.validateGroupName(thirty + "空"),
            .failure(.tooLong(max: 30))
        )
    }

    func testGroupNameTrimsWhitespaceBeforeCounting() {
        // 前後の空白（半角・全角・改行・U+FEFF）は除いてから数える。中の空白は残す
        let thirty = String(repeating: "あ", count: 30)
        XCTAssertEqual(
            SoratomoTextRules.validateGroupName(" \u{3000}\n\u{FEFF}" + thirty + " \u{3000}"),
            .success(thirty)
        )
        XCTAssertEqual(SoratomoTextRules.validateGroupName(" 空 の 会 "), .success("空 の 会"))
    }

    func testGroupNameRejectsEmptyAndWhitespaceOnly() {
        XCTAssertEqual(SoratomoTextRules.validateGroupName(""), .failure(.empty))
        XCTAssertEqual(SoratomoTextRules.validateGroupName(" \u{3000}\n\t"), .failure(.empty))
    }

    func testGroupNameCountsEmojiByCodePoints() {
        // 絵文字 30 個は 30（受け付ける）
        let thirtyEmoji = String(repeating: "🌅", count: 30)
        XCTAssertEqual(SoratomoTextRules.validateGroupName(thirtyEmoji), .success(thirtyEmoji))
        // 結合した絵文字 6 つ = 30 コードポイント（受け付ける）、7 つ = 35（拒否）
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(
            SoratomoTextRules.validateGroupName(String(repeating: family, count: 6)),
            .success(String(repeating: family, count: 6))
        )
        XCTAssertEqual(
            SoratomoTextRules.validateGroupName(String(repeating: family, count: 7)),
            .failure(.tooLong(max: 30))
        )
        // 結合文字の「か＋濁点」を 15 組 = 30（受け付ける）、16 組 = 32（拒否）。見た目は 15・16 文字
        let ga = "\u{304B}\u{3099}"
        XCTAssertEqual(
            SoratomoTextRules.validateGroupName(String(repeating: ga, count: 15)),
            .success(String(repeating: ga, count: 15))
        )
        XCTAssertEqual(
            SoratomoTextRules.validateGroupName(String(repeating: ga, count: 16)),
            .failure(.tooLong(max: 30))
        )
    }

    // MARK: - 表示名（1〜20 文字）

    func testDisplayNameAccepts20AndRejects21() {
        let twenty = String(repeating: "そ", count: 20)
        XCTAssertEqual(SoratomoTextRules.validateDisplayName(twenty).map(\.value), .success(twenty))
        XCTAssertEqual(
            SoratomoTextRules.validateDisplayName(twenty + "ら").map(\.value),
            .failure(.tooLong(max: 20))
        )
    }

    func testDisplayNameTrimsAndRejectsWhitespaceOnly() {
        XCTAssertEqual(SoratomoTextRules.validateDisplayName("\u{3000}そら\n").map(\.value), .success("そら"))
        XCTAssertEqual(SoratomoTextRules.validateDisplayName("\u{3000} ").map(\.value), .failure(.empty))
    }

    // MARK: - キャプション（改行を除いて 0〜100 文字）

    func testSanitizeCaptionRemovesAllNewlineKinds() {
        // LF・CR・CRLF・VT・FF・U+0085・U+2028・U+2029 をすべて取り除き、空白に置き換えずに詰める
        let raw = "朝\n焼\r\nけ\r空\u{000B}が\u{000C}き\u{0085}れ\u{2028}い\u{2029}だ"
        XCTAssertEqual(SoratomoTextRules.sanitizeCaption(raw), "朝焼け空がきれいだ")
    }

    func testSanitizeCaptionKeepsSpacesAndEmptyStaysEmpty() {
        XCTAssertEqual(SoratomoTextRules.sanitizeCaption(" 夕焼け 🌇 "), " 夕焼け 🌇 ")
        XCTAssertEqual(SoratomoTextRules.sanitizeCaption(""), "")
        XCTAssertEqual(SoratomoTextRules.sanitizeCaption("\n\n"), "")
    }

    func testCaptionLimitIs100CodePoints() {
        XCTAssertTrue(SoratomoTextRules.isCaptionWithinLimit(""))
        XCTAssertTrue(SoratomoTextRules.isCaptionWithinLimit(String(repeating: "あ", count: 100)))
        XCTAssertFalse(SoratomoTextRules.isCaptionWithinLimit(String(repeating: "あ", count: 101)))
        // 絵文字 100 個は 100（UTF-16 なら 200 だが、コードポイントで数えるので通る）
        XCTAssertTrue(SoratomoTextRules.isCaptionWithinLimit(String(repeating: "🌅", count: 100)))
        XCTAssertFalse(SoratomoTextRules.isCaptionWithinLimit(String(repeating: "🌅", count: 101)))
    }

    func testCaptionNewlinesAreRemovedBeforeCounting() {
        // 改行を含めると 101 文字でも、取り除いた後は 100 文字なので上限以内
        let raw = String(repeating: "あ", count: 50) + "\n" + String(repeating: "い", count: 50)
        let sanitized = SoratomoTextRules.sanitizeCaption(raw)
        XCTAssertEqual(SoratomoTextRules.length(sanitized), 100)
        XCTAssertTrue(SoratomoTextRules.isCaptionWithinLimit(sanitized))
    }
}
