# Research & Design Decisions — soratomo-reactions ⭐️

## Summary
- **Feature**: `soratomo-reactions`（そらとも投稿へのリアクション。決まった7種類の絵文字から1人1つ）
- **Discovery Scope**: Complex Integration（既存のそらともの投稿・削除・抜ける・退会・通知・ルーター・画面に広く差し込む。full discovery）
- **Key Findings**:
  - 1.15.0のアプリは、投稿の文書に足した項目を読まずに捨てる。変換後の投稿の並びが同じなら、再描画もしない。投稿の文書に埋め込めば、古い版を壊さず、削除のすべての経路と版で投稿と一緒に消える。
  - 既存の間引きの判定`decideThrottle`は「同じ投稿IDなら重複」と決める。リアクションに使うと、別の人が同じ投稿に付けた通知を「重複」として落とす。リアクションには、時刻だけで決める別の判定と、別の記録の置き場が要る。
  - 投稿詳細は、タイムラインの覚え（`SoratomoSkyLookup`・ObservableObjectでない）をbodyで1回読むだけで、覚えの変化を観測しない。リアクションの変化を10秒以内に詳細へ出すには、詳細の投稿1件の監視（`observeSky`）に中身を載せる必要がある。

## Research Log

### 1.15.0のアプリは投稿の文書に足した項目で壊れないか
- **Context**: 要件11.2。保存場所の候補「投稿の文書に埋め込む」の前提。
- **Sources Consulted**: 現物（HEAD `c1a1ea22`）。
  - メインがgit logで確かめた。1.15.0（build 113・`9a56d5e8`）の後、次の5つは変わっていない。
  - `SoratomoSkyService.swift`・`SoratomoModels.swift`・`SoratomoRouter.swift`・`GoldenHourNotificationManager.swift`・`project.pbxproj`。
- **Findings**:
  - `Services/SoratomoSkyService.swift:417`の`decodeSky`は、`authorId`・`width`・`height`・`createdAt`・`caption`（任意）を名前で読むだけ。知らない項目は見ない。`SoratomoSky`を`Codable`（`data(as:)`）で読む口は無い。
  - タイムラインの監視（`:122`）は、`document.data(with: .estimate)`の辞書を`makeTimelineSnapshot`（`:486`）→`decodeSkies`に渡す。
  - 1.15.0の`SoratomoTimelineViewModel`は、変換後の投稿の並びと「続きがありうるか」が同じなら何もしない（`:558`。1.15.0の後に変わっていないので、1.15.0でも同じ行）。`SoratomoSky`の`Equatable`にリアクションが無いので、リアクションだけの更新では再描画しない。
  - 投稿1件の監視（`:200`）は「有るか」しか届けない（`resolveObservedSky`・`:575`）。
  - 削除のルール（`firestore.rules:632`）は`resource.data.authorId`だけを見る。項目が増えても、投稿者本人の削除は通る。
- **Implications**: 投稿の文書に`reactions`と`reactorIds`を足しても、1.15.0のタイムライン・続きの読み込み・投稿詳細・削除は変わらない（要件11.1・11.2）。1.15.0の端末にも更新のたびに監視の読み取りが届くが、件数は小さい（グループは最大20人）。

### 絵文字のセットと、保存する値
- **Context**: 要件4.4〜4.6・13.3・15.4。
- **Sources Consulted**: メインの実測（コードポイントとUTF-16の単位数）。`functions/soratomoCore.js:144`の`codePointLength`。メモリの記録（Firestoreルールの`size()`はUTF-16の単位で数える・ASCのリリースノートは絵文字を拒否する）。
- **Findings**:
  - ☁️（U+2601 U+FE0F）と❤️（U+2764 U+FE0F）は異体字セレクタ付き。キーボードや経路によって、FE0Fの無い形でも来うる。✨（U+2728）はFE0Fを持たない。
  - 要件15.4は、計測の`kind`を「絵文字のセットと一緒に決める英小文字のスネークケースの名前」と定めている。
- **Implications**: 送る値と保存する値を名前（`sunset`など）にする。絵文字は表示側（アプリの対応表とサーバーの通知文の対応表）で引く。見た目の揺れ（要件4.5）はサーバーの検証の問題でなくなる。保存の名前と計測の名前が1つの列挙で済む。

