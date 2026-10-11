# Research & Design Decisions — soratomo-leave-group（そらとも：グループだけ抜ける）⭐️

## Summary
- **Feature**: `soratomo-leave-group`
- **Discovery Scope**: Extension（既存のそらとも・公開前ゲートの「共通の削除」を1グループ版で使う。light discovery）
- **Key Findings**:
  - 既存の手順1（`leaveOrDeleteGroupTx`）は、呼び手がメンバーでなくても人数とオーナーを書き直す。素の`deleteUserDataInGroup`をCallableから呼ぶと、他人のグループを書き換えられる（3.13・3.14の違反）。
  - 入り直しの競合は、1回の実行の中では起きない。順序の不変条件（メンバーの文書が無い間は投稿と画像を作れない・写しは最後に消す）があるため。起きるのは、2つの実行が重なった場合だけ。区切りごとに「同じ回の印が残り、メンバーの文書が無い」ことを照合すれば閉じられる。画像の時刻（`timeCreated`）は要らない。
  - 定期実行で途中の片づけを見つけるには、ルートの「片づけ中の印」のコレクションが最も安い。単一項目の範囲のクエリで引け、インデックスの追加が要らない。collectionGroupは、soratomo specの約束（使わない）にも反する。
  - Kingfisher 8.6.2のディスクのファイル名は、鍵のSHA-256。接頭辞で消せないので、グループ単位で消すにはキャッシュをグループごとに分ける。

## Research Log

### 1. 抜ける処理の土台（`functions/soratomoDeletion.js`）
- **Context**: 要件は`deleteUserDataInGroup`（`:301`）を土台と書く。そのまま使えるかを確かめた。
- **Sources Consulted**: `functions/soratomoDeletion.js:106-173`（手順1）・`:175-243`（手順2・3）・`:245-278`（手順4）・`:301-354`（1グループ分）・`:417-450`（利用者単位）。`functions/soratomoDeletion.test.js:219`・`:263`（既存のテストが「メンバーでない再実行でも人数とオーナーを整える」ことを正としている）・`:921`（遅れた削除が入り直したメンバーを外し直すことを正としている）。
- **Findings**:
  - 手順1は`plan.removed`が偽でも`tx.update(groupRef, { memberCount, ownerId })`と役割の更新をする（`:166-170`）。メンバーの文書が0件なら、グループの文書と招待コードを消す（`:152-162`）。
  - 手順2・3は、`authorId == uid`・`soratomo/{groupId}/{uid}/`だけを見る。入り直したかを見ない（`:331`・`:337`）。
  - 手順4は、メンバーの文書があれば写しを消さない（`:269`）。ただし手順2・3はその前に走る。
  - 退会では「遅れた削除が入り直したメンバーを外し直す」のが正しい（アカウントを消すので）。抜けるでは正しくない（8.6）。
- **Implications**: 抜けるは`deleteUserDataInGroup`を直接呼ばず、同じ部品を使う新しい関数`leaveSoratomoGroup`にする。部品の変更は「手順1の読み書きを分ける」「手順2・3に消す前の照合の口を足す（省略時は今と同じ）」だけにし、退会の結果を変えない（10.2）。

### 2. 途中で止まった片づけを、24時間以内にサーバーが終える仕組み（4.6）
- **Context**: 今の定期実行（`functions/soratomo.js:496-534`）は、Authのアカウントが無い人だけを扱う。アカウントのある人の途中の片づけを見つける手段が無い。
- **Sources Consulted**:
  - `functions/soratomo.js:474-583`・`firestore.rules:564`（collectionGroupを使わない）。
  - soratomo specのdesign.md 995行（同じ約束・13.1）・Firestoreの公式文書（下のReferences）。
- **Findings**:
  - 自動の単一項目インデックスは、コレクション単位で作られる。コレクショングループ単位の自動インデックスは、既定では維持されない。コレクショングループのクエリで絞り込みや並べ替えをするには、コレクショングループ単位のインデックスを手で作る必要がある。
  - 範囲の条件は、その項目での並べ替えを含意する。範囲の条件があるとき、最初の並べ替えは同じ項目でなければならない。
  - 既存の仕事B（`functions/soratomo.js:544`）の単一項目のクエリは、`firestore.indexes.json`に書かれていない。
  - 印に時刻が無いと、アプリの繰り返し（最大8回×75秒）と重ならないように待つ判断ができない。所属の写しの`joinedAt`は参加の時刻で、抜けた時刻ではない。
