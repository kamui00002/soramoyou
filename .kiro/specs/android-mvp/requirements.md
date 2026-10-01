# Requirements Document

## Project Description (Input)
Android版MVP — Kotlin + Jetpack Composeで同じリポジトリの`android/`にAndroidクライアントを新規作成する（モノレポ）。

既存のFirebaseバックエンド（Auth / Firestore / Storage / Cloud Functions、プロジェクト`soramoyou-ios`、`asia-northeast1`）をiOS版と共有し、バックエンド側は原則変更しない。

- **MVP範囲**: メール/パスワード＋匿名ログイン、フィード閲覧、投稿（写真選択＋基本フィルター数種）、プロフィール、いいね
- **後回し**: 空カメラ・空優先AE、空を動かすβと回数パック課金（Play Billing）、広角合成（OpenCV）、ウィジェット、ランキング、AI自動編集
- **最初のマイルストーン**:「ログインして本番Firestoreからフィードが読める（読み取り専用）」

### 制約
- `firestore.rules`の`hasOnly`許可リストに合うよう、iOSと同一のドキュメント形で書き込む（契約書は`docs/firestore-schema.md`）
- `Post.editSettings`のレシピ共有はフィルター数値のiOS互換が必要（MVPで外すか要判断）
- プッシュはFCM共通形式で`users/{uid}.fcmToken`（1ユーザー1トークン）
- 分析イベント名はiOSと揃える（PostHog + Firebase Analytics）
- AdMobはAndroid用ユニットIDを新規発行
- `google-services.json`は`.gitignore`に追加
- Google Play新規個人アカウントはクローズドテスト必須（人数・期間は要確認）

### 作業場所
worktree `/Users/yoshidometoru/dev/soramoyou-android`（ブランチ`機能-Android雛形`）

## Introduction
本仕様は、iOS版「そらもよう」と同じFirebaseバックエンドを共有するAndroidクライアントのMVP要件を定めます。最も重い制約は**iOS版とのデータ互換**です。Androidクライアントが書き込んだドキュメントと画像は、既存のiOSアプリ・Cloud Functions・Security Rulesがそのまま扱えなければなりません。

特に投稿ドキュメントの形は、iOS版のホームフィード全体の可用性に直結します。iOS版のフィード取得は、1ページ内の投稿を1件でも読み取れないと、そのページ全体を失敗として扱います。そのため、Androidクライアントが必須項目を欠いた投稿を1件作るだけで、全iOSユーザーのホームフィードが表示できなくなります。

本仕様で使う用語は次のとおりです。
- **Androidクライアント**：本仕様で新規作成するAndroidアプリ（`android/`配下）
- **iOS版**：既存のiOSアプリ（`Soramoyou/`配下）。ドキュメント形の正典はiOS版のモデル（`Soramoyou/Soramoyou/Models/*.swift`）と`docs/firestore-schema.md`
- **本番バックエンド**：Firebaseプロジェクト`soramoyou-ios`（`asia-northeast1`）のAuth・Firestore・Storage・Cloud Functions
- **公開プロフィール**：`publicProfiles/{uid}`。他ユーザーの表示名・アイコンの読み取り元（Firebase Authenticationのプロフィールは同期されていないため使わない）

要件11・12（Google Playポリシー由来）と要件13（`docs/pre-release-checklist.md`§3由来）は、プロジェクト説明のMVP範囲に明記されていなかったスコープ追加です。2026-10-01にユーザーが3つともMVPに含めると決定しました（M5で実装）。

## マイルストーン（優先順位）
| 順 | マイルストーン | 対象要件 | 完了条件 |
|---|---|---|---|
| M1 | ログインして本番フィードが読める（読み取り専用） | 1、2（既存アカウントでのメール/パスワードログイン・セッション維持・ログアウトのみ）、4、5（5.3のプロフィール画面への遷移はM2）、15、16 | 本番のFirestore・Storageへの書き込みが1件も発生しないこと。新規登録と匿名ログインは`users`・`publicProfiles`を作成する（書き込みになる）ためM1に含めない |
| M2 | アカウント作成とプロフィール | 2（新規登録・匿名）、3、10 | 要件17.1・17.2を満たすこと |
| M3 | いいね | 9 | 要件17.6を満たすこと |
| M4 | 写真選択・フィルター・投稿 | 6、7、8 | 要件17.3〜17.5・17.7を満たすこと |
| M5 | ストア公開に必要な機能 | 11、12、13、14 | 各機能を本番データで1回通すこと |
| M6 | クローズドテストと本番公開 | 17、18 | Google Playの審査を通過すること |

要件17（相互運用の検証）は、M2以降の各マイルストーンで該当する項目を実施します。

## Requirements

### Requirement 1: 開発基盤とバックエンド共有の前提
**Objective:** 開発者として、Androidクライアントを既存リポジトリ内に置き、iOS版と同じ本番バックエンドへ接続したい。これにより、両OSが1つのバックエンドで同じデータを扱える。

#### Acceptance Criteria
1. The Androidプロジェクト shall 同一リポジトリの`android/`ディレクトリ配下に置かれ、iOS版のソースとビルド設定（`Soramoyou/`配下）を変更せずにビルドできる
2. The Androidクライアント shall 本番バックエンド（Firebaseプロジェクト`soramoyou-ios`、リージョン`asia-northeast1`）のAuth・Firestore・Storageに接続する
3. The Androidクライアント shall 既存の`firestore.rules`・`storage.rules`・`firestore.indexes.json`・Cloud Functionsを変更しない状態で、本仕様の全機能を動作させる
4. The Androidクライアント shall Firestoreへのクエリを、`firestore.indexes.json`に定義済みのインデックスか単一フィールドの自動インデックスで実行できる形に限定する
5. If 本仕様の実現にバックエンドの変更が不可避と判明した場合, the 開発プロセス shall 実装の着手前に変更内容と理由を明示し、ユーザーの承認を得る
6. The Androidプロジェクト shall `google-services.json`・アプリ署名鍵・その他の秘密情報を`.gitignore`に登録し、Git管理対象から除外する
7. The 開発プロセス shall セキュリティルール以外で必要になる設定作業（FirebaseプロジェクトへのAndroidアプリ登録、AdMobのAndroidアプリと広告ユニットの作成など）を一覧として文書化する

