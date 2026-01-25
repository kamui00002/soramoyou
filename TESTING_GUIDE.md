# 📱 そらもよう - UIテストガイド

## 🎯 概要

このドキュメントでは、「そらもよう」アプリの包括的なUIテスト（XCUITest）の実行方法と、テストの構成について説明します。

---

## 📁 テストファイル構成

### メインテストファイル
- **SoramoyouUITests.swift** - 基本的な認証、タブ、ホーム、投稿、検索、プロフィールのテスト

### 拡張テストファイル（機能別）
以下のテストファイルが追加されています：

1. **SoramoyouUITests+EditFeatures.swift**
   - 編集画面の3タブ（フィルター、調整、切り取り）のテスト
   - 10種類のフィルターのテスト
   - 編集ツール（装備システム）のテスト
   - リアルタイムプレビューのテスト

2. **SoramoyouUITests+PostDetail.swift**
   - 投稿詳細画面（GalleryDetailView）のテスト
   - 投稿者情報、画像、キャプション、ハッシュタグの表示テスト
   - 位置情報、空の色、編集設定の表示テスト
   - 編集前後の画像切り替えテスト

3. **SoramoyouUITests+Drafts.swift**
   - 下書き一覧画面のテスト
   - 下書きの保存、編集再開、削除のテスト
   - 空の状態の表示テスト

4. **SoramoyouUITests+SearchFeatures.swift**
   - ハッシュタグ検索の詳細テスト
   - 色検索のテスト
   - 時間帯検索（朝、午後、夕方、夜）のテスト
   - 空の種類検索（晴れ、曇り、夕焼け、朝焼け）のテスト
   - 複数条件を組み合わせた検索のテスト
   - 検索結果の表示とページネーションのテスト

5. **SoramoyouUITests+Ads.swift**
   - AdMobバナー広告の表示テスト
   - 各画面（ホーム、検索、投稿、プロフィール）での広告表示テスト
   - 広告の位置確認（画面下部）
   - 広告読み込み失敗時のハンドリングテスト

6. **SoramoyouUITests+E2E.swift**
   - エンドツーエンドのフロー統合テスト
   - 新規ユーザー登録から初投稿までのフロー
   - 完全な投稿フロー（選択→編集→情報入力→投稿）
   - 検索から投稿詳細表示までのフロー
   - プロフィール編集と編集装備設定のフロー
   - 下書き保存と再開のフロー
   - 全タブ巡回のナビゲーションフロー
   - ゲストユーザーの閲覧制限フロー
   - エラー発生と回復のフロー
   - ログアウトと再ログインのフロー

---

## 🚀 テストの実行方法

### 前提条件

#### 1. Xcodeプロジェクトでテストターゲットを設定

現在、テストファイルは作成されていますが、Xcodeプロジェクトにテストターゲットを正しく追加する必要があります。

**手順:**

1. **Xcodeでプロジェクトを開く**
   ```bash
   open Soramoyou/Soramoyou.xcodeproj
   ```

2. **テストターゲットの確認**
   - プロジェクトナビゲーターでプロジェクトファイルを選択
   - TARGETS セクションで `SoramoyouUITests` が存在するか確認
   - 存在しない場合は、"+" ボタンをクリックして追加

3. **テストファイルをターゲットに追加**
   - `Soramoyou/SoramoyouUITests/` フォルダ内の全ファイルを選択
   - 右側のインスペクターで `Target Membership` を確認
   - `SoramoyouUITests` にチェックを入れる

4. **依存関係の設定**
   - `SoramoyouUITests` ターゲットを選択
   - "Build Phases" タブを開く
   - "Dependencies" セクションに `Soramoyou` を追加

#### 2. テスト用のFirebase設定

テストを実行する前に、テスト用のFirebaseプロジェクトまたはテスト環境を用意することをお勧めします。

**オプション:**
- 本番とは別のFirebaseプロジェクトを使用
- Firestoreエミュレータを使用
- テスト用のアカウントを作成

---

### 🧪 テスト実行コマンド

#### 方法1: Xcodeから実行（推奨）

1. **Xcodeでプロジェクトを開く**
   ```bash
   open Soramoyou/Soramoyou.xcodeproj
   ```

2. **テストナビゲーターを開く**
   - `Cmd + 6` を押す

3. **実行したいテストを選択**
   - **全テスト実行:** `SoramoyouUITests` の横の再生ボタンをクリック
   - **特定のファイルのテスト実行:** ファイル名の横の再生ボタンをクリック
   - **特定のテストケース実行:** テスト関数名の横の再生ボタンをクリック

4. **テスト結果を確認**
   - テストナビゲーターに成功/失敗が表示される
   - 失敗したテストの詳細はログで確認

#### 方法2: コマンドラインから実行

