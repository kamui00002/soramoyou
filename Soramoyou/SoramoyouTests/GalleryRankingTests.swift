//
//  GalleryRankingTests.swift
//  SoramoyouTests
//
//  ギャラリーの週間 / 月間ランキング（GalleryViewModel のランキングモード）のテスト ⭐️
//

import XCTest
@testable import Soramoyou

@MainActor
final class GalleryRankingTests: XCTestCase {
    private var firestoreService: MockFirestoreServiceForGallery!
    private var rankingService: MockRankingService!
    private var currentTime = Date(timeIntervalSince1970: 1_790_000_000)
    private var viewModel: GalleryViewModel!

    override func setUp() {
        super.setUp()
        firestoreService = MockFirestoreServiceForGallery()
        rankingService = MockRankingService()
        viewModel = GalleryViewModel(
            firestoreService: firestoreService,
            rankingService: rankingService,
            now: { [unowned self] in self.currentTime }
        )
    }

    override func tearDown() {
        viewModel = nil
        rankingService = nil
        firestoreService = nil
        super.tearDown()
    }

    // MARK: - 表示

    func testWeeklyRankingShowsRankedPostsInOrder() async {
        rankingService.entriesByPeriod[.weekly] = [
            entry(rank: 1, postId: "A", likes: 5),
            entry(rank: 2, postId: "B", likes: 3)
        ]

        await viewModel.setSortOrder(.weeklyRanking)

        XCTAssertTrue(viewModel.isRankingMode)
        XCTAssertEqual(viewModel.posts.map(\.id), ["A", "B"])
        XCTAssertEqual(viewModel.rankedEntry(for: "A")?.rank, 1)
        XCTAssertEqual(viewModel.rankedEntry(for: "B")?.likeCount, 3)
        XCTAssertEqual(rankingService.requestedPeriods, [.weekly])
    }

    func testRankingDoesNotPaginate() async {
        // ちょうど 30 件（ページサイズと同数）でも「続きがある」扱いにしない
        rankingService.entriesByPeriod[.monthly] = (1...30).map { entry(rank: $0, postId: "P\($0)", likes: 31 - $0) }

        await viewModel.setSortOrder(.monthlyRanking)
        XCTAssertFalse(viewModel.hasMorePosts)

        await viewModel.loadMorePosts()
        XCTAssertEqual(viewModel.posts.count, 30)
    }

    func testRankedEntryIsNilOutsideRankingMode() async {
        rankingService.entriesByPeriod[.weekly] = [entry(rank: 1, postId: "A", likes: 5)]
        await viewModel.setSortOrder(.weeklyRanking)

        await viewModel.setSortOrder(.newest)

        XCTAssertFalse(viewModel.isRankingMode)
        XCTAssertNil(viewModel.rankedEntry(for: "A"), "新着に戻したら順位バッジは出さない")
    }

    func testBadgesFollowTheDisplayedPeriod() async {
        rankingService.entriesByPeriod[.weekly] = [entry(rank: 1, postId: "A", likes: 5)]
        rankingService.entriesByPeriod[.monthly] = [
            entry(rank: 1, postId: "B", likes: 9),
            entry(rank: 2, postId: "A", likes: 7)
        ]

        await viewModel.setSortOrder(.weeklyRanking)
        await viewModel.setSortOrder(.monthlyRanking)

        // 月間を表示中は月間の順位（A は 2 位）を出す
        XCTAssertEqual(viewModel.rankedEntry(for: "A")?.rank, 2)
        XCTAssertEqual(viewModel.rankedEntry(for: "A")?.likeCount, 7)
    }

    // MARK: - 絞り込みとの関係

    func testRankingCannotBeSelectedWhileFilterIsActive() async {
        await viewModel.selectTimeOfDay(.morning)

        await viewModel.setSortOrder(.weeklyRanking)

        XCTAssertEqual(viewModel.sortOrder, .newest)
        XCTAssertFalse(viewModel.isRankingMode)
        XCTAssertTrue(rankingService.requestedPeriods.isEmpty)
    }

    func testSelectingFilterWhileRankingFallsBackToNewest() async {
        rankingService.entriesByPeriod[.weekly] = [entry(rank: 1, postId: "A", likes: 5)]
        await viewModel.setSortOrder(.weeklyRanking)

        await viewModel.selectTimeOfDay(.morning)

        XCTAssertEqual(viewModel.effectiveSortOrder, .newest)
        XCTAssertFalse(viewModel.isRankingMode)
        XCTAssertEqual(viewModel.sortOrder, .weeklyRanking, "解除後に戻せるよう選択自体は保持する")
    }

    // MARK: - シャッフル

