//
//  UserProfileViewModelTests.swift ⭐️
//  SoramoyouTests
//
//  他ユーザープロフィールの「投稿グリッドが常に空」不具合（欠陥 D）の再発防止テスト。
//
//  検証の要点は 2 つ:
//  1. フォロー状態に応じて **正しい公開範囲** で Firestore に問い合わせていること
//     （未フォロー相手に ['public','followers'] を投げると rules の followers 枝を
//       満たせず「クエリ全体」が denied になり、公開投稿まで巻き添えで消えるため）
//  2. 取得失敗を **握りつぶしていない** こと（旧実装は catch で [] を返すだけだった）
//
//  最小 Mock（fetchVisibleUserPosts / fetchPublicProfile のみ上書き、残りは
//  FirestoreServiceProtocol+TestDefaults）で検証する。
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

@MainActor
final class UserProfileViewModelTests: XCTestCase {
    // MARK: - 公開範囲の分岐

    /// 未フォローの相手には `[.public]` だけを要求する（followers を混ぜない）
    func testLoadRequestsPublicOnlyWhenNotFollowing() async {
        // Arrange: フォローしていない状態
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedPosts = [makePost(id: "p1", visibility: .public)]
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert: 公開範囲は public のみ
        XCTAssertEqual(firestore.capturedVisibilities, [[.public]],
                       "未フォロー時に followers を混ぜるとクエリ全体が denied になる")
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1"])
        XCTAssertNil(viewModel.errorMessage)
    }

    /// フォロー中の相手には `[.public, .followers]` を要求する
    func testLoadRequestsPublicAndFollowersWhenFollowing() async {
        // Arrange: フォロー中
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedPosts = [
            makePost(id: "p1", visibility: .public),
            makePost(id: "p2", visibility: .followers),
        ]
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert: followers 限定投稿も要求し、結果をそのまま表示する（手元 filter で消さない）
        XCTAssertEqual(firestore.capturedVisibilities, [[.public, .followers]])
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"],
                       "フォロワー限定投稿を手元で除外してはいけない")
    }

    /// 投稿取得はフォロー状態が確定した **後** に 1 回だけ実行される
    func testLoadFetchesPostsOnceAfterFollowStateResolved() async {
        // Arrange
        let firestore = MockFirestoreServiceForUserProfile()
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert: 並列実行して未フォロー扱いのクエリを投げていないこと
        XCTAssertEqual(firestore.capturedVisibilities.count, 1)
        XCTAssertEqual(firestore.capturedVisibilities.first, [.public, .followers])
    }

    // MARK: - エラーを握りつぶさない

    /// 取得失敗時に errorMessage を設定する（旧実装は [] を返すだけで無言だった）
    func testLoadSurfacesFetchErrorInsteadOfSwallowing() async {
        // Arrange: 投稿取得が失敗する
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedPostsError = NSError(
            domain: "test", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"]
        )
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert: posts が空なのは旧実装でも同じなので、errorMessage で判定する
        XCTAssertNotNil(viewModel.errorMessage,
                        "取得失敗を握りつぶすと「常に空」不具合が本番で見えなくなる")
        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
    }

    /// フォロー状態の取得失敗を可視化しつつ、安全側（public のみ）に降格すること ⭐️
    ///
    /// `isFollowing` は投稿クエリの visibility 集合を決める入力なので、取得失敗を
    /// 無言で「未フォロー」に倒すとフォロワー限定投稿が理由も分からず不可視に消え、
    /// 「rules の followers 枝が通るか」を確かめる R1 プローブの誤読も生む。
    /// 降格はするが errorMessage には必ず出す、という約束を固定する。
    func testLoadSurfacesIsFollowingErrorAndFallsBackToPublicOnly() async {
        // Arrange: フォロー中の相手だが、フォロー状態の取得に失敗する
        let firestore = MockFirestoreServiceForUserProfile()
        let follows = MockFollowRepository(isFollowingResult: true)
        follows.isFollowingError = NSError(
            domain: "test", code: 14,
            userInfo: [NSLocalizedDescriptionKey: "unavailable"]
        )
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert: 失敗を握りつぶさない
        XCTAssertNotNil(viewModel.errorMessage,
                        "isFollowing の失敗を無言で未フォローに倒すと、原因不明のまま投稿が消える")

        // Assert: 降格挙動は維持（証明できる public だけを要求する）
        XCTAssertEqual(firestore.capturedVisibilities, [[.public]],
                       "取得できなかったフォロー状態を根拠に followers を混ぜてはいけない")
        XCTAssertFalse(viewModel.isFollowing)
    }

    // MARK: - フォロー操作後の再取得

    /// フォロー成功後は新しい公開範囲で投稿を取り直す
    func testToggleFollowRefetchesPostsWithFollowersVisibility() async {
        // Arrange: 未フォロー状態でロード済み
        let firestore = MockFirestoreServiceForUserProfile()
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)
        await viewModel.load()
        XCTAssertEqual(firestore.capturedVisibilities, [[.public]])

        // Act: フォローする
        await viewModel.toggleFollow()

        // Assert: 2 回目のクエリは followers を含む
        XCTAssertEqual(firestore.capturedVisibilities,
                       [[.public], [.public, .followers]],
                       "フォロー直後にフォロワー限定投稿が見えるようにならない")
        XCTAssertTrue(viewModel.isFollowing)
    }

    /// フォロー解除後は public のみで取り直す（フォロワー限定投稿を残さない）
    func testToggleUnfollowRefetchesPostsWithPublicOnly() async {
        // Arrange: フォロー中の状態でロード済み
        let firestore = MockFirestoreServiceForUserProfile()
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)
        await viewModel.load()

        // Act: フォロー解除
        await viewModel.toggleFollow()

        // Assert: 2 回目のクエリは public のみ
        XCTAssertEqual(firestore.capturedVisibilities,
                       [[.public, .followers], [.public]])
        XCTAssertFalse(viewModel.isFollowing)
    }

    // MARK: - Helpers

    private func makeViewModel(
        firestore: MockFirestoreServiceForUserProfile,
        follows: MockFollowRepository
    ) -> UserProfileViewModel {
        UserProfileViewModel(
            targetUserId: "target",
            ownUserId: "me",
            firestoreService: firestore,
            followRepository: follows
        )
    }

    private func makePost(id: String, visibility: Visibility) -> Post {
        Post(id: id, userId: "target", images: [], visibility: visibility)
    }
}

