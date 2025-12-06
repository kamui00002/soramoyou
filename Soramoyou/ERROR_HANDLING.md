# エラーハンドリング ドキュメント

このドキュメントでは、そらもようアプリで使用するエラーハンドリングシステムについて説明します。

## 概要

統一的なエラーハンドリングシステムを実装し、以下の機能を提供します：

1. **エラーの分類**: ユーザーエラー（4xx）、システムエラー（5xx）、ビジネスロジックエラー（422）
2. **ユーザーフレンドリーなメッセージ**: エラーメッセージを分かりやすく表示
3. **リトライ機能**: システムエラーに対して自動リトライ（指数バックオフ）
4. **ロギング**: エラーをログに記録して監視

## エラーの分類

### ErrorCategory

エラーは以下の3つのカテゴリに分類されます：

- **userError (4xx)**: ユーザーエラー
  - 入力検証エラー
  - 認証エラー
  - 権限エラー
  - 例: `AuthError`, `PhotoSelectionError`

- **systemError (5xx)**: システムエラー
  - ネットワークエラー
  - Firebaseサービスエラー
  - 画像処理エラー
  - 例: `FirestoreServiceError`, `StorageServiceError`, `ImageServiceError`

- **businessError (422)**: ビジネスロジックエラー
  - 投稿制限違反
  - 編集ツール制限違反
  - 状態違反
  - 例: 将来的に実装予定

## ErrorHandler

### エラーの分類

```swift
let category = ErrorHandler.categorize(error)
```

エラーを自動的に分類します。

### ユーザーフレンドリーなメッセージ

```swift
let message = ErrorHandler.getUserFriendlyMessage(error)
```

エラーメッセージをユーザーに分かりやすく表示します。

### エラーのログ記録

```swift
ErrorHandler.logError(error, context: "HomeViewModel.fetchPosts", userId: userId)
```

エラーをログに記録します。コンテキストとユーザーIDを含めることで、デバッグが容易になります。

### リトライ可能かどうかの判定

```swift
let isRetryable = ErrorHandler.isRetryable(error)
```

エラーがリトライ可能かどうかを判定します。システムエラーのみリトライ可能です。

### リトライの実行

```swift
let result = try await ErrorHandler.retry(
    maxAttempts: 3,
    initialDelay: 1.0,
    operation: {
        try await firestoreService.fetchPosts()
    }
)
```

指数バックオフを使用してリトライを実行します。

## RetryableOperation

### リトライ可能な操作の実行

```swift
let result = try await RetryableOperation.executeIfRetryable {
    try await firestoreService.fetchPosts()
}
```

リトライ可能なエラーの場合のみ自動的にリトライを実行します。

## 使用方法

### ViewModelでの使用例

```swift
func fetchPosts() async {
    isLoading = true
    errorMessage = nil
    
    do {
        // リトライ可能な操作として実行
        let result = try await RetryableOperation.executeIfRetryable {
            try await firestoreService.fetchPostsWithSnapshot(limit: pageSize, lastDocument: nil)
        }
        posts = result.posts
        lastDocument = result.lastDocument
    } catch {
        // エラーをログに記録
        ErrorHandler.logError(error, context: "HomeViewModel.fetchPosts")
        // ユーザーフレンドリーなメッセージを表示
        errorMessage = error.userFriendlyMessage
    }
    
    isLoading = false
}
```

### エラー拡張の使用

```swift
// エラーのカテゴリを取得
let category = error.category

// ユーザーフレンドリーなメッセージを取得
let message = error.userFriendlyMessage

// リトライ可能かどうかを判定
let isRetryable = error.isRetryable
```

## エラーハンドリングのパターン

### 1. ユーザーエラー（4xx）

ユーザーエラーは即座にユーザーに表示し、リトライしません。

```swift
catch {
    ErrorHandler.logError(error, context: "AuthViewModel.signIn")
    errorMessage = error.userFriendlyMessage
    throw error
}
```

### 2. システムエラー（5xx）

システムエラーは自動的にリトライし、失敗した場合はユーザーに表示します。

```swift
do {
    let result = try await RetryableOperation.executeIfRetryable {
        try await firestoreService.fetchPosts()
    }
} catch {
    ErrorHandler.logError(error, context: "HomeViewModel.fetchPosts")
    errorMessage = error.userFriendlyMessage
}
```

### 3. ビジネスロジックエラー（422）

ビジネスロジックエラーは即座にユーザーに表示し、リトライしません。

```swift
catch {
    ErrorHandler.logError(error, context: "PostViewModel.savePost")
    errorMessage = error.userFriendlyMessage
    throw error
}
```

## リトライ戦略

### 指数バックオフ

リトライは指数バックオフを使用します：

- 1回目: 1秒待機
- 2回目: 2秒待機
- 3回目: 4秒待機

### 最大試行回数

デフォルトでは最大3回までリトライします。必要に応じて変更可能です。

### リトライ可能なエラー

以下のエラーのみリトライ可能です：

- ネットワークエラー（NSURLErrorDomain）
- FirestoreServiceError
- StorageServiceError
- ImageServiceError

## ロギング

### ログレベル

エラーのカテゴリに応じてログレベルが設定されます：

- **userError**: INFO（情報）
- **systemError**: ERROR（エラー）
- **businessError**: WARNING（警告）

### ログに記録される情報

- エラーのカテゴリ
- コンテキスト（どの操作で発生したか）
- ユーザーID（利用可能な場合）
- エラーメッセージ
- エラーの詳細

## エラーメッセージのカスタマイズ

### LocalizedErrorの実装

各エラー型は`LocalizedError`プロトコルを実装し、`errorDescription`プロパティでユーザーフレンドリーなメッセージを提供します。

```swift
enum AuthError: LocalizedError {
    case invalidEmail
    
    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return "有効なメールアドレスを入力してください"
        }
    }
}
```

### ネットワークエラーの処理

ネットワークエラーは自動的に適切なメッセージに変換されます：

- `NSURLErrorNotConnectedToInternet`: "インターネットに接続されていません"
- `NSURLErrorTimedOut`: "接続がタイムアウトしました"
- `NSURLErrorNetworkConnectionLost`: "ネットワーク接続が失われました"

## ベストプラクティス

1. **エラーのログ記録**: すべてのエラーをログに記録し、デバッグを容易にします
2. **ユーザーフレンドリーなメッセージ**: 技術的なエラーメッセージではなく、ユーザーに分かりやすいメッセージを表示します
3. **リトライの適切な使用**: システムエラーのみリトライし、ユーザーエラーやビジネスロジックエラーはリトライしません
4. **コンテキストの提供**: エラーログにはコンテキスト（どの操作で発生したか）を含めます
5. **ユーザーIDの記録**: 可能な場合はユーザーIDをログに記録します

## 統合されたViewModel

以下のViewModelでErrorHandlerが統合されています：

- `HomeViewModel`: 投稿の取得
- `PostViewModel`: 投稿の保存
- `AuthViewModel`: 認証操作
- `SearchViewModel`: 検索操作
- `ProfileViewModel`: プロフィールの読み込み・更新
- `EditViewModel`: 画像編集
- `DraftsViewModel`: 下書きの管理

## 今後の改善

- **Firebase Crashlyticsの統合**: エラーをCrashlyticsに送信（タスク15.2）
- **エラー分析**: エラーの発生頻度とパターンを分析
- **自動リトライの最適化**: リトライ戦略の改善
- **エラーメッセージの多言語対応**: 国際化対応


