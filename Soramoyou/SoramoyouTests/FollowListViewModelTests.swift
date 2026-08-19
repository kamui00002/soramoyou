//
//  FollowListViewModelTests.swift ⭐️
//  SoramoyouTests
//
//  フォロワー / フォロー中一覧（PR-5）の ViewModel テスト。
//
//  検証の要点:
//  1. 一覧種別に応じて **正しい向き** の uid を表示対象にすること
//     （フォロワー一覧 = followerId ／ フォロー中一覧 = followeeId。
//       ここを取り違えると「フォロワー一覧に自分がずらっと並ぶ」事故になる）
//  2. ページングの打ち切り判定（1ページ未満で hasMore=false）
//  3. フォロワー削除の成功で行が消え、失敗では行が残って errorMessage が出ること
//     （削除は Firestore 側の削除が確定してから行を消す＝楽観的更新をしない）
//
//  Mock は fetchFollowers / fetchFollowing / removeFollower のみ上書きし、
//  残りは FollowRepositoryProtocol+TestDefaults（fatalError）で満たす。
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

@MainActor
final class FollowListViewModelTests: XCTestCase {
    // MARK: - 表示対象の uid の向き

    /// フォロワー一覧では「フォローしてきた側」（followerId）を表示する
    func testFollowersListDisplaysFollowerIds() async {
        // Arrange: me が A・B にフォローされている
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[
            makeFollow(follower: "userA", followee: "me"),
            makeFollow(follower: "userB", followee: "me"),
        ]]
        let viewModel = makeViewModel(listType: .followers, repository: repository)

        // Act
        await viewModel.fetchFirstPage()

