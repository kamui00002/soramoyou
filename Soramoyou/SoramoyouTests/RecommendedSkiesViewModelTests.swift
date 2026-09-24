//
//  RecommendedSkiesViewModelTests.swift
//  SoramoyouTests
//
//  プロフィールの「おすすめの空」欄の投稿解決（RecommendedSkiesViewModel）のテスト ⭐️
//

import XCTest
@testable import Soramoyou

@MainActor
final class RecommendedSkiesViewModelTests: XCTestCase {
    private func post(_ id: String, owner: String, visibility: Visibility = .public) -> Post {
        Post(id: id, userId: owner, images: [], visibility: visibility)
    }

    func testItemsKeepListOrder() async {
        let mock = MockFirestoreServiceForRecommendedSkies()
        mock.posts = ["A": post("A", owner: "me"), "B": post("B", owner: "me"), "C": post("C", owner: "me")]
        let viewModel = RecommendedSkiesViewModel(firestoreService: mock)

        await viewModel.load(postIds: ["C", "A", "B"], ownerId: "me")

        XCTAssertEqual(viewModel.items.map(\.id), ["C", "A", "B"])
        XCTAssertFalse(viewModel.isLoading)
    }

    func testDeletedAndNonPublicPostsAreUnavailable() async {
        let mock = MockFirestoreServiceForRecommendedSkies()
        mock.posts = [
            "public": post("public", owner: "other"),
            "followers": post("followers", owner: "other", visibility: .followers)
        ]
        let viewModel = RecommendedSkiesViewModel(firestoreService: mock)

        await viewModel.load(postIds: ["deleted", "public", "followers"], ownerId: "me")

        XCTAssertEqual(viewModel.items.map(\.id), ["public"])
        XCTAssertEqual(viewModel.unavailablePostIds, ["deleted", "followers"])
    }

    func testTransientFailureIsNotCountedAsUnavailable() async {
        // 通信の失敗で「表示できない空」に数えると、持ち主に誤って整理を促してしまう
        let mock = MockFirestoreServiceForRecommendedSkies()
        mock.posts = ["A": post("A", owner: "me")]
        mock.transientFailurePostIds = ["A"]
        let viewModel = RecommendedSkiesViewModel(firestoreService: mock)

        await viewModel.load(postIds: ["A"], ownerId: "me")

        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertTrue(viewModel.unavailablePostIds.isEmpty)

        // 次の読み込みで取り直せる
        mock.transientFailurePostIds = []
        await viewModel.load(postIds: ["A"], ownerId: "me")
        XCTAssertEqual(viewModel.items.map(\.id), ["A"])
    }

    func testAuthorNameIsShownOnlyForOtherUsersPosts() async {
        let mock = MockFirestoreServiceForRecommendedSkies()
        mock.posts = ["mine": post("mine", owner: "me"), "theirs": post("theirs", owner: "kumo")]
        mock.displayNames = ["me": "わたし", "kumo": "くも"]
        let viewModel = RecommendedSkiesViewModel(firestoreService: mock)

        await viewModel.load(postIds: ["mine", "theirs"], ownerId: "me")

        XCTAssertNil(viewModel.items.first { $0.id == "mine" }?.authorName)
        XCTAssertEqual(viewModel.items.first { $0.id == "theirs" }?.authorName, "くも")
        XCTAssertEqual(mock.fetchedProfileIds, ["kumo"], "持ち主の名前は取りに行かない")
    }

    func testReorderAndRemoveUseCacheWithoutRefetching() async {
        let mock = MockFirestoreServiceForRecommendedSkies()
        mock.posts = ["A": post("A", owner: "me"), "B": post("B", owner: "me"), "C": post("C", owner: "me")]
        let viewModel = RecommendedSkiesViewModel(firestoreService: mock)
        await viewModel.load(postIds: ["A", "B", "C"], ownerId: "me")

        await viewModel.load(postIds: ["B", "A"], ownerId: "me")

        XCTAssertEqual(viewModel.items.map(\.id), ["B", "A"])
        XCTAssertEqual(mock.fetchedPostIds.count, 3, "並べ替え・外すでは取り直さない")
    }

