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
    
    func testUpdateEditToolsValidation() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()
        
        // 4個のツールを選択（最小値未満）
        viewModel.selectedTools = Array(EditTool.allCases.prefix(4))
        
        // When
        await viewModel.updateEditTools()
        
        // Then
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.errorMessage?.contains("5個から8個まで") ?? false)
    }
    
    func testAddEditTool() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        viewModel.selectedTools = Array(EditTool.allCases.prefix(5))
        
        // When
        viewModel.addEditTool(.saturation)
        
        // Then
        XCTAssertEqual(viewModel.selectedTools.count, 6)
        XCTAssertTrue(viewModel.selectedTools.contains(.saturation))
    }
    
    func testRemoveEditTool() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        viewModel.selectedTools = Array(EditTool.allCases.prefix(6))
        
        // When
        viewModel.removeEditTool(.exposure)
        
        // Then
        XCTAssertEqual(viewModel.selectedTools.count, 5)
        XCTAssertFalse(viewModel.selectedTools.contains(.exposure))
    }
    
    func testRemoveEditToolMinimumConstraint() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        viewModel.selectedTools = Array(EditTool.allCases.prefix(5)) // 最小値
        
        // When
        viewModel.removeEditTool(.exposure)
        
        // Then
        // 最小値なので削除されない
        XCTAssertEqual(viewModel.selectedTools.count, 5)
    }
    
    func testIsValidEditToolsSelection() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When & Then - 5個（有効）
        viewModel.selectedTools = Array(EditTool.allCases.prefix(5))
        XCTAssertTrue(viewModel.isValidEditToolsSelection)

        // When & Then - 8個（有効）
        viewModel.selectedTools = Array(EditTool.allCases.prefix(8))
        XCTAssertTrue(viewModel.isValidEditToolsSelection)

        // When & Then - 4個（無効）
        viewModel.selectedTools = Array(EditTool.allCases.prefix(4))
        XCTAssertFalse(viewModel.isValidEditToolsSelection)

        // When & Then - 9個（無効）
        viewModel.selectedTools = Array(EditTool.allCases.prefix(9))
        XCTAssertFalse(viewModel.isValidEditToolsSelection)
    }

    // MARK: - Error Handling Tests

    /// エラーハンドリング: プロフィール読み込み時のネットワークエラー
    func testLoadProfileWithNetworkError() async {
        // Given
        mockFirestoreService.shouldThrowError = true
        mockFirestoreService.errorToThrow = FirestoreServiceError.networkError
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When
        await viewModel.loadProfile()

        // Then
        XCTAssertNil(viewModel.user, "エラー時はユーザー情報がnilであるべき")
        XCTAssertNotNil(viewModel.errorMessage, "エラーメッセージが設定されるべき")
        XCTAssertFalse(viewModel.isLoading, "ローディング状態が解除されるべき")
    }

    /// エラーハンドリング: ユーザーが存在しない場合
    func testLoadProfileWithUserNotFound() async {
        // Given
        mockFirestoreService.shouldThrowError = true
        mockFirestoreService.errorToThrow = FirestoreServiceError.notFound
        viewModel = ProfileViewModel(
            userId: "non-existent-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When
        await viewModel.loadProfile()

        // Then
        XCTAssertNil(viewModel.user)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    /// エラーハンドリング: 投稿読み込み時のエラー
    func testLoadUserPostsWithError() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        mockFirestoreService.shouldThrowPostsError = true
        mockFirestoreService.errorToThrow = FirestoreServiceError.networkError
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When
        await viewModel.loadUserPosts()

        // Then
        XCTAssertTrue(viewModel.userPosts.isEmpty, "エラー時は投稿が空であるべき")
        XCTAssertNotNil(viewModel.errorMessage, "エラーメッセージが設定されるべき")
        XCTAssertFalse(viewModel.isLoadingPosts, "ローディング状態が解除されるべき")
    }

    /// エラーハンドリング: プロフィール更新時のエラー
    func testUpdateProfileWithError() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        mockFirestoreService.shouldThrowUpdateError = true
        mockFirestoreService.errorToThrow = FirestoreServiceError.permissionDenied
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
        XCTAssertNotNil(viewModel.errorMessage, "エラーメッセージが設定されるべき")
        XCTAssertFalse(viewModel.isLoading)
    }

    /// エラーハンドリング: 画像アップロード時のエラー
    func testUpdateProfileWithImageUploadError() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        mockStorageService.shouldThrowError = true
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        let testImage = UIImage(systemName: "photo")!
        viewModel.editingProfileImage = testImage

        // When
        await viewModel.updateProfile()

        // Then
        XCTAssertNotNil(viewModel.errorMessage, "エラーメッセージが設定されるべき")
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - Concurrent Execution Tests

    /// 並行処理: プロフィールと投稿の同時読み込み
    func testConcurrentLoadProfileAndPosts() async {
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

        // When: 同時に実行
        async let profileTask = viewModel.loadProfile()
        async let postsTask = viewModel.loadUserPosts()

        await profileTask
        await postsTask

        // Then: クラッシュせず、両方のデータが読み込まれる
        XCTAssertNotNil(viewModel.user)
        XCTAssertFalse(viewModel.userPosts.isEmpty)
        XCTAssertEqual(viewModel.userPosts.count, testPosts.count)
    }

    /// 並行処理: 連続したプロフィール更新
    func testConsecutiveProfileUpdates() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        // When: 連続して更新
        viewModel.editingDisplayName = "First Update"
        await viewModel.updateProfile()

        viewModel.editingDisplayName = "Second Update"
        await viewModel.updateProfile()

        // Then: クラッシュせず、最後の更新が反映される
        XCTAssertEqual(viewModel.user?.displayName, "Second Update")
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - Edge Case Tests

    /// エッジケース: userIdがnilの場合
    func testLoadProfileWithNilUserId() async {
        // Given
        viewModel = ProfileViewModel(
            userId: nil,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When
        await viewModel.loadProfile()

        // Then
        XCTAssertNil(viewModel.user)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.errorMessage?.contains("ユーザーID") ?? false)
    }

    /// エッジケース: 空のdisplayNameとbio
    func testUpdateProfileWithEmptyFields() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        viewModel.editingDisplayName = ""
        viewModel.editingBio = ""

        // When
        await viewModel.updateProfile()

        // Then
        XCTAssertNil(viewModel.user?.displayName, "空の文字列はnilとして保存されるべき")
        XCTAssertNil(viewModel.user?.bio, "空の文字列はnilとして保存されるべき")
    }

    /// エッジケース: カスタム編集ツールがnilの場合
    func testLoadProfileWithNilCustomEditTools() async {
        // Given
        let testUser = createTestUser(
            customEditTools: nil,
            customEditToolsOrder: nil
        )
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When
        await viewModel.loadProfile()

        // Then: デフォルトの5個のツールが設定される
        XCTAssertEqual(viewModel.equippedTools.count, 5)
        XCTAssertEqual(viewModel.selectedTools.count, 5)
    }

    /// エッジケース: 投稿が空の場合
    func testLoadUserPostsWhenEmpty() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        mockFirestoreService.userPosts = [] // 空の投稿リスト
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When
        await viewModel.loadUserPosts()

        // Then
        XCTAssertTrue(viewModel.userPosts.isEmpty)
        XCTAssertNil(viewModel.errorMessage, "投稿が空でもエラーではない")
        XCTAssertFalse(viewModel.isLoadingPosts)
    }

    /// エッジケース: 他ユーザーのプロフィールでprivate投稿がフィルタリングされる
    func testLoadUserPostsFiltersPrivatePostsForOtherUsers() async {
        // Given
        let otherUserId = "other-user-id"
        let publicPost = Post(
            id: UUID().uuidString,
            userId: otherUserId,
            images: [ImageInfo(url: "https://example.com/1.jpg", width: 100, height: 100, order: 0)],
            caption: "Public",
            visibility: .public
        )
        let privatePost = Post(
            id: UUID().uuidString,
            userId: otherUserId,
            images: [ImageInfo(url: "https://example.com/2.jpg", width: 100, height: 100, order: 0)],
            caption: "Private",
            visibility: .private
        )

        mockFirestoreService.userPosts = [publicPost, privatePost]
        viewModel = ProfileViewModel(
            userId: otherUserId,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When
        await viewModel.loadUserPosts()

        // Then: public投稿のみ表示される
        XCTAssertEqual(viewModel.userPosts.count, 1)
        XCTAssertEqual(viewModel.userPosts.first?.visibility, .public)
    }

    // MARK: - Validation Tests

    /// バリデーション: 長すぎるdisplayName
    func testIsValidProfileEditWithLongDisplayName() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When: 51文字のdisplayName
        viewModel.editingDisplayName = String(repeating: "a", count: 51)

        // Then
        XCTAssertFalse(viewModel.isValidProfileEdit, "50文字を超えるdisplayNameは無効")
    }

    /// バリデーション: 長すぎるbio
    func testIsValidProfileEditWithLongBio() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When: 201文字のbio
        viewModel.editingBio = String(repeating: "a", count: 201)

        // Then
        XCTAssertFalse(viewModel.isValidProfileEdit, "200文字を超えるbioは無効")
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

    // エラーシミュレーション用
    var shouldThrowError = false
    var shouldThrowPostsError = false
    var shouldThrowUpdateError = false
    var errorToThrow: Error = FirestoreServiceError.networkError

    func fetchUser(userId: String) async throws -> User {
        if shouldThrowError {
            throw errorToThrow
        }
        guard let user = user else {
            throw FirestoreServiceError.notFound
        }
        return user
    }

    func updateUser(_ user: User) async throws -> User {
        if shouldThrowUpdateError {
            throw errorToThrow
        }
        // 更新されたユーザー情報を保存
        self.user = user
        return user
    }

    func updateEditTools(userId: String, tools: [EditTool], order: [String]) async throws {
        if shouldThrowUpdateError {
            throw errorToThrow
        }
        updateEditToolsCalled = true
    }

    func fetchUserPosts(userId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] {
        if shouldThrowPostsError {
            throw errorToThrow
        }
        return userPosts
    }
    
    // その他のメソッドは空実装
    func createPost(_ post: Post) async throws -> Post { return post }
    func fetchPosts(limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] { return [] }
    func fetchPostsWithSnapshot(limit: Int, lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) { return ([], nil) }
    func fetchPost(postId: String) async throws -> Post { throw FirestoreServiceError.notFound }
    func deletePost(postId: String) async throws {}
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
}

class MockStorageServiceForProfile: StorageServiceProtocol {
    var uploadedImage: UIImage?

    // エラーシミュレーション用
    var shouldThrowError = false

    func uploadImage(_ image: UIImage, path: String) async throws -> URL {
        if shouldThrowError {
            throw StorageServiceError.uploadFailed
        }
        uploadedImage = image
        return URL(string: "https://example.com/uploaded.jpg")!
    }

    func uploadThumbnail(_ image: UIImage, path: String) async throws -> URL {
        if shouldThrowError {
            throw StorageServiceError.uploadFailed
        }
        return URL(string: "https://example.com/thumbnail.jpg")!
    }

    func deleteImage(path: String) async throws {
        if shouldThrowError {
            throw StorageServiceError.deleteFailed
        }
    }

    func uploadProgress(path: String) -> AsyncStream<Double> {
        return AsyncStream { continuation in
            continuation.finish()
        }
    }
}