- **Implications**: ルートのコレクション`soratomoPendingLeaves/{uid}_{groupId}`に`leftAt`と`episodeId`を持つ印を置く。仕事Cを`soratomoHousekeeping`に足し、`leftAt`の範囲で引く。比べた案は「Architecture Pattern Evaluation」の表A。

### 3. 入り直しの競合（8.4・8.6・8.7）と、画像の新旧の見分け
- **Context**: Storageの画像のパス`soratomo/{groupId}/{uid}/`は、入り直しの前後で同じ。遅れた片づけが、入り直した後の画像を消さない方法を決める必要がある。
- **Sources Consulted**:
  - `functions/soratomoStorage.js:85-99`（`listFiles`は名前だけを返す）。
  - `Models/SoratomoModels.swift:96-111`（パスは`soratomo/{groupId}/{authorId}/{skyId}/display.jpg`と`thumb.jpg`。`skyId`はアプリが作る自動ID）。
  - `functions/soratomoStore.js:314-346`（投稿の作成はメンバーの文書を確かめる・`createdAt`はサーバーの時刻）。
  - `storage.rules:241-246`（画像の作成はメンバーの文書を確かめる）・`functions/soratomoStore.js:256-294`（参加）。
- **Findings**:
  - 画像の名前には時刻が無い。`skyId`は自動IDなので順序を持たない。投稿の文書と画像の対応はパスの`skyId`だけで、取り残しの画像には対応する文書が無い。名前だけでは新旧を見分けられない。
  - 時刻で見分けるなら、ゲートウェイの`listFiles`を、Cloud Storageのオブジェクトの作成時刻（オブジェクトのメタデータの`timeCreated`）も返す形に変える必要がある。Firestoreのサーバー時刻とStorageの時刻の比較にもなる。
  - 一方で、メンバーの文書が無い間は、新しい投稿と画像を作れない。片づけ中（写しがある）の参加を断れば、入り直しは写しが消えた後（＝その回の片づけが終わった後）にしか起きない。
  - よって、1回の実行の中では入り直した後のものに触れない。触れうるのは、別の実行がその回を終えた後に、遅れた実行が続けた場合だけ。
- **Implications**: 時刻の比較はしない。区切りごとに「同じ回の印が残り、メンバーの文書が無い」ことを照合する。照合は「読む→照合→消す」の順で行う。照合が通った時点で入り直しが無ければ、その前に読んだものは入り直す前のもの。比べた案は表B。

### 4. 片づけ中の参加の扱い（8.4）
- **Context**: 要件は「片づけてから参加させる」か「`leave_pending`で断る」のどちらかを求める。
- **Findings**:
  - 片づけ（投稿の削除・画像の削除）はトランザクションにできない。参加のCallableの中で片づけると、参加の応答が長くなる（アプリの制限時間は20秒・`Services/SoratomoGroupService.swift:50`）。
  - 参加の中で片づけると、遅れた片づけとの重なりが増える。ただし、重なりの安全は回の札の照合（表B3）で守られるので、この点は決め手にならない。残る費用は、参加のCallableの複雑さ（片づけの予算・画像の削除の依存）と、試す物の増加。
  - 断る場合の待ち時間は、ふつう数秒（アプリが片づけの完了まで待つ）。アプリが手順1の後に止まった場合だけ、仕事Cが終えるまで最大で約6時間30分になる。これは利用者に見える事実なので、design.mdの「利用者の判断が要る点」U1に挙げた。
  - 写しがあってメンバーの文書が無い状態は、抜けるか退会の片づけ中にしか起きない（参加と作成は両方を同じトランザクションで作る）。
- **Implications**: `leave_pending`で断る。判定は「写しがあり、メンバーの文書が無い」だけで行い、印は見ない（退会の途中も同じく断れる）。所属10個の判定より先に見る。

### 5. 端末の画像のキャッシュ（5.4・5.5）
- **Context**: 抜けたグループの画像だけを消し、ほかのグループの画像は残す必要がある。
- **Sources Consulted**:
  - `Services/SoratomoStorageImageProvider.swift:61-93`。
  - Kingfisher 8.6.2のソース（`Sources/Cache/ImageCache.swift`・`Sources/Cache/DiskStorage.swift`。`gh api`でタグ8.6.2を読んだ）。
