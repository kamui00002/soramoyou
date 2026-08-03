# 空を動かす（Kling版）データ契約 ⭐️

> ⚠️ **`docs/living-sky-design.md`（Metal ローカル版 Living Sky）とは別機能**。
> こちらは Storage 中継＋非同期ジョブ＋外部API（fal.ai Kling）でクラウド側にmp4生成させる方式。
> 命名が近い（`livingSky*`）ため実装時に混同しないこと。Metal版は一時撤収済み（PR #66・DEBUG限定）。
> 本ドキュメントは **フェーズ0（データ契約）** の成果物。実装対象は別担当（Cloud Functions担当 /
> Swiftクライアント担当）。DEBUG限定のE2E検証が目的で、本番導線化はしない。

## 0. アーキテクチャ概要

```
[クライアント]
  1. 画像3枚を Storage へアップロード
     livingSky/{uid}/{jobId}/source.jpg
     livingSky/{uid}/{jobId}/sky_mask.png
     livingSky/{uid}/{jobId}/ground_mask.png
  2. Firestore livingSkyJobs/{jobId} を status="pending" で作成
  3. snapshot listener で status の変化を待つ

[Cloud Functions（別担当）]
  4. onDocumentCreated(livingSkyJobs/{jobId}) トリガーで受信
  5. allowlist（custom claim `skyMotionBeta==true`）を Admin SDK 経由で再検証
     （多層防御。firestore.rules は create 時点のトークンしか見ないため）
  6. livingSkyUsage/{uid} の reserve（予約）と job の status="pending"→"submitting" claim を
     単一トランザクションで実施（at-least-once 再配信対策も兼ねる）
  7. fal.ai Kling API へ submit → falRequestId・submittedAt を保存 → status="submitted"
  8. ポーリング（submittedAt 基準でタイムアウト判定）で完了を待つ → mp4 を Storage の
     livingSky/{uid}/{jobId}/output.mp4 に書き込み
  9. status="completed"（videoURL設定。以降は巻き戻さない）または
     status="failed"（error設定・chargedBucketの側へrefund・入力ファイル削除）
```

- クライアントが書けるのは **画像3枚のアップロード** と **status="pending" の初期ドキュメント作成のみ**。
  以降の状態遷移（submitting/submitted/completed/failed・falRequestId・videoURL 等）は
  **Cloud Functions（Admin SDK）専用**。
  Admin SDK は Firestore/Storage セキュリティルールをバイパスするため、client からの
  `update`/`write` を一律 `false` にしても実装上の障害にはならない（`firestore.rules` / `storage.rules` 参照）。
- **allowlist（custom claim `skyMotionBeta==true`）**: この機能はDEBUG限定E2E検証用だが、
  rules/Functions自体は本番デプロイされ全認証ユーザー（匿名認証・セルフサインアップ含む）に
  開いてしまうため、開発者 allowlist で締めるのが根本対策。`firestore.rules`（job create）・
  `storage.rules`（入力3ファイルの write）の両方で claim を要求し、Cloud Functions側でも
  `isBetaAllowed()`（Admin SDK `auth.getUser(uid).customClaims`）で再検証する（多層防御）。

---

## 1. `livingSkyJobs/{jobId}` スキーマ