### 投稿を消したとき、投稿の下の子は残る
- **Context**: 要件8。サブコレクション案の評価。
- **Sources Consulted**:
  - `Services/SoratomoSkyService.swift:315-330`（アプリの削除は投稿の文書1件だけ）。
  - `functions/soratomoDeletion.js:235`の`deleteSkiesByQuery`（`:242`の`batch.delete`）、`:814`の`deleteSoratomoSky`、`:401`・`:640`の`recursiveDelete`。
  - `functions/soratomo.js:715-727`の公開（投稿の削除トリガーは無い）。
- **Findings**: 子ごと消すのは、グループごと消す2か所だけ。1.15.0のアプリが投稿を消すと、投稿の下の子は残る。
- **Implications**: サブコレクション案では、すべての削除の経路に後始末を足すか、削除トリガーか定期実行で孤児を拾う必要がある。埋め込み案では、投稿の文書と一緒に消える。要件8.1〜8.5が、経路と版に依らず自動で満たされる。

### 通知の間引きの記録と、重複の判定
- **Context**: 要件6.5〜6.8・14.4。
- **Sources Consulted**:
  - `functions/soratomoStore.js:493`の`claimNotifySlot`、`functions/soratomoCore.js:251`の`decideThrottle`。
  - `firestore.rules:636-638`、`functions/soratomoDeletion.js:404`・`:540`。
  - `docs/firestore-schema.md:296-317`（`recommendationNotices`の前例）。
- **Findings**:
  - `notifyState/{uid}`は、グループごと・受信者ごとに1件（`lastSentAt`・`lastSkyId`）。共用すると、リアクションの通知が新着投稿の通知を間引く（要件6.6）。
  - `decideThrottle`は、`lastSkyId === skyId`を「重複」（トリガーの再配信）とする（`:253`）。リアクションに使うと、Aが投稿Pに付けて送った10分後に、Bが同じPに付けても「重複」で送らない。
  - 前例の`recommendationNotices`（ルートの「おすすめ」の通知）は、外して入れ直しても通知は最初の1回だけ、を印の文書の`create()`で守る。TTL（365日）で消えるので、期限の後は再び通知されうる。
- **Implications**: リアクション用に、間引きの記録（投稿者ごと）と送った印（投稿ごと）を、別のコレクションに置く。判定は、時刻だけで決める新しい純関数にする。印と間引きは、1つのトランザクションで読んで書く。TTLは使わない（要件6.8は期限を設けていない）。

### 投稿詳細はリアクションの変化に追従するか
- **Context**: 要件2.5（投稿詳細も10秒以内）。
- **Sources Consulted**:
  - `Views/Soratomo/SoratomoSkyDetailView.swift:95-97`・`:136-154`。
  - `Views/Soratomo/SoratomoDependencies.swift:29-70`（`SoratomoSkyLookup`）。
  - `ViewModels/SoratomoTimelineViewModel.swift:590-595`（`rebuildSkies`→`rememberSkies`）。
- **Findings**:
  - 詳細は、`dependencies.skyLookup.sky(groupId:skyId:)`をbodyの中で読む。`SoratomoSkyLookup`はObservableObjectでない。`:95-96`のコメントは「開いている間に変わるのは削除だけ」として読み直さない。
  - bodyが作り直されるのは、自分の`@State`と`profileStore`が変わったときだけ。タイムラインの監視が`rememberSkies`で覚えを新しくしても、詳細は描き直さない。
  - 詳細は、開いている間`observeSky`を張っている（`:136`）。結果は`.present`・`.gone`・失敗だけで、中身を持たない。
- **Implications**: 詳細の監視を、中身（リアクション）まで届ける形に広げる（`SoratomoSkyPresence.present`にリアクションを載せる）。同じ文書へ2本目のリスナーは張らない。SDKは同じ文書の監視を1つにまとめるので費用は同じだが、同じ文書を2つの経路で読むと、2つの結果の食い違いを考える必要が出る。