### Requirement 2: 認証（メール/パスワード・匿名）
**Objective:** ユーザーとして、iOS版と同じアカウントでAndroidからもログインしたい。これにより、端末を変えても同じ投稿とプロフィールを使える。

#### Acceptance Criteria
1. When ユーザーがメールアドレスとパスワードを入力してログインしたとき, the Androidクライアント shall Firebase Authenticationで認証し、成功したらフィード画面へ遷移する
2. When ユーザーが既存アカウントでログインしたとき, the Androidクライアント shall ログイン処理の中でFirestore・Storageへ書き込まない
3. When ユーザーが新規登録でメールアドレスとパスワードを送信したとき, the Androidクライアント shall Firebase Authenticationでアカウントを作成し、要件3のアカウント文書を作成する
4. When ユーザーが匿名で始める操作をしたとき, the Androidクライアント shall Firebase Authenticationの匿名認証でアカウントを作成し、要件3のアカウント文書を作成する
5. The Androidクライアント shall 新規登録時に、メールアドレスの形式を`firestore.rules`の`isValidEmail`（文字列全体の一致）と同等以上に厳しい規則で検証し、通らない場合はFirebase Authenticationのアカウントを作成しない
6. If 新規登録のパスワードが6文字未満の場合, the Androidクライアント shall アカウントを作成せず、6文字以上が必要である旨を表示する
7. If 認証に失敗した場合, the Androidクライアント shall 失敗の種類（入力不足・メール形式不正・メールアドレスまたはパスワードの誤り・使用済みのメールアドレス・ネットワークエラー・試行回数超過）に応じて、iOS版と同じ趣旨の日本語メッセージを表示する
8. While 認証済みのセッションが端末に保持されている間, the Androidクライアント shall アプリ再起動時にログイン画面を経ずにフィード画面を表示する
9. When ユーザーがログアウトしたとき, the Androidクライアント shall 認証状態を破棄してログイン前の画面に戻り、そのユーザーの表示用データを端末内に残さない
10. The Androidクライアント shall ログイン・新規登録・ログアウトを含むすべての処理で、`users/{uid}`の`fcmToken`・`fcmTokenUpdatedAt`を読み書き・削除しない（1ユーザー1トークンのため、Androidが書き換えるとiOS端末へのプッシュ通知が届かなくなる）
11. If Firebase Authenticationでのアカウント作成後にアカウント文書の作成に失敗した場合, the Androidクライアント shall エラーを表示して記録し、要件3.7の補完で後から回復できる状態にする

### Requirement 3: アカウント文書の作成（users・publicProfiles）
**Objective:** 開発者として、Androidで作られたアカウントをiOS版で作られたアカウントと同じ形で保存したい。これにより、iOS版・Cloud Functions・Security Rulesが作成元を区別せずに扱える。

#### Acceptance Criteria
1. When 新規登録または匿名認証でアカウントを作成したとき, the Androidクライアント shall `users/{uid}`に、`id`（uidと同値）・`createdAt`（Timestamp型）・`updatedAt`（Timestamp型）・`followersCount`（整数の0）・`followingCount`（整数の0）・`postsCount`（整数の0）を書き込む
2. When 新規登録または匿名認証でアカウントを作成したとき, the Androidクライアント shall `users/{uid}`に通知設定の既定値として`notifyReactions`（true）・`notifyNewPostsFromFollowing`（true）・`notifyNewPostsFromEveryone`（false）を書き込む
3. When アカウントを作成したとき, the Androidクライアント shall メールアドレスがあれば`users/{uid}.email`へ書き込み、匿名アカウントでは`email`キー自体を書き込まない
4. When `users/{uid}`を作成できたとき, the Androidクライアント shall `publicProfiles/{uid}`に、`id`（ドキュメントIDと同値）・`createdAt`（Timestamp型）・`updatedAt`（Timestamp型）・`followersCount`（整数の0）・`followingCount`（整数の0）・`postsCount`（整数の0）を書き込む
5. The Androidクライアント shall アカウント文書の任意項目（`displayName`・`photoURL`・`bio`・`recommendedPostIds`など）に値が無いとき、nullや空文字を書かずにキーごと省略する
6. The Androidクライアント shall `followersCount`・`followingCount`をアカウント作成時以外に書き込まない（正典はCloud Functionsが`follows`を数え直して代入する値のため）
7. If ログイン中のユーザーの`publicProfiles/{uid}`が存在しないことを検出した場合, the Androidクライアント shall 存在しない場合にだけ作成する方法（既存の値を上書きしない方法）で公開プロフィールを作成する

### Requirement 4: フィード閲覧
**Objective:** ログイン済みユーザーとして、みんなが投稿した公開の空を新しい順に眺めたい。これにより、iOS版のユーザーと同じフィードを楽しめる。

