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
        XCTAssertNil(viewModel.rankedEntry(for: "A"), "新着に戻したら順位は出さない")
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

    func testOlderRequestForSamePeriodDoesNotOverwriteNewerResult() async {
        // 週間の取得中に引っ張って更新 → 後の取得が先に終わり、先の古い取得が後から返ってくる
        rankingService.entriesByPeriod[.weekly] = [entry(rank: 1, postId: "OLD", likes: 1)]
        rankingService.suspendFirstCall = true
        let firstLoad = Task { await viewModel.setSortOrder(.weeklyRanking) }
        while !rankingService.isFirstCallSuspended {
            await Task.yield()
        }

        rankingService.entriesByPeriod[.weekly] = [entry(rank: 1, postId: "NEW", likes: 5)]
        await viewModel.refresh()
        rankingService.resumeFirstCall()
        await firstLoad.value

        // 一覧も順位表示も新しい結果のまま（古い結果で順位表示の元データを上書きしない）
        XCTAssertEqual(viewModel.posts.map(\.id), ["NEW"])
        XCTAssertEqual(viewModel.rankedEntry(for: "NEW")?.likeCount, 5)
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

    // MARK: - 表示用の並び（rankingDisplayEntries）

    func testRankingDisplayEntriesFollowPostsOrder() async {
        rankingService.entriesByPeriod[.weekly] = [
            entry(rank: 1, postId: "A", likes: 5),
            entry(rank: 2, postId: "B", likes: 4),
            entry(rank: 2, postId: "C", likes: 4)
        ]

        await viewModel.setSortOrder(.weeklyRanking)

        XCTAssertEqual(viewModel.rankingDisplayEntries.map(\.post.id), ["A", "B", "C"])
        XCTAssertEqual(viewModel.rankingDisplayEntries.map(\.rank), [1, 2, 2])
    }

    func testRemovePostDropsEntryWithoutRenumbering() async {
        rankingService.entriesByPeriod[.weekly] = [
            entry(rank: 1, postId: "A", likes: 5),
            entry(rank: 2, postId: "B", likes: 4),
            entry(rank: 3, postId: "C", likes: 3)
        ]
        await viewModel.setSortOrder(.weeklyRanking)

        viewModel.removePost(postId: "B")

        // 消えた投稿だけ表示から外し、順位は集計時のまま（詰め直さない）
        XCTAssertEqual(viewModel.rankingDisplayEntries.map(\.post.id), ["A", "C"])
        XCTAssertEqual(viewModel.rankingDisplayEntries.map(\.rank), [1, 3])
    }

    func testRankingDisplayEntriesAreEmptyWhenNotRanking() async {
        rankingService.entriesByPeriod[.weekly] = [entry(rank: 1, postId: "A", likes: 5)]
        await viewModel.setSortOrder(.weeklyRanking)

        await viewModel.setSortOrder(.newest)

        XCTAssertTrue(viewModel.rankingDisplayEntries.isEmpty)
    }

    // MARK: - 投稿者の取得（authorsByUserId）

    func testAuthorsAreFetchedOncePerUser() async {
        // 同じ人が 2 枚ランクインしても、プロフィールの読み取りは 1 回
        rankingService.entriesByPeriod[.weekly] = [
            entry(rank: 1, postId: "A", likes: 5, userId: "u1"),
            entry(rank: 2, postId: "B", likes: 4, userId: "u1"),
            entry(rank: 3, postId: "C", likes: 3, userId: "u2")
        ]
        firestoreService.publicProfiles = [
            "u1": PublicProfile(id: "u1", displayName: "そら"),
            "u2": PublicProfile(id: "u2", displayName: "くも")
        ]

        await viewModel.setSortOrder(.weeklyRanking)

        XCTAssertEqual(firestoreService.requestedProfileUserIds.sorted(), ["u1", "u2"])
        XCTAssertEqual(viewModel.authorsByUserId["u1"]?.displayName, "そら")
        XCTAssertEqual(viewModel.authorsByUserId["u2"]?.displayName, "くも")
    }

    func testAuthorFetchFailureDoesNotAffectOthers() async {
        // 1 人だけプロフィールが無くても、他の人は辞書に入る（取れなかった人は入れない）
        rankingService.entriesByPeriod[.weekly] = [
            entry(rank: 1, postId: "A", likes: 5, userId: "u1"),
            entry(rank: 2, postId: "B", likes: 4, userId: "missing")
        ]
        firestoreService.publicProfiles = ["u1": PublicProfile(id: "u1", displayName: "そら")]

        await viewModel.setSortOrder(.weeklyRanking)

        XCTAssertEqual(viewModel.authorsByUserId["u1"]?.displayName, "そら")
        XCTAssertNil(viewModel.authorsByUserId["missing"])
        XCTAssertEqual(viewModel.posts.map(\.id), ["A", "B"], "取得失敗でもランキング自体は表示を続ける")
    }

    func testAuthorsAreNotRefetchedWhenSwitchingPeriods() async {
        // 週間 → 月間の行き来で、取得済みの人は読み直さない（新しく出てきた人だけ読む）
        rankingService.entriesByPeriod[.weekly] = [entry(rank: 1, postId: "A", likes: 5, userId: "u1")]
        rankingService.entriesByPeriod[.monthly] = [
            entry(rank: 1, postId: "A", likes: 9, userId: "u1"),
            entry(rank: 2, postId: "B", likes: 7, userId: "u2")
        ]
        firestoreService.publicProfiles = [
            "u1": PublicProfile(id: "u1", displayName: "そら"),
            "u2": PublicProfile(id: "u2", displayName: "くも")
        ]

        await viewModel.setSortOrder(.weeklyRanking)
        await viewModel.setSortOrder(.monthlyRanking)
        await viewModel.setSortOrder(.weeklyRanking)

        XCTAssertEqual(firestoreService.requestedProfileUserIds, ["u1", "u2"])
    }

    func testAuthorsAreNotFetchedOutsideRanking() async {
        // 通常のグリッドは投稿者名を出さないので、プロフィールを読まない
        firestoreService.posts = [post(id: "A")]
        firestoreService.publicProfiles = ["owner-A": PublicProfile(id: "owner-A", displayName: "そら")]

        await viewModel.setSortOrder(.newest)

        XCTAssertTrue(firestoreService.requestedProfileUserIds.isEmpty)
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

    private func post(id: String, userId: String? = nil) -> Post {
        Post(id: id, userId: userId ?? "owner-\(id)", images: [], visibility: .public)
    }

    private func entry(rank: Int, postId: String, likes: Int, userId: String? = nil) -> RankedPost {
        RankedPost(rank: rank, post: post(id: postId, userId: userId), likeCount: likes)
    }
}

// MARK: - Mock

/// ランキング取得のモック（期間ごとの結果を返し、呼ばれた期間を記録する）
final class MockRankingService: RankingServiceProtocol {
    var entriesByPeriod: [RankingPeriod: [RankedPost]] = [:]
    var error: Error?
    private(set) var requestedPeriods: [RankingPeriod] = []
    /// true なら 1 回目の取得を resumeFirstCall() まで止める（取得が重なる状況の再現用）
    var suspendFirstCall = false
    private var firstCallContinuation: CheckedContinuation<Void, Never>?

    /// 1 回目の取得が止まっているか
    var isFirstCallSuspended: Bool { firstCallContinuation != nil }

    /// 止めていた 1 回目の取得を再開する
    func resumeFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }

    func fetchRanking(period: RankingPeriod, blockedUserIds: Set<String>, now: Date) async throws -> RankingResult {
        requestedPeriods.append(period)
        // 呼ばれた時点の結果を返す（止めている間に entriesByPeriod を変えても、この取得は古いまま）
        let entries = entriesByPeriod[period] ?? []
        if suspendFirstCall && requestedPeriods.count == 1 {
            await withCheckedContinuation { continuation in
                firstCallContinuation = continuation
            }
        }
        if let error {
            throw error
        }
        return RankingResult(
            period: period,
            entries: entries,
            likeCount: entries.reduce(0) { $0 + $1.likeCount },
            isTruncated: false,
            fetchedAt: now
        )
    }
}
