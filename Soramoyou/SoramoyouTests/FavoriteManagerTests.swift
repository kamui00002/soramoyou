//
//  FavoriteManagerTests.swift
//  SoramoyouTests
//
//  お気に入り（🔖）状態管理の ViewModel テスト。⭐️
//  最小 Mock（setFavorite / batchCheckFavoriteStatus のみ上書き、
//  残りは FirestoreServiceProtocol+TestDefaults）で検証。
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore

@MainActor
final class FavoriteManagerTests: XCTestCase {

    // MARK: - Helpers

    /// ログイン済みの Manager を組み立てる
    private func makeManager(
        firestore: MockFirestoreServiceForFavorites,
        userId: String? = "me"
    ) -> FavoriteManager {
        let auth = MockAuthService()
        if let userId {
            auth.currentUserValue = User(id: userId)
        }
        return FavoriteManager(firestoreService: firestore, authService: auth)
    }

    private func makePost(id: String, userId: String = "other") -> Post {
        Post(id: id, userId: userId, images: [])
    }

    // MARK: - Tests

    /// 1. ログイン済みでトグルすると、お気に入りに入り setFavorite(true) が1回呼ばれる
    func testToggleAddsFavoriteAndCallsService() async {
        let mock = MockFirestoreServiceForFavorites()
        let manager = makeManager(firestore: mock)

        await manager.toggleFavorite(post: makePost(id: "p1"), source: "home_card")

        XCTAssertTrue(manager.isFavorited("p1"))
        XCTAssertEqual(mock.setFavoriteCalls.count, 1)
        XCTAssertEqual(mock.setFavoriteCalls.first?.postId, "p1")
        XCTAssertEqual(mock.setFavoriteCalls.first?.userId, "me")
        XCTAssertEqual(mock.setFavoriteCalls.first?.isFavorited, true)
    }

    /// 2. もう一度トグルすると外れて setFavorite(false) が呼ばれる
    func testToggleTwiceRemovesFavorite() async {
        let mock = MockFirestoreServiceForFavorites()
        let manager = makeManager(firestore: mock)
        let post = makePost(id: "p1")

        await manager.toggleFavorite(post: post, source: "home_card")
        await manager.toggleFavorite(post: post, source: "home_card")

        XCTAssertFalse(manager.isFavorited("p1"))
        XCTAssertEqual(mock.setFavoriteCalls.count, 2)
        XCTAssertEqual(mock.setFavoriteCalls.last?.isFavorited, false)
    }

    /// 3. 書き込みが失敗したらローカル状態をリバートする（UIが嘘をつかない）
    func testToggleRevertsOnFailure() async {
        let mock = MockFirestoreServiceForFavorites()
        mock.setFavoriteError = NSError(domain: "test", code: 1)
        let manager = makeManager(firestore: mock)

        await manager.toggleFavorite(post: makePost(id: "p1"), source: "home_card")

        XCTAssertEqual(mock.setFavoriteCalls.count, 1, "サービスを呼んだ上で失敗したことを確かめる")
        XCTAssertEqual(mock.setFavoriteCalls.first?.isFavorited, true)
        XCTAssertFalse(manager.isFavorited("p1"), "失敗したらお気に入りに残ってはいけない")
        XCTAssertFalse(manager.showLoginPrompt, "書き込み失敗はログイン要求ではない")
    }

    /// 4. 未ログインならログインプロンプトを立て、サービスを呼ばない
    func testToggleWithoutLoginShowsPrompt() async {
        let mock = MockFirestoreServiceForFavorites()
        let manager = makeManager(firestore: mock, userId: nil)

        await manager.toggleFavorite(post: makePost(id: "p1"), source: "home_card")

        XCTAssertTrue(manager.showLoginPrompt)
        XCTAssertTrue(mock.setFavoriteCalls.isEmpty)
        XCTAssertFalse(manager.isFavorited("p1"))
    }

    /// 5. checkFavoriteStatus は問い合わせた範囲をサーバー値で「上書き」する
    ///    （formUnion だけの実装では、サーバーに無いローカル残骸が消えない）
    func testCheckFavoriteStatusOverwritesQueriedRange() async {
        let mock = MockFirestoreServiceForFavorites()
        let manager = makeManager(firestore: mock)

        // p1 をローカルでお気に入りにしておく（サーバーには無い状態を作る）
        await manager.toggleFavorite(post: makePost(id: "p1"), source: "home_card")
        XCTAssertTrue(manager.isFavorited("p1"))

        // サーバーは p2 だけがお気に入り、と答える
        mock.stubbedFavoritedIds = ["p2"]
        await manager.checkFavoriteStatus(for: [makePost(id: "p1"), makePost(id: "p2")])

        XCTAssertFalse(manager.isFavorited("p1"), "サーバーに無い id は消える")
        XCTAssertTrue(manager.isFavorited("p2"), "サーバーにある id は入る")
    }

    /// 6. サインアウトでローカル状態が空になる ⭐️
    ///
    /// Manager は App レベルの @StateObject でサインアウトしても破棄されない。
    /// お気に入りは「自分だけが見られる」プライベート保存なので、共有端末で
    /// 次のユーザーに前のユーザーの🔖が塗られて見えてはいけない。
    func testClearOnSignOutEmptiesLocalState() async {
        let mock = MockFirestoreServiceForFavorites()
        let manager = makeManager(firestore: mock)

        await manager.toggleFavorite(post: makePost(id: "p1"), source: "home_card")
        manager.registerFavorited(postIds: ["p2", "p3"])
        XCTAssertTrue(manager.isFavorited("p1"))

        manager.clearOnSignOut()

        XCTAssertFalse(manager.isFavorited("p1"))
        XCTAssertFalse(manager.isFavorited("p2"))
        XCTAssertFalse(manager.isFavorited("p3"))
        XCTAssertFalse(manager.showLoginPrompt)
    }

    /// 5-b. 問い合わせていない postId は触らない（ページング追加読み込みで既存状態を壊さない）
    func testCheckFavoriteStatusKeepsUnqueriedIds() async {
        let mock = MockFirestoreServiceForFavorites()
        let manager = makeManager(firestore: mock)

        manager.registerFavorited(postIds: ["keep"])

        mock.stubbedFavoritedIds = []
        await manager.checkFavoriteStatus(for: [makePost(id: "p1")])

        XCTAssertTrue(manager.isFavorited("keep"), "問い合わせ範囲外は保持される")
    }
}

// MARK: - Mock

final class MockFirestoreServiceForFavorites: FirestoreServiceProtocol {
    /// setFavorite の呼び出し記録
    private(set) var setFavoriteCalls: [(postId: String, userId: String, isFavorited: Bool)] = []
    /// setFavorite で投げるエラー（nil なら成功）
    var setFavoriteError: Error?
    /// batchCheckFavoriteStatus が返すID集合
    var stubbedFavoritedIds: Set<String> = []

    func setFavorite(postId: String, userId: String, isFavorited: Bool) async throws {
        // ⚠️ 記録は throw より**前**に行う。
        //    後ろに置くと失敗ケースで記録が残らず、「呼ばれて失敗した」と
        //    「そもそも呼ばれなかった」をテストが区別できなくなる。
        setFavoriteCalls.append((postId: postId, userId: userId, isFavorited: isFavorited))
        if let setFavoriteError { throw setFavoriteError }
    }

    func batchCheckFavoriteStatus(postIds: [String], userId _: String) async throws -> Set<String> {
        // 問い合わせた範囲に絞って返す（本物と同じ振る舞い）
        stubbedFavoritedIds.intersection(postIds)
    }
}
