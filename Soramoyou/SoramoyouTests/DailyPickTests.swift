//
//  DailyPickTests.swift
//  SoramoyouTests
//
//  「今日のおすすめのそらもよう」の文書の読み取り（DailyPick.parse）と、
//  候補の分類（DailyPickResolver）の単体テスト ⭐️
//  Firestore に触らない純関数だけを確かめる。
//
//  陽性対照（2026-10-26 予定・メインが流して記録する）
//  - DailyPickResolver.classify(post:) の `post.visibility == .public` の確認を外す（常に通す）と赤になるはずのテスト:
//      testClassifyFollowersPostIsSkip / testClassifyPrivatePostIsSkip
//  - DailyPick.parse の「/ を含むものを落とす」を外すと赤になるはずのテスト: testParseDropsIdsContainingSlash
//  - DailyPick.parse の重複除去を外すと赤になるはずのテスト: testParseDropsDuplicatesKeepingFirst
//  - DailyPick.parse の上限（maxCandidates）を外すと赤になるはずのテスト: testParseKeepsOnlyFirstFiveWhenMoreThanFive
//  - DailyPickResolver.classify(error:) を常に .skip にすると赤になるはずのテスト:
//      testClassifyErrorNetworkFailureIsStop / testClassifyErrorNonFirestoreServiceErrorIsStop
//  - 結果（2026-10-26・iPhone 18 Pro シミュレーター・22 本）:
//    1 回目（「/」を落とす確認だけを外す）: 赤 3 本＝testParseDropsIdsContainingSlash /
//      testParseFillsUpToFiveAfterDroppingInvalid / testParseReturnsNilWhenAllDropped。上の予言（1 本）は外れ。
//      残りの 2 本も入力に「/」入りの ID を含むので、赤になるのが正しい。
//    2 回目（public の確認・classify(error:) の stop・重複除去・上限の 4 か所を同時に外す）: 赤 7 本＝
//      testClassifyFollowersPostIsSkip / testClassifyPrivatePostIsSkip / testClassifyErrorNetworkFailureIsStop /
//      testClassifyErrorNonFirestoreServiceErrorIsStop / testParseDropsDuplicatesKeepingFirst /
//      testParseKeepsOnlyFirstFiveWhenMoreThanFive / testParseFillsUpToFiveAfterDroppingInvalid。ほかの 15 本は緑。
//      上限の予言（1 本）は外れ＝testParseFillsUpToFiveAfterDroppingInvalid も 6 件目まで読んでしまうので赤になる。
//    壊す前（同じ中身）は 22 本すべて緑
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

final class DailyPickTests: XCTestCase {
    // MARK: - parse

    /// 正常な 5 件がそのまま順番どおりに読める
    func testParseValidFiveIds() {
        let pick = DailyPick.parse(dateKey: "2026-10-25", data: ["postIds": ["a", "b", "c", "d", "e"]])
        XCTAssertEqual(pick?.dateKey, "2026-10-25")
        XCTAssertEqual(pick?.postIds, ["a", "b", "c", "d", "e"])
    }

    /// 文字列以外の要素は落ちる
    func testParseDropsNonStringElements() {
        let pick = DailyPick.parse(dateKey: "2026-10-25", data: ["postIds": ["a", 1, NSNull(), "b", true] as [Any]])
        XCTAssertEqual(pick?.postIds, ["a", "b"])
    }

    /// 空文字と空白だけの要素は落ちる
    func testParseDropsEmptyAndWhitespaceOnly() {
        let pick = DailyPick.parse(dateKey: "2026-10-25", data: ["postIds": ["", "a", "   ", "\n", "b"]])
        XCTAssertEqual(pick?.postIds, ["a", "b"])
    }

    /// 「/」を含む要素は落ちる（文書パスが壊れるため）
    func testParseDropsIdsContainingSlash() {
        let pick = DailyPick.parse(dateKey: "2026-10-25", data: ["postIds": ["a", "x/y", "/z", "b"]])
        XCTAssertEqual(pick?.postIds, ["a", "b"])
    }

    /// 重複は最初の 1 つだけ残る
    func testParseDropsDuplicatesKeepingFirst() {
        let pick = DailyPick.parse(dateKey: "2026-10-25", data: ["postIds": ["a", "b", "a", "c", "b"]])
        XCTAssertEqual(pick?.postIds, ["a", "b", "c"])
    }

    /// 6 件以上は先頭から 5 件
    func testParseKeepsOnlyFirstFiveWhenMoreThanFive() {
        let pick = DailyPick.parse(dateKey: "2026-10-25", data: ["postIds": ["a", "b", "c", "d", "e", "f", "g"]])
        XCTAssertEqual(pick?.postIds, ["a", "b", "c", "d", "e"])
    }

