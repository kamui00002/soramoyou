# Firebase セットアップクイックガイド

このガイドでは、そらもようアプリをFirebaseに接続するための手順を説明します。

## 📋 前提条件

- Googleアカウント
- Xcodeがインストール済み
- このプロジェクトがクローン済み

## 🚀 セットアップ手順（所要時間: 約10分）

### ステップ1: Firebaseプロジェクトの作成

1. **Firebase Consoleにアクセス**
   - https://console.firebase.google.com/ を開く
   - Googleアカウントでログイン

2. **プロジェクトを作成**
   - 「プロジェクトを追加」をクリック
   - プロジェクト名: `soramoyou`（または任意の名前）
   - Google Analyticsは「有効にする」を推奨
   - 「プロジェクトを作成」をクリック

### ステップ2: iOSアプリの登録

1. **iOSアプリを追加**
   - プロジェクトの概要ページで「iOS」アイコンをクリック
   - Apple バンドルID: `com.yourcompany.Soramoyou`
     - ⚠️ 注意: 後でXcodeで同じBundle IDを設定する必要があります
   - アプリのニックネーム: `そらもよう`（オプション）
   - App Store ID: 空欄でOK（後で設定可能）
   - 「アプリを登録」をクリック

2. **設定ファイルのダウンロード**
   - `GoogleService-Info.plist` をダウンロード
   - ダウンロードしたファイルを以下の場所に配置:
     ```
     Soramoyou/Soramoyou/GoogleService-Info.plist
     ```
   - ⚠️ `GoogleService-Info-Template.plist` は削除してください

3. **Firebase SDKの追加**
   - この手順は**スキップ**してください（既に設定済み）
   - 「次へ」→「次へ」→「コンソールに進む」

### ステップ3: Firebaseサービスの有効化

#### 3.1 Authentication（認証）

1. 左メニューから「構築」→「Authentication」を選択
2. 「始める」をクリック
3. 「Sign-in method」タブを選択
4. 「メール/パスワード」を選択
5. 「有効にする」をONにして「保存」

#### 3.2 Cloud Firestore（データベース）

1. 左メニューから「構築」→「Firestore Database」を選択
2. 「データベースの作成」をクリック
3. ロケーション: `asia-northeast1`（東京）を推奨
4. セキュリティルール: 「本番環境モード」を選択
5. 「作成」をクリック

**セキュリティルールの設定:**
1. 「ルール」タブを選択
2. 以下の内容に置き換え:

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // ユーザーコレクション
    match /users/{userId} {
      allow read: if true;
      allow write: if request.auth != null && request.auth.uid == userId;
    }

    // 投稿コレクション
    match /posts/{postId} {
      allow read: if resource.data.visibility == 'public'
                  || (request.auth != null && resource.data.userId == request.auth.uid);
      allow create: if request.auth != null && request.resource.data.userId == request.auth.uid;
      allow update, delete: if request.auth != null && resource.data.userId == request.auth.uid;
    }

    // 下書きコレクション
    match /drafts/{draftId} {
      allow read, write: if request.auth != null && resource.data.userId == request.auth.uid;
    }
  }
}
```

3. 「公開」をクリック

#### 3.3 Firebase Storage（ストレージ）

1. 左メニューから「構築」→「Storage」を選択
2. 「始める」をクリック
3. セキュリティルール: デフォルトのまま「次へ」
4. ロケーション: `asia-northeast1`（東京）を推奨
5. 「完了」をクリック

**セキュリティルールの設定:**
1. 「ルール」タブを選択
2. 以下の内容に置き換え:

```javascript
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /images/{userId}/{imageId} {
      allow read: if true;
      allow write: if request.auth != null && request.auth.uid == userId;
    }

    match /profile_images/{userId}/{imageId} {
      allow read: if true;
      allow write: if request.auth != null && request.auth.uid == userId;
    }
  }
}
```

3. 「公開」をクリック

#### 3.4 Firestoreインデックスの作成

1. 「インデックス」タブを選択
2. 以下のインデックスを追加:

**投稿検索用インデックス:**
- コレクションID: `posts`
- フィールド:
  - `visibility`: 昇順
  - `createdAt`: 降順

**ハッシュタグ検索用インデックス:**
- コレクションID: `posts`
- フィールド:
  - `hashtags`: 配列
  - `createdAt`: 降順

**時間帯検索用インデックス:**
- コレクションID: `posts`
- フィールド:
  - `timeOfDay`: 昇順
  - `createdAt`: 降順

**空の種類検索用インデックス:**
- コレクションID: `posts`
- フィールド:
  - `skyType`: 昇順
  - `createdAt`: 降順

### ステップ4: Xcodeプロジェクトの設定

1. **Xcodeでプロジェクトを開く**
   ```bash
   cd ~/soramoyou
   open Soramoyou/Soramoyou.xcodeproj
   ```

2. **Bundle Identifierの設定**
   - プロジェクトナビゲーターで「Soramoyou」プロジェクトを選択
   - 「Soramoyou」ターゲットを選択
   - 「Signing & Capabilities」タブを選択
   - Bundle Identifier: Firebase Consoleで設定した値と同じにする
     - 例: `com.yourcompany.Soramoyou`

3. **GoogleService-Info.plistの追加確認**
   - プロジェクトナビゲーターで `GoogleService-Info.plist` が存在するか確認
   - 存在しない場合は、ステップ2でダウンロードしたファイルをドラッグ&ドロップ
   - 「Copy items if needed」をチェック
   - ターゲット「Soramoyou」にチェック

4. **ビルドの確認**
   - `Cmd + B` でビルド
   - エラーがないことを確認

5. **実行**
   - シミュレーターを選択（iPhone 15推奨）
   - `Cmd + R` で実行
   - アプリが起動することを確認

## ✅ セットアップ完了チェックリスト

- [ ] Firebaseプロジェクトを作成した
- [ ] iOSアプリを登録した
- [ ] GoogleService-Info.plistをダウンロード・配置した
- [ ] Authenticationでメール/パスワード認証を有効化した
- [ ] Cloud Firestoreを作成した
- [ ] Firestoreのセキュリティルールを設定した
- [ ] Firebase Storageを作成した
- [ ] Storageのセキュリティルールを設定した
- [ ] Firestoreインデックスを作成した
- [ ] XcodeでBundle Identifierを設定した
- [ ] アプリがビルド・実行できることを確認した

## 🎉 次のステップ

セットアップが完了したら、以下の機能を試してみましょう：

1. **新規登録**: 新しいアカウントを作成
2. **ログイン**: 作成したアカウントでログイン
3. **投稿**: 写真を選択して投稿
4. **検索**: ハッシュタグや色で検索
5. **プロフィール**: プロフィール情報を編集

## ❓ トラブルシューティング

### ビルドエラーが発生する

1. `Product` → `Clean Build Folder` (`Cmd + Shift + K`)
2. `File` → `Packages` → `Reset Package Caches`
3. Xcodeを再起動

### Firebase接続エラーが発生する

1. `GoogleService-Info.plist` が正しく配置されているか確認
2. Bundle IdentifierがFirebase Consoleの設定と一致しているか確認
3. インターネット接続を確認

### 認証エラーが発生する

1. Firebase ConsoleでAuthenticationが有効化されているか確認
2. メール/パスワード認証が有効になっているか確認

## 📚 参考資料

- [Firebase公式ドキュメント](https://firebase.google.com/docs)
- [Firebase iOS SDK](https://github.com/firebase/firebase-ios-sdk)
- プロジェクトの `NEXT_STEPS.md` も参照してください
