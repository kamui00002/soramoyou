//
//  PostDetailViewModelTests.swift
//  SoramoyouTests
//
//  投稿詳細画面 ViewModel のテスト。統合レビューで発見した
//  「再編集後、投稿詳細が古い画像URL/公開範囲を保持し続ける」バグの修正
//  （refreshPost メソッド）を検証する。CalendarDiaryViewModelTests と同型の最小 Mock を使う。
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore

@MainActor
final class PostDetailViewModelTests: XCTestCase {

    func testRefreshPostReturnsLatestPostFromFirestore() async {
        // Arrange: Firestore 側は再編集後の新しい画像URL・非公開設定を返す
        let mock = MockFirestoreServiceForPostDetail()
        let updatedPost = Post(
            id: "post1",
            userId: "u1",
            images: [ImageInfo(url: "https://example.com/new.jpg", thumbnail: "", width: 100, height: 100, order: 0)],
            visibility: .private
        )
        mock.stubbedPost = updatedPost
        let viewModel = PostDetailViewModel(firestoreService: mock)

        // Act
        let result = await viewModel.refreshPost(postId: "post1")

        // Assert: 取得した最新投稿がそのまま返る（呼び出し元 View が @State post に差し替える想定）
        XCTAssertEqual(result?.id, "post1")
        XCTAssertEqual(result?.images.first?.url, "https://example.com/new.jpg")
        XCTAssertEqual(result?.visibility, .private)
        XCTAssertEqual(mock.requestedPostId, "post1")
    }

    func testRefreshPostReturnsNilOnFailureWithoutCrashing() async {
        // Arrange: Firestore 取得が失敗する（ネットワークエラー等）
        let mock = MockFirestoreServiceForPostDetail()
        mock.stubbedError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        let viewModel = PostDetailViewModel(firestoreService: mock)

        // Act
        let result = await viewModel.refreshPost(postId: "post1")

        // Assert: nil を返し、呼び出し側が直前の post を保持できるようにする（表示を壊さない）
        XCTAssertNil(result, "取得失敗時は nil を返し、呼び出し側で直前の post を保持できるようにするべき")
    }
}

// MARK: - Mock

/// `fetchPost` のみ上書きする最小 Mock。残りは TestDefaults（fatalError）で満たす。
final class MockFirestoreServiceForPostDetail: FirestoreServiceProtocol {
    var stubbedPost: Post?
    var stubbedError: Error?
    private(set) var requestedPostId: String?

    func fetchPost(postId: String) async throws -> Post {
        requestedPostId = postId
        if let stubbedError { throw stubbedError }
        guard let stubbedPost else {
            fatalError("MockFirestoreServiceForPostDetail.stubbedPost が未設定です")
        }
        return stubbedPost
    }
}