- **Findings**:
  - ディスクのファイル名は、既定で鍵のSHA-256（`usesHashedFileName = true`）。鍵（Storageのパス）の接頭辞で一覧できない。
  - `ImageCache(name:cacheDirectoryURL:diskCachePathClosure:)`（throws）で、置き場の親のフォルダを指定できる。既定の`cachePathBlock`は、親の下に`com.onevcat.Kingfisher.ImageCache.<name>`を作る。
  - 1つの`ImageCache`のメモリの上限は、既定で物理メモリの1/4（`createMemoryStorage`）。
  - ディスクのキャッシュの期限は、既定で「最後に使ってから7日」。
  - KFImageの使い場所は3か所（`SoratomoTimelineView.swift:567-568`・`SoratomoSkyDetailView.swift:233-240`）。
- **Implications**: グループごとに`ImageCache`を作る。親のフォルダは`Caches/soratomo-images/`にまとめ、サインアウトでは親のフォルダごと消す。1.14.xの共通のキャッシュは、1回だけ消す。比べた案は表C。

### 6. 抜けた後の見え方（5.2・5.3・5.6・5.7）
- **Sources Consulted**:
  - `Services/SoratomoRouter.swift:210-296`・`ViewModels/SoratomoTimelineViewModel.swift:262-283`・`:480-527`。
  - `Services/SoratomoGroupService.swift:170-225`・`:273-325`・`Services/SoratomoServiceContracts.swift:50-81`。
- **Findings**:
  - タイムラインは、グループの監視が`.notMember`になると`reportNotAccessible`を呼び、ルーターが「グループを開けませんでした」を出す（`SoratomoTimelineViewModel.swift:503-519`・`SoratomoRouter.swift:265-275`）。
  - 監視の札を止めると、Firestoreの監視を外し、届いていない結果を捨てる（`SoratomoGroupService.swift:283-289`・`:320-324`）。`start()`は札が`nil`のときだけ張り直す。
  - 一覧は、オンラインならルールの拒否で抜けたグループを飛ばす。`getDocument()`は、オフラインなら端末のキャッシュを返す。抜けたグループの古い文書が返りうる。
  - 通知からの行き先は、ルーターがそのままタイムラインを開く。オフラインなら端末のキャッシュで開けてしまう。
- **Implications**: 片づけを呼ぶ前に、タイムラインの監視を止める。完了したら、ルーターの新しい口で一覧へ戻し、別の文言を出す。端末に「抜けたグループの記録」を持ち、一覧と通知の行き先で隠す。記録は、参加の成功か、サーバーがメンバーだと確かめたときに外す。

### 7. 入口の置き場（1.1）
- **Sources Consulted**:
  - `Views/Soratomo/SoratomoTimelineView.swift:100-106`（右上の3つ）・`Views/Soratomo/SoratomoMembersView.swift:11-12`（`init`を変えない約束）。
  - `Views/Soratomo/SoratomoDependencies.swift:104-110`（いま開いているタイムラインの弱参照）。
- **Findings**: 抜ける間は、タイムラインの監視を止める必要がある。タイムラインが一番上の画面なら、同じ画面の中で止めて再開できる。メンバー一覧の下に置くと、下に隠れたタイムラインのViewModelを弱参照で探す必要がある。
- **Implications**: タイムラインの右上に「…」のメニューを足し、中身は「グループを抜ける」だけにする。既存の3つのボタンは変えない。

### 8. Firestoreのトランザクション
- **Sources Consulted**: Firestoreの公式文書（References）。
- **Findings**: 読みは書きより先に行う。競合したら、トランザクション全体を再試行する。Standard editionのサーバーのライブラリは悲観的な排他を使い、トランザクションが読んだ文書に鍵をかける。クエリが範囲に鍵をかけるかは、文書に書かれていない。
- **Implications**: 所属数の数え直しは、既存と同じく「利用者の文書を必ず読む」ことで、参加・作成・手順4を直列にする（クエリの範囲の鍵には頼らない・`functions/soratomoDeletion.js:249-250`）。人数は、グループの文書を読むことで参加と直列にする（既存）。

## Architecture Pattern Evaluation

