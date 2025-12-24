# Firebase セキュリティガイド

このドキュメントでは、そらもようアプリのFirebaseセキュリティルールとインデックスについて説明します。

## 📋 目次

1. [概要](#概要)
2. [Firestoreセキュリティルール](#firestoreセキュリティルール)
3. [Storageセキュリティルール](#storageセキュリティルール)
4. [Firestoreインデックス](#firestoreインデックス)
5. [デプロイ手順](#デプロイ手順)
6. [テスト](#テスト)
7. [トラブルシューティング](#トラブルシューティング)

---

## 概要

そらもようアプリでは、以下のFirebaseサービスを使用します：

- **Firebase Authentication**: ユーザー認証
- **Cloud Firestore**: データベース（users, posts, drafts コレクション）
- **Firebase Storage**: 画像ファイル保存

セキュリティルールにより、適切なアクセス制御とデータ検証を実装します。

---

## Firestoreセキュリティルール

ファイル: `firestore.rules`

### コレクション構造

```
firestore
├── users/{userId}              # ユーザー情報
├── posts/{postId}              # 投稿
└── drafts/{draftId}            # 下書き
```

### users コレクション

**アクセス制御:**

- **読み取り**: 認証済みユーザーなら誰でも可能
  - プロフィール表示機能で他のユーザー情報を取得するため
- **作成**: 自分のドキュメントのみ
  - `userId` がリクエストユーザーの UID と一致する必要がある
  - 初期値のバリデーション（followersCount, followingCount, postsCount は 0）
- **更新**: 自分のドキュメントのみ
  - `userId` と `createdAt` は変更不可
- **削除**: 禁止
  - ユーザー削除は Firebase Authentication または管理コンソールで処理

**データ検証:**

- 必須フィールド: `userId`, `createdAt`, `updatedAt`
- 作成時: カウントフィールドは必ず 0 で初期化

### posts コレクション

**アクセス制御:**

- **読み取り**:
  - `visibility == 'public'` なら誰でも可能
  - それ以外は投稿者のみ
- **作成**: 認証済みユーザーのみ
  - `userId` がリクエストユーザーの UID と一致する必要がある
  - `postId` がドキュメント ID と一致する必要がある
  - 初期値のバリデーション（likesCount, commentsCount は 0）
- **更新**: 投稿者のみ
  - `postId`, `userId`, `createdAt` は変更不可
- **削除**: 投稿者のみ

**データ検証:**

- 必須フィールド: `postId`, `userId`, `images`, `visibility`, `createdAt`, `updatedAt`
- `images`: 配列、1〜10個
- `visibility`: `'public'`, `'private'`, `'followers'` のいずれか
- `caption`: 最大2000文字
- `hashtags`: 最大30個
- `skyColors`: 最大5色

### drafts コレクション

**アクセス制御:**

- **読み取り**: 自分の下書きのみ
- **作成**: 自分の下書きのみ
  - `userId` がリクエストユーザーの UID と一致する必要がある
  - `draftId` がドキュメント ID と一致する必要がある
- **更新**: 自分の下書きのみ
  - `draftId`, `userId`, `createdAt` は変更不可
- **削除**: 自分の下書きのみ

**データ検証:**

- 必須フィールド: `draftId`, `userId`, `images`, `visibility`, `createdAt`, `updatedAt`
- `images`: 配列、1〜10個
- `visibility`: `'public'`, `'private'`, `'followers'` のいずれか
- `caption`: 最大2000文字
- `hashtags`: 最大30個

---

## Storageセキュリティルール

ファイル: `storage.rules`

### ストレージ構造

```
storage
├── images/{userId}/{postId}/{filename}              # 投稿画像（フル解像度）
├── thumbnails/images/{userId}/{postId}/{filename}   # サムネイル
└── profile_images/{userId}/{filename}               # プロフィール画像（Phase 2用）
```

### images/ パス

**アクセス制御:**

- **読み取り**: 誰でも可能
  - 公開投稿の画像を表示するため
- **書き込み**: 認証済みユーザーのみ
  - 自分の `userId` パスのみ
  - 画像ファイル（JPEG, PNG, WEBP, HEIC）のみ
  - 最大5MB
- **削除**: 自分の `userId` パスのみ

### thumbnails/ パス

**アクセス制御:**

- **読み取り**: 誰でも可能
- **書き込み**: 認証済みユーザーのみ
  - 自分の `userId` パスのみ
  - 画像ファイル（JPEG, PNG, WEBP, HEIC）のみ
  - 最大5MB
- **削除**: 自分の `userId` パスのみ

### profile_images/ パス（Phase 2用）

**アクセス制御:**

- **読み取り**: 誰でも可能
- **書き込み**: 認証済みユーザーのみ
  - 自分の `userId` パスのみ
  - 画像ファイル（JPEG, PNG, WEBP, HEIC）のみ
  - 最大2MB
- **削除**: 自分の `userId` パスのみ

---

## Firestoreインデックス

ファイル: `firestore.indexes.json`

### 必要なインデックス

Firestoreは複合クエリ（複数フィールドでのフィルタリング・ソート）を実行するために、インデックスが必要です。

#### 1. ハッシュタグ検索

```json
{
  "collectionGroup": "posts",
  "fields": [
    { "fieldPath": "hashtags", "arrayConfig": "CONTAINS" },
    { "fieldPath": "visibility", "order": "ASCENDING" },
    { "fieldPath": "createdAt", "order": "DESCENDING" }
  ]
}
```

用途: ハッシュタグで検索し、公開投稿のみを新しい順に取得

#### 2. 時間帯検索

```json
{
  "collectionGroup": "posts",
  "fields": [
    { "fieldPath": "timeOfDay", "order": "ASCENDING" },
    { "fieldPath": "visibility", "order": "ASCENDING" },
    { "fieldPath": "createdAt", "order": "DESCENDING" }
  ]
}
```

用途: 特定の時間帯（朝、昼、夕方、夜）で検索し、公開投稿のみを新しい順に取得

#### 3. 空の種類検索

```json
{
  "collectionGroup": "posts",
  "fields": [
    { "fieldPath": "skyType", "order": "ASCENDING" },
    { "fieldPath": "visibility", "order": "ASCENDING" },
    { "fieldPath": "createdAt", "order": "DESCENDING" }
  ]
}
```

用途: 空の種類（快晴、曇り、雨など）で検索し、公開投稿のみを新しい順に取得

#### 4. 色検索

```json
{
  "collectionGroup": "posts",
  "fields": [
    { "fieldPath": "skyColors", "arrayConfig": "CONTAINS" },
    { "fieldPath": "visibility", "order": "ASCENDING" },
    { "fieldPath": "createdAt", "order": "DESCENDING" }
  ]
}
```

用途: 特定の色を含む投稿を検索し、公開投稿のみを新しい順に取得

#### 5. ユーザー投稿一覧

```json
{
  "collectionGroup": "posts",
  "fields": [
    { "fieldPath": "userId", "order": "ASCENDING" },
    { "fieldPath": "createdAt", "order": "DESCENDING" }
  ]
}
```

用途: 特定のユーザーの投稿を新しい順に取得

#### 6. 公開投稿一覧

```json
{
  "collectionGroup": "posts",
  "fields": [
    { "fieldPath": "visibility", "order": "ASCENDING" },
    { "fieldPath": "createdAt", "order": "DESCENDING" }
  ]
}
```

用途: 公開投稿のみを新しい順に取得（フィード表示）

#### 7. 下書き一覧

```json
{
  "collectionGroup": "drafts",
  "fields": [
    { "fieldPath": "userId", "order": "ASCENDING" },
    { "fieldPath": "updatedAt", "order": "DESCENDING" }
  ]
}
```

用途: 特定のユーザーの下書きを更新日時順に取得

---

## デプロイ手順

### 方法1: Firebase Console（推奨）

#### Firestoreセキュリティルール

1. [Firebase Console](https://console.firebase.google.com/) にアクセス
2. プロジェクトを選択
3. **Firestore Database** > **ルール** を開く
4. `firestore.rules` の内容をコピー＆ペースト
5. **公開** をクリック

#### Storageセキュリティルール

1. Firebase Console で **Storage** > **ルール** を開く
2. `storage.rules` の内容をコピー＆ペースト
3. **公開** をクリック

#### Firestoreインデックス

1. Firebase Console で **Firestore Database** > **インデックス** を開く
2. `firestore.indexes.json` の各インデックスを手動で作成するか、
3. または、アプリを実行してクエリエラーが発生した際に表示されるリンクからインデックスを自動作成

### 方法2: Firebase CLI

#### 前提条件

```bash
# Firebase CLIをインストール（未インストールの場合）
npm install -g firebase-tools

# Firebaseにログイン
firebase login

# プロジェクトを初期化（初回のみ）
firebase init firestore
firebase init storage
```

#### デプロイコマンド

```bash
# Firestoreルールとインデックスをデプロイ
firebase deploy --only firestore:rules
firebase deploy --only firestore:indexes

# Storageルールをデプロイ
firebase deploy --only storage
```

---

## テスト

### Firestoreルールのテスト

Firebase Console でルールをテストできます：

1. **Firestore Database** > **ルール** > **ルールプレイグラウンド**
2. テストケースを入力して実行

**テストケース例:**

```javascript
// ケース1: 認証済みユーザーが自分の投稿を作成
service: cloud.firestore
path: /databases/(default)/documents/posts/test-post-123
auth: { uid: "user123" }
method: create
data: {
  postId: "test-post-123",
  userId: "user123",
  images: [{ url: "https://example.com/image.jpg" }],
  visibility: "public",
  likesCount: 0,
  commentsCount: 0,
  createdAt: timestamp.now(),
  updatedAt: timestamp.now()
}
// 結果: 許可されるべき

// ケース2: 認証済みユーザーが他人の投稿を削除しようとする
service: cloud.firestore
path: /databases/(default)/documents/posts/other-post-456
auth: { uid: "user123" }
method: delete
resource: { userId: "user456" }
// 結果: 拒否されるべき
```

### Storageルールのテスト

1. **Storage** > **ルール** > **ルールプレイグラウンド**
2. テストケースを入力して実行

---

## トラブルシューティング

### よくあるエラー

#### 1. "Missing or insufficient permissions"

**原因:** セキュリティルールで拒否されている

**解決方法:**
- ユーザーが認証済みか確認
- ドキュメントの `userId` がリクエストユーザーの UID と一致しているか確認
- セキュリティルールが正しくデプロイされているか確認

#### 2. "The query requires an index"

**原因:** 必要なインデックスが作成されていない

**解決方法:**
- エラーメッセージ内のリンクをクリックして自動作成
- または、`firestore.indexes.json` をデプロイ

#### 3. "Image too large"

**原因:** 画像サイズが制限を超えている

**解決方法:**
- 投稿画像: 最大5MB
- プロフィール画像: 最大2MB
- アプリ側で圧縮してからアップロード

#### 4. "Invalid file type"

**原因:** 許可されていないファイルタイプ

**解決方法:**
- 許可されている形式: JPEG, PNG, WEBP, HEIC
- 適切な形式に変換してからアップロード

---

## セキュリティベストプラクティス

### 1. 最小権限の原則

- ユーザーは自分のデータのみアクセス可能
- 公開データ以外は適切に制限

### 2. データ検証

- フィールドの型、長さ、範囲を検証
- 不正なデータの挿入を防ぐ

### 3. 認証の必須化

- すべての書き込み操作は認証が必要
- 匿名ユーザーは読み取りのみ（公開データ）

### 4. 定期的な監査

- Firebase Console でセキュリティルールを定期的に確認
- アクセスログを監視

### 5. テスト

- セキュリティルールの変更時は必ずテスト
- 境界ケースを確認

---

## 参考資料

- [Firebase Security Rules](https://firebase.google.com/docs/rules)
- [Firestore Security Rules](https://firebase.google.com/docs/firestore/security/get-started)
- [Storage Security Rules](https://firebase.google.com/docs/storage/security)
- [Firestore Indexes](https://firebase.google.com/docs/firestore/query-data/indexing)

---

## まとめ

このガイドでは、そらもようアプリのFirebaseセキュリティルールとインデックスについて説明しました。

**作成されたファイル:**
- ✅ `firestore.rules` - Firestoreセキュリティルール
- ✅ `storage.rules` - Storageセキュリティルール
- ✅ `firestore.indexes.json` - Firestoreインデックス定義

**次のステップ:**
1. Firebase Consoleまたは Firebase CLI でルールをデプロイ
2. インデックスを作成
3. アプリをテストして動作確認

セキュリティは重要です！本番環境にデプロイする前に、必ずテストしてください。
