# Research & Design Decisions

## Summary
- **Feature**: `soratomo`
- **Discovery Scope**: Complex Integration（既存の公開SNSの上に、閉じたグループ共有の場を新設する。Firestore・Storage・Cloud Functions・通知・設定・プロフィールの各所に統合点がある）
- **Key Findings**:
  - StorageのルールからFirestoreを`firestore.exists()`で読める（2022年のcross-service rules）。1回の評価で読めるのは2文書までで、既定のデータベースだけが対象である。メンバー判定を「メンバーごとの文書1件の存在」にすれば、画像の読み取りをメンバーだけに絞れる。`storage.rules`の「StorageのルールからFirestoreは読めない」というコメントは古い。
  - Firestoreの通常の書き込み（`setData`・`updateData`・`delete`）はオフラインでも端末内で成功し、再起動をまたいで後から送られる。要件2の6・4の9・8の19・12の2・12の3・18の5は「通信できないときは失敗として見せる」ことを求めるため、失敗を見せるべき書き込みはトランザクション（オフラインでは`unavailable`で失敗し、キューに積まれない）か、Callable関数（HTTPS呼び出しでキューを持たない）に限る。これが作成・参加・再発行をCallableで実装する決め手になった。
  - 通知の間引き（5分）と、トリガーの重複配信（at-least-once）への備えは、受信者ごと・グループごとの状態文書1つ（最後に送った時刻と投稿ID）で両立できる。間引きを守れる順序は「送る前に状態を確保する」だけである。

## Research Log

