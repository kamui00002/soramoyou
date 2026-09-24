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
        lock.lock()
        fetchedPostIdsStorage.append(postId)
        lock.unlock()

        if transientFailurePostIds.contains(postId) {
            throw FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        }
        guard let post = posts[postId] else { throw FirestoreServiceError.notFound }
        return post
    }

    func fetchPublicProfile(userId: String) async throws -> PublicProfile {
        lock.lock()
        fetchedProfileIdsStorage.append(userId)
        lock.unlock()

        return PublicProfile(id: userId, displayName: displayNames[userId])
    }
}
