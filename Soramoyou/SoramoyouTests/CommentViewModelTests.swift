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

    // MARK: - ページング（壊れたコメントをスキップしても続きを見失わない）

    /// 1 ページ目で壊れたコメントが 1 件スキップされて 19 件しか返らなくても、
    /// サーバー側に続きがあるなら「さらに読み込む」を出し続けること
    ///
    /// 変換できた件数（19）で「最後のページ」と決めると、それより古いコメントに辿り着けなくなる。
    func testFetchCommentsKeepsLoadMoreWhenPageHadSkippedComment() async {
        let firestore = MockFirestoreServiceForComments()
        firestore.commentPages = [(comments: makeComments(19), lastDocument: nil, hasMore: true)]
        let viewModel = CommentViewModel(firestoreService: firestore, authService: MockAuthService())

        await viewModel.fetchComments(postId: "p1")

        XCTAssertEqual(viewModel.comments.count, 19)
        XCTAssertTrue(viewModel.hasMoreComments)
    }

    /// 続きのページが丸ごと壊れていて 0 件でも、サーバー側に続きがあるなら読み込みを止めないこと
    func testLoadMoreKeepsLoadMoreWhenWholePageWasSkipped() async {
        let firestore = MockFirestoreServiceForComments()
        firestore.commentPages = [
            (comments: makeComments(20), lastDocument: nil, hasMore: true),
            (comments: [], lastDocument: nil, hasMore: true),
        ]
        let viewModel = CommentViewModel(firestoreService: firestore, authService: MockAuthService())

        await viewModel.fetchComments(postId: "p1")
        await viewModel.loadMoreComments(postId: "p1")

        XCTAssertEqual(viewModel.comments.count, 20)
        XCTAssertTrue(viewModel.hasMoreComments)
    }

    /// 最後のページを読んだら、追記したうえで「さらに読み込む」を消すこと（既存挙動の回帰防止）
    func testLoadMoreAppendsAndEndsOnLastPage() async {
        let firestore = MockFirestoreServiceForComments()
        firestore.commentPages = [
            (comments: makeComments(20), lastDocument: nil, hasMore: true),
            (comments: makeComments(3), lastDocument: nil, hasMore: false),
        ]
        let viewModel = CommentViewModel(firestoreService: firestore, authService: MockAuthService())

        await viewModel.fetchComments(postId: "p1")
        await viewModel.loadMoreComments(postId: "p1")

        XCTAssertEqual(viewModel.comments.count, 23)
        XCTAssertFalse(viewModel.hasMoreComments)
    }

    // MARK: - Helpers

    /// テスト用のコメントを count 件作る
    private func makeComments(_ count: Int) -> [Comment] {
        (0 ..< count).map { index in
            Comment(userId: "u1", postId: "p1", content: "コメント\(index)")
        }
    }
}

/// CommentViewModel 専用のモック（必要メソッドのみ override・他は protocol extension のデフォルト）
private final class MockFirestoreServiceForComments: FirestoreServiceProtocol {
    var userToReturn: User?
    var fetchUserError: Error?
    var capturedAuthorName: String?
    var capturedAuthorPhotoURL: String?
    var addCommentWasCalled = false
    /// fetchComments が返すページ（呼ばれるたびに先頭から 1 つずつ取り出す）
    var commentPages: [(comments: [Comment], lastDocument: DocumentSnapshot?, hasMore: Bool)] = []

    func fetchUser(userId: String) async throws -> User {
        if let error = fetchUserError { throw error }
        if let user = userToReturn { return user }
        throw NSError(domain: "MockFirestoreServiceForComments", code: 404)
    }

    func fetchComments(
        postId _: String,
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> (comments: [Comment], lastDocument: DocumentSnapshot?, hasMore: Bool) {
        guard !commentPages.isEmpty else {
            XCTFail("fetchComments が用意したページ数より多く呼ばれた")
            return (comments: [], lastDocument: nil, hasMore: false)
        }
        return commentPages.removeFirst()
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
