# ロギングとモニタリング ドキュメント

このドキュメントでは、そらもようアプリで使用するロギングとモニタリングシステムについて説明します。

## 概要

Firebase CrashlyticsとFirebase Analyticsを統合し、以下の機能を提供します：

1. **クラッシュレポート**: クラッシュとエラーをCrashlyticsに記録
2. **エラー分析**: Firebase Analyticsでエラーの発生頻度とパターンを分析
3. **リトライ統計**: ネットワークエラーのリトライ回数と成功率を記録
4. **機密情報の保護**: ログに機密情報が含まれないように自動的に除外

## Firebase Crashlytics

### 統合

Firebase Crashlyticsは`SoramoyouApp.swift`で初期化され、`LoggingService`を通じて使用されます。

### 機能

1. **クラッシュレポート**: アプリのクラッシュを自動的に記録
2. **非致命的なエラー**: エラーを記録して分析
3. **カスタムキー**: エラーのコンテキスト情報を記録
4. **ユーザーID**: エラーをユーザーごとに追跡

### 使用方法

```swift
// エラーを記録
LoggingService.shared.recordError(error, context: "HomeViewModel.fetchPosts", userId: userId)

// 非致命的なエラーを記録
LoggingService.shared.recordNonFatalError(error, context: "PostViewModel.savePost", userId: userId)

// カスタムログを記録
LoggingService.shared.log("Operation completed", level: .info)
```

## Firebase Analytics

### 統合

Firebase Analyticsは`LoggingService`を通じて使用され、イベントとエラーを記録します。

### 機能

1. **エラーイベント**: エラーの発生をイベントとして記録
2. **リトライ統計**: ネットワークエラーのリトライ回数と成功率を記録
3. **ユーザープロパティ**: ユーザー情報を記録
4. **カスタムイベント**: アプリの重要なイベントを記録

### 使用方法

```swift
// イベントを記録
LoggingService.shared.logEvent("post_created", parameters: ["post_id": postId])

// エラーイベントを記録
LoggingService.shared.logErrorEvent(error, context: "HomeViewModel.fetchPosts", category: .systemError)

// リトライイベントを記録
LoggingService.shared.logRetryEvent(
    operation: "fetchPosts",
    attempt: 2,
    success: true
)

// ネットワークリトライ統計を記録
LoggingService.shared.logNetworkRetryStats(
    operation: "fetchPosts",
    totalAttempts: 3,
    success: true
)
```

## 機密情報の除外

### 自動除外

`LoggingService`は以下の機密情報を自動的に除外します：

1. **メールアドレス**: 正規表現で検出して`[EMAIL_REDACTED]`に置換
2. **パスワード**: `password`, `passwd`, `pwd`を含む文字列を`[PASSWORD_REDACTED]`に置換
3. **トークン**: `token`, `api_key`, `secret`を含む文字列を`[TOKEN_REDACTED]`に置換

### 実装

```swift
// 機密情報を除外したコンテキストを返す
private func sanitizeContext(_ context: String?) -> String? {
    guard let context = context else { return nil }
    
    var sanitized = context
    
    // メールアドレスを除外
    sanitized = sanitized.replacingOccurrences(
        of: #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#,
        with: "[EMAIL_REDACTED]",
        options: .regularExpression
    )
    
    // パスワードを除外
    sanitized = sanitized.replacingOccurrences(
        of: #"(?i)(password|passwd|pwd)\s*[:=]\s*[^\s]+"#,
        with: "[PASSWORD_REDACTED]",
        options: .regularExpression
    )
    
    // トークンを除外
    sanitized = sanitized.replacingOccurrences(
        of: #"(?i)(token|api[_-]?key|secret)\s*[:=]\s*[^\s]+"#,
        with: "[TOKEN_REDACTED]",
        options: .regularExpression
    )
    
    return sanitized
}
```

## ErrorHandlerとの統合

### エラーの記録

`ErrorHandler`は自動的に`LoggingService`を使用してエラーを記録します：

