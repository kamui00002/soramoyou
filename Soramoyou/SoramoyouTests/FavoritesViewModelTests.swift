//
//  FavoritesViewModelTests.swift
//  SoramoyouTests
//
//  「私のお気に入りの空」一覧 ViewModel のテスト。⭐️
//  最小 Mock（fetchFavorites / fetchPost のみ上書き）で検証。
//
//  この画面の肝は「1件ずつ fetchPost して、落ちた1件で全体を巻き込まない」こと。
//  そのため失敗の分類（削除済み・非公開化 → 表示しない ／ ネットワーク → エラー表示）を重点的に見る。
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore

@MainActor
final class FavoritesViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeFavorites(_ ids: [String]) -> [Favorite] {
        // createdAt は新しい順（先頭が最新）になるように降順で振る
        ids.enumerated().map { index, id in
            Favorite(postId: id, createdAt: Date(timeIntervalSince1970: Double(1000 - index)))
        }
    }

    private func makePost(_ id: String) -> Post {
        Post(id: id, userId: "u1", images: [])
    }

    /// 非公開化・フォロー解除で読めなくなった状態（permissionDenied）を再現する
    private func permissionDeniedError() -> Error {
        FirestoreServiceError.fetchFailed(
            NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)
        )
    }

    // MARK: - Tests

    /// 1. favorites の順序が posts に保たれる（fetchPost は並列なので順序保持は VM の責務）
    func testLoadPreservesFavoriteOrder() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.stubbedFavoritePages = [makeFavorites(["p1", "p2", "p3"])]
        mock.postsById = ["p1": makePost("p1"), "p2": makePost("p2"), "p3": makePost("p3")]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2", "p3"])
        XCTAssertEqual(viewModel.unavailableCount, 0)
        XCTAssertNil(viewModel.lastError)
    }

    /// 2. 削除済み（notFound）の投稿は落ちて unavailableCount に数えられ、他は表示される
    func testDeletedPostIsCountedAsUnavailable() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.stubbedFavoritePages = [makeFavorites(["p1", "gone", "p3"])]
        mock.postsById = ["p1": makePost("p1"), "p3": makePost("p3")]
        mock.failingPostIds = ["gone": FirestoreServiceError.notFound]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p3"])
        XCTAssertEqual(viewModel.unavailableCount, 1)
        XCTAssertNil(viewModel.lastError, "1件落ちただけで画面全体をエラーにしない")
    }

    /// 3. 非公開化（permissionDenied）も unavailable 扱い
    func testPermissionDeniedIsCountedAsUnavailable() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.stubbedFavoritePages = [makeFavorites(["p1", "hidden"])]
        mock.postsById = ["p1": makePost("p1")]
        mock.failingPostIds = ["hidden": permissionDeniedError()]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1"])
        XCTAssertEqual(viewModel.unavailableCount, 1)
        XCTAssertNil(viewModel.lastError)
    }

    /// 4. 全件が一時的な失敗（ネットワーク等）なら「0件」と嘘をつかずエラーにする
    func testAllTransientFailuresSurfaceError() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.stubbedFavoritePages = [makeFavorites(["p1", "p2"])]
        let networkError = FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009))
        mock.failingPostIds = ["p1": networkError, "p2": networkError]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)

        await viewModel.load()

        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertNotNil(viewModel.lastError, "一時的な失敗を『0件』と表示してはいけない")
    }

    /// 5. pageSize ちょうどなら hasMore が立ち、loadMore で追記され、
    ///    2ページ目が pageSize 未満になったら hasMore が倒れる
    func testPaginationAppendsAndStops() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.stubbedFavoritePages = [
            makeFavorites(["p1", "p2"]),   // 1ページ目 = pageSize(2) ちょうど
            makeFavorites(["p3"])          // 2ページ目 = pageSize 未満
        ]
        mock.postsById = ["p1": makePost("p1"), "p2": makePost("p2"), "p3": makePost("p3")]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 2)

        await viewModel.load()
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"])
        XCTAssertTrue(viewModel.hasMore)

        await viewModel.loadMore()
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2", "p3"])
        XCTAssertFalse(viewModel.hasMore)

        // カーソルの受け渡しを検証する（「追記された」だけでは、カーソルが
        // 進んでいなくても・巻き戻っていてもテストは緑になってしまう）
        XCTAssertEqual(mock.receivedAfterValues.count, 2)
        XCTAssertNil(mock.receivedAfterValues.first ?? nil, "1ページ目は先頭から取る（カーソルなし）")
        XCTAssertEqual(
            mock.receivedAfterValues.last ?? nil,
            mock.stubbedFavoritePages[0].last?.createdAt,
            "2ページ目は1ページ目末尾の createdAt から続ける"
        )
    }

    /// 6. syncFavorited(ids:) で、お気に入りから外れた投稿だけが消える
    func testSyncFavoritedDropsUnfavoritedOnly() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.stubbedFavoritePages = [makeFavorites(["p1", "p2", "p3"])]
        mock.postsById = ["p1": makePost("p1"), "p2": makePost("p2"), "p3": makePost("p3")]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)
        await viewModel.load()

        // p2 を詳細画面で解除したことにする
        viewModel.syncFavorited(ids: ["p1", "p3"])

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p3"])
    }

    /// 7. お気に入りに戻った投稿が、元の位置へ戻る ⭐️
    ///
    /// 起きうる場面は2つとも実在する:
    ///   - 解除の書き込みが失敗して FavoriteManager がローカルをリバートした
    ///   - ユーザーが誤タップに気づいてすぐ押し直した
    /// 削除しかしない実装だと、どちらでも「お気に入りのままなのに一覧から消えた」まま
    /// pull-to-refresh するまで直らない。
    func testSyncFavoritedRestoresPostAtOriginalPosition() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.stubbedFavoritePages = [makeFavorites(["p1", "p2", "p3"])]
        mock.postsById = ["p1": makePost("p1"), "p2": makePost("p2"), "p3": makePost("p3")]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)
        await viewModel.load()

        viewModel.syncFavorited(ids: ["p1", "p3"])
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p3"])

        // 書き込み失敗のリバート（または押し直し）で p2 がお気に入りへ戻る
        viewModel.syncFavorited(ids: ["p1", "p2", "p3"])

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2", "p3"], "末尾ではなく元の位置へ戻る")
    }
}

