//
//  SettingsViewDeleteAccountMessageTests.swift
//  SoramoyouTests
//
//  退会（アカウント削除）の確認の文のテスト ⭐️（soratomo-public-launch 6.3・要件 2.4・2.5）
//

@testable import Soramoyou
import XCTest

final class SettingsViewDeleteAccountMessageTests: XCTestCase {
    /// そらともを使える人に足す 1 文（release-gate 9.4 の文。ここが変わったら、審査メモと G5 の文も見直す）
    private let soratomoSentence = "そらともの投稿（写真を含む）とグループへの参加も削除されます。"

    /// 今までの文（そらともに関係なく出す部分）
    private let baseSentence = "アカウントを削除すると、すべての投稿・下書き・プロフィール情報が完全に削除されます。この操作は取り消せません。"

    func testEnabledAddsSoratomoSentence() {
        // そらともを使える（登録済みでログイン）なら、そらとものデータも消えることを 1 文足す
        let message = SettingsView.deleteAccountConfirmationMessage(isSoratomoEnabled: true)
        XCTAssertEqual(message, baseSentence + soratomoSentence)
    }

    func testDisabledKeepsBaseMessage() {
        // 使えない（匿名・判定前）なら、今までの文のまま
        let message = SettingsView.deleteAccountConfirmationMessage(isSoratomoEnabled: false)
        XCTAssertEqual(message, baseSentence)
        XCTAssertFalse(message.contains("そらとも"))
    }
}
