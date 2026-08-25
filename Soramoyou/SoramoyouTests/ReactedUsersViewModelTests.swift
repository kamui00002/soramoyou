//
//  ReactedUsersViewModelTests.swift
//  SoramoyouTests
//
//  「反応してくれた人」一覧の単体テスト ⭐️
//
//  集約は純関数 `ReactedUsersViewModel.aggregate(likes:excluding:)` に切り出してある。
//  ボタン文言も ViewModel 側にあるのでここで固定できる
//  （PR #97 の D1＝View の private に置いた文言判定が誤ったまま17件 green で通った、の再発防止）。
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

@MainActor
final class ReactedUsersViewModelTests: XCTestCase {
    // MARK: - Helpers

    private func makeLike(user: String, post: String, t: TimeInterval) -> Like {
        Like(userId: user, postId: post, createdAt: Date(timeIntervalSince1970: t))
    }

    private func makePost(
        _ id: String, user: String = "me", visibility: Visibility = .public
    ) -> Post {
        Post(id: id, userId: user, images: [], visibility: visibility)
    }

    // MARK: - 集約（純関数）

    /// 同じ人が複数の投稿に反応していても 1 行にまとまり、件数が数えられる
    func test同じ人は1行にまとまり件数が数えられる() {
        let likes = [
            makeLike(user: "userA", post: "p1", t: 100),
            makeLike(user: "userA", post: "p2", t: 200),
            makeLike(user: "userB", post: "p1", t: 150),
        ]

        let result = ReactedUsersViewModel.aggregate(likes: likes, excluding: "me")

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first(where: { $0.id == "userA" })?.reactionCount, 2)
        XCTAssertEqual(result.first(where: { $0.id == "userB" })?.reactionCount, 1)
    }

    /// 自分自身のいいねは除外する（実データに自分の投稿への自分のいいねが存在する）
    func test自分のいいねは除外される() {
        let likes = [
            makeLike(user: "me", post: "p1", t: 300),
            makeLike(user: "userA", post: "p1", t: 100),
        ]

        let result = ReactedUsersViewModel.aggregate(likes: likes, excluding: "me")

        XCTAssertEqual(result.map(\.id), ["userA"], "自分の一覧に自分が並ばないこと")
    }

    /// 並びは「最後に反応した日時」の降順
    func test最後に反応した順に並ぶ() {
        let likes = [
            makeLike(user: "old", post: "p1", t: 100),
            makeLike(user: "newest", post: "p2", t: 900),
            makeLike(user: "middle", post: "p3", t: 500),
            // old は古い反応が2件目にあるが、最新は 100 のまま
            makeLike(user: "old", post: "p4", t: 50),
        ]

        let result = ReactedUsersViewModel.aggregate(likes: likes, excluding: "me")

        XCTAssertEqual(result.map(\.id), ["newest", "middle", "old"])
        XCTAssertEqual(result.first(where: { $0.id == "old" })?.latestReactedAt,
                       Date(timeIntervalSince1970: 100),
                       "複数反応があるときは最新の日時を採ること")
    }

    /// 同時刻は uid 昇順で決定的に並ぶ（実行のたびに順序が変わらない）
    func test同時刻はuid昇順で安定する() {
        let likes = [
            makeLike(user: "zzz", post: "p1", t: 100),
            makeLike(user: "aaa", post: "p2", t: 100),
            makeLike(user: "mmm", post: "p3", t: 100),
        ]

        let result = ReactedUsersViewModel.aggregate(likes: likes, excluding: "me")

        XCTAssertEqual(result.map(\.id), ["aaa", "mmm", "zzz"])
    }

    /// いいねが無ければ空
    func testいいねがなければ空() {
        XCTAssertTrue(ReactedUsersViewModel.aggregate(likes: [], excluding: "me").isEmpty)
    }

    // MARK: - ボタン文言 ⭐️

    /// この一覧では「フォローバック」とは出さない
    ///
    /// 反応してくれた人が自分をフォローしているとは限らないため。
    /// （フォロワー一覧の同名バグ = PR #97 の D1 と同じ取り違えを繰り返さない）
    func testフォローバックとは出さない() {
        let viewModel = ReactedUsersViewModel(
            ownUserId: "me",
            firestoreService: MockFirestoreServiceForReacted(),
            followRepository: MockFollowRepositoryForReacted()
        )

        XCTAssertEqual(viewModel.followButtonTitle(for: "userA"), "フォロー")
        XCTAssertNotEqual(viewModel.followButtonTitle(for: "userA"), "フォローバック")
    }

    /// 自分自身とゲストにはフォローボタンを出さない
    func test自分とゲストにはボタンを出さない() {
        let signedIn = ReactedUsersViewModel(
            ownUserId: "me",
            firestoreService: MockFirestoreServiceForReacted(),
            followRepository: MockFollowRepositoryForReacted()
        )
        XCTAssertFalse(signedIn.canToggleFollow(for: "me"))
        XCTAssertTrue(signedIn.canToggleFollow(for: "userA"))

        let guest = ReactedUsersViewModel(
            ownUserId: nil,
            firestoreService: MockFirestoreServiceForReacted(),
            followRepository: MockFollowRepositoryForReacted()
        )
        XCTAssertFalse(guest.canToggleFollow(for: "userA"))
    }

    // MARK: - 読み込み

    /// 自分の投稿 → いいね → 人の一覧、の順に辿れる
    func test読み込みで反応した人が並ぶ() async {
        let firestore = MockFirestoreServiceForReacted()
        firestore.stubbedUserPosts = [makePost("p1"), makePost("p2")]
        firestore.stubbedLikes = [
            makeLike(user: "userA", post: "p1", t: 100),
            makeLike(user: "userB", post: "p2", t: 200),
            makeLike(user: "me", post: "p1", t: 300), // 自分の分は除外される
        ]
        let repository = MockFollowRepositoryForReacted()
        repository.stubbedFollowing = ["userB"]
        let viewModel = ReactedUsersViewModel(
            ownUserId: "me", firestoreService: firestore, followRepository: repository
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.reactedUsers.map(\.id), ["userB", "userA"], "新しい順")
        XCTAssertEqual(firestore.capturedLikePostIds, ["p1", "p2"], "自分の投稿の ID で引くこと")
        XCTAssertTrue(viewModel.isFollowingUser("userB"))
        XCTAssertFalse(viewModel.isFollowingUser("userA"))
    }

    /// ゲスト（未ログイン）は何も読みに行かない
    func testゲストは何も読み込まない() async {
        let firestore = MockFirestoreServiceForReacted()
        let viewModel = ReactedUsersViewModel(
            ownUserId: nil,
            firestoreService: firestore,
            followRepository: MockFollowRepositoryForReacted()
        )

        await viewModel.load()

        XCTAssertTrue(viewModel.reactedUsers.isEmpty)
        XCTAssertEqual(firestore.fetchUserPostsCallCount, 0)
    }

    /// 取得に失敗したらエラーを見せる（無言で空にしない）
    func test取得失敗はエラーとして見せる() async {
        struct LoadError: Error {}
        let firestore = MockFirestoreServiceForReacted()
        firestore.stubbedError = LoadError()
        let viewModel = ReactedUsersViewModel(
            ownUserId: "me",
            firestoreService: firestore,
            followRepository: MockFollowRepositoryForReacted()
        )

        await viewModel.load()

        XCTAssertNotNil(viewModel.lastError)
        XCTAssertTrue(viewModel.reactedUsers.isEmpty)
    }

    /// フォロー中集合の取得に失敗しても一覧は表示される
    func testフォロー中集合の失敗でも一覧は出る() async {
        struct FollowingError: Error {}
        let firestore = MockFirestoreServiceForReacted()
        firestore.stubbedUserPosts = [makePost("p1")]
        firestore.stubbedLikes = [makeLike(user: "userA", post: "p1", t: 100)]
        let repository = MockFollowRepositoryForReacted()
        repository.stubbedError = FollowingError()
        let viewModel = ReactedUsersViewModel(
            ownUserId: "me", firestoreService: firestore, followRepository: repository
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.reactedUsers.map(\.id), ["userA"], "一覧は壊さない")
        XCTAssertNil(viewModel.lastError, "ErrorStateView には切り替えない")
    }

    /// フォローすると状態が変わる（楽観的更新をしない＝成功後に変わる）
    func testフォローで状態が変わる() async {
        let firestore = MockFirestoreServiceForReacted()
        let repository = MockFollowRepositoryForReacted()
        let viewModel = ReactedUsersViewModel(
            ownUserId: "me", firestoreService: firestore, followRepository: repository
        )

        await viewModel.toggleFollow(userId: "userA")

        XCTAssertTrue(viewModel.isFollowingUser("userA"))
        XCTAssertEqual(repository.capturedFollows.map(\.target), ["userA"])
    }

    /// フォロー中の相手には「フォロー中」と出す（レビュー D10）
    func testフォロー中は文言が変わる() async {
        let firestore = MockFirestoreServiceForReacted()
        let repository = MockFollowRepositoryForReacted()
        repository.stubbedFollowing = ["userA"]
        let viewModel = ReactedUsersViewModel(
            ownUserId: "me", firestoreService: firestore, followRepository: repository
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.followButtonTitle(for: "userA"), "フォロー中")
        XCTAssertEqual(viewModel.followButtonTitle(for: "userB"), "フォロー")
    }

    /// フォロー中の相手をもう一度押すと解除される（レビュー D10）
    func testフォロー中をもう一度押すと解除される() async {
        let firestore = MockFirestoreServiceForReacted()
        let repository = MockFollowRepositoryForReacted()
        repository.stubbedFollowing = ["userA"]
        let viewModel = ReactedUsersViewModel(
            ownUserId: "me", firestoreService: firestore, followRepository: repository
        )
        await viewModel.load()
        XCTAssertTrue(viewModel.isFollowingUser("userA"), "前提: フォロー中から始める")

        await viewModel.toggleFollow(userId: "userA")

        XCTAssertFalse(viewModel.isFollowingUser("userA"))
        XCTAssertEqual(repository.capturedUnfollows.map(\.target), ["userA"])
        XCTAssertTrue(repository.capturedFollows.isEmpty, "解除なのに follow を呼ばないこと")
    }

    /// フォローに失敗したら状態を変えず、アラートで知らせる（レビュー D10）
    ///
    /// ⚠️ 楽観的更新をしていないことの回帰テスト。先に集合へ入れてから通信すると、
    ///    失敗しても「フォロー中」に見えたまま残り、ユーザーが騙される。
    func testフォロー失敗では状態を変えない() async {
        struct FollowError: Error {}
        let firestore = MockFirestoreServiceForReacted()
        let repository = MockFollowRepositoryForReacted()
        repository.stubbedToggleError = FollowError()
        let viewModel = ReactedUsersViewModel(
            ownUserId: "me", firestoreService: firestore, followRepository: repository
        )

        await viewModel.toggleFollow(userId: "userA")

        XCTAssertFalse(viewModel.isFollowingUser("userA"), "失敗したのにフォロー中に見せない")
        XCTAssertNotNil(viewModel.errorMessage, "アラートで知らせる")
        XCTAssertFalse(viewModel.isTogglingFollow(for: "userA"), "処理中フラグは必ず戻す")
    }

    // MARK: - 30件の壁（レビュー D9）

    /// 非公開投稿を除いたうえで、`likes` へ渡す postId は必ず30件以下に収まる
    ///
    /// ⚠️ Firestore の `in` は最大30要素。ここを超えると実機で即エラーになるが、
    ///    Mock 相手のテストでは黙って通ってしまうため、境界を明示的に固定する。
    func test渡すpostIdは30件以下で非公開を除く() async {
        let firestore = MockFirestoreServiceForReacted()
        // ⚠️ 公開と非公開を**交互に**並べる。非公開を後ろにまとめると、
        //    filter を外しても先頭30件が公開のままになり、テストが穴になる。
        //    交互なら filter が無い瞬間に priv が混ざり、必ず red になる。
        firestore.stubbedUserPosts = (0 ..< 30).flatMap {
            [makePost("pub\($0)"), makePost("priv\($0)", visibility: .private)]
        }
        let viewModel = ReactedUsersViewModel(
            ownUserId: "me",
            firestoreService: firestore,
            followRepository: MockFollowRepositoryForReacted()
        )

        await viewModel.load()

        let sent = firestore.capturedLikePostIds
        XCTAssertEqual(sent.count, 30, "`in` の上限ちょうどまでで頭打ちにすること")
        XCTAssertTrue(sent.allSatisfy { $0.hasPrefix("pub") }, "非公開投稿を混ぜないこと")
        XCTAssertEqual(firestore.capturedUserPostsLimit, 60,
                       "非公開を捨てても30件そろうよう、広めに取ってから絞ること")
    }

    /// 注入した窓の値がそのまま使われる（本番既定値に依存せず境界を試せる）
    func test窓の件数は注入できる() async {
        let firestore = MockFirestoreServiceForReacted()
        firestore.stubbedUserPosts = (0 ..< 10).map { makePost("p\($0)") }
        let viewModel = ReactedUsersViewModel(
            ownUserId: "me",
            firestoreService: firestore,
            followRepository: MockFollowRepositoryForReacted(),
            recentPostsWindow: 3,
            postsFetchWindow: 7
        )

        await viewModel.load()

        XCTAssertEqual(firestore.capturedUserPostsLimit, 7)
        XCTAssertEqual(firestore.capturedLikePostIds, ["p0", "p1", "p2"])
    }
}

