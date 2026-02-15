//
//  PaginatedPostsViewModel.swift
//  Soramoyou
//
//  Created on 2026-02-10.
//
//  ページネーション付き投稿取得の共通基盤ViewModel ⭐️
//  HomeViewModelとGalleryViewModelの重複ロジックを統合

import Foundation
import FirebaseFirestore
import Combine

/// ページネーション付き投稿取得の共通基盤クラス
///
/// サブクラスは `viewModelName` と `pageSize` をオーバーライドして
/// 各画面固有の設定を提供する。
/// クエリ構築はデフォルトで `fetchPostsWithSnapshot` を使用するが、
/// サブクラスでオーバーライドして独自のクエリを使用することも可能。
@MainActor
class PaginatedPostsViewModel: ObservableObject {
    // MARK: - Published Properties（ビューからバインド可能）

    /// 取得した投稿一覧
    @Published var posts: [Post] = []
    /// 初回読み込み中かどうか
    @Published var isLoading = false
    /// 追加読み込み中かどうか
    @Published var isLoadingMore = false
    /// ユーザー向けエラーメッセージ
    @Published var errorMessage: String?
    /// エラーオブジェクトを保持（ErrorStateView用）☁️
    @Published var lastError: Error?
    /// さらに読み込める投稿があるかどうか
    @Published var hasMorePosts = true

    // MARK: - Internal Properties

    /// Firestoreサービス（依存注入対応）
    let firestoreService: FirestoreServiceProtocol
    /// ページネーション用の最後のドキュメントスナップショット
    var lastDocument: DocumentSnapshot?

    // MARK: - Computed Properties（サブクラスでオーバーライド）

    /// ViewModel名（エラーログのコンテキストに使用）
    var viewModelName: String { "PaginatedPostsViewModel" }

    /// 1ページあたりの取得件数
    var pageSize: Int { 20 }

    // MARK: - Initialization

    /// 初期化
    /// - Parameter firestoreService: Firestoreサービス（テスト時にモックを注入可能）
    init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.firestoreService = firestoreService
    }

    // MARK: - Fetch Posts（初回読み込み）

    /// 投稿を取得（初回読み込み）☁️
    ///
    /// 既存の投稿をクリアしてから最初のページを取得する。
    /// サブクラスでクエリをカスタマイズしたい場合は `executeQuery` をオーバーライドする。
    func fetchPosts() async {
        isLoading = true
        errorMessage = nil
        lastError = nil
        posts = []
        lastDocument = nil
        hasMorePosts = true

        do {
            // リトライ可能な操作として実行
            let result = try await RetryableOperation.executeIfRetryable(
                operationName: "\(viewModelName).fetchPosts"
            ) { [self] in
                try await self.executeQuery(lastDocument: nil)
            }
            posts = result.posts
            lastDocument = result.lastDocument
            lastError = nil

            // 取得件数がページサイズ未満なら、これ以上投稿はない
            if result.posts.count < pageSize {
                hasMorePosts = false
            }
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "\(viewModelName).fetchPosts")
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
            lastError = error
        }

        isLoading = false
    }

    // MARK: - Load More Posts（ページネーション）

    /// 次のページの投稿を取得（ページネーション）
    ///
    /// 既に読み込み中、またはこれ以上投稿がない場合はスキップする。
    func loadMorePosts() async {
        guard !isLoadingMore && hasMorePosts else { return }

        isLoadingMore = true
        errorMessage = nil

        do {
            // リトライ可能な操作として実行
            let result = try await RetryableOperation.executeIfRetryable(
                operationName: "\(viewModelName).loadMorePosts"
            ) { [self] in
                try await self.executeQuery(lastDocument: self.lastDocument)
            }

            if result.posts.isEmpty {
                hasMorePosts = false
            } else {
                posts.append(contentsOf: result.posts)
                lastDocument = result.lastDocument

                // 取得件数がページサイズ未満なら、これ以上投稿はない
                if result.posts.count < pageSize {
                    hasMorePosts = false
                }
            }
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "\(viewModelName).loadMorePosts")
            // エラーオブジェクトを保持（ErrorStateView用）
            lastError = error
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }

        isLoadingMore = false
    }

    // MARK: - Refresh

    /// 投稿をリフレッシュ（プルトゥリフレッシュ用）
    func refresh() async {
        await fetchPosts()
    }

    // MARK: - Fetch Single Post

    /// 特定の投稿を取得
    /// - Parameter postId: 取得する投稿のID
    /// - Returns: 投稿データ
    func fetchPost(postId: String) async throws -> Post {
        return try await firestoreService.fetchPost(postId: postId)
    }

    // MARK: - LoadableState変換（AsyncContentView連携用）⭐️

    /// 現在の状態をLoadableStateに変換する
    ///
    /// AsyncContentViewと組み合わせて使用することで、
    /// ローディング/エラー/コンテンツの表示を統一できる。
    /// ```swift
    /// AsyncContentView(state: viewModel.loadableState) { posts in
    ///     // コンテンツ表示
    /// } onRetry: {
    ///     await viewModel.refresh()
    /// }
    /// ```
    var loadableState: LoadableState<[Post]> {
        if isLoading && posts.isEmpty {
            return .loading
        } else if let error = lastError, posts.isEmpty {
            return .error(error)
        } else {
            return .loaded(posts)
        }
    }

    // MARK: - Query Hook（サブクラスでオーバーライド可能）

    /// Firestoreクエリを実行する
    ///
    /// デフォルトでは `fetchPostsWithSnapshot` を使用。
    /// サブクラスでオーバーライドして、ユーザー投稿のみ取得する等のカスタムクエリを実装可能。
    /// - Parameter lastDocument: ページネーション用の最後のドキュメント（nilなら最初のページ）
    /// - Returns: 取得した投稿と最後のドキュメントのタプル
    func executeQuery(lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        return try await firestoreService.fetchPostsWithSnapshot(
            limit: pageSize,
            lastDocument: lastDocument
        )
    }
}
