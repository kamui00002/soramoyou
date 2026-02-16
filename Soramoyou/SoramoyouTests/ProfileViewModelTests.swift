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