// MARK: - Mock

final class MockFirestoreServiceForFavoritesList: FirestoreServiceProtocol {
    /// fetchFavorites が順に返すページ（どのページを返すかはカーソルではなく呼び出し順で決める）
    var stubbedFavoritePages: [[Favorite]] = []
    /// fetchFavorites に渡された `after`（カーソル）の記録 ⭐️
    ///
    /// ⚠️ カーソルを `DocumentSnapshot` ではなく `createdAt` の `Date` にしたのは
    ///    「protocol にスナップショットを出さない＝テストでモックできる」ようにするため。
    ///    その設計判断を活かすには、実際に渡っている値を検証しないと意味がない。
    private(set) var receivedAfterValues: [Date?] = []
    /// postId -> Post（成功する投稿）
    var postsById: [String: Post] = [:]
    /// postId -> 投げるエラー（失敗する投稿）
    var failingPostIds: [String: Error] = [:]

    private var pageIndex = 0

    func fetchFavorites(userId _: String, limit _: Int, after: Date?) async throws -> [Favorite] {
        receivedAfterValues.append(after)
        guard pageIndex < stubbedFavoritePages.count else { return [] }
        defer { pageIndex += 1 }
        return stubbedFavoritePages[pageIndex]
    }

    func fetchPost(postId: String) async throws -> Post {
        if let error = failingPostIds[postId] { throw error }
        guard let post = postsById[postId] else { throw FirestoreServiceError.notFound }
        return post
    }
}
