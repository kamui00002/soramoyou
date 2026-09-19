//
//  ProfileViewModelTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore
// Note: FirebaseAuth.Userとの競合を避けるため、Userは Soramoyou.User を参照

@MainActor
final class ProfileViewModelTests: XCTestCase {
    var viewModel: ProfileViewModel!
    var mockFirestoreService: MockFirestoreServiceForProfile!
    var mockStorageService: MockStorageServiceForProfile!
    
    override func setUp() {
        super.setUp()
        mockFirestoreService = MockFirestoreServiceForProfile()
        mockStorageService = MockStorageServiceForProfile()
    }
    
    override func tearDown() {
        viewModel = nil
        mockFirestoreService = nil
        mockStorageService = nil
        super.tearDown()
    }
    
    func testProfileViewModelInitialization() {
        // Given & When
        let viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        
        // Then
        XCTAssertNotNil(viewModel)
        XCTAssertNil(viewModel.user)
        XCTAssertTrue(viewModel.userPosts.isEmpty)
        XCTAssertTrue(viewModel.equippedTools.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
    }
    
    func testLoadProfile() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        
        // When
        await viewModel.loadProfile()
        
        // Then
        XCTAssertNotNil(viewModel.user)
        XCTAssertEqual(viewModel.user?.id, testUser.id)
        XCTAssertEqual(viewModel.editingDisplayName, testUser.displayName ?? "")
        XCTAssertEqual(viewModel.editingBio, testUser.bio ?? "")
    }
    
    func testLoadUserPosts() async {
        // Given
        let testUser = createTestUser()
        let testPosts = createTestPosts(userId: testUser.id)
        mockFirestoreService.user = testUser
        mockFirestoreService.userPosts = testPosts
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        
        // When
        await viewModel.loadUserPosts()
        
        // Then
        XCTAssertFalse(viewModel.userPosts.isEmpty)
        XCTAssertEqual(viewModel.userPosts.count, testPosts.count)
    }
    
    /// ⭐️ 回帰防止: 投稿が 50 件を超えても投稿数が 50 に書き戻されないこと。
    /// 旧実装は「取得した 1 ページ分の件数」を投稿数として保存していた。
    func testLoadUserPosts_自分の投稿数は取得件数でなく集計値になる() async {
        // Given: 画面に並べるのは 2 件だが、実際の投稿は 104 件ある
        let testUser = createTestUser()
        mockFirestoreService.userPosts = createTestPosts(userId: testUser.id)
        mockFirestoreService.recountedPostsCount = 104
        let authService = MockAuthService()
        authService.currentUserValue = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService,
            authService: authService
        )
        viewModel.user = testUser  // postsCount = 5（古い値）

        // When
        await viewModel.loadUserPosts()

