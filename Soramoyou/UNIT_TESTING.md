# ユニットテスト ドキュメント

このドキュメントでは、そらもようアプリで実装されているユニットテストについて説明します。

## 概要

ユニットテストは、個々のコンポーネント（サービス、ViewModel、モデル）の動作を検証するために実装されています。すべてのテストは`SoramoyouTests`ターゲットに含まれています。

## テストカバレッジ

### AuthService Tests

**ファイル**: `AuthServiceTests.swift`

**テストケース**:
- ✅ 初期化テスト
- ✅ ログインのバリデーションテスト
  - 空のメールアドレス
  - 空のパスワード
  - 無効なメールアドレス形式
  - 有効なメールアドレス形式
- ✅ 新規登録のバリデーションテスト
  - 空のメールアドレス
  - 空のパスワード
  - 無効なメールアドレス形式
  - 弱いパスワード（6文字未満）
  - 有効なパスワード（6文字以上）
- ✅ エラーマッピングテスト
  - Email already in use (17007)
  - Invalid email (17008)
  - Wrong password (17009)
  - User not found (17010)
  - Weak password (17011)
  - Network error (17020)
  - Unknown error
- ✅ 現在のユーザー取得テスト（未認証時）

**注意**: 実際のFirebase Authenticationを使用する統合テストは、テスト環境でのFirebase設定が必要なため、統合テストとして実装されています。

### AuthViewModel Tests

**ファイル**: `AuthViewModelTests.swift`

**テストケース**:
- ✅ 初期状態のテスト
- ✅ ログイン成功のテスト
- ✅ ログイン失敗のテスト
- ✅ 新規登録成功のテスト
- ✅ ログアウトのテスト

**モック**: `MockAuthService`を使用してFirebase Authenticationをモック化

### ImageService Tests

**ファイル**: `ImageServiceTests.swift`

**テストケース**:
- ✅ 初期化テスト
- ✅ 画像リサイズテスト
- ✅ 画像圧縮テスト
- ✅ フィルター適用テスト（各フィルタータイプ）
- ✅ 編集ツール適用テスト（各ツールタイプ）
- ✅ EXIFデータ抽出テスト
- ✅ 色抽出テスト
- ✅ 色温度計算テスト
- ✅ 空の種類検出テスト

### FirestoreService Tests

**ファイル**: `FirestoreServiceTests.swift`

**テストケース**:
- ✅ 初期化テスト
- ✅ 投稿作成テスト
- ✅ 投稿取得テスト
- ✅ 投稿削除テスト
- ✅ 下書き保存テスト
- ✅ 下書き取得テスト
- ✅ 下書き削除テスト
- ✅ ユーザー取得テスト
- ✅ ユーザー更新テスト
- ✅ 編集ツール更新テスト
- ✅ ユーザー投稿取得テスト
- ✅ ハッシュタグ検索テスト
- ✅ 色検索テスト
- ✅ 時間帯検索テスト
- ✅ 空の種類検索テスト

**注意**: 実際のFirestoreを使用するテストは、テスト環境でのFirebase設定が必要です。

### StorageService Tests

**ファイル**: `StorageServiceTests.swift`

**テストケース**:
- ✅ 初期化テスト
- ✅ 画像アップロードテスト
- ✅ サムネイルアップロードテスト
- ✅ 画像削除テスト
- ✅ アップロード進捗監視テスト

**注意**: 実際のFirebase Storageを使用するテストは、テスト環境でのFirebase設定が必要です。

### ViewModel Tests

#### HomeViewModel Tests

**ファイル**: `HomeViewModelTests.swift`

**テストケース**:
- ✅ 初期状態のテスト
- ✅ 投稿取得テスト
- ✅ ページネーションテスト
- ✅ リフレッシュテスト

**モック**: `MockFirestoreServiceForHome`を使用

#### EditViewModel Tests

**ファイル**: `EditViewModelTests.swift`

**テストケース**:
- ✅ 初期化テスト
- ✅ 画像設定テスト
- ✅ フィルター適用テスト
- ✅ 編集ツール適用テスト
- ✅ プレビュー生成テスト
- ✅ 装備ツール読み込みテスト

