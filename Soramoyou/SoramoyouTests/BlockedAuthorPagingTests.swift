//
//  BlockedAuthorPagingTests.swift
//  SoramoyouTests
//
//  ブロック中の投稿者だけのページで無限スクロールが止まらないことのテスト ⭐️
//
//  ブロック中の投稿者の投稿は画面に出さない。除外を「ページを読み終えた後」にかけると、
//  1 ページ全部がブロック中の投稿者だったとき、追加した投稿がすべて消えて最後の投稿が変わらず、
//  「最後の投稿が見えたら次を読む」きっかけが生まれないまま止まってしまう。
//  除外を「ページを返す前」にかけ、PaginatedPostsViewModel の「表示できる投稿が無いページは
//  次のページを読み進める」仕組みに乗せることを、Home / タグ詳細 / ギャラリーで確かめる。
//

@testable import Soramoyou
import XCTest

@MainActor
final class BlockedAuthorPagingTests: XCTestCase {
    /// ブロック中の投稿者
    private let blockedUserId = "blocked-user"
    /// ブロックしていない投稿者
    private let otherUserId = "other-user"

    // MARK: - Home

    /// 追加読み込みで 1 ページ全部がブロック中の投稿者でも、止まらずに次のページまで読む
    func testHome_追加読み込みでブロック中の投稿者だけのページを読み飛ばして次のページを読む() async {
        let firestoreService = MockFirestoreServiceForHome()
        firestoreService.blockedUserIds = [blockedUserId]
        let viewModel = HomeViewModel(firestoreService: firestoreService, authService: makeSignedInAuthService())
        let pageSize = viewModel.pageSize
        firestoreService.postPages = [
            .init(posts: makePosts(count: pageSize, from: 0, userId: otherUserId), readCount: pageSize),
            .init(posts: makePosts(count: pageSize, from: 100, userId: blockedUserId), readCount: pageSize),
            .init(posts: makePosts(count: 3, from: 200, userId: otherUserId), readCount: 3),
        ]

        await viewModel.fetchPosts()
        await viewModel.loadMorePosts()

        XCTAssertEqual(viewModel.posts.count, pageSize + 3, "ブロック中の投稿者だけのページを飛ばして 3 ページ目まで読む")
        XCTAssertFalse(viewModel.posts.contains { $0.userId == blockedUserId })
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertEqual(firestoreService.fetchPostsWithSnapshotCallCount, 3)
    }

    /// 1 ページ目が全部ブロック中の投稿者でも、空の画面にせず次のページを読む
    func testHome_1ページ目がブロック中の投稿者だけでも次のページを読む() async {
        let firestoreService = MockFirestoreServiceForHome()
        firestoreService.blockedUserIds = [blockedUserId]
        let viewModel = HomeViewModel(firestoreService: firestoreService, authService: makeSignedInAuthService())
        let pageSize = viewModel.pageSize
        let secondPage = makePosts(count: 3, from: 100, userId: otherUserId)
        firestoreService.postPages = [
            .init(posts: makePosts(count: pageSize, from: 0, userId: blockedUserId), readCount: pageSize),
            .init(posts: secondPage, readCount: 3),
        ]

        await viewModel.fetchPosts()

        XCTAssertEqual(viewModel.posts.map(\.id), secondPage.map(\.id))
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertEqual(firestoreService.fetchPostsWithSnapshotCallCount, 2)
    }

    // MARK: - タグ詳細

    /// 追加読み込みで 1 ページ全部がブロック中の投稿者でも、止まらずに次のページまで読む
    func testTagDetail_追加読み込みでブロック中の投稿者だけのページを読み飛ばして次のページを読む() async {
        let (viewModel, tagFeedService) = makeTagDetailViewModel()
        let pageSize = viewModel.pageSize
        tagFeedService.stubbedPages = [
            .init(posts: makePosts(count: pageSize, from: 0, userId: otherUserId), readCount: pageSize),
            .init(posts: makePosts(count: pageSize, from: 100, userId: blockedUserId), readCount: pageSize),
            .init(posts: makePosts(count: 3, from: 200, userId: otherUserId), readCount: 3),
        ]

        await viewModel.fetchPosts()
        await viewModel.loadMorePosts()

        XCTAssertEqual(viewModel.posts.count, pageSize + 3, "ブロック中の投稿者だけのページを飛ばして 3 ページ目まで読む")
        XCTAssertFalse(viewModel.posts.contains { $0.userId == blockedUserId })
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertEqual(tagFeedService.fetchCallCount, 3)
    }

