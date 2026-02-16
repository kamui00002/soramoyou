//
//  LoadableState.swift ⭐️☁️
//  Soramoyou
//
//  非同期データ読み込みの状態を表す共通enum
//  各画面で統一されたエラー/ローディング/コンテンツ表示を実現する
//

import Foundation

/// 非同期データの読み込み状態を表すジェネリックenum
///
/// 画面ごとにバラバラだったエラー/ローディング表示を統一するための基盤。
/// ViewModelで `@Published var state: LoadableState<T>` として使用し、
/// Viewでは `AsyncContentView` と組み合わせて自動的に状態を切り替える。
///
/// ## 使用例
/// ```swift
/// @Published var state: LoadableState<[Post]> = .idle
///
/// func fetchPosts() async {
///     state = .loading
///     do {
///         let posts = try await service.fetchPosts()
///         state = .loaded(posts)
///     } catch {
///         state = .error(error)
///     }
/// }
/// ```
enum LoadableState<T> {
    /// 初期状態（まだ読み込みを開始していない）
    case idle
    /// 読み込み中
    case loading
    /// 読み込み完了（データを保持）
    case loaded(T)
    /// エラー発生
    case error(Error)
}

// MARK: - 便利なプロパティ ⭐️

extension LoadableState {
    /// 読み込み中かどうか
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// 読み込みが完了しているかどうか
    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    /// エラー状態かどうか
    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    /// 読み込み完了時のデータを取得（nilの場合あり）
    var data: T? {
        if case .loaded(let data) = self { return data }
        return nil
    }

    /// エラーオブジェクトを取得（nilの場合あり）
    var currentError: Error? {
        if case .error(let error) = self { return error }
        return nil
    }
}

// MARK: - ロード状態の変換ヘルパー ⭐️

extension LoadableState {
    /// データの型を変換する（map操作）
    ///
    /// 例: `LoadableState<[Post]>` を `LoadableState<Int>` (投稿数) に変換
    /// ```swift
    /// let countState = postsState.map { $0.count }
    /// ```
    func map<U>(_ transform: (T) -> U) -> LoadableState<U> {
        switch self {
        case .idle:
            return .idle
        case .loading:
            return .loading
        case .loaded(let data):
            return .loaded(transform(data))
        case .error(let error):
            return .error(error)
        }
    }
}
