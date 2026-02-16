//
//  AsyncContentView.swift ⭐️☁️
//  Soramoyou
//
//  LoadableStateに応じてローディング/エラー/コンテンツを自動切替するジェネリックView
//  既存のLoadingStateView・ErrorStateView・EmptyStateViewを活用して統一的なUIを提供
//

import SwiftUI

/// LoadableStateに応じて自動的にUI状態を切り替えるジェネリックView
///
/// 各画面でバラバラだったローディング/エラー/コンテンツ表示を
/// 1つのコンポーネントに統合し、統一的なUXを提供する。
///
/// ## 基本的な使い方
/// ```swift
/// AsyncContentView(state: viewModel.state) { posts in
///     // 読み込み完了時のコンテンツ
///     ForEach(posts) { post in
///         PostCard(post: post)
///     }
/// } onRetry: {
///     await viewModel.fetchPosts()
/// }
/// ```
///
/// ## カスタマイズ例（空の状態を指定）
/// ```swift
/// AsyncContentView(
///     state: viewModel.state,
///     loadingType: .initial,
///     emptyCheck: { $0.isEmpty },
///     emptyStateType: .posts
/// ) { posts in
///     // コンテンツ
/// } onRetry: {
///     await viewModel.fetchPosts()
/// }
/// ```
struct AsyncContentView<T, Content: View>: View {
    /// 現在の読み込み状態
    let state: LoadableState<T>

    /// ローディング表示のタイプ（デフォルト: initial）
    var loadingType: LoadingType = .initial

    /// データが空かどうかを判定するクロージャ（nilの場合は空チェックしない）
    var emptyCheck: ((T) -> Bool)?

    /// 空の状態を表示するタイプ（nilの場合はEmptyStateViewを表示しない）
    var emptyStateType: EmptyStateType?

    /// 空の状態でのアクション
    var emptyAction: (() -> Void)?

    /// リトライアクション
    var onRetry: (() async -> Void)?

    /// 読み込み完了時に表示するコンテンツ
    @ViewBuilder let content: (T) -> Content

    var body: some View {
        switch state {
        case .idle:
            // 初期状態: 何も表示しない（または薄いローディング）
            Color.clear

        case .loading:
            // ローディング中: 統一されたLoadingStateViewを使用
            LoadingStateView(type: loadingType)

        case .loaded(let data):
            // データが空かどうかチェック
            if let emptyCheck = emptyCheck, emptyCheck(data) {
                // 空の状態
                if let emptyStateType = emptyStateType {
                    EmptyStateView(type: emptyStateType, action: emptyAction)
                } else {
                    // emptyStateTypeが未指定の場合はデフォルトの空表示
                    EmptyStateView(
                        type: .custom(
                            icon: "tray",
                            title: "データがありません",
                            description: "まだデータがありません",
                            actionTitle: nil
                        )
                    )
                }
            } else {
                // データあり: コンテンツを表示
                content(data)
            }

        case .error(let error):
            // エラー: 統一されたErrorStateViewを使用
            // ErrorHandler.isRetryable を活用してリトライ可否を自動判定
            ErrorStateView(
                error: error,
                retryAction: onRetry
            )
        }
    }
}

// MARK: - 簡略化イニシャライザ ⭐️

extension AsyncContentView {
    /// 空チェックなしの簡略化イニシャライザ
    ///
    /// データが常に存在する場合（単一オブジェクトの取得など）に使用
    /// ```swift
    /// AsyncContentView(state: viewModel.userState) { user in
    ///     ProfileContent(user: user)
    /// } onRetry: {
    ///     await viewModel.fetchUser()
    /// }
    /// ```
    init(
        state: LoadableState<T>,
        loadingType: LoadingType = .initial,
        onRetry: (() async -> Void)? = nil,
        @ViewBuilder content: @escaping (T) -> Content
    ) {
        self.state = state
        self.loadingType = loadingType
        self.emptyCheck = nil
        self.emptyStateType = nil
        self.emptyAction = nil
        self.onRetry = onRetry
        self.content = content
    }

    /// コレクション型のデータ用イニシャライザ（空チェック付き）
    ///
    /// 配列などのコレクションが空の場合にEmptyStateViewを表示
    /// ```swift
    /// AsyncContentView(
    ///     state: viewModel.postsState,
    ///     emptyStateType: .posts,
    ///     emptyAction: { /* 投稿画面へ遷移 */ }
    /// ) { posts in
    ///     ForEach(posts) { PostCard(post: $0) }
    /// } onRetry: {
    ///     await viewModel.fetchPosts()
    /// }
    /// ```
    init(
        state: LoadableState<T>,
        loadingType: LoadingType = .initial,
        emptyCheck: @escaping (T) -> Bool,
        emptyStateType: EmptyStateType,
        emptyAction: (() -> Void)? = nil,
        onRetry: (() async -> Void)? = nil,
        @ViewBuilder content: @escaping (T) -> Content
    ) {
        self.state = state
        self.loadingType = loadingType
        self.emptyCheck = emptyCheck
        self.emptyStateType = emptyStateType
        self.emptyAction = emptyAction
        self.onRetry = onRetry
        self.content = content
    }
}

// MARK: - Preview ☁️

struct AsyncContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // ローディング状態
            ZStack {
                LinearGradient(
                    colors: DesignTokens.Colors.daySkyGradient,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                AsyncContentView(state: LoadableState<[String]>.loading) { items in
                    Text("Loaded: \(items.count)")
                }
            }
            .previewDisplayName("Loading")

            // エラー状態
            ZStack {
                LinearGradient(
                    colors: DesignTokens.Colors.daySkyGradient,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                AsyncContentView(
                    state: LoadableState<[String]>.error(
                        NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
                    ),
                    onRetry: {
                        // リトライ処理
                    },
                    content: { items in
                        Text("Loaded: \(items.count)")
                    }
                )
            }
            .previewDisplayName("Error")

            // 空状態
            ZStack {
                LinearGradient(
                    colors: DesignTokens.Colors.daySkyGradient,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                AsyncContentView(
                    state: LoadableState<[String]>.loaded([]),
                    emptyCheck: { $0.isEmpty },
                    emptyStateType: .posts
                ) { items in
                    Text("Loaded: \(items.count)")
                }
            }
            .previewDisplayName("Empty")
        }
    }
}
