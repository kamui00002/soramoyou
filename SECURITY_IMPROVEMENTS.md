# private/followers投稿のセキュリティ改善報告

## 概要

Codexのコードレビューで指摘された「private/followers投稿のセキュリティ問題」に対して、Phase 1の短期対応を実施しました。

## 問題点の詳細

### 1. Firebase Storageの仕様上の制限
- Firebase StorageのdownloadURL()には誰でもアクセス可能なトークンが含まれる
- このURLを知っている第三者がFirestore権限をバイパスして画像に直接アクセス可能
- Storage rulesではFirestoreのフォロワー関係をチェックできない

### 2. セキュリティリスク
- private投稿やfollowers投稿の画像URLが漏洩した場合、権限制御が無効化される
- ネットワークトラフィックの傍受やログの漏洩でURLが露出する可能性
- 現在のStorage rulesでは完全な権限制御ができない

## 実施した対応（Phase 1）

### 1. 技術的負債の文書化（TECH_DEBT.md）
- **目的**: 問題点と将来の改善策を明確に記録
- **内容**:
  - 現状の問題点と制限事項
  - Phase 2での実装オプション（3つ）
  - 推奨アプローチと実装スケジュール

### 2. Firestore Security Rulesの強化
- **ファイル**: `firestore.rules`
- **変更内容**:
  - セキュリティノートの追加
  - 現在の制限事項の明記
  - Phase 2での対応方針の記載

### 3. Storage Rulesのドキュメント改善
- **ファイル**: `storage.rules`
- **変更内容**:
  - 詳細な注意事項セクションの追加
  - 既知の制限事項の明確化
  - 現在の対応とPhase 2での改善予定の記載

### 4. クライアント側の権限チェック機能追加
- **ファイル**: `Soramoyou/Soramoyou/Services/FirestoreService.swift`
- **追加機能**: `canAccessPost(_:currentUserId:)` メソッド
- **機能詳細**:
  - 投稿の公開設定（visibility）に基づく権限チェック
  - public投稿: 誰でもアクセス可能
  - private投稿: 投稿者のみアクセス可能
  - followers投稿: Phase 2でフォロワーチェックを実装予定（現在は投稿者のみ）
- **使用方法**:
  ```swift
  let canAccess = try await firestoreService.canAccessPost(post, currentUserId: userId)
  if canAccess {
      // 画像を表示
  } else {
      // アクセス拒否メッセージを表示
  }
  ```

### 5. コード全体への警告コメント追加
- **対象ファイル**:
  - `StorageService.swift`: uploadImage()メソッド
  - `PostViewModel.swift`: uploadImages()メソッド
  - `HomeView.swift`: 画像表示処理
- **追加内容**:
  - セキュリティに関する重要な注意事項
  - 現在の制限事項の説明
  - Phase 2での改善予定の記載
  - TECH_DEBT.mdへの参照

### 6. README更新
- **追加セクション**: 「セキュリティに関する重要な情報」
- **内容**:
  - Phase 1の現在の実装と制限事項
  - Phase 2での改善予定
  - TECH_DEBT.mdへのリンク
  - プロジェクト構成にTECH_DEBT.mdを追加

## Phase 2での改善予定

### オプション1: Signed URLの活用（推奨）
- **実装方法**: Cloud Functionsを使用してSigned URLを生成
- **利点**:
  - 一時的なアクセス権限の付与
  - 有効期限の設定が可能
  - アクセス時の動的な権限チェック
- **欠点**:
  - Cloud Functions使用によるコスト増加
  - レスポンス時間の増加（関数呼び出しのオーバーヘッド）

### オプション2: Storage参照パスのみを保存
- **実装方法**: URLの代わりにStorage参照パスをFirestoreに保存
- **利点**:
  - コスト増加なし
  - 実装が比較的シンプル
  - Firestore + Storage rulesの2段階チェック
- **欠点**:
  - Storage rulesではフォロワー関係をチェックできない制限は残る

### オプション3: プロキシサーバーの構築
- **実装方法**: 画像リクエストを中継する専用サーバー
- **利点**:
  - 最も堅牢なセキュリティ
  - アクセスログの記録とレート制限
  - 完全なアクセス制御
- **欠点**:
  - インフラコストと運用コストが高い
  - 実装の複雑性が増加

### 推奨アプローチ
1. **短期（Phase 2）**: オプション2（Storage参照パス保存）を実装
2. **中期**: ユーザー増加に応じてオプション1（Signed URL）へ移行
3. **長期**: 必要に応じてオプション3（プロキシサーバー）を検討

## ビルド確認

以下のコマンドでビルドエラーがないことを確認済み:
```bash
xcodebuild -project Soramoyou/Soramoyou.xcodeproj \
  -scheme Soramoyou \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

結果: **BUILD SUCCEEDED**

## 関連ファイル

### 新規作成
- `TECH_DEBT.md`: 技術的負債とセキュリティ改善計画

### 変更ファイル
- `README.md`: セキュリティ情報セクション追加
- `firestore.rules`: セキュリティノート追加
- `storage.rules`: 詳細な注意事項追加
- `Soramoyou/Soramoyou/Services/FirestoreService.swift`: canAccessPost()メソッド追加
- `Soramoyou/Soramoyou/Services/StorageService.swift`: セキュリティ警告コメント追加
- `Soramoyou/Soramoyou/ViewModels/PostViewModel.swift`: セキュリティ警告コメント追加
- `Soramoyou/Soramoyou/Views/Home/HomeView.swift`: セキュリティ注意事項追加

## まとめ

### 実施した対応
✅ 技術的負債の文書化（TECH_DEBT.md）
✅ Firestore/Storage rulesへの注意事項追加
✅ クライアント側権限チェック機能（canAccessPost）の実装
✅ コード全体への警告コメント追加
✅ README更新
✅ ビルド確認（成功）

### 今後の対応
📅 **Phase 2**: フォロー機能実装時にSigned URLまたはStorage参照パス方式を実装
📅 **ユーザー増加時**: より強固なアクセス制御への移行を検討

### 重要事項
⚠️ **現在のPhase 1では**、Firebase StorageのdownloadURL()を使用しているため、URLが漏洩した場合は画像に直接アクセスされる可能性があります。Phase 2での改善が必要です。

✅ **Firestoreレベル**では、投稿の読み取り権限が厳格に管理されており、権限のないユーザーは投稿メタデータ（画像URL含む）を取得できません。

---

作成日: 2026-01-26
担当: Claude Sonnet 4.5
