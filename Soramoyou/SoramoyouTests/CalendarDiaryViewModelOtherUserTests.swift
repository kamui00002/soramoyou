//
//  CalendarDiaryViewModelOtherUserTests.swift
//  SoramoyouTests
//
//  他人の空カレンダー（CalendarDiaryViewModel.loadOtherUser）のテスト ⭐️
//
//  他人には `fetchUserPosts`（公開範囲で絞らない＝本人専用）を使えない。呼ぶとルールに
//  クエリ全体を拒否される。そのため「`fetchVisibleUserPosts` に `[.public, .followers]` を渡す」
//  「`fetchUserPosts` を 1 回も呼ばない（`.postCreated` の読み直しでも）」を、回数と値を直に書いて固定する。
//
//  ⚠️ 既存の CalendarDiaryViewModelTests.swift は未整形のファイルなので触らず、こちらに分けた。
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

@MainActor
final class CalendarDiaryViewModelOtherUserTests: XCTestCase {
    /// 2026 年 6 月 1 日 12 時（グレゴリオ暦）に撮った投稿
    /// - Parameter createdAt: 投稿日時。同じ日の中の並び（`groupByDay` は createdAt の新しい順）を決める。
    ///   ⚠️ 既定値を `Date()` 任せにしない。作った順に時刻が進むので、同じ日に 2 件並べるテストの期待が
    ///   作る順で逆になり、2 つが同じ時刻になった回だけ順が揺れる（固定の時刻を既定にする）。
    private func makePost(
        _ id: String,
        userId: String = "owner",
        visibility: Visibility = .public,
        createdAt: Date = Date(timeIntervalSince1970: 1_780_000_000)
    ) -> Post {
        let capturedAt = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 6, day: 1, hour: 12)
        )!
        return Post(
            id: id,
            userId: userId,
            images: [],
            capturedAt: capturedAt,
            visibility: visibility,
            createdAt: createdAt
        )
    }

    /// 他人用は `fetchVisibleUserPosts` に「公開・フォロワー限定」と上限 1000 を渡し、`fetchUserPosts` は呼ばない
    func testLoadOtherUserRequestsPublicAndFollowersOnly() async {
        let mock = OtherUserCalendarMockFirestoreService()
        // 同じ日の中は投稿日時の新しい順に並ぶので、pub1 を fol1 より新しくして期待の並びを決める
        mock.stubbedVisiblePosts = [
            makePost("pub1", visibility: .public, createdAt: Date(timeIntervalSince1970: 1_780_000_100)),
            makePost("fol1", visibility: .followers, createdAt: Date(timeIntervalSince1970: 1_780_000_000)),
        ]
        let viewModel = CalendarDiaryViewModel(firestoreService: mock)

        await viewModel.loadOtherUser(userId: "owner")

        XCTAssertEqual(mock.receivedVisibleQueries.count, 1)
        XCTAssertEqual(mock.receivedVisibleQueries.first?.userId, "owner")
        XCTAssertEqual(mock.receivedVisibleQueries.first?.visibilities, [.public, .followers])
        XCTAssertEqual(mock.receivedVisibleQueries.first?.limit, 1000)
        XCTAssertEqual(mock.fetchUserPostsCallCount, 0, "他人用で fetchUserPosts を呼ぶと権限エラーになる")
        XCTAssertEqual(
            viewModel.posts(on: SkyStreakDay(year: 2026, month: 6, day: 1)).map(\.id),
            ["pub1", "fol1"],
            "取れた投稿は本人用と同じく暦日ごとに並ぶ"
        )
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    /// 他人用で読んだあとに `.postCreated` が来ても、`fetchUserPosts` を呼ばない（読み直しは本人用だけ）
    func testPostCreatedAfterLoadOtherUserNeverCallsFetchUserPosts() async {
        let mock = OtherUserCalendarMockFirestoreService()
        mock.stubbedVisiblePosts = [makePost("pub1")]
        let viewModel = CalendarDiaryViewModel(firestoreService: mock)
        await viewModel.loadOtherUser(userId: "owner")

        NotificationCenter.default.post(name: .postCreated, object: nil)
        // 通知ハンドラは Task { @MainActor in ... } で非同期に実行されるため、待ってから確かめる
        // （CalendarDiaryViewModelTests の .postCreated のテストと同じ待ち方）
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(mock.fetchUserPostsCallCount, 0)
        XCTAssertEqual(mock.receivedVisibleQueries.count, 1, "他人用は通知で読み直さない")
    }

    /// 対照: 本人用は今までどおり `fetchUserPosts` で読み、`fetchVisibleUserPosts` は呼ばない
    ///
    /// 上の 2 本の「回数 0」が、Mock が数えていないせいの 0 ではないことをここで確かめる。
    func testOwnLoadStillUsesFetchUserPosts() async {
        let mock = OtherUserCalendarMockFirestoreService()
        mock.stubbedUserPosts = [makePost("own1", userId: "me")]
        let viewModel = CalendarDiaryViewModel(firestoreService: mock)

        await viewModel.load(userId: "me")

        XCTAssertEqual(mock.fetchUserPostsCallCount, 1)
        XCTAssertEqual(mock.receivedVisibleQueries.count, 0)
        XCTAssertEqual(viewModel.posts(on: SkyStreakDay(year: 2026, month: 6, day: 1)).map(\.id), ["own1"])
    }

    /// 他人用の読み込みが失敗したら、本人用と同じくエラーを出し、ローディングを解く
    func testLoadOtherUserSetsErrorMessageOnFailure() async {
        let mock = OtherUserCalendarMockFirestoreService()
        mock.stubbedVisibleError = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        let viewModel = CalendarDiaryViewModel(firestoreService: mock)

        await viewModel.loadOtherUser(userId: "owner")

        XCTAssertEqual(viewModel.errorMessage, "boom")
        XCTAssertEqual(viewModel.posts(on: SkyStreakDay(year: 2026, month: 6, day: 1)).map(\.id), [])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(mock.fetchUserPostsCallCount, 0)
    }

    /// 開いた後にフォローが外れていて読み取りがルールに拒否されたら、SDK の英語の文でなく日本語の理由を出す ⭐️ 1.18.0 PR-B
    ///
    /// 本物の `fetchVisibleUserPosts` と同じく `FirestoreServiceError.fetchFailed` で包んだ permission-denied を投げる。
    /// 上のテスト（拒否でない失敗は今までどおり `localizedDescription`）が対照。
    func testLoadOtherUserShowsFollowRemovedMessageWhenPermissionDenied() async {
        let mock = OtherUserCalendarMockFirestoreService()
        mock.stubbedVisibleError = FirestoreServiceError.fetchFailed(NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.permissionDenied.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Missing or insufficient permissions."]
        ))
        let viewModel = CalendarDiaryViewModel(firestoreService: mock)

        await viewModel.loadOtherUser(userId: "owner")

        XCTAssertEqual(viewModel.errorMessage, "フォローが外れたため、いまは空カレンダーを見られません")
        XCTAssertEqual(viewModel.posts(on: SkyStreakDay(year: 2026, month: 6, day: 1)).map(\.id), [])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(mock.fetchUserPostsCallCount, 0)
    }
}