        // Then: 取得件数（2）ではなく、集計した 104 が表示される
        XCTAssertEqual(mockFirestoreService.recountPostsCountCallCount, 1)
        XCTAssertEqual(viewModel.user?.postsCount, 104)
        XCTAssertEqual(viewModel.userPosts.count, 2)
    }

    /// ⭐️ 他人のプロフィールでは投稿数を数え直さない（書き込み権限も無い）
    func testLoadUserPosts_他人のプロフィールでは投稿数を数え直さない() async {
        let testUser = createTestUser()
        mockFirestoreService.userPosts = createTestPosts(userId: testUser.id)
        let authService = MockAuthService()
        authService.currentUserValue = User(id: "someone-else", email: "other@example.com")
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService,
            authService: authService
        )
        viewModel.user = testUser

        await viewModel.loadUserPosts()

        XCTAssertEqual(mockFirestoreService.recountPostsCountCallCount, 0)
        XCTAssertEqual(viewModel.user?.postsCount, 5)
    }

    /// ⭐️ 1 ページ目がページサイズぴったりなら「続きあり」、足りなければ「続きなし」
    func testLoadUserPosts_1ページ目の件数で続きの有無が決まる() async {
        let testUser = createTestUser()
        let imageInfo = ImageInfo(url: "https://example.com/image.jpg", width: 1024, height: 768, order: 0)
        let makePost = { (id: String) in
            Post(id: id, userId: testUser.id, images: [imageInfo], caption: nil, visibility: .public)
        }
        let onePost = makePost("post-single")
        let fullPage = (0..<ProfileViewModel.postsPageSize).map { makePost("post-\($0)") }
        mockFirestoreService.userPostPages = [fullPage]
        // 本物の AuthService（Auth.auth()）に触れないようモックを注入する（自分のプロフィール扱い）
        let authService = MockAuthService()
        authService.currentUserValue = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService,
            authService: authService
        )

        await viewModel.loadUserPosts()
        XCTAssertTrue(viewModel.hasMorePosts)

        // 引っ張って更新 → 今度は 1 件しか無い
        mockFirestoreService.userPostPages = [[onePost]]
        mockFirestoreService.fetchUserPostsPageCallCount = 0
        await viewModel.loadUserPosts()
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertEqual(viewModel.userPosts.count, 1)
    }

    /// ⭐️ 続き読み込み: 2 ページ目が末尾に追記され、境界の重複は除かれ、最終ページで止まる
    func testLoadMoreUserPosts_2ページ目を追記し重複を除き最終ページで止まる() async {
        let testUser = createTestUser()
        let imageInfo = ImageInfo(url: "https://example.com/image.jpg", width: 1024, height: 768, order: 0)
        let makePost = { (id: String) in
            Post(id: id, userId: testUser.id, images: [imageInfo], caption: nil, visibility: .public)
        }
        let fullPage = (0..<ProfileViewModel.postsPageSize).map { makePost("post-\($0)") }
        // 2 ページ目の先頭は 1 ページ目の最後と同じ投稿（ページ境界の重複）
        let lastOfFirstPage = "post-\(ProfileViewModel.postsPageSize - 1)"
        let secondPage = [makePost(lastOfFirstPage), makePost("post-a"), makePost("post-b")]
        mockFirestoreService.userPostPages = [fullPage, secondPage]
        let authService = MockAuthService()
        authService.currentUserValue = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService,
            authService: authService
        )

        await viewModel.loadUserPosts()
        XCTAssertTrue(viewModel.hasMorePosts)

        // When: 末尾まで来たので続きを読む
        let added = await viewModel.loadMoreUserPosts()

        // Then: 重複を除いた 2 件だけが末尾に追記され、続きは無くなる
        XCTAssertEqual(added.map(\.id), ["post-a", "post-b"])
        XCTAssertEqual(viewModel.userPosts.count, ProfileViewModel.postsPageSize + 2)
        XCTAssertEqual(viewModel.userPosts.last?.id, "post-b")
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertFalse(viewModel.isLoadingMorePosts)

        // 続きが無いので、もう一度呼んでも取得しない
        let again = await viewModel.loadMoreUserPosts()
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(mockFirestoreService.fetchUserPostsPageCallCount, 2)
    }

    func testUpdateProfile() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()
        
        viewModel.editingDisplayName = "Updated Name"
        viewModel.editingBio = "Updated Bio"
        
        // When
        await viewModel.updateProfile()
        
        // Then
        XCTAssertEqual(viewModel.user?.displayName, "Updated Name")
        XCTAssertEqual(viewModel.user?.bio, "Updated Bio")
    }
    
    func testUpdateProfileWithImage() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()
        
        let testImage = UIImage(systemName: "photo")!
        viewModel.editingProfileImage = testImage
        viewModel.editingDisplayName = "Updated Name"
        
        // When
        await viewModel.updateProfile()
        
        // Then
        XCTAssertNotNil(mockStorageService.uploadedImage)
        XCTAssertEqual(viewModel.user?.displayName, "Updated Name")
    }

    /// 回帰テスト ⭐️: プロフィール更新が publicProfiles のフォローカウンタを書き換えないこと
    ///
    /// PublicProfile 全体書き込みは、クライアントが持つ古い followersCount /
    /// followingCount で Cloud Functions が保った真値を潰すため経路ごと廃止した
    /// （メソッド自体を型から削除済み＝呼び出しはコンパイラが構造的に禁止する）。
    /// ここでは残った唯一の経路であるターゲット更新が、編集対象フィールドだけを
    /// 渡していることを確認する。
    func testUpdateProfileDoesNotWriteFollowCounters() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        viewModel.editingDisplayName = "Updated Name"
        viewModel.editingBio = "Updated Bio"

        // When
        await viewModel.updateProfile()

        // Then: 編集対象フィールドだけがターゲット更新される
        XCTAssertEqual(mockFirestoreService.updatePublicProfileFieldsCalls.count, 1)
        let call = mockFirestoreService.updatePublicProfileFieldsCalls.first
        XCTAssertEqual(call?.userId, testUser.id)
        XCTAssertEqual(call?.displayName, "Updated Name")
        XCTAssertEqual(call?.bio, "Updated Bio")
        XCTAssertEqual(call?.photoURL, testUser.photoURL)

        // Then: 既存ドキュメントがある場合は新規作成にフォールバックしない
        XCTAssertFalse(mockFirestoreService.createPublicProfileCalled)
    }

    /// publicProfiles ドキュメント未作成（マイグレーション未実施）ユーザーは
    /// notFound を受けて createPublicProfile にフォールバックすること ⭐️
    func testUpdateProfileFallsBackToCreateWhenPublicProfileMissing() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        mockFirestoreService.updatePublicProfileFieldsError = FirestoreServiceError.notFound
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        viewModel.editingDisplayName = "Updated Name"

        // When
        await viewModel.updateProfile()

        // Then
        XCTAssertTrue(mockFirestoreService.createPublicProfileCalled)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// notFound 以外の失敗では新規作成にフォールバックせず、エラーとして見せること ⭐️
    ///
    /// `updatePublicProfileFields` は「更新失敗 → publicProfiles の存在確認 →
    /// 不在なら notFound ／ 存在するなら updateFailed」という構造になっている。
    /// updateFailed は「ドキュメントは在るのに書けなかった」＝ createPublicProfile で
    /// 作り直すと Cloud Functions が保つカウンタを古い値で潰しかねないため、
    /// フォールバック経路に流してはいけない。
    func testUpdateProfileDoesNotFallBackToCreateOnUpdateFailure() async {
        // Given: 更新が updateFailed（存在するが書き込めなかった）で失敗する
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        mockFirestoreService.updatePublicProfileFieldsError = FirestoreServiceError.updateFailed(
            NSError(
                domain: "FIRFirestoreErrorDomain",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "permission denied"]
            )
        )
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        viewModel.editingDisplayName = "Updated Name"

        // When
        await viewModel.updateProfile()

        // Then: 新規作成へのフォールバックは notFound のときだけ
        XCTAssertFalse(
            mockFirestoreService.createPublicProfileCalled,
            "updateFailed で createPublicProfile に流すと、サーバーが保つカウンタを潰しかねない"
        )

        // Then: 失敗を握りつぶさずユーザーに見せる
        XCTAssertNotNil(viewModel.errorMessage)
    }
    
    func testLoadEditTools() async {
        // Given
        let testUser = createTestUser(
            customEditTools: ["exposure", "brightness", "contrast"],
            customEditToolsOrder: ["exposure", "brightness", "contrast"]
        )
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        
        // When
        await viewModel.loadProfile()
        
        // Then
        XCTAssertFalse(viewModel.equippedTools.isEmpty)
        XCTAssertEqual(viewModel.equippedTools.count, 3)
    }
    
    func testUpdateEditTools() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()
        
        // 5個のツールを選択（最小値）
        viewModel.selectedTools = Array(EditTool.allCases.prefix(5))
        
        // When
        await viewModel.updateEditTools()
        
        // Then
        XCTAssertEqual(viewModel.equippedTools.count, 5)
        XCTAssertTrue(mockFirestoreService.updateEditToolsCalled)
    }
    
    func testUpdateEditToolsAllToolsOrder() async {
        // Given - 全ツール表示モードではバリデーションエラーなし
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        // When - 全ツールの順序を保存
        viewModel.selectedTools = EditTool.allCases
        await viewModel.updateEditTools()

        // Then - エラーなし
        XCTAssertNil(viewModel.errorMessage)
    }
    
    func testMoveEditTool() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        viewModel.selectedTools = EditTool.allCases
        let firstTool = viewModel.selectedTools[0]

        // When - 先頭のツールを2番目に移動
        viewModel.moveEditTool(from: IndexSet(integer: 0), to: 2)

        // Then - 先頭のツールが移動している
        XCTAssertEqual(viewModel.selectedTools[1], firstTool)
    }

    func testSelectedToolsContainsAll27Tools() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // Then - 全27ツールが常に選択状態
        XCTAssertEqual(viewModel.selectedTools.count, EditTool.allCases.count)
    }

    func testIsValidEditToolsSelectionAlwaysTrue() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // Then - 全ツール表示のため常にtrue
        XCTAssertTrue(viewModel.isValidEditToolsSelection)
    }

    func testIsValidEditToolsSelection_legacy() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When & Then - 全ツール表示のため常に有効
        XCTAssertTrue(viewModel.isValidEditToolsSelection)
        viewModel.selectedTools = Array(EditTool.allCases.prefix(9))
        XCTAssertTrue(viewModel.isValidEditToolsSelection)
    }
    
    // MARK: - Helper Methods
    
    private func createTestUser(
        customEditTools: [String]? = nil,
        customEditToolsOrder: [String]? = nil
    ) -> User {
        User(
            id: "test-user-id",
            email: "test@example.com",
            displayName: "Test User",
            photoURL: "https://example.com/photo.jpg",
            bio: "Test bio",
            customEditTools: customEditTools,
            customEditToolsOrder: customEditToolsOrder,
            followersCount: 10,
            followingCount: 20,
            postsCount: 5
        )
    }
    
    private func createTestPosts(userId: String) -> [Post] {
        let imageInfo = ImageInfo(
            url: "https://example.com/image.jpg",
            width: 1024,
            height: 768,
            order: 0
        )
        
        return [
            Post(
                id: UUID().uuidString,
                userId: userId,
                images: [imageInfo],
                caption: "Test caption",
                visibility: .public
            ),
            Post(
                id: UUID().uuidString,
                userId: userId,
                images: [imageInfo],
                caption: "Test caption 2",
                visibility: .public
            )
        ]
    }
}