```bash
# すべてのUIテストを実行
xcodebuild test \
  -project Soramoyou/Soramoyou.xcodeproj \
  -scheme Soramoyou \
  -destination 'platform=iOS Simulator,name=iPhone 14 Pro,OS=latest' \
  -only-testing:SoramoyouUITests

# 特定のテストクラスのみ実行
xcodebuild test \
  -project Soramoyou/Soramoyou.xcodeproj \
  -scheme Soramoyou \
  -destination 'platform=iOS Simulator,name=iPhone 14 Pro,OS=latest' \
  -only-testing:SoramoyouUITests/SoramoyouUITests/testWelcomeView_Display

# 特定のテストファイルのみ実行（編集機能テスト）
xcodebuild test \
  -project Soramoyou/Soramoyou.xcodeproj \
  -scheme Soramoyou \
  -destination 'platform=iOS Simulator,name=iPhone 14 Pro,OS=latest' \
  -only-testing:SoramoyouUITests/SoramoyouUITests+EditFeatures
```

#### 方法3: fastlaneを使用（今後の拡張）

```bash
# fastlaneのセットアップ（初回のみ）
bundle exec fastlane init

# UIテストの実行
bundle exec fastlane ui_test
```

---

## 📋 テストカテゴリ別の実行

### 認証関連テスト
```bash
# ウェルカム画面、ログイン、新規登録のテスト
xcodebuild test \
  -project Soramoyou/Soramoyou.xcodeproj \
  -scheme Soramoyou \
  -destination 'platform=iOS Simulator,name=iPhone 14 Pro,OS=latest' \
  -only-testing:SoramoyouUITests/SoramoyouUITests/testWelcomeView_Display \
  -only-testing:SoramoyouUITests/SoramoyouUITests/testAuthenticationFlow_NavigateToLogin \
  -only-testing:SoramoyouUITests/SoramoyouUITests/testAuthenticationFlow_NavigateToSignUp
```

### 編集機能テスト
```bash
# フィルター、調整、切り取り機能のテスト
xcodebuild test \
  -project Soramoyou/Soramoyou.xcodeproj \
  -scheme Soramoyou \
  -destination 'platform=iOS Simulator,name=iPhone 14 Pro,OS=latest' \
  -only-testing:SoramoyouUITests/SoramoyouUITests+EditFeatures
```

### 検索機能テスト
```bash
# ハッシュタグ、色、時間帯、空の種類の検索テスト
xcodebuild test \
  -project Soramoyou/Soramoyou.xcodeproj \
  -scheme Soramoyou \
  -destination 'platform=iOS Simulator,name=iPhone 14 Pro,OS=latest' \
  -only-testing:SoramoyouUITests/SoramoyouUITests+SearchFeatures
```

### E2Eテスト
```bash
# エンドツーエンドのフロー統合テスト
xcodebuild test \
  -project Soramoyou/Soramoyou.xcodeproj \
  -scheme Soramoyou \
  -destination 'platform=iOS Simulator,name=iPhone 14 Pro,OS=latest' \
  -only-testing:SoramoyouUITests/SoramoyouUITests+E2E
```

---

## 🔧 テスト環境の設定

### テストデバイス/シミュレータ

推奨されるテストデバイス：

- **iPhone SE (3rd generation)** - 小画面
- **iPhone 14 Pro** - 標準画面
- **iPhone 14 Pro Max** - 大画面
- **iPad (10th generation)** - タブレット（将来的に対応する場合）

### テストアカウント

テスト用のFirebase認証アカウントを事前に作成しておくことを推奨します：

```
メールアドレス: test@example.com
パスワード: testpassword123
```

⚠️ **重要:** テスト用アカウントの情報は、`.env`ファイルや環境変数で管理し、リポジトリにコミットしないでください。

---

## 📊 テストカバレッジ

### カバーされている機能

✅ **認証機能**
- ウェルカム画面の表示
- ログイン画面への遷移と入力
- 新規登録画面への遷移と入力
- バリデーションエラーの表示

✅ **メインタブビュー**
- 各タブの表示と切り替え
- タブバーの動作

✅ **ホーム画面（フィード）**
- 投稿一覧の表示
- プルリフレッシュ

✅ **投稿機能**
- 写真選択画面の表示
- 編集画面の3タブ（フィルター、調整、切り取り）
- 10種類のフィルターの適用
- 編集ツールの選択と調整
- 装備システム（5〜8個のツール選択）
- 画像の回転と反転
- アスペクト比の選択
- リアルタイムプレビュー
- 投稿情報入力画面
- 位置情報追加
- 公開設定
- 投稿の実行

✅ **投稿詳細画面**
- 投稿者情報の表示
- 画像の表示
- キャプション、ハッシュタグの表示
- 位置情報の表示
- 空の色情報の表示
- 編集前後の画像切り替え
- 編集設定の表示
- 時間帯、空のタイプの表示
- 投稿者プロフィールへの遷移

✅ **検索機能**
- ハッシュタグ検索
- 色検索
- 時間帯検索（朝、午後、夕方、夜）
- 空の種類検索（晴れ、曇り、夕焼け、朝焼け）
- 複数条件の組み合わせ検索
- 検索結果の表示
- 検索結果からの投稿詳細表示