#### Acceptance Criteria
1. When ログイン済みユーザーがフィード画面を開いたとき, the Androidクライアント shall `posts`のうち`visibility`が`public`の投稿を`createdAt`の新しい順に1ページ（20件）取得して表示する
2. When ユーザーがフィードの末尾付近までスクロールしたとき, the Androidクライアント shall 直前のページで実際に読み取った最後のドキュメント（表示から除外したものを含む）を起点に次の1ページを取得し、末尾に追加する
3. When ユーザーがフィードを引っ張って更新したとき, the Androidクライアント shall 先頭ページから取得し直して表示を置き換える
4. The Androidクライアント shall 各投稿の投稿者名とアイコンを`publicProfiles/{投稿者uid}`から取得して表示し、Firebase Authenticationのプロフィールを表示に使わない
5. If 投稿者の公開プロフィールが存在しない・取得に失敗した・ドキュメント内の`id`がドキュメントIDと一致しない場合, the Androidクライアント shall 投稿者名に所定の代替表示を出し、uidや内部IDの一部を名前として表示しない
6. When フィードのページを読み込んだとき, the Androidクライアント shall まだ取得していない投稿者の公開プロフィールだけを取得する
7. The Androidクライアント shall フィードの一覧表示にサムネイル画像（`images[].thumbnail`）を優先して使い、サムネイルが無い投稿は本体画像（`images[].url`）で表示する
8. The Androidクライアント shall 複数枚の画像を持つ投稿を先頭の画像（`order`が最小の画像）で表示し、複数枚であることが分かる表示を付ける
9. While ログイン中のユーザーが他ユーザーをブロックしている間, the Androidクライアント shall 自分の`users/{uid}.blockedUserIds`に含まれるユーザーの投稿をフィードに表示しない
10. If 取得した投稿ドキュメントの一部が読み取れる形でない場合（必須項目の欠落・型の不一致など）, the Androidクライアント shall その投稿だけを表示から除外してドキュメントのパスを記録し、同じページの他の投稿は表示する
11. The Androidクライアント shall iOS版の投稿に含まれる、Androidクライアントが解釈しない項目（`mood`・`frameId`・`postKind`・`collageLayout`・`editRecipeV1`・`externalEditInfo`など）や未知の列挙値があっても、投稿の表示を失敗させない
12. If フィードの取得自体に失敗した場合（通信断・権限拒否など）, the Androidクライアント shall 失敗に応じたメッセージと再試行の操作を表示し、失敗を記録する
13. When 表示できる公開投稿が1件も無いとき, the Androidクライアント shall 投稿が無いことを示す表示を出す

### Requirement 5: 投稿詳細表示
**Objective:** ユーザーとして、気になった空を大きく見て、キャプションや投稿者を確かめたい。これにより、投稿をじっくり味わえる。

#### Acceptance Criteria
1. When ユーザーがフィードの投稿をタップしたとき, the Androidクライアント shall 投稿詳細画面を表示する
2. The Androidクライアント shall 投稿詳細画面に、すべての画像を`order`の順で表示し、キャプション・ハッシュタグ・投稿者名とアイコン・投稿日時・いいね数を表示する
3. When ユーザーが投稿詳細画面で投稿者名またはアイコンをタップしたとき, the Androidクライアント shall その投稿者のプロフィール画面（要件10）を表示する
4. When 撮影日時・時間帯・空の種類を含む投稿の詳細を表示したとき, the Androidクライアント shall それらの情報をiOS版と同じ表示名で表示する
5. If 投稿が削除されている、または閲覧権限が無い場合, the Androidクライアント shall 投稿を表示できない旨を表示する

### Requirement 6: 写真選択と基本フィルター
**Objective:** ユーザーとして、端末の写真から空を選び、簡単なフィルターで整えたい。これにより、Androidからも手軽に投稿できる。

#### Acceptance Criteria
1. When ログイン済み（匿名を含む）のユーザーが投稿を始める操作をしたとき, the Androidクライアント shall システムの写真選択画面（フォトピッカー）を表示する
2. The Androidクライアント shall 写真選択のために、端末内の画像全体への広範な読み取り権限（`READ_MEDIA_IMAGES`・`READ_EXTERNAL_STORAGE`など）を要求しない
3. The Androidクライアント shall 1投稿で選択できる画像の枚数を、iOS版のログイン済みユーザー（匿名を含む）と同じ1〜10枚に制限する（決定事項D3。iOS版の4枚モード〔コラージュ〕は対象外）
4. If ユーザーが上限を超える枚数を選ぼうとした場合, the Androidクライアント shall 超過分を受け付けず、上限の枚数を案内する
5. When 写真が選択されたとき, the Androidクライアント shall 選択した写真をプレビュー表示する
6. The Androidクライアント shall iOS版の10種のフィルター（ナチュラル・クリア・ドラマ・ソフト・ウォーム・クール・ビンテージ・モノクロ・パステル・ヴィヴィッド）のうち未決事項Q2で選ぶものを、iOS版と同じ識別子（`natural`など）と同じ表示名で提供する
7. When ユーザーがフィルターを選択したとき, the Androidクライアント shall 選択したフィルターをプレビューに反映し、別のフィルターを選んだときは前のフィルターを置き換える
8. When ユーザーが「フィルターなし」を選択したとき, the Androidクライアント shall 元の写真をプレビューに表示する
9. If 選択した写真を読み込めない場合（破損・未対応形式など）, the Androidクライアント shall その写真を投稿対象にせず、理由を表示する

### Requirement 7: 投稿の作成（画像アップロードと投稿ドキュメント）
**Objective:** ユーザーとして、整えた空を投稿したい。これにより、iOS版のユーザーにも自分の空が届く。