// MARK: - Mock

/// `fetchUserPosts` と `fetchVisibleUserPosts` だけを上書きし、呼ばれた回数と渡った値を記録する Mock
///
/// ⚠️ `fetchUserPosts` も必ず上書きして数える。TestDefaults のままだと、呼ばれた瞬間に fatalError で
///    テストが「赤」ではなく「クラッシュ」になり、何回呼ばれたかを直に比べられない。
private final class OtherUserCalendarMockFirestoreService: FirestoreServiceProtocol {
    /// `fetchVisibleUserPosts` に渡った値
    struct VisibleQuery {
        let userId: String
        let visibilities: [Visibility]
        let limit: Int
    }

    var stubbedUserPosts: [Post] = []
    var stubbedVisiblePosts: [Post] = []
    var stubbedVisibleError: Error?
    private(set) var fetchUserPostsCallCount = 0
    private(set) var receivedVisibleQueries: [VisibleQuery] = []

    func fetchUserPosts(
        userId _: String,
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> [Post] {
        fetchUserPostsCallCount += 1
        return stubbedUserPosts
    }

    func fetchVisibleUserPosts(
        userId: String,
        visibilities: [Visibility],
        limit: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> [Post] {
        receivedVisibleQueries.append(VisibleQuery(userId: userId, visibilities: visibilities, limit: limit))
        if let stubbedVisibleError { throw stubbedVisibleError }
        return stubbedVisiblePosts
    }
}
