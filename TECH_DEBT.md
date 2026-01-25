# 技術的負債（Technical Debt）

このドキュメントは、プロジェクトの技術的負債と将来の改善点を記録します。

## セキュリティ関連

### 1. Private/Followers投稿の画像アクセス制御（優先度: 高）

**現状の問題点:**
- Firebase StorageのdownloadURL()には誰でもアクセス可能なURLが含まれている
- URLを知っている第三者がFirestore権限をバイパスして画像に直接アクセス可能
- Storage rulesではFirestoreのフォロワー関係をチェックできない

**フェーズ1の対応（実装済み）:**
- ✅ Firestore Security Rulesの強化
- ✅ クライアント側での権限チェック
- ✅ 技術的負債の明確化とドキュメント化

**フェーズ2の対応（将来実装）:**

#### オプション1: Signed URLの活用
```swift
// Firebase Cloud Functionsを使用してSigned URLを生成
// 利点: 一時的なアクセス権限、有効期限設定可能
// 欠点: Cloud Functions使用によるコスト増加
```

**実装例:**
```javascript
// Cloud Functions
exports.getSignedImageUrl = functions.https.onCall(async (data, context) => {
  const { postId, imageIndex } = data;

  // 1. Firestoreで権限チェック
  const post = await admin.firestore().collection('posts').doc(postId).get();
  const postData = post.data();

  // 2. アクセス権限を確認
  if (postData.visibility === 'private' && postData.userId !== context.auth.uid) {
    throw new functions.https.HttpsError('permission-denied', 'No access');
  }

  if (postData.visibility === 'followers') {
    const isFollower = await checkFollowerStatus(context.auth.uid, postData.userId);
    if (!isFollower && postData.userId !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Not a follower');
    }
  }

  // 3. Signed URLを生成（有効期限1時間）
  const bucket = admin.storage().bucket();
  const file = bucket.file(postData.images[imageIndex].path);
  const [url] = await file.getSignedUrl({
    action: 'read',
    expires: Date.now() + 60 * 60 * 1000 // 1時間
  });

  return { url };
});
```

**クライアント側:**
```swift
// PostViewModel.swift に追加
func getSecureImageURL(postId: String, imageIndex: Int) async throws -> URL {
    let functions = Functions.functions()
    let getSignedUrl = functions.httpsCallable("getSignedImageUrl")

    let result = try await getSignedUrl.call([
        "postId": postId,
        "imageIndex": imageIndex
    ])

    guard let data = result.data as? [String: Any],
          let urlString = data["url"] as? String,
          let url = URL(string: urlString) else {
        throw StorageServiceError.invalidURL
    }

    return url
}
```

#### オプション2: Cloud Storage for Firebaseのカスタムトークン
```swift
// Storage参照パスのみをFirestoreに保存し、
// クライアント側でStorage参照を取得してダウンロード
// Storage rulesで認証とowner/followerチェック
```

**実装例:**
```swift
// StorageService.swift に追加
func getSecureImageReference(path: String, postId: String) async throws -> StorageReference {
    // 1. Firestoreで権限チェック
    let hasAccess = try await checkPostAccess(postId: postId)
    guard hasAccess else {
        throw StorageServiceError.accessDenied
    }

    // 2. Storage参照を返す（Storage rulesでさらにチェック）
    return storage.reference().child(path)
}

// 画像ダウンロード
func downloadSecureImage(path: String, postId: String) async throws -> Data {
    let ref = try await getSecureImageReference(path: path, postId: postId)
    let data = try await ref.data(maxSize: 5 * 1024 * 1024)
    return data
}
```

#### オプション3: プロキシサーバーの構築
- 画像リクエストを中継する専用サーバー
- アクセスログの記録とレート制限
- 最も堅牢だがインフラコストが高い

**推奨アプローチ（Phase 2での実装）:**
1. **短期**: オプション2（Storage参照パス保存）
   - コスト増加なし
   - 実装が比較的シンプル
   - Firestore + Storage rulesの2段階チェック

2. **中期**: オプション1（Signed URL）
   - より強固なセキュリティ
   - 有効期限管理が可能
   - Cloud Functionsのコストが発生

3. **長期**: オプション3（必要に応じて）
   - エンタープライズレベルのセキュリティ
   - アクセス解析とレート制限
   - インフラコストと運用コストが高い

**実装スケジュール:**
- Phase 2のフォロー機能実装時にオプション2を実装予定
- ユーザー数が増加した場合にオプション1へ移行を検討

**関連ファイル:**
- `Soramoyou/Soramoyou/Services/StorageService.swift`
- `Soramoyou/Soramoyou/ViewModels/PostViewModel.swift`
- `firestore.rules`
- `storage.rules`

---

## パフォーマンス関連

### 1. 画像の遅延読み込み（優先度: 中）

**現状:**
- フィード画面で全画像を一度に読み込み

**改善案:**
- LazyVGridでの遅延読み込み実装
- サムネイル優先表示、高解像度は必要時のみ

---

## アーキテクチャ関連

### 1. ViewModelのテスト改善（優先度: 中）

**現状:**
- 一部のViewModelでテストカバレッジが不足

**改善案:**
- モックサービスの活用
- エッジケースのテストケース追加

---

## 更新履歴

- 2026-01-26: private/followers投稿のセキュリティ問題を記録
