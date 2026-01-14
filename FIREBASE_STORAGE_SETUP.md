# Firebase Storage セットアップガイド

## 初回セットアップ手順

### 1. Firebase Console での有効化（必須・初回のみ）

1. ブラウザで以下のURLを開く:
   ```
   https://console.firebase.google.com/project/soramoyou-ios/storage
   ```

2. "Get Started" をクリック

3. セキュリティルールの選択:
   - 「本番環境モード」を選択
   - （後でCLIでデプロイするため、ここでの選択は上書きされます）

4. ロケーションの選択:
   - `asia-northeast1` (東京) を選択
   - Firestoreと同じリージョンを使用

5. "完了" をクリック

### 2. セキュリティルールのデプロイ

Console でのセットアップ完了後、ターミナルで以下を実行:

```bash
cd /Users/yoshidometoru/そらもよう
firebase deploy --only storage
```

## Storage構造

```
{bucket}/
├── users/{userId}/profile/{imageId}      # プロフィール画像
├── posts/{userId}/
│   ├── public/{imageId}                  # 公開投稿
│   ├── followers/{imageId}               # フォロワー限定投稿
│   └── private/{imageId}                 # プライベート投稿
└── drafts/{userId}/{imageId}             # 下書き画像
```

## セキュリティルール概要

### アクセス制御
- **プロフィール画像**: 認証ユーザーが読み取り可、所有者のみ書き込み可
- **公開投稿**: 全員読み取り可、所有者のみ書き込み可
- **フォロワー限定投稿**: 認証ユーザーのみ読み取り可、所有者のみ書き込み可
- **プライベート投稿**: 所有者のみ読み取り・書き込み可
- **下書き画像**: 所有者のみアクセス可

### ファイル制限
- **サイズ制限**: 最大5MB
- **タイプ制限**: 画像ファイルのみ (MIME type: `image/*`)

## 検証コマンド

セットアップが完了したか確認:

```bash
# Storage情報の確認
firebase projects:list

# ルールのデプロイテスト
firebase deploy --only storage --dry-run
```

## トラブルシューティング

### エラー: "Firebase Storage has not been set up"
- Firebase Console で Storage を有効化していない
- 上記の「1. Firebase Console での有効化」を実行してください

### エラー: "Permission denied"
- Firebase CLI のログイン確認: `firebase login`
- プロジェクト選択確認: `firebase use soramoyou-ios`

### エラー: "Invalid location"
- ロケーションは初回セットアップ時のみ選択可能
- 変更が必要な場合は、Firebase Consoleで新しいバケットを作成

## iOS アプリでの使用例

```swift
import FirebaseStorage

// Storage reference
let storage = Storage.storage()
let storageRef = storage.reference()

// プロフィール画像のアップロード
let profileRef = storageRef.child("users/\(userId)/profile/\(imageId).jpg")
let uploadTask = profileRef.putData(imageData, metadata: nil)

// 公開投稿画像のアップロード
let publicPostRef = storageRef.child("posts/\(userId)/public/\(imageId).jpg")
```

## 関連ファイル

- セキュリティルール: `/Users/yoshidometoru/そらもよう/storage.rules`
- Firebase設定: `/Users/yoshidometoru/そらもよう/firebase.json`
- Firestore ルール: `/Users/yoshidometoru/そらもよう/firestore.rules`

## 次のステップ

1. ✅ Firebase Storage の有効化（Console）
2. ✅ セキュリティルールのデプロイ（CLI）
3. ⬜ iOS アプリへの Storage SDK 統合
4. ⬜ 画像アップロード機能の実装
5. ⬜ 画像取得機能の実装