### StorageのルールからFirestoreを読む
- **Context**: 要件11の1・11の2・8の14。グループの画像をメンバーだけが読める状態にすることは譲らない（決定事項の表の下の一文）。既存の`storage.rules`（15〜19行・57〜63行）には「StorageのルールからFirestoreは読めない」とあり、フォロワー限定画像はログイン済みなら誰でも読める。
- **Sources Consulted**: [Cloud Storage Security Rules conditions](https://firebase.google.com/docs/storage/security/rules-conditions)、[Announcing cross-service Security Rules](https://firebase.blog/posts/2022/09/announcing-cross-service-security-rules/)
- **Findings**:
  - `firestore.get()`と`firestore.exists()`が使える。パスは`/databases/(default)/documents/...`で、変数は`$(var)`で埋め込む（Firestoreのルールの`$(database)`は使えない）。
  - 「1回のルール評価で読めるFirestoreの文書は2件まで」。読み取りはFirestoreの読み取りとして課金される。
  - 複数データベースがあっても、読めるのは既定のデータベースだけ。本プロジェクトは`(default)`（`firebase.json`）。
  - 初めてこの関数を使うルールをデプロイするとき、StorageからFirestoreへの権限付与をCLIかコンソールが求める（IAMの付与）。
- **Implications**: メンバー判定は`soratomoGroups/{groupId}/members/{uid}`の存在1件で行う（2件上限の半分）。Storageのパスにアップロードした人のuidを含めれば、削除は`request.auth.uid == authorId`だけで判定でき、Firestoreを読まずに済む（要件11の7の「アップロード内容を含めない」も満たす）。初回デプロイのIAM付与は運用手順に書く。

### 画像の取得経路とダウンロードトークン
- **Context**: 要件8の14・11の13。既存の画像表示はすべてKingfisher 8.6.2の`KFImage(url)`で、`StorageService`はアップロードのたびに`downloadURL()`を呼ぶ（77行・149行）。
- **Sources Consulted**:
  - Kingfisher 8.6.2 `Sources/General/ImageSource/ImageDataProvider.swift`
  - [A guide to Firebase Storage download URLs and tokens](https://www.sentinelstand.com/article/guide-to-firebase-storage-download-urls-tokens)
  - [firebase-js-sdk #5342](https://github.com/firebase/firebase-js-sdk/issues/5342)
- **Findings**:
  - `ImageDataProvider`は`Sendable`で、要件は`cacheKey: String`・`data(handler: @escaping @Sendable (Result<Data, any Error>) -> Void)`・`contentURL: URL?`（既定nil）。`KFImage(source: .provider(...))`で使える。
  - Storage SDKの`getData(maxSize:)`は要求のたびにStorageのルールを通る。トークン付きURLはルールを通らない。
  - クライアントSDKでアップロードすると、ダウンロードトークンが自動で付くという記述がある（本プロジェクトの現物では未確認）。
- **Implications**: そらともの画像は`getData`だけで取得し、`downloadURL()`を呼ばず、URLを保存しない。キャッシュの鍵はStorageのパスにし、専用の`ImageCache`に分けてサインアウトで消す。トークンが自動で付く場合の扱いは「要確認」の3で述べる。

### 作成・参加・招待コード再発行の実行場所
- **Context**: 要件2・3・4・11の8〜11の10・12の5。FirebaseFunctionsのSPM製品はリンクされていない（`project.pbxproj`の製品依存はFirebaseAI・Analytics・Auth・Crashlytics・Firestore・Storage・Messaging）。Callable関数は1本も無い。
- **Sources Consulted**: [Call functions from your app（2nd gen）](https://firebase.google.com/docs/functions/callable?gen=2nd)、既存の`firestore.rules`473〜485行（livingSkyJobsの要求文書）と`functions/skyMotion.js`の`onSkyMotionJobCreated`
- **Findings**:
  - Callableは`onCall`で`request.auth.uid`と`request.auth.token`（カスタムクレームを含む）を受け取り、`HttpsError(code, message, details)`で理由付きのエラーを返せる。Swiftでは`Functions.functions(region:)`から呼び、エラーの`details`で理由を受け取る。
  - CallableはHTTPS呼び出しで、オフラインの送信キューを持たない（ドキュメントにキューの記述は無い）。
  - 要求文書とトリガーの方式（C）は、要求文書の作成がFirestoreの書き込みなので、オフラインでは端末内で成功し、通信が戻ったときに勝手に実行される。
- **Implications**: Callable（A）を選ぶ。比較は下の表、決定は「Design Decisions」。

### オフライン時の書き込みのキューイング
- **Context**: 要件2の6・4の9・6の9〜6の11・8の19・12の2〜12の4・18の5。
- **Findings**:
  - Firestoreの`setData`・`updateData`・`delete`は端末内のキャッシュへ先に反映され、オフラインでも完了ハンドラーは後から（同期時に）呼ばれる。未送信の書き込みはディスクに残り、次の起動後に送られる。
  - トランザクションはサーバーとの通信が前提で、オフラインでは失敗する。キューには積まれない。書き込みだけのトランザクションも作れる。
  - Storageのアップロードは既定で長い再試行時間を持つ（`maxUploadRetryTime`）。値は`Storage`のインスタンス単位で、変えると既存のアップロードにも効く。
- **Implications**: そらとも投稿の作成と削除、表示名の保存はトランザクションで行う。アップロードはそらとも側でタスクを保持し、独自の制限時間で`cancel()`する（既存の`Storage`の設定は変えない）。どれも、処理の前にネットワーク監視で通信の有無を確かめる（二重の防御）。

### プッシュ通知（送信・間引き・重複配信）
- **Context**: 要件9。既存の`pushHelpers.sendToToken`（44〜65行）は`aps`を`{sound}`で固定し、ヘッダーを渡せず、結果を返さない。無効トークンの判定と削除の規則は`isInvalidTokenError`に1か所でまとまっている。
- **Sources Consulted**: firebase-admin-node `src/messaging/messaging-api.ts`（`ApnsConfig`と`Aps`）
- **Findings**:
  - `ApnsConfig.headers`にAPNsのヘッダー（値は文字列）を、`Aps.threadId`に`thread-id`を指定できる。`badge`を省けばバッジは変わらない。
  - Firestoreのトリガーの配信は少なくとも1回で、同じイベントは2回届きうる。既存の`recommendationNotices`は`create()`の一度きりで重複を防いでいる（`docs/firestore-schema.md`299行）。
- **Implications**: `pushHelpers.js`に、ヘッダーと`threadId`を受け取り結果を返す兄弟の関数を足す。`sendToToken`は変えない。間引きの状態文書に「最後に送った投稿ID」を持たせ、同じ投稿の再配信を「重複」として送らない。

### 機能フラグ（カスタムクレーム）
- **Context**: 要件1・17。先例は`skyMotionBeta`（`SkyMotionAccess.swift`24〜37行・`firestore.rules`474行と530行・`storage.rules`200行・`functions/skyMotion.js`116〜124行）。
- **Sources Consulted**: [Control access with custom claims](https://firebase.google.com/docs/auth/admin/custom-claims)
- **Findings**:
  - `setCustomUserClaims`は「既存のカスタムクレームを常に上書きする」。クレームの合計は1000バイトまで。
  - 新しいクレームは、次に発行されるIDトークンから効く（再ログイン・トークンの期限切れ・`getIDTokenResult(forcingRefresh: true)`）。
  - `SkyMotionAccess`はDEBUGで無条件に`true`を返す（25〜26行）。そらともで同じことをすると、クレームの無い開発者にも入口が出て、書き込みがすべてルールで拒否される。
  - クレームを付与するスクリプトはリポジトリに無い。
- **Implications**: クレーム名は`soratomoBeta`。付与は既存のクレームを読んで合成してから書く（合成しないと、同じテスターの`skyMotionBeta`が消える）。アプリの判定にDEBUGの例外を設けない。

### 既存コードとの統合点
- **Findings**:
  - 通知センターのデリゲートは`GoldenHourNotificationManager.shared`（`SoramoyouApp.swift`43行）。`didReceive`はゴールデンアワーの計測だけ（238〜245行）、`willPresent`は`[.banner, .sound]`（230〜235行）。コールドスタートでは`ContentView`が0.5秒待ってから画面を出す（23〜37行）。
  - `MainTabView`は`switch selectedTab`でタブの画面を作り直し、What's Newの`.fullScreenCover`をすでに持つ（96行）。
  - ホームは`NavigationView`で、ツールバーには中央の`AppTitleView`だけがある（`HomeView.swift`104〜108行）。`GuestTabView`も`HomeView`を使う（32行）。
  - 設定のプッシュ通知の3つのトグルは`SettingsView.swift`308〜332行、保存は`SettingsViewModel`の直列化された`updateNotificationPreferences`（3引数固定）。`User.toFirestoreData`は3つのプレフを常に書き、`followedTags`は書かない（読み取り専用の先例）。
  - 表示名とアイコンは画面ごとに`publicProfiles`から取り、代替表示は「ユーザー」とプレースホルダー（`RankingDisplayText.authorName`）。Functionsの代替は「だれか」（`index.js`67〜70行）。既存のプロフィール編集は表示名を50文字まで受け付ける（`ProfileViewModel.swift`743行）。
  - 退会処理（`FirestoreService.deleteUserData`）はルートの`posts`・`drafts`・`favorites`・`users`などを消し、collectionGroupのクエリを使わない。Functionsが`users`へ`get`→`set(merge)`すると`users`が復活しうる既知のリスクがある（898〜901行）。
  - `firestore.indexes.json`の複合インデックスはコレクションID`posts`などを対象にし、collectionGroupの範囲指定は無い。
- **Implications**: 通知のタップは`didReceive`に1行足して専用のルーターへ渡す（既存の分岐と計測は変えない）。そらともの画面は`MainTabView`のタブの中身の側から全画面で出し、What's Newの表示中は待つ。そらとものFunctionsは`users`へ書かない（無効トークンの削除は既存と同じ`update`で、文書が無ければ失敗するだけ）。サブコレクションの名前に`posts`を使わない。

### セキュリティルールのテスト手段
- **Context**: 要件11の14。エミュレーターの設定（`firebase.json`の`emulators`）は無い。先例`scripts/rules_test_post_update.py`はRules test API（`firebaserules.googleapis.com/v1/projects/{id}:test`）で評価だけを行う。
- **Sources Consulted**: firebaserules v1 discovery document（`TestCase`・`FunctionMock`）、[firebase-tools #5251](https://github.com/firebase/firebase-tools/issues/5251)、[firebase-js-sdk #6803](https://github.com/firebase/firebase-js-sdk/issues/6803)
- **Findings**:
  - `TestCase.functionMocks`は「サービスが宣言した関数」のモックで、宣言に無い関数は指定できない。Storageのサービスが`firestore.exists`を宣言しているかは文書から読み取れなかった。
  - Storageエミュレーターはcross-service rulesに対応した（firebase-tools 11.10.0で追加、評価の不具合は#5342で修正）。
  - `@firebase/rules-unit-testing`で書いたFirestoreの文書が、Storageのルールの`firestore.get()`から見えない事例がある（#6803）。
- **Implications**: Firestoreのルールは先例どおりRules test APIで、`exists`をモックして許可と拒否の両方を評価する。Storageのルールは、まずRules test APIの`firestore.exists`のモックを試し、使えなければエミュレーター（Firestore・Storage・Auth）でAdmin SDKから同じプロジェクトIDで種データを入れて評価する。どちらでも「許可」と「拒否」の両方を観測できるまで、Storageの項目を検証済みとしない。

### 文字数の数え方
- **Context**: 要件2の2・6の3・11の11・18の2。数え方がアプリ・Functions・ルールで違うと、アプリが通した入力をサーバーが拒否する。
- **Sources Consulted**: [Security Rules language](https://firebase.google.com/docs/rules/rules-language)
- **Findings**: ルールの`string.size()`は「文字数」と説明されるだけで、単位（Unicodeのコードポイントか、UTF-16の単位か）は文書から確定できなかった。
- **Implications**: アプリとFunctionsの文字数はUnicodeのコードポイント数に揃える（Swiftの`unicodeScalars.count`、JavaScriptの`Array.from(s).length`）。ルールの単位は「要確認」の1で確かめる。

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| A: Callable関数 | 作成・参加・再発行を`onCall`で受け、Admin SDKのトランザクションで上限と一意性を守る | 理由ごとのエラーを同期で返せる。非メンバーにグループを読ませずに参加の可否を判定できる。オフラインで積まれない。クライアントの状態が単純 | FirebaseFunctionsのSPM製品の追加と`project.pbxproj`の編集が要る。プロジェクトで初めてのCallable。コールドスタートで数秒かかりうる | 採用 |
| B: クライアントのトランザクション＋ルール | クライアントがグループ・メンバー・コードをトランザクションで書き、ルールで守る | SDKの追加が不要 | 参加前の非メンバーはグループを読めないため、「満員」「見つからない」を区別して返せない（要件4の5〜4の7・12の5）。コードの一意性（要件3の2）と同時参加の上限（要件11の10）をルールだけで守るのが難しい。コードを推測で総当たりされやすい | 不採用 |
| C: 要求文書＋Firestoreトリガー＋結果の監視 | クライアントが要求文書を作り、トリガーが処理して結果を書き、クライアントが監視する（livingSkyJobsの先例） | SDKの追加が不要。先例がある | 要求文書の作成はオフラインでも端末内で成功し、通信が戻ったときに利用者の知らないうちに作成・参加が実行される（要件2の6・4の9・12の2に反する）。トリガー配信とコールドスタートの遅れに加え、監視・タイムアウト・要求文書の掃除（招待コードを含む）が要る | 不採用 |

## Design Decisions

### Decision: 作成・参加・再発行はCallable関数で行う
- **Context**: 要件2・3・4・11の8〜11の10・12の2・12の5。
- **Alternatives Considered**:
  1. B — クライアントのトランザクションとルール
  2. C — 要求文書とトリガー
- **Selected Approach**: `soratomoCreateGroup`・`soratomoJoinGroup`・`soratomoRegenerateInviteCode`の3本の`onCall`（`asia-northeast1`）。Admin SDKのトランザクションで、メンバー数20人・所属10個・コードの一意性を守る。エラーは`HttpsError`の`details.reason`で理由を返す。
- **Rationale**: オフラインで積まれず、失敗を即時に見せられる。グループの中身を非メンバーから隠したまま、理由ごとのエラーを返せる。
- **Trade-offs**: FirebaseFunctionsのSPM製品を足す（依存のFirebaseAuthInterop・AppCheckInterop・SharedSwift・GTMSessionFetcherは既存の製品がすでに引いている）。初回の呼び出しはコールドスタートで遅くなりうる。
- **Follow-up**: `project.pbxproj`の3か所（`XCSwiftPackageProductDependency`・`PBXBuildFile`・Frameworksのビルドフェーズ）を編集する。デプロイ後に未ログインの呼び出しが`unauthenticated`になることを確かめる。

### Decision: 投稿の作成と削除、表示名の保存はトランザクションで書く
- **Context**: 要件6の9〜6の11・8の19・12の3・12の4・18の5。
- **Selected Approach**: 通信の事前確認のうえ、書き込みだけのトランザクションで`setData`・`deleteDocument`・`updateData`を行う。
- **Rationale**: 通常の書き込みは、オフラインでも端末内で成功して後から送られる。投稿が利用者の知らないうちに後から現れたり、削除が後から効いたりする。
- **Trade-offs**: 書き込みの遅延補償（送信前に画面へ出す）が無くなる。投稿は完了後にタイムラインの先頭へ明示的に加える。

### Decision: 投稿は画像のパスを持たず、IDから導く
- **Context**: 要件11の4。
- **Alternatives Considered**:
  1. `livingSkyJobs.sourcePath`のように、パスの文字列を持ち、ルールで完全一致を強制する
  2. パスを持たず、`groupId`・`authorId`・投稿IDから導く。ルールの`keys().hasOnly(...)`でパスの項目を持てなくする
- **Selected Approach**: 2。パスは`soratomo/{groupId}/{authorId}/{skyId}/display.jpg`と`thumb.jpg`で、アプリでは1か所の関数だけが作る。
- **Rationale**: 参照先を構造で固定でき、別の投稿や別の利用者の画像を指す項目がそもそも存在しない。投稿データにはURLとパスのどちらも残らない（要件11の13）。
- **Trade-offs**: 画像の置き場を変えるときはデータの移行が要る。

### Decision: タイムラインは、上限を伸ばす1本のリスナーで表示する
- **Context**: 要件8の2・8の3・8の10・8の18・16の3。
- **Alternatives Considered**:
  1. 先頭20件だけを監視し、続きは1回ずつ取得する — 2ページ目以降の削除が反映されない
  2. ページごとにリスナーを張る — 新しい投稿でページの境界がずれ、重複と抜けの調整が要る
  3. 1本のリスナーの`limit`を20、40、60…と伸ばして張り直す
- **Selected Approach**: 3。
- **Rationale**: 読み込んだ範囲の追加と削除が、すべてリスナーで届く。境界の調整が要らない。
- **Trade-offs**: 続きを読むたびに、張り直したクエリの件数分の読み取りが発生する。メンバーは最大20人、1人1グループ1日20件までのため、v1の規模では許容する。

### Decision: 間引きと重複配信への備えを、受信者ごとの状態文書1つで行う
- **Context**: 要件9の4・9の9・9の11。
- **Selected Approach**: `soratomoGroups/{groupId}/notifyState/{uid}`に`lastSentAt`と`lastSkyId`を持つ。受信者ごとのトランザクションで、`lastSkyId`が同じなら「重複」、5分以内なら「間引き」、それ以外なら状態を書いてから送る。
- **Rationale**: ほぼ同時の2件の投稿でも、送る前に状態を確保すれば片方だけが送られる。送った後に書く順序では、両方が送られる。
- **Trade-offs**: 送信が一時的な失敗で終わっても、状態は「送った」のまま残る。その後5分以内の次の投稿は間引かれ、その受信者は最大5分間の通知を1回取りこぼしうる。失敗は件数としてログに残す。

### Decision: 所属一覧と所属数は`users`の外に持つ
- **Context**: 要件5の1・11の10。退会処理の既知のリスク（Functionsの`users`への書き込みによる復活）。
- **Alternatives Considered**:
  1. collectionGroupのクエリ（`members`をuidで検索）— `{path=**}`のルールと単一項目のインデックスの範囲設定が要り、プロジェクトで初めての形になる
  2. 利用者ごとの写し（`soratomoUsers/{uid}/groups/{groupId}`）と所属数の文書（`soratomoUsers/{uid}`）をFunctionsが書く
- **Selected Approach**: 2。所属数はグループのメンバー数と同じトランザクションで増やし、上限の判定に使う。
- **Rationale**: collectionGroupを使わないため、既存のインデックスとルールに干渉しない（要件13の1）。Functionsは`users`へ書かない。
- **Trade-offs**: 写しと本体の二重持ちになる。v1は退出が無いので、増えるだけで減らない。公開前ゲートG1（退会時の削除）では、写し・所属数・メンバー数を同じトランザクションで減らす必要がある。

### Decision: そらとも通知の既定値は新しいモジュールの側で定義する
- **Context**: 要件9の13・9の14・10の14〜10の16・13の7。
- **Selected Approach**: `users.notifySoratomo`（真偽値・無ければON）。Functionsは`soratomoCore.js`に既定値を置き、`index.js`の`PREF_DEFAULTS`は変えない。iOSは`User`に読み取り専用の`notifySoratomo: Bool?`を足し、`toFirestoreData()`では書かない。保存は専用の`updateData`。
- **Rationale**: 既存の3つの設定と既定値に触れない（要件13の7）。`User`全体を書く`updateUser`が古い値で巻き戻すのを防ぐ（`followedTags`と同じ理由）。
- **Trade-offs**: 既定値の定義がiOSとFunctionsの2か所になる。両方にコメントと単体テストを置き、`docs/firestore-schema.md`に一致の規則を書く。

## 要確認（検証済みと書かない事項）

1. **ルールの`string.size()`の単位**: コードポイントか、UTF-16の単位か。絵文字（サロゲートペア）と結合文字を含む100文字のキャプションで、Rules test APIの許可を確かめる。拒否された場合は、ルールの上限は100のままにし、アプリのキャプションの数え方を`utf16.count`に変えて上限をそろえる。当初の案（ルールの上限を200にし、アプリとFunctionsで長さを保つ）は、2026-10-01のvalidate-designで取り下げた。`skies`を書くのはアプリで、Functionsはキャプションを見ない。そのため、当初の案ではサーバー側の検証で11.11を満たせない。グループ名はFunctionsだけが検証するので影響しない。
   - **結果（2026-10-01・検証済み）**: `size()`は**UTF-16の単位**で数える。正規表現の回数指定（`{1,100}`）は**コードポイント**で数える。どちらもRules test APIで評価した（本番のルールとデータには触れていない）。
   - 評価の入力と結果（`size() <= 100`のとき）: 許可されたのはASCII 100・絵文字50（UTF-16 100）・かな100（UTF-8 300バイト）。拒否されたのはASCII 101・絵文字20＋結合文字（e＋U+0301）20＋かな40（コードポイント100・UTF-16 120）・絵文字50＋a（UTF-16 101・コードポイント51）・e＋U+0301×60（書記素60・コードポイント120）。単位の候補4つ（コードポイント・UTF-16・書記素・UTF-8のバイト）のうち、8件すべてと合ったのはUTF-16だけ。
   - 採用（ユーザーの判断）: キャプションのルールは`size()`を使わず、`matches('[^\\r\\n\\x{85}\\x{2028}\\x{2029}]{1,100}')`で長さと改行類を一度に見る。アプリは`unicodeScalars.count`のまま、Functionsと同じコードポイントにそろう。上の「`utf16.count`に変える」代替案は採らない。
   - 最終版のルールでの結果: コードポイント100（絵文字・結合文字入り）・絵文字50＋aは許可。コードポイント101・e＋U+0301×60・空文字・数値・改行類8種（LF・LFが2つ・CR・CRLF・U+0085・U+2028・U+2029・末尾のLF）は拒否。キャプション無しとタブは許可。
   - 陽性対照: 条件を外したルールでは、101文字・空文字・改行類8種の計9件が許可に変わった。
2. **Storageのルールの`firestore.exists`をテストで評価できるか**: Rules test APIの`functionMocks`で指定できるか。できなければ、エミュレーターでAdmin SDKから種データを入れる方式に切り替える（#6803の回避）。各項目で許可と拒否の両方を観測するまで「検証済み」としない。
3. **アップロード時のダウンロードトークンの自動付与**: クライアントSDKでアップロードした`soratomo/`のオブジェクトのメタデータに`firebaseStorageDownloadTokens`が付くかを、Admin SDKで読んで確かめる。
   - 付く場合: メンバーは読み取りの権限で`downloadURL()`を呼べるため、改造したアプリからトークン付きURLを作って外へ渡せる。これは、メンバーが画像を保存して渡すのと同じ程度の残余リスクで、v1では受け入れる。アプリは`downloadURL()`を呼ばず、URLを保存しない。投稿を削除すればURLも無効になる。公開前ゲートG2の検討時に、アップロード完了のトリガーでトークンを消す案を見直す。
   - 付かない場合: 追加の対応は要らない。
4. **Callableの公開呼び出しの許可**: 2nd genの`onCall`は、デプロイ時にCloud Runの呼び出し元を全員に許可する。組織のポリシー（ドメイン制限）があると失敗する。初回デプロイで確かめる。
5. **日次件数の数え方に使う複合インデックス**: `skies`の`authorId`（昇順）と`createdAt`（昇順）で`count()`が通るか。通らない場合はエラーに含まれる作成リンクで向きを合わせる。数え方が失敗しても投稿は止めない（判定はv1ではアプリ側の目安のため）。

## 範囲外の発見（本specでは直さない）

- `storage.rules`199〜203行の`livingSky`は`allow write`に`isImageFile()`と`isValidSize()`を含むため、削除の要求（`request.resource`が無い）が必ず拒否される。PR #141と同じ型の不具合。別のissueで扱う。
- `storage.rules`15〜19行・57〜63行の「StorageのルールからFirestoreは読めない」というコメントは古い。フォロワー限定画像の読み取りを絞る改修と合わせて直す（別のissue）。

## Risks & Mitigations
- Callableのコールドスタートで作成・参加が数秒待たされる — 処理中の表示と二重送信の防止（要件2の7・4の10）。必要になれば最小インスタンス数を検討する（費用が増えるためv1では0）。
- 招待コードの総当たり — 32文字種の8桁（約1.1兆通り）と機能フラグの両方で守る。`not_found`の件数をログで見て、増えたら利用者ごとの試行回数の上限を加える。
- 投稿に失敗したときの画像の取り残し — 失敗時に削除を試み、失敗は非致命エラーとして記録する。取り残しの掃除はv1.1（180日の自動削除と合わせる）。
- 通知タップで別のモーダルが表示中だと、そらともの画面を出せない — 保留の行き先を、表示が確認できるまで保持する。What's Newの表示中は閉じるまで待つ。タブの中の別のモーダルは実機で確かめる。
- 写し・所属数・メンバー数のずれ — すべて同じトランザクションで更新する。G1の削除も同じトランザクションの形にする。
- 送信の一時的な失敗による取りこぼし — 上記の「間引き」の決定のとおり。件数をログで見る。

## References
- [Cloud Storage Security Rules: conditions（Firestoreの参照）](https://firebase.google.com/docs/storage/security/rules-conditions) — `firestore.get()`・`firestore.exists()`、2文書の上限、既定のデータベース、IAMの付与
- [Announcing cross-service Security Rules](https://firebase.blog/posts/2022/09/announcing-cross-service-security-rules/) — 機能の告知とエミュレーターの対応版
- [firebase-tools #5251](https://github.com/firebase/firebase-tools/issues/5251) — エミュレーターでのcross-service rulesの評価の不具合と修正
- [firebase-js-sdk #6803](https://github.com/firebase/firebase-js-sdk/issues/6803) — rules-unit-testingの種データがStorageのルールから見えない事例
- [Call functions from your app（2nd gen）](https://firebase.google.com/docs/functions/callable?gen=2nd) — `onCall`・`HttpsError`・Swiftからの呼び出し
- [Control access with custom claims](https://firebase.google.com/docs/auth/admin/custom-claims) — `setCustomUserClaims`は上書き、1000バイト、反映の時機
- firebase-admin-node `src/messaging/messaging-api.ts` — `ApnsConfig.headers`・`Aps.threadId`
- Kingfisher 8.6.2 `ImageDataProvider.swift` — `cacheKey`・`data(handler:)`・`Sendable`
- [A guide to Firebase Storage download URLs and tokens](https://www.sentinelstand.com/article/guide-to-firebase-storage-download-urls-tokens) — アップロード時のトークンの自動付与
- [Security Rules language](https://firebase.google.com/docs/rules/rules-language) — `string.size()`
