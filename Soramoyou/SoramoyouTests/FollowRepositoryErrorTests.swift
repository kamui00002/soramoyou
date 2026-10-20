//
//  FollowRepositoryErrorTests.swift
//  SoramoyouTests
//
//  フォローがサーバーに断られたときのエラーの写し方のテスト ⭐️（C 項目 2）
//
//  ブロックしている／されている相手へのフォローは Firestore Rules が権限で断る。
//  そのとき Firebase の英語の文（Missing or insufficient permissions. など）を画面に出さないよう、
//  FollowRepository.mapFollowError が日本語の case に写すことを確かめる。
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

final class FollowRepositoryErrorTests: XCTestCase {
    func testPermissionDeniedBecomesFollowNotAllowed() {
        let denied = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)
        let mapped = FollowRepository.mapFollowError(denied)
        XCTAssertEqual(mapped as? FollowRepositoryError, .followNotAllowed)
        // 画面に出る文（10/19 ユーザー承認）。理由（ブロック）は言わない
        XCTAssertEqual(mapped.userFriendlyMessage, "フォローできませんでした")
    }

    func testOtherFirestoreErrorsPassThrough() {
        // 通信の失敗などは写さない（今の扱いのまま）
        let unavailable = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.unavailable.rawValue)
        let mapped = FollowRepository.mapFollowError(unavailable) as NSError
        XCTAssertEqual(mapped.domain, FirestoreErrorDomain)
        XCTAssertEqual(mapped.code, FirestoreErrorCode.unavailable.rawValue)
    }

    func testSameCodeInOtherDomainPassesThrough() {
        // Firestore の permissionDenied と同じ番号（7）でも、ドメインが違えば写さない
        let other = NSError(domain: "OtherDomain", code: FirestoreErrorCode.permissionDenied.rawValue)
        let mapped = FollowRepository.mapFollowError(other) as NSError
        XCTAssertEqual(mapped.domain, "OtherDomain")
        XCTAssertEqual(mapped.code, FirestoreErrorCode.permissionDenied.rawValue)
    }
}
