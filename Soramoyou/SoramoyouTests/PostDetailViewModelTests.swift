//
//  PostDetailViewModelTests.swift
//  SoramoyouTests
//
//  投稿詳細画面 ViewModel のテスト。統合レビューで発見した
//  「再編集後、投稿詳細が古い画像URL/公開範囲を保持し続ける」バグの修正
//  （refreshPost メソッド）を検証する。CalendarDiaryViewModelTests と同型の最小 Mock を使う。
//
//  加えて「他人の投稿詳細で著者が無言で消える」バグ（loadAuthor が権限で読めない
//  `users` を参照していた）の修正も検証する。Mock はあえて `fetchUser` を実装せず
//  TestDefaults の fatalError のままにしてあり、`users` 参照に戻す回帰が起きたら
//  テストが即座にクラッシュして気付ける構成にしている。
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore

@MainActor
final class PostDetailViewModelTests: XCTestCase {

    func testRefreshPostReturnsLatestPostFromFirestore() async {
        // Arrange: Firestore 側は再編集後の新しい画像URL・非公開設定を返す
        let mock = MockFirestoreServiceForPostDetail()
        let updatedPost = Post(
            id: "post1",
            userId: "u1",
            images: [ImageInfo(url: "https://example.com/new.jpg", thumbnail: "", width: 100, height: 100, order: 0)],
            visibility: .private
        )
        mock.stubbedPost = updatedPost
        let viewModel = PostDetailViewModel(firestoreService: mock)

        // Act
        let result = await viewModel.refreshPost(postId: "post1")

        // Assert: 取得した最新投稿がそのまま返る（呼び出し元 View が @State post に差し替える想定）
        XCTAssertEqual(result?.id, "post1")
        XCTAssertEqual(result?.images.first?.url, "https://example.com/new.jpg")
        XCTAssertEqual(result?.visibility, .private)
        XCTAssertEqual(mock.requestedPostId, "post1")
    }

    func testRefreshPostReturnsNilOnFailureWithoutCrashing() async {
        // Arrange: Firestore 取得が失敗する（ネットワークエラー等）
        let mock = MockFirestoreServiceForPostDetail()
        mock.stubbedError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        let viewModel = PostDetailViewModel(firestoreService: mock)

        // Act
        let result = await viewModel.refreshPost(postId: "post1")

        // Assert: nil を返し、呼び出し側が直前の post を保持できるようにする（表示を壊さない）
        XCTAssertNil(result, "取得失敗時は nil を返し、呼び出し側で直前の post を保持できるようにするべき")
    }

    // MARK: - loadAuthor（他人の投稿で著者が消えるバグの回帰テスト）

    func testLoadAuthorFetchesFromPublicProfilesCollection() async {
        // Arrange: publicProfiles 側にだけ投稿者を用意する。
        // `fetchUser`（users コレクション）は Mock に実装していないため、
        // 万一そちらを呼ぶ実装に戻ると TestDefaults の fatalError で落ちる。
        let mock = MockFirestoreServiceForPostDetail()
        mock.stubbedPublicProfile = PublicProfile(
            id: "u1",
            displayName: "そらまめ",
            photoURL: "https://example.com/icon.jpg"
        )
        let viewModel = PostDetailViewModel(firestoreService: mock)

        // Act
        await viewModel.loadAuthor(userId: "u1")

        // Assert: publicProfiles から取得できており、著者ブロックを描画できる状態になる
        XCTAssertEqual(mock.requestedPublicProfileUserId, "u1",
                       "他人の users は Security Rules で読めないため publicProfiles を参照するべき")
        XCTAssertEqual(viewModel.author?.id, "u1")
        XCTAssertEqual(viewModel.author?.displayName, "そらまめ")
        XCTAssertEqual(viewModel.author?.photoURL, "https://example.com/icon.jpg")
        XCTAssertFalse(viewModel.isLoadingAuthor, "読み込み完了後はローディング表示を畳むべき")
    }

    func testLoadAuthorKeepsErrorMessageNilOnFailure() async {
        // Arrange: 公開プロフィールの取得が失敗する（未作成ユーザー・ネットワーク断など）
        let mock = MockFirestoreServiceForPostDetail()
        mock.stubbedPublicProfileError = FirestoreServiceError.notFound
        let viewModel = PostDetailViewModel(firestoreService: mock)

        // Act
        await viewModel.loadAuthor(userId: "u1")

        // Assert: この画面にはアラート導線が無いため errorMessage は立てず、
        //         ログ（ErrorHandler.logError）だけに留める
        XCTAssertNil(viewModel.author)
        XCTAssertNil(viewModel.errorMessage, "アラート導線が無い画面なので errorMessage には出さない（ログのみ）")
        XCTAssertFalse(viewModel.isLoadingAuthor, "失敗時もローディング表示は畳むべき")
    }
}

// MARK: - Mock

/// `fetchPost` / `fetchPublicProfile` のみ上書きする最小 Mock。残りは TestDefaults（fatalError）で満たす。
/// ⚠️ `fetchUser` はあえて実装しない（users 参照に戻る回帰を fatalError で検知するため）。
final class MockFirestoreServiceForPostDetail: FirestoreServiceProtocol {
    var stubbedPost: Post?
    var stubbedError: Error?
    private(set) var requestedPostId: String?

    /// loadAuthor 用スタブ（publicProfiles コレクション側）
    var stubbedPublicProfile: PublicProfile?
    var stubbedPublicProfileError: Error?
    private(set) var requestedPublicProfileUserId: String?

    func fetchPost(postId: String) async throws -> Post {
        requestedPostId = postId
        if let stubbedError { throw stubbedError }
        guard let stubbedPost else {
            fatalError("MockFirestoreServiceForPostDetail.stubbedPost が未設定です")
        }
        return stubbedPost
    }

    func fetchPublicProfile(userId: String) async throws -> PublicProfile {
        requestedPublicProfileUserId = userId
        if let stubbedPublicProfileError { throw stubbedPublicProfileError }
        guard let stubbedPublicProfile else {
            fatalError("MockFirestoreServiceForPostDetail.stubbedPublicProfile が未設定です")
        }
        return stubbedPublicProfile
    }
}