// MARK: - Mocks

/// `fetchUserPosts` / `fetchLikes` / `fetchPublicProfile` のみ上書きする最小 Mock。
/// 残りは FirestoreServiceProtocol+TestDefaults（fatalError）で満たす。
final class MockFirestoreServiceForReacted: FirestoreServiceProtocol, @unchecked Sendable {
    var stubbedUserPosts: [Post] = []
    var stubbedLikes: [Like] = []
    var stubbedError: Error?

    private let lock = NSLock()
    private var _capturedLikePostIds: [String] = []
    private var _fetchUserPostsCallCount = 0
    private var _capturedUserPostsLimit: Int?

    var capturedLikePostIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return _capturedLikePostIds
    }

    var fetchUserPostsCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _fetchUserPostsCallCount
    }

    /// 直近の `fetchUserPosts(limit:)` に渡された件数（取得窓の検証用）
    var capturedUserPostsLimit: Int? {
        lock.lock(); defer { lock.unlock() }
        return _capturedUserPostsLimit
    }

    // ⚠️ NSLock の lock()/unlock() は async 関数から直接呼ぶと
    //    Swift 6 でエラーになる（unavailable from asynchronous contexts）。
    //    同期ヘルパー経由で触る（FollowListViewModelTests の既存モックと同じ手法）。
    private func recordUserPostsCall(limit: Int) {
        lock.lock(); defer { lock.unlock() }
        _fetchUserPostsCallCount += 1
        _capturedUserPostsLimit = limit
    }

    private func recordLikePostIds(_ postIds: [String]) {
        lock.lock(); defer { lock.unlock() }
        _capturedLikePostIds = postIds
    }

    func fetchUserPosts(userId _: String, limit: Int, lastDocument _: DocumentSnapshot?) async throws -> [Post] {
        recordUserPostsCall(limit: limit)
        if let stubbedError { throw stubbedError }
        return stubbedUserPosts
    }

    func fetchLikes(forPostIds postIds: [String]) async throws -> [Like] {
        recordLikePostIds(postIds)
        if let stubbedError { throw stubbedError }
        return stubbedLikes
    }

    /// 表示名は本テストの対象外なので失敗させる（呼び出し側が try? で握る）
    func fetchPublicProfile(userId _: String) async throws -> PublicProfile {
        throw NSError(domain: "MockFirestoreServiceForReacted", code: -1)
    }
}

