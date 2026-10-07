# Research & Design Decisions（そらとも公開前ゲートG1・G2）

## Summary
- **Feature**: `soratomo-release-gate`
- **Discovery Scope**: Extension（既存のそらともv1への機能追加）＋Complex Integration（Callable・定期実行・Discord・Storageの一括削除）。full discoveryの手順で行った。
- **根拠の範囲**: 手元のコード（worktree soratomo・main 4bbb465以降）と、親セッションが渡した現状調査メモ2本（`.claude/handoffs/2026-10-08_そらとも公開前ゲート_現状調査G1.md`・`…G2.md`）と、公式ドキュメント。本番のFirestore・Firebaseには触れていない。
- **Key Findings**:
  - 投稿詳細（`SoratomoSkyDetailView`）は、タイムラインが覚えた投稿（`SoratomoSkyLookup`）を読むだけで、削除を知る口が無い。`remember`は追加と上書きだけで、消えた投稿を忘れない。要件1.7は今の構造では満たせない。
  - Firestoreのトランザクションの直列化は、文書単位のロックで説明されている。クエリの範囲（後から条件に合う文書が入ること）を守る記述は無い。退会の削除と参加の競合（要件2.11）は、両方がグループの文書を読んで書くことで直列にする。
  - 既存の`blockUser`（`updateData`）は、圏外でも失敗せず、サーバーに届くまで戻らない（`SettingsViewModel.swift:184-185`のコメント）。要件9.9（圏外での失敗の表示）を満たすには、書き込みだけのトランザクションを使う別の口が要る。

## Research Log

### 既存コードの事実（設計の前提の確かめ）
- **Context**: 採用済みの方針が、現物のコードと食い違わないかを確かめた。
- **Sources Consulted**:
  - Functions: `functions/soratomo.js`・`soratomoStore.js`・`soratomoCore.js`・`index.js`・`package.json`
  - ルール: `firestore.rules`・`storage.rules`・`scripts/rules_test_soratomo.py`
  - iOS: `Soratomo*`・`SettingsViewModel.swift`・`FirestoreService.swift`・`PostDetailViewModel.swift`
  - iOS（続き）: `PaginatedPostsViewModel.swift`・`PostPage.swift`・`ContentView.swift`
- **Findings**:
  - `createGroupTx`と`joinGroupTx`は、`groupCount`の無い`soratomoUsers/{uid}`を正しく扱う。`countOf(undefined)`は0（`soratomoStore.js:84-86`）。書き込みは`tx.set(userRef, {...}, { merge: true })`（`:157-161`・`:207`）なので、同じ文書に置いた同意と利用停止の項目は消えない。
  - Callableの共通の包み（`soratomoCallable`・`soratomo.js:82-104`）は、必ず`requireSoratomoUser`（クレームの検査）を通る。退会のCallableは、この包みに「クレームを検査しない」選択肢を足して使う。
  - `SoratomoDomainError`にgRPCのcodeを持たせない決まりがある（`soratomoStore.js:17-18`）。新しい理由も同じ扱いにする。
  - タイムラインは1本のリスナーで`limit`を伸ばす方式（`SoratomoTimelineViewModel.swift:178-184`）。「続きがありうるか」は変換前の文書の件数で決める（`SoratomoSkyService.swift:325-356`）。`PostPage.isExhausted`と同じ規則がすでにある。
  - タイムラインの空の案内は、表示する投稿が0件で、1回でも読めたら出る（`SoratomoTimelineView.swift:140-150`）。続きの読み込みは、末尾の行の`onAppear`だけが起こす（`:224-229`）。全部を隠すと、続きを読むきっかけが無くなる。
  - 投稿の保存の「結果が確定しない失敗」は、`skyExistsOnServer`でサーバーの有無を確かめてから画像を消す（`SoratomoComposeViewModel.swift:390-409`）。Callableでは、関数がまだ動いている間に「無い」と読める。
  - 招待の画面の「オーナーか」は、グループのリスナーが届けた`ownerId`で毎回決め直す（`SoratomoInviteViewModel.swift:108`）。オーナーの引き継ぎの後、再発行の操作は手を入れずに出る（要件2.8）。
  - グループ一覧は、パスが空へ戻るたびに読み直す（`SoratomoGroupListView.swift:88-91`）。メンバー一覧は開くたびに読む。要件2.12は変更なしで満たす。
  - 通知のタップは、一覧を経ずに`[.timeline(groupId)]`のパスで開く（`SoratomoRootView.swift:19`）。入口の同意（要件10.2）は、一覧ではなく根の画面で判定する必要がある。
  - `.userBlocked`通知は`PaginatedPostsViewModel`（ホーム・タグ・ギャラリー・ForYou）が購読している（`PaginatedPostsViewModel.swift:84-108`）。そらとものブロックから同じ通知を送れば、要件9.8は追加の実装なしで満たす。
  - サインアウトの後片付け（`ContentView.swift:86-93`）は、ルーター・判定・画像のキャッシュ・表示名・投稿の覚えを消す。
  - 既存の退会は2か所で同じ順に呼ぶ（匿名: `SettingsViewModel.swift:242-251`、メール: `:274-287`）。`deleteUserData`は「人から見えなくなるものを先に」消す方針（`FirestoreService.swift:860-866`）。
  - `firebase.json`には、Storageのエミュレーター（ポート9199）の設定がすでにある。`test:emulator`は`--only firestore`だけを起こしている。
  - `rules_test_soratomo.py`は、投稿の作成をALLOWと期待するケースが約25件ある。`MUTANTS`は`SKY_CREATE`・`CAPTION_RE`・`DIMENSION`の文字列がルールにちょうど1回現れることを確かめる。
