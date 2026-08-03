# 「空を動かす」課金設計（Phase C・回数パック消費型）⭐️

> ステータス: **C1+C2 実装済み・サンドボックス購入E2E完走**（2026-08-03）。
> /review-full（4レビュアー＋judge）→ Fable 再調査で金銭経路の穴6件を修正済み:
> ①JWS一時失敗をfailedにしない（retryable伝搬・pendingのまま残す）
> ②pending詰まりのリコンサイラ `reconcilePendingSkyMotionPurchases`（5分毎・再試行上限10）
> ③購入とuidの紐付け `appAccountToken`（`users.iapAccountToken`・不一致は真の購入者へ付け替え）
> ④failJobの返金＋failed遷移を1トランザクション化（`isRefundableJob`で二重返金/巻き戻り防止）
> ⑤failJobのbucketは呼び出し元が渡す（再読み取り+"free"フォールバック廃止）
> ⑥`skyMotionPurchases` create に skyMotionBeta claim を要求（rules対称化）
> 原則: **status="failed" はクライアントに finish() を許すシグナル。恒久的に無効と確信できない限り出さない。**

## ✅ 確定した4つの判断（2026-08-03・ユーザー決定）

| # | 項目 | 決定 | 反映先 |
|---|---|---|---|
| 1 | 価格・パック | **5回 ¥1,000 のみ**（20回パックは売れ行きを見てから） | `PACK_CREDITS`（`skyMotionCore.js`）|
| 2 | Small Business Program | **登録する**（手取り30%→15%＝コストの約2倍マージン）| ユーザーのASC作業 |
| 3 | 無料枠 | **1日1回**（試用の入口を残す）| `FREE_DAILY_LIMIT = 1` |
| 4 | 購入残高の日次上限 | **20回/日**（乗っ取り時の被害上限 ¥1,740/日）| `PAID_DAILY_LIMIT = 20` |

**β中の例外**: custom claim `skyMotionBeta` があるユーザーは無料 **3回/日**（`BETA_FREE_DAILY_LIMIT`）。
実機検証を回せるようにするため。一般公開時は **claim の付与をやめるだけ**で自動的に1回へ揃う。

## ✅ C1 実装済み（コミット `c4a7000`・デプロイ済み）

- **カウンタは3本**: `freeUsedToday` / `paidUsedToday`（どちらも日次lazy reset）/ `balance`（日付と無関係）。
  1本にまとめると「無料を使い切ったか」と「今日あと何回買った枠を使えるか」を同時に表現できない。
- `decideReservation` は**どちらから引いたか（`bucket`）を返す**。返金は別プロセス（ポーラーの `failJob`）で
  起きるため、`livingSkyJobs.chargedBucket` に必ず保存する。
- 予約・残高・ジョブclaim は**同一トランザクション**。
- **後方互換**: β時代の `{day, reservedCount}` は `freeUsedToday` として読む（0扱いだと無料枠のタダ乗りになる）。
- **購入検証**: Apple 公式 App Store Server Library で JWS 検証。**Production → Sandbox の順に両方試す**。
  付与数は必ず **JWS 側の productId** から引く。doc ID = transactionId で冪等＋`credited` なら no-op。
  検証部は firebase-admin 非依存の `skyMotionPurchaseVerify.js` に分離（単体テスト可）。
- **rules**: `skyMotionPurchases`（create=pending+JWSのみ）/ `skyMotionBalance`（read=owner・write不可）をデプロイ済み。
- テスト: `npm test` で 64本（金銭喪失の総合ガードを含む）＋ JWS配線 7本。

> ⚠️ **C3 の宿題**: デプロイ済み `onSkyMotionPurchaseCreated` の実弾スモーク（不正JWS→failed・残高不変）は
> ローカルに ADC / gcloud が無く未実施。サンドボックス購入のE2Eで一緒に確認する。

---

> 以下は 2026-07-24 作成時点の計画（§0〜§1 の未決事項は上の表で確定済み）。
> 前提: Phase A（実機E2E）✅ / Phase B（同意ゲート＋ポリシー）✅ = 1.9.5/build78 TestFlight済み。
> 関連: `docs/sky-motion-design.md`（データ契約）/ メモリ [[feature-sky-motion-kling-beta]]。

## 0. 決定事項（ユーザー）と課金モデル

