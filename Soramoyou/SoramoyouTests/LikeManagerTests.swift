//
//  LikeManagerTests.swift
//  SoramoyouTests
//
//  いいね状態管理（LikeManager）の ViewModel テスト。⭐️
//  issue #145「押しても数字が増えない／ギャラリー系から押すと外れる」の再発防止。
//  Mock は「サーバー上のいいね・likesCount」を状態として持ち、
//  本物のサービスと同じ振る舞いで書き込みに応える。
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

@MainActor
final class LikeManagerTests: XCTestCase {
    // MARK: - Helpers

    /// ログイン済みの Manager を組み立てる
    private func makeManager(
        firestore: MockFirestoreServiceForLikes,
        userId: String? = "me"
    ) -> LikeManager {
        let auth = MockAuthService()
        if let userId {
            auth.currentUserValue = User(id: userId)
        }
        return LikeManager(firestoreService: firestore, authService: auth)
    }

    /// 一覧から読んだ時点の投稿（likesCount はその時点のサーバー値）
    private func makePost(id: String, likesCount: Int) -> Post {
        Post(id: id, userId: "other", images: [], likesCount: likesCount)
    }

    /// 条件が満たされるまで 1ms ずつ待つ（上限 2 秒）
    /// - Returns: 条件が満たされたら true
    @discardableResult
    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0 ..< 2000 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("条件が満たされないまま待ち時間が尽きた", file: file, line: line)
        return false
    }

    // MARK: - Tests

    /// 1. いいねに成功したら、表示の数字はサーバーの値（+1 済み）になる（#145 ①）
    func testLikeShowsServerCountAfterSuccess() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikesCounts["p1"] = 5
        let manager = makeManager(firestore: mock)
        let post = makePost(id: "p1", likesCount: 5)

        await manager.toggleLike(post: post)

        XCTAssertTrue(manager.isLiked("p1"))
        XCTAssertTrue(mock.serverLikedPostIds.contains("p1"))
        XCTAssertEqual(mock.serverLikesCounts["p1"], 6)
        XCTAssertEqual(manager.likeCount(for: post), 6, "成功後に古い likesCount へ戻ってはいけない")
    }

    /// 2. いいねを外すのに成功したら、表示の数字はサーバーの値（-1 済み）になる（#145 ①）
    func testUnlikeShowsServerCountAfterSuccess() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikedPostIds = ["p1"]
        mock.serverLikesCounts["p1"] = 6
        let manager = makeManager(firestore: mock)
        let post = makePost(id: "p1", likesCount: 6)
        await manager.checkLikeStatus(for: [post])
        XCTAssertTrue(manager.isLiked("p1"), "前提: サーバー値でいいね済みになっている")

        await manager.toggleLike(post: post)

        XCTAssertFalse(manager.isLiked("p1"))
        XCTAssertFalse(mock.serverLikedPostIds.contains("p1"))
        XCTAssertEqual(manager.likeCount(for: post), 5)
    }

    /// 3. 手元の状態が古く（いいね済みを知らない）ても、押したらいいねが「外れない」（#145 ②）
    ///    ギャラリー系の画面は状態を読まないので、いいね済みの投稿が空のハートで出ることがある。
    ///    そこで押した利用者の意図は「いいねする」。サーバー側でひっくり返してはいけない。
    func testTapWithStaleLocalStateKeepsServerLike() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikedPostIds = ["p1"]
        mock.serverLikesCounts["p1"] = 6
        let manager = makeManager(firestore: mock)
        let post = makePost(id: "p1", likesCount: 6)
        XCTAssertFalse(manager.isLiked("p1"), "前提: 手元はいいね済みを知らない")

        await manager.toggleLike(post: post)

        XCTAssertTrue(mock.serverLikedPostIds.contains("p1"), "サーバーのいいねが消えてはいけない")
        XCTAssertEqual(mock.serverLikesCounts["p1"], 6, "サーバーの数が減っても増えてもいけない")
        XCTAssertTrue(manager.isLiked("p1"))
        XCTAssertEqual(manager.likeCount(for: post), 6, "楽観的な +1 のまま 7 を出してはいけない")
    }

    /// 4. 詳細画面が古い投稿で状態を読み直しても、確定した数字は戻らない（#145 ①の再発防止）
    ///    ギャラリーから開く詳細の `post` は一覧を読んだ時点の値のまま。
    func testCheckLikeStatusWithStalePostKeepsConfirmedCount() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikesCounts["p1"] = 5
        let manager = makeManager(firestore: mock)
        let stalePost = makePost(id: "p1", likesCount: 5)

        await manager.toggleLike(post: stalePost)
        await manager.checkLikeStatus(for: [stalePost])

        XCTAssertTrue(manager.isLiked("p1"))
        XCTAssertEqual(manager.likeCount(for: stalePost), 6)
    }

    /// 5. 一覧を読み直して新しい likesCount が届いたら、その値をそのまま出す（二重カウントしない）
    ///    ultrareview bug_001 の再発防止。
    func testReloadedPostShowsFreshCountWithoutDoubleCounting() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikesCounts["p1"] = 5
        let manager = makeManager(firestore: mock)

        await manager.toggleLike(post: makePost(id: "p1", likesCount: 5))

        XCTAssertEqual(manager.likeCount(for: makePost(id: "p1", likesCount: 6)), 6, "自分の +1 を二重に足さない")
        XCTAssertEqual(manager.likeCount(for: makePost(id: "p1", likesCount: 8)), 8, "他の人のいいねも含む最新値を出す")
    }

    /// 6. 状態の読み直しは、問い合わせた範囲をサーバー値で上書きする（別端末で外した等）
    ///    問い合わせていない投稿の状態は触らない（ページング追加読み込みで既存状態を壊さない）。
    func testCheckLikeStatusOverwritesOnlyQueriedRange() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikedPostIds = ["p1", "keep"]
        let manager = makeManager(firestore: mock)
        await manager.checkLikeStatus(for: [makePost(id: "p1", likesCount: 1), makePost(id: "keep", likesCount: 1)])
        XCTAssertTrue(manager.isLiked("p1"), "前提")

        mock.serverLikedPostIds.remove("p1") // 別端末でいいねを外した
        await manager.checkLikeStatus(for: [makePost(id: "p1", likesCount: 0)])

        XCTAssertFalse(manager.isLiked("p1"), "サーバーで外れたものは手元でも外れる")
        XCTAssertTrue(manager.isLiked("keep"), "問い合わせ範囲外は保持される")
    }

    /// 7. 書き込みの途中でもう一度押しても、書き込みは 1 回だけ（画面とサーバーがずれない）
    ///    「つける／外す」を指定して書く方式では、2 つの書き込みが逆順に確定すると
    ///    画面とサーバーが食い違う。処理中の投稿への連打は受け付けない。
    func testRapidDoubleTapSendsOnlyOneWrite() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikesCounts["p1"] = 5
        let manager = makeManager(firestore: mock)
        let post = makePost(id: "p1", likesCount: 5)
        mock.holdNextWrite = true

        let firstTap = Task { await manager.toggleLike(post: post) }
        // 1 回目が書き込みの途中で「実際に止まった」ところまで待つ。
        // ⚠️ 回数（writeCallCount）で待つと、止める準備の前に次へ進んでしまう。
        await waitUntil { mock.isHoldingWrite }
        XCTAssertTrue(manager.isLiked("p1"), "書き込み中も押した直後の状態（いいね）が出ている")
        await manager.toggleLike(post: post) // 1 回目が終わる前の 2 回目
        mock.releaseHeldWrite()
        await firstTap.value

        XCTAssertEqual(mock.writeCallCount, 1, "処理中の連打で 2 回目を書いてはいけない")
        XCTAssertEqual(manager.isLiked("p1"), mock.serverLikedPostIds.contains("p1"), "画面とサーバーが一致する")
    }

    /// 8. 書き込みが失敗したら、状態も数字も元に戻す（UI が嘘をつかない）
    func testFailureRevertsStateAndCount() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikesCounts["p1"] = 5
        mock.writeError = NSError(domain: "test", code: 1)
        let manager = makeManager(firestore: mock)
        let post = makePost(id: "p1", likesCount: 5)

        await manager.toggleLike(post: post)

        XCTAssertEqual(mock.writeCallCount, 1, "サービスを呼んだ上で失敗したことを確かめる")
        XCTAssertFalse(manager.isLiked("p1"))
        XCTAssertEqual(manager.likeCount(for: post), 5)
        XCTAssertFalse(manager.showLoginPrompt, "書き込み失敗はログイン要求ではない")
    }

    /// 9. 未ログインならログインプロンプトを立て、サービスを呼ばない
    func testToggleWithoutLoginShowsPrompt() async {
        let mock = MockFirestoreServiceForLikes()
        let manager = makeManager(firestore: mock, userId: nil)

        await manager.toggleLike(post: makePost(id: "p1", likesCount: 5))

        XCTAssertTrue(manager.showLoginPrompt)
        XCTAssertEqual(mock.writeCallCount, 0)
        XCTAssertFalse(manager.isLiked("p1"))
    }

    /// 10. 別端末で外した後に読み直すと、押した結果の数字を捨ててサーバーの数を出す（レビュー D1）
    ///     「押した時の likesCount」が偶然また届く（5→6→5）と、数字の一致だけでは古い結果と区別できない。
    ///     サーバーのいいね状態が押した向きと食い違ったら、その数字はもう古い。
    func testCheckLikeStatusDiscardsOverrideWhenServerStateDiffers() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikesCounts["p1"] = 5
        let manager = makeManager(firestore: mock)
        await manager.toggleLike(post: makePost(id: "p1", likesCount: 5))
        XCTAssertEqual(manager.likeCount(for: makePost(id: "p1", likesCount: 5)), 6, "前提: 押した結果が出ている")

        // 同じアカウントの別端末でいいねを外した（サーバーは 5 に戻る）
        mock.serverLikedPostIds.remove("p1")
        mock.serverLikesCounts["p1"] = 5
        let reloaded = makePost(id: "p1", likesCount: 5)
        await manager.checkLikeStatus(for: [reloaded])

        XCTAssertFalse(manager.isLiked("p1"))
        XCTAssertEqual(manager.likeCount(for: reloaded), 5, "空のハートなのに 6 を出してはいけない")
    }

    /// 11. 書き込み中に状態の読み直しが割り込んでも、成功した時点で押した状態とサーバーの数にそろう（レビュー D7）
    ///     詳細画面は開いた時に状態を読むので、開いてすぐ押すと、書き込み前の値で一度上書きされうる。
    func testSuccessReassertsStateAfterInterleavedCheck() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikesCounts["p1"] = 5
        let manager = makeManager(firestore: mock)
        let post = makePost(id: "p1", likesCount: 5)
        mock.holdNextWrite = true

        let tap = Task { await manager.toggleLike(post: post) }
        await waitUntil { mock.isHoldingWrite }
        // 書き込み前のサーバー（いいね無し）を読んだ結果が、書き込み中に届く
        await manager.checkLikeStatus(for: [post])
        mock.releaseHeldWrite()
        await tap.value

        XCTAssertTrue(mock.serverLikedPostIds.contains("p1"))
        XCTAssertTrue(manager.isLiked("p1"), "成功後は押した状態（いいね）にそろう")
        XCTAssertEqual(manager.likeCount(for: post), 6, "数字もサーバーの値にそろう")
    }

    // MARK: - サインアウト・アカウント切替（#147）⭐️
    //
    // LikeManager は App レベルの @StateObject で、サインアウトしても破棄されない。
    // 共有端末で次のユーザーに、前のユーザーのいいね（ピンクのハート）が見えてはいけない。

    /// 12. サインアウトで、いいね状態・押した結果の数字・ログイン案内がすべて消える
    func testClearOnSignOutEmptiesLocalState() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikesCounts["p1"] = 5
        mock.serverLikedPostIds = ["p2"]
        let manager = makeManager(firestore: mock)
        let post = makePost(id: "p1", likesCount: 5)
        await manager.toggleLike(post: post)
        await manager.checkLikeStatus(for: [makePost(id: "p2", likesCount: 1)])
        manager.showLoginPrompt = true
        XCTAssertTrue(manager.isLiked("p1"))
        XCTAssertTrue(manager.isLiked("p2"))

        manager.clearOnSignOut()

        XCTAssertFalse(manager.isLiked("p1"))
        XCTAssertFalse(manager.isLiked("p2"))
        XCTAssertEqual(manager.likeCount(for: post), 5, "押した結果の数字も消え、投稿の値に戻る")
        XCTAssertFalse(manager.showLoginPrompt)
    }

    /// 13. 書き込み中にサインアウトして別のアカウントになったら、成功しても前のユーザーのいいねを戻さない
    func testSuccessAfterAccountSwitchDoesNotRestoreState() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikesCounts["p1"] = 5
        let auth = makeSignedInAuth(userId: "me")
        let manager = LikeManager(firestoreService: mock, authService: auth)
        let post = makePost(id: "p1", likesCount: 5)
        mock.holdNextWrite = true

        let tap = Task { await manager.toggleLike(post: post) }
        await waitUntil { mock.isHoldingWrite }
        switchAccount(auth, to: "you", manager: manager)
        mock.releaseHeldWrite()
        await tap.value

        XCTAssertFalse(manager.isLiked("p1"), "次のユーザーに前のユーザーのいいねを見せない")
        XCTAssertEqual(manager.likeCount(for: post), 5, "前のユーザーが押した結果の数字も出さない")
    }

    /// 14. 書き込み中にアカウントが変わったら、失敗しても前のユーザーの状態へ巻き戻さない
    func testFailureAfterAccountSwitchDoesNotRevert() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikesCounts["p1"] = 5
        mock.serverLikedPostIds = ["p1"]
        let auth = makeSignedInAuth(userId: "me")
        let manager = LikeManager(firestoreService: mock, authService: auth)
        let post = makePost(id: "p1", likesCount: 5)
        await manager.checkLikeStatus(for: [post])
        XCTAssertTrue(manager.isLiked("p1"), "前提: いいね済み")
        mock.writeError = FirestoreServiceError.notFound
        mock.holdNextWrite = true

        let tap = Task { await manager.toggleLike(post: post) } // 外す → 失敗する
        await waitUntil { mock.isHoldingWrite }
        switchAccount(auth, to: "you", manager: manager)
        mock.releaseHeldWrite()
        await tap.value

        XCTAssertFalse(manager.isLiked("p1"), "失敗の巻き戻しで前のユーザーのいいねを復活させない")
    }

    /// 15. いいね状態の読み取り中にアカウントが変わったら、届いた前のユーザーの状態を反映しない
    func testCheckLikeStatusAfterAccountSwitchIsIgnored() async {
        let mock = MockFirestoreServiceForLikes()
        mock.serverLikedPostIds = ["p1"]
        let auth = makeSignedInAuth(userId: "me")
        let manager = LikeManager(firestoreService: mock, authService: auth)
        mock.holdNextCheck = true

        let check = Task { await manager.checkLikeStatus(for: [self.makePost(id: "p1", likesCount: 1)]) }
        await waitUntil { mock.isHoldingWrite }
        switchAccount(auth, to: "you", manager: manager)
        mock.releaseHeldWrite()
        await check.value

        XCTAssertFalse(manager.isLiked("p1"), "前のユーザーの読み取り結果を次のユーザーに反映しない")
    }

    /// ログイン済みの認証サービス（アカウントを途中で切り替えるテスト用に、外から触れるようにする）
    private func makeSignedInAuth(userId: String) -> MockAuthService {
        let auth = MockAuthService()
        auth.currentUserValue = User(id: userId)
        return auth
    }

    /// サインアウトして別のアカウントでサインインし直す（ContentView がサインアウト時に clearOnSignOut を呼ぶのと同じ順）
    private func switchAccount(_ auth: MockAuthService, to userId: String, manager: LikeManager) {
        auth.currentUserValue = nil
        manager.clearOnSignOut()
        auth.currentUserValue = User(id: userId)
    }
}

