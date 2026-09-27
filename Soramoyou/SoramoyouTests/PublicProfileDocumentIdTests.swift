//
//  PublicProfileDocumentIdTests.swift
//  SoramoyouTests
//
//  公開プロフィールの中の `id` がドキュメント ID（＝持ち主の uid）と一致するかのテスト ⭐️
//  （issue #133: 他人の uid を書いたプロフィールで、他人の投稿に自分の名前が付くのを防ぐ）
//

import XCTest
@testable import Soramoyou

final class PublicProfileDocumentIdTests: XCTestCase {
    func testMatchingIdIsAccepted() throws {
        let profile = try PublicProfile(from: ["id": "u1", "displayName": "そら"], documentId: "u1")
        XCTAssertEqual(profile.id, "u1")
        XCTAssertEqual(profile.displayName, "そら")
    }

    func testMismatchedIdIsRejected() {
        // 自分のドキュメント（u1）に他人の uid（u2）を書いたケース → 読み込みで弾く
        XCTAssertThrowsError(try PublicProfile(from: ["id": "u2", "displayName": "なりすまし"], documentId: "u1")) { error in
            XCTAssertEqual(error as? PublicProfileError, .idMismatch)
        }
    }

    func testMissingIdIsStillRejected() {
        // id が無いデータは従来どおり missingUserId で弾く
        XCTAssertThrowsError(try PublicProfile(from: ["displayName": "そら"], documentId: "u1")) { error in
            XCTAssertEqual(error as? PublicProfileError, .missingUserId)
        }
    }
}
