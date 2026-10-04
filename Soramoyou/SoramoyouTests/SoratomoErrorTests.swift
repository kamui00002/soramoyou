//
//  SoratomoErrorTests.swift
//  SoramoyouTests
//
//  そらともの失敗の文言（SoratomoError.userMessage）のテスト ⭐️（tasks 10.2）
//
//  期待値は design.md の Error Categories の表を写したもの。
//

@testable import Soramoyou
import XCTest

final class SoratomoErrorTests: XCTestCase {
    private let generic = "うまくいきませんでした。時間をおいてもう一度お試しください"

    func testUserMessagesMatchDesignTable() {
        let expected: [SoratomoError: String] = [
            .network: "通信できませんでした。インターネットにつながる場所でもう一度お試しください",
            .invalidName: "グループ名は1〜30文字で入力してください",
            .invalidFormat: "招待コードは8文字です（例: ABCD-EFGH）",
            .notFound: "招待コードが見つかりません",
            .groupFull: "このグループは満員です（20人）",
            .userLimit: "参加できるグループは10個までです",
            .dailyLimit: "1日に投稿できるのは1つのグループにつき20件までです",
            .notMember: "グループを開けませんでした",
            .captionTooLong: "キャプションは100文字までです",
            .imageUnreadable: "この写真は使えません。別の写真を選んでください",
            .imageTooLarge: "この写真は大きすぎて送れません",
            .displayNameInvalid: "表示名は1〜20文字で入力してください",
            .flagOff: generic,
            .notOwner: generic,
            .permissionDenied: generic,
            .uploadTimeout: generic,
            .backgroundExpired: generic,
            .unknown: generic,
        ]
        // すべての種類に文言がある（種類を足したら、表とこのテストにも足す）
        XCTAssertEqual(Set(expected.keys), Set(SoratomoError.allCases))
        for error in SoratomoError.allCases {
            XCTAssertEqual(error.userMessage, expected[error], "\(error)")
        }
    }

    func testUserMessagesDoNotExposeInternalCodes() {
        // 内部のエラーコードや英語の識別子を画面に出さない（要件 12.5）
        for error in SoratomoError.allCases {
            let message = error.userMessage
            XCTAssertFalse(message.contains("_"), "\(error): \(message)")
            XCTAssertNil(message.range(of: "[a-z]{3,}", options: .regularExpression), "\(error): \(message)")
        }
    }

    func testNumbersInMessagesMatchLimits() {
        // 文言の数字と上限の定数を合わせる（片方だけ変えると、画面の案内と実際の判定が食い違う）
        XCTAssertTrue(SoratomoError.invalidName.userMessage.contains("1〜\(SoratomoTextRules.groupNameMax)文字"))
        XCTAssertTrue(SoratomoError.displayNameInvalid.userMessage.contains("1〜\(SoratomoTextRules.displayNameMax)文字"))
        XCTAssertTrue(SoratomoError.captionTooLong.userMessage.contains("\(SoratomoTextRules.captionMax)文字"))
        XCTAssertTrue(SoratomoError.invalidFormat.userMessage.contains("\(SoratomoInviteCode.length)文字"))
    }
}