- **Implications**: 投稿詳細に削除を知らせる口（`observeSky`）を足す。入口の同意は根の画面に置く。ブロックは別の書き込み口を作る。投稿の保存の確かめ方を「同じ投稿IDでの送り直し」に変える。ルールのテストは作成のケースを作り直す。

### Firestoreのトランザクションの直列化
- **Context**: 退会の削除（メンバーを外して人数を数え直す）と、参加のCallable（人数を読んで1増やす）が同時に走ったとき、要件2.11を満たせるか。
- **Sources Consulted**: [Transaction serializability and isolation](https://firebase.google.com/docs/firestore/transaction-data-contention)
- **Findings**:
  - サーバーのクライアントライブラリ（Admin SDK）は悲観的な同時実行制御で、トランザクションが読んだ文書にロックを置く。ロックは、ほかのトランザクション・バッチ・非トランザクションの書き込みを止める。
  - トランザクションはコミットの時刻で直列化される（serializable）。
  - クエリの範囲のロック（後から条件に合う文書が入るのを止める）については、このページに記述が無い。
- **Implications**: 人数の正しさを「メンバーのクエリのロック」に頼らない。退会の削除と参加の両方が、グループの文書を読んで書く。これで2つは同じ文書のロックで直列になる。所属数も同じ考え方で、`soratomoUsers/{uid}`の文書を両方が読んで書く。

### Authの削除を知る方法
- **Context**: アカウントが別の経路（古い版のアプリ・Android版・コンソール）で消えたとき、24時間以内に残りを消す（要件4.1）。
- **Sources Consulted**: [firebase functions.identity（2nd gen）](https://firebase.google.com/docs/reference/functions/2nd-gen/node/firebase-functions.identity)・[Firebase Authentication triggers（1st gen）](https://firebase.google.com/docs/functions/auth-events)・firebase-functions 7.4.0の`.guides/upgrade.md`（unpkg）
- **Findings**:
  - 2nd genのidentityにあるのはブロッキング関数（`beforeUserCreated`・`beforeUserSignedIn`など）だけで、Authの削除のイベントは無い。
  - 1st genの`auth.user().onDelete()`は、firebase-functions 7でも`firebase-functions/v1`の読み込み口から使える。
- **Implications**: 2nd genはAuthの削除のトリガーを持たない。ただし1st genを混ぜる選択肢は残っている。設計では定期実行を選び、1st genを混ぜない理由を書く（下のDesign Decisions）。

### Admin SDKの削除の道具
- **Context**: 1回で消し切れない量の削除と、親の文書が無いのに子が残る状態の扱い。
- **Sources Consulted**: [Node.js Firestoreの`Firestore.recursiveDelete`](https://googleapis.dev/nodejs/firestore/latest/Firestore.html)・[`CollectionReference.listDocuments`](https://googleapis.dev/nodejs/firestore/latest/CollectionReference.html)・[nodejs-storage `src/file.ts`](https://github.com/googleapis/nodejs-storage/blob/main/src/file.ts)・[Manage Users（getUsers）](https://firebase.google.com/docs/auth/admin/manage-users)
- **Findings**:
  - `recursiveDelete(ref)`は、指定した参照より下の文書とサブコレクションを`BulkWriter`で消す。途中の削除が失敗しても、指定した参照そのものは消される。
  - `listDocuments()`は「missing documents」（文書は無いが、サブコレクションに文書がある場所）の参照も返す。
  - `File.delete({ ignoreNotFound: true })`で、無いファイルの削除をエラーにしない。
  - `getUsers`は1回に100件までの識別子を受け取り、見つからなかったものを`notFound`に返す。
- **Implications**: グループごと消すときは「グループの文書を先に消し、子は後で消す」順にし、再実行の入口は所属の写しにする（写しは最後に消す）。孤児の一覧（要件4.3）は`listDocuments()`で親の無い文書まで拾う。Storageの削除は、404を「消した数」から除いて進める。

### Callableの時間
- **Context**: 退会の削除が長くなったときの、関数とアプリの両方の制限時間。
- **Sources Consulted**: [HTTPSCallable（FirebaseFunctions for Swift）](https://firebase.google.com/docs/reference/swift/firebasefunctions/api/reference/Classes/HTTPSCallable)・[firebase functions.https.httpsoptions（2nd gen）](https://firebase.google.cn/docs/reference/functions/2nd-gen/node/firebase-functions.https.httpsoptions)
- **Findings**:
  - iOSの`HTTPSCallable.timeoutInterval`の既定は70秒。呼び出しごとに変えられる。
  - 2nd genのCallable（HTTPS）の`timeoutSeconds`の上限は3,600秒。イベントの関数は540秒。
  - 既存のそらとものCallableは、アプリ側で20秒（`SoratomoGroupService.callTimeout`）。
- **Implications**: 1回の呼び出しを短い予算（45秒）に区切り、`done`を返して、アプリが続きを呼ぶ形にする。20秒の定数は退会には使わない。

### 圏外でのブロックの保存
- **Context**: 要件9.9（ブロックの保存に失敗したら、失敗を出して隠さない。通信できない状態を含む）。
- **Sources Consulted**:
  - `SettingsViewModel.swift:184-185`（`updateData`は圏外でも失敗せず、サーバーに届くまで戻らない）
  - `SoratomoSkyService.swift:21-23`（書き込みだけのトランザクションは端末内に積まれず、オフラインで失敗する）
- **Findings**: 既存の`FirestoreService.blockUser`（`:1159-1167`）は`updateData`で、圏外では待ち続け、つながったときに後から適用される。
- **Implications**: そらとものブロックは、同じ項目（`users/{uid}.blockedUserIds`への`arrayUnion`）を、書き込みだけのトランザクションで書く別の口にする。既存の`blockUser`と、ルートの画面のブロックは変えない（要件13.4）。

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| 退会: 本人用Callable（採用） | アプリがAuthの削除の前に呼ぶ | 「消し終えてからAuthを消す」を確かめられる（3.1）。Android版も呼ぶだけ | 関数の障害で退会が止まる | 定期実行と管理スクリプトで補う |
| 退会: `deleteUserData`に足す | アプリから直接消す | 新しい関数が要らない | ルールでアプリから消せない（members・写し・招待コード） | 不可 |
| 後始末: 定期実行（採用） | Authの無いuidを6時間ごとに探す | 公開済みの1.13から退会した人や、関数の障害で漏れた人も拾う | 最悪6時間の遅れ | 24時間（4.1）に収まる |
| 後始末: 1st genの`auth.user().onDelete()` | 削除のイベントで消す | 速い | 1st genを混ぜる。配信の失敗や、デプロイ前の削除は拾えない | 不採用（下の決定） |
| キャプションの検査: 作成をCallableへ（採用） | Admin SDKで書く | 正規化と理由の返却ができる（11.6・11.7） | 1.13の投稿が壊れる（Migration） | 方針として採用済み |
| キャプションの検査: 作成トリガーで消す | 保存の後で消す | アプリの変更が少ない | 一瞬見える。理由を返せない | 決定事項10で不採用 |
| 通報: 新しいコレクション＋Callable（採用） | `soratomoReports` | 既存の`reports`を変えない（13.2・13.3） | コレクションが1つ増える | 方針として採用済み |

## Design Decisions

### Decision: 後始末を定期実行にする（1st genの削除トリガーを混ぜない）
- **Context**: 要件4.1。
- **Alternatives Considered**:
  1. 1st genの`auth.user().onDelete()`を`firebase-functions/v1`から読み込んで足す
  2. `onSchedule`で`soratomoUsers`を走査する
- **Selected Approach**: 2。6時間ごとに`listDocuments()`でuidを集め、`getUsers`でAuthの無いuidを見つけて、共通の削除を走らせる。
- **Rationale**: 2nd genにはAuthの削除のイベントが無い。1st genを混ぜると、このリポジトリで初めて1st genの関数が入り、デプロイとテスト（`.run()`で呼ぶ方式）の作りが2通りになる。さらに、削除のイベントは1回きりで、関数が失敗したときや、デプロイより前に1.13から退会した人は拾えない。走査なら、経路と時期に関わらず「Authが無いのにデータがある」状態そのものを拾える。
- **Trade-offs**: 最悪6時間遅れる（24時間に収まる）。全員分の`soratomoUsers`を読む費用がかかる（Performance）。
- **Follow-up**: 1回の実行で消し切れないときに、次の実行が続きから消すことをエミュレーターで確かめる。

### Decision: 退会のCallableを時間の予算で区切る
- **Context**: 投稿数に上限が無く、1回の呼び出しで消し切れるとは限らない（要件3.1〜3.4）。
- **Alternatives Considered**:
  1. 関数の制限時間を長くし（最大3,600秒）、アプリも長く待つ
  2. 1回を45秒の予算に区切り、`{ done }`を返す。アプリは`done`が真になるまで呼び直す
- **Selected Approach**: 2。アプリは最大8回まで呼ぶ。
- **Rationale**: 長い1回の呼び出しは、アプリの制限時間で切れても関数は動き続け、「消し終えたか」をアプリは知れない。区切れば、毎回の結果で完了を確かめられる（3.1）。途中で止まっても、削除が冪等なので続きから消せる（3.3・3.4）。
- **Trade-offs**: 往復が増える。回数の上限に達したら失敗として扱う（3.2）。
- **Follow-up**: 予算と回数の値は、エミュレーターで1,000件の投稿を消す時間を測って見直す。

### Decision: 退会の削除は既存の8手順の前に置く
- **Context**: 要件13.1（8手順の対象と順序を変えない）と3.1。
- **Alternatives Considered**:
  1. 8手順の前
  2. 8手順の後（Authの削除の直前）
- **Selected Approach**: 1。
- **Rationale**: `deleteUserData`は「人から見えなくなるものを先に」消す方針（`FirestoreService.swift:860-866`）。そらともの投稿は、ほかのメンバーのタイムラインで見えている共有の内容で、この方針では先に消す側へ入る。また、新しい手順は関数を呼ぶので、既存の手順より失敗しやすい。前に置けば、失敗しても既存のデータは手つかずのまま残る。利用者の状態も単純で済む。
- **Trade-offs**: そらともを使っていない人（匿名を含む）の退会にも往復が1回増える。サーバーは空振りで成功を返す（3.8）。
- **Follow-up**: 関数が未デプロイだと、全員の退会が止まる。デプロイの順序（Migration）で、関数をアプリより先に出す。

### Decision: 投稿の保存の確かめ方を「同じ投稿IDでの送り直し」にする
- **Context**: 投稿の作成をCallableに移すと、アプリの制限時間で切れた後も関数が動いていることがある。今の`skyExistsOnServer`は「まだ無い」と読み、画像を消した後で関数が投稿を作ると、画像の無い投稿ができる。
- **Alternatives Considered**:
  1. `skyExistsOnServer`を使い続ける
  2. 結果が確定しない失敗の後に、同じ投稿IDで1回だけ送り直す。サーバーは、同じ投稿者の同じIDを成功として返す（冪等）
- **Selected Approach**: 2。送り直しも確定しなければ、画像を残して失敗にする（既存の「画像の無い投稿より取り残しの画像を選ぶ」方針）。
- **Rationale**: 送り直しと元の呼び出しは、同じ投稿の文書をトランザクションで読むので直列になり、どちらが先でも結果は1件になる。
- **Trade-offs**: 元の要求がとても遅れて届き、その間に利用者が投稿を消していた場合は、投稿が戻りうる。制限時間を超えて遅れ、かつ削除が挟まる場合だけで、受け入れる。

### Decision: 投稿詳細に投稿1件の監視を足す（要件1.7）
- **Context**: 詳細は覚えから読むだけで、削除を知らない。
- **Alternatives Considered**:
  1. タイムラインのVMが前のスナップショットと比べ、消えた投稿を覚えから外す。詳細はVMを監視する
  2. 詳細が投稿の文書を1件だけ監視する（`observeSky`）
- **Selected Approach**: 2。
- **Rationale**: タイムラインのリスナーには`limit`がある。新しい投稿が届くと、古い投稿は窓の外へ押し出されて結果から消える。1の方式では、押し出しと削除を区別できず、消えていない投稿を「表示できません」にしてしまう。文書1件の監視なら、削除だけを正確に知れる。費用は、詳細を開いている間の1件の監視だけ。

### Decision: そらとものブロックは書き込みだけのトランザクションで書く
- **Context**: 要件9.9と13.4。
- **Alternatives Considered**:
  1. 既存の`FirestoreService.blockUser`をそのまま呼ぶ
  2. 同じ項目を、書き込みだけのトランザクションで書く口をそらとも側に作る
- **Selected Approach**: 2。
- **Rationale**: 1は圏外で失敗せずに待ち続け、つながったときに後から適用される（Research Log）。9.9の「失敗を出し、隠さない」と食い違う。2は圏外で必ず失敗し、端末内に積まれない。既存の関数とルートの画面は変えないので、13.4を守る。
- **Trade-offs**: ブロックの書き込みの口が2つになる。どちらも同じ項目（`blockedUserIds`）に`arrayUnion`で書くので、データの形は1つのまま。

### Decision: 通報の転送の失敗は記録の状態で追い、定期実行で送り直す
- **Context**: 要件7.4・7.5と、要件8.1の24時間。
- **Alternatives Considered**:
  1. 既存の`notifyFeedbackToDiscord`と同じく、失敗で例外を投げるだけ（再試行なし）
  2. トリガーの再試行（retry）を有効にする
  3. 記録に`forwardStatus`（`pending`か`sent`）を持たせ、失敗は`pending`のまま残す。定期実行が、10分以上たった`pending`を送り直す
- **Selected Approach**: 3。トリガーは失敗で例外を投げない。
- **Rationale**: 開発者はDiscordで通報に気づく。1では、転送に失敗した通報が届かないまま埋もれ、24時間の対応を落とす。2は、送り先の設定の誤りのような直らない失敗でも7日間再試行し、成功した後の記録の更新に失敗すると二重に送る。3は失敗を記録の上で数えられ、管理スクリプトでも一覧にできる（7.5）。`forwardedAt`の「無い」はクエリで探せないので、状態の項目を持つ。
- **Trade-offs**: 送り直しは最悪6時間後。送った後で記録の更新に失敗すると、次の定期実行でもう一度送る（内容はIDだけなので、開発者が通報のIDで見分ける）。

### Decision: 語のリストが読めないときは拒否する（ただし古いリストがあれば使う）
- **Context**: 要件11.1・11.5。
- **Alternatives Considered**:
  1. 読めなければ検査を飛ばして通す
  2. 読めなければ拒否する
  3. 一度読めたリストを持ち、読み直しに失敗したら古いリストで検査する。一度も読めていなければ拒否する
- **Selected Approach**: 3。
- **Rationale**: 1は、リストの置き忘れや読み取りの障害で、検査が黙って止まる。2は、一時的な障害で作成と投稿が止まる。3は検査を止めず、障害の影響も小さい。
- **Trade-offs**: リストを投入する前に関数をデプロイすると、作成と投稿がすべて失敗する。Migrationで「リストの投入→関数のデプロイ」の順にする。

### Decision: 同意と利用停止は`soratomoUsers/{uid}`に置く
- **Context**: 方針6は「別のコレクションの方が素直なら、その判断と理由を書く」。
- **Alternatives Considered**:
  1. `soratomoUsers/{uid}`に`guidelineVersion`・`guidelineAgreedAt`・`suspendedAt`を足す
  2. 利用停止を別のコレクション（例`soratomoSuspensions/{uid}`）に置く
- **Selected Approach**: 1。
- **Rationale**: 作成と参加のトランザクションは、すでに`soratomoUsers/{uid}`を読んでいる。同じ文書なら、読みを増やさずに同意と利用停止を確かめられる。退会では利用者ごとの記録をすべて消す（2.3）ので、文書ごと消せばよい。読み取りはすでに本人だけ（ルール`:665`）で、10.14を満たす。既存のトランザクションが同じ文書の項目を壊さないことは、コードで確かめた（Research Log）。
- **Trade-offs**: 利用者は自分の利用停止の記録を読める。表示の材料に使えるので、隠す理由は無い。

## Risks & Mitigations
- 関数をアプリより後に出すと、1.14の退会と投稿が全員止まる — Migrationで関数を先に出し、デプロイの後にCallableの存在を確かめる。
- ルールで投稿の作成を閉じると、1.13のベータの人の投稿が止まる — design.mdのユーザーの判断が要る点の節に、時期の選択肢を書いた。
- 退会の途中で別の端末から画像を上げると、取り残しの画像が残りうる — 上げた側のアプリが失敗の後に消す（ルールの削除は本人なら通る）。残っても誰の画面にも出ない。管理スクリプトの`find-orphans --deep`で見つけられる。
- 語のリストを部分一致で検査すると、無害な言葉まで止まる — 語の選び方で調整する（要件11の補足）。
- 定期実行が全員分の`soratomoUsers`を読む費用 — 6時間ごと×利用者数の読み取り。1万人で1日4万件程度と見積もり、公開後に実測する。

## References
- [Transaction serializability and isolation](https://firebase.google.com/docs/firestore/transaction-data-contention) — Admin SDKの悲観的ロックと直列化
- [firebase functions.identity 2nd gen](https://firebase.google.com/docs/reference/functions/2nd-gen/node/firebase-functions.identity) — 2nd genのAuthはブロッキング関数だけ
- [Firebase Authentication triggers（1st gen）](https://firebase.google.com/docs/functions/auth-events) — `auth.user().onDelete()`
- [Firestore（Node.js）recursiveDelete](https://googleapis.dev/nodejs/firestore/latest/Firestore.html) — 一括削除と親の文書の扱い
- [CollectionReference.listDocuments](https://googleapis.dev/nodejs/firestore/latest/CollectionReference.html) — missing documentsを含む
- [nodejs-storage src/file.ts](https://github.com/googleapis/nodejs-storage/blob/main/src/file.ts) — `DeleteFileOptions.ignoreNotFound`
- [Manage Users（Admin SDK）](https://firebase.google.com/docs/auth/admin/manage-users) — `getUsers`の100件と`notFound`
- [HTTPSCallable（FirebaseFunctions for Swift）](https://firebase.google.com/docs/reference/swift/firebasefunctions/api/reference/Classes/HTTPSCallable) — 既定の制限時間70秒
- [firebase functions.https.httpsoptions（2nd gen）](https://firebase.google.cn/docs/reference/functions/2nd-gen/node/firebase-functions.https.httpsoptions) — Callableの制限時間の上限3,600秒