// MARK: - Mock Services

class MockFirestoreServiceForProfile: FirestoreServiceProtocol {
    var user: User?
    var userPosts: [Post] = []
    var updateEditToolsCalled = false
    /// ターゲット更新（updatePublicProfileFields）に渡された引数の記録 ⭐️
    var updatePublicProfileFieldsCalls: [(userId: String, displayName: String?, photoURL: String?, bio: String?)] = []
    /// updatePublicProfileFields が投げるエラー（notFound フォールバック検証用） ⭐️
    var updatePublicProfileFieldsError: Error?
    /// createPublicProfile が呼ばれたか（フォールバック検証用） ⭐️
    var createPublicProfileCalled = false
    
    func fetchUser(userId: String) async throws -> User {
        guard let user = user else {
            throw FirestoreServiceError.notFound
        }
        return user
    }
    
    func updateUser(_ user: User) async throws -> User {
        return user
    }
    
    func updateEditTools(userId: String, tools: [EditTool], order: [String]) async throws {
        updateEditToolsCalled = true
    }
    
    func fetchUserPosts(userId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] {
        return userPosts
    }

    /// fetchUserPostsPage が返すページ（未設定なら userPosts を 1 ページで返す）⭐️
    var userPostPages: [[Post]]?
    /// fetchUserPostsPage が呼ばれた回数
    var fetchUserPostsPageCallCount = 0
    /// recountPostsCount が返す「全投稿数」（nil なら userPosts.count）⭐️
    var recountedPostsCount: Int?
    /// recountPostsCount が呼ばれた回数
    var recountPostsCountCallCount = 0

