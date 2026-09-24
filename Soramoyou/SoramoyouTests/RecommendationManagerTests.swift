//
//  RecommendationManagerTests.swift
//  SoramoyouTests
//
//  「私のおすすめの空」の状態管理（RecommendationManager）のテスト ⭐️
//  最小 Mock（おすすめ関連と fetchPublicProfile だけ上書き、残りは TestDefaults）で検証。
//

import XCTest
@testable import Soramoyou

@MainActor
final class RecommendationManagerTests: XCTestCase {
    // MARK: - Helpers

    private func makeManager(
        firestore: MockFirestoreServiceForRecommendations,
        userId: String? = "me"
    ) -> (RecommendationManager, MockAuthService) {
        let auth = MockAuthService()
        if let userId {
            auth.currentUserValue = User(id: userId)
        }
        return (RecommendationManager(firestoreService: firestore, authService: auth), auth)
    }

    private func makePost(id: String, userId: String = "other", visibility: Visibility = .public) -> Post {
        Post(id: id, userId: userId, images: [], visibility: visibility)
    }

    // MARK: - 読み込み

    func testLoadReadsOwnPublicProfile() async {
        let mock = MockFirestoreServiceForRecommendations()
        mock.serverPostIds = ["A", "B"]
        let (manager, _) = makeManager(firestore: mock)

        await manager.load()

        XCTAssertEqual(manager.recommendedPostIds, ["A", "B"])
        XCTAssertEqual(mock.fetchPublicProfileCalls, ["me"])
    }

    func testLoadSkipsWhenAlreadyLoadedUnlessForced() async {
        let mock = MockFirestoreServiceForRecommendations()
        let (manager, _) = makeManager(firestore: mock)

        await manager.load()
        await manager.load()
        XCTAssertEqual(mock.fetchPublicProfileCalls.count, 1, "同じユーザーで読み込み済みなら読み直さない")

        await manager.load(force: true)
        XCTAssertEqual(mock.fetchPublicProfileCalls.count, 2)
    }

    func testLoadTreatsMissingProfileAsEmpty() async {
        let mock = MockFirestoreServiceForRecommendations()
        mock.profileExists = false
        let (manager, _) = makeManager(firestore: mock)

        await manager.load()

        XCTAssertEqual(manager.recommendedPostIds, [])
    }

    // MARK: - 追加

    func testAddPublicPost() async {
        let mock = MockFirestoreServiceForRecommendations()
        let (manager, _) = makeManager(firestore: mock)

        let outcome = await manager.add(post: makePost(id: "A"), source: "post_detail")

        XCTAssertEqual(outcome, .added)
        XCTAssertEqual(manager.recommendedPostIds, ["A"])
        XCTAssertEqual(mock.serverPostIds, ["A"])
    }

    func testCannotAddNonPublicPost() async {
        // 他の人にも見える場所なので、フォロワー限定・非公開は飾れない
        let mock = MockFirestoreServiceForRecommendations()
        let (manager, _) = makeManager(firestore: mock)

        let followers = await manager.add(post: makePost(id: "F", visibility: .followers), source: "post_detail")
        let privatePost = await manager.add(post: makePost(id: "P", visibility: .private), source: "post_detail")

        XCTAssertEqual(followers, .notPublic)
        XCTAssertEqual(privatePost, .notPublic)
        XCTAssertTrue(mock.addCalls.isEmpty, "サーバーへは書きに行かない")
    }

    func testAddWhenFullIsRejected() async {
        let mock = MockFirestoreServiceForRecommendations()
        mock.serverPostIds = ["A", "B", "C"]
        let (manager, _) = makeManager(firestore: mock)

        let outcome = await manager.add(post: makePost(id: "D"), source: "post_detail")

        XCTAssertEqual(outcome, .full)
        XCTAssertEqual(mock.serverPostIds, ["A", "B", "C"])
        // ローカルが古くても、サーバーの最新一覧に揃う
        XCTAssertEqual(manager.recommendedPostIds, ["A", "B", "C"])
        XCTAssertTrue(manager.isFull)
    }

    func testAddRequiresLogin() async {
        let mock = MockFirestoreServiceForRecommendations()
        let (manager, _) = makeManager(firestore: mock, userId: nil)

        let outcome = await manager.add(post: makePost(id: "A"), source: "post_detail")

        XCTAssertEqual(outcome, .requiresLogin)
    }

