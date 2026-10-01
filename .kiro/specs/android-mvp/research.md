# 調査と設計判断の記録：android-mvp

## Summary
- **Feature**：`android-mvp`
- **Discovery Scope**：新規プラットフォームと既存バックエンドの複雑な統合（Complex Integration）。full discoveryを実施した。
- **主な発見**：
  - iOSのホームフィードは、1ページ内の投稿を1件でもデコードできないとページ全体が失敗する（`FirestoreService.swift:290-292`）。一方で`posts`の作成ルールは`hasAll`だけである（`firestore.rules:57`）。形を守る責任はクライアント側にあるため、Androidは書き込みの直前に形を機械的に検証する必要がある。
  - iOSの退会処理（`deleteUserData`）はFirestoreのドキュメントだけを消し、Storageの画像は消さない（`FirestoreService.swift:884-945`）。Google Playのアカウント削除ポリシーとの関係で、要件12.3からの逸脱を承認項目（QB）として挙げた。
  - Google Playの現行条件（2026-10-01確認）：新規の個人アカウントは、12人以上・14日以上連続のクローズドテストが必須である。新規アプリは、2026-08-31からAPI 36のターゲットが必須である。

## Research Log

### 外部情報の確認状況（取得日：2026-10-01）

| 項目 | 結果 | 状態 | 出典 |
|---|---|---|---|
| 新規個人アカウントのテスト条件 | 2023-11-13より後に作成した個人アカウントは、12人以上のテスターが14日以上連続でオプトインしたクローズドテストが必須です。内部テストは任意です。条件を満たしたらダッシュボードから本番アクセスを申請し、質問票（クローズドテスト・アプリ・本番の準備状況の3区分）に答えます。審査は通常7日以内です | 確認済み | [App testing requirements for new personal developer accounts](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en) |
| ターゲットAPIレベル | 2026-08-31から、新規アプリとアプリの更新はAndroid 16（API 36）以上が必須です。2026-11-01まで延長を申請できます。既存アプリはAPI 35以上でないと、新しいOSの新規ユーザーに表示されません（ページの更新日は2026-09-16） | 確認済み | [Meet Google Play's target API level requirement](https://developer.android.com/google/play/requirements/target-sdk) |
| アカウント削除の要件 | アプリ内の導線（見つけやすい場所）とWebのリンクの両方が必要です。Webのページは、ストア掲載のアプリ名かデベロッパー名を示し、削除のリクエスト方法を目立たせます。アプリを再インストールせずにリクエストできる必要があります。正当な理由（セキュリティ・不正防止・法令）による保持は認められます。URLはData safetyフォームに記入します | 確認済み | [Understanding Google Play's app account deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en) |
| Firebase Android BoM | 最新は34.19.0（2026-09-09）です。KTXモジュールは2025年7月に新版の提供を終え、BoM 34.0.0で除かれました | 確認済み | [Firebase Android SDK Release Notes](https://firebase.google.com/support/release-notes/android) |
| Firebaseの前提条件 | API 23以上、AGP 7.3.0以上、compileSdk 28以上です。Google Servicesプラグインは4.5.0です。`google-services.json`はアプリモジュールの直下に置きます（ページの更新日は2026-10-01） | 確認済み | [Add Firebase to your Android project](https://firebase.google.com/docs/android/setup) |
| Google Mobile Ads SDK（Legacy） | 最新の25.5.0（2026-09-17）で、最小APIを24に引き上げました。ページの冒頭に「保守モード。GMA Next-Gen SDKへ移行」と表示されています | 確認済み | [Release notes (AdMob Android)](https://developers.google.com/admob/android/rel-notes) |
| GMA Next-Gen SDK | minSdk 24以上、compileSdk 35以上、Kotlin 1.9以上が必要です。依存は`com.google.android.libraries.ads.mobile.sdk:ads-mobile-sdk:1.5.0`です。広告を読み込む前の初期化が必須で、初期化はバックグラウンドのスレッドで行います。EEA・英国・スイスの同意は初期化の前に取得します | 確認済み | [Set up GMA Next-Gen SDK](https://developers.google.com/admob/android/next-gen/quick-start) |
| AdMobのアプリ準備（審査） | 全面的な配信には、アプリの公開・対応ストアへの掲載・AdMobでのリンクが必要です。審査中は配信が制限されることがあります。審査は通常2〜3日です | 確認済み | [AdMob app readiness](https://support.google.com/admob/answer/10564477?hl=en) |
| 同意管理（CMP） | EEA・英国（2024-01-16から）とスイス（2024-07-31から）でパーソナライズ広告を配信するには、Google認定のTCF対応CMPが必要です。UMP SDKはその1つです | 確認済み（検索結果の要約。詳細ページは未読） | [Google consent management requirements](https://support.google.com/admob/answer/13554116?hl=en) |
| フォトピッカー | Android 11（API 30）以上で標準提供されます。API 19〜29はGoogle Play開発者サービス経由のバックポートで、マニフェストへの宣言が必要です。`PickMultipleVisualMedia(maxItems)`の上限は`getPickImagesMaxLimit()`です。**ピッカーが使えず`ACTION_OPEN_DOCUMENT`に代わったときは、最大枚数が無視されます**。権限は不要です | 確認済み | [Photo picker](https://developer.android.com/training/data-storage/shared/photopicker) |
| Compose BOM | 最新は2026.09.00（compose ui 1.12.1、material3 1.4.0）です | 確認済み | [BOM to library version mapping](https://developer.android.com/develop/ui/compose/bom/bom-mapping) |
| Android Gradle Plugin | 最新の安定版は9.4.0（2026年9月）です。Gradle 9.6.0以上、JDK 17、ビルドツール36.0.0が必要で、最大APIは37です | 確認済み | [Android Gradle plugin release notes](https://developer.android.com/build/releases/gradle-plugin) |
| ICUの`\w` | `[\p{Alphabetic}\p{Mark}\p{Decimal_Number}\p{Connector_Punctuation}‌‍]`です | 確認済み | [ICU Regular Expressions](https://unicode-org.github.io/icu/userguide/strings/regexp.html) |
| PostHog Android SDK | `com.posthog:posthog-android:3.+`で、API 23以上に対応します。設定は`PostHogAndroidConfig`です。`captureScreenViews`は既定で有効で、`false`で無効にできます | 確認済み | [PostHog Android docs](https://posthog.com/docs/libraries/android) |
| PostHogの既定のイベント属性 | `$os`・`$lib`が既定の属性として存在します | 確認済み（例はWebの値のみ） | [PostHog Events](https://posthog.com/docs/data/events) |
| Firestore rulesの`string.size()` | 「文字数」を返します（UTF-8のバイト数ではありません） | 確認済み（検索結果の要約） | [rules.String](https://firebase.google.com/docs/reference/rules/rules.String) |

### 未確認の事項

記憶にある数値は書いていません。

| 項目 | 状況 | 確認の方法・時期 |
|---|---|---|
| Androidの`java.util.regex`で、`\w`が既定でUnicodeを対象とするか | 公式リファレンスのページ本文を取得できませんでした | 設計で`\w`を使わず、文字クラスを明示します（影響なし） |
| フォトピッカーのURIから撮影日時の列（`MediaStore.PickerMediaColumns`の`DATE_TAKEN`など）を取得できるAPIレベル | 公式リファレンスのページ本文を取得できませんでした | M4の着手時に実機で確認します。取得できなければ`capturedAt`はEXIFだけで決まり、`captured_at_source`は"exif"か"none"になります |
| フォトピッカー経由の元ファイルで、EXIFの`DateTimeOriginal`が保持されるか | 公式ページに記載がありません | M4で、EXIF付きの既知の写真を選んで`capturedAt`を確かめます（陽性対照） |
| PostHog Android SDKの`$os`の実際の値 | Android向けの例が文書にありません | M1で、PostHogのライブイベントを見て確かめます |
| Android OSのバージョン分布 | 公式の分布はAndroid Studio内でのみ提供されます（第三者の数値は採用しません） | Q11の確定時に、Android Studioの分布表で確認します |
| Navigation Compose・Coil・Kotlin・PostHogの確定版数 | 本調査では確認していません | 着手時に`libs.versions.toml`で固定します |
| 自分のPlay Consoleアカウントの作成日 | アカウントの実物での確認が必要です | M5の前 |
| iOSで使っているAuthプロバイダの有効状態 | コンソールの実物を見ていません | M1の前（外部設定作業の#2） |

### iOS側の事実（コードで確認）

#### 投稿ドキュメントとフィード
- **Context**：要件の「必須項目が欠けた投稿1件で全iOSユーザーのフィードが落ちる」の確認。
- **Sources Consulted**：`Post.swift`、`ImageInfo.swift`、`FirestoreService.swift`、`PaginatedPostsViewModel.swift`、`firestore.rules`。
- **Findings**：
  - ホーム（`PaginatedPostsViewModel.swift:210-213`）は`fetchPostsWithSnapshot`を使う。デコードは`try snapshot.documents.compactMap { try Post(from:) }`で行う（`FirestoreService.swift:290-292`）。クロージャ内の`try`が投げると全体が失敗する。
  - デコードに必須なのは、`postId`・`userId`（文字列）と`images`（`[[String: Any]]`）である（`Post.swift:215-228`）。
  - 各画像は`url`（文字列）と`width`・`height`・`order`（`as? Int`）が必須である。失敗した画像は`compactMap`で**黙って落ちる**（`ImageInfo.swift:80-86`、`Post.swift:225`）。
  - `likesCount`・`commentsCount`は、読み込みでは欠落を0とみなす（`Post.swift:293-294`）。一方でrulesの`isCountOnlyUpdate`は`existing.likesCount`を参照し、キー数の一致も求める（`firestore.rules:85-104`）。そのため、欠けた投稿には他人がいいねできない。
  - ページングのカーソルは`snapshot.documents.last`（生の最後の1件）である（`FirestoreService.swift:295`、自分の投稿一覧の注記：:433-435）。
  - **2026-10-01追記（iOS PR #150・OPEN）**：投稿取得9か所を`PostDocumentDecoder.decodePosts`経由に置き換え、壊れた1件を飛ばして`post_decode_failed`（`source`・`path`・`error`）を送る。Crashlyticsには送らない。既知の制約として、1件飛ばしたページでは`PaginatedPostsViewModel`が「件数が`pageSize`未満なら続きなし」と判断し、無限スクロールが止まる。Androidは終了判定を変換前の件数で行う（design.mdのPostDocumentReader節）。
- **Implications**：書き込みの形の検証（許可リスト・整数型の強制）と、iOSのデコード条件の移植（`IosPostReaderContract`）を設計に入れた。

#### いいね
- `setLike`は「押した結果どうなってほしいか」を指定するトランザクションである。いいね文書と投稿を読み、必要なときだけ書き、`likesCount`だけを`FieldValue.increment`で増減する（`FirestoreService.swift:1536-1582`）。
- 投稿の読み取り権限が必要である（`docs/firestore-schema.md:88`）。
- 楽観的な表示の規則は`LikeManager.swift:29-156`にあり、Androidへそのまま写す。
- いいね文書の`createdAt`は端末の時刻である（`Like.swift:38`）。

#### 投稿の作成と画像
- パスは`posts/{uid}/{visibility}/{UUID}.jpg`と`thumbnails/{uid}/{visibility}/{UUID}_thumb.jpg`である（`PostViewModel.swift:728-737`）。
- 品質は本体0.95・サムネイル0.80で（`StorageService.swift:54, 132`）、5MBの判定（:57-60）と`contentType`の`image/jpeg`（:64-65）がある。
- 撮影日時は、EXIFの`DateTimeOriginal`→`PHAsset.creationDate`→無し、の順で決まる（`ExternalEditInfo.swift:78-86`）。`OffsetTimeOriginal`があれば、そのオフセットで解釈する（`ImageService.swift:1047-1072`）。
- 撮影日時が無ければ、`capturedAt`と`timeOfDay`のキーを書かない（`PostViewModel.swift:293-300`、`Post.swift:179-185`）。これにより、要件7.16の「iOSで同じ状況のときと同じ扱い」は「省略する」と確定した。
- ハッシュタグは`#(\w+)`（ICU）で抽出し、重複を除かずに保存する（`PostViewModel.swift:194-207, 904`）。
- `natural`フィルターは恒等変換である（`FilterGraphBuilder.swift:493-494`）。

#### アカウント
- 新規登録では、`users`を`setData(merge:true)`で、`publicProfiles`を上書きの`setData`で作る（`AuthViewModel.swift:99-105`、`FirestoreService.swift:594-605, 1510-1518`）。
- `users`の形は`User.swift:106-157`、`publicProfiles`の形は`PublicProfile.swift:80-117`にある。
- メール形式の検証は`[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}`である（`AuthService.swift:138`）。rulesは`[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}`と長さ254以下である（`firestore.rules:46-52`）。
- プロフィールの編集では、`users`を`User`全体で`setData(merge:true)`する（`ProfileViewModel.swift:540-542`）。手元の古いカウンタで上書きしうるうえ、nilはmergeで省略されるため表示名を空にできない。

#### 退会
- 順序は`publicProfiles`→`follows`（両方向、50件ずつ）→`likes`（1件ずつ3段階）→`comments`（同）→`posts`→`drafts`→`favorites`→`users`である（`FirestoreService.swift:884-945`）。最後にAuthを削除する（`SettingsViewModel.swift:217, 252`）。
- メールアカウントは、データを消し始める前に必ず再認証する（#142、`SettingsViewModel.swift:197-207`）。
- Storageの画像は削除しない。`reports`・`feedback`はrulesにより削除できない（`firestore.rules:377, 397`）。

#### 分析
- `logEvent`はFirebase AnalyticsとPostHogの両方へ送る（`LoggingService.swift:118-130`）。`logScreen`はPostHogにだけ送る（:47-50）。
- 画面名は、タブ名（「ホーム」「ギャラリー」「投稿」「検索」「プロフィール」：`MainTabView.swift:27-33`）と個別の画面（「編集」：`EditView.swift:347`など）である。
- いいね・ログイン・新規登録・通報・ブロック・フィードバック・退会のイベントは、iOSに無い（`logEvent`の全呼び出しを検索して確認）。

#### その他
- `hosting/`には`privacy/index.html`しか無い。ポリシーは「iOSアプリ」と記載し、IDFAのみを挙げ、PostHogを挙げていない（`hosting/privacy/index.html:7, 66, 87-112`）。
- iOSは、UMPとApp Checkのどちらも使っていない（コード検索で確認）。
- iOSのバンドルIDは`com.yoshidometoru.Soramoyou`である（`project.pbxproj:644`）。

## Architecture Pattern Evaluation

| 選択肢 | 説明 | 強み | リスク・制約 | 判断 |
|---|---|---|---|---|
| 単一モジュールとパッケージ分割 | `:app`だけ | 構成が最小です | 形の契約のテストにAndroidの依存が混ざり、JVMのテストが重くなります | 不採用 |
| `:app`と純Kotlinの`:contract` | 形・規則・列挙値をFirebaseに依存しないモジュールへ | 契約のテストが高速です。Firebaseの型が契約へ漏れません | モジュールが1つ増えます | **採用** |
| 機能ごとのマルチモジュール | `:feature:*`など | 大きなチームでの並行開発に向きます | 個人開発のMVPには過剰です | 不採用 |
| Firestoreへの直接アクセス（各リポジトリが書く） | iOSと同じ形 | 単純です | M1の書き込みゼロや形の検証を、一か所で保証できません | 不採用 |
| 読み取り口と書き込み口の分離 | 書き込みを単一のゲートウェイへ集める | 可否の判定・形の検証・記録を一か所で強制できます | ゲートウェイの設計が必要です | **採用** |

## Design Decisions

### 判断：書き込みを単一のゲートウェイへ集め、許可リスト方式で形を検証する
- **Context**：rulesが形を守らず、iOSの読み手が厳しいため（Research Log参照）。
- **Alternatives Considered**：
  1. データクラスを`set(pojo)`で書く — Firestoreの対応付けはnullのプロパティをnullとして書くため、要件3.5・7.12（キーごと省略）に反する。
  2. マップを各リポジトリで組み立てる — 形の検証を強制できない。
- **Selected Approach**：nullと浮動小数を持たない`FsValue`でドキュメントを組み立てる。ゲートウェイが許可リストの契約で検証してから書く。
- **Rationale**：「書けない」ことを、型と実行時の検証の両方で保証できる。
- **Trade-offs**：契約の保守が必要である。iOSが形を変えたら、契約とフィクスチャも更新する。
- **Follow-up**：要件17.7の本番での比較で、契約と実物の一致を確かめる。

### 判断：M1の書き込みゼロを、ビルド定数・構造・実行時・依存の4層で保証する
- **Context**：M1の完了条件が「本番への書き込みが1件も発生しないこと」である。
- **Selected Approach**：
  - ビルド時：`WriteCapability`を空集合にする。
  - 構造：書き込みAPIの呼び出しを`write`パッケージに限り、アーキテクチャテストで強制する。
  - 実行時：ゲートで拒否する。
  - 依存：`firebase-messaging`を入れない。
  - それぞれに陽性対照を用意する。
- **Trade-offs**：アーキテクチャテストはソースの文字列の走査なので、別名での呼び出しなどは検出できない。importの検査と組み合わせて補う。

### 判断：DIは手動（AppContainer）にする
- **Alternatives Considered**：Hilt（KSPとアノテーション処理）、Koin。
- **Selected Approach**：`AppContainer`とViewModelのファクトリで、手動で組み立てる。
- **Rationale**：依存の数が少なく、AGP 9系での注釈処理の互換性を確かめる手間を省ける。テストでは、コンテナごとフェイクに差し替えられる。
- **Follow-up**：画面が増えて組み立てが煩雑になったら、Hiltへの移行を検討する（可逆）。

### 判断：広告SDKはGMA Next-Gen SDKを使う
- **Context**：Legacy SDKは保守モードと公式に表示されている。
- **Trade-offs**：Next-Genは新しく、公開されている事例や情報はLegacyより少ない。初期化は必須で、バックグラウンドのスレッドで行う点に注意する。

### 判断：Firestoreのローカルキャッシュをメモリだけにする
- **Context**：M1の書き込みゼロの保証と、ログアウト時に端末内のデータを残さないこと（2.9）のため。
- **Trade-offs**：オフラインでは閲覧できない。MVPの要件には無い。

### 判断：フィルターは単一のカラーマトリクスで表せる6種に絞る（Q2）
- **Context**：iOSの10種のうち、`clear`・`drama`・`soft`・`pastel`・`vivid`は`CIColorControls`の1段で、`monochrome`は`CIColorMonochrome`の1段である（`FilterGraphBuilder.swift:496-515, 543-563`）。
- **Trade-offs**：Core Imageは線形の作業色空間で処理するため、AndroidのsRGB上のマトリクスとは見た目が完全には一致しない。D1により、MVPでは一致を求めない。

## Risks & Mitigations
- **iOSのフィード全体の停止**：次の手段で多重に防ぐ。
  - 形の契約と整数型の強制
  - `IosPostReaderContract`のテスト
  - エミュレータでのrulesのテスト
  - 本番でのキー集合の比較（17.7）
- **ハッシュタグの抽出結果の不一致**：ICUの`\w`と同じ文字クラスを明示し、黄金ベクタで単体テストし、17.5で本番を突き合わせる。両OSのICUのUnicodeの版の差による、まれな不一致は残りうる。
- **インデックスの欠落**：エミュレータでは検出できないため、各マイルストーンで本番の読み取りを1回ずつ通す。クエリの形は`QuerySpec`の閉じた集合に限る。
- **退会の途中停止**：段階名を記録する。全ての段階を冪等にし（既に無いものの削除は成功として扱う）、再試行で続きから実行できるようにする。
- **匿名アカウントのAuthの削除失敗**：最近のログインが必要で失敗すると、再認証できないためAuthのレコードが残る（PIIなし）。iOSと共通の残存リスクとして記録する。
- **アプリ内削除とStorageの画像（QB）**：承認されなければ、公開画像がURLで読める状態が残る。Data safetyとポリシーの記載との整合を、承認の判断材料として示した。
  - **2026-10-01追記**：ユーザーの判断でQBは不採用となり、iOSと同じく画像は消さない。Playが認める保持の理由はセキュリティ・不正防止・法令に限られる（上表「アカウント削除の要件」）。そのため、M5で削除受付ページを決めるときに審査上の扱いを再確認する。
- **プライバシーポリシーの記載漏れ（PostHog）**：iOSにも共通する既存の問題である。Hostingの変更として承認を得てから更新する。
- **minSdkの確定の遅れ**：上げる方向は既存ユーザーを切り捨てるため、公開前に確定する。

## References
- [App testing requirements for new personal developer accounts](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en) — クローズドテストの条件（取得日2026-10-01）
- [Meet Google Play's target API level requirement](https://developer.android.com/google/play/requirements/target-sdk) — ターゲットAPI 36（取得日2026-10-01、ページの更新日2026-09-16）
- [Understanding Google Play's app account deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en) — 削除の導線とWebのリンク（取得日2026-10-01）
- [Firebase Android SDK Release Notes](https://firebase.google.com/support/release-notes/android) — BoM 34.19.0、KTXの廃止（取得日2026-10-01）
- [Add Firebase to your Android project](https://firebase.google.com/docs/android/setup) — 前提条件（取得日2026-10-01）
- [Release notes (AdMob Android)](https://developers.google.com/admob/android/rel-notes) — Legacy 25.5.0、最小API 24（取得日2026-10-01）
- [Set up GMA Next-Gen SDK](https://developers.google.com/admob/android/next-gen/quick-start) — Next-Gen 1.5.0の前提条件（取得日2026-10-01）
- [AdMob app readiness](https://support.google.com/admob/answer/10564477?hl=en) — ストア公開前の配信制限（取得日2026-10-01）
- [Google consent management requirements](https://support.google.com/admob/answer/13554116?hl=en) — 認定CMP（取得日2026-10-01）
- [Photo picker](https://developer.android.com/training/data-storage/shared/photopicker) — フォトピッカーの提供範囲と上限（取得日2026-10-01）
- [BOM to library version mapping](https://developer.android.com/develop/ui/compose/bom/bom-mapping) — Compose BOM 2026.09.00（取得日2026-10-01）
- [Android Gradle plugin release notes](https://developer.android.com/build/releases/gradle-plugin) — AGP 9.4.0（取得日2026-10-01）
- [ICU Regular Expressions](https://unicode-org.github.io/icu/userguide/strings/regexp.html) — `\w`の定義（取得日2026-10-01）
- [PostHog Android docs](https://posthog.com/docs/libraries/android) — SDKの設定（取得日2026-10-01）
- [PostHog Events](https://posthog.com/docs/data/events) — 既定の属性（取得日2026-10-01）
- [rules.String](https://firebase.google.com/docs/reference/rules/rules.String) — `size()`の意味（取得日2026-10-01）
