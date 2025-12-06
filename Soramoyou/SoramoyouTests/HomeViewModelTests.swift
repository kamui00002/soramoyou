//
//  HomeViewModelTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore

final class HomeViewModelTests: XCTestCase {
    var viewModel: HomeViewModel!
    var mockFirestoreService: MockFirestoreServiceForHome!
    
    override func setUp() {
        super.setUp()
        mockFirestoreService = MockFirestoreServiceForHome()
        viewModel = HomeViewModel(firestoreService: mockFirestoreService)
    }
    
    override func tearDown() {
        viewModel = nil
        mockFirestoreService = nil
        super.tearDown()
    }
    
    func testHomeViewModelInitialization() {
        // Given & When
        let viewModel = HomeViewModel()
        
        // Then
        XCTAssertNotNil(viewModel)
        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isLoadingMore)
        XCTAssertTrue(viewModel.hasMorePosts)
    }
    
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
    
    func testLoadMorePosts() async {
        // Given
        let initialPosts = createTestPosts(count: 20)
        let morePosts = createTestPosts(count: 10, startId: 20)
        mockFirestoreService.posts = initialPosts
        
        await viewModel.fetchPosts()
        
        // When
        mockFirestoreService.posts = morePosts
        await viewModel.loadMorePosts()
        
        // Then
        XCTAssertEqual(viewModel.posts.count, 30)
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
        XCTAssertEqual(viewModel.posts.count, 5) // 追加されていない
    }
    
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
    
    func testFetchPost() async throws {
        // Given
        let testPost = createTestPost(id: "test-post-1")
        mockFirestoreService.singlePost = testPost
        
        // When
        let fetchedPost = try await viewModel.fetchPost(postId: "test-post-1")
        
        // Then
        XCTAssertNotNil(fetchedPost)
        XCTAssertEqual(fetchedPost.id, "test-post-1")
    }
    
    // MARK: - Helper Methods
    
    private func createTestPosts(count: Int, startId: Int = 0) -> [Post] {
        return (0..<count).map { index in
            createTestPost(id: "test-post-\(startId + index)")
        }
    }
    
    private func createTestPost(id: String) -> Post {
        let imageInfo = ImageInfo(
            url: "https://example.com/image.jpg",
            width: 1024,
            height: 768,
            order: 0
        )
        
        return Post(
            id: id,
            userId: "test-user-id",
            images: [imageInfo],
            caption: "Test caption",
            visibility: .public
        )
    }
}

// MARK: - Mock FirestoreService for HomeViewModel

class MockFirestoreServiceForHome: FirestoreServiceProtocol {
    var posts: [Post] = []
    var singlePost: Post?
    
    func fetchPosts(limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] {
        return Array(posts.prefix(limit))
    }
    
    func fetchPostsWithSnapshot(limit: Int, lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        // 簡易実装: 実際のDocumentSnapshotは作成しない
        let postsToReturn = Array(posts.prefix(limit))
        return (posts: postsToReturn, lastDocument: nil)
    }
    
    func fetchPost(postId: String) async throws -> Post {
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
    func searchPosts(hashtag: String?, color: String?, timeOfDay: TimeOfDay?, skyType: SkyType?, colorThreshold: Double?) async throws -> [Post] { return [] }
}

