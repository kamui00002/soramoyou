//
//  ProfileOwnerNameTests.swift ⭐️
//  SoramoyouTests
//
//  他人のプロフィールの欄の題で持ち主を呼ぶ言い方（`ProfileOwnerName`・1.18.0 PR-B）のテスト
//  - 名前があれば「○○さんの」・名前が無い（nil・空文字・空白や改行だけ）なら「空が好きなだれかの」
//  - 前後に空白がある名前は、空白を落としてから「さんの」を付ける（これまでの 3 か所の題と同じ）
//  期待する文はすべて直に書く（`fallback` から組み立てた値と比べて緑にしない）。
//

@testable import Soramoyou
import XCTest

final class ProfileOwnerNameTests: XCTestCase {
    // MARK: - 名前がある

    /// 名前がある →「○○さんの」
    func testPossessive_名前があればさんのを付ける() {
        XCTAssertEqual(ProfileOwnerName.possessive("そら"), "そらさんの")
    }

    /// 前後に空白や改行がある名前 → 落としてから「さんの」を付ける（題に余計な空白を出さない）
    func testPossessive_前後の空白と改行は落とす() {
        XCTAssertEqual(ProfileOwnerName.possessive("  そら \n"), "そらさんの")
    }

    /// 名前の途中の空白は落とさない（前後だけ）
    func testPossessive_名前の途中の空白は残す() {
        XCTAssertEqual(ProfileOwnerName.possessive("そら もよう"), "そら もようさんの")
    }

    // MARK: - 名前が無い

    /// nil →「空が好きなだれかの」
    func testPossessive_nilならだれかの() {
        XCTAssertEqual(ProfileOwnerName.possessive(nil), "空が好きなだれかの")
    }

    /// 空文字 →「空が好きなだれかの」
    func testPossessive_空文字ならだれかの() {
        XCTAssertEqual(ProfileOwnerName.possessive(""), "空が好きなだれかの")
    }

    /// 空白と改行だけ →「空が好きなだれかの」（名前の抜けた「さんの」を出さない）
    func testPossessive_空白と改行だけならだれかの() {
        XCTAssertEqual(ProfileOwnerName.possessive("  \n"), "空が好きなだれかの")
    }

    // MARK: - 呼び方そのもの

    /// 表示名が無い人の呼び方（2026-10-24 利用者の決定）
    func testFallback_空が好きなだれか() {
        XCTAssertEqual(ProfileOwnerName.fallback, "空が好きなだれか")
    }

    // MARK: - 題の形（使い方どおりにつないだとき）

    /// 題の形: 名前あり・なしの両方で、3 か所が組み立てるのと同じつなぎ方をしたときの文
    func testPossessive_題につなぐと期待どおりの文になる() {
        XCTAssertEqual(ProfileOwnerName.possessive("そら") + "空カレンダー", "そらさんの空カレンダー")
        XCTAssertEqual(ProfileOwnerName.possessive("そら") + "お気に入りの空", "そらさんのお気に入りの空")
        XCTAssertEqual(ProfileOwnerName.possessive(nil) + "空カレンダー", "空が好きなだれかの空カレンダー")
        XCTAssertEqual(ProfileOwnerName.possessive(" ") + "お気に入りの空", "空が好きなだれかのお気に入りの空")
    }
}