| フィールド | 型 | 設定者 | 説明 |
|---|---|---|---|
| `id` | string | client | doc ID と一致（rules で強制） |
| `userId` | string | client | 所有者（`request.auth.uid`） |
| `status` | string | 両方 | `pending` → `submitting` → `submitted` → `completed` / `failed`（client が書けるのは初期 `pending` のみ。`submitting` は予約成立と同一トランザクションで claim される中間状態） |
| `sourcePath` | string | client | Storage パス（`livingSky/{uid}/{jobId}/source.jpg`。rules で厳密一致を強制） |
| `skyMaskPath` | string | client | Storage パス（`livingSky/{uid}/{jobId}/sky_mask.png`。rules で厳密一致を強制） |
| `groundMaskPath` | string | client | Storage パス（`livingSky/{uid}/{jobId}/ground_mask.png`。rules で厳密一致を強制） |
| `aspectRatio` | string | client | `"16:9"` \| `"9:16"` \| `"1:1"`（近似選択済み。実寸は §4 参照） |
| `trajectory` | array&lt;{x:int, y:int}&gt; | client | sky_mask 重心 → +40px 水平の2点（ピクセル座標） |
| `falRequestId` | string? | function | submit 成功後に設定 |
| `videoURL` | string? | function | 完成後の Storage ダウンロードURL |
| `submittedAt` | Timestamp? | function | fal.ai へのsubmit成功時に `serverTimestamp()` で記録。**pollのタイムアウト判定はこれを基準にする**（`createdAt` はclientが設定するため偽装可能。基準にしない） |
| `pollAttempts` | int | function | ポーラーの試行回数 |
| `errorCode` | string? | function | `forbidden` \| `quota_exceeded` \| `submit_failed` \| `downstream_unavailable` \| `timeout` 等 |
| `error` | string? | function | エラーの人間可読メッセージ |
| `createdAt` | Timestamp | 両方 | client が作成時に設定（`serverTimestamp()`。rules で `request.time` と一致必須＝偽装防止） |
| `updatedAt` | Timestamp | 両方 | function が状態遷移のたびに更新 |

> ⚠️ `retryCount` フィールドは廃止（未実装のため削除。Cloud Functions は書いておらず常に0の死にフィールドだった）。submit段階のリトライ回数を確認したい場合はログ（`fal submit失敗`）を参照する。

**セキュリティルール（`firestore.rules` に実装済み）**:
- `create`: 認証済み・**custom claim `skyMotionBeta == true`（allowlist）**・
  `userId == request.auth.uid`・`status == 'pending'`・`id == jobId`（doc ID一致）・
  `createdAt == request.time`（serverTimestamp偽装防止）・
  `sourcePath`/`skyMaskPath`/`groundMaskPath` が `livingSky/{uid}/{jobId}/{既定ファイル名}` と厳密一致・
  `falRequestId`/`videoURL` を含まない
- `read`: `resource.data.userId == request.auth.uid`（owner のみ）
- `update`, `delete`: 一律 `false`

---

## 2. `livingSkyUsage/{uid}` スキーマ（2026-08-03 Phase C＝回数パック課金で3カウンタ化）

| フィールド | 型 | 設定者 | 説明 |
|---|---|---|---|
| `day` | string | function | JST `"YYYY-MM-DD"` |
| `freeUsedToday` | int | function | 当日の無料枠使用数（上限: 一般1回 / β=claim保有者3回） |
| `paidUsedToday` | int | function | 当日の購入枠使用数（上限20回＝乗っ取り時の被害上限） |
| `freeLimit` | int | function | 当日の無料枠上限。client の「あとN回」表示の真実源（二重管理しない） |
| `reservedCount` | int | 【旧】 | β時代の単一カウンタ。新規書き込みなし。読み取り時は `freeUsedToday` として解釈（後方互換） |
| `updatedAt` | Timestamp | function | |

購入クレジット残高は別コレクション `skyMotionBalance/{uid}.balance`（日付非依存の資産）。
カウンタを3本に分けるのは、1本だと「無料を使い切ったか」と「今日あと何回買った枠を
使えるか」を同時に表現できないため。購入記録は `skyMotionPurchases/{transactionId}`
（詳細は `docs/firestore-schema.md`・`docs/sky-motion-billing-plan.md`）。

**lazy reset方式**: 日次cronは使わない。Cloud Functions がトランザクション内で
`day` を読み、当日と異なれば当日カウンタ=0 として扱ってから予約処理を行う
（ドキュメントが存在しない・`day` が古い、いずれも「未予約」として扱う）。