// MARK: - Mock

/// サーバー上のいいね状態を持つ最小 Mock（いいねの読み書きだけ上書き、
/// 残りは FirestoreServiceProtocol+TestDefaults）
final class MockFirestoreServiceForLikes: FirestoreServiceProtocol {
    /// サーバー上で「いいね済み」の postId
    var serverLikedPostIds: Set<String> = []
    /// サーバー上の posts.likesCount（postId -> 数）
    var serverLikesCounts: [String: Int] = [:]
    /// 書き込みを呼んだ回数
    private(set) var writeCallCount = 0
    /// 書き込みで投げるエラー（nil なら成功）
    var writeError: Error?
    /// true にすると、次の書き込み 1 回だけを `releaseHeldWrite()` まで止める（連打テスト用）
    var holdNextWrite = false
    /// true にすると、次のいいね状態の読み取り 1 回だけを `releaseHeldWrite()` まで止める（アカウント切替テスト用）⭐️
    var holdNextCheck = false
    /// 止める／再開するの受け渡しは別スレッドから来うるので、ロックで守る
    private let holdLock = NSLock()
    private var heldWrite: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    /// 書き込みが実際に止まっているか
    var isHoldingWrite: Bool {
        holdLock.withLock { heldWrite != nil }
    }

    /// 止めていた書き込みを再開する（まだ止まる前なら、止まらずに通すよう予約する）
    func releaseHeldWrite() {
        let continuation: CheckedContinuation<Void, Never>? = holdLock.withLock {
            releaseRequested = true
            defer { heldWrite = nil }
            return heldWrite
        }
        continuation?.resume()
    }

