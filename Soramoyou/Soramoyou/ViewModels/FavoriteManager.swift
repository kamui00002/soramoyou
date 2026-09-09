//
//  FavoriteManager.swift
//  Soramoyou
//
//  全画面共有の「お気に入り（🔖）」状態管理ViewModel ⭐️
//  EnvironmentObjectとして注入し、PostCard・PostDetailView・GalleryDetailViewで使用
//
//  ⚠️ LikeManager と対になる存在だが、いいねとは別物のプライベート保存。
//     通知を出さない・件数を公開しないため、カウント調整（likeCountAdjustments 相当）は持たない。
//

import Foundation

/// お気に入り状態を一元管理するViewModel
///
/// オプティミスティックUIでタップ即座に反映し、エラー時にリバートする。
/// `@EnvironmentObject` として全画面で共有する。
@MainActor
final class FavoriteManager: ObservableObject {
    /// お気に入り済みの投稿IDセット
    @Published private(set) var favoritedPostIds: Set<String> = []
    /// ログインプロンプト表示フラグ
    /// ⚠️ LikeManager と同様、現時点ではフラグを立てるだけでUIは未配線（既存ギャップに合わせる）。
    @Published var showLoginPrompt = false

    private let firestoreService: FirestoreServiceProtocol
    private let authService: AuthServiceProtocol

    init(firestoreService: FirestoreServiceProtocol = FirestoreService(),
         authService: AuthServiceProtocol = AuthService()) {
        self.firestoreService = firestoreService
        self.authService = authService
    }

    /// お気に入り済みかどうかを判定
    func isFavorited(_ postId: String) -> Bool {
        favoritedPostIds.contains(postId)
    }

    /// お気に入りをトグル（オプティミスティックUI）
    /// - Parameters:
    ///   - post: 対象の投稿
    ///   - source: 計装用の発生源（"home_card" / "post_detail" / "gallery_detail" / "profile_list" / "tag_detail"）
    func toggleFavorite(post: Post, source: String) async {
        guard let userId = authService.currentUser()?.id else {
            showLoginPrompt = true
            return
        }

        let postId = post.id
        // 「押した結果どうなってほしいか」を先に決める。
        // サーバー側トグルにしないので、ローカル状態が古くてもこの意図どおりに収束する（冪等）。
        let willFavorite = !favoritedPostIds.contains(postId)

        // オプティミスティック更新（タップに即座に反応させる）
        if willFavorite {
            favoritedPostIds.insert(postId)
        } else {
            favoritedPostIds.remove(postId)
        }

        do {
            try await firestoreService.setFavorite(postId: postId, userId: userId, isFavorited: willFavorite)
            LoggingService.shared.logEvent("favorite_toggled", parameters: [
                "is_favorited": willFavorite,
                "source": source,
                "is_own_post": post.userId == userId
            ])
        } catch {
            // ⚠️ await の最中にサインアウト／アカウント切替が挟まっていたら、
            //    前ユーザー宛のリバートを新しい状態へ書き戻してはいけない
            //    （clearOnSignOut で消したはずの id が復活してしまう）。
            guard authService.currentUser()?.id == userId else {
                ErrorHandler.logError(error, context: "FavoriteManager.toggleFavorite", userId: userId)
                return
            }
            // 失敗時はローカルを元に戻す（UIが嘘をつかないように）
            if willFavorite {
                favoritedPostIds.remove(postId)
            } else {
                favoritedPostIds.insert(postId)
            }
            ErrorHandler.logError(error, context: "FavoriteManager.toggleFavorite", userId: userId)
        }
    }

    /// 表示中の投稿についてお気に入り状態をバッチチェック
    ///
    /// ⚠️ LikeManager の `formUnion` だけの実装と違い、**問い合わせた postId の範囲だけ**
    ///    サーバー値で上書きする（subtract → formUnion）。
    ///    こうしないと「別端末で外した」「サインアウト前の残骸」がローカルに残り続ける。
    ///    問い合わせていない postId は触らないので、ページング追加読み込みでも既存状態は壊れない。
    func checkFavoriteStatus(for posts: [Post]) async {
        guard let userId = authService.currentUser()?.id else { return }
        let postIds = posts.map(\.id)
        guard !postIds.isEmpty else { return }

        do {
            let favoritedIds = try await firestoreService.batchCheckFavoriteStatus(postIds: postIds, userId: userId)
            // ⚠️ await の最中にサインアウト／アカウント切替が挟まっていたら、
            //    前ユーザー宛の照会結果を反映しない（別ユーザーの🔖が見えてしまう）。
            guard authService.currentUser()?.id == userId else { return }
            favoritedPostIds.subtract(postIds)      // 今回の対象範囲をいったんクリア
            favoritedPostIds.formUnion(favoritedIds) // サーバー値で埋め直す
        } catch {
            ErrorHandler.logError(error, context: "FavoriteManager.checkFavoriteStatus", userId: userId)
        }
    }

    /// favorites コレクションから取得した postId を「お気に入り済み」として登録する
    ///
    /// お気に入り一覧画面は favorites を直接読んでいるので、
    /// 同じ内容をサーバーへ再照会するのは無駄。取得済みの事実をそのまま反映する。
    func registerFavorited(postIds: [String]) {
        favoritedPostIds.formUnion(postIds)
    }

    /// サインアウト時にローカル状態を捨てる ⭐️
    ///
    /// ⚠️ お気に入りは「自分だけが見られる」プライベート保存なので、共有端末で
    ///    次のユーザーに前のユーザーの🔖が塗られて見えてはいけない。
    ///    Manager は App レベルの `@StateObject` でサインアウトしても破棄されず、
    ///    `checkFavoriteStatus` は**問い合わせた範囲しか**上書きしないため、
    ///    明示的に消さないと範囲外の残骸が残り続ける。
    ///
    ///    `AuthViewModel.signOut` が `WidgetCacheManager.clearOnSignOut()` /
    ///    `SkyMotionCreditService.handleSignOut()` に対して行っている
    ///    「ユーザー固有のローカル状態はサインアウトで消す」慣例に揃えたもの。
    ///    （AuthViewModel からは別 `@StateObject` の本 Manager に手が届かないため、
    ///      呼び出しは ContentView 側で配線している）
    func clearOnSignOut() {
        favoritedPostIds = []
        showLoginPrompt = false
    }
}
