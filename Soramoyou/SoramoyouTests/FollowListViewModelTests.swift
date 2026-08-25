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
        // フォロワー一覧では「一覧本体の取得」に fetchFollowing は使わない。
        // ⚠️ ただしフォローバック表示のため、自分（me）のフォロー中集合の取得は走る。
        XCTAssertEqual(repository.fetchFollowingCallCount, 0)
        XCTAssertEqual(repository.capturedFollowingTargets, ["me"])
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

    // MARK: - フォローバック導線 ⭐️

    /// 自分がフォローしていないフォロワーは「未フォロー」、している相手は「フォロー中」と判定される
    func testフォロー中の相手だけがフォロー中と判定される() async {
        // Arrange: me は A・B にフォローされていて、うち B だけを自分もフォローしている（＝相互）
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[
            makeFollow(follower: "userA", followee: "me"),
            makeFollow(follower: "userB", followee: "me"),
        ]]
        repository.stubbedFollowingByUser = ["me": [makeFollow(follower: "me", followee: "userB")]]
        let viewModel = makeViewModel(listType: .followers, repository: repository)

        // Act
        await viewModel.fetchFirstPage()

        // Assert
        XCTAssertFalse(viewModel.isFollowingUser("userA"), "片思いのフォロワーは未フォロー")
        XCTAssertTrue(viewModel.isFollowingUser("userB"), "相互フォローの相手はフォロー中")
    }

    /// 自分のフォロー中集合の取得は 1 回だけ（行ごとに叩く N+1 にしない）
    func testフォロー中集合の取得は一度だけ() async {
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[
            makeFollow(follower: "userA", followee: "me"),
            makeFollow(follower: "userB", followee: "me"),
            makeFollow(follower: "userC", followee: "me"),
        ]]
        repository.stubbedFollowingByUser = ["me": []]
        let viewModel = makeViewModel(listType: .followers, repository: repository)

        await viewModel.fetchFirstPage()

        XCTAssertEqual(
            repository.capturedFollowingTargets, ["me"],
            "行数に関わらず自分のフォロー中集合の取得は 1 回"
        )
    }

    /// フォローバックすると、その相手がフォロー中になる
    func testフォローバックでフォロー中になる() async {
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[makeFollow(follower: "userA", followee: "me")]]
        repository.stubbedFollowingByUser = ["me": []]
        let viewModel = makeViewModel(listType: .followers, repository: repository)
        await viewModel.fetchFirstPage()
        XCTAssertFalse(viewModel.isFollowingUser("userA"))

        // Act
        await viewModel.toggleFollow(userId: "userA")

        // Assert
        XCTAssertTrue(viewModel.isFollowingUser("userA"))
        XCTAssertEqual(repository.capturedFollows.map(\.target), ["userA"])
        XCTAssertEqual(repository.capturedFollows.map(\.owner), ["me"])
        XCTAssertTrue(repository.capturedUnfollows.isEmpty, "フォロー時に解除は呼ばない")
    }

    /// フォロー中の相手をもう一度押すとフォロー解除になる
    func testフォロー中をもう一度押すと解除される() async {
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[makeFollow(follower: "userB", followee: "me")]]
        repository.stubbedFollowingByUser = ["me": [makeFollow(follower: "me", followee: "userB")]]
        let viewModel = makeViewModel(listType: .followers, repository: repository)
        await viewModel.fetchFirstPage()
        XCTAssertTrue(viewModel.isFollowingUser("userB"))

        // Act
        await viewModel.toggleFollow(userId: "userB")

        // Assert
        XCTAssertFalse(viewModel.isFollowingUser("userB"))
        XCTAssertEqual(repository.capturedUnfollows.map(\.target), ["userB"])
    }

    /// 失敗したらフォロー状態は変えず、エラーを見せる（楽観的更新をしない）
    func testフォロー失敗時は状態を変えずエラーを出す() async {
        struct FollowError: Error {}
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[makeFollow(follower: "userA", followee: "me")]]
        repository.stubbedFollowingByUser = ["me": []]
        let viewModel = makeViewModel(listType: .followers, repository: repository)
        await viewModel.fetchFirstPage()
        repository.stubbedFollowError = FollowError()

        // Act
        await viewModel.toggleFollow(userId: "userA")

        // Assert
        XCTAssertFalse(viewModel.isFollowingUser("userA"), "失敗したらフォロー中にしない")
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// 自分自身の行にはフォローボタンを出さない
    func test自分自身の行にはボタンを出さない() {
        let repository = MockFollowListRepository()
        let viewModel = makeViewModel(listType: .followers, repository: repository)

        XCTAssertFalse(viewModel.canToggleFollow(for: "me"))
        XCTAssertTrue(viewModel.canToggleFollow(for: "userA"))
    }

    /// ゲスト（未ログイン = ownUserId が nil）にはフォローボタンを出さず、押しても何も起きない
    func testゲストにはボタンを出さず操作もしない() async {
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[makeFollow(follower: "userA", followee: "target")]]
        let viewModel = FollowListViewModel(
            listType: .followers,
            targetUserId: "target",
            ownUserId: nil,
            followRepository: repository,
            firestoreService: MockFirestoreServiceForFollowList(),
            pageSize: 30
        )
        await viewModel.fetchFirstPage()

        XCTAssertFalse(viewModel.canToggleFollow(for: "userA"))

        // Act: 押されても何も起きないこと
        await viewModel.toggleFollow(userId: "userA")

        XCTAssertTrue(repository.capturedFollows.isEmpty)
        XCTAssertTrue(
            repository.capturedFollowingTargets.isEmpty,
            "未ログインでは自分のフォロー中集合も取りに行かない"
        )
    }

    /// 自分のフォロー中一覧では、表示中の行がそのまま自分のフォロー中集合になる（追加クエリを投げない）
    func test自分のフォロー中一覧では追加クエリを投げない() async {
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[
            makeFollow(follower: "me", followee: "userA"),
            makeFollow(follower: "me", followee: "userB"),
        ]]
        let viewModel = makeViewModel(listType: .following, repository: repository)

        await viewModel.fetchFirstPage()

        XCTAssertTrue(viewModel.isFollowingUser("userA"))
        XCTAssertTrue(viewModel.isFollowingUser("userB"))
        XCTAssertEqual(
            repository.capturedFollowingTargets, ["me"],
            "一覧本体の取得 1 回だけで、自分の集合のための追加取得はしない"
        )
    }

    /// 【回帰】自分のフォロー中一覧を 2 ページ目まで読んでも、追加された行はフォロー中と判定される
    ///
    /// 高速パス（表示中の follows を集合にする）が初回ページ分しか反映せず、
    /// 31 件目以降に「フォロー」ボタンが誤表示されていた（レビュー D2）。
    func testフォロー中一覧の2ページ目もフォロー中と判定される() async {
        // Arrange: pageSize=2。1ページ目は満杯、2ページ目に userC
        let repository = MockFollowListRepository()
        repository.stubbedPages = [
            [
                makeFollow(follower: "me", followee: "userA"),
                makeFollow(follower: "me", followee: "userB"),
            ],
            [makeFollow(follower: "me", followee: "userC")],
        ]
        let viewModel = makeViewModel(listType: .following, repository: repository, pageSize: 2)
        await viewModel.fetchFirstPage()

        // Act
        await viewModel.loadMore()

        // Assert: 一覧に出ていること自体がフォロー中の証拠
        XCTAssertTrue(viewModel.isFollowingUser("userC"), "2ページ目の行もフォロー中と判定されること")
        XCTAssertEqual(viewModel.followButtonTitle(for: "userC"), "フォロー中")
    }

    // MARK: - ボタン文言 ⭐️

    /// 「フォローバック」は自分のフォロワー一覧でだけ出す（レビュー D1）
    func test他人のフォロワー一覧ではフォローバックと出さない() async {
        // Arrange: 他人（target）のフォロワー一覧を自分（me）が見ている
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[makeFollow(follower: "userA", followee: "target")]]
        repository.stubbedFollowingByUser = ["me": []]
        repository.listTypeForStub = .followers
        repository.listTargetUserId = "target"
        let viewModel = FollowListViewModel(
            listType: .followers,
            targetUserId: "target",
            ownUserId: "me",
            followRepository: repository,
            firestoreService: MockFirestoreServiceForFollowList(),
            pageSize: 30
        )
        await viewModel.fetchFirstPage()

        // Assert: userA は「target をフォローしている人」であって自分のフォロワーではない
        XCTAssertFalse(viewModel.isOwnFollowersList)
        XCTAssertEqual(
            viewModel.followButtonTitle(for: "userA"), "フォロー",
            "他人のフォロワー一覧で『フォローバック』と出すと、存在しない関係を提示することになる"
        )
    }

    /// 自分のフォロワー一覧では「フォローバック」、フォロー済みなら「フォロー中」
    func test自分のフォロワー一覧ではフォローバックと出す() async {
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[
            makeFollow(follower: "userA", followee: "me"),
            makeFollow(follower: "userB", followee: "me"),
        ]]
        repository.stubbedFollowingByUser = ["me": [makeFollow(follower: "me", followee: "userB")]]
        let viewModel = makeViewModel(listType: .followers, repository: repository)

        await viewModel.fetchFirstPage()

        XCTAssertTrue(viewModel.isOwnFollowersList)
        XCTAssertEqual(viewModel.followButtonTitle(for: "userA"), "フォローバック")
        XCTAssertEqual(viewModel.followButtonTitle(for: "userB"), "フォロー中")
    }

    /// 自分のフォロー中一覧では「フォローバック」ではなく「フォロー中」
    func testフォロー中一覧の文言はフォロー中() async {
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[makeFollow(follower: "me", followee: "userA")]]
        let viewModel = makeViewModel(listType: .following, repository: repository)

        await viewModel.fetchFirstPage()

        XCTAssertEqual(viewModel.followButtonTitle(for: "userA"), "フォロー中")
    }

    /// 自分のフォロー中集合の取得に失敗しても、一覧表示は続く（コメントで宣言している約束・レビュー D10）
    func testフォロー中集合の取得に失敗しても一覧は表示される() async {
        struct OwnFollowingError: Error {}
        let repository = MockFollowListRepository()
        repository.stubbedPages = [[makeFollow(follower: "userA", followee: "me")]]
        repository.stubbedOwnFollowingError = OwnFollowingError()
        let viewModel = makeViewModel(listType: .followers, repository: repository)

        // Act
        await viewModel.fetchFirstPage()

        // Assert: 一覧は生きていて、エラー表示にも切り替わらない
        XCTAssertEqual(viewModel.follows.count, 1, "集合取得の失敗で一覧を壊さない")
        XCTAssertNil(viewModel.lastError, "ErrorStateView に切り替えない")
        // 集合が空なので「未フォロー」に見えるが、押せば正しく処理される
        XCTAssertFalse(viewModel.isFollowingUser("userA"))
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
        // 一覧本体の取得と「自分のフォロー中集合」の取得をモックが区別できるようにする
        repository.listTypeForStub = listType
        repository.listTargetUserId = "me"
        return FollowListViewModel(
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

    /// `fetchFollowing(of:)` に渡された uid の記録
    /// （一覧本体の取得か、自分のフォロー中集合の取得かを区別するのに使う）
    private(set) var capturedFollowingTargets: [String] = []
    /// 「この uid のフォロー中一覧」として返す固定値（フォローバック表示の判定用）。
    /// 自分のフォロー中集合として扱われた `fetchFollowing` は `stubbedPages` を消費しない。
    var stubbedFollowingByUser: [String: [Follow]] = [:]
    /// 検証対象の一覧の種別（makeViewModel が設定する）。
    /// フォロワー一覧では `fetchFollowing` は必ず「自分のフォロー中集合」の取得になる。
    var listTypeForStub: FollowListType?
    /// 一覧本体が対象にしている uid（makeViewModel が設定する）
    var listTargetUserId: String?

    /// 「自分のフォロー中集合」の取得だけを失敗させるスタブ。
    /// stubbedFetchError は一覧本体が先に落ちてしまい、集合取得だけの失敗を作れないため分ける。
    var stubbedOwnFollowingError: Error?

    private(set) var capturedFollows: [(target: String, owner: String)] = []
    private(set) var capturedUnfollows: [(target: String, owner: String)] = []
    var stubbedFollowError: Error?

    private var pageIndex = 0

    func follow(_ targetUserId: String, by ownUserId: String) async throws {
        if let stubbedFollowError { throw stubbedFollowError }
        capturedFollows.append((target: targetUserId, owner: ownUserId))
    }

    func unfollow(_ targetUserId: String, by ownUserId: String) async throws {
        if let stubbedFollowError { throw stubbedFollowError }
        capturedUnfollows.append((target: targetUserId, owner: ownUserId))
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
        of userId: String,
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> (follows: [Follow], lastDocument: DocumentSnapshot?) {
        capturedFollowingTargets.append(userId)
        // 「自分のフォロー中集合」の取得は固定値を返し、一覧本体用の stubbedPages を消費しない。
        // ・フォロワー一覧では fetchFollowing が一覧本体に使われることはない
        // ・フォロー中一覧では、一覧の対象 uid と違えば自分の集合の取得
        let isOwnFollowingFetch = listTypeForStub == .followers
            || (listTargetUserId != nil && userId != listTargetUserId)
        if isOwnFollowingFetch {
            if let stubbedOwnFollowingError { throw stubbedOwnFollowingError }
            if let stubbedFetchError { throw stubbedFetchError }
            return (follows: stubbedFollowingByUser[userId] ?? [], lastDocument: nil)
        }
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