/// フォロー操作と「自分のフォロー中一覧」だけを扱う最小 Mock
final class MockFollowRepositoryForReacted: FollowRepositoryProtocol, @unchecked Sendable {
    var stubbedFollowing: [String] = []
    /// `fetchFollowing`（一覧読み込み）で投げるエラー
    var stubbedError: Error?
    /// `follow` / `unfollow`（ボタン操作）で投げるエラー
    var stubbedToggleError: Error?

    private let lock = NSLock()
    private var _capturedFollows: [(target: String, owner: String)] = []
    private var _capturedUnfollows: [(target: String, owner: String)] = []

    var capturedFollows: [(target: String, owner: String)] {
        lock.lock(); defer { lock.unlock() }
        return _capturedFollows
    }

    var capturedUnfollows: [(target: String, owner: String)] {
        lock.lock(); defer { lock.unlock() }
        return _capturedUnfollows
    }

    // 同上（async から直接 lock を触らないための同期ヘルパー）
    private func recordFollow(target: String, owner: String) {
        lock.lock(); defer { lock.unlock() }
        _capturedFollows.append((target: target, owner: owner))
    }

    private func recordUnfollow(target: String, owner: String) {
        lock.lock(); defer { lock.unlock() }
        _capturedUnfollows.append((target: target, owner: owner))
    }