### 表A: 途中で止まった片づけを見つける方法（4.6）

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| A1 collectionGroup | 写しに`leftAt`を足し、`collectionGroup("groups")`で`leftAt`の範囲を引く | 印の文書が増えない | コレクショングループ単位のインデックスを手で作る必要がある。インデックスより先に定期実行が動くと失敗する。soratomo specの約束（collectionGroupを使わない・design.md 995行）に反する | 不採用 |
| A2 全員の写しを読む | 仕事Aと同じく利用者を一覧し、各人の写しとメンバーの文書を読む | 新しい文書が要らない | 読みが利用者の数に比例する。抜けた時刻が無く、アプリの繰り返しと重ならないように待てない | 不採用 |
| **A3 ルートの印** | `soratomoPendingLeaves/{uid}_{groupId}`に`leftAt`・`episodeId`を置き、`leftAt`の範囲で引く | 読みは片づけ中の件数だけ。自動の単一項目インデックスで動く。印が「回の札」も兼ねる（8.6） | 印と写しの2つの文書を持つ。退会の手順4は印を消さないので、古い印が残りうる（仕事Cが`stale_marker`で消す） | **採用** |
| A4 別の定期実行（1時間ごと） | A3と同じ印を、新しい`onSchedule`で引く | 止まった片づけが早く終わる（最大1時間半） | 関数が1本増え、Cloud Schedulerのジョブも増える（無料の枠を超えると月に少額） | 不採用。既存の6時間ごとで24時間に3回の機会があり、要件を満たす |

### 表B: 遅れた片づけが入り直した後のものを消さない方法（8.6）

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| B1 時刻で絞る | 投稿は`createdAt <= leftAt`、画像は`timeCreated <= leftAt`だけを消す | 遅れた実行がいつ走っても範囲が決まる | 投稿のクエリが複合インデックス（`authorId`＋`createdAt`）を要する。ゲートウェイの口を変える（メタデータを返す）。FirestoreとStorageの時計の比較になる。取り残しの画像（文書が無い）の扱いが時刻だけになる | 不採用 |
| B2 メンバーの文書だけを再確認 | 区切りごとに、メンバーの文書が無いことだけを確かめる | 読みが1件 | 抜けて、入り直して、また抜けた場合に、古い回の遅れた手順4が新しい回の写しを消しうる（新しい回の印も残らない） | 不採用 |
| **B3 回の札で照合** | 区切りごとに「印が同じ`episodeId`のまま残り、メンバーの文書が無い」ことを確かめる。手順4も同じ照合の後だけ書く。定期実行は手順1を走らせない | 時刻もインデックスも要らない。回をまたいだ遅れも区別できる | 区切りごとに2件の読み | **採用** |

### 表C: 端末の画像をグループ単位で消す方法（5.4・5.5）

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| C1 知っている鍵だけ消す | 投稿の覚え・端末のFirestoreのキャッシュから、そのグループの投稿のパスを作って消す | 変更が小さい | 前のセッションで見た画像が残りうる（最後に使ってから7日で消えるまで）。5.4を満たし切れない | 不採用 |
| C2 鍵の台帳 | 画像を取りに行くたびに、グループごとの鍵を端末に記録し、抜けたら台帳の鍵を消す | キャッシュは1つのまま | 台帳と実物がずれうる。台帳の置き場と上限の管理が要る | 不採用 |
| **C3 グループごとのキャッシュ** | `ImageCache`をグループごとに作り、抜けたらそのキャッシュを空にしてフォルダを消す | 確実に消せて、ほかのグループに触れない | KFImageの3か所の変更。1.14.xの共通のキャッシュを1回消す。メモリの上限を割る | **採用** |

## Design Decisions

### Decision: 抜けるの入口は新しいCallable、片づけは新しい関数
- **Context**: 3.13・3.14・8.6を、既存の`deleteUserDataInGroup`のままでは守れない（Research Log 1）。
- **Alternatives Considered**:
  1. `deleteUserDataInGroup`に「抜ける」の選択肢を足す。
  2. 新しい`leaveSoratomoGroup`を作り、部品だけを共用する。
- **Selected Approach**: 2。
- **Rationale**: 退会の関数の分岐が増えない。退会の既存のテストが、そのまま退会の守りになる。
- **Trade-offs**: 手順の並びが2か所に書かれる。部品（手順1の読み書き・投稿と画像の削除）は共用するので、消す範囲はずれない。
- **Follow-up**: 退会の既存のテストが部品の変更の後も通ること。

### Decision: 片づけ中の印をルートのコレクションに置き、回の札を持たせる
- **Context**: 4.6（見つける）と8.6（遅れた実行を止める）の両方に、抜けた時刻と回の区別が要る。
- **Selected Approach**: 表A3と表B3。
- **Rationale**: インデックスとcollectionGroupが要らない。照合の読みは区切りごとに2件。
- **Trade-offs**: 新しいコレクションと、拒否だけのルールの`match`が1つ増える。public-launch specのルールの変更とは、行が重ならない。
- **Follow-up**: 本番での最初の仕事Cの実行で、クエリが失敗しないこと（design.mdの要確認Q1）。

