//
//  PaginatedPostsViewModelTests.swift
//  SoramoyouTests
//
//  無限スクロールの「続きがあるか」判定のテスト ⭐️
//
//  壊れた投稿は PostDocumentDecoder が 1 件ずつ飛ばすため、変換後の件数は
//  実際に読んだドキュメント数より少なくなる。満杯のページなのに
//  「件数 < pageSize ＝ 続きなし」と判定して止まらないことを確かめる。
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

@MainActor
final class PaginatedPostsViewModelTests: XCTestCase {
    private var mockFirestoreService: MockFirestoreServiceForPaging!
    private var viewModel: PaginatedPostsViewModel!

    override func setUp() {
        super.setUp()
        mockFirestoreService = MockFirestoreServiceForPaging()
        viewModel = PaginatedPostsViewModel(firestoreService: mockFirestoreService)
    }

    override func tearDown() {
        viewModel = nil
        mockFirestoreService = nil
        super.tearDown()
    }

    // MARK: - 壊れた投稿を飛ばしたページ（変換後の件数 < pageSize）

    /// 1 ページ目で 1 件飛ばしても、満杯まで読めていれば続きありのまま
    func testFetchPosts_壊れた投稿を1件飛ばしても満杯まで読めていれば続きありのまま() async {
        let pageSize = viewModel.pageSize
        // pageSize 件読んだうち 1 件が壊れていて、表示できるのは pageSize - 1 件
        mockFirestoreService.pages = [
            .init(posts: makePosts(count: pageSize - 1, from: 0), readCount: pageSize),
        ]

        await viewModel.fetchPosts()

        XCTAssertEqual(viewModel.posts.count, pageSize - 1)
        XCTAssertTrue(viewModel.hasMorePosts, "読んだのは満杯の pageSize 件なので、続きがある")
    }

    /// 2 ページ目で 1 件飛ばしても、3 ページ目を読みに行く
    func testLoadMorePosts_壊れた投稿を飛ばしたページの後も次のページを読む() async {
        let pageSize = viewModel.pageSize
        mockFirestoreService.pages = [
            .init(posts: makePosts(count: pageSize, from: 0), readCount: pageSize),
            .init(posts: makePosts(count: pageSize - 1, from: 100), readCount: pageSize),
            .init(posts: makePosts(count: 5, from: 200), readCount: 5),
        ]

        await viewModel.fetchPosts()
        await viewModel.loadMorePosts()

        XCTAssertEqual(viewModel.posts.count, pageSize * 2 - 1)
        XCTAssertTrue(viewModel.hasMorePosts, "2 ページ目も満杯まで読めているので、まだ続きがある")

        await viewModel.loadMorePosts()

        XCTAssertEqual(viewModel.posts.count, pageSize * 2 - 1 + 5)
        XCTAssertFalse(viewModel.hasMorePosts, "3 ページ目は pageSize 未満しか読めなかったので終わり")
        XCTAssertEqual(mockFirestoreService.fetchCallCount, 3)
    }

    // MARK: - 全件が壊れていたページ（変換後 0 件）

    /// 1 ページ目が全部壊れていても、空の画面にせず次のページを先読みする
    func testFetchPosts_1ページ目が全部壊れていても次のページを先読みする() async {
        let pageSize = viewModel.pageSize
        let secondPage = makePosts(count: 3, from: 100)
        mockFirestoreService.pages = [
            .init(posts: [], readCount: pageSize),
            .init(posts: secondPage, readCount: 3),
        ]

        await viewModel.fetchPosts()

        XCTAssertEqual(viewModel.posts.map(\.id), secondPage.map(\.id))
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertEqual(mockFirestoreService.fetchCallCount, 2)
    }

    /// 追加読み込みで全部壊れたページに当たっても、止まらずに次のページまで読む
    func testLoadMorePosts_全部壊れたページを読み飛ばして次のページを読む() async {
        let pageSize = viewModel.pageSize
        mockFirestoreService.pages = [
            .init(posts: makePosts(count: pageSize, from: 0), readCount: pageSize),
            .init(posts: [], readCount: pageSize),
            .init(posts: makePosts(count: 3, from: 200), readCount: 3),
        ]

        await viewModel.fetchPosts()
        await viewModel.loadMorePosts()

        XCTAssertEqual(viewModel.posts.count, pageSize + 3)
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertEqual(mockFirestoreService.fetchCallCount, 3)
    }

    /// 全部壊れたページが延々と続いても、1 回の読み込みで読むページ数には上限がある
    func testLoadMorePosts_全部壊れたページが続いても読みすぎずに続きありで止まる() async {
        let pageSize = viewModel.pageSize
        let brokenPageCount = 10
        mockFirestoreService.pages =
            [.init(posts: makePosts(count: pageSize, from: 0), readCount: pageSize)]
                + Array(repeating: .init(posts: [], readCount: pageSize), count: brokenPageCount)

        await viewModel.fetchPosts()
        await viewModel.loadMorePosts()

        let pagesReadByLoadMore = mockFirestoreService.fetchCallCount - 1
        XCTAssertGreaterThan(pagesReadByLoadMore, 1, "全部壊れたページで止まらず、次のページを先読みする")
        XCTAssertLessThan(pagesReadByLoadMore, brokenPageCount, "壊れたページを際限なく読み続けない")
        XCTAssertEqual(viewModel.posts.count, pageSize)
        XCTAssertTrue(viewModel.hasMorePosts, "まだ読み切っていないので、次のスクロールで続きを読める")
    }

    // MARK: - Helpers

    /// テスト用の投稿を作る（id は "post-<番号>"）
    private func makePosts(count: Int, from start: Int) -> [Post] {
        (start ..< start + count).map { index in
            Post(
                id: "post-\(index)",
                userId: "test-user-id",
                images: [ImageInfo(url: "https://example.com/image.jpg", width: 1024, height: 768, order: 0)],
                caption: nil,
                visibility: .public
            )
        }
    }
}

// MARK: - Mock

/// ページを順番に返す FirestoreService のモック ⭐️
///
/// 本物の DocumentSnapshot はテストで作れないため、カーソルの代わりに
/// 呼ばれた回数で「何ページ目か」を決める（ProfileViewModelTests の userPostPages と同じ方式）。
final class MockFirestoreServiceForPaging: FirestoreServiceProtocol {
    /// 1 ページ分の模擬データ
    struct Page {
        /// 表示できる投稿（壊れた投稿を飛ばした後）
        let posts: [Post]
        /// Firestore から実際に読んだドキュメント数（壊れた投稿も含む）
        let readCount: Int
    }

    /// 呼ばれた順に返すページ。尽きたら空ページ（続きなし）を返す
    var pages: [Page] = []
    /// fetchPostsWithSnapshot が呼ばれた回数
    private(set) var fetchCallCount = 0

    func fetchPostsWithSnapshot(limit: Int, lastDocument _: DocumentSnapshot?) async throws -> PostPage {
        defer { fetchCallCount += 1 }
        guard fetchCallCount < pages.count else {
            return PostPage(posts: [], lastDocument: nil, isExhausted: true)
        }
        let page = pages[fetchCallCount]
        // 本番（PostPage(posts:snapshot:limit:)）と同じく、読んだ件数で続きの有無を決める
        return PostPage(posts: page.posts, lastDocument: nil, isExhausted: page.readCount < limit)
    }
}
