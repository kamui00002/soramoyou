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
    /// 投稿者の公開プロフィール。
    /// ⚠️ `User`（`users` コレクション）ではなく `PublicProfile`（`publicProfiles`）を保持する。
    /// `users` は Firestore Security Rules で `isOwner` 制限がかかっており、
    /// 他人のドキュメントは読めないため（HomeViewModel / UserProfileViewModel と同じ方針）。
    @Published var author: PublicProfile?
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

    /// 投稿の最新状態を取り直す。
    ///
    /// 再編集（投稿済み画像の上書き更新）は同じ postId のドキュメントを新しい画像URL・
    /// 公開範囲・レシピで置き換えるが、投稿詳細画面が保持する `post` スナップショットは
    /// 自動更新されない。放置すると、再編集後に戻ってきた投稿詳細から共有カードを
    /// 書き出すと削除済みの旧Storage画像をDLしたり、旧 visibility を基準に
    /// 位置情報の既定表示が決まってしまう（統合レビューで発見）。
    /// `.postCreated` 通知（再編集の保存完了時にも発火）を受けて呼び出す想定。
    /// - Parameter postId: 取り直す投稿のID
    /// - Returns: 取得できた最新の投稿。失敗時は nil（呼び出し側は直前の post を保持し、表示を壊さない）
    func refreshPost(postId: String) async -> Post? {
        do {
            return try await firestoreService.fetchPost(postId: postId)
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.refreshPost")
            return nil
        }
    }

    /// 投稿者情報（公開プロフィール）を読み込む。
    ///
    /// ⚠️ 参照先は必ず `publicProfiles`（`fetchPublicProfile`）にすること。
    /// `fetchUser` が読む `users` コレクションは `firestore.rules` の
    /// `allow read: if isOwner(userId)` により **他人のドキュメントでは権限エラーになる**。
    /// その結果、他人の投稿詳細では取得が必ず失敗し、描画側の
    /// `if let user = viewModel.author` が偽になって著者ブロックごと無言で消えていた。
    ///
    /// 失敗時は `errorMessage` に載せず `ErrorHandler.logError` のみに留める。
    /// この画面には `errorMessage` を監視してアラートを出す導線が無く、
    /// セットしても誰にも見えないため。ただし原因追跡のためログは必ず残す。
    /// - Parameter userId: 投稿者のユーザーID
    func loadAuthor(userId: String) async {
        isLoadingAuthor = true

        do {
            author = try await firestoreService.fetchPublicProfile(userId: userId)
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.loadAuthor")
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
            await storageService.deletePostImages(post)
            return true
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.deletePost", userId: userId)
            deleteError = error.userFriendlyMessage
            return false
        }
    }

}