**reserve-on-create + refund-on-failure**:
1. ジョブ作成トリガー受信時、まず allowlist（custom claim `skyMotionBeta`）を
   Admin SDK 経由で再検証する（不許可なら `status="failed"` / `errorCode="forbidden"` にして
   **fal.ai を呼び出さない**。予約も行わない）
2. 許可されていれば、`livingSkyUsage/{uid}`＋`skyMotionBalance/{uid}` の予約とジョブの
   `status`（`pending`→`submitting`）の claim を**単一トランザクション**で行う。
   トランザクション内で job の最新状態をライブ読み取りし、`pending` でなければ何もしない
   （at-least-once 再配信対策・`isClaimableJob`）。判定は**無料枠優先→尽きたら購入残高**:
   - 無料枠が残っていれば `freeUsedToday += 1`（購入ぶんを温存＝ユーザー有利側）
   - 尽きて残高>0 なら `paidUsedToday += 1`・`balance -= 1`（日次上限20回）
   - どちらも不可なら `status="failed"` / `errorCode="quota_exceeded"` / `quotaReason` で
     理由を区別し **fal.ai を呼び出さない**（非課金）
   - **どちらから引いたかを `job.chargedBucket`（"free"/"paid"）に必ず保存する**
     （返金は別プロセス＝ポーラーで起きるため、job 自身が覚えていないと戻す先が分からない）
3. fal.ai 呼び出しが失敗（submit失敗・downstream不可・timeout）した場合、`failJob` が
   **返金＋`status="failed"` 遷移を単一トランザクション**で行う。トランザクション内で
   `isRefundableJob`（`status` が `submitting`/`submitted` のときのみ true）をライブ判定し、
   既に terminal なら no-op（**二重返金・completed の failed への巻き戻り・二重通知を防ぐ**）。
   返金は `chargedBucket` の側だけを戻す（free の失敗で残高を増やさない／paid の失敗で
   購入クレジットを取りこぼさない）。bucket は呼び出し元が `claim.bucket` /
   `job.chargedBucket` を引数で渡す（failJob 内で再読み取りしない）

**セキュリティルール（`firestore.rules` に実装済み）**:
- `read`: `isOwner(uid)`
- `write`: 一律 `false`（予約・返金は Cloud Functions 専用。client の `write:false` は
  Admin SDK の書き込みを妨げない）

---

## 3. Storage スキーマ

パス: `livingSky/{userId}/{jobId}/{fileName}`

| ファイル | 書き手 | 説明 |
|---|---|---|
| `source.jpg` | client | 元の空写真（編集確定後） |
| `sky_mask.png` | client | 空マスク（白=空）。`SkyMaskProviderProtocol` 出力を2値化したもの |
| `ground_mask.png` | client | 地上マスク（白=地上）。sky_mask の反転相当 |
| `output.mp4` | function（Admin SDK） | 生成された動画。client は Storage rules 経由では書けない（Admin SDK が rules をバイパスして書く） |

**セキュリティルール（`storage.rules` に実装済み）**:
- `read`: owner のみ（画像3枚＋完成後の `output.mp4` すべて）
- `write`: owner ＋ **custom claim `skyMotionBeta == true`（allowlist）** ＋
  `fileName in ['source.jpg', 'sky_mask.png', 'ground_mask.png']`（ホワイトリスト）＋
  `isImageFile()` ＋ `isValidSize()`（既存の 5MB 上限ヘルパーを流用）。
  `fileName` ホワイトリストにより `output.mp4` の client write は rules 上でも原理的に
  到達不能（Cloud Functions が Admin SDK で rules をバイパスして書く専用パスと一致）

---

## 4. マスク・軌跡の極性（PoC実証済み）

fal.ai Kling の Motion Control API に渡す際の極性は以下の通り（PoC で実証済み・変更禁止）:

- **static_mask_url（固定領域）** = `ground_mask`（白=地上）
- **dynamic_masks[0].mask_url（動かす領域）** = `sky_mask`（白=空） + `trajectories`
  （sky_mask の重心 → 水平方向に +40px の2点・ピクセル座標）
