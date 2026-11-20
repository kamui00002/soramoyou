# Google Play「データ セーフティ」入力表（Android 版） ⭐️

> Play Console → アプリのコンテンツ → **データ セーフティ** に入れる内容。iOS 版の `docs/app-privacy-label.md` の Android 版。
> 出典は Kiro android-mvp のタスク 34.2 の棚卸し（R8 をかけたリリースビルド prodRelease の統合マニフェストと依存の一覧・アプリのコード・各 SDK の一次資料）。
> 最終確認: 2026-10-16（この日の時点のコード）
> **プライバシーポリシー（`hosting/privacy/`・タスク 26.2）と、design.md の 18.3（Data safety）の節と必ず一致させること。**
> SDK の版を上げたら §4 の一次資料を読み直す（SDK は集めるものを黙って変えることがある）。

---

## 0. 最初の質問

| 質問 | 回答 | 根拠 |
|---|---|---|
| 必須のユーザーデータを収集または共有しますか？ | **はい** | §1 |
| 収集したユーザーデータは、すべて転送時に暗号化されていますか？ | **はい** | Firebase・AdMob・GA for Firebase は TLS（各一次資料）。PostHog は `https://us.i.posthog.com`（`PostHogSetup.kt:26`）。アプリは https 以外の画像の URL を読まない（`RemoteImageUrl.kt`）。平文の通信を許す設定（`networkSecurityConfig`）は検証用の変種（emulator）にだけあり、本番の prod には無い |
| ユーザーがデータの削除をリクエストする方法を用意していますか？ | **はい** | アプリ内の「アカウントを削除」（タスク 31）と、受付ページ `https://soramoyou-ios.web.app/delete-account/`（タスク 26.1）。退会しても通報は不正利用の防止のため残す（Play の FAQ は「法令の遵守・不正利用の防止などの正当な理由で一部を残す場合も、削除の手段があると選んでよい」） |
| アカウント削除の URL（アカウントを作れるアプリ） | `https://soramoyou-ios.web.app/delete-account/` | アカウントはメールアドレスとパスワードで作る（匿名では作らない。タスク 12 の決定） |

---

## 1. 収集・共有するデータ

- 「共有」は第三者へ渡すこと。**開発者の代わりに処理するサービス提供者（Firebase・PostHog）へ送るのは共有に当たらない**（Play の定義。PostHog はユーザー判断で提供者として扱う）
- 「必須／任意」は、ユーザーが集めるかどうかを選べるか。アプリ内に止める設定が無いものは必須にする
- 一時的な処理（ephemeral）として申告するものは無い
- 「共有」が「はい」の行で第三者に当たるのは広告の SDK（AdMob）だけ。共有の目的は、AdMob の開示どおり広告・分析・不正防止

