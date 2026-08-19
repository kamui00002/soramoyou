//
//  TagDetailViewModelTests.swift
//  SoramoyouTests
//
//  タグ詳細画面 ViewModel の「タグフォロー」まわりのテスト ⭐️
//
//  ここで守りたいのは主に 2 点。
//  ① 上限（User.maxFollowedTags = 30）を超えるフォローを書き込ませないこと。
//     判定は必ず「サーバーから取り直した最新の followedTags」に対して行うため、
//     モックの fetchUser が返す User の件数でシナリオを組む。
//  ② 未ログイン（ゲスト）では書き込みを一切行わず、理由をユーザーに見せること。
//
//  Firestore には触らないため、エミュレータ無しで実行できる。
//  Mock は PostDetailViewModelTests と同じ「必要なメソッドだけ上書きし、
//  残りは FirestoreServiceProtocol+TestDefaults（fatalError）に任せる」方式。
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

@MainActor
final class TagDetailViewModelTests: XCTestCase {
    /// テスト対象のタグ（"#" を含まない生の単語）
    private let targetTag = "夕焼け"

    // MARK: - フォロー

    /// フォロー中タグが 29 件（上限未満）なら followTag が呼ばれて成功すること
    func testToggleFollowTagFollowsWhenUnderLimit() async {
        // Arrange: サーバー上は対象タグを含まない 29 件
        let firestore = MockFirestoreServiceForTagDetail()
        firestore.stubbedUser = makeUser(followedTags: otherTags(count: 29))
        let viewModel = makeViewModel(firestoreService: firestore, currentUserId: "user-1")

        // Act
        await viewModel.toggleFollowTag()

        // Assert: 書き込みが 1 回だけ走り、状態がフォロー中になる
        XCTAssertEqual(firestore.followTagCalls.count, 1)
        XCTAssertEqual(firestore.followTagCalls.first?.userId, "user-1")
        XCTAssertEqual(firestore.followTagCalls.first?.tag, targetTag)
        XCTAssertTrue(firestore.unfollowTagCalls.isEmpty)
        XCTAssertTrue(viewModel.isFollowingTag)
        XCTAssertNil(viewModel.followErrorMessage)
        XCTAssertFalse(viewModel.isTogglingFollow)
    }

    /// フォロー中タグが 30 件（上限）なら followTag を呼ばず、エラーを見せること
    ///
    /// ⚠️ arrayUnion は配列長を知らないため、ここで止めないと黙って 31 件目が書ける。
    func testToggleFollowTagDoesNotFollowWhenAtLimit() async {
        // Arrange: サーバー上は対象タグを含まない 30 件（＝上限ぴったり）
        let firestore = MockFirestoreServiceForTagDetail()
        firestore.stubbedUser = makeUser(followedTags: otherTags(count: User.maxFollowedTags))
        let viewModel = makeViewModel(firestoreService: firestore, currentUserId: "user-1")

        // Act
        await viewModel.toggleFollowTag()

        // Assert: 書き込みは一切走らず、理由がユーザーに見える
        XCTAssertTrue(firestore.followTagCalls.isEmpty, "上限に達していたら followTag を呼んではいけない")
        XCTAssertTrue(firestore.unfollowTagCalls.isEmpty)
        XCTAssertFalse(viewModel.isFollowingTag)
        XCTAssertNotNil(viewModel.followErrorMessage)
        XCTAssertTrue(
            viewModel.followErrorMessage?.contains("\(User.maxFollowedTags)") ?? false,
            "上限件数がメッセージに含まれるべき: \(viewModel.followErrorMessage ?? "nil")"
        )
        XCTAssertFalse(viewModel.isTogglingFollow)
    }

    // MARK: - フォロー解除

    /// 既にフォロー済みのタグなら unfollowTag が呼ばれること
    func testToggleFollowTagUnfollowsWhenAlreadyFollowing() async {
        // Arrange: サーバー上の followedTags に対象タグが入っている
        let firestore = MockFirestoreServiceForTagDetail()
        firestore.stubbedUser = makeUser(followedTags: otherTags(count: 3) + [targetTag])
        let viewModel = makeViewModel(firestoreService: firestore, currentUserId: "user-1")

        // Act
        await viewModel.toggleFollowTag()

        // Assert
        XCTAssertEqual(firestore.unfollowTagCalls.count, 1)
        XCTAssertEqual(firestore.unfollowTagCalls.first?.userId, "user-1")
        XCTAssertEqual(firestore.unfollowTagCalls.first?.tag, targetTag)
        XCTAssertTrue(firestore.followTagCalls.isEmpty)
        XCTAssertFalse(viewModel.isFollowingTag)
        XCTAssertNil(viewModel.followErrorMessage)
    }

