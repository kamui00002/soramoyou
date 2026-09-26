//
//  PublicProfileRecommendedPostIdsTests.swift
//  SoramoyouTests
//
//  公開プロフィールの「おすすめの空」フィールド（recommendedPostIds）の読み書きのテスト ⭐️
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore

final class PublicProfileRecommendedPostIdsTests: XCTestCase {
    func testOldDataWithoutFieldReadsAsEmpty() throws {
        // 旧データ（フィールド無し）でも壊れずに読める
        let profile = try PublicProfile(from: ["id": "u1", "createdAt": Timestamp(date: Date())])
        XCTAssertEqual(profile.recommendedPostIds, [])
    }

    func testFieldIsReadInOrder() throws {
        let profile = try PublicProfile(from: ["id": "u1", "recommendedPostIds": ["C", "A", "B"]])
        XCTAssertEqual(profile.recommendedPostIds, ["C", "A", "B"])
    }

    func testDuplicatedIdsAreNormalizedOnRead() throws {
        let profile = try PublicProfile(from: ["id": "u1", "recommendedPostIds": ["A", "A", "B"]])
        XCTAssertEqual(profile.recommendedPostIds, ["A", "B"])
    }

    func testWrongTypeReadsAsEmpty() throws {
        let profile = try PublicProfile(from: ["id": "u1", "recommendedPostIds": "A"])
        XCTAssertEqual(profile.recommendedPostIds, [])
    }

    func testEmptyListIsNotWritten() {
        // 空のときはキーごと書かない（旧データと同じ形）
        let data = PublicProfile(id: "u1").toFirestoreData()
        XCTAssertNil(data["recommendedPostIds"])
    }

    func testNonEmptyListIsWritten() {
        let data = PublicProfile(id: "u1", recommendedPostIds: ["A", "B"]).toFirestoreData()
        XCTAssertEqual(data["recommendedPostIds"] as? [String], ["A", "B"])
    }

    func testProfileCreatedFromUserHasNoRecommendations() {
        XCTAssertEqual(PublicProfile(from: User(id: "u1")).recommendedPostIds, [])
    }
}