    /// 落ちた分は数に入れず、残った有効な要素で 5 件まで埋める
    func testParseFillsUpToFiveAfterDroppingInvalid() {
        let pick = DailyPick.parse(
            dateKey: "2026-10-25",
            data: ["postIds": ["", "a", "x/y", "b", "c", "d", "e", "f"]]
        )
        XCTAssertEqual(pick?.postIds, ["a", "b", "c", "d", "e"])
    }

    /// postIds が無ければ nil
    func testParseReturnsNilWhenPostIdsMissing() {
        XCTAssertNil(DailyPick.parse(dateKey: "2026-10-25", data: ["other": 1]))
    }

    /// postIds が配列でない（String）なら nil
    func testParseReturnsNilWhenPostIdsIsString() {
        XCTAssertNil(DailyPick.parse(dateKey: "2026-10-25", data: ["postIds": "a,b,c"]))
    }

    /// postIds が [Int] なら全部落ちて nil
    func testParseReturnsNilWhenPostIdsIsIntArray() {
        XCTAssertNil(DailyPick.parse(dateKey: "2026-10-25", data: ["postIds": [1, 2, 3]]))
    }

    /// 全部落ちたら nil
    func testParseReturnsNilWhenAllDropped() {
        XCTAssertNil(DailyPick.parse(dateKey: "2026-10-25", data: ["postIds": ["", "  ", "a/b"]]))
    }

    /// 空配列は nil
    func testParseReturnsNilWhenEmptyArray() {
        XCTAssertNil(DailyPick.parse(dateKey: "2026-10-25", data: ["postIds": [String]()]))
    }

    /// 前後の空白は落として使う
    func testParseTrimsSurroundingWhitespace() {
        let pick = DailyPick.parse(dateKey: "2026-10-25", data: ["postIds": [" a ", "b"]])
        XCTAssertEqual(pick?.postIds, ["a", "b"])
    }

    // MARK: - classify(post:)

    /// 公開で未ブロックは show
    func testClassifyPublicUnblockedIsShow() {
        let post = makePost(id: "p1", userId: "u1", visibility: .public)
        XCTAssertEqual(DailyPickResolver.classify(post: post, blockedUserIds: ["other"]), .show)
    }

    /// followers の投稿は skip（フォロー中だと read が通るので端末でも確かめる）
    func testClassifyFollowersPostIsSkip() {
        let post = makePost(id: "p1", userId: "u1", visibility: .followers)
        XCTAssertEqual(DailyPickResolver.classify(post: post, blockedUserIds: []), .skip)
    }

    /// private の投稿は skip
    func testClassifyPrivatePostIsSkip() {
        let post = makePost(id: "p1", userId: "u1", visibility: .private)
        XCTAssertEqual(DailyPickResolver.classify(post: post, blockedUserIds: []), .skip)
    }

    /// ブロック中の投稿者は skip
    func testClassifyBlockedAuthorIsSkip() {
        let post = makePost(id: "p1", userId: "u1", visibility: .public)
        XCTAssertEqual(DailyPickResolver.classify(post: post, blockedUserIds: ["u1", "u2"]), .skip)
    }

    // MARK: - classify(error:)

    /// 削除済み（notFound）は skip
    func testClassifyErrorNotFoundIsSkip() {
        XCTAssertEqual(DailyPickResolver.classify(error: FirestoreServiceError.notFound), .skip)
    }

    /// permissionDenied の fetchFailed は skip
    func testClassifyErrorPermissionDeniedIsSkip() {
        let underlying = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)
        XCTAssertEqual(DailyPickResolver.classify(error: FirestoreServiceError.fetchFailed(underlying)), .skip)
    }

    /// 壊れた投稿（PostModelError）の fetchFailed は skip
    func testClassifyErrorPostModelErrorIsSkip() {
        let error = FirestoreServiceError.fetchFailed(PostModelError.missingRequiredFields)
        XCTAssertEqual(DailyPickResolver.classify(error: error), .skip)
    }

    /// ネットワーク断に見立てた別の code の fetchFailed は stop
    func testClassifyErrorNetworkFailureIsStop() {
        let underlying = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.unavailable.rawValue)
        XCTAssertEqual(DailyPickResolver.classify(error: FirestoreServiceError.fetchFailed(underlying)), .stop)
    }

    /// FirestoreServiceError 以外のエラーは stop
    func testClassifyErrorNonFirestoreServiceErrorIsStop() {
        let error = NSError(domain: "test", code: FirestoreErrorCode.permissionDenied.rawValue)
        XCTAssertEqual(DailyPickResolver.classify(error: error), .stop)
    }

    // MARK: - ヘルパー

    /// テスト用の最小限の Post を作る
    private func makePost(id: String, userId: String, visibility: Visibility) -> Post {
        Post(
            id: id,
            userId: userId,
            images: [ImageInfo(url: "https://example.com/\(id).jpg", width: 100, height: 100, order: 0)],
            visibility: visibility
        )
    }
}