    // MARK: - ゲスト（未ログイン）

    /// 未ログインなら書き込みも読み取りも行わず、ログインが必要な旨を見せること
    func testToggleFollowTagDoesNothingForGuest() async {
        // Arrange: currentUser() が nil（ゲストモード＝Firebase 未認証）
        let firestore = MockFirestoreServiceForTagDetail()
        let viewModel = makeViewModel(firestoreService: firestore, currentUserId: nil)

        // Act
        await viewModel.toggleFollowTag()

        // Assert: guard が最初に発火するので fetchUser すら呼ばれない
        XCTAssertEqual(firestore.fetchUserCallCount, 0, "未ログインならサーバーへ問い合わせない")
        XCTAssertTrue(firestore.followTagCalls.isEmpty)
        XCTAssertTrue(firestore.unfollowTagCalls.isEmpty)
        XCTAssertFalse(viewModel.isFollowingTag)
        XCTAssertTrue(
            viewModel.followErrorMessage?.contains("ログイン") ?? false,
            "ログインが必要な旨を見せるべき: \(viewModel.followErrorMessage ?? "nil")"
        )
    }

    // MARK: - Helpers

    /// テスト対象の ViewModel を組み立てる
    /// - Parameter currentUserId: nil ならゲスト（未ログイン）扱い
    private func makeViewModel(
        firestoreService: MockFirestoreServiceForTagDetail,
        currentUserId: String?
    ) -> TagDetailViewModel {
        // MockAuthService は AuthViewModelTests のものを再利用する（同じテストターゲット）。
        // 同名クラスを重複定義するとコンパイルできないため、新規には作らない。
        let authService = MockAuthService()
        authService.currentUserValue = currentUserId.map { User(id: $0, email: "test@example.com") }

        return TagDetailViewModel(
            tag: targetTag,
            firestoreService: firestoreService,
            tagFeedService: MockTagFeedServiceForTagDetail(),
            authService: authService
        )
    }

    /// 対象タグを含まないダミーのフォロー中タグを count 件つくる
    private func otherTags(count: Int) -> [String] {
        (0 ..< count).map { "タグ\($0)" }
    }

    /// フォロー中タグだけを差し替えたテスト用 User
    private func makeUser(id: String = "user-1", followedTags: [String]?) -> User {
        User(id: id, email: "test@example.com", followedTags: followedTags)
    }
}

// MARK: - Mocks

/// フォロー操作に必要な 3 メソッドだけ上書きする Mock。
/// 呼ばれた回数・引数を記録して「呼ばれていないこと」も検証できるようにする。
final class MockFirestoreServiceForTagDetail: FirestoreServiceProtocol {
    /// fetchUser が返すユーザー（＝サーバー上の最新状態）
    var stubbedUser: User?
    /// fetchUser を失敗させたいときに設定する
    var stubbedFetchUserError: Error?

    private(set) var fetchUserCallCount = 0
    private(set) var followTagCalls: [(userId: String, tag: String)] = []
    private(set) var unfollowTagCalls: [(userId: String, tag: String)] = []

    func fetchUser(userId: String) async throws -> User {
        fetchUserCallCount += 1
        if let stubbedFetchUserError { throw stubbedFetchUserError }
        guard let stubbedUser else {
            fatalError("MockFirestoreServiceForTagDetail.stubbedUser が未設定です（userId=\(userId)）")
        }
        return stubbedUser
    }

    func followTag(userId: String, tag: String) async throws {
        followTagCalls.append((userId: userId, tag: tag))
    }

    func unfollowTag(userId: String, tag: String) async throws {
        unfollowTagCalls.append((userId: userId, tag: tag))
    }
}

/// タグフィード取得の Mock。フォローのテストでは一覧を読まないので空を返すだけ。
/// （実サービスの既定引数だと Firestore.firestore() に触れてしまうため、必ず注入する）
final class MockTagFeedServiceForTagDetail: TagFeedServiceProtocol {
    var stubbedPosts: [Post] = []

    func fetchPostsByHashtag(
        _: String,
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        (posts: stubbedPosts, lastDocument: nil)
    }

    func fetchInferredTags(userId _: String, topN _: Int) async throws -> [String] {
        []
    }
}
