# Firestore スキーマ ⭐️

## users コレクション
```json
{
  "userId": "string (ドキュメントID)",
  "email": "string",
  "displayName": "string",
  "photoURL": "string",
  "bio": "string",
  "createdAt": "timestamp",
  "updatedAt": "timestamp",
  "followersCount": "number",
  "followingCount": "number",
  "postsCount": "number",
  "customEditTools": ["string"],      // 選択した編集ツール名
  "customEditToolsOrder": ["string"]  // 表示順
}
```

## posts コレクション
```json
{
  "postId": "string (ドキュメントID)",
  "userId": "string",
  "images": [
    {
      "url": "string",
      "thumbnail": "string",
      "width": "number",
      "height": "number",
      "order": "number"
    }
  ],
  "caption": "string",
  "mood": "string",                  // 機能1: 気分(calm/uplifted/wistful/dignified/dreamy)。未設定なら無し
  "frameId": "string",               // 機能1: 枠ID "{mood}_{frameStyle}" 形式（例 calm_matte / wistful_bottomBand）。未設定なら無し
  "frameCaption": "string",          // 機能1: 額縁に焼く一言（通常 caption とは別）。未設定なら無し
  "frameTextColorHex": "string",     // 機能1: フレーム文字色 "#RRGGBB"。未設定なら無し＝style自動色（おまかせ）
  "frameFontStyle": "string",        // 機能1: フレーム文字フォント(standard/rounded/serif/mono)。未設定なら無し＝mood既定
  "hashtags": ["string"],
  "location": {
    "latitude": "number",
    "longitude": "number",
    "city": "string",
    "prefecture": "string",
    "landmark": "string"
  },
  "skyColors": ["string"],           // 16進数カラーコード（最大5色）
  "capturedAt": "timestamp",
  "timeOfDay": "string",             // morning, afternoon, evening, night
  "skyType": "string",               // clear, cloudy, sunset, sunrise, storm
  "colorTemperature": "number",      // K表示
  "visibility": "string",            // public, followers, private
  "likesCount": "number",
  "commentsCount": "number",
  "createdAt": "timestamp",
  "updatedAt": "timestamp"
}
```

## drafts コレクション
```json
{
  "draftId": "string (ドキュメントID)",
  "userId": "string",
  "images": [/* posts と同じ構造 */],
  "editedImages": ["string"],
  "editSettings": {
    "brightness": "number",
    "contrast": "number",
    "saturation": "number"
    // その他の編集パラメータ
  },
  "caption": "string",
  "hashtags": ["string"],
  "location": {/* posts と同じ構造 */},
  "visibility": "string",
  "createdAt": "timestamp",
  "updatedAt": "timestamp"
}
```

## follows コレクション（Phase 2）
```json
{
  "followId": "string (ドキュメントID)",
  "followerId": "string",
  "followingId": "string",
  "createdAt": "timestamp"
}
```

---

## Firebase使用時の重要事項

### セキュリティ
- ✅ APIキーは**必ず環境変数**で管理（`.env`ファイル）
- ✅ `.env`ファイルは`.gitignore`に追加
- ✅ Firestoreのセキュリティルールを適切に設定
- ✅ 認証状態を常に確認してからデータアクセス

### パフォーマンス
- ✅ 不要なリアルタイムリスナーは必ず削除
- ✅ クエリは必要最小限に（limitを活用）
- ✅ 画像は適切なサイズに圧縮してからアップロード

### 「そらもよう」特有のセキュリティ
- ✅ Firebase Security Rulesの設定（ユーザーは自分のデータのみ編集可能）
- ✅ 画像のアクセス制御（公開設定に応じた表示制限）
- ✅ 投稿の公開設定（public / followers / private）

### 「そらもよう」特有のパフォーマンス
- ✅ 画像の遅延読み込み（LazyLoad）
- ✅ サムネイル生成で通信量削減
- ✅ Firestoreクエリの最適化
- ✅ 画像圧縮（JPEG 80-90%、最大5MB）
- ✅ ページネーション実装（無限スクロール）

### 画像処理
- ✅ Core ImageフレームワークまたはCIFilterを使用
- ✅ リアルタイムプレビュー
- ✅ 編集パラメータの保存（下書き機能用）
- ✅ EXIF情報の読み取り
- ✅ 色分析アルゴリズムの実装

### ユーザビリティ
- ✅ ローディング表示
- ✅ エラーハンドリング
- ✅ オフライン対応（可能な範囲で）
- ✅ 未ログインユーザーの閲覧制限（写真3枚まで）
