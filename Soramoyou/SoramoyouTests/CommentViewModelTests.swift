//
//  CommentViewModelTests.swift
//  SoramoyouTests
//
//  コメント投稿時に投稿者名・写真を Firestore プロフィールから取得して
//  非正規化保存する挙動（Option A）の検証
//

import XCTest
import FirebaseFirestore
@testable import Soramoyou

@MainActor
final class CommentViewModelTests: XCTestCase {

    /// プロフィールが取得できれば、その表示名・写真をコメントに焼き込んで保存する
    func testAddCommentDenormalizesAuthorNameAndPhoto() async {
        let firestore = MockFirestoreServiceForComments()
        firestore.userToReturn = User(
            id: "u1",
            email: "x@example.com",
            displayName: "Soumatou",
            photoURL: "https://example.com/a.jpg"
        )
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "u1")
        let viewModel = CommentViewModel(firestoreService: firestore, authService: auth)

        let success = await viewModel.addComment(postId: "p1", content: "きれいな空")

        XCTAssertTrue(success)
        XCTAssertEqual(firestore.capturedAuthorName, "Soumatou")
        XCTAssertEqual(firestore.capturedAuthorPhotoURL, "https://example.com/a.jpg")
        // 楽観的更新で先頭に挿入されたコメントにも名前が乗る
        XCTAssertEqual(viewModel.comments.first?.authorName, "Soumatou")
        XCTAssertEqual(viewModel.comments.first?.authorPhotoURL, "https://example.com/a.jpg")
    }

    /// プロフィール取得に失敗してもコメント投稿自体は成功する（best-effort）
    func testAddCommentProceedsWhenProfileFetchFails() async {
        let firestore = MockFirestoreServiceForComments()
        firestore.fetchUserError = NSError(domain: "test", code: 1)
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "u1")
        let viewModel = CommentViewModel(firestoreService: firestore, authService: auth)

        let success = await viewModel.addComment(postId: "p1", content: "きれいな空")

        XCTAssertTrue(success)
        XCTAssertNil(firestore.capturedAuthorName)
        XCTAssertNil(firestore.capturedAuthorPhotoURL)
    }

    /// 未ログインではコメントを投稿できない
    func testAddCommentFailsWhenNotAuthenticated() async {
        let firestore = MockFirestoreServiceForComments()
        let auth = MockAuthService()
        auth.currentUserValue = nil
        let viewModel = CommentViewModel(firestoreService: firestore, authService: auth)

        let success = await viewModel.addComment(postId: "p1", content: "きれいな空")

        XCTAssertFalse(success)
        XCTAssertNil(firestore.capturedAuthorName)
    }
}

/// CommentViewModel 専用のモック（必要メソッドのみ override・他は protocol extension のデフォルト）
private final class MockFirestoreServiceForComments: FirestoreServiceProtocol {
    var userToReturn: User?
    var fetchUserError: Error?
    var capturedAuthorName: String?
    var capturedAuthorPhotoURL: String?
    var addCommentWasCalled = false

    func fetchUser(userId: String) async throws -> User {
        if let error = fetchUserError { throw error }
        if let user = userToReturn { return user }
        throw NSError(domain: "MockFirestoreServiceForComments", code: 404)
    }

    func addComment(postId: String, userId: String, content: String, authorName: String?, authorPhotoURL: String?) async throws -> Comment {
        addCommentWasCalled = true
        capturedAuthorName = authorName
        capturedAuthorPhotoURL = authorPhotoURL
        return Comment(
            userId: userId,
            postId: postId,
            content: content,
            authorName: authorName,
            authorPhotoURL: authorPhotoURL
        )
    }
}
