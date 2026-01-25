//
//  PostDetailViewModel.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import FirebaseFirestore

@MainActor
class PostDetailViewModel: ObservableObject {
    @Published var post: Post
    @Published var comments: [Comment] = []
    @Published var isLiked: Bool = false
    @Published var isLoading = false
    @Published var isLoadingComments = false
    @Published var errorMessage: String?
    @Published var newCommentText: String = ""
    @Published var showAddToCollectionSheet = false
    @Published var userCollections: [Collection] = []

    private let userId: String?
    private let firestoreService: FirestoreServiceProtocol
    private var lastCommentDocument: DocumentSnapshot?

    init(
        post: Post,
        userId: String?,
        firestoreService: FirestoreServiceProtocol = FirestoreService()
    ) {
        self.post = post
        self.userId = userId
        self.firestoreService = firestoreService
    }

    // MARK: - Load Data

    /// 初期データをロード
    func loadInitialData() async {
        isLoading = true

        async let likeStatus: () = loadLikeStatus()
        async let commentsLoad: () = loadComments()
        async let collectionsLoad: () = loadUserCollections()

        await likeStatus
        await commentsLoad
        await collectionsLoad

        isLoading = false
    }

    /// いいね状態をロード
    func loadLikeStatus() async {
        guard let userId = userId else { return }

        do {
            isLiked = try await firestoreService.isPostLiked(userId: userId, postId: post.id)
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.loadLikeStatus", userId: userId)
        }
    }

    /// コメントをロード
    func loadComments() async {
        isLoadingComments = true

        do {
            comments = try await firestoreService.fetchComments(postId: post.id, limit: 20, lastDocument: nil)
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.loadComments", userId: userId)
            errorMessage = error.userFriendlyMessage
        }

        isLoadingComments = false
    }

    /// ユーザーのコレクションをロード
    func loadUserCollections() async {
        guard let userId = userId else { return }

        do {
            userCollections = try await firestoreService.fetchCollections(userId: userId)
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.loadUserCollections", userId: userId)
        }
    }

    // MARK: - Likes

    /// いいねをトグル
    func toggleLike() async {
        guard let userId = userId else {
            errorMessage = "いいねするにはログインが必要です"
            return
        }

        let wasLiked = isLiked

        // 楽観的更新
        isLiked.toggle()
        post.likesCount += isLiked ? 1 : -1

        do {
            if isLiked {
                try await firestoreService.likePost(userId: userId, postId: post.id)
            } else {
                try await firestoreService.unlikePost(userId: userId, postId: post.id)
            }
        } catch {
            // ロールバック
            isLiked = wasLiked
            post.likesCount += wasLiked ? 1 : -1

            ErrorHandler.logError(error, context: "PostDetailViewModel.toggleLike", userId: userId)
            errorMessage = error.userFriendlyMessage
        }
    }

    // MARK: - Comments

    /// コメントを送信
    func submitComment() async {
        guard let userId = userId else {
            errorMessage = "コメントするにはログインが必要です"
            return
        }

        let trimmedText = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty else {
            errorMessage = "コメントを入力してください"
            return
        }

        guard trimmedText.count <= 500 else {
            errorMessage = "コメントは500文字以内で入力してください"
            return
        }

        let comment = Comment(
            userId: userId,
            postId: post.id,
            content: trimmedText
        )

        do {
            let createdComment = try await firestoreService.createComment(comment)
            comments.append(createdComment)
            post.commentsCount += 1
            newCommentText = ""
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.submitComment", userId: userId)
            errorMessage = error.userFriendlyMessage
        }
    }

    /// コメントを削除
    func deleteComment(_ comment: Comment) async {
        guard let userId = userId, comment.userId == userId else {
            errorMessage = "自分のコメントのみ削除できます"
            return
        }

        do {
            try await firestoreService.deleteComment(commentId: comment.id)
            comments.removeAll { $0.id == comment.id }
            post.commentsCount -= 1
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.deleteComment", userId: userId)
            errorMessage = error.userFriendlyMessage
        }
    }

    // MARK: - Collections

    /// コレクションに投稿を追加
    func addToCollection(_ collection: Collection) async {
        guard let userId = userId else {
            errorMessage = "コレクションに追加するにはログインが必要です"
            return
        }

        do {
            try await firestoreService.addPostToCollection(userId: userId, collectionId: collection.id, postId: post.id)
            showAddToCollectionSheet = false
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.addToCollection", userId: userId)
            errorMessage = error.userFriendlyMessage
        }
    }

    /// 新しいコレクションを作成して投稿を追加
    func createCollectionAndAdd(name: String) async {
        guard let userId = userId else {
            errorMessage = "コレクションを作成するにはログインが必要です"
            return
        }

        let collection = Collection(userId: userId, name: name)

        do {
            let createdCollection = try await firestoreService.createCollection(collection)
            try await firestoreService.addPostToCollection(userId: userId, collectionId: createdCollection.id, postId: post.id)
            userCollections.append(createdCollection)
            showAddToCollectionSheet = false
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.createCollectionAndAdd", userId: userId)
            errorMessage = error.userFriendlyMessage
        }
    }
}
