# セキュリティ修正デプロイメントガイド

## 完了済みタスク ✅

### 1. Firestoreセキュリティルールのデプロイ
**ステータス**: ✅ 完了

Firestoreセキュリティルールを更新し、デプロイしました。

**変更内容**:
- `/users` コレクション: 所有者のみアクセス可能（email、blockedUserIds等の機密情報を保護）
- `/publicProfiles` コレクション: 認証済みユーザーが読み取り可能（公開情報のみ）

**デプロイ結果**:
```
✔  cloud.firestore: rules file firestore.rules compiled successfully
✔  firestore: released rules firestore.rules to cloud.firestore
✔  Deploy complete!
```

### 2. データ移行スクリプトの作成
**ステータス**: ✅ 完了

`migrate-public-profiles.js` スクリプトを作成しました。

**機能**:
- 既存の `users` コレクションから公開プロフィール情報を抽出
- `publicProfiles` コレクションに保存
- バッチ処理で500件ずつ効率的に移行
- エラーハンドリングと進捗表示

**実行方法**:

1. Firebase Admin SDKをインストール:
```bash
npm install firebase-admin
```

2. サービスアカウントキーをダウンロード:
   - Firebase Console > Project Settings > Service Accounts
   - "Generate New Private Key" をクリック
   - ダウンロードしたJSONファイルを `serviceAccountKey.json` として保存

3. スクリプトを実行:
```bash
node migrate-public-profiles.js
```

4. 確認プロンプトで `yes` を入力して実行

**注意**:
- 既存の `publicProfiles` コレクションにデータがある場合は上書きされます
- 実行前にバックアップを推奨します

---

## 手動操作が必要なタスク ⚠️

### 3. XcodeプロジェクトへのPublicProfile.swift追加

**ファイルの場所**:
```
Soramoyou/Soramoyou/Models/PublicProfile.swift
```

**追加手順**:

1. Xcodeで `Soramoyou.xcodeproj` を開く

2. プロジェクトナビゲータで `Soramoyou` > `Models` フォルダを右クリック

3. "Add Files to Soramoyou..." を選択

4. `PublicProfile.swift` ファイルを選択

5. 以下のオプションを確認:
   - ✅ Copy items if needed (チェック不要 - 既にプロジェクト内にある)
   - ✅ Create groups (選択)
   - ✅ Add to targets: Soramoyou (チェック)

6. "Add" をクリック

7. ビルドして確認:
   ```
   Command + B
   ```

**確認方法**:
- プロジェクトナビゲータで `Models` フォルダ内に `PublicProfile.swift` が表示される
- ビルドエラーが発生しないことを確認

---

## 修正内容のまとめ

### セキュリティ脆弱性
**重大度**: HIGH
**タイプ**: Authorization Bypass
**影響範囲**: PII（個人識別情報）の露出

### 修正アプローチ
公開情報と機密情報を別コレクションに分離:

**機密情報** (`users` コレクション - 所有者のみアクセス):
- email
- blockedUserIds

**公開情報** (`publicProfiles` コレクション - 認証済みユーザーがアクセス):
- id
- displayName
- photoURL
- bio
- customEditTools
- customEditToolsOrder
- followersCount, followingCount, postsCount
- createdAt, updatedAt

### コード変更

#### 新規ファイル
- `Soramoyou/Soramoyou/Models/PublicProfile.swift`

#### 変更ファイル
- `firestore.rules` - セキュリティルール更新
- `Soramoyou/Soramoyou/Services/FirestoreService.swift` - 公開プロフィールメソッド追加
- `Soramoyou/Soramoyou/ViewModels/AuthViewModel.swift` - サインアップ時に両コレクション作成
- `Soramoyou/Soramoyou/ViewModels/ProfileViewModel.swift` - 適切なコレクションを使用

---

## 次のステップ

1. ✅ Firestoreルールはデプロイ済み（即座に適用）

2. ⚠️ **XcodeでPublicProfile.swiftを追加** (上記手順参照)

3. ⚠️ **データ移行スクリプトを実行** (既存ユーザーがいる場合)
   ```bash
   node migrate-public-profiles.js
   ```

4. ⚠️ **アプリをビルド＆テスト**
   - 新規ユーザー登録が正常に動作するか
   - 既存ユーザーのプロフィール表示が正常か
   - 他ユーザーのプロフィール表示が正常か

5. ⚠️ **コミット＆プッシュ**
   ```bash
   git add .
   git commit -m "修正: Authorization Bypass脆弱性の修正 - 公開/機密プロフィール分離"
   git push
   ```

---

## トラブルシューティング

### ビルドエラー: "No such module 'FirebaseFirestore'"
- Pod installを実行: `cd Soramoyou && pod install`
- Xcodeを再起動

### 移行スクリプトエラー: "serviceAccountKey.json not found"
- Firebase Consoleからサービスアカウントキーをダウンロード
- プロジェクトルートに `serviceAccountKey.json` として保存

### プロフィール表示エラー
- Firestoreルールが正しくデプロイされているか確認
- Firebase Consoleで `publicProfiles` コレクションにデータが存在するか確認
- アプリを再起動してキャッシュをクリア

---

## 完了確認チェックリスト

- [x] Firestoreセキュリティルールのデプロイ
- [x] データ移行スクリプトの作成
- [ ] XcodeプロジェクトへのPublicProfile.swift追加
- [ ] データ移行スクリプトの実行（既存ユーザーがいる場合）
- [ ] アプリのビルド＆動作確認
- [ ] コミット＆プッシュ

---

**作成日**: 2026-02-16
**対応PR**: 機能-AppStore申請準備
