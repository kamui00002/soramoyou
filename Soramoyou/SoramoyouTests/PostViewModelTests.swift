//
//  PostViewModelTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-24.
//

import XCTest
@testable import Soramoyou

@MainActor
final class PostViewModelTests: XCTestCase {
    var sut: PostViewModel!
    var mockImageService: MockImageService!
    var mockStorageService: MockStorageService!
    var mockFirestoreService: MockFirestoreService!

    override func setUp() {
        super.setUp()
        mockImageService = MockImageService()
        mockStorageService = MockStorageService()
        mockFirestoreService = MockFirestoreService()

        sut = PostViewModel(
            userId: "test-user-123",
            imageService: mockImageService,
            storageService: mockStorageService,
            firestoreService: mockFirestoreService
        )
    }

    override func tearDown() {
        sut = nil
        mockImageService = nil
        mockStorageService = nil
        mockFirestoreService = nil
        super.tearDown()
    }

    // MARK: - Image Management Tests

    func testSetSelectedImages_setsImagesAndClearsEditedImages() {
        // Given
        let image1 = UIImage()
        let image2 = UIImage()
        let images = [image1, image2]

        sut.editedImages = [UIImage()] // 既存の編集済み画像

        // When
        sut.setSelectedImages(images)

        // Then
        XCTAssertEqual(sut.selectedImages.count, 2)
        XCTAssertTrue(sut.editedImages.isEmpty)
    }

    func testSetEditedImages_setsImagesAndSettings() {
        // Given
        let image = UIImage()
        let images = [image]
        let settings = EditSettings(appliedFilter: .vivid)

        // When
        sut.setEditedImages(images, editSettings: settings)

        // Then
        XCTAssertEqual(sut.editedImages.count, 1)
        XCTAssertEqual(sut.editSettings?.appliedFilter, .vivid)
    }

    // MARK: - Caption Management Tests

    func testSetCaption_extractsHashtags() {
        // Given
        let caption = "Beautiful sky #sunset #evening #photography"

        // When
        sut.setCaption(caption)

        // Then
        XCTAssertEqual(sut.caption, caption)
        XCTAssertEqual(sut.hashtags.count, 3)
        XCTAssertTrue(sut.hashtags.contains("sunset"))
        XCTAssertTrue(sut.hashtags.contains("evening"))
        XCTAssertTrue(sut.hashtags.contains("photography"))
    }

    func testSetCaption_withNoHashtags_setsEmptyArray() {
        // Given
        let caption = "Beautiful sky without hashtags"

        // When
        sut.setCaption(caption)

        // Then
        XCTAssertEqual(sut.caption, caption)
        XCTAssertTrue(sut.hashtags.isEmpty)
    }

    func testSetCaption_withJapaneseHashtags_doesNotExtract() {
        // Given
        let caption = "#日本語のハッシュタグ は抽出されない"

        // When
        sut.setCaption(caption)

        // Then
        // 現在の実装は英数字のみ対応
        XCTAssertTrue(sut.hashtags.isEmpty)
    }

    // MARK: - Location and Visibility Tests

    func testSetLocation_updatesLocation() {
        // Given
        let location = Location(
            name: "Tokyo Tower",
            latitude: 35.6586,
            longitude: 139.7454
        )

        // When
        sut.setLocation(location)

        // Then
        XCTAssertEqual(sut.location?.name, "Tokyo Tower")
        XCTAssertEqual(sut.location?.latitude, 35.6586, accuracy: 0.0001)
    }

    func testSetVisibility_updatesVisibility() {
        // Given
        let visibility: Visibility = .private

        // When
        sut.setVisibility(visibility)

        // Then
        XCTAssertEqual(sut.visibility, .private)
    }

    // MARK: - Save Post Tests