    /// 1 ページ目が全部ブロック中の投稿者でも、空の画面にせず次のページを読む
    func testTagDetail_1ページ目がブロック中の投稿者だけでも次のページを読む() async {
        let (viewModel, tagFeedService) = makeTagDetailViewModel()
        let pageSize = viewModel.pageSize
        let secondPage = makePosts(count: 3, from: 100, userId: otherUserId)
        tagFeedService.stubbedPages = [
            .init(posts: makePosts(count: pageSize, from: 0, userId: blockedUserId), readCount: pageSize),
            .init(posts: secondPage, readCount: 3),
        ]

        await viewModel.fetchPosts()

        XCTAssertEqual(viewModel.posts.map(\.id), secondPage.map(\.id))
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertEqual(tagFeedService.fetchCallCount, 2)
    }

    // MARK: - ギャラリー（通常モード）

    /// 追加読み込みで 1 ページ全部がブロック中の投稿者でも、止まらずに次のページまで読む
    func testGallery_追加読み込みでブロック中の投稿者だけのページを読み飛ばして次のページを読む() async {
        let firestoreService = MockFirestoreServiceForGallery()
        firestoreService.blockedUserIds = [blockedUserId]
        let viewModel = GalleryViewModel(firestoreService: firestoreService, authService: makeSignedInAuthService())
        let pageSize = viewModel.pageSize
        firestoreService.postPages = [
            .init(posts: makePosts(count: pageSize, from: 0, userId: otherUserId), readCount: pageSize),
            .init(posts: makePosts(count: pageSize, from: 100, userId: blockedUserId), readCount: pageSize),
            .init(posts: makePosts(count: 3, from: 200, userId: otherUserId), readCount: 3),
        ]

        await viewModel.fetchPosts()
        await viewModel.loadMorePosts()

        XCTAssertEqual(viewModel.posts.count, pageSize + 3, "ブロック中の投稿者だけのページを飛ばして 3 ページ目まで読む")
        XCTAssertFalse(viewModel.posts.contains { $0.userId == blockedUserId })
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertEqual(firestoreService.filteredFetchCallCount, 3)
    }

    /// 1 ページ目が全部ブロック中の投稿者でも、空の画面にせず次のページを読む
    func testGallery_1ページ目がブロック中の投稿者だけでも次のページを読む() async {
        let firestoreService = MockFirestoreServiceForGallery()
        firestoreService.blockedUserIds = [blockedUserId]
        let viewModel = GalleryViewModel(firestoreService: firestoreService, authService: makeSignedInAuthService())
        let pageSize = viewModel.pageSize
        let secondPage = makePosts(count: 3, from: 100, userId: otherUserId)
        firestoreService.postPages = [
            .init(posts: makePosts(count: pageSize, from: 0, userId: blockedUserId), readCount: pageSize),
            .init(posts: secondPage, readCount: 3),
        ]

        await viewModel.fetchPosts()

        XCTAssertEqual(viewModel.posts.map(\.id), secondPage.map(\.id))
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertEqual(firestoreService.filteredFetchCallCount, 2)
    }

    // MARK: - Helpers

    /// ログイン済みの認証サービス（ログインしていないとブロックリストを読まない）
    private func makeSignedInAuthService() -> MockAuthService {
        let authService = MockAuthService()
        authService.currentUserValue = User(id: "current-user", email: "test@example.com")
        return authService
    }

    /// ブロック中の投稿者がいるログイン済みユーザーのタグ詳細を作る
    private func makeTagDetailViewModel() -> (TagDetailViewModel, MockTagFeedServiceForTagDetail) {
        let firestoreService = MockFirestoreServiceForTagDetail()
        firestoreService.blockedUserIds = [blockedUserId]
        let tagFeedService = MockTagFeedServiceForTagDetail()
        let viewModel = TagDetailViewModel(
            tag: "夕焼け",
            firestoreService: firestoreService,
            tagFeedService: tagFeedService,
            authService: makeSignedInAuthService()
        )
        return (viewModel, tagFeedService)
    }

    /// テスト用の投稿を作る（id は "post-<番号>"）
    private func makePosts(count: Int, from start: Int, userId: String) -> [Post] {
        (start ..< start + count).map { index in
            Post(
                id: "post-\(index)",
                userId: userId,
                images: [ImageInfo(url: "https://example.com/image.jpg", width: 1024, height: 768, order: 0)],
                caption: nil,
                visibility: .public
            )
        }
    }
}