- **課金モデル = 回数パック（消費型 Consumable）**。「N回ぶんのクレジットを買い切り、生成のたびに1消費」。
- fal.ai の生成コストは**変動費**（後述）なので、クレジット＝実コストに直結させ、コスト割れしない価格にするのが最重要。
- 既存 StoreKit 資産（`PaymentService`・StoreKit 2・product-ID非依存）を再利用する。既存 `SkyStitchProduct`（Non-Consumable・広角用・温存）とは別に、消費型プロダクトを新設。

## 1. 💰 単価経済性（ここが設計の土台・要ユーザー判断）

**実測コスト**: fal.ai Kling v1.5-pro = **$0.112/秒フラット**（Deep Research で確定・誤情報 $0.14/秒 は refuted）。1生成 = 5秒素材 = **$0.56 ≒ ¥87/generation**（¥155/$ 概算。サーバー ffmpeg・Storage・Functions 実行は誤差レベルだが上乗せ要因）。

**Apple の取り分**: 既定 **30%** / **App Store Small Business Program**（年商 $1M 未満で申請可・一人開発は該当）に登録すれば **15%**。

**5回パックの採算表**（コスト ¥87/gen に対して）:

| 価格 | 税込/gen | 手取り(30%後) | 手取り(15%後) | 15%時マージン |
|---|---|---|---|---|
| ¥600 | ¥120 | ¥84 ❌割れ | ¥102 | +¥15（薄） |
| ¥800 | ¥160 | ¥112 | ¥136 | +¥49（1.56倍） |
| ¥1,000 | ¥200 | ¥140 | ¥170 | +¥83（≒2倍）|
| ¥1,200 | ¥240 | ¥168 | ¥204 | +¥117（2.34倍）|

**結論**: 当初案「5回¥600」は **30%控除で赤字・15%でも薄利**。健全マージン（≒2倍）なら **5回 ¥1,000 前後 ＋ Small Business Program 登録**が目安。大容量パック（例 20回）は割安感を出せるが、¥100/gen を切ると 15%後でも割れるので下限に注意。

> **要ユーザー判断①**: 価格（5回¥800 / ¥1,000 / ¥1,200 …）とパック構成（5回だけ / 5・20の2種 …）。
> **要ユーザー判断②**: App Store Small Business Program に登録するか（登録=手取り +15pt・純粋な利益改善）。

## 2. データ契約（Firestore・既存流儀に合わせる）

**`skyMotionPurchases/{transactionId}`**（新規・doc ID = StoreKit の transactionId ＝ **冪等化を Firestore 層で無料で得る**）
```
transactionId / userId / productId / jws（署名付きトランザクション）/
status（pending→credited/failed）/ creditedCount / error? / createdAt / updatedAt
```
- client が書けるのは `status=pending` の初期作成のみ（JWS 添付）。検証・加算は Cloud Functions（Admin SDK）専用。
- **同じ transactionId は同じ doc = 再送しても create が衝突 → Function は既 credited なら no-op**（二重加算しない）。

**`skyMotionBalance/{uid}`**（新規・残高の唯一の真実源＝サーバー権威）
```
uid / balance（int・購入で加算/消費で減算）/ updatedAt
```
- read = 所有者のみ / **write = 一律不可**（加算＝購入検証Function、減算＝`reserveAndClaimJob`、返金＝`refundUsage` のみ）。
- 「Restore は消費型を復元しない」が **残高は Firestore にあるので再インストールでも読める**（設計の性質・穴ではない）。

## 3. クライアント（StoreKit 2・`PaymentService` 拡張）

**新プロダクト定義** `Models/SkyMotionProduct.swift`（`SkyStitchProduct` を鏡写し）:
```
com.yoshidometoru.Soramoyou.skymotion.pack5  （消費型 Consumable）
（必要なら .pack20 も）
```

**購入フロー（金銭喪失を防ぐ不変条件・最重要）**:
1. `product.purchase()` → 検証済み `Transaction` を得る
2. `skyMotionPurchases/{transactionId}` を JWS 付きで作成 → **サーバーが検証＋残高加算を durable に完了** → status=credited を観測
3. **その後で初めて `transaction.finish()`**

⚠️ 2 の前に finish するとアプリ落ちで「課金したのに未加算」＝金銭喪失。だから:
- **起動時に `Transaction.updates` / `Transaction.unfinished` を回すループ**を持ち、finish 前に落ちた未完了トランザクションを再送する（冪等な加算が再送を吸収）。「デモでは動くが客の金を落とす」との分かれ目。
- 現 `PaymentService.finishIfVerified`（即 finish）は**消費型では使わない**。消費型専用フロー（加算確認後 finish）を追加する。