### Decision: 片づけ中の参加は`leave_pending`で断る
- **Context**: 8.4。
- **Selected Approach**: Research Log 4のとおり。
- **Rationale**: 参加の応答時間を延ばさない。入り直しが「回の片づけが終わった後」に限られ、順序の不変条件が成り立つ。作る物が少ない。
- **Trade-offs**: 抜けた直後（ふつう数秒）に入り直そうとした人は、少し待つ必要がある。アプリの片づけが途中で止まった人は、最大で約6時間30分待つ。
- **Follow-up**: 待ち時間の扱いは利用者の判断U1（A: このまま・B: 1時間ごとの定期実行・C: 参加の中で片づける）。公開後に`soratomo_join_failed`の`leave_pending`の件数を見る。

### Decision: 定期実行は手順1を走らせない
- **Context**: 定期実行が印を見つけたとき、その人が入り直していることがある。
- **Selected Approach**: `origin: "sweep"`では、メンバーの文書があれば印だけを消して終える。
- **Rationale**: 遅れた片づけが、入り直したメンバーを外し直さない（8.6）。退会の定期実行（アカウントの無い人）とは目的が違う。

### Decision: 抜けたグループの端末の記録
- **Context**: 5.3・5.6・5.7。オフラインでは、端末のFirestoreのキャッシュから抜けたグループが出うる。
- **Selected Approach**: 利用者ごとのUserDefaultsにグループIDを最大50件。一覧と通知の行き先で隠す。参加が成功したとき、またはサーバーがメンバーだと確かめたときに外す。
- **Rationale**: 通報した投稿の記録（`SoratomoReportedSkies`）と同じ置き方で、作りと試し方がそろう。

### Decision: 入口はタイムラインの右上の「…」のメニュー
- **Context**: 1.1。Research Log 7。
- **Rationale**: 抜ける間にタイムラインの監視を止め、失敗したら再開する処理を、同じ画面の中に閉じられる。既存の3つのボタンとメンバー一覧の`init`を変えない。

## Risks & Mitigations
- 確定より前に別の端末で始まった画像のアップロードが、片づけの一覧の後に届くと、取り残しの画像が残りうる。退会と同じ既知の隙間。アプリは処理中に投稿させない（1.9）。design.mdの差し戻しD3で確認する。
- 退会が抜けるの途中のグループを処理すると、印だけが残る。仕事Cが件数0で消す（`continued`か`stale_marker`）。
- 本番でクエリがインデックスを要求した場合、仕事Cが失敗し続ける。ほかの仕事は止まらない（別の`try`）。デプロイの後の最初の実行のログで確かめる（要確認Q1）。
- グループごとのキャッシュでメモリの使い方が変わる。上限を所属の上限10で割り、合計を今と同じにする。
- 1.14.xの共通の画像のキャッシュを1回消すので、先行公開の利用者は画像を1回取り直す。人数が少なく、影響は小さい。

## References
- [Index types in Cloud Firestore（Firebase）](https://firebase.google.com/docs/firestore/query-data/index-overview) — 自動の単一項目インデックスはコレクション単位で作られる。コレクショングループ単位の自動インデックスは既定では維持されず、絞り込みや並べ替えのあるコレクショングループのクエリには、コレクショングループ単位のインデックスが要る。
- [Order and limit data（Firebase）](https://firebase.google.com/docs/firestore/query-data/order-limit-data) — 範囲の条件はその項目の並べ替えを含意し、最初の並べ替えは同じ項目でなければならない。
- [Transactions and batched writes（Firebase）](https://firebase.google.com/docs/firestore/manage-data/transactions) — 読みは書きより先。競合したらトランザクション全体を再試行する。
- [Transaction serializability and isolation / data contention（Firebase）](https://firebase.google.com/docs/firestore/transaction-data-contention) — Standard editionのサーバーのライブラリは悲観的な排他を使い、読んだ文書に鍵をかける。範囲の鍵については記載が無い。
- Kingfisher 8.6.2のソース（`gh api repos/onevcat/Kingfisher/contents/Sources/Cache/ImageCache.swift?ref=8.6.2`・`DiskStorage.swift`）。
  - 確かめたこと: `ImageCache(name:cacheDirectoryURL:)`・メモリの既定の上限・ハッシュのファイル名・ディスクの期限7日。
