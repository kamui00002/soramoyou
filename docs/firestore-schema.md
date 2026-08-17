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
  "customEditToolsOrder": ["string"], // 表示順
  "fcmToken": "string",               // プッシュ通知の登録トークン（端末ごと・PushNotificationManagerが保存／無効時に自動削除）
  "fcmTokenUpdatedAt": "timestamp",   // fcmToken の更新時刻
  "notifyReactions": "boolean",       // 通知: 自分の投稿への いいね/コメント（既定 true・欠落=true）
  "notifyNewPostsFromFollowing": "boolean", // 通知: フォロー中の人の新規投稿（既定 true・欠落=true）
  "notifyNewPostsFromEveryone": "boolean"   // 通知: 誰かの新規投稿＝全員（既定 false・欠落=false）
}
```
- 通知プレフ3つの既定値は **iOS `User.swift` と Cloud Functions `functions/index.js` の `PREF_DEFAULTS` で一致必須**（reactions=true / following=true / everyone=false）。旧ユーザーはフィールド欠落＝既定で動く。
- `fcmToken` は Cloud Functions（送信側）のみが読む。クライアントは書き込み専用（merge）。送信時に無効トークンは自動削除。
- 送信トリガー: `likes`/`comments`/`posts` のドキュメント作成（`functions/index.js`）。デプロイには Blaze プラン＋APNs認証キーが必要。

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
  "postKind": "string",              // 投稿種別(single/collage/panorama)。未設定=single相当。collage/panoramaは合成済み1枚をimagesに保存
  "collageLayout": "string",         // 配置写真レイアウト(grid2x2/vertical4)。postKind=collage時のみ
  "panelLabels": ["string"],         // 配置写真の各パネルの一言(朝/昼/夕/夜=「空の一日」等・自由/任意)。collage時のみ
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

## feedback コレクション（アプリ内フィードバック）
```json
{
  "feedbackId": "string (ドキュメントID)",
  "userId": "string",                // 送信者（auth.uid と一致が必須）
  "message": "string",               // 本文（1〜1000文字）
  "category": "string",              // 種別 bug/request/other（任意）
  "appVersion": "string",            // 例 "1.7.4 (57)"（任意・トラブル切り分け用）
  "deviceInfo": "string",            // 例 "iOS 18.5 / iPhone"（任意）
  "createdAt": "timestamp"           // serverTimestamp
}
```
- セキュリティ: 作成は認証済みユーザーが自分のIDでのみ（rules `hasAll(['userId','message','createdAt'])` + message 1〜1000文字）。**読み取り・更新・削除は不可**（管理者が Firebase コンソールで閲覧）。
- email・表示名などの PII は保存しない（userId のみ）。
- 副作用: ドキュメント作成で Cloud Functions `notifyFeedbackToDiscord`（`functions/index.js`）が発火し、開発者の Discord へ Webhook 通知する。Webhook URL は Secret Manager `DISCORD_WEBHOOK_URL`（コードに実値なし）。デプロイには Blaze ＋ `firebase functions:secrets:set DISCORD_WEBHOOK_URL` が必要。

## livingSkyJobs コレクション（「空を動かす」β・Kling版）
```json
{
  "id": "string (ドキュメントID)",      // doc ID と一致（rules で強制）
  "userId": "string",                    // 所有者（request.auth.uid）
  "status": "string",                    // pending → submitting → submitted → completed/failed
  "sourcePath": "string",                // livingSky/{uid}/{jobId}/source.jpg（rules で厳密一致必須）
  "skyMaskPath": "string",               // livingSky/{uid}/{jobId}/sky_mask.png（rules で厳密一致必須）
  "groundMaskPath": "string",            // livingSky/{uid}/{jobId}/ground_mask.png（rules で厳密一致必須）
  "aspectRatio": "string",               // "16:9" | "9:16" | "1:1"（近似選択済み）
  "trajectory": [{ "x": "number", "y": "number" }], // sky_mask重心 → 幅10%水平ドリフトの2点
  "loopDuration": "string",              // client設定。"short"/"medium"/"long" → サーバーのsetpts係数(1.3/1.5/1.7)
  "chargedBucket": "string",             // function専用。予約時にどちらから引いたか("free"/"paid")。返金の生命線
  "quotaReason": "string",               // function専用。quota_exceeded の内訳(free_exhausted_no_balance/paid_daily_cap)
  "falRequestId": "string",              // function専用。submit成功後に設定
  "videoURL": "string",                  // function専用。完成後のStorageダウンロードURL
  "submittedAt": "timestamp",            // function専用。fal.aiへのsubmit成功時刻。pollタイムアウト判定の基準
  "pollAttempts": "number",              // function専用。ポーラーの試行回数
  "errorCode": "string",                 // forbidden/quota_exceeded/submit_failed/downstream_unavailable/timeout 等
  "error": "string",                     // エラーの人間可読メッセージ
  "createdAt": "timestamp",              // client設定（serverTimestamp()。rulesでrequest.timeと一致必須）
  "updatedAt": "timestamp"               // functionが状態遷移のたびに更新
}
```
- クライアントが書けるのは **画像3枚のアップロード**（Storage）と **status="pending" の初期ドキュメント作成のみ**。以降の状態遷移は Cloud Functions（Admin SDK）専用（`update`/`delete` は client から一律禁止）。
- **アクセス制御**: custom claim `skyMotionBeta == true`（allowlist）が create に必須。Cloud Functions側でも Admin SDK 経由で再検証する（多層防御）。到達範囲は DEBUG ビルド＋Release/TestFlight の claim 保有者。
- 失敗時の返金は `chargedBucket` の側だけを戻す。返金＋failed遷移は1トランザクション（`isRefundableJob`=submitting/submittedのみ許可）で、二重返金・completed巻き戻りを防ぐ。
- 詳細な契約・rules条件・状態遷移図は `docs/sky-motion-design.md` 参照。

## livingSkyUsage コレクション（「空を動かす」・1日あたりの利用回数カウンタ）
```json
{
  "uid": "string (ドキュメントID)",
  "day": "string",              // JST "YYYY-MM-DD"（lazy reset。日次cronは使わない）
  "freeUsedToday": "number",    // 当日の無料枠使用数（上限: 一般1回/β3回。reserve-on-create + refund-on-failure）
  "paidUsedToday": "number",    // 当日の購入枠使用数（上限20回=乗っ取り時の被害上限）
  "freeLimit": "number",        // 当日の無料枠上限（サーバーが書く。clientの「あとN回」表示の真実源＝二重管理しない）
  "reservedCount": "number",    // 【旧・後方互換】β時代の単一カウンタ。新規書き込みなし。読み取り時はfreeUsedTodayとして解釈
  "updatedAt": "timestamp"
}
```
- 読み取りは所有者のみ、書き込みは一律不可（予約・返金は Cloud Functions 専用）。
- **カウンタは3本**（free/paid/balance）。1本だと「無料を使い切ったか」と「今日あと何回買った枠を使えるか」を同時に表現できない。残高は `skyMotionBalance` 側（日付非依存）。
- 詳細は `docs/sky-motion-design.md` §2 参照。

## skyMotionPurchases コレクション（「空を動かす」回数パックの購入記録）
```json
{
  "transactionId": "string (ドキュメントID)", // StoreKitのtransactionId。doc ID=冪等キー（同じ購入は同じdoc）
  "userId": "string",                // client申告の購入者（auth.uid と一致必須）
  "status": "string",                // pending → credited/failed。**failed=クライアントにfinish()を許すシグナル**
  "jws": "string",                   // VerificationResult.jwsRepresentation（署名付き）。サーバーがAppleルートCAで検証
  "productId": "string",             // サーバーが検証済みJWSの値で上書き（client申告は信用しない）
  "creditedCount": "number",         // function専用。付与したクレジット数
  "creditedUid": "string",           // function専用。実際の付与先（appAccountToken不一致時はuserIdと異なりうる・監査用）
  "environment": "string",           // function専用。"Production"/"Sandbox"（検証が通った環境）
  "verifyAttempts": "number",        // function専用。リコンサイラの再試行回数（上限10で verification_timeout）
  "errorCode": "string",             // verification_failed/transaction_id_mismatch/unknown_product/verification_timeout 等
  "error": "string",
  "createdAt": "timestamp",          // serverTimestamp（rulesでrequest.timeと一致必須）
  "updatedAt": "timestamp"
}
```
- create は **skyMotionBeta claim 保有者**が自分のIDで status="pending"+jws のみ（jws は100KB未満）。update/delete は client から一律禁止。
- 検証は `onSkyMotionPurchaseCreated`、pending 詰まりは `reconcilePendingSkyMotionPurchases`（5分毎）が拾い直す。JWS検証の**一時的失敗**（OCSP不調）では failed にしない（pendingのまま残す）。
- 付与先は JWS 内の `appAccountToken`（`users.iapAccountToken` と照合・不一致なら逆引きで本来の購入者へ付け替え）で確定する。

## skyMotionBalance コレクション（「空を動かす」の購入クレジット残高）
```json
{
  "uid": "string (ドキュメントID)",
  "balance": "number",          // 残高（購入で+パック数/生成予約で-1/生成失敗で+1）。日付と無関係な資産
  "updatedAt": "timestamp"
}
```
- 読み取りは所有者のみ（client は**表示用**に読むだけ）、書き込みは一律不可。**残高の真実源はサーバー**＝生成可否の判定は必ず `reserveAndClaimJob`（Cloud Functions）が行う。
- 加算=購入検証Function / 減算=予約 / 返金=failJob。いずれも該当ドキュメント群と同一トランザクション。

## users への追加フィールド（回数パック関連）
```json
{
  "iapAccountToken": "string"   // 購入用の安定UUID（小文字）。初回購入時にclientが生成・永続化。
                                // StoreKitのappAccountTokenに渡し、サーバーが「本当の購入者」の照合に使う
}
```

## publicProfiles コレクション — 書き込み契約 ⭐️

- **`followersCount` / `followingCount` はクライアント書き込み対象外**。正典はCloud Functions（`onFollowCreated` / `onFollowDeleted`）が `follows` を `count()` した結果を代入する値。
- クライアントからプロフィールを更新するときは `updatePublicProfileFields`（`displayName` / `photoURL` / `bio` のみを `updateData`）を使う。`PublicProfile` 全体を書くとクライアントが持つ古いカウンタでサーバーの真値を潰す。
- 更新失敗時は `publicProfiles/{userId}` の存在を `get` で確認して分岐する（不在＝新規作成、存在＝更新失敗）。`update` ルールが `resource.data.id` を参照するため、ドキュメント不在でも `NOT_FOUND` ではなく `PERMISSION_DENIED` が返りうるので、**エラーコードで不在判定してはいけない**。

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