    func testShuffleIsIgnoredInRankingMode() async {
        rankingService.entriesByPeriod[.weekly] = [entry(rank: 1, postId: "A", likes: 5)]
        await viewModel.setSortOrder(.weeklyRanking)

        await viewModel.toggleShuffle()

        XCTAssertFalse(viewModel.isShuffled)
    }

    func testRankingKeepsOrderEvenIfShuffleWasOn() async {
        firestoreService.posts = [post(id: "X")]
        await viewModel.fetchPosts()
        await viewModel.toggleShuffle()
        XCTAssertTrue(viewModel.isShuffled)

        rankingService.entriesByPeriod[.weekly] = (1...10).map { entry(rank: $0, postId: "P\($0)", likes: 11 - $0) }
        await viewModel.setSortOrder(.weeklyRanking)

        XCTAssertEqual(viewModel.posts.map(\.id), (1...10).map { "P\($0)" })
    }

    // MARK: - キャッシュ

    func testRankingIsCachedWithinLifetime() async {
        rankingService.entriesByPeriod[.weekly] = [entry(rank: 1, postId: "A", likes: 5)]

        await viewModel.setSortOrder(.weeklyRanking)
        await viewModel.setSortOrder(.newest)
        currentTime = currentTime.addingTimeInterval(GalleryViewModel.rankingCacheLifetime - 1)
        await viewModel.setSortOrder(.weeklyRanking)

        XCTAssertEqual(rankingService.requestedPeriods, [.weekly])
    }

    func testRankingIsRefetchedAfterLifetime() async {
        rankingService.entriesByPeriod[.weekly] = [entry(rank: 1, postId: "A", likes: 5)]

        await viewModel.setSortOrder(.weeklyRanking)
        currentTime = currentTime.addingTimeInterval(GalleryViewModel.rankingCacheLifetime + 1)
        await viewModel.setSortOrder(.weeklyRanking)

        XCTAssertEqual(rankingService.requestedPeriods, [.weekly, .weekly])
    }

    func testRefreshBypassesRankingCache() async {
        rankingService.entriesByPeriod[.weekly] = [entry(rank: 1, postId: "A", likes: 5)]

        await viewModel.setSortOrder(.weeklyRanking)
        await viewModel.refresh()

        XCTAssertEqual(rankingService.requestedPeriods, [.weekly, .weekly])
    }

    // MARK: - エラー

    func testRankingErrorIsSurfaced() async {
        // ⚠️ ネットワーク系のエラーは RetryableOperation がバックオフ付きで再試行してテストが遅くなるため、
        //    再試行されない notFound を使う（既存の GalleryViewModelTests と同じ）
        rankingService.error = FirestoreServiceError.notFound

        await viewModel.setSortOrder(.weeklyRanking)

        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertNotNil(viewModel.lastError)
    }

    // MARK: - 並び替えの値

    func testSortOrderProperties() {
        XCTAssertEqual(GallerySortOrder.newest.sortField, "createdAt")
        XCTAssertEqual(GallerySortOrder.popular.sortField, "likesCount")
        XCTAssertNil(GallerySortOrder.weeklyRanking.sortField)
        XCTAssertEqual(GallerySortOrder.weeklyRanking.rankingPeriod, .weekly)
        XCTAssertEqual(GallerySortOrder.monthlyRanking.rankingPeriod, .monthly)
        XCTAssertNil(GallerySortOrder.popular.rankingPeriod)
        XCTAssertEqual(GallerySortOrder.weeklyRanking.analyticsValue, "weekly_ranking")
        XCTAssertEqual(GallerySortOrder.monthlyRanking.analyticsValue, "monthly_ranking")
    }

    // MARK: - Helpers

    private func post(id: String) -> Post {
        Post(id: id, userId: "owner-\(id)", images: [], visibility: .public)
    }

    private func entry(rank: Int, postId: String, likes: Int) -> RankedPost {
        RankedPost(rank: rank, post: post(id: postId), likeCount: likes)
    }
}

// MARK: - Mock

/// ランキング取得のモック（期間ごとの結果を返し、呼ばれた期間を記録する）
final class MockRankingService: RankingServiceProtocol {
    var entriesByPeriod: [RankingPeriod: [RankedPost]] = [:]
    var error: Error?
    private(set) var requestedPeriods: [RankingPeriod] = []

    func fetchRanking(period: RankingPeriod, blockedUserIds: Set<String>, now: Date) async throws -> RankingResult {
        requestedPeriods.append(period)
        if let error {
            throw error
        }
        let entries = entriesByPeriod[period] ?? []
        return RankingResult(
            period: period,
            entries: entries,
            likeCount: entries.reduce(0) { $0 + $1.likeCount },
            isTruncated: false,
            fetchedAt: now
        )
    }
}
