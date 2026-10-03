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

    /// 取得世代トークン。`fetchPosts` のたびに +1 し、await 復帰後に世代が一致する場合のみ
    /// 結果を反映する。絞り込み/並び替えチップの連打で古い（先着の）取得結果が新しい表示を
    /// 上書きし、posts と選択中の状態が食い違う不具合を防ぐ（レビュー F4）。
    private var fetchGeneration = 0

    /// 1 回の読み込みで読み進める最大ページ数 ⭐️
    ///
    /// 全件が壊れていて変換後 0 件になったページでは、画面の「最後の投稿が見えたら次を読む」
    /// きっかけが生まれず、無限スクロールが止まってしまう。そこで表示できる投稿が出るまで
    /// 次のページを読み進めるが、壊れた投稿が大量に続いても読み取りが膨らまないよう上限を設ける。
    static let maxPagesPerLoad = 3

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
        // この取得の世代を確定。await 中により新しい fetchPosts が走ったら、こちらの結果は破棄する。
        fetchGeneration += 1
        let generation = fetchGeneration

        isLoading = true
        errorMessage = nil
        lastError = nil
        posts = []
        lastDocument = nil
        hasMorePosts = true

        do {
            let result = try await fetchVisiblePage(
                after: nil,
                generation: generation,
                operationName: "\(viewModelName).fetchPosts"
            )
            // 古い取得（await 中に新しい fetchPosts が始まった）の結果は捨てる。
            // 最新世代がローディング解除・表示更新を担うため、ここでは何もせず抜ける。
            guard generation == fetchGeneration else { return }
            posts = result.posts
            lastDocument = result.lastDocument
            lastError = nil

            // 続きの有無は「実際に読んだドキュメント数」で決まる isExhausted で判定する。
            // 取得件数（posts.count）で判定すると、壊れた投稿を飛ばしただけの満杯のページでも
            // 「続きなし」と誤判定して無限スクロールが止まる
            hasMorePosts = !result.isExhausted
        } catch {
            guard generation == fetchGeneration else { return }
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

        // このページングが属する取得世代。await 中に fetchPosts が走って世代が変わったら、
        // 取得済みの旧ページを新しい一覧へ append しないよう破棄する。
        let generation = fetchGeneration

        isLoadingMore = true
        errorMessage = nil
        // 世代不一致で早期 return しても追加読み込みが恒久ブロックされないよう、必ず解除する。
        defer { isLoadingMore = false }

        do {
            let result = try await fetchVisiblePage(
                after: lastDocument,
                generation: generation,
                operationName: "\(viewModelName).loadMorePosts"
            )

            // 途中で fetchPosts（絞り込み変更など）が走っていたら、この旧ページは捨てる。
            guard generation == fetchGeneration else { return }

            posts.append(contentsOf: result.posts)
            // カーソルは投稿が 0 件でも進める（上限で止まった全件壊れのページを、次回また読み直さないため）。
            // 1 件も読めなかった（＝続きなし）ときだけは nil なので、位置を変えない
            if let nextCursor = result.lastDocument {
                lastDocument = nextCursor
            }
            // 続きの有無は isExhausted で判定する（fetchPosts と同じ理由）
            hasMorePosts = !result.isExhausted
        } catch {
            guard generation == fetchGeneration else { return }
            // エラーをログに記録
            ErrorHandler.logError(error, context: "\(viewModelName).loadMorePosts")
            // エラーオブジェクトを保持（ErrorStateView用）
            lastError = error
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
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

    // MARK: - Page Loading

    /// 表示できる投稿が 1 件以上あるページを取得する ⭐️
    ///
    /// 変換後 0 件（ページ内の全件が壊れている）なのに続きがあるときは、カーソルを進めて
    /// 次のページを読む。表示できる投稿が出る・続きが無くなる・`maxPagesPerLoad` に達する・
    /// 新しい fetchPosts が始まる、のいずれかでその時点のページを返す
    /// （上限で止まったときは「続きありの空ページ」になり、次のスクロールでまた続きを読む）。
    /// - Parameters:
    ///   - cursor: 読み始めの位置（nil なら最初のページ）
    ///   - generation: 呼び出し元の取得世代（変わったら読み進めをやめる）
    ///   - operationName: リトライ・ログ用の操作名
    /// - Returns: 最後に読んだページ（カーソルと続きの有無もそのページのもの）
    private func fetchVisiblePage(
        after cursor: DocumentSnapshot?,
        generation: Int,
        operationName: String
    ) async throws -> PostPage {
        var nextCursor = cursor
        var pagesRead = 0
        while true {
            let pageCursor = nextCursor
            // リトライ可能な操作として実行
            let page = try await RetryableOperation.executeIfRetryable(
                operation: { [self] in try await self.executeQuery(lastDocument: pageCursor) },
                operationName: operationName
            )
            pagesRead += 1
            if !page.posts.isEmpty || page.isExhausted || pagesRead >= Self.maxPagesPerLoad
                || generation != fetchGeneration
            {
                return page
            }
            // 全件が壊れていたページ。飛ばした分も含めて読んだ位置から続きを読む
            nextCursor = page.lastDocument
        }
    }

    // MARK: - Query Hook（サブクラスでオーバーライド可能）

    /// Firestoreクエリを実行する
    ///
    /// デフォルトでは `fetchPostsWithSnapshot` を使用。
    /// サブクラスでオーバーライドして、ユーザー投稿のみ取得する等のカスタムクエリを実装可能。
    /// - Parameter lastDocument: ページネーション用の最後のドキュメント（nilなら最初のページ）
    /// - Returns: 取得した投稿・最後のドキュメント・続きの有無
    func executeQuery(lastDocument: DocumentSnapshot?) async throws -> PostPage {
        return try await firestoreService.fetchPostsWithSnapshot(
            limit: pageSize,
            lastDocument: lastDocument
        )
    }
}
