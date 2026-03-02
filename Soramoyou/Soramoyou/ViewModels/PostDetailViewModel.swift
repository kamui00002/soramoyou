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
    /// 投稿削除処理のエラー
    @Published var deleteError: String?

    private let firestoreService: FirestoreServiceProtocol
    private let authService: AuthServiceProtocol
    private let storageService: StorageServiceProtocol

    init(firestoreService: FirestoreServiceProtocol = FirestoreService(),
         authService: AuthServiceProtocol = AuthService(),
         storageService: StorageServiceProtocol = StorageService()) {
        self.firestoreService = firestoreService
        self.authService = authService
        self.storageService = storageService
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

    /// 投稿を削除する（自分の投稿のみ）。成功時は true を返す。
    /// 削除失敗時は deleteError にメッセージをセットして false を返す。
    /// - Parameter post: 削除する投稿
    /// - Returns: 削除成功なら true
    func deletePost(_ post: Post) async -> Bool {
        guard let userId = authService.currentUser()?.id else {
            deleteError = "ログインが必要です"
            return false
        }
        deleteError = nil

        do {
            try await RetryableOperation.executeIfRetryable {
                try await self.firestoreService.deletePost(postId: post.id, userId: userId)
            }

            // Storage 画像の削除（ベストエフォート・並列実行）
            await deletePostImages(post)
            return true
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.deletePost", userId: userId)
            deleteError = error.userFriendlyMessage
            return false
        }
    }

    /// Storage から投稿に関連する画像を並列削除（エラーは無視）
    private func deletePostImages(_ post: Post) async {
        await withTaskGroup(of: Void.self) { group in
            for image in post.images {
                if let url = URL(string: image.url) {
                    let path = storagePathFromURL(url, postId: post.id, userId: post.userId, isOriginal: false)
                    group.addTask { try? await self.storageService.deleteImage(path: path) }
                }
            }
            if let originals = post.originalImages {
                for image in originals {
                    if let url = URL(string: image.url) {
                        let path = storagePathFromURL(url, postId: post.id, userId: post.userId, isOriginal: true)
                        group.addTask { try? await self.storageService.deleteImage(path: path) }
                    }
                }
            }
        }
    }

    /// Firebase Storage URL から削除パスを構築する
    /// Firebase Storage URL 例: https://firebasestorage.googleapis.com/v0/b/<bucket>/o/users%2F<uid>%2Fposts%2F<postId>%2F<file>?token=...
    private func storagePathFromURL(_ url: URL, postId: String, userId: String, isOriginal: Bool) -> String {
        let fileName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let subfolder = isOriginal ? "originals/" : ""
        return "users/\(userId)/posts/\(postId)/\(subfolder)\(fileName)"
    }
}
