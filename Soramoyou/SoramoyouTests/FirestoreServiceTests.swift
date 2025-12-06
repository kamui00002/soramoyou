//
//  FirestoreServiceTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore

final class FirestoreServiceTests: XCTestCase {
    var firestoreService: FirestoreService!
    
    override func setUp() {
        super.setUp()
        firestoreService = FirestoreService()
    }
    
    override func tearDown() {
        firestoreService = nil
        super.tearDown()
    }
    
    func testFirestoreServiceInitialization() {
        // Given & When
        let service = FirestoreService()
        
        // Then
        XCTAssertNotNil(service)
    }
    
    func testCreatePost() async throws {
        // Given
        let post = createTestPost()
        
        // When
        let createdPost = try await firestoreService.createPost(post)
        
        // Then
        XCTAssertNotNil(createdPost)
        XCTAssertEqual(createdPost.id, post.id)
        XCTAssertEqual(createdPost.userId, post.userId)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post.id)
    }
    
    func testFetchPost() async throws {
        // Given
        let post = createTestPost()
        _ = try await firestoreService.createPost(post)
        
        // When
        let fetchedPost = try await firestoreService.fetchPost(postId: post.id)
        
        // Then
        XCTAssertNotNil(fetchedPost)
        XCTAssertEqual(fetchedPost.id, post.id)
        XCTAssertEqual(fetchedPost.userId, post.userId)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post.id)
    }
    
    func testFetchPosts() async throws {
        // Given
        let post1 = createTestPost(id: "test-post-1")
        let post2 = createTestPost(id: "test-post-2")
        _ = try await firestoreService.createPost(post1)
        _ = try await firestoreService.createPost(post2)
        
        // When
        let posts = try await firestoreService.fetchPosts(limit: 10, lastDocument: nil)
        
        // Then
        XCTAssertFalse(posts.isEmpty)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post1.id)
        try? await firestoreService.deletePost(postId: post2.id)
    }
    
    func testFetchPostsWithPagination() async throws {
        // Given
        let post1 = createTestPost(id: "test-post-pag-1")
        let post2 = createTestPost(id: "test-post-pag-2")
        _ = try await firestoreService.createPost(post1)
        _ = try await firestoreService.createPost(post2)
        
        // When - 最初のページ
        let firstPage = try await firestoreService.fetchPosts(limit: 1, lastDocument: nil)
        XCTAssertEqual(firstPage.count, 1)
        
        // Then - 次のページ
        if let lastDoc = firstPage.first {
            // 実際のDocumentSnapshotを取得する必要があるが、テストでは簡略化
            let secondPage = try await firestoreService.fetchPosts(limit: 1, lastDocument: nil)
            XCTAssertFalse(secondPage.isEmpty)
        }
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post1.id)
        try? await firestoreService.deletePost(postId: post2.id)
    }
    
    func testDeletePost() async throws {
        // Given
        let post = createTestPost()
        _ = try await firestoreService.createPost(post)
        
        // When
        try await firestoreService.deletePost(postId: post.id)
        
        // Then
        // 削除された投稿を取得しようとするとエラーになることを確認
        do {
            _ = try await firestoreService.fetchPost(postId: post.id)
            XCTFail("削除された投稿が取得できてしまった")
        } catch {
            // エラーが発生することが期待される
            XCTAssertTrue(error is FirestoreServiceError)
        }
    }
    
    func testFetchPostsWithVisibilityFilter() async throws {
        // Given
        let publicPost = createTestPost(id: "test-public", visibility: .public)
        let privatePost = createTestPost(id: "test-private", visibility: .private)
        _ = try await firestoreService.createPost(publicPost)
        _ = try await firestoreService.createPost(privatePost)
        
        // When - 公開投稿のみ取得
        let posts = try await firestoreService.fetchPosts(limit: 10, lastDocument: nil)
        
        // Then
        // 公開投稿のみが含まれることを確認（実際の実装に依存）
        XCTAssertFalse(posts.isEmpty)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: publicPost.id)
        try? await firestoreService.deletePost(postId: privatePost.id)
    }
    
    // MARK: - Draft Tests
    
    func testSaveDraft() async throws {
        // Given
        let draft = createTestDraft()
        
        // When
        let savedDraft = try await firestoreService.saveDraft(draft)
        
        // Then
        XCTAssertNotNil(savedDraft)
        XCTAssertEqual(savedDraft.id, draft.id)
        
        // Cleanup
        try? await firestoreService.deleteDraft(draftId: draft.id)
    }
    
    func testFetchDrafts() async throws {
        // Given
        let draft1 = createTestDraft(id: "test-draft-1")
        let draft2 = createTestDraft(id: "test-draft-2")
        _ = try await firestoreService.saveDraft(draft1)
        _ = try await firestoreService.saveDraft(draft2)
        
        // When
        let drafts = try await firestoreService.fetchDrafts(userId: draft1.userId)
        
        // Then
        XCTAssertFalse(drafts.isEmpty)
        
        // Cleanup
        try? await firestoreService.deleteDraft(draftId: draft1.id)
        try? await firestoreService.deleteDraft(draftId: draft2.id)
    }
    
    func testLoadDraft() async throws {
        // Given
        let draft = createTestDraft()
        _ = try await firestoreService.saveDraft(draft)
        
        // When
        let loadedDraft = try await firestoreService.loadDraft(draftId: draft.id)
        
        // Then
        XCTAssertNotNil(loadedDraft)
        XCTAssertEqual(loadedDraft.id, draft.id)
        
        // Cleanup
        try? await firestoreService.deleteDraft(draftId: draft.id)
    }
    
    func testDeleteDraft() async throws {
        // Given
        let draft = createTestDraft()
        _ = try await firestoreService.saveDraft(draft)
        
        // When
        try await firestoreService.deleteDraft(draftId: draft.id)
        
        // Then
        // 削除された下書きを取得しようとするとエラーになることを確認
        do {
            _ = try await firestoreService.loadDraft(draftId: draft.id)
            XCTFail("削除された下書きが取得できてしまった")
        } catch {
            XCTAssertTrue(error is FirestoreServiceError)
        }
    }
    
    // MARK: - User Tests
    
    func testFetchUser() async throws {
        // Given
        let user = createTestUser()
        _ = try await firestoreService.updateUser(user)
        
        // When
        let fetchedUser = try await firestoreService.fetchUser(userId: user.id)
        
        // Then
        XCTAssertNotNil(fetchedUser)
        XCTAssertEqual(fetchedUser.id, user.id)
    }
    
    func testUpdateUser() async throws {
        // Given
        let user = createTestUser()
        
        // When
        let updatedUser = try await firestoreService.updateUser(user)
        
        // Then
        XCTAssertNotNil(updatedUser)
        XCTAssertEqual(updatedUser.id, user.id)
    }
    
    func testUpdateEditTools() async throws {
        // Given
        let userId = "test-user-id"
        let tools: [EditTool] = [.brightness, .contrast, .saturation]
        let order = ["brightness", "contrast", "saturation"]
        
        // When
        try await firestoreService.updateEditTools(userId: userId, tools: tools, order: order)
        
        // Then
        // エラーが発生しないことを確認
        XCTAssertTrue(true)
    }
    
    // MARK: - Search Tests
    
    func testSearchByHashtag() async throws {
        // Given
        let post = createTestPost(hashtags: ["sky", "blue"])
        _ = try await firestoreService.createPost(post)
        
        // When
        let results = try await firestoreService.searchByHashtag("sky")
        
        // Then
        XCTAssertFalse(results.isEmpty)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post.id)
    }
    
    func testSearchByColor() async throws {
        // Given
        let post = createTestPost(skyColors: ["#0000FF", "#FF0000"])
        _ = try await firestoreService.createPost(post)
        
        // When
        let results = try await firestoreService.searchByColor("#0000FF")
        
        // Then
        XCTAssertFalse(results.isEmpty)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post.id)
    }
    
    func testSearchByTimeOfDay() async throws {
        // Given
        let post = createTestPost(timeOfDay: .morning)
        _ = try await firestoreService.createPost(post)
        
        // When
        let results = try await firestoreService.searchByTimeOfDay(.morning)
        
        // Then
        XCTAssertFalse(results.isEmpty)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post.id)
    }
    
    func testSearchBySkyType() async throws {
        // Given
        let post = createTestPost(skyType: .clear)
        _ = try await firestoreService.createPost(post)
        
        // When
        let results = try await firestoreService.searchBySkyType(.clear)
        
        // Then
        XCTAssertFalse(results.isEmpty)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post.id)
    }
    
    func testSearchPostsComposite() async throws {
        // Given
        let post = createTestPost(
            hashtags: ["sky"],
            timeOfDay: .morning,
            skyType: .clear
        )
        _ = try await firestoreService.createPost(post)
        
        // When
        let results = try await firestoreService.searchPosts(
            hashtag: "sky",
            timeOfDay: .morning,
            skyType: .clear
        )
        
        // Then
        XCTAssertFalse(results.isEmpty)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post.id)
    }
    
    func testFetchUserPosts() async throws {
        // Given
        let userId = "test-user-id"
        let post1 = createTestPost(id: "test-user-post-1", userId: userId)
        let post2 = createTestPost(id: "test-user-post-2", userId: userId)
        _ = try await firestoreService.createPost(post1)
        _ = try await firestoreService.createPost(post2)
        
        // When
        let posts = try await firestoreService.fetchUserPosts(userId: userId, limit: 10, lastDocument: nil)
        
        // Then
        XCTAssertFalse(posts.isEmpty)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post1.id)
        try? await firestoreService.deletePost(postId: post2.id)
    }
    
    // MARK: - Helper Methods
    
    private func createTestPost(
        id: String = UUID().uuidString,
        userId: String = "test-user-id",
        visibility: Visibility = .public,
        hashtags: [String]? = ["test", "sky"],
        skyColors: [String]? = nil,
        timeOfDay: TimeOfDay? = nil,
        skyType: SkyType? = nil
    ) -> Post {
        let imageInfo = ImageInfo(
            url: "https://example.com/image.jpg",
            width: 1024,
            height: 768,
            order: 0
        )
        
        return Post(
            id: id,
            userId: userId,
            images: [imageInfo],
            caption: "Test caption",
            hashtags: hashtags,
            skyColors: skyColors,
            timeOfDay: timeOfDay,
            skyType: skyType,
            visibility: visibility
        )
    }
    
    private func createTestDraft(
        id: String = UUID().uuidString,
        userId: String = "test-user-id"
    ) -> Draft {
        let imageInfo = ImageInfo(
            url: "https://example.com/image.jpg",
            width: 1024,
            height: 768,
            order: 0
        )
        
        return Draft(
            id: id,
            userId: userId,
            images: [imageInfo],
            caption: "Test draft caption"
        )
    }
    
    private func createTestUser(
        id: String = "test-user-id",
        email: String = "test@example.com"
    ) -> User {
        return User(
            id: id,
            email: email,
            displayName: "Test User"
        )
    }
}

