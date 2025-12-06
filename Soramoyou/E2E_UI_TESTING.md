# E2E/UIテスト ドキュメント

このドキュメントでは、そらもようアプリで実装されているE2E/UIテストについて説明します。

## 概要

E2E/UIテストは、ユーザーインターフェースの操作をシミュレートして、アプリのエンドツーエンドの動作を検証するテストです。XCTestのUIテスト機能を使用して実装されています。

## テストカバレッジ

### 認証のUI操作テスト

**ファイル**: `SoramoyouUITests.swift`

**テストケース**:
- ✅ `testWelcomeView_Display()`: ウェルカム画面の表示
- ✅ `testAuthenticationFlow_NavigateToLogin()`: ログイン画面への遷移
- ✅ `testAuthenticationFlow_NavigateToSignUp()`: 新規登録画面への遷移
- ✅ `testAuthenticationFlow_LoginValidationError()`: ログイン入力のバリデーションエラー

**テスト内容**:
1. ウェルカム画面の要素（タイトル、ボタン）が表示されることを確認
2. ログイン/新規登録ボタンをタップして画面遷移を確認
3. 入力フィールドが表示されることを確認
4. バリデーションエラーが表示されることを確認

### メインタブビューのテスト

**テストケース**:
- ✅ `testMainTabView_DisplayTabs()`: タブの表示
- ✅ `testMainTabView_SwitchTabs()`: タブの切り替え

**テスト内容**:
1. 各タブ（ホーム、投稿、検索、プロフィール）が表示されることを確認
2. タブをタップして切り替えが動作することを確認

### フィード表示のUI操作テスト

**テストケース**:
- ✅ `testHomeView_Display()`: ホーム画面の表示
- ✅ `testHomeView_DisplayPosts()`: 投稿の表示
- ✅ `testHomeView_PullToRefresh()`: プルリフレッシュ

**テスト内容**:
1. ホーム画面のタイトルが表示されることを確認
2. 投稿が表示されることを確認（実際のデータに依存）
3. プルリフレッシュが動作することを確認

### 投稿のUI操作テスト

**テストケース**:
- ✅ `testPostView_Display()`: 投稿画面の表示
- ✅ `testPostView_PhotoSelectionButton()`: 写真選択ボタンの表示

**テスト内容**:
1. 投稿画面のタイトルが表示されることを確認
2. 写真選択ボタンが表示されることを確認

**注意**: 実際の写真選択、編集、投稿情報入力、投稿保存のテストは、システムの写真ライブラリアクセスが必要なため、より詳細な実装が必要です。

### 検索のUI操作テスト

**テストケース**:
- ✅ `testSearchView_Display()`: 検索画面の表示
- ✅ `testSearchView_HashtagSearch()`: ハッシュタグ検索
- ✅ `testSearchView_TimeOfDaySearch()`: 時間帯検索

**テスト内容**:
1. 検索画面のタイトルが表示されることを確認
2. ハッシュタグを入力して検索を実行
3. 時間帯を選択して検索を実行
4. 検索結果が表示されることを確認（実際のデータに依存）

### プロフィールのUI操作テスト

**テストケース**:
- ✅ `testProfileView_Display()`: プロフィール画面の表示
- ✅ `testProfileView_EditMenu()`: プロフィール編集メニュー

**テスト内容**:
1. プロフィール画面のタイトルが表示されることを確認
2. 編集メニューが表示されることを確認
3. プロフィール編集ボタンが表示されることを確認

## テスト実行方法

### Xcodeで実行

1. Xcodeでプロジェクトを開く
2. テストナビゲーター（`Cmd + 6`）を開く
3. `SoramoyouUITests`ターゲットを選択
4. `Cmd + U`でテストを実行

### コマンドラインで実行

```bash
# すべてのUIテストを実行
xcodebuild test -scheme Soramoyou -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SoramoyouUITests

# 特定のテストケースを実行
xcodebuild test -scheme Soramoyou -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SoramoyouUITests/SoramoyouUITests/testWelcomeView_Display
```

## UI要素の識別

### アクセシビリティ識別子の使用

UIテストでは、UI要素を識別するために以下の方法を使用します：

