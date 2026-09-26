//
//  RankingAggregatorTests.swift
//  SoramoyouTests
//
//  いいねランキング（週間 / 月間）の集計ロジックのテスト ⭐️
//

import XCTest
@testable import Soramoyou

final class RankingAggregatorTests: XCTestCase {
    /// 基準時刻（テストを実行日に依存させない）
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - RankingPeriod

    func testWindowStartGoesBackSevenDaysForWeekly() {
        let start = RankingPeriod.weekly.windowStart(now: now)
        XCTAssertEqual(now.timeIntervalSince(start), 7 * 24 * 60 * 60)
    }

    func testWindowStartGoesBackThirtyDaysForMonthly() {
        let start = RankingPeriod.monthly.windowStart(now: now)
        XCTAssertEqual(now.timeIntervalSince(start), 30 * 24 * 60 * 60)
    }

    // MARK: - candidates

    func testCandidatesGroupLikesByPostAndSortByCount() {
        let likes = [
            like(user: "u1", post: "A", minutesAgo: 10),
            like(user: "u2", post: "B", minutesAgo: 20),
            like(user: "u3", post: "B", minutesAgo: 30),
            like(user: "u4", post: "C", minutesAgo: 5)
        ]

        let candidates = RankingAggregator.candidates(from: likes)

        // B（2件）が先頭。A と C は同数なので、いいねが新しい C が先
        XCTAssertEqual(candidates.map(\.postId), ["B", "C", "A"])
        XCTAssertEqual(candidates.map(\.rawLikeCount), [2, 1, 1])
    }

