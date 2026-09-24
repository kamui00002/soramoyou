//
//  RankingServiceTests.swift
//  SoramoyouTests
//
//  いいねランキングの取得ループ（期間クエリ・投稿の段階取得・失敗の扱い）のテスト ⭐️
//

import XCTest
@testable import Soramoyou

final class RankingServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testFetchRankingQueriesWindowEndingNow() async throws {
        let mock = MockFirestoreServiceForRanking()
        let service = RankingService(firestoreService: mock)

        _ = try await service.fetchRanking(period: .weekly, blockedUserIds: [], now: now)

        XCTAssertEqual(mock.lastLikesQuery?.start, now.addingTimeInterval(-7 * 24 * 60 * 60))
        XCTAssertEqual(mock.lastLikesQuery?.end, now)
        XCTAssertEqual(mock.lastLikesQuery?.limit, RankingService.likeReadLimit)
    }

    func testFetchRankingReturnsRankedPublicPosts() async throws {
        let mock = MockFirestoreServiceForRanking()
        mock.likes = [
            Like(userId: "u1", postId: "A", createdAt: now),
            Like(userId: "u2", postId: "A", createdAt: now),
            Like(userId: "u1", postId: "B", createdAt: now)
        ]
        mock.posts = [
            "A": Post(id: "A", userId: "o1", images: []),
            "B": Post(id: "B", userId: "o2", images: [])
        ]
        let service = RankingService(firestoreService: mock)

        let result = try await service.fetchRanking(period: .monthly, blockedUserIds: [], now: now)

        XCTAssertEqual(result.period, .monthly)
        XCTAssertEqual(result.entries.map(\.post.id), ["A", "B"])
        XCTAssertEqual(result.entries.map(\.likeCount), [2, 1])
        XCTAssertEqual(result.likeCount, 3)
        XCTAssertFalse(result.isTruncated)
    }

    func testDeletedPostsAreSkippedWithoutFailing() async throws {
        let mock = MockFirestoreServiceForRanking()
        mock.likes = [
            Like(userId: "u1", postId: "deleted", createdAt: now),
            Like(userId: "u2", postId: "deleted", createdAt: now),
            Like(userId: "u1", postId: "A", createdAt: now)
        ]
        mock.posts = ["A": Post(id: "A", userId: "o1", images: [])]
        let service = RankingService(firestoreService: mock)

        let result = try await service.fetchRanking(period: .weekly, blockedUserIds: [], now: now)

        XCTAssertEqual(result.entries.map(\.post.id), ["A"])
    }

    func testTransientPostFetchFailureIsThrown() async {
        // 一時的な失敗で 1 件だけ黙って落とすと、嘘の順位になる → 投げてエラー表示（再試行）に回す
        let mock = MockFirestoreServiceForRanking()
        mock.likes = [Like(userId: "u1", postId: "A", createdAt: now)]
        mock.transientFailurePostIds = ["A"]
        let service = RankingService(firestoreService: mock)

        do {
            _ = try await service.fetchRanking(period: .weekly, blockedUserIds: [], now: now)
            XCTFail("一時的な失敗は投げ直されるべき")
        } catch {
            // 期待どおり
        }
    }

    func testStopsFetchingPostsWhenRankingCannotChange() async throws {
        // 35 件すべて 1 いいね → 最初の 30 件で順位表が埋まり、残りは同数なので取りに行かない
        let mock = MockFirestoreServiceForRanking()
        mock.likes = (0..<35).map { Like(userId: "u1", postId: "P\($0)", createdAt: now.addingTimeInterval(-Double($0))) }
        mock.posts = Dictionary(uniqueKeysWithValues: (0..<35).map { ("P\($0)", Post(id: "P\($0)", userId: "o", images: [])) })
        let service = RankingService(firestoreService: mock)

        let result = try await service.fetchRanking(period: .weekly, blockedUserIds: [], now: now)

        XCTAssertEqual(result.entries.count, RankingService.rankingLimit)
        XCTAssertEqual(mock.fetchedPostIds.count, RankingService.postFetchBatchSize)
    }

    func testFetchesMorePostsWhenSomeAreNotPublic() async throws {
        // 先頭 10 件が非公開 → 1 回目の 30 件では 20 件しか埋まらないので、残り 5 件も取りに行く
        let mock = MockFirestoreServiceForRanking()
        mock.likes = (0..<35).map { Like(userId: "u1", postId: "P\($0)", createdAt: now.addingTimeInterval(-Double($0))) }
        mock.posts = Dictionary(uniqueKeysWithValues: (0..<35).map { index in
            ("P\(index)", Post(id: "P\(index)", userId: "o", images: [], visibility: index < 10 ? .private : .public))
        })
        let service = RankingService(firestoreService: mock)

        let result = try await service.fetchRanking(period: .weekly, blockedUserIds: [], now: now)

        XCTAssertEqual(result.entries.count, 25)
        XCTAssertEqual(mock.fetchedPostIds.count, 35)
    }

    func testMarksResultTruncatedWhenLikeReadLimitIsReached() async throws {
        let mock = MockFirestoreServiceForRanking()
        mock.likes = (0..<RankingService.likeReadLimit).map {
            Like(userId: "u\($0)", postId: "A", createdAt: now)
        }
        mock.posts = ["A": Post(id: "A", userId: "o", images: [])]
        let service = RankingService(firestoreService: mock)

        let result = try await service.fetchRanking(period: .monthly, blockedUserIds: [], now: now)

        XCTAssertTrue(result.isTruncated)
    }
}

// MARK: - Mock

/// ランキング用のモック。fetchPost は TaskGroup から並列に呼ばれるため記録はロックで守る。
final class MockFirestoreServiceForRanking: FirestoreServiceProtocol, @unchecked Sendable {
    struct LikesQuery {
        let start: Date
        let end: Date
        let limit: Int
    }

    var likes: [Like] = []
    var posts: [String: Post] = [:]
    /// 一時的な失敗（ネットワーク断相当）を返す postId
    var transientFailurePostIds: Set<String> = []

    private let lock = NSLock()
    private(set) var lastLikesQuery: LikesQuery?
    private var fetchedPostIdsStorage: [String] = []

    var fetchedPostIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return fetchedPostIdsStorage
    }

    func fetchLikes(from start: Date, to end: Date, limit: Int) async throws -> [Like] {
        lastLikesQuery = LikesQuery(start: start, end: end, limit: limit)
        return Array(likes.prefix(limit))
    }

    func fetchPost(postId: String) async throws -> Post {
        lock.lock()
        fetchedPostIdsStorage.append(postId)
        lock.unlock()

        if transientFailurePostIds.contains(postId) {
            throw FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        }
        guard let post = posts[postId] else {
            throw FirestoreServiceError.notFound
        }
        return post
    }
}