    func follow(_ targetUserId: String, by ownUserId: String) async throws {
        if let stubbedToggleError { throw stubbedToggleError }
        recordFollow(target: targetUserId, owner: ownUserId)
    }

    func unfollow(_ targetUserId: String, by ownUserId: String) async throws {
        if let stubbedToggleError { throw stubbedToggleError }
        recordUnfollow(target: targetUserId, owner: ownUserId)
    }

    func isFollowing(_: String, by _: String) async throws -> Bool {
        fatalError("MockFollowRepositoryForReacted.isFollowing は未実装です")
    }

    func fetchFollowers(
        of _: String, limit _: Int, lastDocument _: DocumentSnapshot?
    ) async throws -> (follows: [Follow], lastDocument: DocumentSnapshot?) {
        fatalError("MockFollowRepositoryForReacted.fetchFollowers は未実装です")
    }

    func fetchFollowing(
        of ownUserId: String, limit _: Int, lastDocument _: DocumentSnapshot?
    ) async throws -> (follows: [Follow], lastDocument: DocumentSnapshot?) {
        if let stubbedError { throw stubbedError }
        let follows = stubbedFollowing.map {
            Follow(id: Follow.makeId(followerId: ownUserId, followeeId: $0),
                   followerId: ownUserId, followeeId: $0)
        }
        return (follows: follows, lastDocument: nil)
    }

    func removeFollower(_: String, from _: String) async throws {
        fatalError("MockFollowRepositoryForReacted.removeFollower は未実装です")
    }
}
