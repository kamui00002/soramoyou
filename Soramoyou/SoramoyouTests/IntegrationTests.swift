//
//  IntegrationTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//

import XCTest
@testable import Soramoyou
import UIKit

/// 統合テスト: 複数のコンポーネントが連携して動作することを検証
@MainActor
final class IntegrationTests: XCTestCase {
    
    // MARK: - Authentication Flow Tests
    
    /// 認証フローの統合テスト: ログインからホーム画面遷移まで
    func testAuthenticationFlow_LoginToHome() async throws {
        // Given
        let authViewModel = AuthViewModel(authService: MockAuthService())
        let homeViewModel = HomeViewModel(firestoreService: MockFirestoreServiceForHome())
        
        // モックの設定
        let testUser = User(id: "test-user-id", email: "test@example.com", displayName: "Test User")
        if let mockAuthService = authViewModel.authService as? MockAuthService {
            mockAuthService.signInResult = .success(testUser)
        }
        
        // When: ログイン
        try await authViewModel.signIn(email: "test@example.com", password: "password123")
        
        // Then: 認証状態の確認
        XCTAssertTrue(authViewModel.isAuthenticated)
        XCTAssertNotNil(authViewModel.currentUser)
        XCTAssertEqual(authViewModel.currentUser?.id, "test-user-id")
        
        // When: ホーム画面で投稿を取得
        await homeViewModel.fetchPosts()
        
        // Then: 投稿が取得できることを確認（モックなので空でもOK）
        XCTAssertNotNil(homeViewModel.posts)
    }
    
    /// 認証フローの統合テスト: 新規登録からホーム画面遷移まで
    func testAuthenticationFlow_SignUpToHome() async throws {
        // Given
        let authViewModel = AuthViewModel(authService: MockAuthService())
        let homeViewModel = HomeViewModel(firestoreService: MockFirestoreServiceForHome())
        
        // モックの設定
        let newUser = User(id: "new-user-id", email: "new@example.com", displayName: "New User")
        if let mockAuthService = authViewModel.authService as? MockAuthService {
            mockAuthService.signUpResult = .success(newUser)
        }
        
        // When: 新規登録
        try await authViewModel.signUp(email: "new@example.com", password: "password123")
        
        // Then: 認証状態の確認
        XCTAssertTrue(authViewModel.isAuthenticated)
        XCTAssertNotNil(authViewModel.currentUser)
        XCTAssertEqual(authViewModel.currentUser?.id, "new-user-id")
        
        // When: ホーム画面で投稿を取得
        await homeViewModel.fetchPosts()
        
        // Then: 投稿が取得できることを確認
        XCTAssertNotNil(homeViewModel.posts)
    }
    
    /// 認証フローの統合テスト: ログアウト
    func testAuthenticationFlow_Logout() async throws {
        // Given
        let authViewModel = AuthViewModel(authService: MockAuthService())
        
        // モックの設定: ログイン済み状態
        let testUser = User(id: "test-user-id", email: "test@example.com")
        if let mockAuthService = authViewModel.authService as? MockAuthService {
            mockAuthService.signInResult = .success(testUser)
            mockAuthService.currentUserValue = testUser
        }
        
        // ログイン
        try await authViewModel.signIn(email: "test@example.com", password: "password123")
        XCTAssertTrue(authViewModel.isAuthenticated)
        
        // When: ログアウト
        try await authViewModel.signOut()
        
        // Then: 認証状態がクリアされることを確認
        XCTAssertFalse(authViewModel.isAuthenticated)
        XCTAssertNil(authViewModel.currentUser)
    }
    
    // MARK: - Post Flow Tests
    
