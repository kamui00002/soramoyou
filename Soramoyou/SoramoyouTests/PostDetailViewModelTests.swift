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

import FirebaseFirestore
@testable import Soramoyou
import XCTest

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

    // MARK: - ブロック通知 ⭐️

    /// ブロックに成功したら、一覧に伝える通知（.userBlocked）をブロック相手の ID 付きで送る
    func testBlockPostAuthor_成功したらブロック相手のIDを付けて通知を送る() async {
        let mock = MockFirestoreServiceForPostDetail()
        let viewModel = PostDetailViewModel(firestoreService: mock, authService: makeSignedInAuthService())
        let post = Post(id: "post1", userId: "blocked-user", images: [], visibility: .public)
        let notified = expectation(forNotification: .userBlocked, object: nil) { notification in
            notification.userInfo?[Notification.blockedUserIdKey] as? String == "blocked-user"
        }

        let blocked = await viewModel.blockPostAuthor(post: post)

        await fulfillment(of: [notified], timeout: 1)
        XCTAssertTrue(blocked, "保存できたら true（画面はこれを見て閉じる）")
        XCTAssertEqual(mock.blockedUserIds, ["blocked-user"])
    }

    /// ブロックに失敗したら通知を送らない（一覧から消したのに実際はブロックされていない、を防ぐ）
    func testBlockPostAuthor_失敗したら通知を送らない() async {
        let mock = MockFirestoreServiceForPostDetail()
        mock.stubbedBlockUserError = FirestoreServiceError.notFound
        let viewModel = PostDetailViewModel(firestoreService: mock, authService: makeSignedInAuthService())
        let post = Post(id: "post1", userId: "blocked-user", images: [], visibility: .public)
        let notified = expectation(forNotification: .userBlocked, object: nil)
        notified.isInverted = true

        let blocked = await viewModel.blockPostAuthor(post: post)

        await fulfillment(of: [notified], timeout: 0.3)
        XCTAssertFalse(blocked, "保存できなかったら false（画面を閉じない）")
        XCTAssertNotNil(viewModel.reportError, "失敗はエラーとして画面に出す")
    }

    /// ゲスト（ログインしていない人）がブロックしても保存せずに false を返す ⭐️
    /// 以前は何もせずに抜けても、画面が「エラーが無い＝できた」と見て閉じていた
    func testBlockPostAuthor_ゲストは保存せずにfalseを返す() async {
        let mock = MockFirestoreServiceForPostDetail()
        let viewModel = PostDetailViewModel(firestoreService: mock, authService: MockAuthService())
        let post = Post(id: "post1", userId: "blocked-user", images: [], visibility: .public)
        let notified = expectation(forNotification: .userBlocked, object: nil)
        notified.isInverted = true

        let blocked = await viewModel.blockPostAuthor(post: post)

        await fulfillment(of: [notified], timeout: 0.3)
        XCTAssertFalse(blocked, "ゲストは保存できないので false（画面を閉じない）")
        XCTAssertEqual(mock.blockedUserIds, [], "ゲストは保存しに行かない")
    }

    // MARK: - 通報 ⭐️（ゲストに「通報しました」が出ていた不具合）

    /// ゲストが通報しても送らずに false を返す。reportError も立てない
    /// （ゲストへの案内は、画面が isSignedIn を見て先に「ログインが必要です」で出す）
    func testSubmitReport_ゲストは送らずにfalseを返す() async {
        let mock = MockFirestoreServiceForPostDetail()
        let viewModel = PostDetailViewModel(firestoreService: mock, authService: MockAuthService())
        let post = Post(id: "post1", userId: "author", images: [], visibility: .public)

        let reported = await viewModel.submitReport(post: post, reason: .spam)

        XCTAssertFalse(reported, "ゲストは送れないので false（「通報しました」を出さない）")
        XCTAssertEqual(mock.reportedPosts, [], "ゲストは送りに行かない")
        XCTAssertNil(viewModel.reportError, "ゲストの案内は画面の「ログインが必要です」で出すので、エラーは立てない")
    }

    /// ログインした人の通報は、自分の uid で送られて true を返す
    /// （Apple の審査で求められる通報の仕組みが、ログインした人には今までどおり使えることを守る）
    func testSubmitReport_ログインした人は自分のIDで送ってtrueを返す() async {
        let mock = MockFirestoreServiceForPostDetail()
        let viewModel = PostDetailViewModel(firestoreService: mock, authService: makeSignedInAuthService())
        let post = Post(id: "post1", userId: "author", images: [], visibility: .public)

        let reported = await viewModel.submitReport(post: post, reason: .spam)

        XCTAssertTrue(reported, "送れたら true（画面はこれを見て「通報しました」を出す）")
        XCTAssertEqual(mock.reportedPosts, [
            MockFirestoreServiceForPostDetail.ReportedPost(
                postId: "post1",
                reporterId: "current-user",
                reportedUserId: "author",
                reason: "spam"
            ),
        ])
        XCTAssertNil(viewModel.reportError)
    }

    /// 送信に失敗したら false を返し、理由を reportError に入れる（画面の「エラー」のアラートが出す）
    func testSubmitReport_失敗したらfalseでエラーを立てる() async {
        let mock = MockFirestoreServiceForPostDetail()
        mock.stubbedReportPostError = FirestoreServiceError.notFound
        let viewModel = PostDetailViewModel(firestoreService: mock, authService: makeSignedInAuthService())
        let post = Post(id: "post1", userId: "author", images: [], visibility: .public)

        let reported = await viewModel.submitReport(post: post, reason: .spam)

        XCTAssertFalse(reported, "送れなかったら false（「通報しました」を出さない）")
        XCTAssertNotNil(viewModel.reportError, "失敗はエラーとして画面に出す")
    }

    /// 一度失敗したあとに成功したら、前の失敗の理由が消えている
    /// （以前は reportError がどこでも消されず、前の失敗が残ったままになっていた）
    func testSubmitReport_失敗のあとに成功したら前のエラーが消える() async {
        let mock = MockFirestoreServiceForPostDetail()
        mock.stubbedReportPostError = FirestoreServiceError.notFound
        let viewModel = PostDetailViewModel(firestoreService: mock, authService: makeSignedInAuthService())
        let post = Post(id: "post1", userId: "author", images: [], visibility: .public)
        let firstReported = await viewModel.submitReport(post: post, reason: .spam)
        XCTAssertFalse(firstReported, "前提: 1 回目は失敗している")
        XCTAssertNotNil(viewModel.reportError, "前提: 1 回目の失敗の理由が入っている")

        mock.stubbedReportPostError = nil
        let reported = await viewModel.submitReport(post: post, reason: .spam)

        XCTAssertTrue(reported)
        XCTAssertNil(viewModel.reportError, "前の失敗の理由が残っていると、成功したのに「エラー」のアラートが出てしまう")
    }

    // MARK: - isSignedIn ⭐️

    /// 画面が「ログインが必要です」を出すかの判定は、uid の有無で決まる
    func testIsSignedIn_ゲストはfalseでログインした人はtrue() {
        let mock = MockFirestoreServiceForPostDetail()

        let guestViewModel = PostDetailViewModel(firestoreService: mock, authService: MockAuthService())
        let signedInViewModel = PostDetailViewModel(firestoreService: mock, authService: makeSignedInAuthService())

        XCTAssertFalse(guestViewModel.isSignedIn, "ゲストは uid が無いので false")
        XCTAssertTrue(signedInViewModel.isSignedIn, "ログインした人は uid があるので true")
    }

    /// ログイン済みの認証サービス（ログインしていないと通報・ブロックは何もしない）
    private func makeSignedInAuthService() -> MockAuthService {
        let authService = MockAuthService()
        authService.currentUserValue = User(id: "current-user", email: "test@example.com")
        return authService
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

    // MARK: ブロック（通知のテスト用）⭐️

    /// blockUser を失敗させたいときに設定する
    var stubbedBlockUserError: Error?
    /// blockUser に渡されたブロック相手の ID
    private(set) var blockedUserIds: [String] = []

    func blockUser(userId _: String, blockedUserId: String) async throws {
        if let stubbedBlockUserError { throw stubbedBlockUserError }
        blockedUserIds.append(blockedUserId)
    }

    // MARK: 通報（ゲストに「通報しました」が出ていた不具合のテスト用）⭐️

    /// reportPost に渡された中身
    struct ReportedPost: Equatable {
        let postId: String
        let reporterId: String
        let reportedUserId: String
        let reason: String
    }

    /// reportPost を失敗させたいときに設定する
    var stubbedReportPostError: Error?
    /// reportPost に渡された中身（呼ばれた回数もこれで数える。失敗させたときも、呼ばれたことは残す）
    private(set) var reportedPosts: [ReportedPost] = []

    func reportPost(postId: String, reporterId: String, reportedUserId: String, reason: String) async throws {
        reportedPosts.append(ReportedPost(postId: postId, reporterId: reporterId, reportedUserId: reportedUserId, reason: reason))
        if let stubbedReportPostError { throw stubbedReportPostError }
    }
}
