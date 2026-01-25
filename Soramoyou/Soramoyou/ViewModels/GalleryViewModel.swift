//
//  GalleryViewModel.swift
//  Soramoyou
//
//  Created on 2025-01-19.
//

import Foundation
import FirebaseFirestore
import Combine

@MainActor
class GalleryViewModel: ObservableObject {
    @Published var posts: [Post] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var hasMorePosts = true

    private let firestoreService: FirestoreServiceProtocol
    private var lastDocument: DocumentSnapshot?
    private let pageSize = 30  // グリッド表示用に多めに取得

    init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.firestoreService = firestoreService
    }

    // MARK: - Fetch Public Posts

    /// 公開投稿を取得（初回読み込み）
    func fetchPosts() async {
        isLoading = true
        errorMessage = nil
        posts = []
        lastDocument = nil
        hasMorePosts = true

        do {
            // リトライ可能な操作として実行
            let result = try await RetryableOperation.executeIfRetryable(
                operationName: "GalleryViewModel.fetchPosts"
            ) { [self] in
                try await self.firestoreService.fetchPostsWithSnapshot(limit: self.pageSize, lastDocument: nil)
            }
            posts = result.posts
            lastDocument = result.lastDocument

            // 最後のドキュメントを保存（ページネーション用）
            if result.posts.count < pageSize {
                hasMorePosts = false
            }
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "GalleryViewModel.fetchPosts")
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }

        isLoading = false
    }

    /// 次のページの投稿を取得（ページネーション）
    func loadMorePosts() async {
        guard !isLoadingMore && hasMorePosts else { return }

        isLoadingMore = true
        errorMessage = nil

        do {
            // リトライ可能な操作として実行
            let result = try await RetryableOperation.executeIfRetryable(
                operationName: "GalleryViewModel.loadMorePosts"
            ) { [self] in
                try await self.firestoreService.fetchPostsWithSnapshot(limit: self.pageSize, lastDocument: self.lastDocument)
            }

            if result.posts.isEmpty {
                hasMorePosts = false
            } else {
                posts.append(contentsOf: result.posts)
                lastDocument = result.lastDocument

                // 取得した投稿数がページサイズより少ない場合は、これ以上取得できない
                if result.posts.count < pageSize {
                    hasMorePosts = false
                }
            }
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "GalleryViewModel.loadMorePosts")
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }

        isLoadingMore = false
    }

    /// 投稿をリフレッシュ
    func refresh() async {
        await fetchPosts()
    }

    /// 特定の投稿を取得
    func fetchPost(postId: String) async throws -> Post {
        return try await firestoreService.fetchPost(postId: postId)
    }
}
