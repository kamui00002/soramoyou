//
//  GalleryViewModelTests.swift
//  SoramoyouTests
//
//  Created on 2025-01-19.
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore

@MainActor
final class GalleryViewModelTests: XCTestCase {
    var viewModel: GalleryViewModel!
    var mockFirestoreService: MockFirestoreServiceForGallery!

    override func setUp() {
        super.setUp()
        mockFirestoreService = MockFirestoreServiceForGallery()
        viewModel = GalleryViewModel(firestoreService: mockFirestoreService)
    }

    override func tearDown() {
        viewModel = nil
        mockFirestoreService = nil
        super.tearDown()
    }

    // MARK: - 初期化テスト

    func testGalleryViewModelInitialization() {
        // Given & When
        let viewModel = GalleryViewModel(firestoreService: mockFirestoreService)

        // Then
        XCTAssertNotNil(viewModel)
        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isLoadingMore)
        XCTAssertTrue(viewModel.hasMorePosts)
    }

    // MARK: - 投稿取得テスト

    func testFetchPosts() async {
        // Given
        let testPosts = createTestPosts(count: 5)
        mockFirestoreService.posts = testPosts

        // When
        await viewModel.fetchPosts()

        // Then
        XCTAssertFalse(viewModel.posts.isEmpty)
        XCTAssertEqual(viewModel.posts.count, 5)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testFetchPostsWithEditSettings() async {
        // Given: 編集設定を持つ投稿を作成
        let editSettings = EditSettings(brightness: 0.2, contrast: 0.1, saturation: -0.1, appliedFilter: .warm)
        let testPost = createTestPost(id: "post-with-edit", editSettings: editSettings)
        mockFirestoreService.posts = [testPost]

        // When
        await viewModel.fetchPosts()

        // Then
        XCTAssertEqual(viewModel.posts.count, 1)
        XCTAssertNotNil(viewModel.posts.first?.editSettings)
        XCTAssertEqual(viewModel.posts.first?.editSettings?.appliedFilter, .warm)
    }

    func testFetchPostsWithOriginalImages() async {
        // Given: オリジナル画像を持つ投稿を作成
        let originalImageInfo = ImageInfo(url: "https://example.com/original.jpg", width: 1024, height: 768, order: 0)
        let testPost = createTestPost(id: "post-with-original", originalImages: [originalImageInfo])
        mockFirestoreService.posts = [testPost]

        // When
        await viewModel.fetchPosts()

        // Then
        XCTAssertEqual(viewModel.posts.count, 1)
        XCTAssertNotNil(viewModel.posts.first?.originalImages)
        XCTAssertEqual(viewModel.posts.first?.originalImages?.count, 1)
    }

    // MARK: - ページネーションテスト

    func testLoadMorePosts() async {
        // Given
        let initialPosts = createTestPosts(count: 30)
        let morePosts = createTestPosts(count: 10, startId: 30)
        mockFirestoreService.posts = initialPosts

        await viewModel.fetchPosts()

        // When
        mockFirestoreService.posts = morePosts
        await viewModel.loadMorePosts()

        // Then
        XCTAssertEqual(viewModel.posts.count, 40)
        XCTAssertFalse(viewModel.isLoadingMore)
    }

    func testLoadMorePostsWhenNoMorePosts() async {
        // Given
        let initialPosts = createTestPosts(count: 5)
        mockFirestoreService.posts = initialPosts

        await viewModel.fetchPosts()

        // When
        mockFirestoreService.posts = []
        await viewModel.loadMorePosts()

        // Then
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertEqual(viewModel.posts.count, 5)
    }

    // MARK: - リフレッシュテスト

    func testRefresh() async {
        // Given
        let initialPosts = createTestPosts(count: 10)
        mockFirestoreService.posts = initialPosts

        await viewModel.fetchPosts()
        XCTAssertEqual(viewModel.posts.count, 10)

        // When
        let refreshedPosts = createTestPosts(count: 15)
        mockFirestoreService.posts = refreshedPosts
        await viewModel.refresh()

        // Then
        XCTAssertEqual(viewModel.posts.count, 15)
    }

    // MARK: - エラーハンドリングテスト

    func testFetchPostsError() async {
        // Given
        mockFirestoreService.shouldThrowError = true

        // When
        await viewModel.fetchPosts()

        // Then
        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    // MARK: - Helper Methods

    private func createTestPosts(count: Int, startId: Int = 0) -> [Post] {
        return (0..<count).map { index in
            createTestPost(id: "test-post-\(startId + index)")
        }
    }

    private func createTestPost(
        id: String,
        editSettings: EditSettings? = nil,
        originalImages: [ImageInfo]? = nil
    ) -> Post {
        let imageInfo = ImageInfo(
            url: "https://example.com/image.jpg",
            thumbnail: "https://example.com/thumbnail.jpg",
            width: 1024,
            height: 768,
            order: 0
        )

        return Post(
            id: id,
            userId: "test-user-id",
            images: [imageInfo],
            originalImages: originalImages,
            editSettings: editSettings,
            caption: "Test caption",
            visibility: .public
        )
    }
}

// MARK: - Mock FirestoreService for Gallery

class MockFirestoreServiceForGallery: FirestoreServiceProtocol {
    var posts: [Post] = []
    var singlePost: Post?
    var shouldThrowError = false

    func fetchPosts(limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] {
        if shouldThrowError {
            throw FirestoreServiceError.notFound
        }
        return Array(posts.prefix(limit))
    }

    func fetchPostsWithSnapshot(limit: Int, lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        if shouldThrowError {
            throw FirestoreServiceError.notFound
        }
        let postsToReturn = Array(posts.prefix(limit))
        return (posts: postsToReturn, lastDocument: nil)
    }

    func fetchPost(postId: String) async throws -> Post {
        if shouldThrowError {
            throw FirestoreServiceError.notFound
        }
        if let post = singlePost, post.id == postId {
            return post
        }
        throw FirestoreServiceError.notFound
    }

    // その他のメソッドは空実装
    func createPost(_ post: Post) async throws -> Post { return post }
    func deletePost(postId: String) async throws {}
    func fetchUserPosts(userId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] { return [] }
    func saveDraft(_ draft: Draft) async throws -> Draft { return draft }
    func fetchDrafts(userId: String) async throws -> [Draft] { return [] }
    func loadDraft(draftId: String) async throws -> Draft { throw FirestoreServiceError.notFound }
    func deleteDraft(draftId: String) async throws {}
    func fetchUser(userId: String) async throws -> User { return User(id: userId, email: "test@example.com") }
    func updateUser(_ user: User) async throws -> User { return user }
    func updateEditTools(userId: String, tools: [EditTool], order: [String]) async throws {}
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