### 1.15.0のアプリが未知のtypeの通知を受けたとき
- **Context**: 要件11.3〜11.5。
- **Sources Consulted**:
  - `Services/GoldenHourNotificationManager.swift:41-43`・`:234-254`。
  - `Services/SoratomoRouter.swift:28`・`:42-50`・`:207-210`・`:231-232`。
  - `AppDelegate.swift`（通知のデリゲートに関わらない）、`Services/PushNotificationManager.swift`（トークンだけ）、`SoramoyouApp.swift:61`（デリゲートは`GoldenHourNotificationManager.shared`だけ）。
- **Findings**:
  - `didReceive`は、識別子がゴールデンアワーの接頭辞のときだけ計測し（`:246-248`）、`SoratomoRouter.shared.receive`に渡す（`:253`）。
  - `receive`は、`SoratomoNotificationPayload.parse`がnilなら何もしない（`:207-210`）。`parse`は`type == "soratomoPost"`のときだけ値を返す。
  - 保留（`pending`）が無いので、`resolvePending`は何もしない（`:232`）。`soratomo_notification_opened`は記録されない。
  - 前面での表示は、全種類で共通の`[.banner, .sound, .list]`（`:43`）。
- **Implications**: 通知の`type`を`soratomoReaction`にすれば、1.15.0は落ちず、別の画面やグループへ進まず、新着投稿として計測しない（アプリが開くだけ）。新しい版のルーターに`soratomoReaction`を足す。