## 4. サーバー（`functions/skyMotion.js` に追加・onCall 不使用）

**購入検証 Function** `onSkyMotionPurchaseCreated`（`onDocumentCreated("skyMotionPurchases/{transactionId}")`）:
- **Apple App Store Server Library（Node）**で JWS を Apple ルートCA に対しローカル検証（**非推奨の `/verifyReceipt` は使わない**）。
- **`environment`（Sandbox / Production）を明示的に両対応**。TestFlight・サンドボックス購入は `Sandbox`。Production 決め打ちだと TestFlight 購入が全部検証失敗＝幻のバグを追うことになる。
- 検証 OK かつ productId が既知の消費型 → **`skyMotionBalance/{uid}.balance += packSize`** をトランザクションで加算・status=credited・既 credited なら no-op（冪等）。

**残高消費（既存の急所に噛ませる）** `reserveAndClaimJob()`:
- 現行=無料 `DAILY_LIMIT=3/日` の予約。ここを **同一 Firestore トランザクション内**で「無料枠 or 購入残高」を判定し、使う方を1減らす（別々の read-then-write にすると同時実行2件が balance=1 を両方見て両方通る）。
- 失敗時 `refundUsage()` は使った方を戻す（無料枠 or 残高）。**1トランザクション・2カウンタ**。

## 5. ゲート変更・Security Rules

- 現行ゲート = allowlist claim `skyMotionBeta`（β）。Phase C = **「残高 > 0（購入済み） or βclaim（無料枠）」**でボタン表示。公開時は claim 依存を外す。
- `firestore.rules`: `skyMotionPurchases`（create=`status=pending`＋自分のuid限定・update/delete=false）、`skyMotionBalance`（read=owner・write=false）。
- **クライアント残高は絶対に信用しない**（表示用キャッシュのみ）。生成可否の真実は必ずサーバー（`reserveAndClaimJob`）で判定。

## 6. MVP スコープ外（β では作らない・過剰実装しない）

- **App Store Server Notifications V2 / 返金処理**: 返金された消費型は残高が stale になるが、β では許容。今作らない。
- **サブスク・複数階層**: 今回は消費型パックのみ。
- 「購入の復元」ボタンでの消費型復元（前述のとおり残高は Firestore が真実源なので不要）。

## 7. ユーザーの事前作業（App Store Connect・手作業）

- [ ] **Paid Apps 契約＋銀行・税務情報**をアクティブに（これが無いと IAP は一切動かない）
- [ ] **消費型（Consumable）プロダクトを ASC で作成**（ID = 新 enum と一致）
- [ ] `Soramoyou.storekit` に同 ID を追加（ローカル/サンドボックステスト用）
- [ ] （採算判断次第）**Small Business Program 登録**

## 8. 実装フェーズ（承認後）

- **C0 契約確定**: 価格・パック・rules・Firestore スキーマ・プロダクトID を確定（ユーザー判断①②反映）。
- **C1 サーバー**: App Store Server Library 導入 → JWS検証（Sandbox/Prod）→ `onSkyMotionPurchaseCreated` → `reserveAndClaimJob` に残高消費を統合 → `node:test`。
- **C2 クライアント**: `SkyMotionProduct` → 消費型購入フロー（加算確認後 finish）→ `Transaction.updates` 起動ループ → 残高表示・購入UI（`SkyMotionSheet` に「クレジット購入」導線）。
- **C3 結合**: サンドボックスで購入→加算→生成で1消費→失敗で返金 を実機確認。
- 各段で `/review-full` → keep 対応 → ユーザー実機確認。main 直コミットなし・作業ブランチ。

---

## 要ユーザー判断まとめ（先に決めれば C0 に着手できる）

1. **価格・パック構成**（推奨: 5回 ¥1,000＋Small Business Program で ≒2倍マージン）
2. **Small Business Program 登録の可否**（手取り 30%→15%）
3. **無料枠の扱い**: 現行 3回/日 を「公開後も 1〜2回だけ無料で残す（転換の入口）」か「純粋に有料のみ」か
4. **購入残高は日次上限を超えられるか**: 通常 Yes（買ったぶんは使える）だが、乗っ取り対策に**1日あたりの上限（例 20回/日）**は残す