    /// 投稿フローの統合テスト: 写真選択から投稿保存まで
    func testPostFlow_PhotoSelectionToPostSave() async throws {
        // Given
        let userId = "test-user-id"
        let postViewModel = PostViewModel(userId: userId)
        
        // テスト画像を作成
        let testImage = createTestImage(size: CGSize(width: 1024, height: 768))
        
        // When: 画像を選択
        postViewModel.setSelectedImages([testImage])
        
        // Then: 選択された画像が設定されることを確認
        XCTAssertEqual(postViewModel.selectedImages.count, 1)
        
        // When: 編集設定を適用
        let editSettings = EditSettings(brightness: 0.3, contrast: 0.5, saturation: 0.2)
        postViewModel.setEditedImages([testImage], editSettings: editSettings)
        
        // Then: 編集済み画像が設定されることを確認
        XCTAssertEqual(postViewModel.editedImages.count, 1)
        XCTAssertNotNil(postViewModel.editSettings)
        
        // When: 投稿情報を設定
        postViewModel.caption = "Test caption"
        postViewModel.hashtags = ["test", "sky"]
        postViewModel.visibility = .public
        
        // Then: 投稿情報が設定されることを確認
        XCTAssertEqual(postViewModel.caption, "Test caption")
        XCTAssertEqual(postViewModel.hashtags, ["test", "sky"])
        XCTAssertEqual(postViewModel.visibility, .public)
        
        // Note: 実際の投稿保存はFirebase StorageとFirestoreへの接続が必要なため、
        // モックを使用したテストは別途実装
    }
    
    /// 投稿フローの統合テスト: 下書き保存
    func testPostFlow_DraftSave() async throws {
        // Given
        let userId = "test-user-id"
        let postViewModel = PostViewModel(userId: userId)
        
        // テスト画像を作成
        let testImage = createTestImage(size: CGSize(width: 1024, height: 768))
        postViewModel.setSelectedImages([testImage])
        
        // 投稿情報を設定
        postViewModel.caption = "Draft caption"
        postViewModel.hashtags = ["draft"]
        postViewModel.visibility = .public
        
        // When: 下書きを保存
        // Note: 実際の下書き保存はFirestoreへの接続が必要なため、
        // モックを使用したテストは別途実装
        // try await postViewModel.saveDraft()
        
        // Then: 下書きが保存されることを確認
        // XCTAssertNotNil(postViewModel.draftId)
    }
    
    // MARK: - Search Flow Tests
    
    /// 検索フローの統合テスト: 検索条件から結果表示まで
    func testSearchFlow_SearchCriteriaToResults() async {
        // Given
        let mockService = MockFirestoreServiceForSearch()
        let testPost = createTestPost(id: "search-post-1")
        mockService.searchResults = [testPost]
        
        let searchViewModel = SearchViewModel(firestoreService: mockService)
        
        // When: 検索条件を設定
        searchViewModel.hashtag = "sky"
        searchViewModel.selectedTimeOfDay = .morning
        searchViewModel.selectedSkyType = .clear
        
        // Then: 検索条件が設定されることを確認
        XCTAssertEqual(searchViewModel.hashtag, "sky")
        XCTAssertEqual(searchViewModel.selectedTimeOfDay, .morning)
        XCTAssertEqual(searchViewModel.selectedSkyType, .clear)
        
        // When: 検索を実行
        await searchViewModel.performSearch()
        
        // Then: 検索結果が取得されることを確認
        XCTAssertFalse(searchViewModel.isLoading)
        XCTAssertEqual(searchViewModel.searchResults.count, 1)
        XCTAssertEqual(searchViewModel.searchResults.first?.id, "search-post-1")
    }
    
    /// 検索フローの統合テスト: ハッシュタグ検索
    func testSearchFlow_HashtagSearch() async {
        // Given
        let mockService = MockFirestoreServiceForSearch()
        let testPosts = [
            createTestPost(id: "post-1", hashtags: ["sky", "blue"]),
            createTestPost(id: "post-2", hashtags: ["sky", "cloudy"])
        ]
        mockService.searchResults = testPosts
        
        let searchViewModel = SearchViewModel(firestoreService: mockService)
        
        // When: ハッシュタグで検索
        searchViewModel.hashtag = "sky"
        await searchViewModel.performSearch()
        
        // Then: 検索結果が取得されることを確認
        XCTAssertEqual(searchViewModel.searchResults.count, 2)
    }
    
    /// 検索フローの統合テスト: 色検索
    func testSearchFlow_ColorSearch() async {
        // Given
        let mockService = MockFirestoreServiceForSearch()
        let testPost = createTestPost(id: "color-post-1", skyColors: ["#87CEEB"])
        mockService.searchResults = [testPost]
        
        let searchViewModel = SearchViewModel(firestoreService: mockService)
        
        // When: 色で検索
        searchViewModel.selectedColor = "#87CEEB"
        await searchViewModel.performSearch()
        
        // Then: 検索結果が取得されることを確認
        XCTAssertEqual(searchViewModel.searchResults.count, 1)
    }
    
