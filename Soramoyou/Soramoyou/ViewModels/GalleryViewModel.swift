//
//  GalleryViewModel.swift
//  Soramoyou
//
//  Created on 2025-01-19.
//
//  ギャラリー画面用ViewModel ⭐️
//  PaginatedPostsViewModelを継承し、グリッド表示に最適化された設定を提供

import Foundation
import FirebaseFirestore
import Combine

/// ギャラリー画面のViewModel
///
/// PaginatedPostsViewModelを継承し、グリッド表示に特化した設定を提供する。
/// ページサイズをホームより多め（30件）に設定してグリッド表示に最適化。
@MainActor
class GalleryViewModel: PaginatedPostsViewModel {
    // MARK: - PaginatedPostsViewModel Overrides

    /// ViewModel名（エラーログ用）
    override var viewModelName: String { "GalleryViewModel" }

    /// グリッド表示用に多めに取得（30件/ページ）
    override var pageSize: Int { 30 }
    
    /// ブロックしているユーザーIDのリスト
    private var blockedUserIds: [String] = []
    
    /// 投稿を取得（ブロックユーザーのフィルタリング付き）
    override func fetchPosts() async {
        await loadBlockedUsers()
        await super.fetchPosts()
        filterBlockedUsers()
    }
    
    /// 次のページの投稿を取得（ブロックユーザーのフィルタリング付き）
    override func loadMorePosts() async {
        await super.loadMorePosts()
        filterBlockedUsers()
    }
    
    /// ブロックユーザーリストを読み込む
    private func loadBlockedUsers() async {
        let authService = AuthService()
        guard let currentUserId = authService.currentUser()?.id else { return }
        
        do {
            blockedUserIds = try await firestoreService.fetchBlockedUserIds(userId: currentUserId)
        } catch {
            blockedUserIds = []
        }
    }
    
    /// ブロックユーザーの投稿をフィルタリング
    private func filterBlockedUsers() {
        guard !blockedUserIds.isEmpty else { return }
        posts = posts.filter { !blockedUserIds.contains($0.userId) }
    }
}