#### Acceptance Criteria
1. When ユーザーが投稿を確定したとき, the Androidクライアント shall 各画像を長辺2048px以下・JPEG形式・5MB未満に変換し、画素の向きを正立に焼き込んでからアップロードする
2. The Androidクライアント shall アップロードする画像ファイルに、撮影位置（GPS）を含むEXIFメタデータを含めない
3. The Androidクライアント shall 本体画像を`posts/{uid}/{公開範囲}/{画像ID}.jpg`に、長辺512px以下のサムネイルを`thumbnails/{uid}/{公開範囲}/{画像ID}_thumb.jpg`に、`contentType`を`image/jpeg`としてアップロードする（`{公開範囲}`は`public`・`followers`・`private`のいずれかで、投稿の`visibility`と一致させる）
4. The Androidクライアント shall JPEGの圧縮品質を本体・サムネイルごとに統一し、その値は未決事項Q5で決める
5. If 変換後の画像が5MB以上になる場合, the Androidクライアント shall その画像をアップロードせず、画像が大きすぎる旨を表示する
6. The Androidクライアント shall 2000文字を超えるキャプションを投稿させない
7. The Androidクライアント shall キャプションからiOS版と同じ規則（`#`に続く単語構成文字の並びで、日本語を含む）でハッシュタグを抽出し、`#`を除いた元の文字列のまま（小文字化などの正規化をせずに）`hashtags`へ保存する
8. If 抽出したハッシュタグが30個を超える場合, the Androidクライアント shall 投稿を確定させず、上限を案内する
9. The Androidクライアント shall 公開範囲として「公開」「フォロワーのみ」「非公開」を選べるようにし、既定値を「公開」とする
10. When すべての画像のアップロードが完了したとき, the Androidクライアント shall `posts/{postId}`に、`postId`（ドキュメントIDと同値の文字列）・`userId`（自分のuid）・`images`（マップ型の配列）・`visibility`・`likesCount`（整数の0）・`commentsCount`（整数の0）・`createdAt`（Timestamp型）・`updatedAt`（Timestamp型）を含むドキュメントを作成する
11. The Androidクライアント shall `images`の各要素に、`url`・`thumbnail`・`width`・`height`・`order`・`storagePath`・`thumbnailStoragePath`を、アップロードした実ファイルと一致する値で書き込み、`width`・`height`・`order`を整数型で書き込む
12. The Androidクライアント shall 任意項目（キャプション・ハッシュタグなど）は値があるときだけ書き込み、値が無い場合やAndroidで取得できないiOS固有の項目（`externalEditInfo`・`originalImages`など）は、null・空文字・仮の値を書かずにキーごと省略する
13. The Androidクライアント shall 列挙値を持つ項目（`visibility`・`timeOfDay`・`skyType`など）に、iOS版と同一の文字列値だけを書き込む
14. When 投稿ドキュメントを作成するとき, the Androidクライアント shall 撮影日時（`capturedAt`、アップロード前に元画像のEXIFから読み取る）と時間帯（`timeOfDay`）を、iOS版と同じ項目名・型・値域で書き込む（決定事項D4）
15. The Androidクライアント shall 時間帯を、撮影日時の端末ローカル時刻の「時」からiOS版の`TimeOfDay.from(date:)`と同じ区切り（5〜11時は`morning`、12〜16時は`afternoon`、17〜19時は`evening`、それ以外は`night`）で決める
16. If 元画像から撮影日時を読み取れない場合, the Androidクライアント shall iOS版で同じ状況のときと同じ扱いをする（`capturedAt`・`timeOfDay`を省略するか、別の時刻で代替するかは、設計時にiOS版の実装で確認する）
17. The Androidクライアント shall 画像解析が必要な項目（`skyType`・`skyColors`・`colorTemperature`）をMVPでは書き込まず、キーごと省略する
18. If 投稿ドキュメントの作成に失敗した場合, the Androidクライアント shall その投稿のためにアップロードした画像をStorageから削除し、失敗を表示して記録する
19. When 投稿ドキュメントの作成に成功したとき, the Androidクライアント shall 自分の投稿数をサーバー側で数え直し、全投稿数を`users/{uid}.postsCount`に、公開投稿数を`publicProfiles/{uid}.postsCount`に保存する
20. If 投稿数の数え直しに失敗した場合, the Androidクライアント shall 投稿自体は成功として扱い、失敗を記録する
21. While 画像のアップロード中または投稿の保存中である間, the Androidクライアント shall 進捗を表示し、同じ投稿の二重送信を受け付けない
22. When 投稿が成功したとき, the Androidクライアント shall 完了を表示し、フィードと自分のプロフィールに新しい投稿が反映された状態にする

### Requirement 8: 編集情報（editSettings）の扱い
**Objective:** 開発者として、Androidの投稿がiOS版のレシピ共有と矛盾しないようにしたい。これにより、MVPでレシピ共有を外してもiOS版の表示を壊さず、将来の追加も妨げない。

レシピ共有はMVPに含めない（決定事項D1）。ただし、ユーザーは今後Androidでも対応したい意向（2026-10-01）のため、将来の追加を妨げない形にする。

#### Acceptance Criteria
1. The Androidクライアント shall 投稿ドキュメントに`editSettings`・`editRecipeV1`を書き込まず、キーごと省略する
2. The Androidクライアント shall iOS版の投稿に含まれる`editSettings`・`editRecipeV1`を書き換えたり削除したりしない
3. The Androidクライアント shall フィルターの内部表現に、iOS版の`editSettings`と対応づけられる識別子（要件6.6の`natural`などと同じもの）を使い、将来`editSettings`を書き込む形へ拡張できるようにする

将来レシピ共有に対応するときの論点（MVPでは決めない）：
- 同じ`editSettings`を同じ写真へ適用したときの、iOS版との見た目の許容差
- 数値の型と精度（iOS版は編集値をFloatとして読むため、Androidが書く値によっては読み取り時に失われるおそれがある）
- iOS版のフィルター係数は`FilterGraphBuilder`と`ImageService`の2か所に重複しており、Androidが3か所目になる
- iOS版の投稿のレシピをAndroidで表示・適用するか