    func testCandidatesCountSameUserOnlyOnce() {
        // ID 設計上は起きないが、重複しても 1 人 1 件として数える
        let likes = [
            like(user: "u1", post: "A", minutesAgo: 10),
            like(user: "u1", post: "A", minutesAgo: 5)
        ]

        let candidates = RankingAggregator.candidates(from: likes)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.rawLikeCount, 1)
        XCTAssertEqual(candidates.first?.latestLikedAt, now.addingTimeInterval(-5 * 60))
    }

    func testCandidatesAreDeterministicWhenCountAndTimeTie() {
        // いいね数も時刻も同じなら postId の昇順（実行ごとに並びが変わらない）
        let likes = [
            like(user: "u1", post: "Z", minutesAgo: 10),
            like(user: "u2", post: "M", minutesAgo: 10),
            like(user: "u3", post: "A", minutesAgo: 10)
        ]

        let candidates = RankingAggregator.candidates(from: likes)

        XCTAssertEqual(candidates.map(\.postId), ["A", "M", "Z"])
    }

    // MARK: - rank

    func testRankExcludesSelfLikes() {
        // A: 投稿者本人 + 1 人 → 1 件、B: 他人 2 人 → 2 件
        let likes = [
            like(user: "ownerA", post: "A", minutesAgo: 1),
            like(user: "u1", post: "A", minutesAgo: 2),
            like(user: "u2", post: "B", minutesAgo: 3),
            like(user: "u3", post: "B", minutesAgo: 4)
        ]
        let posts = [
            "A": post(id: "A", owner: "ownerA"),
            "B": post(id: "B", owner: "ownerB")
        ]

        let ranked = rank(likes: likes, posts: posts)

        XCTAssertEqual(ranked.map(\.post.id), ["B", "A"])
        XCTAssertEqual(ranked.map(\.likeCount), [2, 1])
    }

    func testRankDropsPostsWithOnlySelfLikes() {
        let likes = [like(user: "ownerA", post: "A", minutesAgo: 1)]
        let posts = ["A": post(id: "A", owner: "ownerA")]

        XCTAssertTrue(rank(likes: likes, posts: posts).isEmpty)
    }

    func testRankIncludesOnlyPublicPosts() {
        let likes = [
            like(user: "u1", post: "public", minutesAgo: 1),
            like(user: "u1", post: "followers", minutesAgo: 1),
            like(user: "u2", post: "followers", minutesAgo: 2),
            like(user: "u1", post: "private", minutesAgo: 1)
        ]
        let posts = [
            "public": post(id: "public", owner: "o1", visibility: .public),
            "followers": post(id: "followers", owner: "o2", visibility: .followers),
            "private": post(id: "private", owner: "o3", visibility: .private)
        ]

        XCTAssertEqual(rank(likes: likes, posts: posts).map(\.post.id), ["public"])
    }

    func testRankSkipsPostsThatCouldNotBeFetched() {
        // 削除済み・読めない投稿（posts に無い）は順位に入れない
        let likes = [
            like(user: "u1", post: "deleted", minutesAgo: 1),
            like(user: "u2", post: "deleted", minutesAgo: 1),
            like(user: "u1", post: "A", minutesAgo: 1)
        ]
        let posts = ["A": post(id: "A", owner: "o1")]

        let ranked = rank(likes: likes, posts: posts)

        XCTAssertEqual(ranked.map(\.post.id), ["A"])
        XCTAssertEqual(ranked.first?.rank, 1)
    }

    func testRankExcludesBlockedAuthorsWithoutLeavingGaps() {
        let likes = [
            like(user: "u1", post: "A", minutesAgo: 1),
            like(user: "u2", post: "A", minutesAgo: 1),
            like(user: "u1", post: "B", minutesAgo: 1)
        ]
        let posts = [
            "A": post(id: "A", owner: "blocked"),
            "B": post(id: "B", owner: "o1")
        ]

        let ranked = RankingAggregator.rank(
            candidates: RankingAggregator.candidates(from: likes),
            posts: posts,
            blockedUserIds: ["blocked"],
            limit: 30
        )

        // ブロック相手の A を除いた B が 1 位（2 位にならない）
        XCTAssertEqual(ranked.map(\.post.id), ["B"])
        XCTAssertEqual(ranked.first?.rank, 1)
    }

    func testRankUsesCompetitionRankingForTies() {
        // 件数: A=3, B=2, C=2, D=1 → 順位 1, 2, 2, 4
        let likes = [
            like(user: "u1", post: "A", minutesAgo: 1),
            like(user: "u2", post: "A", minutesAgo: 1),
            like(user: "u3", post: "A", minutesAgo: 1),
            like(user: "u1", post: "B", minutesAgo: 2),
            like(user: "u2", post: "B", minutesAgo: 2),
            like(user: "u1", post: "C", minutesAgo: 3),
            like(user: "u2", post: "C", minutesAgo: 3),
            like(user: "u1", post: "D", minutesAgo: 4)
        ]
        let posts = Dictionary(uniqueKeysWithValues: ["A", "B", "C", "D"].map { ($0, post(id: $0, owner: "o")) })

        let ranked = rank(likes: likes, posts: posts)

        XCTAssertEqual(ranked.map(\.post.id), ["A", "B", "C", "D"])
        XCTAssertEqual(ranked.map(\.rank), [1, 2, 2, 4])
    }

    func testRankRespectsLimit() {
        let likes = (0..<5).map { like(user: "u1", post: "P\($0)", minutesAgo: Double($0)) }
        let posts = Dictionary(uniqueKeysWithValues: (0..<5).map { ("P\($0)", post(id: "P\($0)", owner: "o")) })

        let ranked = RankingAggregator.rank(
            candidates: RankingAggregator.candidates(from: likes),
            posts: posts,
            blockedUserIds: [],
            limit: 3
        )

        XCTAssertEqual(ranked.count, 3)
        // 同数なので、いいねが新しい順
        XCTAssertEqual(ranked.map(\.post.id), ["P0", "P1", "P2"])
    }

    func testRankReordersWhenSelfLikeIsRemoved() {
        // 暫定値では A(2) > B(1) だが、A の 1 件は本人 → A(1) と B(1) の同数になり、
        // いいねが新しい B が先に来る
        let likes = [
            like(user: "ownerA", post: "A", minutesAgo: 1),
            like(user: "u1", post: "A", minutesAgo: 30),
            like(user: "u2", post: "B", minutesAgo: 10)
        ]
        let posts = [
            "A": post(id: "A", owner: "ownerA"),
            "B": post(id: "B", owner: "ownerB")
        ]

        let ranked = rank(likes: likes, posts: posts)

        XCTAssertEqual(ranked.map(\.post.id), ["B", "A"])
        XCTAssertEqual(ranked.map(\.rank), [1, 1])
    }

    // MARK: - shouldFetchMore

    func testShouldFetchMoreWhenRankingIsNotFull() {
        let next = RankingAggregator.Candidate(postId: "X", likedAtByUserId: ["u1": now])
        XCTAssertTrue(RankingAggregator.shouldFetchMore(ranked: [], nextCandidate: next, limit: 30))
    }

    func testShouldNotFetchMoreWhenNoCandidatesRemain() {
        XCTAssertFalse(RankingAggregator.shouldFetchMore(ranked: [], nextCandidate: nil, limit: 30))
    }

    func testShouldFetchMoreOnlyWhenNextCandidateCanBeatBoundary() {
        let ranked = [RankedPost(rank: 1, post: post(id: "A", owner: "o"), likeCount: 2)]
        let beats = RankingAggregator.Candidate(postId: "X", likedAtByUserId: ["u1": now, "u2": now, "u3": now])
        let ties = RankingAggregator.Candidate(postId: "Y", likedAtByUserId: ["u1": now, "u2": now])

        XCTAssertTrue(RankingAggregator.shouldFetchMore(ranked: ranked, nextCandidate: beats, limit: 1))
        XCTAssertFalse(RankingAggregator.shouldFetchMore(ranked: ranked, nextCandidate: ties, limit: 1))
    }

    // MARK: - Helpers

    private func like(user: String, post: String, minutesAgo: Double) -> Like {
        Like(userId: user, postId: post, createdAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    private func post(id: String, owner: String, visibility: Visibility = .public) -> Post {
        Post(id: id, userId: owner, images: [], visibility: visibility)
    }

    private func rank(likes: [Like], posts: [String: Post]) -> [RankedPost] {
        RankingAggregator.rank(
            candidates: RankingAggregator.candidates(from: likes),
            posts: posts,
            blockedUserIds: [],
            limit: 30
        )
    }
}
