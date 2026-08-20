//
//  ForYouFeedViewModelTests.swift
//  SoramoyouTests
//
//  ForYouFeedViewModel（あなた向けフィード VM）と基底クラスの噛み合わせを検証する ⭐️
//
//  レビュー D2/D4 対応: 純関数的な MergedFeedPaginator 側は厚くテスト済みだった一方、
//  「最も危うい基底との噛み合わせ」（Paginator 差し替え・hasMorePosts 上書き・
//  isRefreshing ガード・builder 失敗時の状態）が未検証だったため追加。
//

@testable import Soramoyou
import XCTest

@MainActor
final class ForYouFeedViewModelTests: XCTestCase {
    // MARK: - Helpers

    /// テスト用の最小 Post
    private func makePost(_ id: String, user: String = "u1", t: TimeInterval) -> Post {
        Post(id: id, userId: user, images: [], createdAt: Date(timeIntervalSince1970: t))
    }

    /// 配列を切り出すだけのストリーム（呼び出し回数を記録できる）
    private func makeCountingStream(
        id: String,
        posts: [Post],
        counter: CallCounter
    ) -> FeedStreamSource {
        var offset = 0
        return FeedStreamSource(id: id) { limit in
            counter.increment()
            let page = Array(posts.dropFirst(offset).prefix(limit))
            offset += page.count
            return FeedStreamPage(posts: page, isExhausted: page.count < limit)
        }
    }

