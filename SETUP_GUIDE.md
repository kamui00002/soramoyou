# そらもよう - セットアップガイド

## 現在の状態

✅ **完了済み**
- すべてのソースコード（Views、ViewModels、Services、Models）
- テストコード（ユニット、統合、UIテスト）
- ドキュメント
- セキュリティルール（Firestore、Storage）
- Firestoreインデックス定義

⚠️ **必要な作業**
- Xcodeプロジェクトの作成
- Firebaseプロジェクトの設定

## ステップ1: Xcodeプロジェクトの作成

### 1.1 Xcodeで新規プロジェクトを作成

1. **Xcodeを開く**
   ```bash
   open -a Xcode
   ```

2. **新規プロジェクトを作成**
   - "Create a new Xcode project"を選択
   - "iOS" > "App"を選択
   - "Next"をクリック

3. **プロジェクト情報を入力**
   - **Product Name**: `Soramoyou`
   - **Team**: あなたの開発チームを選択
   - **Organization Identifier**: `com.yourcompany`（適宜変更）
   - **Bundle Identifier**: `com.yourcompany.Soramoyou`（自動生成）
   - **Interface**: `SwiftUI`
   - **Language**: `Swift`
   - **Storage**: `None`（Core Dataは使用しない）
   - **Include Tests**: ✅ チェックを入れる

4. **保存場所を選択**
   - 既存の`Soramoyou`ディレクトリを選択
   - **重要**: 既存のファイルを上書きしないよう注意
   - "Create"をクリック

### 1.2 既存のファイルをプロジェクトに追加

1. **プロジェクトナビゲーターで右クリック**
   - `Soramoyou`グループ（青いフォルダアイコン）を右クリック
   - "Add Files to Soramoyou..."を選択

2. **以下のフォルダを追加**
   - `Soramoyou/Models/` - "Create groups"を選択
   - `Soramoyou/Views/` - "Create groups"を選択
   - `Soramoyou/ViewModels/` - "Create groups"を選択
   - `Soramoyou/Services/` - "Create groups"を選択
   - `Soramoyou/Utils/` - "Create groups"を選択

3. **既存のSoramoyouApp.swiftを置き換え**
   - プロジェクトに自動生成された`SoramoyouApp.swift`を削除
   - 既存の`Soramoyou/Soramoyou/SoramoyouApp.swift`を追加

4. **Info.plistを更新**
   - プロジェクトの`Info.plist`を既存の`Soramoyou/Soramoyou/Info.plist`の内容で置き換え

### 1.3 テストターゲットにテストファイルを追加

1. **SoramoyouTestsターゲットに追加**
   - `Soramoyou/SoramoyouTests/`フォルダ内のすべてのテストファイルを追加
   - ターゲット: `SoramoyouTests`を選択

2. **SoramoyouUITestsターゲットに追加**
   - `Soramoyou/SoramoyouUITests/`フォルダ内のテストファイルを追加
   - ターゲット: `SoramoyouUITests`を選択

## ステップ2: Swift Package Managerで依存関係を追加

### 2.1 パッケージ依存関係の追加

1. **プロジェクトナビゲーターでプロジェクトを選択**
   - 一番上の青いアイコン（プロジェクト名）をクリック

2. **Package Dependenciesタブを開く**
   - プロジェクト設定の"Package Dependencies"タブを選択

3. **Firebase iOS SDKを追加**
   - "+"ボタンをクリック
   - URL: `https://github.com/firebase/firebase-ios-sdk`
   - Version: `10.18.0` 以降を選択
   - "Add Package"をクリック
   - 以下のプロダクトを選択:
     - ✅ FirebaseAuth
     - ✅ FirebaseFirestore
     - ✅ FirebaseStorage
     - ✅ FirebaseCrashlytics
     - ✅ FirebaseAnalytics
   - "Add Package"をクリック

4. **Kingfisherを追加**
   - "+"ボタンをクリック
   - URL: `https://github.com/onevcat/Kingfisher`
   - Version: `7.9.0` 以降を選択
   - "Add Package"をクリック
   - ✅ Kingfisherを選択
   - "Add Package"をクリック

5. **Google Mobile Ads SDKを追加**
   - "+"ボタンをクリック
   - URL: `https://github.com/googleads/swift-package-manager-google-mobile-ads.git`
   - Version: `10.14.0` 以降を選択
   - "Add Package"をクリック
   - ✅ GoogleMobileAdsを選択
   - "Add Package"をクリック

### 2.2 ターゲットに依存関係を追加

1. **Soramoyouターゲットを選択**
   - プロジェクト設定で"Soramoyou"ターゲットを選択
   - "General"タブ > "Frameworks, Libraries, and Embedded Content"
   - 追加したパッケージが表示されていることを確認

2. **テストターゲットにも追加**
   - `SoramoyouTests`ターゲットにも同様に依存関係を追加

## ステップ3: Firebaseプロジェクトの設定

### 3.1 Firebase Consoleでプロジェクトを作成