        // Assert: 行に出るのは A と B（me ではない）
        XCTAssertEqual(viewModel.follows.map { viewModel.displayUserId(for: $0) },
                       ["userA", "userB"])
        XCTAssertEqual(repository.fetchFollowersCallCount, 1)
        XCTAssertEqual(repository.fetchFollowingCallCount, 0)
    }

    /// フォロー中一覧では「フォローされている側」（followeeId）を表示する
    func testFollowingListDisplaysFolloweeIds() async {
        // Arrange: me が A・B をフォローしている
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[
            makeFollow(follower: "me", followee: "userA"),
            makeFollow(follower: "me", followee: "userB"),
        ]]
        let viewModel = makeViewModel(listType: .following, repository: repository)

        // Act
        await viewModel.fetchFirstPage()

        // Assert
        XCTAssertEqual(viewModel.follows.map { viewModel.displayUserId(for: $0) },
                       ["userA", "userB"])
        XCTAssertEqual(repository.fetchFollowingCallCount, 1)
        XCTAssertEqual(repository.fetchFollowersCallCount, 0)
    }

    // MARK: - ページング

    /// 1 ページに満たない件数なら hasMore は false（無限に読み続けない）
    func testHasMoreIsFalseWhenPageIsNotFull() async {
        // Arrange: pageSize=3 に対して 2 件だけ返す
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[
            makeFollow(follower: "userA", followee: "me"),
            makeFollow(follower: "userB", followee: "me"),
        ]]
        let viewModel = makeViewModel(listType: .followers, repository: repository, pageSize: 3)

        // Act
        await viewModel.fetchFirstPage()

        // Assert
        XCTAssertFalse(viewModel.hasMore)
    }

    /// ちょうど 1 ページ分なら hasMore は true のままで、loadMore が次ページを足す
    func testLoadMoreAppendsNextPage() async {
        // Arrange: pageSize=2。1ページ目は満杯、2ページ目は 1 件
        let repository = MockFollowListRepository()
        repository.stubbedPages = [
            [
                makeFollow(follower: "userA", followee: "me"),
                makeFollow(follower: "userB", followee: "me"),
            ],
            [
                makeFollow(follower: "userC", followee: "me"),
            ],
        ]
        let viewModel = makeViewModel(listType: .followers, repository: repository, pageSize: 2)

        // Act
        await viewModel.fetchFirstPage()
        XCTAssertTrue(viewModel.hasMore)
        await viewModel.loadMore()

        // Assert: 3 件になり、末尾判定で hasMore が落ちる
        XCTAssertEqual(viewModel.follows.map { viewModel.displayUserId(for: $0) },
                       ["userA", "userB", "userC"])
        XCTAssertFalse(viewModel.hasMore)
    }

    // MARK: - 初回ロードの失敗

    /// 取得失敗を握りつぶさず lastError に出す（一覧が「常に空」で沈黙しない）
    func testFetchFirstPageSurfacesError() async {
        // Arrange
        let repository = MockFollowListRepository()
        repository.stubbedFetchError = NSError(
            domain: "test", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"]
        )
        let viewModel = makeViewModel(listType: .followers, repository: repository)

        // Act
        await viewModel.fetchFirstPage()

        // Assert
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertTrue(viewModel.follows.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - フォロワー削除

    /// 削除成功で該当行だけが消え、リポジトリには正しい向きの引数が渡る
    func testRemoveFollowerRemovesRowOnSuccess() async {
        // Arrange: 自分（me）のフォロワー一覧
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[
            makeFollow(follower: "userA", followee: "me"),
            makeFollow(follower: "userB", followee: "me"),
        ]]
        let viewModel = makeViewModel(listType: .followers, repository: repository)
        await viewModel.fetchFirstPage()

        // Act: userA を削除
        await viewModel.removeFollower(userId: "userA")

        // Assert: userA の行だけ消える
        XCTAssertEqual(viewModel.follows.map(\.followerId), ["userB"])
        // 引数の向き: 「userA を me のフォロワーから外す」
        XCTAssertEqual(repository.capturedRemovals.count, 1)
        XCTAssertEqual(repository.capturedRemovals.first?.follower, "userA")
        XCTAssertEqual(repository.capturedRemovals.first?.owner, "me")
        XCTAssertNil(viewModel.errorMessage)
    }

    /// 削除失敗では行を消さず errorMessage を出す（楽観的更新をしない約束の固定）
    func testRemoveFollowerKeepsRowOnFailure() async {
        // Arrange
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[
            makeFollow(follower: "userA", followee: "me"),
        ]]
        repository.stubbedRemoveError = NSError(
            domain: "test", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"]
        )
        let viewModel = makeViewModel(listType: .followers, repository: repository)
        await viewModel.fetchFirstPage()

        // Act
        await viewModel.removeFollower(userId: "userA")

        // Assert: 行は残り、エラーが見える
        XCTAssertEqual(viewModel.follows.map(\.followerId), ["userA"])
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// 他人のフォロワー一覧では削除を実行しない（ボタン非表示の裏の防御）
    func testRemoveFollowerIsNoOpWhenNotOwnList() async {
        // Arrange: 閲覧者 me が other のフォロワー一覧を見ている
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[
            makeFollow(follower: "userA", followee: "other"),
        ]]
        let viewModel = FollowListViewModel(
            listType: .followers,
            targetUserId: "other",
            ownUserId: "me",
            followRepository: repository,
            firestoreService: MockFirestoreServiceForFollowList(),
            pageSize: 30
        )
        await viewModel.fetchFirstPage()

        // Act
        await viewModel.removeFollower(userId: "userA")

        // Assert: リポジトリは呼ばれず行も残る
        XCTAssertTrue(repository.capturedRemovals.isEmpty)
        XCTAssertEqual(viewModel.follows.count, 1)
    }

    // MARK: - プロフィール取得

    /// 表示対象の uid の PublicProfile を取得してキャッシュする
    func testFetchFirstPageLoadsProfilesForDisplayedUsers() async {
        // Arrange
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[
            makeFollow(follower: "userA", followee: "me"),
            makeFollow(follower: "userB", followee: "me"),
        ]]
        let firestore = MockFirestoreServiceForFollowList()
        let viewModel = FollowListViewModel(
            listType: .followers,
            targetUserId: "me",
            ownUserId: "me",
            followRepository: repository,
            firestoreService: firestore,
            pageSize: 30
        )

        // Act
        await viewModel.fetchFirstPage()

        // Assert: 表示対象（followerId）ぶんのプロフィールが引ける
        XCTAssertEqual(Set(viewModel.profilesByUserId.keys), ["userA", "userB"])
        XCTAssertEqual(Set(firestore.requestedProfileIds), ["userA", "userB"])
    }

    // MARK: - Helpers

    private func makeViewModel(
        listType: FollowListType,
        repository: MockFollowListRepository,
        pageSize: Int = 30
    ) -> FollowListViewModel {
        FollowListViewModel(
            listType: listType,
            targetUserId: "me",
            ownUserId: "me",
            followRepository: repository,
            firestoreService: MockFirestoreServiceForFollowList(),
            pageSize: pageSize
        )
    }

    private func makeFollow(follower: String, followee: String) -> Follow {
        Follow(
            id: Follow.makeId(followerId: follower, followeeId: followee),
            followerId: follower,
            followeeId: followee
        )
    }
}

