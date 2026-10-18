//
//  FirestoreServiceTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//
//
//  🔧 2026-09-16 修正: 本物の Firestore（本番プロジェクト）へ通信するテストを明示オプトインにする。
//
//  背景:
//    - このファイルの async テストは本物の Firestore へ投稿・下書き・ユーザーを書き込みに行く統合テスト。
//      GoogleService-Info.plist が置かれた環境では、全件実行のたびに本番へ通信していた
//      （PR #110 で直した StorageServiceTests と同じ構造）。
//
//  方針:
//    - 実通信するテストは環境変数 SORAMOYOU_FIRESTORE_INTEGRATION_TESTS=1 での明示オプトインにする
//      （既定はスキップ。全件実行・CI・XcodeBuildMCP の test_sim では走らない）。
//    - Firestore を触らない純粋な単体テスト（初期化・toFirestoreData・init(from:)）はそのまま常時実行。
//
//  実通信テストの有効化方法:
//    - xcodebuild: 環境変数に TEST_RUNNER_ を前置すると test host アプリへ届く
//        TEST_RUNNER_SORAMOYOU_FIRESTORE_INTEGRATION_TESTS=1 xcodebuild test ... \
//          -only-testing:SoramoyouTests/FirestoreServiceTests
//    - Xcode: スキーム編集 > Test > Arguments > Environment Variables に
//        SORAMOYOU_FIRESTORE_INTEGRATION_TESTS = 1 を追加
//    ⚠️ 有効化すると本物の Firestore へ書き込みに行く（test-user-id 等の固定 ID を使うため、
//       firestore.rules が許可する環境では本番データに残る。エミュレータ or テスト専用プロジェクトを推奨）。
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore

final class FirestoreServiceTests: XCTestCase {
    var firestoreService: FirestoreService!
    
    // MARK: - 実通信テストのガード

    /// 実通信テストをオプトインするための環境変数名
    private static let integrationTestsEnvironmentKey = "SORAMOYOU_FIRESTORE_INTEGRATION_TESTS"

    /// Firebase（GoogleService-Info.plist）が設定されているか確認する
    private func isFirebaseConfigured() -> Bool {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
    }

    /// 実通信テストが環境変数で明示的に有効化されているか
    private func isIntegrationTestingEnabled() -> Bool {
        ProcessInfo.processInfo.environment[Self.integrationTestsEnvironmentKey] == "1"
    }

    /// 本物の Firestore へ通信するテストの共通ガード。
    /// plist がない環境と、環境変数でオプトインしていない環境ではスキップする。
    private func skipUnlessIntegrationTestsEnabled() throws {
        try XCTSkipUnless(isFirebaseConfigured(), "Firebase not configured in test environment")
        try XCTSkipUnless(
            isIntegrationTestingEnabled(),
            "実通信テストは既定でスキップ。有効化するには環境変数 \(Self.integrationTestsEnvironmentKey)=1 を設定する"
        )
    }

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
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

        // Given
        let post = createTestPost()
        
        // When
        let createdPost = try await firestoreService.createPost(post)
        
