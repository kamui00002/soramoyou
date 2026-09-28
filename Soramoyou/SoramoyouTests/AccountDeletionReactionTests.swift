//
//  AccountDeletionReactionTests.swift
//  SoramoyouTests
//
//  退会時に likes / comments を消すときの判定の単体テスト ⭐️（issue #130）
//
//  FirestoreService.deleteReaction は Firestore に書き込むので単体では動かせないが、
//  壊れやすい判定 2 つは純粋な static 関数に切り出してあるので、ここで固定する:
//    ① 投稿のカウンタを減らしてよいか（存在し、1 以上のときだけ）
//    ② 失敗を「投稿が読めない/書けない」として次の段へ進めてよいか
//       （permission-denied / not-found だけ。ネットワーク断などは退会を止める）
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

final class AccountDeletionReactionTests: XCTestCase {
    // MARK: - shouldDecrementCounter

    /// 投稿があり、カウンタが 1 以上なら減らす
    func testDecrementsWhenPostExistsAndCountIsPositive() {
        XCTAssertTrue(FirestoreService.shouldDecrementCounter(postExists: true, currentCount: 1))
        XCTAssertTrue(FirestoreService.shouldDecrementCounter(postExists: true, currentCount: 42))
    }

    /// カウンタが 0 なら減らさない（マイナスにしない）
    func testDoesNotDecrementWhenCountIsZero() {
        XCTAssertFalse(FirestoreService.shouldDecrementCounter(postExists: true, currentCount: 0))
    }

    /// カウンタが既にマイナスにズレていても、さらに減らさない
    func testDoesNotDecrementWhenCountIsNegative() {
        XCTAssertFalse(FirestoreService.shouldDecrementCounter(postExists: true, currentCount: -1))
    }

    /// カウンタのフィールドが無い旧データは 0 扱い＝減らさない
    func testDoesNotDecrementWhenCountFieldIsMissing() {
        XCTAssertFalse(FirestoreService.shouldDecrementCounter(postExists: true, currentCount: nil))
    }

    /// 投稿が無ければ減らさない（updateData は存在しない文書で失敗するため）
    func testDoesNotDecrementWhenPostDoesNotExist() {
        XCTAssertFalse(FirestoreService.shouldDecrementCounter(postExists: false, currentCount: 3))
        XCTAssertFalse(FirestoreService.shouldDecrementCounter(postExists: false, currentCount: nil))
    }

    // MARK: - isPostUnreachableError

    /// permission-denied（削除済み・非公開・フォロワー限定で読めない投稿）は次の段へ進む
    func testPermissionDeniedIsUnreachable() {
        let error = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)
        XCTAssertTrue(FirestoreService.isPostUnreachableError(error))
    }

    /// not-found（消えた投稿への updateData）は次の段へ進む
    func testNotFoundIsUnreachable() {
        let error = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.notFound.rawValue)
        XCTAssertTrue(FirestoreService.isPostUnreachableError(error))
    }

    /// ネットワーク断は次の段へ進めない（退会を止めて再試行させる）
    func testUnavailableIsNotUnreachable() {
        let error = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.unavailable.rawValue)
        XCTAssertFalse(FirestoreService.isPostUnreachableError(error))
    }

    /// 別ドメインで同じ数値コードのエラーを取り違えない
    func testSameCodeInOtherDomainIsNotUnreachable() {
        let error = NSError(domain: NSURLErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)
        XCTAssertFalse(FirestoreService.isPostUnreachableError(error))
    }
}