### Requirement 9: いいね
**Objective:** ユーザーとして、好きな空にいいねしたい。これにより、iOS版の投稿者にも反応が届く。

#### Acceptance Criteria
1. The Androidクライアント shall フィードと投稿詳細に、各投稿のいいね数（0未満になる場合は0）と、自分がいいね済みかどうかを表示する
2. When フィードまたは投稿詳細で投稿を読み込んだとき, the Androidクライアント shall 表示中の投稿について`likes/{uid}_{postId}`の有無を確認し、いいね済みの状態を反映する
3. When ユーザーがいいねしていない投稿のいいねボタンを押したとき, the Androidクライアント shall 1つのトランザクションで、`likes/{uid}_{postId}`を`userId`・`postId`・`createdAt`（Timestamp型）の3項目だけで作成し、投稿の`likesCount`を1増やす
4. When ユーザーがいいね済みの投稿のいいねボタンを押したとき, the Androidクライアント shall 1つのトランザクションで、`likes/{uid}_{postId}`を削除し、投稿の`likesCount`を1減らす
5. The Androidクライアント shall いいねの追加・取り消しで、投稿ドキュメントの`likesCount`以外の項目（`updatedAt`を含む）を書き換えない
6. The Androidクライアント shall いいねの書き込みを「押した結果どうなってほしいか」を指定する方式で行い、サーバー上で既にその状態なら何も書き込まずに現在のいいね数を返す
7. When ユーザーがいいねボタンを押したとき, the Androidクライアント shall サーバーの応答を待たずに表示を切り替え、書き込みが成功したらサーバー上のいいね数に表示を揃える
8. If いいねの書き込みに失敗した場合（閲覧権限を失った投稿を含む）, the Androidクライアント shall 表示を押す前の状態に戻し、失敗を記録する
9. While ある投稿へのいいねの書き込みが完了していない間, the Androidクライアント shall 同じ投稿へのいいね操作を受け付けない

### Requirement 10: プロフィール
**Objective:** ユーザーとして、自分の空の一覧と表示名を整え、他の人のプロフィールも見たい。これにより、自分の空を集めて人に見せられる。

#### Acceptance Criteria
1. When ユーザーが自分のプロフィール画面を開いたとき, the Androidクライアント shall 表示名・アイコン・自己紹介・投稿数を、Firestoreの`users/{uid}`または`publicProfiles/{uid}`から取得して表示する
2. When ユーザーが自分のプロフィール画面を開いたとき, the Androidクライアント shall 自分の投稿を公開範囲によらず`createdAt`の新しい順にページ単位で一覧表示する
3. If 表示名が未設定の場合, the Androidクライアント shall 所定の代替表示を出し、uidや内部IDの一部を名前として表示しない
4. When ユーザーが他ユーザーのプロフィールを開いたとき, the Androidクライアント shall `publicProfiles/{uid}`の表示名・アイコン・自己紹介・投稿数と、その人の公開範囲が「公開」の投稿だけを新しい順に表示する
5. The Androidクライアント shall 他ユーザーの投稿一覧を取得するクエリに、必ず`visibility`が`public`である条件を含める（含めないとクエリ全体が権限拒否になるため）
6. When ユーザーがプロフィール編集で表示名・自己紹介・アイコンを保存したとき, the Androidクライアント shall `users/{uid}`と`publicProfiles/{uid}`の両方に、変更した項目と`updatedAt`だけを部分更新で書き込む
7. The Androidクライアント shall プロフィール編集で`id`・`email`・`followersCount`・`followingCount`・`postsCount`・`fcmToken`を書き込まない
8. When ユーザーがアイコン画像を選んで保存したとき, the Androidクライアント shall 長辺1024px以下のJPEG画像を`users/{uid}/profile/`配下に5MB未満でアップロードし、そのダウンロードURLを`photoURL`として保存する
9. If 公開プロフィールの更新に失敗した場合, the Androidクライアント shall エラーの種類から推測せずに公開プロフィールの有無を取得して確かめ、存在しなければ要件3.7の方法で作成してから更新し直し、存在すれば失敗を表示する
10. The Androidクライアント shall 表示名と自己紹介に、iOS版と同じ入力上限を適用する（値は設計時にiOS版の実装から確認する）
11. Where 自分の投稿の削除をMVPに含める場合（未決事項Q8）, the Androidクライアント shall 投稿ドキュメントと、その投稿の`storagePath`・`thumbnailStoragePath`が指す画像を削除し、投稿数を数え直す

### Requirement 11: 通報・ブロック（Google PlayのUGCポリシー対応）
**Objective:** ユーザーとして、不快な投稿を通報し、相手をブロックしたい。これにより、安心して使える（Google Playでは、ユーザー生成コンテンツを公開するアプリに必須）。

#### Acceptance Criteria
1. The Androidクライアント shall 他ユーザーの投稿（フィード・投稿詳細）から、通報とブロックの操作に到達できる導線を提供する
2. When ユーザーが通報理由を選んで通報したとき, the Androidクライアント shall `reports`に`postId`・`reporterId`（自分のuid）・`reportedUserId`・`reason`・`createdAt`（サーバー時刻）を書き込む
3. The Androidクライアント shall 通報理由をiOS版と同じ5種（`inappropriate`・`spam`・`harassment`・`copyright`・`other`）に限定し、iOS版と同じ表示名で表示する
4. When ユーザーが投稿者をブロックしたとき, the Androidクライアント shall 自分の`users/{uid}.blockedUserIds`にその投稿者のuidを配列への追加操作で加え、表示中のフィードからその投稿者の投稿を除く
5. When ユーザーがブロック中のユーザー一覧からブロックを解除したとき, the Androidクライアント shall 配列の削除操作で`blockedUserIds`からそのuidを取り除く
6. If 通報またはブロックの書き込みに失敗した場合, the Androidクライアント shall 失敗を表示して記録する
7. The Androidクライアント shall 自分自身の投稿には通報とブロックの操作を表示しない