| # | Play のカテゴリ | データの種類 | 収集 | 共有 | 必須／任意 | 目的 | 何を・どこへ（根拠） |
|---|---|---|---|---|---|---|---|
| 1 | 個人情報 | **メールアドレス** | はい | いいえ | 必須 | アプリの機能・アカウント管理 | Firebase Auth の新規登録とログイン。Firestore の `users/{uid}.email`（`AccountBootstrapper.kt:69`・`AccountDocumentRepairer.kt:93`）。`publicProfiles` には書かない |
| 2 | 個人情報 | **ユーザー ID** | はい | いいえ | 必須 | アプリの機能・分析・アカウント管理 | Firebase の uid。各文書の `userId`、Firebase Analytics と Crashlytics の `setUserId`、PostHog の `identify`（**uid だけ**。メールや表示名は渡さない。イベントの値は `AnalyticsSanitizer` がメールなどを伏せる） |
| 3 | 個人情報 | **名前** | はい | いいえ | 任意 | アプリの機能・アカウント管理 | `publicProfiles.displayName`（空なら書かない）。Play の定義は「自分を呼ぶ名前。ニックネームを含む」。iOS 版も「名前」で申告している |
| 4 | 写真と動画 | **写真** | はい | いいえ | 任意 | アプリの機能 | 投稿の画像（Firebase Storage）とアイコン（`photoURL`）。EXIF は送る前に消える（`AndroidImageCodec.kt:143-146` で Bitmap から JPEG を作り直す）。撮影日時 `capturedAt` は写真に付く情報としてここに含め、別の項目にしない（位置は含まない） |
| 5 | アプリのアクティビティ | **その他のユーザー生成コンテンツ** | はい | いいえ | 任意 | アプリの機能 | キャプション・ハッシュタグ・自己紹介（`bio`。Play の定義の例に「user bios」がある）・フィードバックの本文（`message`。iOS 版も「その他のユーザーコンテンツ」に入れている） |
| 6 | アプリのアクティビティ | **その他の操作** | はい | いいえ | 任意 | アプリの機能 | いいね（`likes`）・ブロック（`blockedUserIds`）・通報（`reports`。理由は選択式で、対象の投稿とユーザー）。Play の定義の例に「likes」がある |
| 7 | アプリのアクティビティ | **アプリの操作** | はい | **はい** | 必須 | 分析・広告・不正防止 | Firebase Analytics の 4 イベント（`post_completed`・`error_occurred`・`retry_operation`・`post_decode_failed`。`AnalyticsFacade.kt:18-27`）。PostHog の 4 画面（手動で送る）と、SDK 既定のアプリのライフサイクルのイベント。AdMob の起動・タップなど（一次資料） |
| 8 | アプリの情報とパフォーマンス | **クラッシュログ** | はい | いいえ | 必須 | アプリの機能・分析 | Firebase Crashlytics（スタックトレース・状態・端末の情報・uid） |
| 9 | アプリの情報とパフォーマンス | **診断** | はい | **はい** | 必須 | 分析・広告・不正防止 | Firebase sessions（端末とアプリの情報）。AdMob の起動時間・ハング率・電池の使用量など（一次資料） |
| 10 | 位置情報 | **おおよその位置** | はい | **はい** | 必須 | 広告・分析・不正防止 | **アプリ自身は集めない**（位置の権限も位置のフィールドも無い）。AdMob が IP アドレスから推定し、GA for Firebase がマスクした IP から導出する。PostHog も IP から GeoIP を付ける（プロジェクト 430627 は `anonymize_ips: false`）。Play の定義は「IP アドレスなどから推定したおおよその位置もここに申告する」 |
| 11 | デバイスまたはその他の ID | **デバイスまたはその他の ID** | はい | **はい** | 必須 | 広告・分析・不正防止 | 広告 ID と App set ID（AdMob）・app-instance ID（GA for Firebase）・FID（Firebase Installations）・installation UUID（Crashlytics）。広告 ID は端末の設定でリセット・削除できる |

---

## 2. 収集しないもの（確かめた方法つき）

- **正確な位置・位置の権限**：位置の権限が無い（§3 の 11 個）。投稿の文書に位置のフィールドが無い（`ShapeContracts.kt` の投稿の形）。EXIF は送る前に消える（§1 の 4）。位置の機能は MVP の対象外
- **端末の写真全体への読み取り**：`READ_MEDIA_*`・`READ/WRITE_EXTERNAL_STORAGE` が無い。写真はシステムの写真選択画面で選んだものだけを読む
- **プッシュ通知**：`firebase-messaging` が入っていない（ビルド時の検査 `verifyNoFirebaseMessaging`）。`POST_NOTIFICATIONS` も無い。`users.fcmToken` を書かない（要件 2.10）。PostHog への通知トークンの送信も明示で切っている（`PostHogSetup.kt:35`）
- **購入履歴**：Android 版に課金は無い（iOS 版の「空を動かす」回数パックは Android 版の対象外）
- **メッセージ**：アプリ内で人どうしがやりとりする機能（DM・コメント）は無い（コメントは MVP の対象外）
- **広告の失敗**：Logcat の警告（`Log.w`）に出すだけで、`error_occurred` にも Crashlytics にも送らない（`BannerAdSlot.kt:74`・`AppContainer.kt:472`。iOS 版も同じ）
- **PostHog の画面の録画**：プロジェクト側は `session_recording_opt_in: true` だが、posthog-android 3.71.4 は `sessionReplay` の既定が false で、アプリも触らない＝Android 版は録画しない
- **PostHog の画面の自動計測**：切っている（`PostHogSetup.kt:32`。画面名は 4 つだけ手動で送る）