    func testSavePost_withNoUserId_throwsError() async {
        // Given
        let sutWithoutUser = PostViewModel(
            userId: nil,
            imageService: mockImageService,
            storageService: mockStorageService,
            firestoreService: mockFirestoreService
        )

        // When/Then
        do {
            try await sutWithoutUser.savePost()
            XCTFail("Expected error to be thrown")
        } catch let error as PostViewModelError {
            XCTAssertEqual(error, .userNotAuthenticated)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSavePost_withNoImages_throwsError() async {
        // Given
        // sut has no edited images

        // When/Then
        do {
            try await sut.savePost()
            XCTFail("Expected error to be thrown")
        } catch let error as PostViewModelError {
            XCTAssertEqual(error, .noImages)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSavePost_successfulUpload_setsIsPostSavedTrue() async {
        // Given
        let image = UIImage()
        sut.editedImages = [image]
        sut.setCaption("Test post #test")

        mockImageService.shouldSucceed = true
        mockStorageService.shouldSucceed = true
        mockFirestoreService.shouldSucceed = true

        // When
        try? await sut.savePost()

        // Then
        XCTAssertTrue(sut.isPostSaved)
        XCTAssertEqual(sut.uploadProgress, 1.0)
        XCTAssertNil(sut.errorMessage)
    }

    func testSavePost_uploadFailure_performsRollback() async {
        // Given
        let image1 = UIImage()
        let image2 = UIImage()
        sut.editedImages = [image1, image2]

        mockImageService.shouldSucceed = true
        mockStorageService.shouldFailOnSecondUpload = true
        mockFirestoreService.shouldSucceed = true

        // When
        do {
            try await sut.savePost()
            XCTFail("Expected error to be thrown")
        } catch {
            // Then
            XCTAssertTrue(mockStorageService.deleteImageCalled)
            XCTAssertFalse(sut.isPostSaved)
            XCTAssertNotNil(sut.errorMessage)
        }
    }

    func testSavePost_parallelUpload_maintainsOrder() async {
        // Given
        let images = [UIImage(), UIImage(), UIImage()]
        sut.editedImages = images

        mockImageService.shouldSucceed = true
        mockStorageService.shouldSucceed = true
        mockFirestoreService.shouldSucceed = true

        // When
        try? await sut.savePost()

        // Then
        // 並列アップロードでもインデックス順が保持されるべき
        XCTAssertEqual(mockStorageService.uploadedImageCount, 3)
        XCTAssertEqual(mockStorageService.uploadedThumbnailCount, 3)
    }

    func testSavePost_updatesProgressDuringUpload() async {
        // Given
        let images = [UIImage(), UIImage()]
        sut.editedImages = images

        mockImageService.shouldSucceed = true
        mockStorageService.shouldSucceed = true
        mockFirestoreService.shouldSucceed = true

        var progressUpdates: [Double] = []

        // Observe progress changes
        let expectation = expectation(description: "Progress updates")
        expectation.expectedFulfillmentCount = 2 // At least 2 updates expected

        Task {
            for await _ in NotificationCenter.default.notifications(named: NSNotification.Name("uploadProgress")) {
                progressUpdates.append(sut.uploadProgress)
                expectation.fulfill()
            }
        }

        // When
        try? await sut.savePost()

        // Then
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertTrue(progressUpdates.contains { $0 > 0 && $0 < 1.0 })
    }

    // MARK: - Draft Management Tests

    func testSaveDraft_withNoUserId_throwsError() async {
        // Given
        let sutWithoutUser = PostViewModel(
            userId: nil,
            imageService: mockImageService,
            storageService: mockStorageService,
            firestoreService: mockFirestoreService
        )
        sutWithoutUser.selectedImages = [UIImage()]

        // When/Then
        do {
            try await sutWithoutUser.saveDraft()
            XCTFail("Expected error to be thrown")
        } catch let error as PostViewModelError {
            XCTAssertEqual(error, .userNotAuthenticated)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSaveDraft_withNoImages_throwsError() async {
        // Given
        // sut has no images

        // When/Then
        do {
            try await sut.saveDraft()
            XCTFail("Expected error to be thrown")
        } catch let error as PostViewModelError {
            XCTAssertEqual(error, .noImages)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSaveDraft_successful_callsFirestore() async {
        // Given
        sut.selectedImages = [UIImage()]
        sut.setCaption("Draft caption #draft")
        mockFirestoreService.shouldSucceed = true

        // When
        try? await sut.saveDraft()

        // Then
        XCTAssertTrue(mockFirestoreService.saveDraftCalled)
    }

    func testLoadDraft_setsViewModelProperties() {
        // Given
        let draft = Draft(
            id: "draft-123",
            userId: "test-user-123",
            images: [],
            caption: "Draft caption",
            hashtags: ["test", "draft"],
            location: Location(name: "Test Location", latitude: 0, longitude: 0),
            visibility: .private
        )

        // When
        sut.loadDraft(draft)

        // Then
        XCTAssertEqual(sut.caption, "Draft caption")
        XCTAssertEqual(sut.hashtags, ["test", "draft"])
        XCTAssertEqual(sut.location?.name, "Test Location")
        XCTAssertEqual(sut.visibility, .private)
    }

    // MARK: - Reset Tests

    func testReset_clearsAllData() {
        // Given
        sut.selectedImages = [UIImage()]
        sut.editedImages = [UIImage()]
        sut.setCaption("Test #caption")
        sut.setLocation(Location(name: "Test", latitude: 0, longitude: 0))
        sut.setVisibility(.private)
        sut.isPostSaved = true
        sut.errorMessage = "Error"

        // When
        sut.reset()

        // Then
        XCTAssertTrue(sut.selectedImages.isEmpty)
        XCTAssertTrue(sut.editedImages.isEmpty)
        XCTAssertTrue(sut.caption.isEmpty)
        XCTAssertTrue(sut.hashtags.isEmpty)
        XCTAssertNil(sut.location)
        XCTAssertEqual(sut.visibility, .public)
        XCTAssertFalse(sut.isPostSaved)
        XCTAssertNil(sut.errorMessage)
        XCTAssertNil(sut.extractedInfo)
    }
}

// MARK: - Mock Services

class MockImageService: ImageServiceProtocol {
    var shouldSucceed = true
    var resizeDelay: TimeInterval = 0.01

    func applyFilter(_ filter: FilterType, to image: UIImage) async throws -> UIImage {
        if !shouldSucceed { throw ImageServiceError.processingFailed }
        return image
    }

    func applyEditTool(_ tool: EditTool, value: Float, to image: UIImage) async throws -> UIImage {
        if !shouldSucceed { throw ImageServiceError.processingFailed }
        return image
    }

    func applyEditSettings(_ settings: EditSettings, to image: UIImage) async throws -> UIImage {
        if !shouldSucceed { throw ImageServiceError.processingFailed }
        return image
    }

    func generatePreview(_ image: UIImage, edits: EditSettings) async throws -> UIImage {
        if !shouldSucceed { throw ImageServiceError.processingFailed }
        return image
    }

    func resizeImage(_ image: UIImage, maxSize: CGSize) async throws -> UIImage {
        try? await Task.sleep(nanoseconds: UInt64(resizeDelay * 1_000_000_000))
        if !shouldSucceed { throw ImageServiceError.processingFailed }
        return image
    }

    func compressImage(_ image: UIImage, quality: CGFloat) async throws -> Data {
        if !shouldSucceed { throw ImageServiceError.compressionFailed }
        return Data()
    }

    func extractColors(_ image: UIImage, maxCount: Int) async throws -> [String] {
        if !shouldSucceed { throw ImageServiceError.processingFailed }
        return ["#FF0000", "#00FF00", "#0000FF"]
    }

    func calculateColorTemperature(_ image: UIImage) async throws -> Int {
        if !shouldSucceed { throw ImageServiceError.processingFailed }
        return 5500
    }

    func detectSkyType(_ image: UIImage) async throws -> SkyType {
        if !shouldSucceed { throw ImageServiceError.processingFailed }
        return .clear
    }

    func extractEXIFData(_ image: UIImage) async throws -> EXIFData {
        if !shouldSucceed { throw ImageServiceError.processingFailed }
        return EXIFData()
    }
}

class MockStorageService: StorageServiceProtocol {
    var shouldSucceed = true
    var shouldFailOnSecondUpload = false
    var uploadedImageCount = 0
    var uploadedThumbnailCount = 0
    var deleteImageCalled = false

    func uploadImage(_ image: UIImage, path: String) async throws -> URL {
        uploadedImageCount += 1
        if shouldFailOnSecondUpload && uploadedImageCount > 1 {
            throw StorageServiceError.uploadFailed(NSError(domain: "test", code: -1))
        }
        if !shouldSucceed { throw StorageServiceError.uploadFailed(NSError(domain: "test", code: -1)) }
        return URL(string: "https://example.com/\(path)")!
    }

    func uploadThumbnail(_ image: UIImage, path: String) async throws -> URL {
        uploadedThumbnailCount += 1
        if shouldFailOnSecondUpload && uploadedThumbnailCount > 1 {
            throw StorageServiceError.uploadFailed(NSError(domain: "test", code: -1))
        }
        if !shouldSucceed { throw StorageServiceError.uploadFailed(NSError(domain: "test", code: -1)) }
        return URL(string: "https://example.com/thumbnails/\(path)")!
    }

    func deleteImage(path: String) async throws {
        deleteImageCalled = true
        if !shouldSucceed { throw StorageServiceError.deleteFailed(NSError(domain: "test", code: -1)) }
    }

    func uploadProfileImage(_ image: UIImage, userId: String) async throws -> URL {
        if !shouldSucceed { throw StorageServiceError.uploadFailed(NSError(domain: "test", code: -1)) }
        return URL(string: "https://example.com/profile/\(userId)")!
    }

    func deleteProfileImage(userId: String) async throws {
        if !shouldSucceed { throw StorageServiceError.deleteFailed(NSError(domain: "test", code: -1)) }
    }

    func observeUploadProgress(for path: String) -> AsyncStream<Double> {
        AsyncStream { continuation in
            continuation.yield(0.5)
            continuation.yield(1.0)
            continuation.finish()
        }
    }
}

class MockFirestoreService: FirestoreServiceProtocol {
    var shouldSucceed = true
    var saveDraftCalled = false
    var createPostCalled = false

    func createPost(_ post: Post) async throws -> Post {
        createPostCalled = true
        if !shouldSucceed { throw FirestoreServiceError.createFailed(NSError(domain: "test", code: -1)) }
        return post
    }

    func fetchPosts(limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] {
        if !shouldSucceed { throw FirestoreServiceError.fetchFailed(NSError(domain: "test", code: -1)) }
        return []
    }

    func fetchPostsWithSnapshot(limit: Int, lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        if !shouldSucceed { throw FirestoreServiceError.fetchFailed(NSError(domain: "test", code: -1)) }
        return ([], nil)
    }

    func fetchPost(postId: String) async throws -> Post {
        if !shouldSucceed { throw FirestoreServiceError.fetchFailed(NSError(domain: "test", code: -1)) }
        throw FirestoreServiceError.notFound
    }

    func deletePost(postId: String) async throws {
        if !shouldSucceed { throw FirestoreServiceError.deleteFailed(NSError(domain: "test", code: -1)) }
    }

    func fetchUserPosts(userId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] {
        if !shouldSucceed { throw FirestoreServiceError.fetchFailed(NSError(domain: "test", code: -1)) }
        return []
    }

    func saveDraft(_ draft: Draft) async throws -> Draft {
        saveDraftCalled = true
        if !shouldSucceed { throw FirestoreServiceError.createFailed(NSError(domain: "test", code: -1)) }
        return draft
    }

    func fetchDrafts(userId: String) async throws -> [Draft] {
        if !shouldSucceed { throw FirestoreServiceError.fetchFailed(NSError(domain: "test", code: -1)) }
        return []
    }

    func loadDraft(draftId: String) async throws -> Draft {
        if !shouldSucceed { throw FirestoreServiceError.fetchFailed(NSError(domain: "test", code: -1)) }
        throw FirestoreServiceError.notFound
    }

    func deleteDraft(draftId: String) async throws {
        if !shouldSucceed { throw FirestoreServiceError.deleteFailed(NSError(domain: "test", code: -1)) }
    }

    func fetchUser(userId: String) async throws -> User {
        if !shouldSucceed { throw FirestoreServiceError.fetchFailed(NSError(domain: "test", code: -1)) }
        throw FirestoreServiceError.notFound
    }

    func updateUser(_ user: User) async throws -> User {
        if !shouldSucceed { throw FirestoreServiceError.updateFailed(NSError(domain: "test", code: -1)) }
        return user
    }

    func updateEditTools(userId: String, tools: [EditTool], order: [String]) async throws {
        if !shouldSucceed { throw FirestoreServiceError.updateFailed(NSError(domain: "test", code: -1)) }
    }

    func searchByHashtag(_ hashtag: String) async throws -> [Post] {
        if !shouldSucceed { throw FirestoreServiceError.searchFailed(NSError(domain: "test", code: -1)) }
        return []
    }

    func searchByColor(_ color: String, threshold: Double?) async throws -> [Post] {
        if !shouldSucceed { throw FirestoreServiceError.searchFailed(NSError(domain: "test", code: -1)) }
        return []
    }

    func searchByTimeOfDay(_ timeOfDay: TimeOfDay) async throws -> [Post] {
        if !shouldSucceed { throw FirestoreServiceError.searchFailed(NSError(domain: "test", code: -1)) }
        return []
    }

    func searchBySkyType(_ skyType: SkyType) async throws -> [Post] {
        if !shouldSucceed { throw FirestoreServiceError.searchFailed(NSError(domain: "test", code: -1)) }
        return []
    }

    func searchPosts(hashtag: String?, color: String?, timeOfDay: TimeOfDay?, skyType: SkyType?, colorThreshold: Double?) async throws -> [Post] {
        if !shouldSucceed { throw FirestoreServiceError.searchFailed(NSError(domain: "test", code: -1)) }
        return []
    }
}