### Requirement 12: アカウント削除（Google Playのアカウント削除要件対応）
**Objective:** ユーザーとして、アカウントと関連データを自分で削除したい。これにより、使うのをやめたときに自分のデータを残さずに済む（Google Playでは、アプリ内でアカウントを作成できるアプリに必須）。

#### Acceptance Criteria
1. The Androidクライアント shall 設定画面など見つけやすい場所に、アカウント削除の導線を提供する
2. When ユーザーがアカウント削除を開始したとき, the Androidクライアント shall 削除されるデータと取り消せないことを示して確認を求める
3. Where アプリ内で削除を完結させる方式を採る場合（未決事項Q6）, the Androidクライアント shall iOS版の退会処理と同じ対象・同じ順序（公開プロフィール→フォロー関係→自分のいいねと相手の投稿のカウンタ→自分のコメントと相手の投稿のカウンタ→自分の投稿→下書き→お気に入り→`users`文書→Firebase Authenticationのアカウント）でデータを削除する（正典は設計時にiOS版の`FirestoreService.deleteUserData`と呼び出し元の手順で確認する）
4. Where アプリ内で削除を完結させる方式を採る場合, the Androidクライアント shall 途中の手順で失敗したら以降の手順とFirebase Authenticationのアカウント削除を実行せず、失敗を表示して再試行できる状態にする
5. If アカウント削除時にFirebase Authenticationが再認証を要求した場合, the Androidクライアント shall メールアドレスのアカウントではパスワードの再入力を求め、再認証してから削除を続ける
6. Where Webの削除リクエスト窓口へ案内する方式を採る場合, the Androidクライアント shall アプリ内の導線からその窓口を開く
7. When アカウント削除が完了したとき, the Androidクライアント shall ログイン前の画面に戻り、端末内にそのユーザーのデータを残さない

### Requirement 13: アプリ内フィードバック
**Objective:** ユーザーとして、不具合や要望をアプリから直接送りたい。これにより、ストアのレビュー以外の方法で声を届けられる（`docs/pre-release-checklist.md`§3の後付けできない機能）。

#### Acceptance Criteria
1. The Androidクライアント shall 設定画面などから、フィードバック送信画面に到達できる導線を提供する
2. When ユーザーがフィードバックを送信したとき, the Androidクライアント shall `feedback`に`userId`（自分のuid）・`message`・`createdAt`（サーバー時刻）を書き込み、種別（`bug`・`request`・`other`）・アプリのバージョン・端末情報（OS名とバージョンなど）は値があるときだけ書き込む
3. If 本文が空白だけ、または1000文字を超える場合, the Androidクライアント shall 送信させず、理由を表示する
4. The Androidクライアント shall フィードバックに自動で付加する項目に、メールアドレス・表示名を含めない
5. When 送信に成功したとき, the Androidクライアント shall 送信完了を表示する
6. If 送信に失敗した場合, the Androidクライアント shall 入力した本文を残したまま失敗を表示する

### Requirement 14: 広告（AdMob）
**Objective:** 運営者として、iOS版と同じくバナー広告で収益を得たい。これにより、運営費をまかなえる。

#### Acceptance Criteria
1. Where 広告を表示するビルドである場合（未決事項Q9）, the Androidクライアント shall 画面下部にバナー広告を表示する
2. The Androidクライアント shall iOS版と共用しない、Android用に新規発行した広告ユニットIDを使う
3. While 開発用・テスト用のビルドである間, the Androidクライアント shall 本番の広告ユニットではなくテスト用の広告を表示する
4. If 広告の読み込みに失敗した場合, the Androidクライアント shall 画面のレイアウトを崩さず、他の操作を妨げない
5. The Androidクライアント shall 広告を、投稿の画像や操作ボタンと重ならない位置に表示する

### Requirement 15: 分析・エラー計測
**Objective:** 開発者として、iOS版と同じ物差しでAndroidの利用状況と不具合を把握したい。これにより、両OSを並べて改善の判断ができる。

#### Acceptance Criteria
1. The Androidクライアント shall 行動分析のイベントを、単一の送信窓口からPostHogとFirebase Analyticsの両方へ送る
2. The Androidクライアント shall iOS版に同じ操作があるイベントを、iOS版と同一のイベント名・パラメータキー・値の表記で送る（例：投稿完了の`post_completed`、エラーの`error_occurred`）
3. When 投稿が成功したとき, the Androidクライアント shall `post_completed`をiOS版と同じパラメータキーで送り、Androidに無い機能のパラメータ（`has_mood`・`saved_original_images`など）は、iOS版でその機能を使わなかったときと同じ値で送る
4. When 主要な画面が表示されたとき, the Androidクライアント shall iOS版と同じ画面名で画面表示イベントを送る（画面名の一覧は未決事項Q10で確定する）
5. The Androidクライアント shall 分析上のユーザー識別にuidだけを使い、メールアドレス・表示名・キャプション本文・位置などの個人情報をイベントに含めない
6. The Androidクライアント shall イベント名を変えずに、Androidからのイベントであることを分析ツール上で区別できるようにする
7. When ユーザーがログアウトしたとき, the Androidクライアント shall 分析ツールのユーザー識別を解除する
8. The Androidクライアント shall クラッシュに加えて、クラッシュせずに処理だけが失敗したエラー（取得失敗・権限拒否・デコード失敗など）も、発生箇所を特定できる文脈とともに記録する
9. If 分析イベントや計測の送信に失敗した場合, the Androidクライアント shall ユーザー操作の処理を失敗させない