---

## 3. 権限（11 個）と持ち込み元

prodRelease の APK（aapt2）と AAB 用のマニフェストで同じ 11 個（2026-10-15 確認）。検証用の emulatorRelease も同じ 11 個で、違うのはパッケージ名の付いた `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` だけ。

| 権限 | 持ち込み元 |
|---|---|
| `android.permission.INTERNET` | ads-mobile-sdk 1.5.0（アプリも使う） |
| `android.permission.ACCESS_NETWORK_STATE` | アプリ自身（接続状態の監視・タスク 4.3） |
| `android.permission.READ_BASIC_PHONE_STATE` | ads-mobile-sdk 1.5.0 |
| `com.google.android.gms.permission.AD_ID` | ads-mobile-sdk 1.5.0 |
| `android.permission.ACCESS_ADSERVICES_AD_ID` | play-services-measurement-api 23.2.0 |
| `android.permission.ACCESS_ADSERVICES_ATTRIBUTION` | play-services-measurement-api 23.2.0 |
| `android.permission.WAKE_LOCK` | play-services-measurement 23.2.0 |
| `com.google.android.finsky.permission.BIND_GET_INSTALL_REFERRER_SERVICE` | play-services-measurement 23.2.0 |
| `android.permission.FOREGROUND_SERVICE` | work-runtime 2.7.0（ads-mobile-sdk 1.5.0 が持ち込む） |
| `com.google.android.providers.gsf.permission.READ_GSERVICES` | recaptcha 18.6.1（firebase-auth が持ち込む） |
| `com.yoshidometoru.soramoyou.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | androidx.core 1.18.0 |

- 無いもの：位置（`ACCESS_FINE/COARSE_LOCATION`）・`READ_MEDIA_*`・`READ/WRITE_EXTERNAL_STORAGE`・`POST_NOTIFICATIONS`・`c2dm`
- `RECEIVE_BOOT_COMPLETED` はマニフェストの合体の報告書には出るが、最終の APK には無い

---

## 4. 組み込まれた SDK（データに関わるもの）

`prodReleaseRuntimeClasspath` の解決結果（2026-10-15）から、データの送受信に関わるものだけを抜き出した。版は解決後のもの。

| SDK | 版 | 役割 | 一次資料（データの開示） |
|---|---|---|---|
| Firebase BoM | 34.19.0 | 下の Firebase の版を揃える | — |
| firebase-auth | 24.2.0 | ログイン・新規登録（IP を不正防止に使う） | firebase.google.com/docs/android/play-data-disclosure |
| firebase-firestore | 26.6.0 | 文書の読み書き（リクエストに uid） | 同上 |
| firebase-storage | 22.0.2 | 画像の保存（リクエストに uid） | 同上 |
| firebase-analytics（play-services-measurement） | 23.2.0 | 分析（app-instance ID・広告 ID・おおよその位置） | support.google.com/analytics/answer/11582702 |
| firebase-crashlytics | 20.1.1 | クラッシュの報告 | firebase.google.com/docs/android/play-data-disclosure |
| firebase-installations / firebase-sessions | 19.1.2 / 3.0.8 | FID・セッションの情報（Firebase の各 SDK が使う） | 同上 |
| ads-mobile-sdk（GMA Next-Gen） | 1.5.0 | バナー広告 | developers.google.com/admob/android/next-gen/privacy/play-data-disclosure |
| user-messaging-platform（UMP） | 4.0.0 | 広告の同意 | — |
| posthog-android | 3.71.4 | 分析（4 画面・ライフサイクル・uid） | プロジェクト 430627 の設定と SDK の既定値を確かめた（§1 の 7・10、§2） |
| recaptcha | 18.6.1 | firebase-auth が使う不正防止 | — |
| work-runtime / room-runtime | 2.7.0 / 2.2.5 | ads-mobile-sdk が持ち込む（端末の中だけ） | — |
| coil3（okhttp 4.12.0） | 3.6.3 | 画像の読み込み（端末の中のキャッシュ） | — |

- firebase-appcheck 19.4.1 は Firebase の他の SDK が持ち込むだけで、アプリは App Check を使っていない

---

## 5. 判断の記録

### 決まったこと（ユーザー判断 2026-10-15）

- **おおよその位置**：収集すると申告する。アプリ自身は集めないが、SDK が IP から推定・導出するため。design.md の 18.3 の節の「位置情報は収集しない」を、同じ意味に直した（目的と共有は 10/16 の E で広げた）
- **デバイスなどの ID**：収集・共有すると申告する（広告・分析・不正防止）
- **PostHog**：開発者の代わりに処理するサービス提供者として扱い、共有に当たらない（収集〔分析〕にだけ入れる）

### 決まったこと（ユーザー判断 2026-10-16・5 つとも推奨どおり）

| 記号 | 何を | 案 | 決めたことと理由 |
|---|---|---|---|
| A | 表示名（`displayName`） | ①「名前」として申告する ②申告しない | **①**。Play の定義に「ニックネーム」が入り、iOS 版も「名前」で申告している |
| B | フィードバックの本文（`message`） | ①「その他のユーザー生成コンテンツ」に入れる ②「その他のメッセージ」にする | **①**。Play の定義でメッセージは「チャットなど」、ユーザー生成コンテンツは「自由記述の回答」を例に挙げる。iOS 版も「その他のユーザーコンテンツ」に入れている |
| C | 撮影日時（`capturedAt`） | ①「写真」に付随する情報として扱い、別の項目にしない ②別の項目で申告する | **①**。Play に写真の付随情報の項目は無い。位置は含まない（EXIF は消える）。プライバシーポリシー（26.2）には「写真の撮影日時」を集めると書いてある |
| D | いいね・ブロック・通報 | ①「その他の操作」として申告する ②申告しない | **①**。Play の定義の例に「likes」があり、いいねは Firestore に保存する |
| E | 位置・アプリの操作・診断の「共有」 | ①AdMob の開示どおり「共有」も付ける（広告・分析・不正防止） ②収集だけにする | **①**。おおよその位置の目的にも不正防止を足した。AdMob（GMA Next-Gen）の開示は、IP・操作・診断・ID の 4 つを**すべて「収集かつ共有」**と書く。ID だけ共有にすると食い違う |

### 決まったこと（ユーザー判断 2026-11-10・Play Console へ入れるときに）

| 何を | 決めたことと理由 |
|---|---|
| ご意見（本文・アプリの版・端末の情報・内部 ID）と通報（理由と投稿の内部 ID）を開発者用の Discord へ送る処理（ご意見は `functions/index.js` の `notifyFeedbackToDiscord`。公開中のポリシーの「Discord」の節に記載） | **共有に数えない**。開発者が確かめるための通知で、PostHog と同じく開発者の代わりに処理する先として扱う。§1 の 2・5・6 行は「共有 いいえ」のまま |
| アカウントを消さずに一部のデータの削除を依頼できるか（任意の設問） | **はい**。URL はアカウント削除と同じ。受付ページに、一部のデータだけでも同じ方法で申し込めると書いてある |

- ご意見の文書には本文のほかにアプリの版と端末の情報（OS の版と機種名）が入る。§1 の 9 行（診断）で収集すると申告しているので、データの種類は増えない

---

## 6. 入力後のチェック

- [x] §1 の 11 行すべてに「収集／共有」「必須／任意」「目的」を入れた（2026-11-10。書き出した CSV と差 0）
- [x] §5 の判断（10/15・10/16・11/10）どおりに入れた
- [x] プライバシーポリシー（`hosting/privacy/`・タスク 26.2）と食い違っていない。特に「おおよその位置（SDK が IP から推定）」と PostHog（2026-11-10 に公開中の版・最終更新 11/08 を読んだ。「アプリは端末の位置を取得しない。広告と分析のサービスが IP からおおよその地域を推定する」で申告と一致。この枝の `hosting/` は main より古いので使わない。端末の ID はポリシーでは「デバイス情報」と広告 ID の表現で、矛盾はしない）
- [x] design.md の 18.3 の節と食い違っていない（2026-11-10 に読み比べた）
- [x] アカウント削除の URL が 200 で開ける（2026-11-09 に Chrome で開いた）