✅ **プロフィール機能**
- プロフィール画面の表示
- ユーザー情報（統計情報）の表示
- 投稿一覧の表示
- プロフィール編集メニュー
- プロフィール編集画面
- 表示モード切り替え（グリッド⇔リスト）
- 編集装備設定画面
- プルリフレッシュ

✅ **下書き機能**
- 下書き一覧画面の表示
- 下書きリストの表示
- 下書きの詳細確認
- 下書きからの編集再開
- 下書きの削除
- 空の状態の表示

✅ **AdMob広告**
- 各画面でのバナー広告表示
- 広告の位置確認（画面下部）
- コンテンツと広告の重なりチェック
- 広告読み込み失敗時のハンドリング

✅ **E2Eフロー**
- 新規ユーザー登録から初投稿まで
- 完全な投稿フロー
- 検索から投稿詳細表示まで
- プロフィール編集と編集装備設定
- 下書き保存と再開
- 全タブ巡回
- ゲストユーザーの閲覧制限
- エラー発生と回復
- ログアウトと再ログイン

---

## ⚠️ テスト実行時の注意事項

### 1. 写真選択のテスト制限

iOS 14以降、システムの写真ピッカー（PHPicker）はXCUITestでの自動操作に制限があります。
写真選択のテストは以下のように対応しています：

- 写真選択ボタンのタップまでをテスト
- 写真ピッカーが表示されることを確認
- 実際の写真選択は手動操作が必要、またはモックを使用

### 2. Firebase接続のテスト

- テスト実行時はインターネット接続が必要
- Firebaseエミュレータを使用する場合は事前に起動
- テスト用アカウントでのデータは定期的にクリーンアップ

### 3. AdMob広告のテスト

- テスト環境では広告が読み込まれない場合がある
- テスト用の広告IDを使用することを推奨
- 広告表示のテストは「表示されること」を確認するが、読み込み失敗も許容

### 4. シミュレータの設定

以下の設定を推奨：

- **言語:** 日本語
- **地域:** 日本
- **位置情報サービス:** 有効
- **写真ライブラリ:** テスト用の画像を事前に追加

### 5. テスト実行時間

- 全テスト実行には**約30〜60分**かかる場合があります
- 特定の機能テストのみを実行することで時間短縮可能
- CI/CDでは並列実行を検討

---

## 🐛 テスト失敗時のデバッグ

### 失敗の一般的な原因と対処法

1. **要素が見つからない（waitForExistence timeout）**
   - タイムアウト時間を延長
   - UI要素のアクセシビリティIDを確認
   - 画面遷移のタイミングを調整（sleep追加）

2. **Firebase接続エラー**
   - インターネット接続を確認
   - FirebaseのGoogleService-Info.plistが正しく設定されているか確認
   - テスト用アカウントが存在するか確認

3. **広告関連のテスト失敗**
   - テスト環境での広告読み込みは不安定なため、許容範囲
   - AdMobのテスト広告IDを使用しているか確認

4. **写真選択関連のテスト失敗**
   - シミュレータの写真ライブラリにテスト画像が存在するか確認
   - 写真ピッカーの制限により、自動選択ができない場合がある

### デバッグ方法

```bash
# テストを一つずつ実行してデバッグ
xcodebuild test \
  -project Soramoyou/Soramoyou.xcodeproj \
  -scheme Soramoyou \
  -destination 'platform=iOS Simulator,name=iPhone 14 Pro,OS=latest' \
  -only-testing:SoramoyouUITests/SoramoyouUITests/testWelcomeView_Display \
  -verbose
```

Xcodeで実行する場合：
1. デバッグしたいテストにブレークポイントを設定
2. テストを実行
3. ブレークポイントで停止したら、変数や状態を確認

---

## 📈 継続的改善

### テストの追加

新しい機能を実装した際は、対応するUIテストも追加してください：

1. 適切なテストファイルに追加（例: 新しい編集ツール → `SoramoyouUITests+EditFeatures.swift`）
2. テスト関数の命名規則に従う（`test機能名_テスト内容`）
3. Given-When-Then形式でテストを記述
4. 適切なアサーションを使用

### CI/CDへの統合

将来的にGitHub ActionsやBitrise等のCI/CDサービスでテストを自動実行することを推奨します。

---

## 📚 参考資料

- [Apple - XCTest Framework](https://developer.apple.com/documentation/xctest)
- [Apple - XCUITest](https://developer.apple.com/documentation/xctest/user_interface_tests)
- [Firebase Test Lab](https://firebase.google.com/docs/test-lab)
- [fastlane - UI Testing](https://docs.fastlane.tools/actions/run_tests/)

---

## 🤝 サポート

テストに関する質問や問題がある場合は、GitHubのIssueを作成してください。

---

**最終更新日:** 2026-01-25
