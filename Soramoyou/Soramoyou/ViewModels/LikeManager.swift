//
//  LikeManager.swift
//  Soramoyou
//
//  全画面共有のいいね状態管理ViewModel
//  EnvironmentObjectとして注入し、PostCard・PostDetailView・GalleryDetailViewで使用
//

import Foundation

// MARK: - 計装の差し替え口 ⭐️ PR-H

/// いいねの計装の送り先（テストでは記録するだけの偽物を渡す）
///
/// DailyPickViewModel の `DailyPickEventLogging` と同じ形。
/// FavoriteManager のように `LoggingService.shared` を直に呼ぶと、送ったかどうかをテストで確かめられないため。
protocol LikeEventLogging: AnyObject {
    func logEvent(_ name: String, parameters: [String: Any]?)
}

/// 本番は LoggingService（PostHog・Firebase Analytics の両方に送る）。署名はそのまま合う
extension LoggingService: LikeEventLogging {}

/// いいねをどの操作で押したか（`like_toggled` の `method` に rawValue を送る）⭐️ PR-H
enum LikeToggleMethod: String {
    /// ハートのボタン
    case button
    /// 写真の 2 回タップ（読み上げの「いいね」操作もここに数える）
    case doubleTap = "double_tap"
}

/// いいね状態を一元管理するViewModel
///
/// オプティミスティックUIでタップ即座に反映し、エラー時にリバートする。
/// `@EnvironmentObject` として全画面で共有する。
@MainActor
class LikeManager: ObservableObject {
    /// 押した結果の数字を「どの likesCount の投稿で押したか」と組で覚えておく ⭐️
    ///
    /// 画面が持っている `Post.likesCount` は一覧を読んだ時点の値のまま更新されない（issue #145 ①）。
    /// そこで押したときの `Post.likesCount`（基準）と押した結果の数字を組で持ち、
    /// 投稿の likesCount が基準のままなら押した結果を、変わっていれば（＝読み直して最新値が届いた）
    /// 投稿の値をそのまま出す。画面ごとに「読み直したら消す」場所を用意しなくてよく、
    /// 自分の +1 を二重に数えることもない（ultrareview bug_001）。
    ///
    /// ⚠️ 限界: 「基準と同じ数が届いた＝まだ読み直していない」とは限らない。数が一度動いて元に戻ると
    ///    （5→6→5）基準と一致して、押した結果が出続ける。自分のいいね状態が変わった場合（別端末で外した等）は
    ///    `checkLikeStatus` が `isLiked` の食い違いで捨てる。他の人の操作でちょうど基準に戻った場合までは
    ///    見分けられない（投稿ごとの数を画面をまたいで共有する仕組みが要る）。
    struct LikeCountOverride: Equatable {
        /// 押したときに画面が持っていた Post.likesCount
        let baseCount: Int
        /// 表示する数字（押した直後は楽観的な値、書き込み成功後はサーバー値）
        let count: Int
        /// 押した結果のいいね状態。サーバーの状態と食い違ったら、この数字はもう古い
        let isLiked: Bool
    }

    /// いいね済みの投稿IDセット
    @Published private(set) var likedPostIds: Set<String> = []
    /// 押した結果の数字（postId -> 基準と数字）
    @Published private(set) var likeCountOverrides: [String: LikeCountOverride] = [:]
    /// ログインプロンプト表示フラグ
    @Published var showLoginPrompt = false

    /// 書き込み中の投稿ID（処理中の連打を受け付けないため）
    private var inFlightPostIds: Set<String> = []

    private let firestoreService: FirestoreServiceProtocol
    private let authService: AuthServiceProtocol
    /// 計装の送り先（本番は LoggingService.shared・テストは記録するだけの偽物）⭐️ PR-H
    private let logger: LikeEventLogging

    init(firestoreService: FirestoreServiceProtocol = FirestoreService(),
         authService: AuthServiceProtocol = AuthService(),
         logger: LikeEventLogging = LoggingService.shared)
    {
        self.firestoreService = firestoreService
        self.authService = authService
        self.logger = logger
    }

    /// いいね済みかどうかを判定
    func isLiked(_ postId: String) -> Bool {
        likedPostIds.contains(postId)
    }

    /// 投稿のいいね数を取得（押した結果の数字を含む）
    func likeCount(for post: Post) -> Int {
        // 投稿の likesCount が押したときのままなら、押した結果を出す。
        // 変わっていれば読み直した最新値なので、そちらを信じる（自分の分も含まれている）。
        if let override = likeCountOverrides[post.id], override.baseCount == post.likesCount {
            return max(0, override.count)
        }
        return max(0, post.likesCount)
    }

