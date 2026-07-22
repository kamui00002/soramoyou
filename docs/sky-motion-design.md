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
  5. livingSkyUsage/{uid} をトランザクションで reserve（予約）
  6. fal.ai Kling API へ submit → falRequestId を保存 → status="submitted"
  7. ポーリングで完了を待つ → mp4 を Storage の
     livingSky/{uid}/{jobId}/output.mp4 に書き込み
  8. status="completed"（videoURL設定）または status="failed"（error設定・reservedCountをrefund）
```

- クライアントが書けるのは **画像3枚のアップロード** と **status="pending" の初期ドキュメント作成のみ**。
  以降の状態遷移（submitted/completed/failed・falRequestId・videoURL 等）は **Cloud Functions（Admin SDK）専用**。
  Admin SDK は Firestore/Storage セキュリティルールをバイパスするため、client からの
  `update`/`write` を一律 `false` にしても実装上の障害にはならない（`firestore.rules` / `storage.rules` 参照）。

---

## 1. `livingSkyJobs/{jobId}` スキーマ

| フィールド | 型 | 設定者 | 説明 |
|---|---|---|---|
| `id` | string | client | doc ID と一致 |
| `userId` | string | client | 所有者（`request.auth.uid`） |
| `status` | string | 両方 | `pending` → `submitted` → `completed` / `failed`（client が書けるのは初期 `pending` のみ） |
| `sourcePath` | string | client | Storage パス（`livingSky/{uid}/{jobId}/source.jpg`） |
| `skyMaskPath` | string | client | Storage パス（`livingSky/{uid}/{jobId}/sky_mask.png`） |
| `groundMaskPath` | string | client | Storage パス（`livingSky/{uid}/{jobId}/ground_mask.png`） |
| `aspectRatio` | string | client | `"16:9"` \| `"9:16"` \| `"1:1"`（近似選択済み。実寸は §4 参照） |
| `trajectory` | array&lt;{x:int, y:int}&gt; | client | sky_mask 重心 → +40px 水平の2点（ピクセル座標） |
| `falRequestId` | string? | function | submit 成功後に設定 |
| `videoURL` | string? | function | 完成後の Storage ダウンロードURL |
| `retryCount` | int | function | submit 段階のリトライ回数 |
| `pollAttempts` | int | function | ポーラーの試行回数 |
| `errorCode` | string? | function | `quota_exceeded` \| `submit_failed` \| `downstream_unavailable` \| `timeout` 等 |
| `error` | string? | function | エラーの人間可読メッセージ |
| `createdAt` | Timestamp | 両方 | client が作成時に設定（`serverTimestamp()`） |
| `updatedAt` | Timestamp | 両方 | function が状態遷移のたびに更新 |

**セキュリティルール（`firestore.rules` に実装済み）**:
- `create`: 認証済み・`userId == request.auth.uid`・`status == 'pending'`・`falRequestId`/`videoURL` を含まない
- `read`: `resource.data.userId == request.auth.uid`（owner のみ）
- `update`, `delete`: 一律 `false`

---

## 2. `livingSkyUsage/{uid}` スキーマ

| フィールド | 型 | 設定者 | 説明 |
|---|---|---|---|
| `day` | string | function | JST `"YYYY-MM-DD"` |
| `reservedCount` | int | function | 当日の予約済み回数 |
| `updatedAt` | Timestamp | function | |

**lazy reset方式**: 日次cronは使わない。Cloud Functions がトランザクション内で
`day` を読み、当日と異なれば `reservedCount = 0` として扱ってから予約処理を行う
（ドキュメントが存在しない・`day` が古い、いずれも「未予約」として扱う）。

**reserve-on-create + refund-on-failure**:
1. ジョブ作成トリガー受信時、トランザクションで `reservedCount` を読み、
   `reservedCount >= 上限(3)` なら `status="failed"` / `errorCode="quota_exceeded"` にして **fal.ai を呼び出さない**（非課金）
   予約可能なら `reservedCount += 1` を書き込んでから fal.ai を呼ぶ
2. fal.ai 呼び出しが失敗（submit失敗・downstream不可・timeout）した場合、
   同トランザクション方式で `reservedCount -= 1` して返金する（成功時は返金しない）

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
- `write`: owner ＋ `isImageFile()` ＋ `isValidSize()`（既存の 5MB 上限ヘルパーを流用。mp4 は
  `isImageFile()` を満たさないため client 経由では原理的に書けない＝Functions 専用パスと一致）

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

## 5. 回数・コスト方針

- **3回/日/ユーザー**（無料枠。§2 の `reservedCount` 上限）
- **reserve-on-create + refund-on-failure**: 予約は fal.ai 呼び出し前に確定させ、
  失敗時のみ返金する（成功時は消費のまま）
- `quota_exceeded` 時は fal.ai を一切呼び出さない（＝コストゼロ）

---

## 6. 調整可能な数値定数

Cloud Functions 実装担当が **1箇所（設定ファイル or 定数モジュール）にまとめて** 変更できるようにすること:

| 定数 | 既定値 | 説明 |
|---|---|---|
| 1日の上限 | 3 | `livingSkyUsage.reservedCount` の上限 |
| ドリフト | +40px | trajectory の水平移動量 |
| poll のタイムアウト | 20分 | ポーリングを打ち切って `status="failed"` / `errorCode="timeout"` にするまでの時間 |
| submit のリトライ回数 | 1回 | fal.ai submit 失敗時の再試行回数 |

---

## 7. 本ドキュメントのスコープ外（別担当）

- Cloud Functions 本体（`functions/skyMotion.js` 相当）: トリガー実装・fal.ai 連携・ポーリング・
  トランザクション予約/返金ロジック
- Swift クライアント本体: マスク2値化・アップロード・snapshot listener・UI
- DEBUG限定導線（本番導線化はしない。既存 Metal版 Living Sky が本番導線→撤収した経緯があるため、
  本機能も検証が済むまで DEBUG ゲート必須）