### Firestoreのインデックス
- **Context**: 要件9（本人のリアクションをグループの中で引く）・要件16.7。
- **Sources Consulted**: [Indexing overview](https://docs.cloud.google.com/firestore/native/docs/concepts/index-overview)、[Manage indexes](https://docs.cloud.google.com/firestore/docs/query-data/indexing?authuser=0)、`firestore.indexes.json`（`fieldOverrides`は空）。
- **Findings**:
  - 配列の項目には、コレクションの範囲のarray-containsの単一項目インデックスが自動で作られる。
  - 地図の項目は、下の項目ごとに再帰的に索引される。
  - コレクショングループの範囲の単一項目インデックスは、自動では作られない（このspecは使わない）。
- **Implications**:
  - `skies.where("reactorIds", "array-contains", uid)`と`reactionNotices.where("notifiedReactorIds", "array-contains", uid)`は、インデックスを足さずに動く。`firestore.indexes.json`は変えない。
  - `reactions`の地図の下の項目も自動で索引されるが、1件あたり最大20人分で、1文書の索引の上限から遠い。除外の設定（`fieldOverrides`）はデプロイを増やすので足さない。

### Callableの応答の後の処理
- **Context**: 通知をCallableの中で送るか。
- **Sources Consulted**: [Functions best practices](https://docs.cloud.google.com/functions/docs/bestpractices/tips)、[CPU throttlingの事例](https://dev.to/dalenguyen/the-background-task-that-froze-a-serverless-cpu-throttling-mystery-3j3d)。
- **Findings**: 関数が応答を返した後の非同期の処理には、CPUが割り当てられず進まない（2nd genはCloud Runのリクエスト課金が既定）。後で別の呼び出しの最中に動き出して、邪魔をすることもある。
- **Implications**: 通知は、Callableの本体の中で`await`し終えてから応答を返す。応答の時間に、送信の時間（数百ミリ秒）が加わる。アプリは楽観的な表示で、待ち時間を見せない。

### トランザクションの競合
- **Context**: 要件4.9・4.10（同時の要求）。
- **Sources Consulted**: [Data contention in transactions](https://docs.cloud.google.com/firestore/docs/transaction-data-contention)、[Understand error codes](https://docs.cloud.google.com/firestore/docs/understand-error-codes)、[Best practices](https://docs.cloud.google.com/firestore/docs/best-practices)。メモリの記録（エミュレーターは競合したトランザクションを`INVALID_ARGUMENT`で返す）。
- **Findings**: サーバーのライブラリ（Admin SDK）は悲観的な排他で、読んだ文書をロックする。競合したトランザクションは、決まった回数まで自動で再試行される。1文書への書き込みが多すぎると、ABORTEDが増える。
- **Implications**: 1つの投稿への同時のリアクション（最大19人）は、投稿の文書のトランザクションで直列になる。量は小さい。テストは、既存の要確認3の型（同時実行の想定内の失敗を許す）にそろえる。

### APNsの置き換えキー
- **Context**: 要件6.14。
- **Sources Consulted**: [Amazon PinpointのAPNs collapse id](https://docs.aws.amazon.com/sdk-for-kotlin/api/latest/pinpoint/aws.sdk.kotlin.services.pinpoint.model/-apns-message/collapse-id.html)、[apns2 crate](https://docs.rs/apns2)、`functions/pushHelpers.js:95-127`。
- **Findings**: `apns-collapse-id`は64バイトまで。スレッドIDは`aps`の中の値で、既存は`soratomo-{groupId}`。
- **Implications**: 置き換えキーは、新着投稿の`soratomo-{groupId}`と別の値にする。グループ単位なら`soratomo-reaction-{groupId}`（38バイト）、投稿単位なら`soratomo-rx-{groupId}-{skyId}`（53バイト）。どちらも64バイトに収まる（IDは自動IDの20文字）。どちらにするかは、利用者の確認事項にした（design.mdのU2）。

### カードの押せる範囲とVoiceOver
- **Context**: 要件1.7・1.8・13.4。
- **Sources Consulted**: `Views/Soratomo/SoratomoTimelineView.swift:390-445`。
- **Findings**:
  - カードは全体が1つの`Button`（`.buttonStyle(.plain)`）で、ラベルの中に行の中身がある。長押しのメニューは、同じ`Button`に付いている（`:412`）。
  - SwiftUIでは、Buttonのラベルの中に別のButtonやMenuを置くと、タップを外のButtonに取られ、中の操作を押せないことがある。
- **Implications**: リアクションの操作（`Menu`）は、カードのButtonのラベルの外（`overlay`）に置く。数の表示はラベルの中に置き、押すと詳細へ進むようにする（要件1.8）。長押しのメニューはoverlayより先に付け、リアクションの操作の上では出ない形にする。実機の押せる範囲とVoiceOverの要素の分かれ方は、実装の時に確かめる（design.mdの要確認）。

## Architecture Pattern Evaluation

保存場所の比較。制約は次の6つ。(a) collectionGroupのクエリ禁止、(b) 10秒以内の反映、(c) 見る人ごとのブロックの除外、(d) 削除の全経路と全版、(e) 抜けると退会で本人の分を引く、(f) 投稿の作成と更新をクライアントに許さない。

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| A. 投稿の文書に埋め込む（**採用**） | `skies/{s}.reactions: { uid: { kind, at } }`と`reactorIds: [uid]` | (b) 既存のタイムラインの監視1本で届く。(c) 付けた人ごとの情報が端末にある。(d) 投稿の文書と一緒に消える。(e) `reactorIds`のarray-containsで引ける。(f) 書き手はAdmin SDKだけ | 投稿の文書の更新が、監視しているメンバー全員（1.15.0を含む）に届く。1つの投稿への書き込みが直列になる | 1人1つは地図のキーで自明 |
| B. 投稿の下のサブコレクション`skies/{s}/reactions/{uid}` | 1人1文書 | 1人1つは文書IDで自明 | (a) 投稿ごとの監視（最大60本）かcollectionGroupが要る。(d) 1.15.0の削除で孤児が残る。(e) 投稿を全部回るかcollectionGroupが要る | 退けた |
| C. グループの下の平らなコレクション`soratomoGroups/{g}/reactions/{skyId}_{uid}` | `skyId`・`uid`・`kind`を項目に持つ | (e) `uid`の等式で引ける | (b) 監視は「グループの全リアクション」（増え続ける）か`skyId in [...]`（30件ずつ・窓が変わるたびに張り直し）。(d) 孤児の後始末が別に要る | 退けた |
| D. クライアントがルールで直接書く | `skies`の`update`を「自分のキーだけ」に開く | 応答が速い | (f) に反する（要件12.8）。利用停止の確認（4.11）にルールの`get`が増える。通知には更新のトリガーが要る | 退けた |

## Design Decisions

### Decision: 保存場所は投稿の文書に埋め込む
- **Context**: 制約(a)〜(f)を同時に満たす必要がある（要件2.5・2.6・5.1・8・9・12.8）。
- **Alternatives Considered**:
  1. サブコレクション（B）
  2. グループの下の平らなコレクション（C）
  3. ルールでクライアントに書かせる（D）
- **Selected Approach**: A。`reactions`は「uid→`{ kind, at }`」の地図、`reactorIds`は付けた人のuidの配列。書き手は、Callable`soratomoSetReaction`と、抜ける・退会の片づけ（どちらもAdmin SDK）だけ。
- **Rationale**: 上の表のとおり。とくに(d)は、1.15.0のアプリからの削除を含めて、仕組みの上で自動になる。
- **Trade-offs**: 投稿の文書の更新が、監視している全員に届く（最大20人・数バイト）。1つの投稿への同時の書き込みは直列になる。
- **Follow-up**: 本番の最初の抜けるの後に、array-containsのクエリが`FAILED_PRECONDITION`にならないことを確かめる。

### Decision: 地図の値は`{ kind, at }`にする（名前だけの文字列にしない）
- **Context**: 押した人の一覧の並び順（要件3の補足で設計に委ねられた）。後から形を変えると移行になる。
- **Alternatives Considered**:
  1. `reactions: { uid: "sunset" }`（名前だけ）
  2. `reactions: { uid: { kind: "sunset", at: Timestamp } }`
- **Selected Approach**: 2。`at`は、付けた・選び直したときのサーバーの時刻。
- **Rationale**: 一覧を新しい順に並べられる。後で「前に見てから付いた反応」などを足すときも、移行が要らない。
- **Trade-offs**: 文書が少し大きくなる（1人あたり数十バイト）。アプリの変換が1段深くなる。

### Decision: 送る値・保存する値は、絵文字でなく名前にする
- **Context**: 要件4.4〜4.6・15.4。
- **Alternatives Considered**:
  1. 名前（`sunset`など）を送り、名前で保存する
  2. 絵文字そのものを送り、サーバーで正規化（FE0Fの有無をそろえる）して保存する
- **Selected Approach**: 1。
- **Rationale**:
  - 2は、正規化の規則（どの形を正とするか）を、アプリとサーバーの両方に持たせる必要がある。改造したアプリからの似た文字（肌の色の修飾・ZWJの組み合わせ）も、1つずつ拒否する必要がある。
  - 1は「7つの名前のどれか」を比べるだけで、要件4.5は表示の対応表の問題になる。計測の`kind`（15.4）とも1つの列挙で済む。
- **Trade-offs**: 絵文字の対応表を、iOS（`SoratomoReactionKind`）とFunctions（`REACTION_KINDS`）の2か所に持つ。両方の単体テストで7行の値を固定する（`GUIDELINE_VERSION`と同じ作法）。

### Decision: 通知はCallableの中で、トランザクションの確定の後に送る
- **Context**: 要件6.1・6.7・6.16・6.17。
- **Alternatives Considered**:
  1. Callableの中で、リアクションのトランザクションが「新しく付いた（added）」と確定した後に送る
  2. 投稿の更新のトリガー（`onDocumentUpdated`）で、前後の差分から「新しく付いた人」を拾って送る
- **Selected Approach**: 1。送信まで`await`してから応答を返す。送信の失敗は結果の文字列にして、例外を投げない。
- **Rationale**: トランザクションの結果が「新しく付いた」かを正確に知っている。2は、外す・選び直す・片づけの更新でも発火し、差分の読み違いと再配信に備える必要がある。1なら関数の数も増えない。
- **Trade-offs**: Callableの応答に、送信の時間が加わる。確定の後、送信の前にインスタンスが止まると、その1通は送られない（受け入れる。要件6.16のとおりリアクションは残る）。
- **Follow-up**: 再試行で`unchanged`になった要求からは送らない。送ると、間引かれた付け方が後から通知になり、要件6.5の「後からまとめて送らない」に触れうるため。

### Decision: 間引きの記録と送った印は、別々のサーバー専用の文書に置き、1つのトランザクションで判定する
- **Context**: 要件6.5・6.6・6.8。
- **Alternatives Considered**:
  1. 既存の`notifyState/{uid}`を共用する
  2. 印を投稿の文書（メンバーが読める）に置く
  3. 印を「投稿ID_付けた人」の文書ごとに置き、TTLで消す（`recommendationNotices`の型）
  4. 間引きは`reactionNotifyState/{投稿者}`、印は`reactionNotices/{投稿ID}`（付けた人のuidの配列）に置き、投稿の削除トリガーで印を消す
- **Selected Approach**: 4。
  - 判定は新しい純関数`decideReactionNotify`。印に入っていれば`duplicate`、5分以内なら`throttled`、それ以外は`send`。
  - `send`のときだけ、間引きの記録と印を同じトランザクションで書く。間引かれたときは印を書かない。
- **Rationale**: 1は新着投稿の通知を間引く（6.6）。2はメンバーが「一度付けて外した」ことを読めてしまい、抜けると退会で消す対象も増える。3は期限の後に2通目が出うる（6.8は期限を設けていない）。4は、印が投稿と一緒に消え（トリガー）、本人が抜けると退会でuidを外せる（array-contains）。
- **Trade-offs**: コレクションが2つ、削除トリガーが1本増える。間引かれた付け方は印を残さないので、5分を過ぎてから外して付け直すと1通が出うる（それでも、同じ人の同じ投稿で多くても1通）。

### Decision: 投稿の削除トリガーで印を消し、消えたリアクションの数をログに残す
- **Context**: 要件8（消した空に関わる記録を残さない）・要件14.5（要件8の削除の件数）。
- **Alternatives Considered**:
  1. 削除トリガー`onSoratomoSkyDeleted`
  2. 定期実行で、グループを回って孤児の印を拾う
  3. 印を残す（`notifyState.lastSkyId`と同じくIDだけなので受け入れる）
- **Selected Approach**: 1。削除された文書の中身（`event.data`）から`reactions`の件数を数えてログに出し、`reactionNotices/{skyId}`を消す。
- **Rationale**: 削除の経路と版に依らず発火する（1.15.0の削除・グループごとの削除・運用の削除）。リアクションの件数のログ（14.5）を、要件8のすべての経路で1か所から出せる。2は、グループの数と印の数に比例して読み取りが増える。
- **Trade-offs**: 関数が1本増える。グループごと消すときは、投稿の数だけ発火する（1件あたり書き込み1つ・無料枠の範囲）。トリガーが失敗すると印が残るが、印はサーバー専用で、残っても「通知しない」側にしか効かない。

### Decision: 投稿詳細は`observeSky`を広げてリアクションを受け取る
- **Context**: 要件2.5（詳細でも10秒以内）。
- **Alternatives Considered**:
  1. `SoratomoSkyPresence.present`にリアクションを載せる（監視は1本のまま）
  2. 新しいprotocolの`observeReactions`で、同じ文書に2本目の監視を張る
  3. 覚え（`SoratomoSkyLookup`）をObservableObjectにする
- **Selected Approach**: 1。
- **Rationale**: 同じ文書を1つの経路で読む。3は、タイムラインの窓（20・40・60件）から投稿が外れると覚えが更新されず、詳細の追従が窓に左右される。
- **Trade-offs**: `SoratomoSkyPresence`の形が変わる。詳細の`case .success(.present)`（`SoratomoSkyDetailView.swift:145`）と、既存のモックとテストの`.present`を直す。

### Decision: 押した人の一覧はシートにする
- **Context**: 要件3.1・15.6（別の画面にするかは設計に委ねられた）。
- **Selected Approach**: 投稿詳細の「押した人を見る」から、シートで出す。画面名（`logScreen`）は足さない（15.6は「新しい画面として作る場合」の条件）。開いたことは`soratomo_reactions_viewed`で記録する。
- **Rationale**: 一覧は最大20行で、続きの読み込みと遷移が無い。ルーターのパス（`SoratomoDestination`）を増やさずに済む。leave-groupの確認と処理中の表示も、新しい画面にしなかった。

### Decision: アプリは楽観的に表示し、結果が出たら一時の表示を10秒で手放す
- **Context**: 要件1.9・1.10・2.6・10.3。
- **Selected Approach**:
  - 押した時点で、自分の分だけを一時の表示（上書き）で先に変える。
  - 成功したら上書きを「確定」にし、10秒後に消す（それまでに監視がサーバーの状態を届ける・要件2.5）。
  - 失敗したら上書きをすぐ消して元に戻し、失敗を出す。送っている間は、同じ投稿の操作を受け付けない。
- **Rationale**: Callableの応答に通知の送信が含まれるので、待たせると重く感じる。上書きは自分の1件だけで、ほかの人の数には触れない（2.6）。
- **Trade-offs**: 10秒の間に別の端末で自分のリアクションを変えると、その間だけこの端末の表示が古い（受け入れる）。

## Risks & Mitigations
- 1.15.0の互換の前提が崩れる（将来`Codable`の読み方に変える等）。対策: 要件11.6の手順（1.15.0のビルドで通す）をリリース手順に置く。`docs/firestore-schema.md`の`skies`の行に「アプリは知らない項目を読み捨てる前提」を書く。
- 本人のリアクションの除去が、入り直した後のリアクションに及ぶ（要件9.4）。対策: 抜けるの照合（`isLeaveEpisodeCurrent`）を、除去のページごとの「更新する前」に挟む（投稿と同じ「読む→照合→消す」）。照合と更新の間の隙間は、更新の前提条件（`lastUpdateTime`）で閉じる（2026-10-18に利用者が決定）。陽性対照で確かめる。
- 除去の途中で投稿が消える（`update`がNOT_FOUND）。対策: 1件ずつの結果を見て、NOT_FOUNDは数えずに飛ばす。`set(merge)`は使わない（消えた投稿を作り直すため）。
- 戻り値の件数の項目（`reactionsDeleted`）の追加で、既存のテストの`deepStrictEqual`が割れる。対策: 既存の件数の意味は変えず、期待値に`reactionsDeleted: 0`を足して直す。要件12.12の「結果を変えない」は、消す範囲と既存の件数の値についての規則と読む。
- Callableの応答が遅くなる（送信を含む）。対策: 楽観的な表示。応答の制限時間は、既存の20秒（`SoratomoGroupService.callTimeout`）。
- カードの押せる範囲が実機で重なる。対策: overlayに置く。実機とVoiceOverで確かめる（要確認）。
- 削除トリガーが`recursiveDelete`とバッチの削除でも発火するか。対策: エミュレーターで件数を数えて確かめる（要確認）。

## References
- [Firestore: Indexing overview](https://docs.cloud.google.com/firestore/native/docs/concepts/index-overview) — 配列のarray-containsと地図の下の項目の、自動の単一項目インデックス
- [Firestore: Manage indexes](https://docs.cloud.google.com/firestore/docs/query-data/indexing?authuser=0) — 除外の設定
- [Firestore: Data contention in transactions](https://docs.cloud.google.com/firestore/docs/transaction-data-contention) — サーバーのライブラリの悲観的な排他と再試行
- [Firestore: Understand error codes](https://docs.cloud.google.com/firestore/docs/understand-error-codes) — ABORTEDの原因
- [Firestore: Best practices](https://docs.cloud.google.com/firestore/docs/best-practices) — 書き込みの頻度と競合
- [Cloud Functions: best practices](https://docs.cloud.google.com/functions/docs/bestpractices/tips) — 応答の後の処理は進まない
- [CPU throttlingの事例（DEV Community）](https://dev.to/dalenguyen/the-background-task-that-froze-a-serverless-cpu-throttling-mystery-3j3d) — 2nd genの応答後の処理
- [Extend Cloud Firestore with Cloud Functions (2nd gen)](https://firebase.google.com/docs/firestore/extend-with-functions-2nd-gen?hl=el) — `onDocumentDeleted`
- [Amazon PinpointのAPNs collapse id](https://docs.aws.amazon.com/sdk-for-kotlin/api/latest/pinpoint/aws.sdk.kotlin.services.pinpoint.model/-apns-message/collapse-id.html) — `apns-collapse-id`は64バイトまで
- [apns2 crate](https://docs.rs/apns2) — collapse idの上限の実装例