### Requirement 16: 共通のUI品質
**Objective:** ユーザーとして、iOS版と同じ感覚で迷わずに使いたい。これにより、両OSのユーザーが同じアプリとして認識できる。

#### Acceptance Criteria
1. The Androidクライアント shall 画面の文言を日本語で表示し、公開範囲・フィルター名・通報理由・空の種類などの用語をiOS版の表示名と揃える
2. While 通信や処理の完了を待っている間, the Androidクライアント shall 読み込み中であることを表示する
3. If ネットワークに接続できない場合, the Androidクライアント shall 接続できない旨を表示し、接続が戻ったら再試行できるようにする
4. The Androidクライアント shall 端末のダークテーマ設定に追従して表示する
5. The Androidクライアント shall 画像やアイコンだけの操作ボタンに、TalkBackで読み上げられる説明を付ける
6. The Androidクライアント shall 端末の文字サイズを大きくしても、主要な操作ボタンと文言が画面外へはみ出さずに操作できる

### Requirement 17: iOS版との相互運用の検証
**Objective:** 開発者として、Androidが書いたデータをiOS版が正しく扱えることを実データで確かめたい。これにより、片方のOSだけが壊れる事故を出荷前に防ぐ。

#### Acceptance Criteria
1. When Androidクライアントで作成したアカウントを使ってiOS版にログインしたとき, the 検証手順 shall iOS版でプロフィールを表示・編集できることを確認する
2. When iOS版で作成したアカウントを使ってAndroidクライアントにログインしたとき, the 検証手順 shall Androidクライアントでプロフィールを表示・編集できることを確認する
3. When Androidクライアントで投稿したとき, the 検証手順 shall iOS版のフィード・投稿詳細・投稿者のプロフィールで、その投稿の画像・キャプション・ハッシュタグ・投稿者名とアイコンが正しく表示され、iOS版のフィードが失敗しないことを確認する
4. When iOS版のユーザーがAndroidクライアントの投稿にいいねしたとき, the 検証手順 shall いいねが成功し、投稿の`likesCount`が1増えることを確認する
5. When 日本語のハッシュタグを含む同じキャプションをAndroidクライアントとiOS版でそれぞれ投稿したとき, the 検証手順 shall 両者に同じ`hashtags`配列が保存されることを確認する
6. When Androidクライアントでいいね・取り消しをしたとき, the 検証手順 shall 投稿の`likesCount`以外の項目が変化していないこと、およびiOS版の投稿者にいいねの通知が届くことを確認する
7. The 検証手順 shall Androidクライアントが作成・更新したドキュメントのキーの集合と型を、同じ操作をiOS版で行ったドキュメントと比べ、差分が意図したものだけであることを確認する
8. The 検証手順 shall 各マイルストーンの完了前に、本番データでハッピーパスを1回通す（`docs/pre-release-checklist.md`§0のAndroid版）
9. The 検証手順 shall 公開範囲が「公開」の検証用投稿は、フォロワーと「全員の新着」通知をオンにしたiOSユーザーへの新着通知（`onPostCreated`）を発生させることを踏まえて最小限にし、可能な検証は「非公開」「フォロワーのみ」の投稿で行う
10. The 検証手順 shall 検証用に本番へ作成した投稿・アカウント・いいねを、検証後に削除する

### Requirement 18: Google Play公開とクローズドテスト
**Objective:** 運営者として、Google Playのルールに沿ってAndroid版を公開したい。これにより、審査での差し戻しや公開後の削除を避けられる。

#### Acceptance Criteria
1. The リリース手順 shall 本番公開の前に、新規の個人デベロッパーアカウントに課されるクローズドテストの条件（必要なテスター数・期間は申請時点で要確認）を満たすまでクローズドテストを実施する
2. The リリース手順 shall 申請時点でGoogle Playが求めるターゲットAPIレベル（値は申請時点で要確認）を満たすビルドを提出する
3. The リリース手順 shall Google Play Consoleのデータセーフティ欄に、Androidクライアントが収集・送信するデータ（メールアドレス・写真・分析イベント・広告ID・クラッシュ情報など）を、実装と一致させて申告する
4. The リリース手順 shall プライバシーポリシー（既存の`hosting/privacy/`）が、Androidクライアントの収集データと利用SDKを反映していることを確かめてから、ストア掲載情報にURLを登録する
5. The リリース手順 shall アカウントと関連データの削除をリクエストできるWebページのURLを、Google Play Consoleに登録する
6. The リリース手順 shall コンテンツのレーティングと、ユーザー生成コンテンツを含むアプリであることを申告する
7. The リリース手順 shall 提出するビルドのバージョンコードを過去に提出したものより大きくし、バージョン名とともにリポジトリ上の設定値として管理する
8. The リリース手順 shall アプリの署名鍵をリポジトリに含めず、紛失しない方法で保管する
9. The リリース手順 shall 提出の前に、要件17の検証と`docs/pre-release-checklist.md`のうちAndroidに該当する項目を通す

