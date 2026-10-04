//
//  SoratomoInviteCodeTests.swift
//  SoramoyouTests
//
//  そらともの招待コード（SoratomoInviteCode）の正規化と表示のテスト ⭐️（tasks 10.3）
//

@testable import Soramoyou
import XCTest

final class SoratomoInviteCodeTests: XCTestCase {
    // MARK: - 字種（Functions と一致）

    func testAlphabetMatchesFunctions() {
        // ⚠️ functions/soratomoCore.js の INVITE_ALPHABET と同じ文字列であること（片方だけ変えない）
        XCTAssertEqual(SoratomoInviteCode.alphabet, "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        XCTAssertEqual(SoratomoInviteCode.alphabet.count, 32)
        XCTAssertEqual(SoratomoInviteCode.length, 8)
    }

    // MARK: - 正規化

    func testParseAcceptsNormalizedCode() {
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: "ABCDEFGH")?.rawValue, "ABCDEFGH")
    }

    func testParseUppercasesLowercase() {
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: "abcdefgh")?.rawValue, "ABCDEFGH")
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: "aBcD2345")?.rawValue, "ABCD2345")
    }

    func testParseConvertsFullWidthToHalfWidth() {
        // 全角の英字（大文字・小文字）と数字
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: "ＡＢＣＤｅｆｇｈ")?.rawValue, "ABCDEFGH")
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: "ＡＢＣＤ２３４５")?.rawValue, "ABCD2345")
    }

    func testParseIgnoresHyphensAndSpaces() {
        // 表示の形（4 文字ごとのハイフン）をそのまま貼り付けても通る
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: "ABCD-EFGH")?.rawValue, "ABCDEFGH")
        // 前後と途中の半角空白・全角空白・タブ・改行
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: " ABCD EFGH\n")?.rawValue, "ABCDEFGH")
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: "\u{3000}ABCD\u{3000}EFGH\t")?.rawValue, "ABCDEFGH")
    }

    func testParseIgnoresFullWidthAndJapaneseHyphens() {
        // 全角ハイフン（U+FF0D）・長音符（U+30FC：日本語入力のまま「-」を打ったとき）・半角の長音符（U+FF70）
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: "ABCD\u{FF0D}EFGH")?.rawValue, "ABCDEFGH")
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: "ABCD\u{30FC}EFGH")?.rawValue, "ABCDEFGH")
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: "ABCD\u{FF70}EFGH")?.rawValue, "ABCDEFGH")
        // ダッシュ類（U+2010〜U+2015）・マイナス（U+2212）・小さいハイフン（U+FE63）
        for scalar in ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}", "\u{FE63}"] {
            XCTAssertEqual(
                SoratomoInviteCode.parse(userInput: "ABCD\(scalar)EFGH")?.rawValue,
                "ABCDEFGH",
                "区切り \(scalar.unicodeScalars.map { String($0.value, radix: 16) }) を無視できていない"
            )
        }
    }

    func testParseHandlesMixedInput() {
        // 全角・小文字・ハイフン・空白・全角ハイフンが混ざった入力
        XCTAssertEqual(
            SoratomoInviteCode.parse(userInput: " ａｂｃｄ－ＥＦ gh\u{3000}")?.rawValue,
            "ABCDEFGH"
        )
        XCTAssertEqual(
            SoratomoInviteCode.parse(userInput: "ab\u{30FC}CD - ２3 ４５")?.rawValue,
            "ABCD2345"
        )
    }

    // MARK: - 拒否（サーバーへ問い合わせない）

    func testParseRejectsSevenAndNineCharacters() {
        XCTAssertNil(SoratomoInviteCode.parse(userInput: "ABCDEFG"))
        XCTAssertNil(SoratomoInviteCode.parse(userInput: "ABCD-EFG"))
        XCTAssertNil(SoratomoInviteCode.parse(userInput: "ABCDEFGHJ"))
        XCTAssertNil(SoratomoInviteCode.parse(userInput: "ABCD-EFGH-J"))
    }

    func testParseRejectsEmptyAndSeparatorsOnly() {
        XCTAssertNil(SoratomoInviteCode.parse(userInput: ""))
        XCTAssertNil(SoratomoInviteCode.parse(userInput: " - \u{3000}ー "))
    }

    func testParseRejectsCharactersOutsideAlphabet() {
        // 読み間違えやすい 0・O・1・I は字種に無い。似た文字へ補正せずに無効にする
        XCTAssertNil(SoratomoInviteCode.parse(userInput: "ABCDEFG0"))
        XCTAssertNil(SoratomoInviteCode.parse(userInput: "ABCDEFGO"))
        XCTAssertNil(SoratomoInviteCode.parse(userInput: "ABCDEFG1"))
        XCTAssertNil(SoratomoInviteCode.parse(userInput: "ABCDEFGI"))
        // 字種外の記号や日本語
        XCTAssertNil(SoratomoInviteCode.parse(userInput: "ABCDEFG_"))
        XCTAssertNil(SoratomoInviteCode.parse(userInput: "ABCDEFGあ"))
    }

    // MARK: - 表示

    func testDisplayTextInsertsHyphenEveryFourCharacters() {
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: "abcdefgh")?.displayText, "ABCD-EFGH")
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: "2345 6789")?.displayText, "2345-6789")
    }

    func testDisplayTextRoundTripsThroughParse() {
        // 表示の形を入力し直しても同じコードになる（共有された文面をそのまま貼り付けたとき）
        let code = SoratomoInviteCode.parse(userInput: "QRSTUVWX")
        XCTAssertNotNil(code)
        XCTAssertEqual(SoratomoInviteCode.parse(userInput: code?.displayText ?? ""), code)
    }
}