**モック**: `MockImageService`、`MockFirestoreService`を使用

#### ProfileViewModel Tests

**ファイル**: `ProfileViewModelTests.swift`

**テストケース**:
- ✅ プロフィール読み込みテスト
- ✅ プロフィール更新テスト
- ✅ ユーザー投稿取得テスト
- ✅ 編集ツール管理テスト
  - 編集ツール追加
  - 編集ツール削除
  - 編集ツール順序変更
  - 編集ツール更新

**モック**: `MockFirestoreServiceForProfile`、`MockStorageService`を使用

#### SearchViewModel Tests

**ファイル**: `SearchViewModelTests.swift`

**テストケース**:
- ✅ 初期状態のテスト
- ✅ ハッシュタグ検索テスト
- ✅ 色検索テスト
- ✅ 時間帯検索テスト
- ✅ 空の種類検索テスト
- ✅ 複合検索テスト

**モック**: `MockFirestoreServiceForSearch`を使用

### Model Tests

#### UserModel Tests

**ファイル**: `UserModelTests.swift`

**テストケース**:
- ✅ 初期化テスト
- ✅ Codable準拠テスト
- ✅ Firestoreマッピングテスト

### AdService Tests

**ファイル**: `AdServiceTests.swift`

**テストケース**:
- ✅ 初期化テスト
- ✅ バナー広告読み込みテスト

## テスト実行方法

### Xcodeで実行

1. Xcodeでプロジェクトを開く
2. `Cmd + U`を押してすべてのテストを実行
3. または、テストナビゲーター（`Cmd + 6`）から個別のテストを実行

### コマンドラインで実行

```bash
# すべてのテストを実行
xcodebuild test -scheme Soramoyou -destination 'platform=iOS Simulator,name=iPhone 15'

# 特定のテストクラスのみ実行
xcodebuild test -scheme Soramoyou -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SoramoyouTests/AuthServiceTests
```

## モックの実装

### MockAuthService

`AuthViewModelTests.swift`で定義されています。`AuthServiceProtocol`を実装し、テスト用の結果を返します。

```swift
class MockAuthService: AuthServiceProtocol {
    var signInResult: Result<User, Error>?
    var signUpResult: Result<User, Error>?
    var signOutError: Error?
    var currentUserValue: User?
    
    // 実装...
}
```

### MockFirestoreService

各ViewModelテストで使用されるモック実装です。テスト用のデータを返します。

### MockImageService

`EditViewModelTests.swift`で定義されています。画像処理をモック化します。

### MockStorageService

`ProfileViewModelTests.swift`で定義されています。ストレージ操作をモック化します。

## テストのベストプラクティス

1. **AAA パターン**: Arrange（Given）、Act（When）、Assert（Then）のパターンを使用
2. **モックの使用**: 外部依存（Firebase、ネットワーク）をモック化
3. **テストの独立性**: 各テストは独立して実行可能
4. **クリーンアップ**: `tearDown`でリソースをクリーンアップ
5. **明確なテスト名**: テスト名で何をテストしているか明確に

## テストカバレッジの確認

### Xcodeで確認

1. `Cmd + 9`でテストナビゲーターを開く
2. テストを実行
3. レポートビューアーでカバレッジを確認

### コマンドラインで確認

```bash
xcodebuild test -scheme Soramoyou -destination 'platform=iOS Simulator,name=iPhone 15' -enableCodeCoverage YES
```

## 今後の改善

- **統合テスト**: 実際のFirebaseサービスを使用する統合テスト
- **E2Eテスト**: UIテストの実装
- **パフォーマンステスト**: パフォーマンスメトリクスのテスト
- **スナップショットテスト**: UIコンポーネントのスナップショットテスト

## 注意事項

1. **Firebase設定**: 実際のFirebaseサービスを使用するテストは、テスト環境でのFirebase設定が必要です
2. **非同期テスト**: `async/await`を使用するテストは`XCTest`の非同期テスト機能を使用
3. **メインスレッド**: ViewModelのテストは`@MainActor`を使用してメインスレッドで実行


