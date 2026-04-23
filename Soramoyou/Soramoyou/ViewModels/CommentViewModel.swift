//
//  CommentViewModel.swift
//  Soramoyou
//
//  コメント一覧取得・投稿・削除のViewModel
//

import Foundation
import FirebaseFirestore

/// コメントセクションのViewModel
@MainActor
class CommentViewModel: ObservableObject {
    @Published var comments: [Comment] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var hasMoreComments = true

    private let firestoreService: FirestoreServiceProtocol
    private let authService: AuthServiceProtocol
    private var lastDocument: DocumentSnapshot?
    private let pageSize = 20

    init(firestoreService: FirestoreServiceProtocol = FirestoreService(),
         authService: AuthServiceProtocol = AuthService()) {
        self.firestoreService = firestoreService
        self.authService = authService
    }

    /// コメント一覧を取得（初回読み込み）
    func fetchComments(postId: String) async {
        isLoading = true
        errorMessage = nil
        comments = []
        lastDocument = nil
        hasMoreComments = true

        do {
            let result = try await firestoreService.fetchComments(
                postId: postId,
                limit: pageSize,
                lastDocument: nil
            )
            comments = result.comments
            lastDocument = result.lastDocument
            if result.comments.count < pageSize {
                hasMoreComments = false
            }
        } catch {
            ErrorHandler.logError(error, context: "CommentViewModel.fetchComments")
            errorMessage = error.userFriendlyMessage
        }

        isLoading = false
    }

    /// 次のページのコメントを取得
    func loadMoreComments(postId: String) async {
        guard !isLoadingMore && hasMoreComments else { return }

        isLoadingMore = true

        do {
            let result = try await firestoreService.fetchComments(
                postId: postId,
                limit: pageSize,
                lastDocument: lastDocument
            )
            if result.comments.isEmpty {
                hasMoreComments = false
            } else {
                comments.append(contentsOf: result.comments)
                lastDocument = result.lastDocument
                if result.comments.count < pageSize {
                    hasMoreComments = false
                }
            }
        } catch {
            ErrorHandler.logError(error, context: "CommentViewModel.loadMoreComments")
            errorMessage = error.userFriendlyMessage
        }

        isLoadingMore = false
    }

    /// コメントを投稿
    /// - Returns: 成功時は true
    func addComment(postId: String, content: String) async -> Bool {
        guard let userId = authService.currentUser()?.id else {
            errorMessage = "ログインが必要です"
            return false
        }

        guard !content.isEmpty, content.count <= 500 else {
            errorMessage = "コメントは1〜500文字で入力してください"
            return false
        }

        isSending = true
        errorMessage = nil

        do {
            let comment = try await firestoreService.addComment(
                postId: postId,
                userId: userId,
                content: content
            )
            // 新しいコメントを先頭に追加（降順表示のため）
            comments.insert(comment, at: 0)
            isSending = false
            return true
        } catch {
            ErrorHandler.logError(error, context: "CommentViewModel.addComment", userId: userId)
            errorMessage = error.userFriendlyMessage
            isSending = false
            return false
        }
    }

    /// コメントを削除
    func deleteComment(_ comment: Comment) async {
        guard let userId = authService.currentUser()?.id else { return }

        do {
            try await firestoreService.deleteComment(
                commentId: comment.id,
                postId: comment.postId,
                userId: userId
            )
            comments.removeAll { $0.id == comment.id }
        } catch {
            ErrorHandler.logError(error, context: "CommentViewModel.deleteComment", userId: userId)
            errorMessage = error.userFriendlyMessage
        }
    }

    /// 自分のコメントかどうかを判定
    func isOwnComment(_ comment: Comment) -> Bool {
        guard let userId = authService.currentUser()?.id else { return false }
        return comment.userId == userId
    }

    /// 投稿者かどうかを判定（モデレーション用）
    func isPostOwner(postUserId: String) -> Bool {
        guard let userId = authService.currentUser()?.id else { return false }
        return postUserId == userId
    }
}
