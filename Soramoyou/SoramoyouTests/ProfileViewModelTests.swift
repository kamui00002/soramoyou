//
//  ProfileViewModelTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//

import XCTest
@testable import Soramoyou
import FirebaseAuth

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
    func deletePost(postId: String) async throws {}
    func saveDraft(_ draft: Draft) async throws -> Draft { return draft }
    func fetchDrafts(userId: String) async throws -> [Draft] { return [] }
    func loadDraft(draftId: String) async throws -> Draft { throw FirestoreServiceError.notFound }
    func deleteDraft(draftId: String) async throws {}
    func searchByHashtag(_ hashtag: String) async throws -> [Post] { return [] }
    func searchByColor(_ color: String, threshold: Double?) async throws -> [Post] { return [] }
    func searchByTimeOfDay(_ timeOfDay: TimeOfDay) async throws -> [Post] { return [] }
    func searchBySkyType(_ skyType: SkyType) async throws -> [Post] { return [] }
    func searchPosts(hashtag: String?, color: String?, timeOfDay: TimeOfDay?, skyType: SkyType?, colorThreshold: Double?) async throws -> [Post] { return [] }
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