- マスクは **2値化**（フェザーではない。既存 Metal版 Living Sky のフェザーマスクとは別物）
- 出力 mp4 の実寸は **AVAsset から動的取得**すること。`aspectRatio` enum（16:9/9:16/1:1）を
  指定しても API が返す実際の比率とは異なることが実測で確認されている。決め打ち禁止

---

## 5. 回数・コスト方針（2026-08-03 Phase C＝回数パック課金で改定）

- **無料枠: 一般1回/日・β（claim保有者）3回/日**（§2 の `freeUsedToday` 上限）。
  一般公開時は claim の付与をやめるだけで自動的に1回へ揃う
- **購入残高: 5回パック¥1,000（消費型IAP）**。残高からの利用は20回/日が上限
  （乗っ取り・暴走時の被害上限）。詳細は `docs/sky-motion-billing-plan.md`
- **reserve-on-create + refund-on-failure**: 予約は fal.ai 呼び出し前に確定させ、
  失敗時のみ `chargedBucket` の側へ返金する（成功時は消費のまま）
- `quota_exceeded` 時は fal.ai を一切呼び出さない（＝コストゼロ）

---

## 6. 調整可能な数値定数

Cloud Functions 実装担当が **1箇所（`functions/skyMotionCore.js`）にまとめて** 変更できるようにすること:

| 定数 | 既定値 | 説明 |
|---|---|---|
| `FREE_DAILY_LIMIT` | 1 | 一般ユーザーの無料枠/日 |
| `BETA_FREE_DAILY_LIMIT` | 3 | β（skyMotionBeta claim）の無料枠/日 |
| `PAID_DAILY_LIMIT` | 20 | 購入残高からの利用上限/日 |
| `PACK_CREDITS` | pack5→5 | 消費型プロダクトID→付与クレジット数 |
| ドリフト | 幅の10% | trajectory の水平移動量（`SkyMotionPreset.driftWidthRatio`。幅6.5%以下はKlingに無視される実測あり） |
| `LOOP_DURATION_FACTORS` | 1.3/1.5/1.7 | setpts 係数（上限 `LOOP_SLOW_FACTOR_MAX`=1.8。超えると「動いて見えない」） |
| poll のタイムアウト | 20分 | `submittedAt` からの経過時間がこれを超えたらポーリングを打ち切って `status="failed"` / `errorCode="timeout"` にする（`createdAt` は基準にしない） |
| submit のリトライ回数 | 1回 | fal.ai submit 失敗時の再試行回数 |

---

## 7. 本ドキュメントのスコープ外（別担当）

- Cloud Functions 本体（`functions/skyMotion.js` 相当）: トリガー実装・allowlist再検証・fal.ai 連携・
  ポーリング・トランザクション予約/返金ロジック
- Swift クライアント本体: マスク2値化・アップロード・snapshot listener・UI
- 導線ゲート: DEBUG ビルド＋Release/TestFlight の skyMotionBeta claim 保有者
  （`SkyMotionAccess.isEnabled()`）。⚠️「DEBUG限定」ではない——TestFlight の allowlist
  ユーザーにも到達し、IAPが動く（2026-08-03 訂正）

### 既知の制限（公開β送り・今は許容）

- **`submitting` で止まったジョブは自動タイムアウトしない**: `pollSkyMotionJobs` は
  `status == "submitted"` のみをクエリするため、Cloud Functions が
  `reserveAndClaimJob()` のトランザクションをコミットした直後（`status="submitting"`）
  〜 fal.ai への submit 完了前にクラッシュ/再起動すると、そのジョブは `submitted` に
  到達せず poll 対象にも入らず、無期限に `submitting` のまま残る（client の
  snapshot listener も終端状態を待ち続けタイムアウトしない）。低頻度の DEBUG限定機能
  としては許容し、完全な per-job lease／`submitting` の直接タイムアウト監視は
  公開β送り（本ドキュメント冒頭の「修正項目」⚪スコープ外を参照）。
