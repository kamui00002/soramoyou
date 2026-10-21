//
//  SoratomoReactionKindTests.swift
//  SoramoyouTests
//
//  そらとものリアクションの 7 種類の絵文字のテスト ⭐️（soratomo-reactions tasks 7.1）
//
//  ⚠️ 期待値は functions/soratomoCore.test.js の EXPECTED_REACTION_KINDS と同じ値にすること（片方だけ変えない）。
//     絵文字は文字列で比べると、見えない U+FE0F が実装とテストの両方から落ちても緑のままになるので、
//     コードポイントの数値と UTF-16 の単位数で固定する。
//

@testable import Soramoyou
import XCTest

final class SoratomoReactionKindTests: XCTestCase {
    /// 1 行分の期待値（design.md「絵文字のセット」の表）
    private struct Expected {
        /// 名前（保存・計測の `kind`）
        let name: String
        /// 絵文字のコードポイント（FE0F を含む）
        let codePoints: [UInt32]
        /// UTF-16 の単位数
        let utf16: Int
        /// VoiceOver の日本語名
        let spokenName: String
    }

    /// 並び順どおりの 7 行
    private let expected: [Expected] = [
        Expected(name: "sunset", codePoints: [0x1F305], utf16: 2, spokenName: "夕焼け"),
        Expected(name: "cloud", codePoints: [0x2601, 0xFE0F], utf16: 2, spokenName: "くも"),
        Expected(name: "rainbow", codePoints: [0x1F308], utf16: 2, spokenName: "虹"),
        Expected(name: "sparkles", codePoints: [0x2728], utf16: 1, spokenName: "きれい"),
        Expected(name: "eyes", codePoints: [0x1F440], utf16: 2, spokenName: "見たよ"),
        Expected(name: "red_heart", codePoints: [0x2764, 0xFE0F], utf16: 2, spokenName: "赤いハート"),
        Expected(name: "blue_heart", codePoints: [0x1F499], utf16: 2, spokenName: "青いハート"),
    ]

    // MARK: - 並びと名前

    func testOrderAndNamesMatchFunctions() {
        // 並びはメニューと数の表示の順。名前は Functions の REACTION_KINDS の name と同じ
        XCTAssertEqual(
            SoratomoReactionKind.allCases.map(\.rawValue),
            ["sunset", "cloud", "rainbow", "sparkles", "eyes", "red_heart", "blue_heart"]
        )
        XCTAssertEqual(SoratomoReactionKind.allCases.map(\.rawValue), expected.map(\.name))
    }

    func testNamesAreLowerSnakeCase() {
        // 計測の kind は英小文字のスネークケース（要件 15.4）
        for kind in SoratomoReactionKind.allCases {
            XCTAssertNotNil(kind.rawValue.range(of: "^[a-z]+(_[a-z]+)*$", options: .regularExpression), kind.rawValue)
        }
    }

    func testRawValueAcceptsOnlyTheSevenNames() {
        XCTAssertEqual(SoratomoReactionKind(rawValue: "red_heart"), .redHeart)
        XCTAssertEqual(SoratomoReactionKind(rawValue: "blue_heart"), .blueHeart)
        // Swift のケース名・大文字・絵文字そのものは名前として受けない
        XCTAssertNil(SoratomoReactionKind(rawValue: "redHeart"))
        XCTAssertNil(SoratomoReactionKind(rawValue: "SUNSET"))
        XCTAssertNil(SoratomoReactionKind(rawValue: "\u{1F305}"))
        XCTAssertNil(SoratomoReactionKind(rawValue: ""))
    }

    // MARK: - 絵文字

    func testEmojiCodePointsIncludeVariationSelector() {
        // zip が短い方で黙って止まらないよう、先に件数をそろえる
        XCTAssertEqual(SoratomoReactionKind.allCases.count, 7)
        XCTAssertEqual(SoratomoReactionKind.allCases.count, expected.count)
        for (kind, row) in zip(SoratomoReactionKind.allCases, expected) {
            XCTAssertEqual(kind.emoji.unicodeScalars.map(\.value), row.codePoints, row.name)
            XCTAssertEqual(kind.emoji.utf16.count, row.utf16, row.name)
        }
    }

    func testEachEmojiIsOneCharacter() {
        // FE0F 付きでも 1 文字（書記素クラスター）として見える
        for kind in SoratomoReactionKind.allCases {
            XCTAssertEqual(kind.emoji.count, 1, kind.rawValue)
        }
    }

    // MARK: - VoiceOver の日本語名

    func testSpokenNames() {
        XCTAssertEqual(SoratomoReactionKind.allCases.count, expected.count)
        for (kind, row) in zip(SoratomoReactionKind.allCases, expected) {
            XCTAssertEqual(kind.spokenName, row.spokenName, row.name)
        }
    }
}
