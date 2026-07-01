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

    // MARK: - 絞り込みテスト（時間帯・空の種類）

    func testFilterByTimeOfDay() async {
        // Given: 時間帯が混在した投稿
        mockFirestoreService.posts = [
            createTestPost(id: "morning-1", timeOfDay: .morning),
            createTestPost(id: "night-1", timeOfDay: .night),
            createTestPost(id: "morning-2", timeOfDay: .morning)
        ]

        // When: 朝で絞り込む
        await viewModel.selectTimeOfDay(.morning)

        // Then: 朝の投稿だけが返り、フィルタ状態が反映される
        XCTAssertEqual(viewModel.posts.count, 2)
        XCTAssertTrue(viewModel.posts.allSatisfy { $0.timeOfDay == .morning })
        XCTAssertEqual(viewModel.selectedTimeOfDay, .morning)
        XCTAssertTrue(viewModel.hasActiveFilter)
        XCTAssertEqual(mockFirestoreService.lastTimeOfDayFilter, .morning)
    }

    func testFilterBySkyType() async {
        // Given
        mockFirestoreService.posts = [
            createTestPost(id: "clear-1", skyType: .clear),
            createTestPost(id: "storm-1", skyType: .storm)
        ]

        // When
        await viewModel.selectSkyType(.clear)

        // Then
        XCTAssertEqual(viewModel.posts.count, 1)
        XCTAssertEqual(viewModel.posts.first?.skyType, .clear)
        XCTAssertEqual(mockFirestoreService.lastSkyTypeFilter, .clear)
    }

    func testSelectingSameTimeOfDayClearsFilter() async {
        // Given
        mockFirestoreService.posts = [createTestPost(id: "morning-1", timeOfDay: .morning)]
        await viewModel.selectTimeOfDay(.morning)
        XCTAssertTrue(viewModel.hasActiveFilter)

        // When: 同じ値を再選択
        mockFirestoreService.posts = createTestPosts(count: 3)
        await viewModel.selectTimeOfDay(.morning)

        // Then: フィルタ解除
        XCTAssertNil(viewModel.selectedTimeOfDay)
        XCTAssertFalse(viewModel.hasActiveFilter)
    }

    // MARK: - 並び替えテスト（新着・人気）

    func testSortByPopularUsesLikesCountField() async {
        // Given
        mockFirestoreService.posts = createTestPosts(count: 3)

        // When: 人気順に切替
        await viewModel.setSortOrder(.popular)

        // Then: likesCount フィールドでクエリされる
        XCTAssertEqual(mockFirestoreService.lastSortField, "likesCount")
        XCTAssertEqual(viewModel.effectiveSortOrder.sortField, "likesCount")
    }

    func testPopularSortForcedToNewestWhenFilterActive() async {
        // Given: 絞り込み中
        mockFirestoreService.posts = [createTestPost(id: "morning-1", timeOfDay: .morning)]
        await viewModel.selectTimeOfDay(.morning)

        // When: 人気順を要求
        await viewModel.setSortOrder(.popular)

        // Then: 新着に固定される（人気順インデックス爆発の回避）
        XCTAssertEqual(viewModel.effectiveSortOrder.sortField, "createdAt")
        XCTAssertEqual(mockFirestoreService.lastSortField, "createdAt")
    }

    // MARK: - 色で探すテスト

    func testColorModeUsesSearchByColorAndDisablesPaging() async {
        // Given: 色検索の結果を用意（pageSize=30 と同数でもページング無効になること）
        mockFirestoreService.colorSearchResults = createTestPosts(count: 30)

        // When
        await viewModel.selectColor("#0000FF")

        // Then: searchByColor が使われ、ページングは無効
        XCTAssertEqual(mockFirestoreService.lastSearchedColor, "#0000FF")
        XCTAssertEqual(viewModel.posts.count, 30)
        XCTAssertTrue(viewModel.isColorMode)
        XCTAssertFalse(viewModel.hasMorePosts)
    }

    func testColorModeLoadMoreDoesNotDuplicate() async {
        // Given: 色モードで取得済み
        mockFirestoreService.colorSearchResults = createTestPosts(count: 30)
        await viewModel.selectColor("#FF0000")
        XCTAssertEqual(viewModel.posts.count, 30)

        // When: 追加読み込みを試みる
        await viewModel.loadMorePosts()

        // Then: 重複せず件数は変わらない
        XCTAssertEqual(viewModel.posts.count, 30)
    }

    // MARK: - シャッフルテスト

    func testShuffleKeepsSameCount() async {
        // Given
        mockFirestoreService.posts = createTestPosts(count: 20)
        await viewModel.fetchPosts()

        // When
        await viewModel.toggleShuffle()

        // Then: 件数は変わらず、状態がONになる
        XCTAssertTrue(viewModel.isShuffled)
        XCTAssertEqual(viewModel.posts.count, 20)
    }

    func testShuffleOffRestoresOrder() async {
        // Given: シャッフルON
        mockFirestoreService.posts = createTestPosts(count: 10)
        await viewModel.fetchPosts()
        await viewModel.toggleShuffle()
        XCTAssertTrue(viewModel.isShuffled)

        // When: OFF（再取得で元順に戻る）
        await viewModel.toggleShuffle()

        // Then
        XCTAssertFalse(viewModel.isShuffled)
        XCTAssertEqual(viewModel.posts.count, 10)
        XCTAssertEqual(viewModel.posts.map { $0.id }, (0..<10).map { "test-post-\($0)" })
    }

    // MARK: - レイアウト切替テスト

    func testToggleLayoutMode() {
        // Given: 既定はグリッド
        XCTAssertEqual(viewModel.layoutMode, .grid)

        // When & Then
        viewModel.toggleLayoutMode()
        XCTAssertEqual(viewModel.layoutMode, .mosaic)
        viewModel.toggleLayoutMode()
        XCTAssertEqual(viewModel.layoutMode, .grid)
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
        originalImages: [ImageInfo]? = nil,
        timeOfDay: TimeOfDay? = nil,
        skyType: SkyType? = nil,
        skyColors: [String]? = nil,
        likesCount: Int = 0
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
            hashtags: nil,
            skyColors: skyColors,
            timeOfDay: timeOfDay,
            skyType: skyType,
            visibility: .public,
            likesCount: likesCount
        )
    }
}

