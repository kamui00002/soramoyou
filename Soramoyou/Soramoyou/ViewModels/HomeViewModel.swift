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
    }

    /// 次のページの投稿を取得（ブロックユーザーのフィルタリング付き）
    override func loadMorePosts() async {
        await super.loadMorePosts()
        filterBlockedUsers()
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
            ErrorHandler.logError(error, context: "HomeViewModel.submitReport", userId: reporterId)
            reportError = error.userFriendlyMessage
        }
    }

    /// 投稿者をブロック
    func blockPostAuthor(post: Post) async {
        guard let currentUserId = authService.currentUser()?.id else { return }

        do {
            try await firestoreService.blockUser(userId: currentUserId, blockedUserId: post.userId)
            // ブロック後、該当ユーザーの投稿をフィードから除外
            blockedUserIds.append(post.userId)
            filterBlockedUsers()
        } catch {
            ErrorHandler.logError(error, context: "HomeViewModel.blockPostAuthor", userId: currentUserId)
            reportError = error.userFriendlyMessage
        }
    }
}
