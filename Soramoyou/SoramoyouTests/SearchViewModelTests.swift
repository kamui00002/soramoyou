//
//  SearchViewModelTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore

@MainActor
final class SearchViewModelTests: XCTestCase {
    var viewModel: SearchViewModel!
    var mockFirestoreService: MockFirestoreServiceForSearch!
    
    override func setUp() {
        super.setUp()
        mockFirestoreService = MockFirestoreServiceForSearch()
        viewModel = SearchViewModel(firestoreService: mockFirestoreService)
    }
    
    override func tearDown() {
        viewModel = nil
        mockFirestoreService = nil
        super.tearDown()
    }
    
    func testSearchViewModelInitialization() {
        // Given & When
        let viewModel = SearchViewModel()
        
        // Then
        XCTAssertNotNil(viewModel)
        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.hasSearchCriteria)
    }
    
    func testSearchByHashtag() async {
        // Given
        let testPosts = createTestPosts(hashtags: ["sky", "blue"])
        mockFirestoreService.searchResults = testPosts
        
        // When
        await viewModel.searchByHashtag("sky")
        
        // Then
        XCTAssertFalse(viewModel.searchResults.isEmpty)
        XCTAssertEqual(viewModel.hashtag, "sky")
        XCTAssertNil(viewModel.selectedColor)
        XCTAssertNil(viewModel.selectedTimeOfDay)
        XCTAssertNil(viewModel.selectedSkyType)
        XCTAssertTrue(viewModel.hasSearchCriteria)
    }
    
    func testSearchByColor() async {
        // Given
        let testPosts = createTestPosts(skyColors: ["#0000FF"])
        mockFirestoreService.searchResults = testPosts
        
        // When
        await viewModel.searchByColor("#0000FF", threshold: 0.3)
        
        // Then
        XCTAssertFalse(viewModel.searchResults.isEmpty)
        XCTAssertEqual(viewModel.selectedColor, "#0000FF")
        XCTAssertEqual(viewModel.colorThreshold, 0.3)
        XCTAssertTrue(viewModel.hasSearchCriteria)
    }
    
    func testSearchByTimeOfDay() async {
        // Given
        let testPosts = createTestPosts(timeOfDay: .morning)
        mockFirestoreService.searchResults = testPosts
        
        // When
        await viewModel.searchByTimeOfDay(.morning)
        
        // Then
        XCTAssertFalse(viewModel.searchResults.isEmpty)
        XCTAssertEqual(viewModel.selectedTimeOfDay, .morning)
        XCTAssertTrue(viewModel.hasSearchCriteria)
    }
    
    func testSearchBySkyType() async {
        // Given
        let testPosts = createTestPosts(skyType: .clear)
        mockFirestoreService.searchResults = testPosts
        
        // When
        await viewModel.searchBySkyType(.clear)
        
        // Then
        XCTAssertFalse(viewModel.searchResults.isEmpty)
        XCTAssertEqual(viewModel.selectedSkyType, .clear)
        XCTAssertTrue(viewModel.hasSearchCriteria)
    }
    
    func testPerformSearchWithMultipleCriteria() async {
        // Given
        let testPosts = createTestPosts(hashtags: ["sky"], timeOfDay: .morning, skyType: .clear)
        mockFirestoreService.searchResults = testPosts
        
        // When
        viewModel.hashtag = "sky"
        viewModel.selectedTimeOfDay = .morning
        viewModel.selectedSkyType = .clear
        await viewModel.performSearch()
        
        // Then
        XCTAssertFalse(viewModel.searchResults.isEmpty)
        XCTAssertTrue(viewModel.hasSearchCriteria)
    }
    
    func testClearSearch() {
        // Given
        viewModel.hashtag = "sky"
        viewModel.selectedColor = "#0000FF"
        viewModel.selectedTimeOfDay = .morning
        viewModel.selectedSkyType = .clear
        viewModel.searchResults = createTestPosts()
        
        // When
        viewModel.clearSearch()
        
        // Then
        XCTAssertTrue(viewModel.hashtag.isEmpty)
        XCTAssertNil(viewModel.selectedColor)
        XCTAssertNil(viewModel.selectedTimeOfDay)
        XCTAssertNil(viewModel.selectedSkyType)
        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertFalse(viewModel.hasSearchCriteria)
    }
    
    // MARK: - Helper Methods
    
    private func createTestPosts(
        hashtags: [String]? = nil,
        skyColors: [String]? = nil,
        timeOfDay: TimeOfDay? = nil,
        skyType: SkyType? = nil
    ) -> [Post] {
        let imageInfo = ImageInfo(
            url: "https://example.com/image.jpg",
            width: 1024,
            height: 768,
            order: 0
        )
        
        let post = Post(
            id: UUID().uuidString,
            userId: "test-user-id",
            images: [imageInfo],
            caption: "Test caption",
            hashtags: hashtags,
            skyColors: skyColors,
            timeOfDay: timeOfDay,
            skyType: skyType,
            visibility: .public
        )
        
        return [post]
    }
}

// MARK: - Mock FirestoreService for Search

class MockFirestoreServiceForSearch: FirestoreServiceProtocol {
    var searchResults: [Post] = []
    
    func searchPosts(
        hashtag: String?,
        color: String?,
        timeOfDay: TimeOfDay?,
        skyType: SkyType?,
        colorThreshold: Double?,
        limit: Int
    ) async throws -> [Post] {
        return searchResults
    }
    
    // その他のメソッドは空実装
    func createPost(_ post: Post) async throws -> Post { return post }
    func fetchPosts(limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] { return [] }
    func fetchPostsWithSnapshot(limit: Int, lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) { return ([], nil) }
    func fetchPost(postId: String) async throws -> Post { throw FirestoreServiceError.notFound }
    func deletePost(postId: String, userId: String) async throws {}
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
}



