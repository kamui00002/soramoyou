//
//  LikeManager.swift
//  Soramoyou
//
//  全画面共有のいいね状態管理ViewModel
//  EnvironmentObjectとして注入し、PostCard・PostDetailView・GalleryDetailViewで使用
//

import Foundation

/// いいね状態を一元管理するViewModel
///
/// オプティミスティックUIでタップ即座に反映し、エラー時にリバートする。
/// `@EnvironmentObject` として全画面で共有する。
@MainActor
class LikeManager: ObservableObject {
    /// いいね済みの投稿IDセット
    @Published private(set) var likedPostIds: Set<String> = []
    /// ローカルでのいいねカウント調整値（postId -> 差分）
    @Published private(set) var likeCountAdjustments: [String: Int] = [:]
    /// ログインプロンプト表示フラグ
    @Published var showLoginPrompt = false

    private let firestoreService: FirestoreServiceProtocol
    private let authService: AuthServiceProtocol

    init(firestoreService: FirestoreServiceProtocol = FirestoreService(),
         authService: AuthServiceProtocol = AuthService()) {
        self.firestoreService = firestoreService
        self.authService = authService
    }

    /// いいね済みかどうかを判定
    func isLiked(_ postId: String) -> Bool {
        likedPostIds.contains(postId)
    }

    /// 投稿のいいね数を取得（ローカル調整値を含む）
    func likeCount(for post: Post) -> Int {
        let adjustment = likeCountAdjustments[post.id] ?? 0
        return max(0, post.likesCount + adjustment)
    }

    /// いいねをトグル（オプティミスティックUI）
    func toggleLike(post: Post) async {
        guard let userId = authService.currentUser()?.id else {
            showLoginPrompt = true
            return
        }

        let postId = post.id
        let wasLiked = likedPostIds.contains(postId)

        // オプティミスティック更新
        if wasLiked {
            likedPostIds.remove(postId)
            likeCountAdjustments[postId, default: 0] -= 1
        } else {
            likedPostIds.insert(postId)
            likeCountAdjustments[postId, default: 0] += 1
        }

        // Firestore に反映
        do {
            _ = try await firestoreService.toggleLike(postId: postId, userId: userId)
        } catch {
            // エラー時にリバート
            if wasLiked {
                likedPostIds.insert(postId)
                likeCountAdjustments[postId, default: 0] += 1
            } else {
                likedPostIds.remove(postId)
                likeCountAdjustments[postId, default: 0] -= 1
            }
            ErrorHandler.logError(error, context: "LikeManager.toggleLike", userId: userId)
        }
    }

    /// フィード読み込み時にいいね状態をバッチチェック
    func checkLikeStatus(for posts: [Post]) async {
        guard let userId = authService.currentUser()?.id else { return }
        let postIds = posts.map(\.id)
        guard !postIds.isEmpty else { return }

        do {
            let likedIds = try await firestoreService.batchCheckLikeStatus(postIds: postIds, userId: userId)
            // 既存のセットにマージ（ページネーションで追加読み込み時に上書きしない）
            likedPostIds.formUnion(likedIds)
        } catch {
            ErrorHandler.logError(error, context: "LikeManager.checkLikeStatus", userId: userId)
        }
    }
}
