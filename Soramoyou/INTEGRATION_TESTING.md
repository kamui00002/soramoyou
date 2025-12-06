# 統合テスト ドキュメント

このドキュメントでは、そらもようアプリで実装されている統合テストについて説明します。

## 概要

統合テストは、複数のコンポーネントが連携して動作することを検証するテストです。ユニットテストとは異なり、実際のサービス間の連携や、エンドツーエンドのフローをテストします。

## テストカバレッジ

### 認証フローのテスト

**ファイル**: `IntegrationTests.swift`

**テストケース**:
- ✅ `testAuthenticationFlow_LoginToHome()`: ログインからホーム画面遷移まで
- ✅ `testAuthenticationFlow_SignUpToHome()`: 新規登録からホーム画面遷移まで
- ✅ `testAuthenticationFlow_Logout()`: ログアウトフロー

**テスト内容**:
1. 認証サービスでログイン/新規登録を実行
2. 認証状態が正しく設定されることを確認
3. ホーム画面で投稿を取得できることを確認

### 投稿フローのテスト

**テストケース**:
- ✅ `testPostFlow_PhotoSelectionToPostSave()`: 写真選択から投稿保存まで
- ✅ `testPostFlow_DraftSave()`: 下書き保存フロー

**テスト内容**:
1. 画像を選択
2. 編集設定を適用
3. 投稿情報（キャプション、ハッシュタグ、公開設定）を設定
4. 投稿が保存可能な状態になることを確認

**注意**: 実際のFirebase StorageとFirestoreへの接続が必要なため、完全な投稿保存テストは実際のFirebase環境で実行する必要があります。

### 検索フローのテスト

**テストケース**:
- ✅ `testSearchFlow_SearchCriteriaToResults()`: 検索条件から結果表示まで
- ✅ `testSearchFlow_HashtagSearch()`: ハッシュタグ検索
- ✅ `testSearchFlow_ColorSearch()`: 色検索

**テスト内容**:
1. 検索条件（ハッシュタグ、色、時間帯、空の種類）を設定
2. 検索を実行
3. 検索結果が正しく取得されることを確認

### Firebase統合テスト

**テストケース**:
- ✅ `testFirebaseIntegration_FirestoreAndAuth()`: FirestoreとAuthenticationの連携
- ✅ `testFirebaseIntegration_StorageAndFirestore()`: StorageとFirestoreの連携（投稿保存）

**テスト内容**:
1. 認証サービスでログイン
2. Firestoreサービスでプロフィールを取得
3. サービス間の連携が正しく動作することを確認

**注意**: 実際のFirebaseサービスを使用するテストは、テスト環境でのFirebase設定が必要です。

### 完全なユーザージャーニーのテスト

**テストケース**:
- ✅ `testCompleteUserJourney_LoginPostSearch()`: ログイン → 投稿作成 → 検索

**テスト内容**:
1. ログイン
2. 投稿情報を設定
3. 検索を実行
4. エンドツーエンドのフローが正しく動作することを確認

## モックの使用

統合テストでは、実際のFirebaseサービスを使用する代わりに、モックを使用してテストを実行します。これにより、以下の利点があります：

1. **高速な実行**: ネットワーク通信が不要
2. **再現性**: テスト結果が一貫している
3. **独立性**: 外部サービスに依存しない

### 使用されるモック

- `MockAuthService`: 認証サービスをモック化
- `MockFirestoreServiceForHome`: ホーム画面用のFirestoreサービスをモック化
- `MockFirestoreServiceForSearch`: 検索用のFirestoreサービスをモック化
- `MockFirestoreServiceForProfile`: プロフィール用のFirestoreサービスをモック化

## テスト実行方法

### Xcodeで実行

1. Xcodeでプロジェクトを開く
2. テストナビゲーター（`Cmd + 6`）を開く
3. `IntegrationTests`クラスを選択
4. `Cmd + U`でテストを実行

### コマンドラインで実行

```bash
# すべての統合テストを実行
xcodebuild test -scheme Soramoyou -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SoramoyouTests/IntegrationTests

# 特定のテストケースを実行
xcodebuild test -scheme Soramoyou -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SoramoyouTests/IntegrationTests/testAuthenticationFlow_LoginToHome
```

## 実際のFirebase環境でのテスト

実際のFirebaseサービスを使用する統合テストを実行する場合は、以下の設定が必要です：

### 1. テスト環境のFirebase設定

1. Firebase Consoleでテスト用プロジェクトを作成
2. `GoogleService-Info.plist`をテストターゲットに追加
3. テスト用のFirebase設定を適用

### 2. テストデータの準備

- テスト用のユーザーアカウントを作成
- テスト用の投稿データを準備
- テスト後のクリーンアップを実装

### 3. テストの実装

```swift
func testRealFirebaseIntegration() async throws {
    // 実際のFirebaseサービスを使用
    let authService = AuthService()
    let firestoreService = FirestoreService()
    
    // テストを実行
    // ...
    
    // クリーンアップ
    // ...
}
```

## テストのベストプラクティス

1. **独立性**: 各テストは独立して実行可能
2. **クリーンアップ**: テスト後にリソースをクリーンアップ
3. **モックの使用**: 外部依存をモック化してテストを高速化
4. **エラーハンドリング**: エラーケースもテスト
5. **フローの検証**: エンドツーエンドのフローを検証

## 今後の改善

- **実際のFirebase統合テスト**: テスト環境でのFirebase設定を使用した統合テスト
- **パフォーマンステスト**: フローのパフォーマンスを測定
- **負荷テスト**: 複数のユーザーが同時に操作する場合のテスト
- **エラーシナリオのテスト**: ネットワークエラー、サービス障害などのテスト

## 注意事項

1. **Firebase設定**: 実際のFirebaseサービスを使用するテストは、テスト環境でのFirebase設定が必要です
2. **非同期テスト**: `async/await`を使用するテストは`XCTest`の非同期テスト機能を使用
3. **メインスレッド**: ViewModelのテストは`@MainActor`を使用してメインスレッドで実行
4. **モックの制限**: モックを使用したテストは、実際のサービスとの動作の違いに注意が必要です