## 対象外（MVP後に検討）
- 空カメラ・空優先AE
- 空を動かすβと回数パック課金（Play Billing）
- 広角合成（OpenCV）
- ウィジェット
- いいねランキング（週間・月間）
- AI自動編集
- プッシュ通知の受信（FCMトークンの登録）：`users/{uid}.fcmToken`が1ユーザー1トークンのため、Androidが登録するとiOS端末への配信が途切れる（下記「バックエンドへの影響」参照）
- コメント、フォロー（フォロー一覧・タグフォロー・あなた向けフィード）、検索、お気に入り（私のお気に入りの空）、私のおすすめの空
- 下書き、投稿の再編集、オリジナル画像の保存
- 位置情報・ランドマークの付与
- 気分フレーム・配置写真、27種の編集ツールと装備
- What's New・オンボーディングでの機能案内、ゴールデンアワー通知、空カレンダー・空図鑑
- レビュー誘導（アプリ内レビュー）：不具合がある状態で出すと低評価が溜まるため、本番公開後に判断する（`docs/pre-release-checklist.md`§3）
- 匿名アカウントからメールアドレスのアカウントへの引き継ぎ
- レシピ共有（`editSettings`のiOS互換）：**ユーザーは今後Androidでも対応したい意向（2026-10-01）**。MVPでは書き込まず、将来の追加を妨げない形にする（要件8）
- 空の種類・主要色・色温度の自動抽出（画像解析が必要なため。要件7.17）
- iOS版の4枚モード（コラージュ）

対象外の機能に関わる項目（iOS版の投稿の`commentsCount`・`mood`など）も、Androidクライアントは書き換えません。

## 決定事項（2026-10-01・ユーザー決定）
- **D1（旧Q1）**：レシピ共有（`editSettings`のiOS互換）はMVPに含めない。ただし今後Androidでも対応したい意向があるため、将来の追加を妨げない形にする（要件8）
- **D2**：要件11（通報・ブロック）・要件12（アカウント削除）・要件13（アプリ内フィードバック）をMVPに含める（M5）
- **D3（旧Q3）**：1投稿あたりの画像はiOS版と同じ1〜10枚（要件6.3）
- **D4（旧Q4）**：自動抽出メタデータは撮影日時（`capturedAt`）と時間帯（`timeOfDay`）だけを書き込む。空の種類・主要色・色温度は書き込まない（要件7.14〜7.17）

## 未決事項（Open Questions）
番号は追跡のため初稿のまま残している（Q1・Q3・Q4は決定事項へ移動）。
- **Q2**：MVPで提供するフィルターの種類と数（iOS版10種のうちどれか）
- **Q5**：JPEGの圧縮品質。プロジェクト規約（`CLAUDE.md`）は80〜90%で、iOS版の実装（`StorageService`）は本体95%・サムネイル80%と食い違っている。どちらに揃えるか（5MB未満は確定）
- **Q6**：アカウント削除の方式。アプリ内で完結させる（iOS版と同等の手順をAndroidにも実装する）か、Webの削除リクエスト窓口へのリンクにするか。どちらの方式でもGoogle Play ConsoleへのWebのURL登録は必要である。一方、現状の`hosting/`には`/privacy/`しかなく、削除リクエストの窓口は存在しない
- **Q7**：未ログインのゲスト閲覧をMVPに含めるか。rules上は公開投稿を未認証で読めるが、`publicProfiles`と`likes`は認証が必須のため、ゲストには投稿者名といいね状態を表示できない
- **Q8**：自分の投稿の削除をMVPに含めるか。含めない場合、Androidだけを使うユーザーは誤って投稿した空を消せない
- **Q9**：広告をクローズドテスト版から入れるか。同意取得（UMPなど）が必要か
- **Q10**：分析の構成。PostHogのプロジェクトをiOS版と共用するか（共用すれば同じファネルで比較できる）、画面表示イベントの画面名一覧をどう揃えるか
- **Q11**：対応する最小のAndroidバージョン
- **Q12**：Google Playの現行条件（新規個人アカウントのクローズドテストの人数・期間、ターゲットAPIレベルの値）。申請時点で公式情報を確認する

## バックエンドへの影響（調査結果）
- **MVPの範囲では、`firestore.rules`・`storage.rules`・`firestore.indexes.json`・Cloud Functionsの変更は不要の見込み**。フィード（`visibility`＋`createdAt`）・自分の投稿（`userId`＋`createdAt`）・他人の公開投稿（`visibility`＋`userId`＋`createdAt`）の各クエリはインデックス定義済みで、本仕様の書き込みはすべて現行のrulesで許可されている
- **投稿の形を守る仕組みはrulesではなく読み手側にある**。`posts`の作成ルールは`hasAll`（必須キーの存在だけ）で、余分なキーも欠けた任意キーも通る。一方、①iOS版は`postId`・`userId`・`images`が無い投稿を読めず、1件でもあるとそのページのフィード全体が失敗する。②他人のいいね・コメントによるカウンタ更新（`isCountOnlyUpdate`）は`affectedKeys().hasOnly(['likesCount','commentsCount'])`とキー数の一致を要求するため、`likesCount`・`commentsCount`が無い投稿には誰もいいねできず、いいね時に`updatedAt`などを同時に書くと拒否される。要件7.10〜7.13と9.5はこのための要件である
- **ルール以外で必要な設定作業**：FirebaseプロジェクトへのAndroidアプリ登録（`google-services.json`の発行）、AdMobでのAndroidアプリと広告ユニットの作成、Google Play Consoleの設定
- **将来、バックエンドの変更が必要になる見込み**：Androidでプッシュ通知を受けるには、`users/{uid}.fcmToken`（1ユーザー1トークンで、iOS版はログアウト時に削除する）を複数端末に対応する形へ変える必要がある（スキーマとCloud Functionsの変更）。Webの削除リクエスト窓口を設ける場合は、Hostingへのページ追加が必要
- **運用上の注意**：Androidクライアントの公開投稿でもCloud Functionsの`onPostCreated`が動き、フォロワーと「全員の新着」通知をオンにしたiOSユーザーへ新着通知が送られる（バックエンドの変更は不要で、検証時の扱いは要件17.9で定める）