        // Then
        XCTAssertNotNil(createdPost)
        XCTAssertEqual(createdPost.id, post.id)
        XCTAssertEqual(createdPost.userId, post.userId)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post.id, userId: post.userId)
    }
    
    func testFetchPost() async throws {
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

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
        try? await firestoreService.deletePost(postId: post.id, userId: post.userId)
    }
    
    func testFetchPosts() async throws {
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

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
        try? await firestoreService.deletePost(postId: post1.id, userId: post1.userId)
        try? await firestoreService.deletePost(postId: post2.id, userId: post2.userId)
    }
    
    func testFetchPostsWithPagination() async throws {
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

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
        try? await firestoreService.deletePost(postId: post1.id, userId: post1.userId)
        try? await firestoreService.deletePost(postId: post2.id, userId: post2.userId)
    }
    
    func testDeletePost() async throws {
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

        // Given
        let post = createTestPost()
        _ = try await firestoreService.createPost(post)
        
        // When
        try await firestoreService.deletePost(postId: post.id, userId: post.userId)
        
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
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

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
        try? await firestoreService.deletePost(postId: publicPost.id, userId: publicPost.userId)
        try? await firestoreService.deletePost(postId: privatePost.id, userId: privatePost.userId)
    }
    
    // MARK: - Draft Tests
    
    func testSaveDraft() async throws {
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

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
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

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
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

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
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

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
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

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
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

        // Given
        let user = createTestUser()
        
        // When
        let updatedUser = try await firestoreService.updateUser(user)
        
        // Then
        XCTAssertNotNil(updatedUser)
        XCTAssertEqual(updatedUser.id, user.id)
    }
    
    func testUpdateEditTools() async throws {
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

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
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

        // Given
        let post = createTestPost(hashtags: ["sky", "blue"])
        _ = try await firestoreService.createPost(post)
        
        // When
        let results = try await firestoreService.searchByHashtag("sky")
        
        // Then
        XCTAssertFalse(results.isEmpty)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post.id, userId: post.userId)
    }
    
    func testSearchByColor() async throws {
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

        // Given
        let post = createTestPost(skyColors: ["#0000FF", "#FF0000"])
        _ = try await firestoreService.createPost(post)
        
        // When
        let results = try await firestoreService.searchByColor("#0000FF")
        
        // Then
        XCTAssertFalse(results.isEmpty)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post.id, userId: post.userId)
    }
    
    func testSearchByTimeOfDay() async throws {
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

        // Given
        let post = createTestPost(timeOfDay: .morning)
        _ = try await firestoreService.createPost(post)
        
        // When
        let results = try await firestoreService.searchByTimeOfDay(.morning)
        
        // Then
        XCTAssertFalse(results.isEmpty)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post.id, userId: post.userId)
    }
    
    func testSearchBySkyType() async throws {
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

        // Given
        let post = createTestPost(skyType: .clear)
        _ = try await firestoreService.createPost(post)
        
        // When
        let results = try await firestoreService.searchBySkyType(.clear)
        
        // Then
        XCTAssertFalse(results.isEmpty)
        
        // Cleanup
        try? await firestoreService.deletePost(postId: post.id, userId: post.userId)
    }
    
    func testSearchPostsComposite() async throws {
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

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
        try? await firestoreService.deletePost(postId: post.id, userId: post.userId)
    }
    
    func testFetchUserPosts() async throws {
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

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
        try? await firestoreService.deletePost(postId: post1.id, userId: post1.userId)
        try? await firestoreService.deletePost(postId: post2.id, userId: post2.userId)
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

    /// 匿名ユーザー（emailなし）のテスト用ヘルパー
    private func createAnonymousTestUser(
        id: String = "test-anonymous-user-id"
    ) -> User {
        return User(
            id: id,
            email: nil,
            displayName: nil
        )
    }
}

// MARK: - 匿名ユーザー対応テスト

extension FirestoreServiceTests {

    /// 匿名ユーザーのtoFirestoreDataでemailフィールドが含まれないことを確認
    func testAnonymousUserToFirestoreDataExcludesEmail() {
        // Given: emailがnilの匿名ユーザー
        let user = createAnonymousTestUser()

        // When: Firestoreデータに変換
        let data = user.toFirestoreData()

        // Then: emailフィールドが含まれないことを確認
        XCTAssertNil(data["email"], "匿名ユーザーのFirestoreデータにemailフィールドが含まれてはいけない")
        XCTAssertEqual(data["id"] as? String, user.id)
        XCTAssertNotNil(data["createdAt"], "createdAtは必須フィールド")
    }

    /// emailありのユーザーのtoFirestoreDataでemailフィールドが含まれることを確認
    func testAuthenticatedUserToFirestoreDataIncludesEmail() {
        // Given: emailありのユーザー
        let user = createTestUser(email: "user@example.com")

        // When: Firestoreデータに変換
        let data = user.toFirestoreData()

        // Then: emailフィールドが含まれることを確認
        XCTAssertEqual(data["email"] as? String, "user@example.com")
    }

    /// 匿名ユーザーのプロフィール更新が成功することを確認
    func testUpdateAnonymousUser() async throws {
        // 本物の Firestore へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

        // Given: emailがnilの匿名ユーザー
        let user = createAnonymousTestUser()

        // When: プロフィールを更新
        let updatedUser = try await firestoreService.updateUser(user)

        // Then: エラーなく更新されることを確認
        XCTAssertNotNil(updatedUser)
        XCTAssertEqual(updatedUser.id, user.id)
        XCTAssertNil(updatedUser.email, "匿名ユーザーのemailはnilのまま")
    }

    /// Firestoreドキュメントからemailなしのユーザーを復元できることを確認
    func testInitUserFromFirestoreDataWithoutEmail() throws {
        // Given: emailフィールドがないFirestoreデータ（匿名ユーザー）
        let data: [String: Any] = [
            "id": "anonymous-user-123",
            "createdAt": Date(),
            "updatedAt": Date(),
            "followersCount": 0,
            "followingCount": 0,
            "postsCount": 0
        ]

        // When: Firestoreデータからユーザーを初期化
        let user = try User(from: data)

        // Then: emailがnilとして正しく復元されることを確認
        XCTAssertEqual(user.id, "anonymous-user-123")
        XCTAssertNil(user.email, "emailフィールドがない場合はnilであるべき")
    }
}

