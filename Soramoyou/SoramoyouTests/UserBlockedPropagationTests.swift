//
//  UserBlockedPropagationTests.swift
//  SoramoyouTests
//
//  投稿詳細でのブロックが一覧に伝わることのテスト ⭐️
//
//  投稿詳細でブロックすると `.userBlocked` 通知が送られる。ホーム・タグ詳細・ギャラリーの一覧は
//  それを受け取り、表示中の投稿と、以降に読むページの両方からその人の投稿を除く。
//  （ForYou は ForYouFeedViewModelTests 側で、Paginator の次のページまで確かめる）
//

@testable import Soramoyou
import XCTest

@MainActor
final class UserBlockedPropagationTests: XCTestCase {
    /// ブロックする投稿者
    private let blockedUserId = "blocked-user"
    /// ブロックしない投稿者
    private let otherUserId = "other-user"

    // MARK: - Home

    func testHome_ブロック通知で表示中の投稿から除き次のページでも除く() async {
        let firestoreService = MockFirestoreServiceForHome()
        let viewModel = HomeViewModel(firestoreService: firestoreService, authService: makeSignedInAuthService())
        let pageSize = viewModel.pageSize
        firestoreService.postPages = [
            .init(posts: makeAlternatingPosts(count: pageSize, from: 0), readCount: pageSize),
            .init(posts: makeAlternatingPosts(count: pageSize, from: 100), readCount: pageSize),
        ]
        await viewModel.fetchPosts()
        XCTAssertEqual(viewModel.posts.count, pageSize, "前提: ブロック前は両方の投稿者が出ている")

        postUserBlocked(blockedUserId)
        await waitForMainActorTasks { !viewModel.posts.contains { $0.userId == self.blockedUserId } }
        XCTAssertFalse(viewModel.posts.contains { $0.userId == blockedUserId }, "通知を受けたら、追加読み込みを待たずに表示中の投稿から除く")
        await viewModel.loadMorePosts()

        XCTAssertFalse(viewModel.posts.contains { $0.userId == blockedUserId }, "表示中の投稿からも次のページからも除く")
        XCTAssertEqual(viewModel.posts.count, pageSize, "2 ページとも、ブロックしていない投稿者の半分だけが残る")
    }

    // MARK: - タグ詳細

    func testTagDetail_ブロック通知で表示中の投稿から除き次のページでも除く() async {
        let tagFeedService = MockTagFeedServiceForTagDetail()
        let viewModel = TagDetailViewModel(
            tag: "夕焼け",
            firestoreService: MockFirestoreServiceForTagDetail(),
            tagFeedService: tagFeedService,
            authService: makeSignedInAuthService()
        )
        let pageSize = viewModel.pageSize
        tagFeedService.stubbedPages = [
            .init(posts: makeAlternatingPosts(count: pageSize, from: 0), readCount: pageSize),
            .init(posts: makeAlternatingPosts(count: pageSize, from: 100), readCount: pageSize),
        ]
        await viewModel.fetchPosts()
        XCTAssertEqual(viewModel.posts.count, pageSize, "前提: ブロック前は両方の投稿者が出ている")

        postUserBlocked(blockedUserId)
        await waitForMainActorTasks { !viewModel.posts.contains { $0.userId == self.blockedUserId } }
        XCTAssertFalse(viewModel.posts.contains { $0.userId == blockedUserId }, "通知を受けたら、追加読み込みを待たずに表示中の投稿から除く")
        await viewModel.loadMorePosts()

        XCTAssertFalse(viewModel.posts.contains { $0.userId == blockedUserId }, "表示中の投稿からも次のページからも除く")
        XCTAssertEqual(viewModel.posts.count, pageSize, "2 ページとも、ブロックしていない投稿者の半分だけが残る")
    }

    // MARK: - ギャラリー（通常モード）

    func testGallery_ブロック通知で表示中の投稿から除き次のページでも除く() async {
        let firestoreService = MockFirestoreServiceForGallery()
        let viewModel = GalleryViewModel(firestoreService: firestoreService, authService: makeSignedInAuthService())
        let pageSize = viewModel.pageSize
        firestoreService.postPages = [
            .init(posts: makeAlternatingPosts(count: pageSize, from: 0), readCount: pageSize),
            .init(posts: makeAlternatingPosts(count: pageSize, from: 100), readCount: pageSize),
        ]
        await viewModel.fetchPosts()
        XCTAssertEqual(viewModel.posts.count, pageSize, "前提: ブロック前は両方の投稿者が出ている")

        postUserBlocked(blockedUserId)
        await waitForMainActorTasks { !viewModel.posts.contains { $0.userId == self.blockedUserId } }
        XCTAssertFalse(viewModel.posts.contains { $0.userId == blockedUserId }, "通知を受けたら、追加読み込みを待たずに表示中の投稿から除く")
        // ⚠️ モックは常に lastDocument を nil で返すため、ギャラリーは 2 ページ目でもブロックリストを
        //    読み直す（本番は 1 ページ目だけ）。読み直しで消えないよう、モック側にも追加しておく
        //    （本番でもブロックは Firestore に書き込み済みなので、読み直せば含まれる）
        firestoreService.blockedUserIds = [blockedUserId]
        await viewModel.loadMorePosts()

        XCTAssertFalse(viewModel.posts.contains { $0.userId == blockedUserId }, "表示中の投稿からも次のページからも除く")
        XCTAssertEqual(viewModel.posts.count, pageSize, "2 ページとも、ブロックしていない投稿者の半分だけが残る")
    }

    // MARK: - Helpers

    /// 投稿詳細でブロックしたときと同じ通知を送る
    private func postUserBlocked(_ userId: String) {
        NotificationCenter.default.post(
            name: .userBlocked,
            object: nil,
            userInfo: [Notification.blockedUserIdKey: userId]
        )
    }

    /// ログイン済みの認証サービス（ログインしていないとブロックリストを読まない）
    private func makeSignedInAuthService() -> MockAuthService {
        let authService = MockAuthService()
        authService.currentUserValue = User(id: "current-user", email: "test@example.com")
        return authService
    }

    /// ブロックする投稿者としない投稿者が交互に並ぶ投稿を作る（id は "post-<番号>"）
    private func makeAlternatingPosts(count: Int, from start: Int) -> [Post] {
        (start ..< start + count).map { index in
            Post(
                id: "post-\(index)",
                userId: index.isMultiple(of: 2) ? otherUserId : blockedUserId,
                images: [ImageInfo(url: "https://example.com/image.jpg", width: 1024, height: 768, order: 0)],
                caption: nil,
                visibility: .public
            )
        }
    }
}

extension XCTestCase {
    /// 通知を受けた ViewModel が MainActor 上の Task で処理を終えるまで待つ ⭐️
    ///
    /// 通知の受け取りは `Task { @MainActor in … }` で非同期に処理されるため、送った直後には
    /// まだ反映されていない。条件が満たされるまで MainActor に順番を譲る（回数に上限があるので、
    /// 反映されない＝不具合のときは待ち続けずに戻り、続くアサートで落ちる）。
    /// - Note: `condition` を `@escaping` にしているのは、XCTestCase（Objective-C 由来）の extension に置いた
    ///   `@MainActor` の async 関数では、非 escaping のクロージャを受け取るとコンパイルできないため
    ///   （"escaping local function captures non-escaping value"）。
    @MainActor
    func waitForMainActorTasks(until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0 ..< 50 {
            if condition() { return }
            await Task.yield()
        }
    }
}