    func fetchUserPostsPage(userId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        defer { fetchUserPostsPageCallCount += 1 }
        guard let pages = userPostPages else { return (userPosts, nil) }
        let index = fetchUserPostsPageCallCount
        return (index < pages.count ? pages[index] : [], nil)
    }

    func recountPostsCount(userId: String) async throws -> Int {
        recountPostsCountCallCount += 1
        return recountedPostsCount ?? userPosts.count
    }
    
    // その他のメソッドは空実装
    func createPost(_ post: Post) async throws -> Post { return post }
    func fetchPosts(limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] { return [] }
    func fetchPostsWithSnapshot(limit: Int, lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) { return ([], nil) }
    func fetchPost(postId: String) async throws -> Post { throw FirestoreServiceError.notFound }
    func deletePost(postId: String, userId: String) async throws {}
    func saveDraft(_ draft: Draft) async throws -> Draft { return draft }
    func fetchDrafts(userId: String) async throws -> [Draft] { return [] }
    func loadDraft(draftId: String) async throws -> Draft { throw FirestoreServiceError.notFound }
    func deleteDraft(draftId: String) async throws {}
    func searchByHashtag(_ hashtag: String) async throws -> [Post] { return [] }
    func searchByColor(_ color: String, threshold: Double?) async throws -> [Post] { return [] }
    func searchByTimeOfDay(_ timeOfDay: TimeOfDay) async throws -> [Post] { return [] }
    func searchBySkyType(_ skyType: SkyType) async throws -> [Post] { return [] }
    func searchPosts(
        hashtag: String?,
        color: String?,
        timeOfDay: TimeOfDay?,
        skyType: SkyType?,
        colorThreshold: Double?,
        limit: Int
    ) async throws -> [Post] { return [] }
    func fetchPublicProfile(userId: String) async throws -> PublicProfile { throw FirestoreServiceError.notFound }
    func updatePublicProfileFields(userId: String, displayName: String?, photoURL: String?, bio: String?) async throws {
        updatePublicProfileFieldsCalls.append((userId: userId, displayName: displayName, photoURL: photoURL, bio: bio))
        if let error = updatePublicProfileFieldsError {
            throw error
        }
    }
    func createPublicProfile(from user: User) async throws { createPublicProfileCalled = true }
    func deleteUserData(userId: String) async throws {}
    func reportPost(postId: String, reporterId: String, reportedUserId: String, reason: String) async throws {}
    func blockUser(userId: String, blockedUserId: String) async throws {}
    func unblockUser(userId: String, blockedUserId: String) async throws {}
    func fetchBlockedUserIds(userId: String) async throws -> [String] { return [] }
}

class MockStorageServiceForProfile: StorageServiceProtocol {
    var uploadedImage: UIImage?
    
    func uploadImage(_ image: UIImage, path: String) async throws -> URL {
        uploadedImage = image
        return URL(string: "https://example.com/uploaded.jpg")!
    }
    
    func uploadThumbnail(_ image: UIImage, path: String) async throws -> URL {
        return URL(string: "https://example.com/thumbnail.jpg")!
    }
    
    func deleteImage(path: String) async throws {}
    func uploadProgress(path: String) -> AsyncStream<Double> {
        return AsyncStream { continuation in
            continuation.finish()
        }
    }
}



