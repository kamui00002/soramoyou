//
//  RankingDisplayTextTests.swift
//  SoramoyouTests
//
//  ランキング表示の文言（RankingDisplayText）とメダル（RankingMedal）のテスト ⭐️
//

import XCTest
@testable import Soramoyou

final class RankingDisplayTextTests: XCTestCase {
    // MARK: - 投稿者名

    func testAuthorNameFallsBackToUser() {
        // 未取得・空・空白だけの名前は「ユーザー」（他の画面と同じ表記）
        XCTAssertEqual(RankingDisplayText.authorName(nil), "ユーザー")
        XCTAssertEqual(RankingDisplayText.authorName(PublicProfile(id: "u", displayName: nil)), "ユーザー")
        XCTAssertEqual(RankingDisplayText.authorName(PublicProfile(id: "u", displayName: "  \n")), "ユーザー")
    }

    func testAuthorNameTrimsWhitespace() {
        XCTAssertEqual(RankingDisplayText.authorName(PublicProfile(id: "u", displayName: " そら ")), "そら")
    }

    // MARK: - 副題（場所 → キャプション）

    func testSubtitlePrefersMostSpecificPlace() {
        // ランドマーク → 市区町村 → 都道府県 の順で、いちばん具体的なものを 1 つ
        XCTAssertEqual(
            RankingDisplayText.subtitle(for: post(location: location(city: "横浜市", prefecture: "神奈川県", landmark: "みなとみらい"), caption: "夕焼け")),
            "みなとみらい"
        )
        XCTAssertEqual(
            RankingDisplayText.subtitle(for: post(location: location(city: "横浜市", prefecture: "神奈川県"), caption: "夕焼け")),
            "横浜市"
        )
        XCTAssertEqual(
            RankingDisplayText.subtitle(for: post(location: location(prefecture: "神奈川県"), caption: "夕焼け")),
            "神奈川県"
        )
    }

    func testSubtitleSkipsBlankPlaceAndUsesCaption() {
        // 空白だけの場所は無いものとして扱い、キャプションに進む
        XCTAssertEqual(
            RankingDisplayText.subtitle(for: post(location: location(city: "  ", landmark: ""), caption: "朝の雲")),
            "朝の雲"
        )
    }

    func testSubtitleJoinsCaptionLinesWithSpace() {
        // 1 行表示で途中が切れないよう、改行（空行を含む）を空白 1 つでつなぐ
        XCTAssertEqual(
            RankingDisplayText.subtitle(for: post(caption: "きれいな空\n\n#空 #雲")),
            "きれいな空 #空 #雲"
        )
    }

    func testSubtitleIsNilWhenNothingToShow() {
        XCTAssertNil(RankingDisplayText.subtitle(for: post()))
        XCTAssertNil(RankingDisplayText.subtitle(for: post(caption: " \n ")))
    }

    // MARK: - メダル

    func testMedalIsDecidedByRank() {
        XCTAssertEqual(RankingMedal(rank: 1), .gold)
        XCTAssertEqual(RankingMedal(rank: 2), .silver)
        XCTAssertEqual(RankingMedal(rank: 3), .bronze)
        XCTAssertNil(RankingMedal(rank: 4))
        XCTAssertNil(RankingMedal(rank: 0))
    }

    // MARK: - Helpers

    private func post(location: Location? = nil, caption: String? = nil) -> Post {
        Post(id: "P", userId: "u", images: [], caption: caption, location: location, visibility: .public)
    }

    private func location(city: String? = nil, prefecture: String? = nil, landmark: String? = nil) -> Location {
        Location(latitude: 35.0, longitude: 139.0, city: city, prefecture: prefecture, landmark: landmark)
    }
}