    func testAddCreatesMissingPublicProfileThenRetries() async {
        // 公開プロフィール未作成の旧アカウントでも追加できる
        let mock = MockFirestoreServiceForRecommendations()
        mock.profileExists = false
        let (manager, _) = makeManager(firestore: mock)

        let outcome = await manager.add(post: makePost(id: "A"), source: "post_detail")

        XCTAssertEqual(outcome, .added)
        XCTAssertEqual(mock.createPublicProfileCount, 1)
        XCTAssertEqual(mock.serverPostIds, ["A"])
    }

    func testProfileFallbackKeepsPostAddedByAnotherDevice() async {
        // 旧アカウントで 2 台が同時に最初のおすすめを追加 → こちらが作成する前に、
        // 別の端末がプロフィールを作って X を追加していた。作成で上書きして X を消さない。
        let mock = MockFirestoreServiceForRecommendations()
        mock.profileExists = false
        mock.otherDeviceCreatesProfileWith = ["X"]
        let (manager, _) = makeManager(firestore: mock)

        let outcome = await manager.add(post: makePost(id: "A"), source: "post_detail")

        XCTAssertEqual(outcome, .added)
        XCTAssertEqual(mock.serverPostIds, ["X", "A"])
        XCTAssertEqual(mock.createPublicProfileCount, 0, "既にあるので作成しない")
    }

    func testAddFailureReturnsFailed() async {
        let mock = MockFirestoreServiceForRecommendations()
        mock.addError = FirestoreServiceError.updateFailed(NSError(domain: "test", code: 1))
        let (manager, _) = makeManager(firestore: mock)

        let outcome = await manager.add(post: makePost(id: "A"), source: "post_detail")

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(manager.recommendedPostIds, [])
    }

    // MARK: - トグル / 外す

    func testToggleRemovesWhenAlreadyRecommended() async {
        let mock = MockFirestoreServiceForRecommendations()
        mock.serverPostIds = ["A", "B"]
        let (manager, _) = makeManager(firestore: mock)
        await manager.load()

        let outcome = await manager.toggle(post: makePost(id: "A"), source: "post_detail")

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(manager.recommendedPostIds, ["B"])
        XCTAssertEqual(mock.serverPostIds, ["B"])
    }

    func testRemoveSeveralUnavailablePosts() async {
        let mock = MockFirestoreServiceForRecommendations()
        mock.serverPostIds = ["A", "B", "C"]
        let (manager, _) = makeManager(firestore: mock)
        await manager.load()

        let outcome = await manager.remove(postIds: ["A", "C"], source: "profile_cleanup")

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(manager.recommendedPostIds, ["B"])
    }

    func testRemoveFailureRevertsLocalState() async {
        let mock = MockFirestoreServiceForRecommendations()
        mock.serverPostIds = ["A", "B"]
        let (manager, _) = makeManager(firestore: mock)
        await manager.load()
        mock.writeError = FirestoreServiceError.updateFailed(NSError(domain: "test", code: 1))

        let outcome = await manager.remove(postIds: ["A"], source: "profile")

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(manager.recommendedPostIds, ["A", "B"], "失敗したら元に戻す")
    }

    // MARK: - 並べ替え

    func testMoveSavesNewOrder() async {
        let mock = MockFirestoreServiceForRecommendations()
        mock.serverPostIds = ["A", "B", "C"]
        let (manager, _) = makeManager(firestore: mock)
        await manager.load()

        await manager.move(postId: "C", by: -1)

        XCTAssertEqual(manager.recommendedPostIds, ["A", "C", "B"])
        XCTAssertEqual(mock.serverPostIds, ["A", "C", "B"])
    }

    func testMovePastEdgeDoesNotWrite() async {
        let mock = MockFirestoreServiceForRecommendations()
        mock.serverPostIds = ["A", "B"]
        let (manager, _) = makeManager(firestore: mock)
        await manager.load()

        await manager.move(postId: "A", by: -1)

        XCTAssertEqual(mock.moveCalls.count, 0)
    }

    // MARK: - 別端末・読み込み中の変更

    func testRemoveKeepsPostAddedOnAnotherDevice() async {
        // 端末1で読み込んだ後に、端末2で C が追加された
        let mock = MockFirestoreServiceForRecommendations()
        mock.serverPostIds = ["A", "B"]
        let (manager, _) = makeManager(firestore: mock)
        await manager.load()
        mock.serverPostIds = ["A", "B", "C"]

        // 端末1で A を外しても、C は消えない（手元の古い一覧で上書きしない）
        _ = await manager.remove(postIds: ["A"], source: "profile")

        XCTAssertEqual(mock.serverPostIds, ["B", "C"])
        XCTAssertEqual(manager.recommendedPostIds, ["B", "C"], "サーバーの最新一覧に揃う")
    }