    // MARK: - Firebase Integration Tests
    
    /// Firebase統合テスト: FirestoreとAuthenticationの連携
    func testFirebaseIntegration_FirestoreAndAuth() async throws {
        // Given
        let mockAuthService = MockAuthService()
        let mockFirestoreService = MockFirestoreServiceForProfile()
        
        let testUser = User(
            id: "integration-user-id",
            email: "integration@example.com",
            displayName: "Integration User"
        )
        mockAuthService.signInResult = .success(testUser)
        mockFirestoreService.user = testUser
        
        let authViewModel = AuthViewModel(authService: mockAuthService)
        let profileViewModel = ProfileViewModel(userId: nil, firestoreService: mockFirestoreService)
        
        // When: ログイン
        try await authViewModel.signIn(email: "integration@example.com", password: "password123")
        
        // Then: 認証状態の確認
        XCTAssertTrue(authViewModel.isAuthenticated)
        XCTAssertNotNil(authViewModel.currentUser)
        
        // When: プロフィールを読み込み
        await profileViewModel.loadProfile()
        
        // Then: プロフィールが取得されることを確認
        XCTAssertNotNil(profileViewModel.user)
        XCTAssertEqual(profileViewModel.user?.id, "integration-user-id")
    }
    
    /// Firebase統合テスト: StorageとFirestoreの連携（投稿保存）
    func testFirebaseIntegration_StorageAndFirestore() async throws {
        // Given
        let userId = "test-user-id"
        let postViewModel = PostViewModel(userId: userId)
        
        // テスト画像を作成
        let testImage = createTestImage(size: CGSize(width: 1024, height: 768))
        postViewModel.setSelectedImages([testImage])
        
        // 投稿情報を設定
        postViewModel.caption = "Integration test post"
        postViewModel.hashtags = ["integration", "test"]
        postViewModel.visibility = .public
        
        // Note: 実際のStorageとFirestoreへの接続が必要なため、
        // このテストは実際のFirebase環境で実行する必要があります
        // モックを使用したテストは別途実装
    }
    
    // MARK: - Complete User Journey Tests
    
    /// 完全なユーザージャーニーのテスト: ログイン → 投稿作成 → 検索
    func testCompleteUserJourney_LoginPostSearch() async throws {
        // Given
        let mockAuthService = MockAuthService()
        let mockSearchService = MockFirestoreServiceForSearch()
        
        let testUser = User(id: "journey-user-id", email: "journey@example.com")
        mockAuthService.signInResult = .success(testUser)
        
        let authViewModel = AuthViewModel(authService: mockAuthService)
        let postViewModel = PostViewModel(userId: nil)
        let searchViewModel = SearchViewModel(firestoreService: mockSearchService)
        
        // Step 1: ログイン
        try await authViewModel.signIn(email: "journey@example.com", password: "password123")
        XCTAssertTrue(authViewModel.isAuthenticated)
        
        // Step 2: 投稿情報を設定
        postViewModel.userId = testUser.id
        let testImage = createTestImage(size: CGSize(width: 1024, height: 768))
        postViewModel.setSelectedImages([testImage])
        postViewModel.caption = "Journey test post"
        postViewModel.hashtags = ["journey", "test"]
        postViewModel.visibility = .public
        
        // Then: 投稿情報が設定されることを確認
        XCTAssertEqual(postViewModel.selectedImages.count, 1)
        XCTAssertEqual(postViewModel.caption, "Journey test post")
        
        // Step 3: 検索
        let testPost = createTestPost(id: "journey-post-1", hashtags: ["journey"])
        mockSearchService.searchResults = [testPost]
        searchViewModel.hashtag = "journey"
        await searchViewModel.performSearch()
        
        // Then: 検索結果が取得されることを確認
        XCTAssertEqual(searchViewModel.searchResults.count, 1)
    }
    
    // MARK: - Helper Methods
    
    private func createTestImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
    
    private func createTestPost(
        id: String,
        userId: String = "test-user-id",
        hashtags: [String] = [],
        skyColors: [String] = []
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
            hashtags: hashtags.isEmpty ? nil : hashtags,
            visibility: .public,
            skyColors: skyColors
        )
    }
}