- **システムエラー**: Crashlyticsに致命的なエラーとして記録
- **ビジネスロジックエラー**: Crashlyticsに非致命的なエラーとして記録
- **すべてのエラー**: Firebase Analyticsにイベントとして記録

### リトライ統計の記録

`ErrorHandler.retry()`は自動的にリトライ統計を記録します：

- **リトライイベント**: 各リトライ試行を記録
- **ネットワークリトライ統計**: リトライの成功/失敗を記録

## ユーザーIDの設定

### 認証時の設定

`AuthViewModel`は認証成功時に自動的にユーザーIDを設定します：

```swift
// ログイン成功時
LoggingService.shared.setUserID(user.id)

// ログアウト時
LoggingService.shared.setUserID(nil)
```

### 手動設定

必要に応じて手動でユーザーIDを設定できます：

```swift
LoggingService.shared.setUserID(userId)
```

## ログレベル

### LogLevel

- **debug**: デバッグ情報（開発時のみ）
- **info**: 一般的な情報
- **warning**: 警告（Crashlyticsにも記録）
- **error**: エラー（Crashlyticsにも記録）

### 使用方法

```swift
LoggingService.shared.log("Operation started", level: .info)
LoggingService.shared.log("Warning occurred", level: .warning)
LoggingService.shared.log("Error occurred", level: .error)
```

## Firebase Consoleでの確認

### Crashlytics

1. Firebase Console > Crashlytics にアクセス
2. クラッシュとエラーを確認
3. カスタムキーとユーザーIDでフィルタリング
4. スタックトレースを確認

### Analytics

1. Firebase Console > Analytics > Events にアクセス
2. イベントの発生頻度を確認
3. カスタムパラメータで分析
4. ユーザープロパティでセグメント分析

## ベストプラクティス

1. **エラーの記録**: すべてのエラーを記録し、コンテキスト情報を含める
2. **機密情報の保護**: ログに機密情報が含まれないように注意
3. **ユーザーIDの設定**: 認証成功時にユーザーIDを設定
4. **リトライ統計の記録**: ネットワークエラーのリトライ統計を記録
5. **イベントの記録**: アプリの重要なイベントを記録

## デバッグモード

### デバッグビルドでの動作

デバッグビルドでもCrashlyticsは有効です（開発中もエラーを記録）。

必要に応じて、デバッグモードでCrashlyticsを無効化できます：

```swift
#if DEBUG
// Crashlyticsを無効化（オプション）
#else
// 本番ビルドでは常に有効
#endif
```

## セットアップ手順

### 1. Firebase Consoleでの設定

1. Firebase Console > プロジェクト設定 > 統合 にアクセス
2. Crashlyticsを有効化
3. Analyticsを有効化

### 2. Xcodeプロジェクトの設定

1. Xcodeでプロジェクトを開く
2. ターゲット > Build Phases > Run Script を開く
3. 以下のスクリプトを追加：

```bash
"${PODS_ROOT}/FirebaseCrashlytics/run"
```

### 3. Package.swiftの確認

`Package.swift`に以下が含まれていることを確認：

```swift
.product(name: "FirebaseCrashlytics", package: "firebase-ios-sdk"),
.product(name: "FirebaseAnalytics", package: "firebase-ios-sdk"),
```

## トラブルシューティング

### Crashlyticsが動作しない

1. Firebase ConsoleでCrashlyticsが有効化されているか確認
2. `GoogleService-Info.plist`が正しく配置されているか確認
3. XcodeのRun Scriptが正しく設定されているか確認

### Analyticsが動作しない

1. Firebase ConsoleでAnalyticsが有効化されているか確認
2. `GoogleService-Info.plist`が正しく配置されているか確認
3. イベントが正しく記録されているかFirebase Consoleで確認

## 今後の改善

- **カスタムダッシュボード**: エラーとリトライ統計のカスタムダッシュボード
- **アラート設定**: エラー率が閾値を超えた場合のアラート
- **パフォーマンス監視**: アプリのパフォーマンスメトリクスの記録
- **A/Bテスト**: Firebase Remote Configとの統合