1. **Firebase Consoleにアクセス**
   - [Firebase Console](https://console.firebase.google.com/)にアクセス
   - Googleアカウントでログイン

2. **プロジェクトを作成**
   - "プロジェクトを追加"をクリック
   - プロジェクト名: `soramoyou`（任意）
   - Google Analyticsの設定（任意）
   - "プロジェクトを作成"をクリック

3. **iOSアプリを追加**
   - "iOS"アイコンをクリック
   - **バンドルID**: XcodeプロジェクトのBundle Identifierと一致させる
     - 例: `com.yourcompany.Soramoyou`
   - **アプリのニックネーム**: `Soramoyou`
   - **App Store ID**: 空白（後で設定可能）
   - "アプリを登録"をクリック

4. **GoogleService-Info.plistをダウンロード**
   - ダウンロードボタンをクリック
   - ファイルを保存

### 3.2 GoogleService-Info.plistをプロジェクトに追加

1. **Xcodeプロジェクトに追加**
   - ダウンロードした`GoogleService-Info.plist`をXcodeプロジェクトの`Soramoyou`グループにドラッグ&ドロップ
   - "Copy items if needed"にチェックを入れる
   - "Add to targets: Soramoyou"にチェックを入れる
   - "Finish"をクリック

2. **.gitignoreに追加されていることを確認**
   - `GoogleService-Info.plist`はGitにコミットしない（既に`.gitignore`に追加済み）

### 3.3 Firebaseサービスの有効化

1. **Authenticationを有効化**
   - Firebase Console > Authentication
   - "始める"をクリック
   - "Sign-in method"タブを開く
   - "メール/パスワード"を有効化
   - "保存"をクリック

2. **Cloud Firestoreを有効化**
   - Firebase Console > Firestore Database
   - "データベースを作成"をクリック
   - ロケーションを選択（例: `asia-northeast1` - 東京）
   - セキュリティルール: "テストモードで開始"を選択（後で本番用ルールに更新）
   - "有効にする"をクリック

3. **Firebase Storageを有効化**
   - Firebase Console > Storage
   - "始める"をクリック
   - セキュリティルール: "テストモードで開始"を選択（後で本番用ルールに更新）
   - ロケーションを選択（Firestoreと同じロケーションを推奨）
   - "完了"をクリック

## ステップ4: セキュリティルールのデプロイ

### 4.1 Firestore Security Rules

1. **Firebase Consoleでルールを設定**
   - Firebase Console > Firestore Database > ルール
   - `Soramoyou/firestore.rules`の内容をコピー
   - ルールエディタに貼り付け
   - "公開"をクリック

### 4.2 Storage Security Rules

1. **Firebase Consoleでルールを設定**
   - Firebase Console > Storage > ルール
   - `Soramoyou/storage.rules`の内容をコピー
   - ルールエディタに貼り付け
   - "公開"をクリック

### 4.3 Firestoreインデックスの作成

1. **Firebase Consoleでインデックスを作成**
   - Firebase Console > Firestore Database > インデックス
   - `Soramoyou/firestore.indexes.json`の内容を参照
   - 必要なインデックスを手動で作成するか、Firebase CLIでデプロイ

   **Firebase CLIを使用する場合:**
   ```bash
   # Firebase CLIをインストール（未インストールの場合）
   npm install -g firebase-tools
   
   # Firebaseにログイン
   firebase login
   
   # プロジェクトを初期化
   firebase init firestore
   
   # インデックスをデプロイ
   firebase deploy --only firestore:indexes
   ```

## ステップ5: ビルドと動作確認

### 5.1 ビルドの確認

1. **Xcodeでビルド**
   - `Cmd + B`でビルドを実行
   - エラーがないか確認

2. **よくあるエラーと対処法**

   **エラー: "Cannot find 'FirebaseAuth' in scope"**
   - プロジェクト設定 > Package Dependenciesでパッケージが正しく追加されているか確認
   - ターゲットの"Frameworks, Libraries, and Embedded Content"に追加されているか確認

   **エラー: "Missing GoogleService-Info.plist"**
   - `GoogleService-Info.plist`がプロジェクトに追加されているか確認
   - ターゲットの"Copy Bundle Resources"に含まれているか確認

   **エラー: "Info.plist not found"**
   - プロジェクト設定 > Build Settings > Info.plist Fileのパスを確認

### 5.2 シミュレーターで実行

1. **シミュレーターを選択**
   - デバイス選択でiPhone 15（または任意のデバイス）を選択

2. **アプリを実行**
   - `Cmd + R`でアプリを実行
   - ウェルカム画面が表示されることを確認

3. **基本機能の動作確認**
   - ✅ ウェルカム画面の表示
   - ✅ ログイン/新規登録
   - ✅ ホーム画面の表示
   - ✅ 投稿機能（写真選択、編集、投稿）
   - ✅ 検索機能
   - ✅ プロフィール機能

## トラブルシューティング

### ビルドエラーが発生する場合

1. **クリーンビルドを実行**
   - `Cmd + Shift + K`でクリーン
   - `Cmd + B`で再ビルド

2. **DerivedDataを削除**
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData
   ```

3. **パッケージを再取得**
   - File > Packages > Reset Package Caches
   - File > Packages > Update to Latest Package Versions

### Firebase接続エラーが発生する場合

1. **GoogleService-Info.plistの確認**
   - ファイルが正しく配置されているか確認
   - Bundle Identifierが一致しているか確認

2. **ネットワーク接続の確認**
   - インターネット接続を確認
   - ファイアウォール設定を確認

## 次のステップ

セットアップが完了したら、以下を実施してください：

1. **テストの実行**
   - `Cmd + U`でテストを実行
   - すべてのテストが成功することを確認

2. **コードレビュー**
   - コードスタイルの統一
   - コメントの追加

3. **デプロイ準備**
   - App Store Connectの設定
   - 証明書とプロビジョニングプロファイルの準備

詳細は`NEXT_STEPS.md`を参照してください。