    func testForceReloadRefetches() async {
        let mock = MockFirestoreServiceForRecommendedSkies()
        mock.posts = ["A": post("A", owner: "me")]
        let viewModel = RecommendedSkiesViewModel(firestoreService: mock)
        await viewModel.load(postIds: ["A"], ownerId: "me")

        // 別端末で非公開にされた
        mock.posts = ["A": post("A", owner: "me", visibility: .private)]
        await viewModel.load(postIds: ["A"], ownerId: "me", force: true)

        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertEqual(viewModel.unavailablePostIds, ["A"])
    }

    func testPostsOfUsersBlockedByViewerAreHidden() async {
        // 他の人のプロフィールで、閲覧者がブロックした人の投稿は出さない
        let mock = MockFirestoreServiceForRecommendedSkies()
        mock.posts = ["byBlocked": post("byBlocked", owner: "troll"), "ok": post("ok", owner: "kumo")]
        mock.blockedUserIdsByViewer = ["viewer": ["troll"]]
        let viewModel = RecommendedSkiesViewModel(firestoreService: mock)

        await viewModel.load(postIds: ["byBlocked", "ok"], ownerId: "owner", viewerId: "viewer")

        XCTAssertEqual(viewModel.items.map(\.id), ["ok"])
        XCTAssertTrue(viewModel.unavailablePostIds.isEmpty, "ブロックは「表示できない空」に数えない")
    }

    func testBlockListFailureStillShowsSection() async {
        let mock = MockFirestoreServiceForRecommendedSkies()
        mock.posts = ["ok": post("ok", owner: "kumo")]
        mock.blockListError = FirestoreServiceError.notFound
        let viewModel = RecommendedSkiesViewModel(firestoreService: mock)

        await viewModel.load(postIds: ["ok"], ownerId: "owner", viewerId: "viewer")

        XCTAssertEqual(viewModel.items.map(\.id), ["ok"])
    }

    func testEmptyListShowsNothing() async {
        let mock = MockFirestoreServiceForRecommendedSkies()
        let viewModel = RecommendedSkiesViewModel(firestoreService: mock)

        await viewModel.load(postIds: [], ownerId: "me")

        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertTrue(viewModel.unavailablePostIds.isEmpty)
        XCTAssertTrue(mock.fetchedPostIds.isEmpty)
    }
}

// MARK: - Mock

/// fetchPost / fetchPublicProfile だけを持つモック（TaskGroup から並列に呼ばれるので記録はロックで守る）
final class MockFirestoreServiceForRecommendedSkies: FirestoreServiceProtocol, @unchecked Sendable {
    var posts: [String: Post] = [:]
    var displayNames: [String: String] = [:]
    var transientFailurePostIds: Set<String> = []
    /// 閲覧者 → ブロックしている人
    var blockedUserIdsByViewer: [String: [String]] = [:]
    var blockListError: Error?

    private let lock = NSLock()
    private var fetchedPostIdsStorage: [String] = []
    private var fetchedProfileIdsStorage: [String] = []

    var fetchedPostIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return fetchedPostIdsStorage
    }

    var fetchedProfileIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return fetchedProfileIdsStorage
    }

    func fetchPost(postId: String) async throws -> Post {
        record(postId: postId)

        if transientFailurePostIds.contains(postId) {
            throw FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        }
        guard let post = posts[postId] else { throw FirestoreServiceError.notFound }
        return post
    }

    func fetchBlockedUserIds(userId: String) async throws -> [String] {
        if let blockListError { throw blockListError }
        return blockedUserIdsByViewer[userId] ?? []
    }

    func fetchPublicProfile(userId: String) async throws -> PublicProfile {
        record(profileId: userId)
        return PublicProfile(id: userId, displayName: displayNames[userId])
    }

    /// lock/unlock は async コンテキストから直接呼べない（noasync）ため、
    /// 同期メソッドに切り出してから呼ぶ（FollowListViewModelTests と同じ流儀）
    private func record(postId: String? = nil, profileId: String? = nil) {
        lock.lock()
        if let postId { fetchedPostIdsStorage.append(postId) }
        if let profileId { fetchedProfileIdsStorage.append(profileId) }
        lock.unlock()
    }
}