// MARK: - Mocks

/// `fetchVisibleUserPosts` / `fetchPublicProfile` のみ上書きする最小 Mock。
/// 残りは FirestoreServiceProtocol+TestDefaults（fatalError）で満たす。
final class MockFirestoreServiceForUserProfile: FirestoreServiceProtocol {
    /// 呼び出しごとに要求された公開範囲を記録する（呼び出し回数の検証も兼ねる）
    private(set) var capturedVisibilities: [[Visibility]] = []
    var stubbedPosts: [Post] = []
    var stubbedPostsError: Error?

    func fetchVisibleUserPosts(
        userId _: String,
        visibilities: [Visibility],
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> [Post] {
        capturedVisibilities.append(visibilities)
        if let stubbedPostsError { throw stubbedPostsError }
        return stubbedPosts
    }

    func fetchPublicProfile(userId: String) async throws -> PublicProfile {
        PublicProfile(id: userId, displayName: "テストユーザー")
    }
}

/// フォロー状態を固定で返し、follow/unfollow で切り替える最小 Mock。
/// `FollowRepositoryProtocol` は Sendable 継承のため `@unchecked Sendable` を付ける
/// （テストは @MainActor 上でのみ触るので実質的な競合は起きない）。
final class MockFollowRepository: FollowRepositoryProtocol, @unchecked Sendable {
    private var isFollowingResult: Bool
    /// isFollowing が投げるエラー（フォロー状態の取得失敗を再現する）
    var isFollowingError: Error?

    init(isFollowingResult: Bool) {
        self.isFollowingResult = isFollowingResult
    }

    func follow(_: String, by _: String) async throws {
        isFollowingResult = true
    }

    func unfollow(_: String, by _: String) async throws {
        isFollowingResult = false
    }

    func isFollowing(_: String, by _: String) async throws -> Bool {
        if let isFollowingError { throw isFollowingError }
        return isFollowingResult
    }
}