// MARK: - Mock FirestoreService for Gallery

class MockFirestoreServiceForGallery: FirestoreServiceProtocol {
    var posts: [Post] = []
    var singlePost: Post?
    var shouldThrowError = false

    // 探索ヘッダー検証用の記録
    var lastSortField: String?
    var lastTimeOfDayFilter: TimeOfDay?
    var lastSkyTypeFilter: SkyType?
    var lastSearchedColor: String?
    /// 色で探す（searchByColor）の返却結果
    var colorSearchResults: [Post] = []

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

    func fetchPostsWithSnapshot(
        timeOfDay: TimeOfDay?,
        skyType: SkyType?,
        sortField: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        if shouldThrowError {
            throw FirestoreServiceError.notFound
        }
        // クエリ条件を記録（テストの検証用）
        lastSortField = sortField
        lastTimeOfDayFilter = timeOfDay
        lastSkyTypeFilter = skyType

        // 絞り込みを模倣
        var result = posts
        if let timeOfDay = timeOfDay {
            result = result.filter { $0.timeOfDay == timeOfDay }
        }
        if let skyType = skyType {
            result = result.filter { $0.skyType == skyType }
        }
        // 人気順を模倣
        if sortField == "likesCount" {
            result = result.sorted { $0.likesCount > $1.likesCount }
        }

        return (posts: Array(result.prefix(limit)), lastDocument: nil)
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
    func deletePost(postId: String, userId: String) async throws {}
    func fetchUserPosts(userId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] { return [] }
    func saveDraft(_ draft: Draft) async throws -> Draft { return draft }
    func fetchDrafts(userId: String) async throws -> [Draft] { return [] }
    func loadDraft(draftId: String) async throws -> Draft { throw FirestoreServiceError.notFound }
    func deleteDraft(draftId: String) async throws {}
    func fetchUser(userId: String) async throws -> User { return User(id: userId, email: "test@example.com") }
    func updateUser(_ user: User) async throws -> User { return user }
    func updateEditTools(userId: String, tools: [EditTool], order: [String]) async throws {}
    func syncPostsCount(userId: String, count: Int) async throws {}
    func fetchPublicProfile(userId: String) async throws -> PublicProfile { throw FirestoreServiceError.notFound }
    func updatePublicProfile(_ profile: PublicProfile) async throws {}
    func createPublicProfile(from user: User) async throws {}
    func deleteUserData(userId: String) async throws {}
    func reportPost(postId: String, reporterId: String, reportedUserId: String, reason: String) async throws {}
    func blockUser(userId: String, blockedUserId: String) async throws {}
    func unblockUser(userId: String, blockedUserId: String) async throws {}
    func fetchBlockedUserIds(userId: String) async throws -> [String] { return [] }
    func searchByHashtag(_ hashtag: String) async throws -> [Post] { return [] }
    func searchByColor(_ color: String, threshold: Double?) async throws -> [Post] {
        if shouldThrowError {
            throw FirestoreServiceError.notFound
        }
        lastSearchedColor = color
        return colorSearchResults
    }
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