1. **テキストラベル**: `app.staticTexts["そらもよう"]`
2. **ボタン**: `app.buttons["ログイン"]`
3. **テキストフィールド**: `app.textFields["メールアドレス"]`
4. **セキュアテキストフィールド**: `app.secureTextFields["パスワード"]`
5. **タブバー**: `app.tabBars.buttons["ホーム"]`
6. **ナビゲーションバー**: `app.navigationBars["ログイン"]`

### アクセシビリティ識別子の追加（推奨）

より安定したUIテストのため、重要なUI要素にアクセシビリティ識別子を追加することを推奨します：

```swift
Button("ログイン") {
    // ...
}
.accessibilityIdentifier("loginButton")
```

## テストのベストプラクティス

1. **待機処理**: UI要素の表示を待つために`waitForExistence(timeout:)`を使用
2. **独立性**: 各テストは独立して実行可能
3. **クリーンアップ**: テスト後にアプリをリセット
4. **エラーハンドリング**: 要素が存在しない場合の処理を実装
5. **実際のデータ**: 実際のデータに依存するテストは、テスト用のデータを準備

## 制限事項と注意点

### 1. システム機能へのアクセス

- **写真ライブラリ**: システムの写真ライブラリアクセスが必要なテストは、シミュレーターの設定が必要
- **位置情報**: 位置情報を使用するテストは、シミュレーターの位置情報設定が必要
- **カメラ**: カメラを使用するテストは、シミュレーターのカメラ設定が必要

### 2. 非同期処理

- UIテストでは、非同期処理の完了を待つ必要があります
- `waitForExistence(timeout:)`を使用して要素の表示を待ちます

### 3. 認証状態

- 認証が必要な画面のテストは、テスト用の認証情報を使用するか、モックを使用します
- 実際のFirebase認証を使用する場合は、テスト環境でのFirebase設定が必要です

### 4. ネットワーク依存

- ネットワークに依存するテストは、オフライン環境では失敗する可能性があります
- モックを使用してネットワーク依存を排除することを推奨します

## 今後の改善

### 1. より詳細なテスト

- **投稿フロー**: 写真選択 → 編集 → 投稿情報入力 → 投稿保存の完全なフロー
- **編集フロー**: フィルター適用、編集ツール調整のUI操作
- **プロフィール編集**: プロフィール情報の編集、画像の変更

### 2. アクセシビリティ識別子の追加

重要なUI要素にアクセシビリティ識別子を追加して、より安定したテストを実装：

```swift
// Viewに追加
.accessibilityIdentifier("uniqueIdentifier")

// テストで使用
let element = app.buttons["uniqueIdentifier"]
```

### 3. スクリーンショットテスト

UIの見た目を検証するために、スクリーンショットテストを追加：

```swift
let screenshot = app.screenshot()
let attachment = XCTAttachment(screenshot: screenshot)
attachment.name = "HomeView"
add(attachment)
```

### 4. パフォーマンステスト

UI操作のパフォーマンスを測定：

```swift
measure {
    // UI操作を実行
}
```

### 5. アクセシビリティテスト

アクセシビリティ機能のテストを追加：

```swift
XCTAssertTrue(app.isAccessibilityElement)
```

## トラブルシューティング

### 要素が見つからない

1. **待機時間の調整**: `waitForExistence(timeout:)`のタイムアウトを延長
2. **アクセシビリティ識別子の確認**: 要素に正しい識別子が設定されているか確認
3. **階層の確認**: 要素が正しい階層に存在するか確認

### テストが不安定

1. **待機処理の追加**: 非同期処理の完了を待つ処理を追加
2. **リトライロジック**: 失敗した操作をリトライ
3. **環境の確認**: シミュレーターの状態を確認

### 認証が必要なテスト

1. **テスト用の認証情報**: テスト専用の認証情報を使用
2. **モックの使用**: 認証をモック化してテストを実行
3. **テスト環境の設定**: テスト環境でのFirebase設定

## 参考資料

- [Apple Developer: UI Testing](https://developer.apple.com/documentation/xctest/ui_testing)
- [XCTest Framework](https://developer.apple.com/documentation/xctest)
- [SwiftUI Testing](https://developer.apple.com/documentation/swiftui/testing)