    func testMoveUsesLatestServerList() async {
        let mock = MockFirestoreServiceForRecommendations()
        mock.serverPostIds = ["A", "B"]
        let (manager, _) = makeManager(firestore: mock)
        await manager.load()
        mock.serverPostIds = ["A", "B", "C"]

        await manager.move(postId: "B", by: -1)

        XCTAssertEqual(mock.serverPostIds, ["B", "A", "C"])
        XCTAssertEqual(manager.recommendedPostIds, ["B", "A", "C"])
    }

    func testLoadResultIsDiscardedWhenChangedDuringLoad() async {
        // 読み込みの通信中に追加が終わった → 後から返ってきた古い一覧で書き戻さない
        let mock = MockFirestoreServiceForRecommendations()
        mock.serverPostIds = ["A"]
        let (manager, _) = makeManager(firestore: mock)
        let postB = makePost(id: "B")
        mock.onFetchPublicProfile = {
            _ = await manager.add(post: postB, source: "post_detail")
        }

        await manager.load(force: true)

        XCTAssertEqual(manager.recommendedPostIds, ["A", "B"])
    }

    // MARK: - サインアウト

    func testClearOnSignOutForgetsListAndReloadsNextTime() async {
        let mock = MockFirestoreServiceForRecommendations()
        mock.serverPostIds = ["A"]
        let (manager, _) = makeManager(firestore: mock)
        await manager.load()

        manager.clearOnSignOut()
        XCTAssertEqual(manager.recommendedPostIds, [])

        await manager.load()
        XCTAssertEqual(mock.fetchPublicProfileCalls.count, 2, "サインアウト後は読み込み済み扱いにしない")
    }
}

// MARK: - Mock

/// サーバー上の一覧（serverPostIds）を本物と同じルール（RecommendedSkies）で更新するモック
final class MockFirestoreServiceForRecommendations: FirestoreServiceProtocol {
    var serverPostIds: [String] = []
    var profileExists = true
    var addError: Error?
    /// 外す・並べ替えで投げるエラー（nil なら成功）
    var writeError: Error?
    /// fetchPublicProfile の「通信中」に割り込ませる処理（読み込み中の変更を再現する）
    var onFetchPublicProfile: (() async -> Void)?
    /// 最初の追加が notFound で失敗した直後に、別の端末がプロフィールを作ってこの一覧を書いた、を再現する
    var otherDeviceCreatesProfileWith: [String]?

    private(set) var fetchPublicProfileCalls: [String] = []
    private(set) var addCalls: [String] = []
    private(set) var removeCalls: [Set<String>] = []
    private(set) var moveCalls: [(postId: String, offset: Int)] = []
    private(set) var createPublicProfileCount = 0

    func fetchPublicProfile(userId: String) async throws -> PublicProfile {
        fetchPublicProfileCalls.append(userId)
        guard profileExists else { throw FirestoreServiceError.notFound }
        // 読み取った時点の一覧を返す（割り込んだ変更は反映されない＝古い結果）
        let snapshot = serverPostIds
        if let onFetchPublicProfile {
            self.onFetchPublicProfile = nil
            await onFetchPublicProfile()
        }
        return PublicProfile(id: userId, recommendedPostIds: snapshot)
    }

    func addRecommendedPost(postId: String, userId _: String) async throws -> RecommendedSkies.AddResult {
        addCalls.append(postId)
        if let addError { throw addError }
        guard profileExists else {
            if let otherList = otherDeviceCreatesProfileWith {
                otherDeviceCreatesProfileWith = nil
                profileExists = true
                serverPostIds = otherList
            }
            throw FirestoreServiceError.notFound
        }
        let result = RecommendedSkies.adding(postId, to: serverPostIds)
        serverPostIds = result.postIds
        return result
    }

    func removeRecommendedPosts(_ postIds: Set<String>, userId _: String) async throws -> [String] {
        removeCalls.append(postIds)
        if let writeError { throw writeError }
        serverPostIds = RecommendedSkies.removing(postIds, from: serverPostIds)
        return serverPostIds
    }

    func moveRecommendedPost(_ postId: String, by offset: Int, userId _: String) async throws -> [String] {
        moveCalls.append((postId: postId, offset: offset))
        if let writeError { throw writeError }
        serverPostIds = RecommendedSkies.moving(postId, by: offset, in: serverPostIds)
        return serverPostIds
    }

    func fetchUser(userId: String) async throws -> User {
        User(id: userId)
    }

    /// 本物と同じく「無いときだけ作る」
    func createPublicProfileIfMissing(from _: User) async throws {
        guard !profileExists else { return }
        createPublicProfileCount += 1
        profileExists = true
        serverPostIds = []
    }
}
