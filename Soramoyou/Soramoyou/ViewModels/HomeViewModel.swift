//
//  HomeViewModel.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//
//  ホーム画面（フィード）用ViewModel ⭐️
//  PaginatedPostsViewModelを継承し、ホーム固有のロジックのみを提供

import Foundation
import FirebaseFirestore
import Combine

/// ホーム画面のViewModel
///
/// PaginatedPostsViewModelを継承し、フィード表示に特化した設定を提供する。
/// デフォルトのクエリ（全公開投稿を新しい順に取得）をそのまま使用。
@MainActor
class HomeViewModel: PaginatedPostsViewModel {
    // MARK: - PaginatedPostsViewModel Overrides

    /// ViewModel名（エラーログ用）
    override var viewModelName: String { "HomeViewModel" }

    /// ホームフィードのページサイズ
    override var pageSize: Int { 20 }

    /// ブロックしているユーザーIDのリスト
    private var blockedUserIds: [String] = []

    /// 認証サービス
    private let authService: AuthServiceProtocol

    /// 通報・ブロック処理のエラー
    @Published var reportError: String?

    /// 投稿者キャッシュ（userId -> PublicProfile）⭐️ Issue #2
    /// PostCard で投稿者名/アバターを表示するため、フィードロード時に一括取得して
    /// メモリにキャッシュする。N+1 リクエストを避けつつ、UI から個別問い合わせなく
    /// 著者情報を引ける。
    ///
    /// 注意: `users` コレクションは Firestore Security Rules で `isOwner` 制限が
    /// かかっているため、他ユーザーのドキュメントは読めない。代わりに公開可能な
    /// `publicProfiles` コレクションを使用する。
    @Published var authorsByUserId: [String: PublicProfile] = [:]

    /// 自分自身の userId（フォローボタン表示制御用）
    var currentUserId: String? { authService.currentUser()?.id }

    // MARK: - Initializer

    init(firestoreService: FirestoreServiceProtocol = FirestoreService(),
         authService: AuthServiceProtocol = AuthService()) {
        self.authService = authService
        super.init(firestoreService: firestoreService)
    }

    // MARK: - Feed

    /// 投稿を取得（ブロックユーザーのフィルタリング付き）
    override func fetchPosts() async {
        // ブロックリストを事前に取得
        await loadBlockedUsers()
        // 親クラスの取得ロジックを実行
        await super.fetchPosts()
        // ブロックユーザーの投稿を除外
        filterBlockedUsers()
        // 投稿者情報を一括取得（PostCard 表示用）⭐️ Issue #2
        await fetchAuthorsForCurrentPosts()
    }

    /// 次のページの投稿を取得（ブロックユーザーのフィルタリング付き）
    override func loadMorePosts() async {
        await super.loadMorePosts()
        filterBlockedUsers()
        // 追加分の投稿者情報も取得
        await fetchAuthorsForCurrentPosts()
    }

    /// 1 ページ分を取得し、ブロック中の投稿者の投稿を除いて返す ⭐️
    ///
    /// 除外は `posts` に入れた後でなく、ここ（ページを返す前）で行う。後から除外すると、
    /// 1 ページ全部がブロック中の投稿者だったときに追加分がすべて消えて最後の投稿が変わらず、
    /// 「最後の投稿が見えたら次を読む」きっかけが生まれないまま無限スクロールが止まる。
    /// ここで除外すれば、基底の「表示できる投稿が無いページは次のページを読み進める」に乗る。
    /// - Note: fetchPosts / loadMorePosts の後がけの `filterBlockedUsers()` は従来どおり残す
    ///   （二重にかかっても結果は同じ）。
    /// - Note: ForYouFeedViewModel はこのメソッドを super を呼ばずに上書きする
    ///   （Paginator がページを返す前にブロック除外する）ので、ここは通らない。
    override func executeQuery(lastDocument: DocumentSnapshot?) async throws -> PostPage {
        let page = try await super.executeQuery(lastDocument: lastDocument)
        return page.filteringPosts { !blockedUserIds.contains($0.userId) }
    }

    // ⚠️ この著者取得・ブロック除外ロジックは HomeViewModel / TagDetailViewModel / GalleryViewModel
    //    （Gallery はランキング表示中のみ著者を取得し、失敗を ErrorHandler でログに残す）に重複がある。
    //    仕様を変えるときは全箇所を同時に更新すること。基底 PaginatedPostsViewModel への引き上げは別リファクタ PR で検討。

    /// 現在 posts に含まれる userId のうち、未取得の PublicProfile を並列で fetch する。⭐️ Issue #2
    /// `users` コレクションは isOwner 制限があるため、`publicProfiles` を使う。
    private func fetchAuthorsForCurrentPosts() async {
        let missingUserIds = Set(posts.map(\.userId))
            .subtracting(authorsByUserId.keys)
        guard !missingUserIds.isEmpty else { return }

        await withTaskGroup(of: PublicProfile?.self) { group in
            for userId in missingUserIds {
                group.addTask { [firestoreService] in
                    try? await firestoreService.fetchPublicProfile(userId: userId)
                }
            }
            for await profile in group {
                if let profile = profile {
                    authorsByUserId[profile.id] = profile
                }
            }
        }
    }

    /// ブロックユーザーリストを読み込む
    private func loadBlockedUsers() async {
        guard let currentUserId = authService.currentUser()?.id else { return }

        do {
            blockedUserIds = try await firestoreService.fetchBlockedUserIds(userId: currentUserId)
        } catch {
            // ブロックリスト取得に失敗しても投稿表示は継続
            blockedUserIds = []
        }
    }

    /// ブロックユーザーの投稿をフィルタリング
    private func filterBlockedUsers() {
        guard !blockedUserIds.isEmpty else { return }
        posts = posts.filter { !blockedUserIds.contains($0.userId) }
    }

    /// 投稿詳細でのブロック（`.userBlocked` 通知）を受けて、その人の投稿を一覧から除く ⭐️
    ///
    /// 表示中の投稿から除くだけでなく、`blockedUserIds` に足すことで、以降に読むページ
    /// （`executeQuery` の除外）からも除く。
    override func handleUserBlocked(_ userId: String) {
        guard !blockedUserIds.contains(userId) else { return }
        blockedUserIds.append(userId)
        filterBlockedUsers()
    }

    // MARK: - Report

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
            ErrorHandler.logError(error, context: "HomeViewModel.submitReport", userId: reporterId)
            reportError = error.userFriendlyMessage
        }
    }
}