// MARK: - Mocks

/// fetchFollowers / fetchFollowing / removeFollower のみ上書きする最小 Mock。
/// 残り（follow/unfollow/isFollowing）は FollowRepositoryProtocol の本体定義を
/// 実装する必要があるが、この画面では呼ばれないため fatalError にする。
final class MockFollowListRepository: FollowRepositoryProtocol, @unchecked Sendable {
    /// 呼び出しごとに順番に返すページ（尽きたら空配列）
    var stubbedPages: [[Follow]] = []
    var stubbedFetchError: Error?
    var stubbedRemoveError: Error?

    private(set) var fetchFollowersCallCount = 0
    private(set) var fetchFollowingCallCount = 0
    private(set) var capturedRemovals: [(follower: String, owner: String)] = []

    private var pageIndex = 0

    func follow(_: String, by _: String) async throws {
        fatalError("MockFollowListRepository.follow は未実装です")
    }

    func unfollow(_: String, by _: String) async throws {
        fatalError("MockFollowListRepository.unfollow は未実装です")
    }

    func isFollowing(_: String, by _: String) async throws -> Bool {
        fatalError("MockFollowListRepository.isFollowing は未実装です")
    }

    func fetchFollowers(
        of _: String,
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> (follows: [Follow], lastDocument: DocumentSnapshot?) {
        fetchFollowersCallCount += 1
        return try nextPage()
    }

    func fetchFollowing(
        of _: String,
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> (follows: [Follow], lastDocument: DocumentSnapshot?) {
        fetchFollowingCallCount += 1
        return try nextPage()
    }

    func removeFollower(_ followerUserId: String, from ownUserId: String) async throws {
        if let stubbedRemoveError { throw stubbedRemoveError }
        capturedRemovals.append((follower: followerUserId, owner: ownUserId))
    }

    private func nextPage() throws -> (follows: [Follow], lastDocument: DocumentSnapshot?) {
        if let stubbedFetchError { throw stubbedFetchError }
        guard pageIndex < stubbedPages.count else {
            return (follows: [], lastDocument: nil)
        }
        let page = stubbedPages[pageIndex]
        pageIndex += 1
        // DocumentSnapshot はテストで生成できないため常に nil を返す。
        // ViewModel の hasMore 判定は件数ベースなので支障ない。
        return (follows: page, lastDocument: nil)
    }
}

/// `fetchPublicProfile` のみ上書きする最小 Mock。
/// 残りは FirestoreServiceProtocol+TestDefaults（fatalError）で満たす。
///
/// ⚠️ fetchPublicProfile は ViewModel の withTaskGroup から **並列に** 呼ばれるため、
///    記録用配列は NSLock で保護する（保護なしだと同時 append でデータレース）。
final class MockFirestoreServiceForFollowList: FirestoreServiceProtocol {
    private let lock = NSLock()
    private var _requestedProfileIds: [String] = []

    /// 要求された userId の記録（表示対象の向きの検証に使う）
    var requestedProfileIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedProfileIds
    }

    func fetchPublicProfile(userId: String) async throws -> PublicProfile {
        record(userId)
        return PublicProfile(id: userId, displayName: "テスト \(userId)")
    }

    /// lock/unlock は async コンテキストから直接呼べない（noasync）ため、
    /// 同期メソッドに切り出してから呼ぶ
    private func record(_ userId: String) {
        lock.lock()
        _requestedProfileIds.append(userId)
        lock.unlock()
    }
}
