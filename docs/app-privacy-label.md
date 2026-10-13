# App Store Connect「App のプライバシー」入力表 ⭐️

> ASC → アプリ → **App のプライバシー** のフォームに入れる内容。
> 出典は `Soramoyou/PrivacyInfo.xcprivacy`（コードを実査して作成）。**こことマニフェストは必ず一致させること。**
> 最終確認: 2026-10-13（そらとも＝友達グループの一般公開を反映。種類は 9 のまま・マニフェストも変更なし）

## 0. 最初の質問

| 質問 | 回答 |
|---|---|
| このAppはデータを収集しますか？ | **はい** |

---

## 1. 収集するデータ（9種類）

各項目は ASC 上で **「App機能」「分析」などの用途** と
**「ユーザーにリンク」「トラッキングに使用」** の2つのフラグを聞かれる。

| # | ASC のカテゴリ | 項目 | 用途 | ユーザーにリンク | トラッキングに使用 |
|---|---|---|---|---|---|
| 1 | 連絡先情報 | **メールアドレス** | App機能 | **はい** | いいえ |
| 2 | 識別子 | **ユーザーID** | App機能, 分析 | **はい** | いいえ |
| 3 | 連絡先情報 | **名前** | App機能 | **はい** | いいえ |
| 4 | ユーザーコンテンツ | **写真またはビデオ** | App機能 | **はい** | いいえ |
| 5 | ユーザーコンテンツ | **その他のユーザーコンテンツ** | App機能 | **はい** | いいえ |
| 6 | 位置情報 | **正確な位置情報** | App機能 | **はい** | いいえ |
| 7 | 購入 | **購入履歴** | App機能 | **はい** | いいえ |
| 8 | 使用状況データ | **製品の操作** | 分析 | **はい** | いいえ |
| 9 | 診断 | **クラッシュデータ** | App機能 | **はい** | いいえ |

### 各項目の根拠（審査で聞かれたら答えられるように）

| # | 何を・どこへ |
|---|---|
| 1 | Firebase Auth のアカウント作成／ログイン |
| 2 | Firestore の `userId`、Analytics/Crashlytics の `setUserID`（**内部UIDのみ**。email や表示名は渡さない）。そらともでは、グループの参加・通報の記録の uid と、ガイドラインに同意した版と日時（`soratomoUsers` の `guidelineVersion`・`guidelineAgreedAt`） |
| 3 | プロフィールの表示名（`users.displayName`）。そらともの投稿者名とメンバー一覧にも出す（そらとも専用の名前は無い） |
| 4 | 投稿画像を Firebase Storage へアップロード。そらともの投稿画像は Storage の `soratomo/` 配下（位置情報などのメタデータは送る前に落とす） |
| 5 | キャプション・ハッシュタグ・コメント・アプリ内フィードバック本文・そらとものグループ名と投稿のキャプション |
| 6 | 投稿に位置情報を付けた場合の緯度・経度（`posts.location`）。**付けるかは投稿ごとに選択制** |
| 7 | 「空を動かす」回数パックの `transactionId` / `productId` / 購入日時。**決済情報は Apple が処理し受け取らない** |
| 8 | `LoggingService` → Firebase Analytics の画面表示・主要操作イベント（PII は sanitize 済み） |
| 9 | Crashlytics。`setUserID` で内部UIDを紐づけているため「リンクあり」 |

> **そらとも（友達グループ・1.15.0 で一般公開）で新しい種類は増えない。**
> 通報の理由は 5 つの固定の選択肢（`functions/soratomoCore.js` の `REPORT_REASONS`）で、自由記述は無い。
> 運営の Discord へ転送するのは内部ID・理由・時刻だけ（`buildReportForwardPayload`）。
> 表と `PrivacyInfo.xcprivacy` は 9 種類のまま（2026-10-12 に開発者が承認・soratomo-public-launch tasks 10.4）。

---

## 2. ⚠️ 広告（AdMob）の扱い

**AdMob 由来の「デバイスID」「広告データ」は、この一覧に含めていない。**

理由: `GoogleMobileAds.framework` が**自前のプライバシーマニフェストで宣言**しており、
Apple 側で SDK 分と合算される。アプリ側で重複宣言しない。

ただし **ASC のフォームは「Appが収集するデータ」＝SDK経由を含む**ため、
ASC 上では以下も申告が必要になる可能性が高い。**入力時に AdMob の項目が求められたら**:

| ASC のカテゴリ | 項目 | 用途 | リンク | トラッキング |
|---|---|---|---|---|
| 識別子 | デバイスID | サードパーティ広告 | はい | **はい** |
| 使用状況データ | 広告データ | サードパーティ広告 | はい | **はい** |

> ⚠️ この2項目を入れると ASC 上で「トラッキング」に該当し、**ATT の実装が必須**になる。
> 本アプリは `AdService.requestTrackingAuthorization()` で ATT を実装済みなので整合する。

---

## 3. プライバシーポリシーURL

```
https://soramoyou-ios.web.app/privacy/
```

- Firebase Hosting で公開（`hosting/privacy/index.html`）
- 本文の原本は `SettingsView.privacyPolicyText`。
  **`scripts/build-privacy-policy-html.py` で生成**するので、アプリ内とホスト版はドリフトしない
- アプリ内の本文を変えたら: 生成スクリプト実行 → `firebase deploy --only hosting --project soramoyou-ios`

> ⚠️ **記録と現物のずれ（2026-10-13）**: 提出時（1.15.0 の審査提出 2026-10-13 20:34）の ASC の実際の指し先は、
> 上の URL ではなく **Google サイトの「利用規約」ページ**だった（`privacyChoicesUrl` も同じ）。
> 同日 21:19 に、審査中の appInfo（1.15.0 と一緒に出る側）の `privacyPolicyUrl` と `privacyChoicesUrl` の両方を上の URL へ直した。
> 公開中の appInfo（1.14.0 側）は `409 INVALID_STATE`（今の状態では変えられない）で直せず、1.15.0 の公開で入れ替わる。公開の後に読み直して確かめる。
> 確かめ方: 文書ではなく現物で。ASC の API の `appInfoLocalizations` の `privacyPolicyUrl`／`privacyChoicesUrl` を読む。

---

## 4. 入力後のチェック

- [ ] 9項目すべてに「用途」「リンク」「トラッキング」を設定した
- [ ] AdMob 由来の2項目を入れた場合、トラッキング＝はい にした
- [ ] プライバシーポリシーURLが 200 で開ける
- [ ] `PrivacyInfo.xcprivacy` の宣言と食い違っていない
      （食い違うと Apple 側で警告・審査で指摘される）