    /// ログイン済みユーザーを持つ MockAuthService を作る
    private func makeSignedInAuth() -> MockAuthService {
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "me", email: "me@example.com", displayName: "Me")
        return auth
    }

    /// スレッド安全な呼び出しカウンタ（withTaskGroup 等の並行呼び出し対策で NSLock 保護）
    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return _count
        }

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            _count += 1
        }
    }

    // MARK: - Mocks

    /// ForYouFeedViewModel が必要とする最小の FirestoreService モック。
    /// fetchBlockedUserIds の「2回目の呼び出し」をゲートで待機させられる
    /// （リフレッシュ中の await 窓を決定的に再現するため。レビュー D4 の回帰テスト用）。
    final class MockFirestoreServiceForForYou: FirestoreServiceProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _blockedCallCount = 0
        private var _gateOpen = true

        var blockedCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _blockedCallCount
        }

        var gateOpen: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _gateOpen
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _gateOpen = newValue
            }
        }

        /// ブロックリスト取得。gateOpen=false の間、2回目の呼び出し
        /// （＝基底 HomeViewModel.loadBlockedUsers 由来）を待機させる。
        func fetchBlockedUserIds(userId _: String) async throws -> [String] {
            let count: Int = {
                lock.lock()
                defer { lock.unlock() }
                _blockedCallCount += 1
                return _blockedCallCount
            }()
            if count == 2 {
                while !gateOpen {
                    try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
                }
            }
            return []
        }

        /// 著者一括取得（基底 fetchAuthorsForCurrentPosts）用。テストでは著者不要なので失敗させる
        /// （呼び出し側が try? で握るため、投稿表示には影響しない）。
        func fetchPublicProfile(userId _: String) async throws -> PublicProfile {
            throw NSError(domain: "MockFirestoreServiceForForYou", code: -1)
        }
    }

    /// 固定結果を返す SourceBuilder モック
    final class StubSourceBuilder: ForYouFeedSourceBuilderProtocol, @unchecked Sendable {
        private let result: Result<ForYouFeedSources, Error>
        let buildCallCounter = CallCounter()

        init(result: Result<ForYouFeedSources, Error>) {
            self.result = result
        }

        func buildSources(for _: String) async throws -> ForYouFeedSources {
            buildCallCounter.increment()
            return try result.get()
        }
    }

    private struct BuilderError: Error {}

    // MARK: - (a) ゲスト（未認証）

    /// ゲスト（currentUser が nil）では builder を呼ばず、空＋hasMorePosts=false で安全に終わる
    func testゲストは空のままhasMoreFalse() async {
        let auth = MockAuthService() // currentUserValue = nil
        let builder = StubSourceBuilder(result: .success(
            ForYouFeedSources(streams: [], followeeCount: 0, tagCount: 0, tagSource: "none")
        ))
        let viewModel = ForYouFeedViewModel(
            firestoreService: MockFirestoreServiceForForYou(),
            authService: auth,
            sourceBuilder: builder
        )

        await viewModel.fetchPosts()

        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertEqual(builder.buildCallCounter.count, 0, "未認証では buildSources を呼ばない")
    }

    // MARK: - (b) builder 失敗

    /// ソース構成の失敗は無言の空フィードにせず、エラーとして表示される
    func testBuilder失敗はエラーとして表示される() async {
        let builder = StubSourceBuilder(result: .failure(BuilderError()))
        let viewModel = ForYouFeedViewModel(
            firestoreService: MockFirestoreServiceForForYou(),
            authService: makeSignedInAuth(),
            sourceBuilder: builder
        )

        await viewModel.fetchPosts()

        XCTAssertNotNil(viewModel.lastError, "失敗が lastError に載る（ErrorStateView 用）")
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - (c) hasMorePosts が Paginator の真値を反映する

    /// 取得件数がちょうど pageSize でも、Paginator が枯渇を知っていれば hasMorePosts=false になる。
    /// （基底の近似「取得件数 < pageSize なら false」だけだと true のまま残るケース）
    func testHasMoreはPaginatorの真値を反映する() async {
        // 2ストリーム × 10件 = ちょうど pageSize(20) 件で全枯渇するソース構成
        let counterA = CallCounter()
        let counterB = CallCounter()
        let streamA = makeCountingStream(
            id: "A",
            posts: (0 ..< 10).map { makePost("a\($0)", t: 1000 - TimeInterval($0)) },
            counter: counterA
        )
        let streamB = makeCountingStream(
            id: "B",
            posts: (0 ..< 10).map { makePost("b\($0)", t: 500 - TimeInterval($0)) },
            counter: counterB
        )
        let builder = StubSourceBuilder(result: .success(
            ForYouFeedSources(streams: [streamA, streamB], followeeCount: 2, tagCount: 0, tagSource: "none")
        ))
        let viewModel = ForYouFeedViewModel(
            firestoreService: MockFirestoreServiceForForYou(),
            authService: makeSignedInAuth(),
            sourceBuilder: builder
        )

        await viewModel.fetchPosts()

        XCTAssertEqual(viewModel.posts.count, 20, "ちょうど pageSize 件が取得される")
        XCTAssertFalse(
            viewModel.hasMorePosts,
            "基底の近似（count == pageSize → true のまま）ではなく Paginator の枯渇情報を反映すべき"
        )
    }

    // MARK: - (D4 回帰) リフレッシュ中の loadMorePosts 割り込み

    /// リフレッシュが Paginator を差し替えた直後の await 窓（基底のブロックリスト取得中）に
    /// loadMorePosts が割り込んでも、新しい Paginator の1ページ目を先食いしない。
    /// ガードが無いと: 割り込みが1ページ目を消費 → リフレッシュ結果が2ページ目から始まり
    /// 先頭 pageSize 件が無言欠落する。
    func testリフレッシュ中のloadMoreは新Paginatorを先食いしない() async {
        let streamCounter = CallCounter()
        let stream = makeCountingStream(
            id: "A",
            posts: (0 ..< 40).map { makePost("p\($0)", t: 1000 - TimeInterval($0)) },
            counter: streamCounter
        )
        let builder = StubSourceBuilder(result: .success(
            ForYouFeedSources(streams: [stream], followeeCount: 1, tagCount: 0, tagSource: "none")
        ))
        let firestore = MockFirestoreServiceForForYou()
        firestore.gateOpen = false // 2回目の fetchBlockedUserIds（基底由来）で待機させる
        let viewModel = ForYouFeedViewModel(
            firestoreService: firestore,
            authService: makeSignedInAuth(),
            sourceBuilder: builder
        )

        // リフレッシュを開始し、「Paginator 差し替え済み・基底のブロック取得で待機中」まで進める
        let refreshTask = Task { await viewModel.fetchPosts() }
        var waited = 0
        while firestore.blockedCallCount < 2, waited < 400 {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
            waited += 1
        }
        XCTAssertEqual(firestore.blockedCallCount, 2, "基底のブロック取得（ゲート地点）まで到達すべき")

        // この await 窓で最終投稿の .onAppear 相当の追加読み込みが割り込む
        await viewModel.loadMorePosts()
        XCTAssertEqual(
            streamCounter.count, 0,
            "リフレッシュ完了前に Paginator の1ページ目を先食いしてはいけない（レビュー D4）"
        )

        // ゲートを開けてリフレッシュを完走させる
        firestore.gateOpen = true
        await refreshTask.value

        XCTAssertEqual(viewModel.posts.count, 20)
        XCTAssertEqual(viewModel.posts.first?.id, "p0", "先頭ページが欠落していないこと")
        XCTAssertTrue(viewModel.hasMorePosts, "残り20件があるので継続")
    }
}
