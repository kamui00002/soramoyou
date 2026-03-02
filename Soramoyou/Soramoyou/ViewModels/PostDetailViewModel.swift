//
//  PostDetailViewModel.swift
//  Soramoyou
//
//  投稿詳細画面のViewModel
//

import Foundation

/// 投稿詳細画面のViewModel
@MainActor
class PostDetailViewModel: ObservableObject {
    @Published var author: User?
    @Published var isLoadingAuthor = false
    @Published var errorMessage: String?
    /// 通報・ブロック処理のエラー
    @Published var reportError: String?

    private let firestoreService: FirestoreServiceProtocol
    private let authService: AuthServiceProtocol

    init(firestoreService: FirestoreServiceProtocol = FirestoreService(),
         authService: AuthServiceProtocol = AuthService()) {
        self.firestoreService = firestoreService
        self.authService = authService
    }

    /// 投稿者情報を読み込む
    func loadAuthor(userId: String) async {
        isLoadingAuthor = true
        errorMessage = nil

        do {
            author = try await firestoreService.fetchUser(userId: userId)
        } catch {
            errorMessage = error.userFriendlyMessage
        }

        isLoadingAuthor = false
    }

    // MARK: - Report & Block

    /// 通報を送信
    func submitReport(post: Post, reason: ReportReason) async {
        guard let reporterId = authService.currentUser()?.id else { return }

        do {
            try await firestoreService.reportPost(
                postId: post.id ?? "",
                reporterId: reporterId,
                reportedUserId: post.userId,
                reason: reason.rawValue
            )
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.submitReport", userId: reporterId)
            reportError = error.userFriendlyMessage
        }
    }

    /// 投稿者をブロック
    func blockPostAuthor(post: Post) async {
        guard let currentUserId = authService.currentUser()?.id else { return }

        do {
            try await firestoreService.blockUser(userId: currentUserId, blockedUserId: post.userId)
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.blockPostAuthor", userId: currentUserId)
            reportError = error.userFriendlyMessage
        }
    }

    // MARK: - Delete Post

    /// ログイン中のユーザーが自分の投稿かどうか
    func isOwnPost(_ post: Post) -> Bool {
        guard let currentUserId = authService.currentUser()?.id else { return false }
        return post.userId == currentUserId
    }

    /// 投稿を削除する（自分の投稿のみ）
    /// - Parameters:
    ///   - post: 削除する投稿
    ///   - storageService: Storage サービス（画像削除用）
    func deletePost(_ post: Post, storageService: StorageServiceProtocol = StorageService()) async throws {
        guard let userId = authService.currentUser()?.id else { return }

        try await RetryableOperation.executeIfRetryable {
            try await self.firestoreService.deletePost(postId: post.id, userId: userId)
        }

        // Storage 画像の削除（ベストエフォート）
        for image in post.images {
            if let url = URL(string: image.url),
               let fileName = url.pathComponents.last {
                let path = "users/\(post.userId)/posts/\(post.id)/\(fileName)"
                try? await storageService.deleteImage(path: path)
            }
        }
        if let originals = post.originalImages {
            for image in originals {
                if let url = URL(string: image.url),
                   let fileName = url.pathComponents.last {
                    let path = "users/\(post.userId)/posts/\(post.id)/originals/\(fileName)"
                    try? await storageService.deleteImage(path: path)
                }
            }
        }
    }
}