    /// いいねをトグル（オプティミスティックUI）
    /// - Parameters:
    ///   - post: 対象の投稿
    ///   - source: 計装用の発生源（"home_card" / "post_detail" / "gallery_detail" / "profile_list" / "tag_detail"）
    ///   - method: 計装用の押し方（ハートのボタン／写真の 2 回タップ）⭐️ PR-H
    func toggleLike(post: Post, source: String, method: LikeToggleMethod) async {
        guard let userId = authService.currentUser()?.id else {
            showLoginPrompt = true
            return
        }

        let postId = post.id
        // ⚠️ 書き込み中の投稿への連打は受け付けない。
        //    「つける／外す」を指定して書く方式では、2 つの書き込みがサーバーで逆順に確定すると
        //    画面（最後に押した状態）とサーバーが食い違う。1 投稿につき書き込みは 1 本ずつにする。
        guard !inFlightPostIds.contains(postId) else { return }
        inFlightPostIds.insert(postId)
        defer { inFlightPostIds.remove(postId) }

        // 「押した結果どうなってほしいか」を先に決める（FavoriteManager と同じ）。
        // サーバー側トグルにしないので、手元の状態が古くても
        // （ギャラリー系の画面でいいね済みが空のハートで出ていても）押した意図どおりに収束する（issue #145 ②）。
        let willLike = !likedPostIds.contains(postId)
        let previousOverride = likeCountOverrides[postId]
        let displayedCount = likeCount(for: post)

        // オプティミスティック更新（タップに即座に反応させる）
        if willLike {
            likedPostIds.insert(postId)
        } else {
            likedPostIds.remove(postId)
        }
        likeCountOverrides[postId] = LikeCountOverride(
            baseCount: post.likesCount,
            count: displayedCount + (willLike ? 1 : -1),
            isLiked: willLike
        )

        // Firestore に反映
        do {
            let serverCount = try await firestoreService.setLike(postId: postId, userId: userId, isLiked: willLike)
            // ⚠️ 書き込みの最中にサインアウト／アカウント切替が挟まっていたら、前のユーザーの結果を
            //    今のユーザーの画面へ書き戻さない（clearOnSignOut で消した状態が復活する・#147）。
            //    FavoriteManager.toggleFavorite と同じガード。
            guard authService.currentUser()?.id == userId else { return }
            // 計装 `like_toggled` ⭐️ PR-H — 書き込みに成功し、アカウントも変わっていないときだけ送る。
            // 失敗（画面は元に戻る）や前のユーザーの操作まで数えると、実際に付いた／外れたいいねと数が合わなくなるため。
            logger.logEvent("like_toggled", parameters: [
                "is_liked": willLike,
                "method": method.rawValue,
                "source": source,
                "is_own_post": post.userId == userId,
            ])
            // 成功した時点でサーバーは「押した意図どおり」の状態。途中で状態の読み直しが挟まっても、ここでそろえる。
            if willLike {
                likedPostIds.insert(postId)
            } else {
                likedPostIds.remove(postId)
            }
            // 楽観的な ±1 をサーバーの数字で置き換える。
            // 既にその状態だった（サーバーは書かなかった）場合も、ここで正しい数字にそろう。
            likeCountOverrides[postId] = LikeCountOverride(baseCount: post.likesCount, count: serverCount, isLiked: willLike)
        } catch {
            // ⚠️ 成功時と同じく、アカウントが変わっていたら前のユーザー宛の巻き戻しをしない（#147）
            guard authService.currentUser()?.id == userId else {
                ErrorHandler.logError(error, context: "LikeManager.toggleLike", userId: userId)
                return
            }
            // エラー時にリバート
            if willLike {
                likedPostIds.remove(postId)
            } else {
                likedPostIds.insert(postId)
            }
            likeCountOverrides[postId] = previousOverride
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
            // ⚠️ 読み取りの最中にアカウントが変わっていたら、届いたのは前のユーザーのいいね状態なので反映しない（#147）。
            //    FavoriteManager.checkFavoriteStatus と同じガード。
            guard authService.currentUser()?.id == userId else { return }
            // ⚠️ 問い合わせた範囲だけサーバー値で上書きする（FavoriteManager と同じ subtract → formUnion）。
            //    formUnion だけだと、別端末で外したいいねがピンクのまま残る。
            //    問い合わせていない postId は触らないので、ページング追加読み込みでも既存状態は壊れない。
            likedPostIds.subtract(postIds)
            likedPostIds.formUnion(likedIds)
            // ⚠️ 数字（likeCountOverrides）は、サーバーの状態と食い違うものだけ捨てる。
            //    全部消すと、詳細画面（一覧を読んだ時点の古い Post で呼ぶ）で押した結果が古い数字に戻る（issue #145 ①）。
            //    一方、押した向きとサーバーのいいね状態が食い違う投稿（別端末で外した等）の数字はもう古い。
            //    数の一致だけでは見分けられない（5→6→5 で基準と同じ数が届く）ので、状態で見分けて捨てる。
            //    書き込み中の投稿は、読んだ値が書き込み前のことがあるので触らない（成功時にそろえる）。
            for postId in postIds where !inFlightPostIds.contains(postId) {
                if let override = likeCountOverrides[postId], override.isLiked != likedIds.contains(postId) {
                    likeCountOverrides.removeValue(forKey: postId)
                }
            }
        } catch {
            ErrorHandler.logError(error, context: "LikeManager.checkLikeStatus", userId: userId)
        }
    }

    /// サインアウト時にローカル状態を捨てる ⭐️（#147）
    ///
    /// ⚠️ Manager は App レベルの `@StateObject` でサインアウトしても破棄されず、
    ///    `checkLikeStatus` は**問い合わせた範囲しか**上書きしないため、明示的に消さないと
    ///    共有端末で次のユーザーに前のユーザーのいいね（ピンクのハート）や押した結果の数字が見えてしまう。
    ///    `FavoriteManager.clearOnSignOut()` と同じ対策で、呼び出しも同じく ContentView で配線している
    ///    （AuthViewModel からは別 `@StateObject` の本 Manager に手が届かないため）。
    func clearOnSignOut() {
        likedPostIds = []
        likeCountOverrides = [:]
        showLoginPrompt = false
    }
}
