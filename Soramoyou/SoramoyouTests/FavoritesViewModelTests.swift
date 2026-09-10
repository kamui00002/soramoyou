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

    /// 8. 一時的な失敗に当たったら、そのページを**そこで切り詰める** ⭐️
    ///
    /// 「失敗した1件だけ飛ばして残りを積む」と、カーソルはページ末尾まで進むのに
    /// 失敗した投稿は積まれていない。次ページはその先から始まるので、
    /// **その投稿は二度と取りに行かれず静かに消える**（お気に入りしたのに一覧に無い）。
    ///
    /// レジで30個スキャンして袋に入ったのが25個なら、レシートは25個分で切る。
    /// ＝カーソルは「解決できた最後の1件」までしか進めない。
    func testTransientFailureTruncatesPageAtFailurePoint() async {
        let mock = MockFirestoreServiceForFavoritesList()
        let firstPage = makeFavorites(["p1", "p2", "p3"])
        mock.stubbedFavoritePages = [firstPage, makeFavorites(["p4"])]
        mock.postsById = ["p1": makePost("p1"), "p3": makePost("p3"), "p4": makePost("p4")]
        mock.failingPostIds = [
            "p2": FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009))
        ]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 3)

        await viewModel.load()

        XCTAssertEqual(
            viewModel.posts.map(\.id), ["p1"],
            "p2 で打ち切る。p3 を先に積むと、間の p2 が永久に欠落する"
        )
        XCTAssertTrue(viewModel.hasMore, "切り詰めた＝サーバーにはまだ続きが残っている")
        XCTAssertNotNil(viewModel.loadMoreError, "つまずいたことをフッターに出す（黙って諦めない）")

        await viewModel.loadMore()

        XCTAssertEqual(
            mock.receivedAfterValues.last ?? nil,
            firstPage[0].createdAt,
            "カーソルは成功した p1 までしか進めない（p3 まで消費したことにしない）"
        )
    }

    /// 9. 1ページ丸ごと出せなかったら、次のページまで繰る ⭐️
    ///
    /// 一覧が0件だと画面に最後のセルが存在せず、`.onAppear` 起点の loadMore が発火しない。
    /// ViewModel 側で繰らないと、その先に生きている投稿があっても永久に辿り着けない。
    func testAllUnavailablePageAdvancesToNextPage() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.stubbedFavoritePages = [
            makeFavorites(["gone1", "gone2"]),  // pageSize ちょうど＝続きがある
            makeFavorites(["p3"])
        ]
        mock.postsById = ["p3": makePost("p3")]
        mock.failingPostIds = [
            "gone1": FirestoreServiceError.notFound,
            "gone2": FirestoreServiceError.notFound
        ]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 2)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p3"], "1ページ目が全滅でも2ページ目まで繰る")
        XCTAssertEqual(viewModel.unavailableCount, 2, "繰った先でも、出せなかった件数は数え続ける")
        XCTAssertFalse(viewModel.hasMore, "2ページ目が pageSize 未満なので終端")
    }

    /// 10. 全ページ出せなくても、ページ繰りは予算で止まる ⭐️
    ///
    /// 削除済みの favorites が数百件ある人で無限に回らないための上限。
    /// ただし打ち切ったときに `hasMore` を倒してはいけない
    /// （倒すと「お気に入りは全部消えました」と**嘘の断定**を表示することになる）。
    func testAllUnavailablePagesStopAtPageBudget() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // 予算より多いページを用意し、全ページとも全件が削除済み
        mock.stubbedFavoritePages = (1...8).map { makeFavorites(["g\($0)a", "g\($0)b"]) }
        for page in mock.stubbedFavoritePages {
            for favorite in page {
                mock.failingPostIds[favorite.postId] = FirestoreServiceError.notFound
            }
        }
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 2)

        await viewModel.load()

        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertEqual(mock.receivedAfterValues.count, 5, "無限には繰らない（1リクエストあたり5ページまで）")
        XCTAssertTrue(viewModel.hasMore, "予算切れ。続きが残っているのに『全部消えた』と断定しない")
    }

    /// 11. 続きの読み込みが一時的に失敗したら、黙って捨てず表に出す ⭐️
    ///
    /// 修正前の `loadMore` は解決結果の一時的な失敗を見ておらず、取れなかった投稿は
    /// **カーソルだけ進んで静かに消えていた**。画面にも何も出ないので気づく手段が無い。
    /// 一覧全体をエラーにはせず（既に出ているものは残す）、フッターで再試行を促す。
    func testLoadMoreSurfacesTransientErrorInsteadOfDroppingIt() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.stubbedFavoritePages = [makeFavorites(["p1", "p2"]), makeFavorites(["p3", "p4"])]
        mock.postsById = [
            "p1": makePost("p1"), "p2": makePost("p2"),
            "p3": makePost("p3"), "p4": makePost("p4")
        ]
        mock.failingPostIds = [
            "p4": FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009))
        ]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 2)

        await viewModel.load()
        XCTAssertNil(viewModel.loadMoreError, "1ページ目は問題なく解決できている")

        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2", "p3"], "p4 の手前まで積む")
        XCTAssertNotNil(viewModel.loadMoreError, "失敗を黙って捨てない")
        XCTAssertTrue(viewModel.hasMore, "p4 はまだサーバーに残っている")
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