    /// holdNextWrite が立っていれば、releaseHeldWrite() が呼ばれるまで待つ
    private func waitIfHeld() async {
        guard holdNextWrite else { return }
        holdNextWrite = false
        await waitForRelease()
    }

    /// releaseHeldWrite() が呼ばれるまで待つ（書き込み・読み取り共通）
    private func waitForRelease() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = holdLock.withLock {
                if releaseRequested { return true }
                heldWrite = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// 本物の setLike と同じ「つける／外すを指定して書く」書き込み（既にその状態なら書かない）
    func setLike(postId: String, userId _: String, isLiked: Bool) async throws -> Int {
        // ⚠️ 記録は throw より前（FavoriteManagerTests と同じ理由）
        writeCallCount += 1
        await waitIfHeld()
        if let writeError { throw writeError }

        let exists = serverLikedPostIds.contains(postId)
        if isLiked, !exists {
            serverLikedPostIds.insert(postId)
            serverLikesCounts[postId, default: 0] += 1
        } else if !isLiked, exists {
            serverLikedPostIds.remove(postId)
            serverLikesCounts[postId, default: 0] -= 1
        }
        return serverLikesCounts[postId, default: 0]
    }

    func batchCheckLikeStatus(postIds: [String], userId _: String) async throws -> Set<String> {
        // 読んだ結果は止める前に決める（止めている間にサインアウトしても、届くのは前のユーザーの状態）
        let likedIds = serverLikedPostIds.intersection(postIds)
        if holdNextCheck {
            holdNextCheck = false
            await waitForRelease()
        }
        // 問い合わせた範囲に絞って返す（本物と同じ振る舞い）
        return likedIds
    }
}
