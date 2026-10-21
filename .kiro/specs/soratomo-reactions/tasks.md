# Implementation Plan

## 進め方の約束

- 作業ブランチは `機能-そらともいいね`（要件のコミット `c1a1ea22` と設計のコミット `3928bf31` が載っている・まだpushしていない・上流なし）。mainへ直接コミット・pushしない。コミットは日本語（`機能:`・`修正:`・`ドキュメント:`）にする。コミットの前に `git status` を見て、対象のファイルを名前で `git add` する（`git add .` は使わない）。初回のpushは、サンドボックスの外で `git push -u origin 機能-そらともいいね`（上流を自分のブランチにする）。
- 着手の前に `git fetch -q origin` をして、`git log --oneline origin/main..HEAD` に載っているのが要件・設計・このtasks.mdのコミットだけであることを確かめる。mainが進んでいれば、取り込んでから始める（`functions/`・`firestore.rules`・`Soramoyou/` に入った変更を、テストの基準値に含めるため）。
- Functionsのデプロイは、mainを取り込んだ状態（作業ツリーがcleanで `HEAD == origin/main`）から行う。古いブランチから出すと、既存の関数が古いコードに戻る。
- 「（ユーザーのGOを取ってから実行）」と書いた操作は、利用者のGOを得るまで実行しない。AIが単独で実行しない。GOは1手ずつ取る（まとめて取らない）。確認とGOは、選択肢の形（AskUserQuestion）で聞く。対象は次のとおり。
  - pushとPRの作成・mainへのマージ
  - FirestoreのルールとFunctions（と、ポリシーを直す場合のhosting）のデプロイ
  - 本番のFirestore・Auth・Storageへの読み書き（件数や項目名だけの読み取りと、Cloud Loggingのログの読み取りを含む）
  - 本番の関数への直接の要求（公開呼び出しの許可の確かめ・12.4）
  - TestFlightへのアップロード・App Store Connectの読み書き・審査への提出
  - 利用者に端末の操作を頼むこと（頼む前に「いまさわれる端末」と、その端末に「入っている版とbuild番号」を聞く）
- firebase CLIには必ず `--project soramoyou-ios` を付ける（`.firebaserc` が空のため）。
- secretとトークンの値を、コマンドの引数・出力・ログ・チャットのどこにも出さない。本番の設定やログをRESTで読むときは、項目の名前で絞って読む。招待コード・メールアドレス・パスワードは、このファイル・コミット・チャットに書かない。
- 本番と端末の操作の結果は、そのタスクの `_Requirements:` の行の後に「結果（日時）」の箇条で書く（leave-group specのtasks.mdと同じ形）。空の結果の行は前もって置かない。書くのは内部IDの頭・件数・時刻・ハッシュの頭だけにする。グループ名・表示名・キャプション・招待コード・トークンは書かない。
- 陽性対照: 各テストは、先に赤（期待外れ）になることを1回確かめてから、正しいもので通す。赤の取り方は2通りある。
  - 「今の現物」で赤が取れるもの（C2・C6）は、テストを実装より先に書き、実装の前のコードで赤を記録してから実装する。赤のテストはコミットしない（CLAUDE.mdの「エラーがある状態ではコミットしない」）。赤の証拠は、そのときの `HEAD` と、テストのファイルの shasum の頭を結果に書いて残し、実装の後に緑を確かめてから、テストと実装を一緒にコミットする。
  - 「わざと壊した形」で赤を取るもの（C1・C3〜C5・C7〜C10と、各タスクの `陽性対照:` の行）は、壊した写しで赤を確かめ、正しい実装に戻して緑にする。壊した写しは、shasumで元に戻ったことを確かめる（または、scratchpadの一時的なworktreeで壊し、終わったら消す。共有のstashは使わない）。
  - 取れなかったときは「検証済み」と書かず、取れなかった理由を記録する。
- design.mdのTesting Strategyの陽性対照C1〜C10の置き場は次のとおり。C1は5。C2は4.1（今の現物で赤）と4.2・4.3（緑）。C3は4.3。C4は2.3。C5は2.1。C6は7.3（今の現物で赤）と7.4（緑）。C7は7.2。C8は7.2。C9は3.2。C10は4.3。
- design.mdの「要確認」Q1〜Q7は、確かめるまで「検証済み」と書かない。確かめる場所は次のとおり。Q1は1.1（本番での裏付けは13.1・任意）。Q2は9.2と13.1（シミュレーター）と14.3（実機・VoiceOver）。Q3は1.2。Q4は13.1。Q5は1.3（反映は4.2・4.3）。Q6は1.3（反映は7.2・7.4）。Q7は13.1（サーバーの実行時間）と14.3（実機の体感）。Q1とQ3は、結果によって設計を変える。そのときは実装を止めて利用者に相談し、design.mdを直してから進む（1.1・1.2の分岐のとおり）。
- design.mdの「要件への差し戻し」D1〜D4は、利用者が「書いた解釈のまま」で承認済み（2026-10-18・設計の承認と同時）。読み方は、D1を3.1と4.2の詳細に、D2を3.1に、D3を7.6に、D4を4.2と6に書いた。
- design.mdの「利用者の決定」（2026-10-18）を前提にする。U1はA（What's Newはリアクションの1ページだけ）、U2はA（置き換えキーはグループ単位の `soratomo-reaction-{groupId}`）。手順2bの入り直しとの隙間は、更新の前提条件（`lastUpdateTime`）で閉じる。U3の文言は、design.mdの下書きのまま実装し（8.4）、実装の後に画面の現物を見せて確定する（10）。
- 本数の数え方を混ぜない。いま `functions/soratomo.js` の中は、Callable 8本・トリガー2本・定期実行1本の計11本（ヘッダーの2行目と23行目、`functions/index.js` の580行のコメントに記載）。このspecの後は、Callable 9本（`soratomoSetReaction` を足す）・トリガー3本（`onSoratomoSkyDeleted` を足す）・定期実行1本の計13本。本番の関数の全体は、22本から24本になる見込み（12.3で出す前に数え直す）。
- Functionsのテストは、`functions/` で、lintが `npm run lint`、単体が `npm test`、エミュレーターが `npm run test:emulator`（firestoreとstorageを起こす）。このspecは新しいテストのファイルを作らず、既存の `soratomoCore.test.js`・`soratomoStore.test.js`・`soratomo.test.js`・`soratomoDeletion.test.js`・`scripts/soratomo-admin.emulator.test.js` に足す。新しいファイルを作るなら、`package.json` の `lint`・`test`・`test:emulator` に登録する。エミュレーターのポート（8080など）が別のセッションに使われていたら、ポートを替えた設定ファイルを `--config` で渡す（leave-group 1.1の前例）。Javaは Android Studio 同梱のJDKを `JAVA_HOME` で渡し、Storageエミュレーターの一時置き場は専用の `TMPDIR` にする（別のセッションのエミュレーターと共有しないため）。
- エミュレーターは、競合したトランザクションを `INVALID_ARGUMENT` で返すことがある（SDKは再試行しない）。同時実行のテストは、既存の要確認3のテスト（`soratomoDeletion.test.js`）の扱いに合わせ、想定内の失敗として数える。
- ルールのテストは、リポジトリの直下で `python3 scripts/rules_test_soratomo.py`（通常）と `python3 scripts/rules_test_soratomo.py --mutants`（陽性対照）。rules test APIで評価するだけで、本番のデータに触れない。401が返るときは、`firebase projects:list > /dev/null` を一度実行してから再実行する。
- iOSのビルドとテストは、`uptime` と `pgrep -x xcodebuild` で負荷とほかのビルドを見てから、`nice -n 19`・`-jobs 4`・`-parallel-testing-enabled NO` で1本ずつ行う（重ねて回すとMacごと落ちた先例がある）。テストのシミュレーターは iPhone 17e `C2E3F752` を使う（共用の端末は使わない）。まず関係するテストのクラスだけを `-only-testing` で回し、最後に全体を1回回す（全体は `-test-timeouts-enabled YES` で1本60秒。`StorageServiceTests.testUploadProgress` が時間切れ無しだと75分固まる）。件数はxcresultで数える。テストの後にxcodebuildがgRPCの後始末で止まったら、孫の本物のxcodebuildにINT（効かなければTERM）を送る。TERMで止めるとxcresultは読めないので、ログの `Test Case` の行を名前で数える。
- 新しいSwiftファイルは、プロジェクトの同期グループが自動で拾う。`project.pbxproj` は触らない（版数の値を変える14.1だけは直す）。既存のprotocolにはメソッドを足さない（既存のモックを壊さない）。既存のSwiftファイルを編集した直後は `git diff` を見て、整形のフックが無関係の行を書き換えていないことを確かめる（混ざったら戻して入れ直す）。
- `(P)` を付けたタスクは、前提に書いたタスクが済んでいれば、ほかのタスクと同時に進めてよい（触るファイルと資源が重ならない）。付けていないタスクは、同じファイルを触るか、前のタスクの成果物に依存するか、エミュレーターやビルドを共有する。iOSのタスクは、ファイルが別でも、ビルド・DerivedData・シミュレーターが1つで1本ずつしか回せないので `(P)` を付けない。本番・App Store Connect・端末の段にも付けない。
- Functions側（2〜6）とiOS側（7〜9）は別の境界で、サーバーの契約はdesign.mdのAPI ContractとEvent Contractで固定済みなので、1.1と1.3（実装の前の確かめ）の後は、別のセッションで並行して進めてよい。ただし、1.2（要確認Q3）の結果が契約（外すときの `kind` の送り方）を変えうるので、サーバーの入力の検査（2.2）とiOSのサービス（7.5）は、1.2の後に書く（1.2を待つのはこの2つだけ）。同じブランチを別のセッションで進めるときは、同じ作業ツリーで同時にコミットしない。
- このtasks.mdに `textlint --fix` を掛けない（見出しの番号の後の空白が消える）。

## (a) 実装の前に、設計の前提を確かめる（要確認Q1・Q3・Q5・Q6）

- [x] 1. 実装の前に、設計の前提を現物で確かめる

- [x] 1.1 (P) 投稿の削除トリガーが、バッチの削除と `recursiveDelete` でも1件ずつ発火するかを確かめる（要確認Q1）
  - 前提: なし（1.2とエミュレーターのポートが重ならないよう、別のポートの設定で起こす）
  - 使い捨ての形で確かめる。scratchpadに、`soratomoGroups/{groupId}/skies/{skyId}` の `onDocumentDeleted` だけを持つ関数のフォルダを作り（依存は `functions/node_modules` へのリンクで足りる）、受けたイベントごとに、投稿IDと、消えた文書の中身（`event.data`）の `reactions` の鍵の数を、別のコレクションの文書に書く。リポジトリの `functions/` には置かず、コミットしない
  - `firebase emulators:exec --only functions,firestore`（その使い捨てのフォルダを指す設定を `--config` で渡す）の中で、Admin SDKの台本から次の3つを流し、書き込みが落ち着くまで待ってから発火の数を数える
    - 投稿1件の `delete()`（アプリの削除と、運用の `deleteSoratomoSky` の形）
    - 投稿3件を1つのバッチで `batch.delete`（共通の削除の `deleteSkiesByQuery` の形）
    - 投稿4件と、ほかの子のコレクション（`members`・`notifyState`）を持つグループを `db.recursiveDelete(groupRef)`（グループごと消す形）
  - 期待: 3つとも、消した投稿の数だけ発火し、どのイベントにも消えた文書の `reactions` が載り、鍵の数が台本で入れた数と一致する
  - 陽性対照: 投稿1件の削除で1件発火すること（数える仕組みが効いていること）を先に確かめる。トリガーを公開しない形（exportsから外す）で、同じ台本の数が0になることも確かめる
  - 結果で分岐する: バッチか `recursiveDelete` のどちらかで1件ずつ発火しない、または消えた文書の中身が載らないなら、design.mdの「投稿の削除」と14.5の件数の出し方は成り立たない（印 `reactionNotices` の削除を共通の削除の側へ移すなど、設計の変更が要る）。2以降の実装を止め、結果と案をAskUserQuestionで利用者に相談し、design.mdを直してから進む
  - エミュレーターの挙動は本番の保証ではないので、本番での裏付けは13.1で取る（任意）
  - _Requirements: 8.1, 8.2, 8.3, 14.5_
  - 結果（2026-10-18 10:41）: エミュレーター（firebase-tools 15.0.0・Firestore Emulator v1.20.2・firebase-functions 7.4.0・firebase-admin 14.5.0・`HEAD` `7360ea35`）で、Q1は成り立った。scratchpadの使い捨ての関数フォルダ2つ（トリガーを公開した `fn-on` と、exportsから外した写し `fn-off`。差分はexportsの1行だけ。`index.js` の shasum の頭 `7a8bfe498516`／`2a441473d597`、台本 `probe.js` は `8f5e083080ec`）を、別ポート（firestore 8183・websocket 9163・functions 5103・hub 4423・logging 4523）の設定を `--config` で渡して起こした。トリガーはイベントごとに自動IDの文書を1件書く形にし（`event.id` で潰さないので、重複して発火すれば見える）、場面ごとに「期待数に届いてから3秒増えない」まで待って数えた
    - on: (1) 投稿1件の `delete()` で1件（鍵2。数える仕組みの陽性対照として先に確かめ、通らなければ残りを流さない形にした）。(2) `select().limit(300).get()` から1つのバッチで3件を `batch.delete` して3件（鍵3・4・5）。(3a) 親の文書があるグループ（投稿4件・`members` 2件・`notifyState` 1件）を `recursiveDelete` して4件（鍵6〜9）。(3b) 本番の `delete_group` の形（親の文書を先に消してから `recursiveDelete`）で4件（鍵10・11・12・0。0は空の地図）。どのイベントにも `event.data` が載り、`reactions` の鍵の数と `reactorIds` の長さが台本で入れた数と一致した。`event.id` は12件で12種類（重複なし）。`members`・`notifyState` の削除では発火しない。最初の発火まで約0.3〜1.0秒
    - off（陽性対照の陰性側）: エミュレーターが読み込んだ関数は `q1Unrelated` だけで、投稿の削除トリガーは登録されなかった。同じ台本の4場面とも15秒待って0件。投稿は消えていた（残り0件）ので、0件は「消せなかった」せいではない
    - 分岐: 3つの形とも1件ずつ発火し、消えた文書の中身が載ったので、design.mdの「投稿の削除」と14.5の件数の出し方は変えない。2以降へ進んでよい。ただしエミュレーターの挙動であり、本番の保証ではない（本番の裏付けは13.1・任意）
    - 実行の環境: サンドボックスの中ではローカルのポートを開けない（`listen EPERM`）ため、`emulators:exec` の2回だけサンドボックスの外で流した。firebase CLIは `XDG_CONFIG_HOME` を空の一時フォルダにして、利用者のCLIの設定（ログイン情報）を読まずに起こした。外で起こした関数エミュレーターが「Application Default Credentials detected」と警告したが、プロジェクトは `demo-` で、台本と関数はエミュレーターのFirestoreだけを読み書きした（本番には触れていない）。Javaは Android Studio 同梱のJBRを `JAVA_HOME` と `PATH` で渡した

- [x] 1.2 iOSのFirebaseFunctionsが `NSNull` をJSONの `null` として送るかを確かめる（要確認Q3）
  - 前提: なし（iOSのビルドとシミュレーターを使うので `(P)` を付けない。1.1とは別のポートのエミュレーターで行う）
  - scratchpadに、受けた `data` の `kind` について「鍵があるか」と「値の型（文字列・null・それ以外）」だけを返す使い捨てのCallableを置き、Functionsのエミュレーターで起こす。リポジトリには置かない
  - iOSのテストからエミュレーターへつなぐ口（`97c34a43`・#188でテストの接続先をエミュレーターに切り替えた現物）を読み、同じ形で `Functions.functions(region: "asia-northeast1")` を `useEmulator` でつなぐ使い捨てのテストを書き、`["groupId": …, "skyId": …, "kind": NSNull()]` を送って返りを見る（`C2E3F752`・`-only-testing` で1本だけ）。使い捨てのテストはコミットしない
  - 期待: 「鍵がある・値は null」が返る
  - 陽性対照: 同じテストで、`kind` の鍵を省いた要求が「鍵が無い」、`"sunset"` を送った要求が「文字列」と返り、3通りが見分けられることを確かめる
  - 補助（証拠の代わりにしない）: firebase-ios-sdkの `FunctionsSerializer` が `NSNull` をどう書くかを、パッケージの現物で読んで結果に書く
  - 結果で分岐する: 「鍵がある・値は null」で届かなければ、契約を「`kind` の鍵を省いた形を『外す』とする（`null` も外すとして受ける）」に直す。このタスクの中で、design.mdのAPI Contractと、`setReactionTx` の判定の順（手順1の `invalid_input` の条件）と、`SoratomoReactionService` の送る値の記述を同じく直し、直した差分を利用者に報告してから2.2・7.5へ進む
  - _Requirements: 1.3, 1.4, 1.5, 4.4_
  - 結果（2026-10-18 14:08）: エミュレーター（firebase-tools 15.0.0・firebase-functions 7.4.0・Node 22.20.0・firebase-ios-sdk 12.6.0（`087bb952`）・Xcode 27・iPhone 17e `C2E3F752`・`HEAD` `083da11c`）で、Q3は成り立った。`NSNull()` を入れた `kind` は「鍵がある・値は `null`」で届いた。scratchpadの使い捨てのCallable `q3ProbeKind`（`onCall`・region `asia-northeast1`。`index.js` の shasum の頭 `69b27388f59c`）は、受けた `data` の `kind` の鍵の有無（`hasOwnProperty`）と値の型に加えて、線の上に流れた本文（`rawRequest.body` をJSONに戻したもの）を返す形にした。テストの接続先の作り（`FirebaseEmulatorSwitch` が `Functions.functions(region:)` を `127.0.0.1:5001`・`demo-soramoyou-security` へ向ける）に合わせて、エミュレーターも同じプロジェクトIDとポートで起こした。使い捨てのテスト `Q3NSNullProbeTests.testKindNullArrival`（shasum の頭 `e4ad4497a865`）は、アプリのサービスと同じ `httpsCallable(name).call([String: Any])` の形で3通りを送った
    - 返り（3通りが見分けられた＝陽性対照）: (1) `["groupId": …, "skyId": …, "kind": NSNull()]` → 鍵あり・`null`。本文は `{"data":{"groupId":…,"kind":null,"skyId":…}}`。(2) `kind` の鍵を省く → 鍵なし（`absent`）。本文に `kind` が無い。(3) `"sunset"` → 鍵あり・文字列。本文は `"kind":"sunset"`。関数のログにも同じ3行が残った（その前の1行は、台本が関数の読み込みを確かめるためにcurlで送った `{"data":{"kind":null}}` で、iOSの証拠には数えない）。テストは1本・0失敗（`Executed 1 test, with 0 failures`・`xcodebuild exit=0`）
    - 補助（証拠の代わりにしない）: firebase-ios-sdk 12.6.0 の `FunctionsSerializer.encode`（`FirebaseFunctions/Sources/Internal/FunctionsSerializer.swift:35-36`）は `NSNull` をそのまま返し、`Functions.swift:569-571` が `["data": encoded]` を `JSONSerialization` で書く。現物の返りと合う
    - 分岐: 「鍵がある・値は null」で届いたので、契約（外すときは `kind: null` を送る）と、design.mdのAPI Contract・`setReactionTx` の判定の順（手順1の `invalid_input` は `kind` の鍵が無いとき）・`SoratomoReactionService` の送る値（`kind?.rawValue ?? NSNull()`）は変えない。2.2・7.5へ進んでよい。ただしエミュレーターでの確かめで、配備した関数へ「外す」を送るのは13.1の通しで見る
    - 実行の環境: ビルドは `nice -n 19`・`-jobs 4` の `build-for-testing`（`-only-testing` でこのクラスだけ）、テストは `emulators:exec --only functions` の中で `test-without-building`・`-only-testing` の1本・`-parallel-testing-enabled NO`・`-test-timeouts-enabled YES`。サンドボックスの中ではDerivedData（外付けのSSD）に書けず、ローカルのポートも開けない（`listen EPERM`）ので、ビルドと `emulators:exec` の2回をサンドボックスの外で流した（前に `uptime` の負荷が3〜4台・ほかの `xcodebuild` が無い・5001が空いていることを確かめた）。firebase CLIは `XDG_CONFIG_HOME` を空の一時フォルダにして起こし、JavaはJBRを `JAVA_HOME` と `PATH` で渡した。関数エミュレーターが「Application Default Credentials detected」と警告したが、プロジェクトは `demo-` で、使い捨ての関数は受けた値を返すだけ（ほかのサービスに触れない）。テストの間のアプリのログに出た `-1001`（タイムアウト）は、Callableの3回の要求とは別の通信で（3回とも返りが届いている）、行き先は確かめていない。終わった後、5001などのポートと `xcodebuild` が残っていないことを確かめた。使い捨てのテストは消し、`git status` が空に戻ったことを確かめた（写しはscratchpad）

- [x] 1.3 (P) 既存のテストのうち、形が変わって直す必要がある箇所を数える（要確認Q5・Q6）
  - 前提: なし（検索だけ）
  - Q5: `functions/soratomoDeletion.test.js`・`functions/soratomo.test.js`・`scripts/soratomo-admin.test.js`・`scripts/soratomo-admin.emulator.test.js` で、削除の戻り値（`deleteUserDataInGroup`・`leaveSoratomoGroup`・`deleteSoratomoUserData` の結果）と、削除のログの項目（`soratomoDeleteMyData: ok`・`soratomoLeaveGroup: ok`・`soratomoLeave: swept`・`soratomoDeletion: summary`）を `deepStrictEqual` で丸ごと比べている箇所を `grep -n` で数え、ファイルと行を結果に書く。4.2・4.3で `reactionsDeleted: 0` を足す範囲は、この一覧にする
  - Q6: `Soramoyou/Soramoyou` と `Soramoyou/SoramoyouTests` で、`SoratomoSkyPresence` の `.present` と `SoratomoEvent.notificationOpened` をパターンや値で比べている箇所を数え、ファイルと行を結果に書く（詳細の `case .success(.present)`・`SoratomoServiceMocks.swift` のモック・`SoratomoRouterTests`・`SoratomoAnalyticsTests` など）。7.2・7.4で直す範囲は、この一覧にする
  - 陽性対照: 検索が、すでに分かっている1か所（`SoratomoSkyDetailView.swift` の `case .success(.present)`）を拾うことを先に確かめる。拾わなければ検索の書き方を直す
  - _Requirements: 2.5, 12.12, 12.15, 15.5_
  - 結果（2026-10-18 10:49）: `HEAD` `cef5d099` の現物で数えた。数え方の読み替えが1つある。4つのテストは `node:assert/strict` の `assert.deepEqual`（中身は `deepStrictEqual` と同じ厳密な比較）を使っていて、`deepStrictEqual` の字面は0件だった。そこで、`assert.deepEqual(`・`assert.deepStrictEqual(` の呼び出しを括弧の対応で丸ごと抜き出し、削除の戻り値とログの項目名（`skiesDeleted`・`imagesDeleted`・`groupsLeft`・`ownersTransferred`・`groupsDeleted`）か、4つのログの名前を含むものを拾った（scratchpadの使い捨ての台本。389件のうち43件）。期待値を変数に入れた形（`ZERO_TOTALS`・`NOTHING`・`zero`・admin の `DONE`）は、項目名が呼び出しの外に出る行を別に拾って追った
    - 陽性対照: Q5の台本が、素の `grep` で先に見つけた `soratomoDeletion.test.js:477`（`deleteUserDataInGroup` の結果の丸ごとの比較）を拾うことを確かめた。Q6は、`grep` が `SoratomoSkyDetailView.swift:145` の `case .success(.present), .failure:` を拾うことを先に確かめた
    - Q5・壊れる（`reactionsDeleted: 0` を足す範囲）は2ファイルで38か所。`functions/soratomoDeletion.test.js` の32か所: `deleteUserDataInGroup` の結果8か所（477・502・532・556・579・606・647・686）／`deleteSoratomoUserData` の合計5か所（857・973と、`ZERO_TOTALS` を使う876・888・1258）／`suspendSoratomoUser` の合計3か所（1033と、`ZERO_TOTALS` を使う1047・1054。利用停止は `deleteSoratomoUserData` の合計をそのまま返す）／`leaveSoratomoGroup` の結果16か所（1601・1732・1777・1818・1830・1978・1982・2016・2127・2200と、`NOTHING` を使う1758・1803・1844・1941・1950・2155）。共有の定数 `ZERO_TOTALS`（824行）と `NOTHING`（1684行）に足せば11か所がまとめて直る。`functions/soratomo.test.js` の6か所: `soratomoDeleteMyData: ok` が687・698、`soratomoLeaveGroup: ok` が801（2人分の行）、`soratomoDeletion: summary` が1172（`zero`（1171行）に足す）、`soratomoLeave: swept` が1282・1314
    - Q5・壊れない（直さない）: `soratomo.test.js` の応答の比較9か所（370・676・697・776・783・795・796・1418・1420。応答は `{ done }` と `{ done, groupDeleted }` のままなので変わらない）。`soratomoDeletion.test.js` の `deleteSoratomoSky` の3か所（1092・1098・1111。この戻り値には足さない）。1件ずつ比べる `assert.equal`（676・713・918など）。`scripts/soratomo-admin.test.js` は0か所（削除は決まった値を返す偽物で、`formatTotals` は項目を名前で取り出す。473行は整形した文字列の比較）。`scripts/soratomo-admin.emulator.test.js` は0か所（削除の件数を比べていない）。`soratomo.test.js:822` の公開する関数の名前の一覧はQ5の対象外（3.1・3.2で直す）
    - Q6・`SoratomoSkyPresence.present`: 直す範囲は5か所。アプリのパターン1か所（`SoratomoSkyDetailView.swift:145` の `case .success(.present), .failure:`）、アプリの値1か所（`SoratomoSkyService.swift:587` の `return .success(.present)`。7.2でリアクションを渡す形に変える本体）、テストの値3か所（`SoratomoServiceContractsTests.swift:169`・`:173`、`SoratomoSkyServiceTests.swift:339`）。`SoratomoServiceMocks.swift` に `.present` の字面は0件で、型の名前を書いた3か所（133・156・198）は型の名前が変わらないので直さない。拾ったうち `LivingSkyPreviewView.swift:472`（Metalの `commandBuffer.present`）と、説明のコメント2か所（`SoratomoSkyDetailView.swift:134`・`SoratomoSkyService.swift:562`）は対象外。参考: 7.2で引数を足す `resolveObservedSky` の呼び出しは、アプリ1か所（`SoratomoSkyService.swift:234`）とテスト7か所（`SoratomoSkyServiceTests.swift` の338・344・351・357・365・369・376）
    - Q6・`SoratomoEvent.notificationOpened`: パターンはアプリの2か所だけで、テストには0か所。`SoratomoAnalytics.swift:353` の `case let .notificationOpened(result):` は、値を1つだけ束ねているので直す（7.4で `type` を足すと関連値が2つになる）。`SoratomoAnalytics.swift:314` の `case .notificationOpened:`（値を束ねない）は直さなくてよい見込み。値を作る側はアプリの5か所（`SoratomoRouter.swift` の256・284・304・336・342。7.4で種類を渡す）。テストの値の比較は30か所（`SoratomoAnalyticsTests.swift:42` と、`SoratomoRouterTests.swift` の29か所: 187・200・211・228・247・320・357・363・367・374・378・391・407・432・445・471・484・509・514・539・545・554・558・634・637・657・764・778・790）で、どれも `soratomoPost` の場面。`type` の既定を `.postCreated` にする設計なら字面を変えずに `post_created` の意味のまま通る見込み（7.3の「既存の `soratomoPost` のテストは変えない」と合う）。どちらの「見込み」も、7.2・7.4のビルドで確かめるまで検証済みとしない

## (b) Functions: リアクションの規則（純関数とトランザクション）

- [x] 2. リアクションの規則をサーバーに作る

- [x] 2.1 (P) 7種類の絵文字・通知文・間引きの判定を、純関数で作る（陽性対照C5）
  - 前提: 1.1, 1.3（1.1の結果で設計が変わらなかったこと。変わったら、直したdesign.mdに従う。1.2（Q3）は純関数に効かないので待たない）
  - `functions/soratomoCore.js` に、design.mdの「soratomoCoreのリアクションの規則」のとおり、`REACTION_KINDS`（7行・並び・名前・FE0Fを含む絵文字）・`isReactionKind`・`buildReactionNotification`・`decideReactionNotify` を足し、`module.exports` に載せる。間引きの間隔は既存の `THROTTLE_MS`、名前の代わりは既存の `FALLBACK_NAME` を使う。既存の `decideThrottle`・`buildNotification` は変えない
  - `soratomoCore.test.js`（`npm test`）:
    - `REACTION_KINDS` の7行（並び・名前・絵文字のコードポイント）を固定する（7.1の `SoratomoReactionKindTests` と同じ値）
    - `isReactionKind`: 7つの名前だけが真。絵文字・FE0Fの無い形・大文字・前後の空白・`null`・数・物は偽
    - `buildReactionNotification`: 題はグループ名、本文は「{名前}さんがあなたの空に{絵文字}を付けました」、名前が空・空白だけ・文字列でないときは「だれか」。キャプションを入れない（引数にも取らない）
    - `decideReactionNotify`: 印に付けた人がいれば `duplicate`。最後に送ってから5分以内（5分ちょうどを含む）なら `throttled`。記録が無い・時刻が読めない・5分を過ぎたなら `send`。投稿IDに左右されない
  - 陽性対照（C5）: 場面は「Aが投稿Pに付けて送った10分後に、Bが同じPに付ける」。期待は `send`。`decideReactionNotify` の中身を既存の `decideThrottle`（`lastSkyId` を渡す形）に置き換えた写しで、`duplicate` になってこのテストが赤になることを先に確かめる。絵文字そのもの（☁️）を受ける `isReactionKind`、キャプションを本文に足す `buildReactionNotification` の写しでも、それぞれのテストが赤になることを確かめる
  - _Requirements: 4.4, 4.5, 4.6, 6.5, 6.8, 6.9, 6.10, 6.11_
  - 結果（2026-10-18 14:31）: 着手の前に `origin/main` が1件進んでいた（#191 `ca372cdb`・`functions/package.json` の lint・test・test:emulator に `follows-cleanup` を登録）ので、マージで取り込んだ（`f3c3fc03`。それまでのコミットの番号を変えないため、rebaseしない）。取り込んだ後の基準値は、lintが緑、`npm test` が399本（サンドボックスの中では `skyMotionCore.test.js` の `fetchWithTimeout` の1本がローカルのポートを開けず `listen EPERM` で落ちる。外では緑）
    - 作ったもの: `functions/soratomoCore.js` の末尾に `// MARK: - リアクション` の節を足し、`REACTION_KINDS`（凍結した7行）・`isReactionKind`・`buildReactionNotification`・`decideReactionNotify` を `module.exports` に載せた。`THROTTLE_MS`・`FALLBACK_NAME`・`toMillisOrNull` を使い、`decideThrottle`・`buildNotification` は変えていない。設計の型に無い振る舞いを2つ決めた。（1）`buildReactionNotification` は、`kind` が7つの名前でないとき `TypeError` を投げる（絵文字の欠けた通知を作らない。呼び出し側の `setReactionTx` が名前を検査済みなので、ふつうは起きない。3.1の `notifyReaction` は例外を `failed` にする）。（2）「だれか」の条件は、tasks 2.1のとおり空・空白だけ（`trim()` で空）・文字列でない（新着投稿の `buildNotification` は空白だけを「だれか」にしない）
    - 絵文字の書き方: 実装に4桁の `\uXXXX` で書いた下書きが、道具の入力の段階で生の文字（☁️・❤️・✨）に変わった（波かっこの `\u{1F305}` は残った）。見えない U+FE0F を見落とさないよう、7行とも波かっこの形 `\u{2601}\u{FE0F}` などに直し、ASCIIだけで書かれていることを確かめた。テストは絵文字をコードポイントの数値（`[0x2601, 0xfe0f]` など）とUTF-16の単位数で固定した（文字列で書くと、FE0Fが実装とテストの両方から落ちても緑のままになるため）
    - テスト: `soratomoCore.test.js` の末尾に18本を足した（`REACTION_KINDS` 2・`isReactionKind` 4・`buildReactionNotification` 5・`decideReactionNotify` 7）。テストだけを足した状態で18本中17本が赤（関数が無い）。残る1本（`kind` が名前でないと `TypeError`）は、関数が無いことによる `TypeError` で偶然通っていたので、下のm4で陽性対照を別に取った。実装の後、`node --test soratomoCore.test.js` が102本・0失敗、lintが緑、`npm test`（サンドボックスの外・Node 22.20.0）が417本・0失敗（399＋18）
    - 陽性対照（C5ほか）: 本物のファイルには触らず、scratchpadに「壊した写しの `soratomoCore.js`」と「テストの写し」を並べて流した（本物の shasum の頭は、流す前と後で `soratomoCore.js` が `6a626f68719e`、`soratomoCore.test.js` が `7dbc99e9fb9e` のまま）。m1（C5・`decideReactionNotify` の中身を `decideThrottle(state, skyId, nowMs)` に置き換え・写しの頭 `63fc8dbde5ba`）で、C5のテストが `actual: 'duplicate'`／`expected: 'send'` で赤（ほかに `decideReactionNotify` の5本も赤・計6本）。m2（☁️などの絵文字そのものも受ける `isReactionKind`・`beab402c9fee`）で「絵文字そのものと FE0F の無い形は偽」の1本だけが赤。m3（キャプションを本文の末尾に足す `buildReactionNotification`・`a94180671d4c`）で「キャプションを本文に入れない」の1本だけが赤。m4（知らない `kind` で投げずに空の本文を返す・`4542fe6e6339`）で `TypeError` の1本だけが赤。m5（くもの絵文字から U+FE0F を落とす・`1b59918d5a57`）で、7行の表・7種類の本文・「だれか」の3本が赤（数値で固定した効き目の確かめ）。どの写しも、赤は狙ったテストに限られた

- [x] 2.2 本人のリアクションを付ける・外す・選び直すトランザクション `setReactionTx` を作る
  - 前提: 1.2, 2.1
  - `functions/soratomoStore.js` に、design.mdの「setReactionTx」のとおりに作る。判定の順は、`invalid_input`（前）→`invalid_reaction`（前）→トランザクションで `soratomoUsers/{uid}`・`members/{uid}`・投稿の文書を `getAll` で読む→`suspended`（既存の `assertNotSuspended`）→`not_member`→`sky_not_found`→`self_reaction`（外す要求も拒否）。外すときの `kind` の送り方は、1.2の結果の契約に従う
  - 書き方: `FieldPath` で本人のキーだけを指す。付ける・選び直すは `reactions.{uid}` に `{ kind, at: serverTimestamp }` と `reactorIds` の `arrayUnion`、外すは `FieldValue.delete()` と `arrayRemove`。同じ `kind` か、付いていないものを外す要求は、書かずに `unchanged`。今の値が壊れている（物でない・知らない名前）ときは「付いている」とみなす。投稿のほかの項目とグループの文書には書かない。同意とブロックの一覧は読まない
  - `SoratomoDomainError` の理由の型（JSDoc）に `self_reaction`・`invalid_reaction` を足す
  - `soratomoStore.test.js`（エミュレーター）:
    - 付ける→`added`・選び直す→`replaced`・外す→`removed`・同じもの→`unchanged`。どの場合も `reactions` の鍵の集合と `reactorIds` が等しい（I1）。投稿の `authorId`・`createdAt`・`caption`・`width`・`height` と、グループの文書（`lastActivityAt` を含む）が変わらない
    - ほかの人のリアクションは残る。uidに `.` を含む人のキーでも、ほかの人のキーに触れない
    - 拒否: `invalid_input`・`invalid_reaction`（絵文字・FE0Fの無い形・知らない名前）・`suspended`・`not_member`・`sky_not_found`・`self_reaction`。どれも文書を書かない
    - ガイドラインに未同意の人も付けられる。投稿者にブロックされた人も付けられる
    - 同時実行（既存の要確認3の型）: 同じ人が違う絵文字で20回並べても1件。19人が同時に付けても19件で、絵文字ごとの数が実際に付けた人の数と一致する
  - 陽性対照: 本人のキーでなく `reactions` の地図を丸ごと書き直す写しで、「ほかの人のリアクションは残る」が赤になることを先に確かめる。`assertNotSuspended` を外した写しで `suspended` のテストが、`self_reaction` の判定を外した写しで自分の投稿のテストが、`arrayUnion` を書かない写しでI1のテストが、それぞれ赤になることも確かめる
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.6, 4.7, 4.8, 4.9, 4.10, 4.11, 4.14, 5.5, 12.1, 12.7_
  - 結果（2026-10-18 14:43）: `HEAD` `c087299`（2.1の後）の上で作った。`functions/soratomoStore.js` に `setReactionTx` と、今の値を読む部品 `readOwnReaction` を足し、`firebase-admin/firestore` から `FieldPath` を読み込み、`SoratomoDomainError` の理由の型に `self_reaction`・`invalid_reaction` を足した。判定の順と書き方はdesign.mdのとおり（1.2の結果どおり、`kind` の鍵が無いときを `invalid_input` にする契約のまま）。書くのは `tx.update` の2組（`new FieldPath("reactions", uid)` と `reactorIds`）だけで、投稿のほかの項目とグループの文書には書かない。投稿の `authorId` が文書IDとして使えない形なら、`reportSkyTx` と同じく想定外の失敗（internal）にした
    - テスト: `soratomoStore.test.js` の末尾に10本を足した（付ける・選び直す・同じもの・外す・無いものを外すの一続き／ほかの人のリアクションは残る／uidに `.` を含む人／壊れた今の値7通り／`invalid_input` 13通りと `invalid_reaction` 12通り／拒否4種を付ける・外すの両方で／判定の順／未同意・古い版・ブロックされた人／同じ人の20回／19人）。I1は `assertReactionInvariant`（鍵の集合と `reactorIds` の比較）で各場面に入れた。「書かない」は投稿とグループの文書の `updateTime` が変わらないことで見た
    - 流し方: エミュレーター（`emulators:exec --only firestore`・`--project demo-soramoyou-security`・firestore 8080）の1回の中で、scratchpadの台本 `run-2.2.sh` から「実装の前の写し（`HEAD` の `soratomoStore.js`）→本物→壊した写し5通り→本物」の順に `soratomoStore.test.js` を流した。サンドボックスの中ではポートを開けない（`listen EPERM`）ので、この1回だけサンドボックスの外で流した（firebase CLIは空の `XDG_CONFIG_HOME`、JavaはJBRを `JAVA_HOME` と `PATH` で渡した）。本物のファイルには触らず、写しはscratchpadに置いた（本物の shasum の頭は、写しを作る前と流した後で `soratomoStore.js` が `ccc0341d8c35`、`soratomoStore.test.js` が `a1fef0b1ebed` のまま）
    - 結果: 実装の前の写し（頭 `269e275417e9`）は73本中10本が赤で、赤は新しい10本だけ（既存の63本は緑）。本物は2回とも73本・0失敗。同時実行は、同じ人の20回が成功20・競合0（`added` 1・`replaced` 16・`unchanged` 3）、19人が1回目で19人とも成功（競合による送り直し0）。送り直しの道は今回の流れでは通っていない
    - 陽性対照: mA（付ける・選び直すで `reactions` の地図を丸ごと書き直す・`e3833be20af6`）で「ほかの人のリアクションは残る」が赤（ほかに一続き・`.`・未同意とブロック・同時実行2本の計6本）。mB（`assertNotSuspended` を外す・`a361f7381bd2`）で拒否4種のテストと判定の順の2本が赤。mC（`self_reaction` の判定を外す・`88aa82fbc8d4`）で拒否4種のテストの1本だけが赤。mD（`arrayUnion` を書かない・`1f5478dd3e11`）でI1を見る6本が赤。追加のmE（本人のキーを `FieldPath` でなく文字列 `reactions.${uid}` で指す・`a93cf633e09a`）で「uidに `.` を含む人」の1本だけが赤
    - 全体のエミュレーターのテスト（`npm run test:emulator`）は、同じ `soratomoStore.js` を触る2.3の後にまとめて1回流す（2.3の結果に書く）

- [x] 2.3 通知の間引きと「同じ人の同じ投稿で1通まで」を、1つのトランザクションで決める `claimReactionNotifySlot` を作る（陽性対照C4）
  - 前提: 2.2（同じ `soratomoStore.js` を触る）
  - design.mdの「claimReactionNotifySlot」のとおり。1つのトランザクションで、投稿の文書・`reactionNotices/{skyId}`・`reactionNotifyState/{authorId}` を読み、投稿が無ければ何も書かずに `sky_gone`。`send` のときだけ、`reactionNotifyState/{authorId}.lastSentAt` と `reactionNotices/{skyId}.notifiedReactorIds`（`arrayUnion`・無ければ作る）を書く。間引かれたときは印を書かない。新着投稿の `notifyState/{uid}` には触れない
  - `soratomoStore.test.js`: `send` の直後の別の人は `throttled`。同じ付けた人は、5分を過ぎても `duplicate`。別の投稿者は別に数える。投稿が無ければ `sky_gone` で何も書かない。間引かれた付け方は印を残さない
  - 陽性対照（C4）: 場面は「投稿者へリアクションの通知を送った直後に、同じグループで新しい投稿がある」。期待は、既存の `claimNotifySlot`（新着投稿）が `send` を返すこと。リアクションの記録を `notifyState/{uid}`（新着投稿と同じ文書）に書く写しで、新着投稿の側が `throttled` になってこのテストが赤になることを先に確かめる
  - _Requirements: 6.5, 6.6, 6.8_
  - 結果（2026-10-18 15:03）: `HEAD` `97d5b4e3`（2.2の後）の上で作った。`functions/soratomoStore.js` に `claimReactionNotifySlot` と、コレクションの名前の定数 `REACTION_NOTIFY_STATE`（`reactionNotifyState`）・`REACTION_NOTICES`（`reactionNotices`）を足した。判定は2.1の `decideReactionNotify` に任せ、`send` のときだけ `reactionNotifyState/{authorId}` を `{ lastSentAt }` で書き（`claimNotifySlot` と同じく上書き）、`reactionNotices/{skyId}` に `notifiedReactorIds` の `arrayUnion` を `merge` で書く。引数の形の誤りは `claimNotifySlot` と同じく `TypeError`
    - テスト: `soratomoStore.test.js` の末尾に7本を足した（初回の書き込み／別の人の間引き（5分ちょうどを含む）と間引かれた人の印の無さ／同じ人の重複（24時間後も）と別の投稿／別の投稿者・別のグループ／`sky_gone`（記録が残っていても）／同時実行（2人で1通・同じ人の2回で1通）／C4）
    - C4のテストの作り直し: 最初の形は「リアクションの後に新着投稿の `notifyState` が無いこと」を新着投稿の判定より先にassertしていて、C4の写しはそのassertで赤になり、「新着投稿の側が `throttled` になる」まで届いていなかった（陽性対照として取れていない）。新着投稿の判定を最初にassertする順に直して、写しと本物を流し直した。下の数はすべて流し直した後のもの（最初の回のログはscratchpadの `pc-2.3/first-run`）
    - 流し方: 2.2と同じく、エミュレーター（`emulators:exec --only firestore`・`demo-soramoyou-security`・8080）の1回の中で、台本 `run-2.3.sh` から「実装の前の写し（`HEAD` の `soratomoStore.js`・頭 `ccc0341d8c35`）→本物→壊した写し4通り→本物」を流した（サンドボックスの外・空の `XDG_CONFIG_HOME`・JBR）。本物の shasum の頭は `soratomoStore.js` が `f9af65440f23`、`soratomoStore.test.js` が `01065a86d9d7`（写しへ配ったテストも6つとも同じ頭）
    - 結果: 実装の前の写しは80本中7本が赤で、赤は新しい7本だけ。本物は2回とも80本・0失敗。同時実行は2回とも、2人が `send` 1・`throttled` 1、同じ人の2回が `send` 1・`duplicate` 1（競合0）
    - 陽性対照（C4）: 写し mC4（`REACTION_NOTIFY_STATE` を `notifyState` にした＝リアクションの記録を新着投稿と同じ文書に書く・頭 `aca288430692`）で、C4のテストが新着投稿の `claimNotifySlot` の `actual: 'throttled'`／`expected: 'send'` で赤（ほかに `reactionNotifyState` を読む5本も赤・計6本）。追加の写し: mX（間引き・重複のときも印を書く・`36c4d7d552bc`）で、2回目の間引きが `duplicate` になり「間引かれた付け方は印を残さない」が赤（ほかに同時実行の1本）。mY（投稿の有無を見ない・`74781152df92`）で `sky_gone` の1本だけが `actual: 'send'` で赤。mZ（`send` で印を書かない・`a42a497dd90d`）で、同じ人の2回目が `send` になり重複のテストが赤（ほかに印を読む4本・計5本）
    - 全体（2.2と2.3をまとめて）: lintが緑。`npm test` が417本・0失敗、`npm run test:emulator`（firestore と storage・Storageの一時置き場は専用の `TMPDIR`）が325本・0失敗（どちらもサンドボックスの外・Node 22.20.0）。終わった後、エミュレーターのプロセスが残っていないことを `ps` で確かめた

## (c) Functions: Callableと削除トリガーの配線

- [x] 3. リアクションのCallableと、投稿の削除トリガーを配線する

- [x] 3.1 リアクションのCallable `soratomoSetReaction` と、投稿者への通知 `notifyReaction` を作る
  - 前提: 2.3
  - `functions/soratomo.js` の `soratomoLeaveGroup` の直後（いまの333行の後。行番号は書く前に現物で確かめる）に、`soratomoCallable` で作る。選択肢は `respond`（`{ outcome, kind }` だけ。`authorId` は返さない）と `okLogFields`（`uid`・`groupId`・`skyId`・`outcome`・`kind`・`notify`）だけ。関門はほかのCallableと同じ（登録済みのログイン・匿名は拒否）
  - 本体: `setReactionTx` → `outcome === "added"` のときだけ `notifyReaction` を `await` → 応答。`replaced`・`removed`・`unchanged` では送らない
  - `notifyReaction`: design.mdの「通知を送るかの判定」とEvent Contractのとおり。グループ・投稿者のメンバーの文書・投稿者と付けた人の `users` を `getAll` で読み、`group_missing`・`author_left` → `classifyRecipient({ userData: 投稿者, posterId: 付けた人 })` → `claimReactionNotifySlot` → `sendToTokenGrouped`。`data` は `{ type: "soratomoReaction", groupId, postId }`、スレッドIDは `soratomo-{groupId}`、置き換えキーは `soratomo-reaction-{groupId}`。例外を投げず、失敗は結果の文字列 `failed` にして、`warn` のログに `errorName` と `errorCode` だけを出す
  - `REASON_TO_CODE` に `self_reaction: "failed-precondition"`・`invalid_reaction: "invalid-argument"` を足す。`module.exports` に足し（12本目）、公開する関数の数を確かめる既存のテストを12本に直す（3.2で13本にする。ヘッダーと本数のコメントも3.2でまとめて直す）
  - D1の読み方（承認済み）: 6.8の「多くても1通」は、同じメンバーである間の約束。本人が抜ける・退会すると印から外れる（4.2・4.3）ので、入り直して同じ投稿に付け直すと、もう1通が出うる
  - D2の読み方（承認済み）: ログの `notify` は、送らなかったとき `null`。送ろうとしたとき `sent`・`throttled`・`duplicate`・`no_token`・`failed`・`invalid_token`・`pref_off`・`blocked` に加えて、`author_left`・`group_missing`・`sky_gone`
  - `soratomo.test.js`（`.run()` で呼ぶ）:
    - 関門: 未ログインは `unauthenticated`、匿名は `registration_required`。`CALLABLES`（public-launch 3.1の後で7本の見込み・現物で数える）に `soratomoSetReaction` を足し、関門のテストが新しいCallableにも効くことを見る
    - 応答のキーは `outcome` と `kind` だけ。各理由が決めた `code` と `details.reason` になる（`not_member`・`sky_not_found`・`self_reaction`・`invalid_reaction`・`suspended`）
    - 通知: `added` で投稿者へ1通だけ（付けた人とほかのメンバーへは送らない）。`data`・スレッドID・置き換えキー・題・本文の形を見る。本文にキャプションが無い。表示名が空なら「だれか」
    - 送らない場合: `replaced`・`removed`・`unchanged`／そらとも通知がOFF（未保存はONとして送る）／投稿者が付けた人をブロック／トークン無し／5分以内の別の人／外して付け直した同じ人
    - 既存の3つの設定を見ない: `notifyReactions` がOFFでもそらとも通知がONなら送り、`notifyReactions` がONでもそらとも通知がOFFなら送らない。`users` のどの設定も書き換えない。宛先の `users` に版の情報があっても無くても、送るかは変わらない
    - 送信の失敗（偽の送信が投げる）でも、リアクションは残り、応答は成功
    - リアクションの通知の直後でも、`onSoratomoSkyCreated` の新着投稿の通知は送られる。リアクションで、新着投稿の通知とほかの既存の通知の送信が呼ばれない
    - ログ: `notify` の値が場面と合う。グループ名・表示名・キャプション・招待コード・トークンが出ていない
  - 陽性対照: `replaced` でも送る写しで「選び直しで送らない」が、`type` を `soratomoPost` にした写しで `data` のテストが、置き換えキーを `soratomo-{groupId}` にした写しで置き換えキーのテストが、送信の失敗で投げる写しで「リアクションは残り、応答は成功」が、成功のログにグループ名を足した写しでログのテストが、それぞれ赤になることを先に確かめる
  - _Requirements: 4.12, 4.15, 4.16, 5.4, 6.1, 6.2, 6.3, 6.4, 6.7, 6.12, 6.13, 6.14, 6.15, 6.16, 6.17, 6.18, 11.3, 11.4, 11.5, 12.4, 12.5, 12.6, 14.2, 14.3, 14.4_
  - 結果（2026-10-19 11:37）: `HEAD` `541cd2b3`（2.3と時刻の訂正の後）の上で作った。着手の前に `git fetch -q origin` をして、`origin/main` が進んでいないことを確かめた（取り込みなし）
    - 作ったもの: `functions/soratomo.js` の `soratomoLeaveGroup` の直後（333行の後）に `// MARK: - リアクション（soratomo-reactions 3.1）` の節を足し、`notifyReaction` と `soratomoSetReaction`（`soratomoCallable`・選択肢は `respond` と `okLogFields` だけ）を置いた。`REASON_TO_CODE` に `self_reaction: "failed-precondition"`・`invalid_reaction: "invalid-argument"` を、`module.exports` に `soratomoSetReaction` を足した（12本目）。ヘッダーの本数と説明・`functions/index.js` のコメントは3.2でまとめて直す
    - 設計の型に無い振る舞いを3つ決めた。（1）`notifyReaction` は通知文（`buildReactionNotification`）を枠の確保（`claimReactionNotifySlot`）より前に作る（組み立てが投げたとき、間引きの記録と送った印を使ったまま何も送らない形にしないため）。（2）`added` 以外の `notify` は明示的に `null` にする（`undefined` だとログの項目ごと消え、D2の「送らなかったとき `null`」と違う）。（3）`notifyReaction` の失敗のログは `soratomoSetReaction: notify_failed`（warn）で、項目は `uid`（付けた人）・`groupId`・`skyId`・`errorName`・`errorCode`（新着投稿の「宛先1人の処理に失敗」と同じ形）。`classifyRecipient` の `posterId` には付けた人を渡す（投稿者が付けた人をブロックしていれば送らない）
    - テスト: `soratomo.test.js` の末尾に11本を足し、`CALLABLES` に `soratomoSetReaction` を足して8本にし（関門の4本の名前の「7本」を「8本」に）、公開する関数の一覧のテストを12本に直した（そのテストの名前と、選択肢の名前の検査のコメントの「11本」も12本に）。偽の送信の口に、既存のほかの通知の送信（`sendToToken`・`sendToUid`）を記録だけする形を足した（リアクションで呼ばれないことを見るため）。期待する絵文字はコードポイントの数値（`String.fromCodePoint`）から作った
    - 足した11本: 応答とログの形（5つの outcome）／拒否（12通り・理由ごとの code と `details.reason`）／通知の形（宛先・題・本文・`data`・スレッド・置き換えキー・キャプションなし・要求に書いた uid を使わない・ログに名前などを出さない）／「だれか」（4通り・FE0Fまで載る）／選び直す・同じもの・外すでは5分を過ぎても送らない／間引きと重複（5分以内の別の人・外して付け直した同じ人・5分を過ぎた後）／宛先の判定（`pref_off`・`blocked`・`no_token` 2通り・`author_left`・`group_missing`）／既存の3つの設定と版の情報を見ない・users を書き換えない（5通り）／失敗（送信が投げる・`failed`・`invalid_token`・組み立てが投げる・枠の確保が投げる）／書いた直後に投稿が消えたら `sky_gone`（`store.setReactionTx` を包んで書いた直後に投稿を消す形。既存の `core.buildNotification` の差し替えと同じ手）／新着投稿の通知との独立（両方の向き）
    - 流し方: 2.2・2.3と同じく、エミュレーター（`emulators:exec --only firestore`・`demo-soramoyou-security`・8080）の1回の中で、scratchpadの台本 `run-3.1.sh` から「実装の前の写し（`HEAD` の `soratomo.js`・頭 `fcacaf61620f`）→本物→壊した写し7通り→本物」を流した（サンドボックスの外・空の `XDG_CONFIG_HOME`・JBR）。写しの置き場には `soratomo.js`（写し）と `soratomoCore.js`・`soratomoStore.js`・`soratomoDeletion.js`・`soratomoNgWords.js`・`soratomo.test.js` を写した（`pushHelpers` と `soratomoStorage` はテストの偽物が横取りするので写さない）。本物の shasum の頭は、写しを作る前と流した後で `soratomo.js` が `68cf65f29b20`、`soratomo.test.js` が `7dd3d6d5d9fc` のまま（写しへ配ったテストも8つとも同じ頭）
    - 結果: 実装の前の写しは69本中15本が赤で、赤は新しい11本と、`soratomoSetReaction` を足した関門の3本（未ログイン・匿名・方式の読めないトークン）と、公開する関数の一覧の1本だけ（関門の「クレームの無い登録済みは止められない」は失敗を受け止める形なので、関数が無くても緑のまま）。本物は2回とも69本・0失敗。終わった後、エミュレーターのプロセスが残っていないことを `ps` で確かめた
    - 陽性対照: m1（`replaced` でも送る・`233889412cca`）で「5分を過ぎていても送らない」が送信1通で赤、応答とログの形の1本が選び直しの `notify` の `duplicate`（期待は `null`）で赤（計2本）。m2（`type` を `soratomoPost`・`1bbdac96c0a5`）で通知の形の1本と新着投稿との独立の1本が `type` の違いで赤。m3（置き換えキーを `soratomo-{groupId}`・`e500ead12832`）で通知の形の1本だけが `collapseId` の違いで赤。m4（`notifyReaction` の失敗を投げ直す・`d606d96ea2ba`）で失敗の1本だけが、最初の場面（送信が投げる）の応答が `internal` になって赤。m5（成功のログにグループ名を足す・`3d63375c5e91`）で、応答とログの形・通知の形（ログの項目の比較）・失敗（「ログに名前を出さない」）の3本が赤。追加の写し: m6（`classifyRecipient` の `posterId` に投稿者を渡す・`3e50147cba0b`）で宛先の判定の1本だけが、ブロックの場面で送ってしまって赤。m7（枠の確保を通知文の組み立てより先にする・`82aede0e3092`）で失敗の1本だけが「組み立てが投げる: 間引きの記録を使わない」の `0` の期待に `1` で赤。どの写しも、赤は狙ったテストに限られた
    - 全体のテスト（`npm test`・`npm run test:emulator`）は、同じ `soratomo.js` を触る3.2の後にまとめて1回流す（3.2の結果に書く）。lintは緑。`soratomo.js` を読むテストのファイルは `soratomo.test.js` だけ（grepで確かめた）

- [x] 3.2 投稿の削除トリガー `onSoratomoSkyDeleted` を作り、本数の記載を直す（陽性対照C9）
  - 前提: 3.1（同じ `soratomo.js` を触る）
  - design.mdの「onSoratomoSkyDeleted」のとおり、`onDocumentDeleted({ document: "soratomoGroups/{groupId}/skies/{skyId}", region: REGION })` で作る（再試行は付けない）。消えた文書の `reactions` の鍵の数を数え（地図でなければ0）、`reactionNotices/{skyId}` を消し、`soratomoReaction: sky_deleted`（`groupId`・`skyId`・`reactionsDeleted`）をinfoで出す。失敗は `soratomoReaction: sky_deleted_failed`（`groupId`・`skyId`・`errorName`・`errorCode`）をerrorで出し、投げない
  - `module.exports` に足して13本にし、公開する関数の数を確かめる既存のテストを13本に直す。`functions/soratomo.js` のヘッダー（2行目の本数・説明の箇条に `soratomoSetReaction` と `onSoratomoSkyDeleted`・23行目の「11 本」）と、`functions/index.js` の580行のコメント（Callable 9本・トリガー3本・定期実行1本）を直す
  - `soratomo.test.js`: 印が消える・件数のログ（地図でない `reactions` は0）・2回目も成功（印が無くても成功）・ログに名前などが無い。公開する関数が13本で、選択肢の名前の検査が通る
  - 陽性対照（C9）: 場面は「リアクションの付いた投稿を消し、削除のイベントを渡す」。印を消さない写し（本体を件数のログだけにした形＝トリガーを外したのと同じ結果）で、「印が消える」が赤になることを先に確かめる
  - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 14.3, 14.5_
  - 結果（2026-10-19 11:48）: `HEAD` `51c42ca4`（3.1の後）の上で作った。`functions/soratomo.js` の `onSoratomoSkyCreated` の後に `// MARK: - 投稿の削除（soratomo-reactions 3.2）` の節を足し、`handleSoratomoSkyDeleted` と `onSoratomoSkyDeleted`（`onDocumentDeleted`・region `asia-northeast1`・再試行なし）を置いた。消えた文書の `reactions` を `event.data.get` で読み、地図（null・配列でない物）のときだけ鍵の数を数える。印のコレクションの名前は `soratomoStore.js` の `REACTION_NOTICES` と同じ文字列で書いた（コメントで結んだ）。`module.exports` に足して13本。ヘッダー（2行目を Callable 9本・トリガー3本・定期実行1本に、説明の箇条に `soratomoSetReaction` と `onSoratomoSkyDeleted`、23行目を「13 本」）と `functions/index.js` の580行のコメント（Callable 9本・トリガー3本）を直した。直した後、3つのファイルで古い本数（「11本」「12本」「Callable 8本」「トリガー2本」）が0件であることを検索で確かめた（同じ検索は直す前の「11本」を拾えていた）
    - テスト: `soratomo.test.js` の末尾に4本を足し、公開する関数の一覧のテストを13本に直した（名前と、選択肢の名前の検査のコメントも13本に）。足した4本: 印が消える・ほかの投稿の印と間引きの記録は残る・件数のログ（2件）・再配信でも成功・ログに名前などを出さない／地図でない `reactions`（無い・null・配列・文字列）と空の地図は0件・イベントに中身が無くても投げない／印の削除の失敗（`db.collection` を一時的に差し替えて投げさせる）で投げず、`sky_deleted_failed` を error で内部IDと `errorName`・`errorCode` だけ／関数の設定（削除のイベント・文書のパターン・リージョン・`retry: false`。設定の形は先に使い捨ての関数で確かめた）
    - 流し方: エミュレーター（`emulators:exec --only firestore,storage`・`demo-soramoyou-security`・Storageの一時置き場は専用の `TMPDIR`）の1回の中で、scratchpadの台本 `run-3.2.sh` から「実装の前の写し（`HEAD` の `soratomo.js`・頭 `68cf65f29b20`）→本物→壊した写し3通り→本物」を流し、続けて `package.json` の `test:emulator` の `node --test` の部分をそのまま `functions/` で流した（サンドボックスの外・空の `XDG_CONFIG_HOME`・JBR）。本物の shasum の頭は、写しを作る前と流した後で `soratomo.js` が `9cba95389070`、`soratomo.test.js` が `c1b5e6c3a74c`、`index.js` が `0cdf347c9677` のまま
    - 結果: 実装の前の写しは73本中5本が赤で、赤は新しい4本（関数が無い）と公開する関数の一覧の1本だけ。本物は2回とも73本・0失敗
    - 陽性対照（C9）: 写し mC9（本体から印の削除の1行を外し、件数のログだけにした形＝トリガーを外したのと同じ結果・頭 `1fb568bb86d1`）で、C9のテストが「消えた投稿の印を消す」の `expected: false`／`actual: true` で赤（ほかに、削除を呼ばないので失敗のログが出ない失敗の1本も赤・計2本）。追加の写し: mD-throw（失敗を投げ直す・`f181ba871993`）で失敗の1本だけが、差し替えで投げさせたエラーで赤。mD-array（配列も地図として数える・`70adbbb6b3ba`）で地図でない値の1本だけが、配列の場面の `2`（期待は `0`）で赤
    - 全体（3.1と3.2をまとめて）: lintが緑。`npm test` が417本・0失敗、`npm run test:emulator` の中身が340本・0失敗（2.3の後の325本＋3.1の11本＋3.2の4本。どちらもサンドボックスの外・Node 22.20.0）。終わった後、エミュレーターのプロセスが残っていないことを `ps` で確かめた

## (d) Functions: 共通の削除（手順2b）

- [x] 4. 抜ける・退会・利用停止・後始末で、本人が付けたリアクションを消す

- [x] 4.1 本人のリアクションが消えることのテストを先に書き、今の現物で赤を確かめる（陽性対照C2）
  - 前提: 1.3（4.1〜4.3は `soratomoDeletion.test.js` とエミュレーターを使うので、2・3と同時に進めない）
  - `soratomoDeletion.test.js` に、リアクションと印をAdmin SDKで直接入れた種を作る部品を足す（ほかのメンバーの投稿に、本人と別の人のリアクション・`reactorIds`・`reactionNotices` の `notifiedReactorIds`、本人あての `reactionNotifyState`）
  - テストを足す（期待は4.2・4.3の後の姿）:
    - 抜ける（`leaveSoratomoGroup`・`origin: "self"`）: 本人がほかのメンバーの投稿に付けたリアクションと、印の中の本人が消え、本人の `reactionNotifyState` が消える。ほかの人のリアクションと印は残る。`done: true` は消し終えた後
    - 退会（`deleteSoratomoUserData`）・利用停止（`suspendSoratomoUser`）・アカウントの無い人（仕事Aの部品）: 所属するすべてのグループで同じく消え、`done: true` は消し終えた後
    - 運用の削除（`scripts/soratomo-admin.js` の、内部IDを指定した削除）: 同じく消える（`scripts/soratomo-admin.emulator.test.js` に1件）
  - テストだけを足した作業ツリー（コミットしない）で、今の現物（4.2の前の `soratomoDeletion.js`）で流す。そのときの `HEAD` とテストのファイルの shasum の頭を結果に書く。赤の理由が「本人のリアクションが残る」であることをテストごとに確かめ、件数で記録する（`reactionsDeleted` の項目が無いことによる赤は、別に数えて分ける）
  - _Requirements: 9.1, 9.5, 9.6, 9.7, 9.8, 9.9_
  - 結果（2026-10-19 12:24）: `HEAD` `bd382a12`（3.2の後。着手の前に `git fetch -q origin` をして、`origin/main` が進んでいないことを確かめた）の現物の `soratomoDeletion.js`（shasum の頭 `768625632b3a`）で、テストだけを足した作業ツリー（コミットしない）から流した。足したテストのファイルの shasum の頭は、`soratomoDeletion.test.js` が `97bea90fb111`、`scripts/soratomo-admin.emulator.test.js` が `7a5048ba7fec`
    - 足したもの: `soratomoDeletion.test.js` の末尾（既存の行番号を動かさないため。1.3で数えた38か所の位置はそのまま）に `// MARK: - 手順2b` の節を切り、種の部品（`seedReactedSky`・`seedReactionNotice`・`seedReactionNotifyState`・`seedReactionScene`）と、状態を丸ごと読む `reactionDump`、期待の形 `G1_AFTER_AMY`・`G2_AFTER_AMY`、見る順を決めた `assertReactionsAfter`（投稿→印→間引きの記録）を置き、テストを4本足した（退会 `self`・利用停止・アカウントの無い人 `account_deleted` は、同じ種と期待を表で回す3本。抜ける `origin: "self"` が1本）。`scripts/soratomo-admin.emulator.test.js` の末尾に `delete-user` の1本を足した。種は Admin SDK で直接入れ、`kind` は名前の文字列だけにした。本人の投稿の印は入れていない（本人の投稿は手順2で消え、その印は削除のトリガーが消すが、このテストは関数を起こさない）
    - 種の形: amy は g1（owner・bob）と g2（carl・dave）のただのメンバー。g1 は owner の o1 に amy と bob、bob の b1 に amy と owner、owner の o2 に bob、amy の a1 に bob が付けている。g2 は carl の c1 に amy と dave。印は o1 `[amy, bob]`・b1 `[amy]`・o2 `[bob]`・c1 `[amy, dave]`、間引きの記録は g1 が amy・owner・bob、g2 が amy・carl
    - 見る順: 状態（投稿の `reactions` のキーと `reactorIds`→印→間引きの記録）を先に、戻り値の `reactionsDeleted` を最後にした。戻り値の丸ごとの比較は書いていない（`reactionsDeleted` の欠落で先に落ち、C2の赤を隠すため）。既存の `ZERO_TOTALS`・`NOTHING`・`zero` には、まだ `reactionsDeleted: 0` を足していない（4.2・4.3で足す）
    - 流し方: 8080 が別のセッションのエミュレーターに使われていた（`port taken`）ので、ポートを替えた設定（firestore 8186・websocket 9166・hub 4426・logging 4526。規則のファイルは作業ツリーの絶対パス）を scratchpad に置いて `--config` で渡し、`emulators:exec --only firestore`・`demo-soramoyou-security` の1回の中で、台本 `run-4.1.sh` から2ファイルを流した（サンドボックスの外・空の `XDG_CONFIG_HOME`・JBR）
    - 結果（陽性対照C2の赤）: `soratomoDeletion.test.js` は68本中4本が赤（既存の64本は緑）、`soratomo-admin.emulator.test.js` は11本中1本が赤（既存の10本は緑）。赤は足した5本だけで、5本とも最初の状態の assert で落ちた。理由はどれも「本人のリアクションが残る」。4本は g1 の投稿の比較で、o1 と b1 の `reactions` のキーと `reactorIds` に amy が残っていた（期待は o1 が `[bob]`、b1 が `[owner]`）。delete-user の1本は、s2 の `reactions` のキーに deadU が残っていた（期待は `[other]`）。`reactionsDeleted` の項目が無いことによる赤は0本（状態の assert で先に落ち、そこまで届かない）
    - コミット: 赤のテストはコミットしない。退会・利用停止・後始末・運用の4本は4.2の緑と一緒に、抜けるの1本は4.3の緑と一緒にコミットする

- [x] 4.2 手順2b `removeUserReactionsInGroup` を作り、退会・利用停止・後始末・運用の削除に差し込む（陽性対照C2）
  - 前提: 4.1, 3.2（`soratomo.js` のログの項目を触るので、3の後）
  - `functions/soratomoDeletion.js` に、design.mdの「共通の削除」のService Interfaceのとおりに作る。`skies` を `where("reactorIds", "array-contains", uid)` で300件ずつ読み、`beforeDelete`（省略可）を呼び、各文書を `update`（`reactions.{uid}` を `FieldPath` で `delete`・`reactorIds` から `arrayRemove`・前提条件 `{ lastUpdateTime: 読んだ文書の updateTime }`）で同時に10件まで書く。`NOT_FOUND` と `FAILED_PRECONDITION` は数えずに飛ばす（後者は次の区切りで読み直す）。`set(merge)` は使わない。続けて `reactionNotices` を `where("notifiedReactorIds", "array-contains", uid)` で同じく読み、同じ前提条件で `arrayRemove(uid)`。区切りごとに締め切りを確かめる
  - `deleteUserDataInGroup` の手順2の後、残るメンバーがいる（`leave`）ときだけ手順2bを呼ぶ（照合なし）。手順3で `reactionNotifyState/{uid}` も消す。`delete_group` では行わない。行番号はdesign.md（`abaa3bdb` の現物で確かめた値）を目安にし、書く前に現物で確かめる
  - D4の読み方（承認済み）: 戻り値に `reactionsDeleted`（消した投稿のリアクションの数）を足し、`deleteSoratomoUserData` の合計に足す。`soratomo.js` の `soratomoDeleteMyData` の `okLogFields` に足す（`soratomoDeletion: summary` は合計をそのまま出すので自動で載る）。リアクション以外の消す範囲・既存の件数の値・利用者へ返す応答（`{ done }`）は変えない。既存のテストは、1.3（Q5）で数えた箇所の期待値に `reactionsDeleted: 0` を足す以外は変えない
  - D1の読み方（承認済み）: 印の中の本人のuidを、退会・利用停止・アカウントの無い人の片づけで外す
  - `soratomoDeletion.test.js` に足す: 最後の1人では手順2bを行わず全部が消える／締め切り（300件を超えるリアクションで `done: false`・続きで消し切る・2回目は件数0）／更新の前に投稿が消えた（`NOT_FOUND`・投げずに飛ばし数えない）／更新の前に投稿が書き換わった（`FAILED_PRECONDITION`・投げずに飛ばし、次の区切りで読み直して消す）／何度呼んでも1回で成功した場合と同じ／利用停止の解除で消したリアクションが戻らない
  - 4.1の退会・利用停止・アカウントの無い人・運用の削除のテストが緑になったことを並べて記録する
  - 陽性対照: `set(merge)` で書く写しで「消えた投稿を作り直さない」が、`reactions` の地図を丸ごと消す写しで「ほかの人のリアクションは残る」が、`arrayRemove` をしない写しでI1が、それぞれ赤になることを先に確かめる
  - _Requirements: 9.2, 9.3, 9.5, 9.6, 9.7, 9.8, 9.9, 9.10, 9.11, 9.12, 12.12, 12.13, 14.5_
  - 結果（2026-10-19 15:09）: `HEAD` `bd382a12`（4.1と同じ。コミットの前に `git fetch -q origin` をもう一度して、`origin/main` が進んでいないことを確かめた）の上で作った。`functions/soratomoDeletion.js` に手順2b `removeUserReactionsInGroup` と、部品の `updateEachByQuery`（クエリを `select()` で300件ずつ読み、照合→書く→締め切りの確認の順。毎回先頭から読む）・`updateDocChunk`（同時に10件まで・前提条件 `{ lastUpdateTime: 読んだ文書の updateTime }`・飛ばした書き込みは数えない）と、定数 `REACTION_NOTIFY_STATE`・`REACTION_NOTICES`・`REACTION_UPDATE_CONCURRENCY`（10）・`SKIPPED_WRITE_CODES`（5と9）を足し、`FieldPath` を読み込んだ。投稿は `reactions.{uid}`（`FieldPath`）の削除と `reactorIds` の `arrayRemove` を前提条件つきの1回の `update` で書き（I1）、印は `notifiedReactorIds` から `arrayRemove` するだけで文書は消さない。`deleteUserDataInGroup` は、手順2（投稿）の後・画像の前に、`leave` のときだけ手順2bを照合なしで呼び、手順3で `reactionNotifyState/{uid}` も消す。戻り値と `deleteSoratomoUserData` の合計に `reactionsDeleted` を足し、`soratomo.js` の `soratomoDeleteMyData` の `okLogFields` に足した。`removeUserReactionsInGroup` は exports にも足した（テストで、照合の口から「読んだ後・書く前」の場面を作るため。4.3で抜けるからも呼ぶ）
    - 前提の実測（scratchpadの使い捨ての台本 `probe-4.2.js`・エミュレーター）: `select()` で読んだ文書にも `updateTime` が載る。前提条件 `lastUpdateTime` つきの `update` は、読んだ後に書き換わった文書でも、読んだ後に消えた文書でも `FAILED_PRECONDITION`（code 9）で失敗し、消えた文書は作り直されない（`NOT_FOUND` では返らなかった）。飛ばすコードは、設計の2つ（5と9）を両方とも残した（本番がどちらで返しても飛ばす）
    - 既存のテストの直し（D4）: 1.3（Q5）で数えた範囲のうち、退会・利用停止・後始末の分だけに `reactionsDeleted: 0` を足した。`soratomoDeletion.test.js` は12か所（`deleteUserDataInGroup` の結果8か所・`deleteSoratomoUserData` の合計2か所・`suspendSoratomoUser` の合計1か所・共有の定数 `ZERO_TOTALS`。行番号は1.3の値から動いている）、`functions/soratomo.test.js` は3か所（`soratomoDeleteMyData: ok` の2か所と、`soratomoDeletion: summary` の `zero`）。抜けるの分（`NOTHING` と `leaveSoratomoGroup` の結果・`soratomoLeaveGroup: ok`・`soratomoLeave: swept`）は4.3で足す。期待値の追加のほかは、既存のテストを変えていない
    - 足したテスト（`soratomoDeletion.test.js` の「手順2b」の節）: 4.1の3本（退会 `self`・利用停止・アカウントの無い人）はそのままに、6本を足した（最後の1人では手順2bを行わずすべてが消える／締め切り（301件で1回目は300件・`done: false`、続きで1件、3回目と4回目は件数0で状態が同じ）／読んだ後・書く前に投稿が消えた／書き換わった（照合の口の中で bob が `setReactionTx` で選び直す）／締め切りで止まってもI1がそろう／利用停止の解除で戻らない）。消えた・書き換わった・I1の3本は `removeUserReactionsInGroup` を直接呼び、照合の口で場面を作る。`scripts/soratomo-admin.emulator.test.js` は4.1の1本のまま（shasum の頭 `7a5048ba7fec`・4.1と同じ）
    - 4.1の抜けるの1本は4.3まで赤なので、作業ツリーから外してscratchpadに置いた（4.3で戻す）。このコミットには含めない
    - 流し方: 4.1と同じ設定（ポートを替えた設定を `--config` で渡す・`--only firestore,storage`・サンドボックスの外・空の `XDG_CONFIG_HOME`・JBR）で、`emulators:exec` の1回の中で、台本 `run-4.2.sh` から、実装の前の写し→本物→壊した写し7つ→本物→全体（`test:emulator` の `node --test` の部分）の順に流した（13:06に終わった）。テストのファイルの shasum の頭は `soratomoDeletion.test.js` が `bbb8b29b158f`、本物の `soratomoDeletion.js` が `22b905ae3338`。流した後に作業ツリーが変わっていないこと（更新の時刻と、写しの置き場のテストのファイルとの shasum の一致）を確かめた。終わった後、ポート（8186・9196・4426）で待ち受けるプロセスが残っていないことを `lsof` で確かめた
    - 結果（実装の前の赤）: 実装の前の写し（`HEAD` の `soratomoDeletion.js`・頭 `768625632b3a`）は73本中21本が赤。既存の12本は、期待と実際の差分が `reactionsDeleted: 0` の1行だけ（期待値に足した分）。新しい9本は、C2の3本と解除の1本が g1 の投稿に amy が残る、最後の1人の1本が `reactionsDeleted` が無い、締め切りの1本が `done` が `true`、直接呼ぶ3本が関数が無い（`is not a function`）
    - 結果（本物）: 本物は2回とも73本・0失敗。`scripts/soratomo-admin.emulator.test.js` は11本・0失敗。4.1で赤だった退会・利用停止・アカウントの無い人・運用の削除の4本が緑になった（陽性対照C2のうち4.2の分）。全体のエミュレーターのテストは350本・0失敗（3.2の後の340本に、このファイルの9本と運用の1本）。サンドボックスの外で、`npm run lint` は緑、`npm test` は417本・0失敗（本数は変わらない）
    - 陽性対照（写しごとの赤。どれも、落ちた assert の位置と期待・実際まで読んだ）:
      - m1 `set(merge)` で書く（頭 `b0f7a94a6bb2`）: 1本が赤。消えた投稿の場面の「消えた投稿を作り直さない」（`expected: false`／`actual: true`）
      - m2 `reactions` の地図を丸ごと消す（`1a8616ed149a`）: 8本が赤。C2の3本・解除・締め切り・消えた・I1の7本は、ほかの人のリアクションのキーまで消えた（例: o1 の期待 `[bob]` が `[]`）。書き換わったの1本は、地図が無くなって `Object.keys` が投げた
      - m3 `reactorIds` から外さない（`5d84f14002b4`）: I1の1本だけを流して赤（b1 の `reactorIds` に amy が残り、キーと食い違う）。ほかのテストは、外れない投稿がクエリに当たり続けて動かない時計では終わらないので流していない
      - m4 手順3で `reactionNotifyState/{uid}` を消さない（`9b9bb4e469c5`）: 5本が赤。どれも間引きの記録に amy が残る
      - m5 印の中の本人を外さない（印のクエリを誰にも当たらない形にした・`4fa12a6c251b`）: 6本が赤。どれも印に amy が残る
      - m7 飛ばした書き込みも数える（`46e03e64d0a1`）: 2本が赤。消えたの場面の `deleted` が `2`（期待は `1`）、書き換わったの場面が `3`（期待は `2`）
      - m6 最後の1人でも手順2bを行う（`9e3eac6cba98`）: 73本・0失敗で、赤にならなかった（陽性対照が取れていない）。手順2bは全投稿を消した後に走るので投稿のクエリが空で、印から本人を外しても直後の `recursiveDelete` で消えるため、結果が同じになる（等価な写し）。そのため「最後の1人では手順2bを行わず」のテストが確かめているのは「すべてが消える」と `reactionsDeleted` が0であることまでで、「手順2bを呼ばない」ことは確かめていない。4.3の抜けるの最後の1人のテストは、照合の口が呼ばれた回数で見る
    - コミット: 4.1の退会・利用停止・アカウントの無い人・運用の削除の4本と、4.2のテストと実装を一緒にコミットする

- [x] 4.3 抜けるに手順2bを照合つきで差し込み、入り直しとの競合を確かめる（陽性対照C2・C3・C10）
  - 前提: 4.2
  - `leaveSoratomoGroup` の手順2の後、`leave` のときだけ手順2bを呼び、`beforeDelete` に照合（`isLeaveEpisodeCurrent`）を渡す。外れたら `superseded` で止める。`finishLeaveTx` で `reactionNotifyState/{uid}` も消す。結果に `reactionsDeleted` を足す
  - `functions/soratomo.js` の `soratomoLeaveGroup` の `okLogFields` と、仕事Cの `soratomoLeave: swept` に `reactionsDeleted` を足す。応答（`{ done, groupDeleted }`）は変えない
  - 止め方: 実行を手順2bの照合の前後で止める口は、`leaveSoratomoGroup` のdepsに省略できるテスト用の口を足すか、`removeUserReactionsInGroup` を直接呼ぶ形にする（どちらにしたかを結果に書く。口を足すなら、本番の既定は何もしない形にする）
  - 陽性対照（C2）: 4.1の抜けるのテストが緑になったことを記録する
  - 陽性対照（C3）: 場面は「抜けるの実行Aを手順2bの照合の前で止め、その間に実行Bが最後まで終え、本人が入り直して同じ投稿に付け直し、Aを再開する」。期待は、Aが照合で `superseded` になり、新しいリアクションが残ること。手順2bに照合を渡さない写しで、新しいリアクションが消えて赤になることを先に確かめる
  - 陽性対照（C10）: 場面は「実行Aの手順2bで、照合が真を返した直後・更新の前に、実行Bが最後まで終え、本人が入り直して同じ投稿に付け直す」（照合の口を包み、本物の照合が真を返した後に、Bと入り直しと付け直しを行ってから真を返す）。期待は、Aの更新が `FAILED_PRECONDITION` で何も消さず、次の区切りの読み直しで照合が外れて `superseded` になり、新しいリアクションが残ること。更新の前提条件（`lastUpdateTime`）を外した写しで、新しいリアクションが消えて赤になることを先に確かめる
  - 入り直したがまだ付けていない場合は、抜ける前のリアクションを消す（文書が変わっていないため）。ほかのメンバーが同じ投稿に付けた・外した場合は、次の区切りで読み直して消す。最後の1人の抜けるでは手順2bを行わず、グループごと消える
  - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.10, 9.11, 12.12, 12.13, 14.5_
  - 結果（2026-10-19 15:52）: `HEAD` `141ba82c`（4.1・4.2の後。着手の前に `git fetch -q origin` をして、`origin/main` が進んでいないことを確かめた）の上で作った。止め方は、`leaveSoratomoGroup` のdepsに省略できるテスト用の口 `wrapReactionCheck`（照合を受け取り、手順2bに渡す照合を返す）を足す形にした。本番の既定は何もしない形（`(check) => check`）で、関数でなければ手順1の前に `TypeError`（何も書かない）。手順2の後・手順3の前に、`leave` のときだけ `removeUserReactionsInGroup` を `wrapReactionCheck(stillCurrent)` つきで呼び、数を結果に入れてから、`stopped` なら `superseded`、未完了なら `done: false` で返す（手順2と同じ型）。手順2・手順3・`recursiveDelete` の前の照合は包まない。`finishLeaveTx` は `leave` のときに `reactionNotifyState/{uid}` も消す。結果に `reactionsDeleted` を足し、`soratomo.js` の `soratomoLeaveGroup` の `okLogFields` と仕事Cの `soratomoLeave: swept` に足した。応答（`{ done, groupDeleted }`）は変えていない
    - 既存のテストの直し（D4）: 1.3（Q5）で数えた抜けるの分に `reactionsDeleted: 0` を足した。`soratomoDeletion.test.js` は11行（共有の定数 `NOTHING` の1行で6か所が直り、残りは10か所。同じ形の2か所は1回の置き換え）、`functions/soratomo.test.js` は4行（`soratomoLeaveGroup: ok` の2行と `soratomoLeave: swept` の2行）。1.3の38か所は、4.2と4.3ですべて直した。期待値の追加のほかは、既存のテストを変えていない
    - 足したテスト: 4.1の抜けるの1本（scratchpadから戻した）と、4.3の6本（C3／C10の付け直す形と付け直さない形の2本／照合の後・書く前にほかのメンバーが選び直す／最後の1人は手順2bを行わない（照合の口が呼ばれた回数が0）／口が関数でなければ `TypeError` で何も書かない）。shasum の頭は、`soratomoDeletion.test.js` が `4113c4a22b70`、`soratomo.test.js` が `d0f26dfece72`、本物の `soratomoDeletion.js` が `b9ba93a77f7e`、`soratomo.js` が `a158c436e762`
    - 入り直しの読み方: `joinGroupTx` は所属の写しが残っている間は `leave_pending` で断るので、入り直せるのは、別の実行が手順4（写しと印を消す）まで終えた後だけ。その実行の手順2bが抜ける前のリアクションを先に消しているので、「入り直したがまだ付けていない」場面は、C10の付け直さない形（Aの書き込みは前提条件で失敗して数えず、手順4の照合で止まる。抜ける前のリアクションは消えたまま）になる。「文書が変わっていないので消す」形は、この順では起きない
    - 流し方: 4.2と同じ設定で、台本 `run-4.3.sh` から、本物→実装の前の写し→壊した写し4つ→`soratomo.js` の写し→本物→全体の順に流した（15:23〜15:51。下書きのテストを初めて流すので、本物を先にした）。負荷が高め（1分平均32）だったので `nice` を付けた。流した後に作業ツリーが変わっていないこと（4つのファイルの shasum が、写しを作る前と同じ）を確かめ、終わった後にポート（8186・9166・9196・4426・4526）で待ち受けるプロセスが無いことを `lsof` で確かめた
    - 結果（実装の前の赤）: 実装の前の写し（`HEAD` の `soratomoDeletion.js`・頭 `22b905ae3338`）は80本中18本が赤。既存の11本は、期待と実際の差分が `reactionsDeleted: 0` の1行だけ。新しい7本は、C2の抜けると選び直しの2本が amy が残る、C3とC10の3本が口が呼ばれない（場面が作れず「B が A より先に」で落ちる）、最後の1人の1本が `reactionsDeleted` が無い、口の型の1本が `TypeError` が出ない。`soratomo.js` をログの項目を足す前に戻した写し（`d4f9d5ed411f`）では、`soratomo.test.js` が73本中3本が赤（`soratomoLeaveGroup: ok` の1本と `soratomoLeave: swept` の2本。差分は `reactionsDeleted: 0` の1行だけ）
    - 結果（本物）: 本物は2回とも80本・0失敗。陽性対照C2のうち4.3の分（4.1の抜けるの1本）が緑になった。全体のエミュレーターのテストは357本・0失敗（4.2の後の350本に7本）。サンドボックスの外で、`npm run lint` は緑、`npm test` は417本・0失敗
    - 陽性対照（写しごとの赤。どれも、落ちた assert の位置と期待・実際まで読んだ）:
      - mC3 手順2bに照合を渡さない（`wrapReactionCheck(async () => true)`。止める口は残す・頭 `6a68f0451868`）: 2本が赤。C3とC10の付け直す形で、o1 のキーが `[bob]`（期待は `[amy, bob]`）＝新しいリアクションが消えた。C3は、1周目は前提条件で失敗して飛ばし、読み直した2周目で照合が真のまま書けて消える
      - mC10 投稿の書き込みから前提条件を外す（`8eb94758a057`）: 2本が赤。C10の付け直す形で新しいリアクションが消え（o1 のキーが `[bob]`）、付け直さない形で `reactionsDeleted` が `1`（期待は `0`）。4.2の「書き換わった」のテストは、前提条件が無くても1回目の書き込みが通って件数が同じになるので赤にならない（前提条件を確かめているのはC10だけ）
      - mF `finishLeaveTx` で `reactionNotifyState/{uid}` を消さない（`28b39dd9b380`）: 1本が赤。C2の抜けるで、間引きの記録に amy が残る
      - mL 最後の1人でも手順2bを行う（`8066cad2d6ed`）: 1本が赤。最後の1人のテストで、照合の口が1回呼ばれた（手順2で投稿を消した後も、印のクエリが前のメンバーの投稿の印に当たるため）。4.2のm6（退会の部品・照合なし）では取れなかった陽性対照が、抜けるでは照合の口の回数で取れた
    - コミット: 4.1の抜けるの1本と、4.3のテストと実装を一緒にコミットする

## (e) Firestoreのルール

- [x] 5. (P) Firestoreのルールに、リアクションの通知の記録の拒否を足す（陽性対照C1）
  - 前提: 1.1（ルールとルールのテストだけを触る。エミュレーターを使わないので、2〜4と同時に進めてよい）
  - `firestore.rules` の `soratomoGroups/{groupId}` の中、`notifyState` の `match` の後に、design.mdの「Backend: ルール・インデックス・ルールのテスト」のとおり拒否だけの `match` を2つ（`reactionNotifyState/{uid}`・`reactionNotices/{skyId}`）、コメントつきで足す。`skies` の `match` の条件は変えず、コメントを1行足す。冒頭のコメントの書き手の一覧に「リアクションと、リアクションの通知の記録」を足す。行番号は書く前に現物で確かめる
  - `storage.rules` と `firestore.indexes.json` は変えない
  - `scripts/rules_test_soratomo.py`: design.mdのとおり、`CASES` に6件（他人の投稿へのリアクションの `update`・投稿者の `reactions` の `update`・非メンバーの `update` はDENY／リアクションの付いた自分の投稿の削除はALLOW／付けた人の他人の投稿の削除はDENY／非メンバーのリアクションの付いた投稿の取得はDENY）、`closed_collection_cases()` に2つのコレクション（立場は投稿者・付けた人・ほかのメンバー・未ログイン。`get`・`list`・`create`・`update`・`delete` をすべてDENY）、`MUTANTS` に2つ（それぞれの `if false` を `if true` へ）を足す。ファイルの先頭のspecの一覧に、このspecを足す
  - 差分が「新しい `match` とコメント」だけで、既存の `match` の条件を緩めていないことを、差分で確かめる
  - 陽性対照（C1）: `--mutants` で、既存の壊し方「投稿の更新を許す」が、新しい `update` のDENYのケースを期待外れにする。新しい2つの壊し方が、新しい閉じたコレクションのケースを期待外れにする。どの壊し方でも期待外れにならないケースが0件・どのケースも期待外れにしない壊し方が0個・置き換え元が1回でない壊し方が0個。通常の実行がすべて期待どおり。件数を記録する
  - ここではルールをデプロイしない（12.5で行う）
  - _Requirements: 4.13, 12.8, 12.14, 12.16_
  - 結果（2026-10-19 16:06）: `HEAD` `e781dab7`（4.3とdesign.mdの直しの後）の上で作った。`firestore.rules` の `soratomoGroups/{groupId}` の中、`notifyState` の `match` の後に、拒否だけの `match` を2つ（`reactionNotifyState/{uid}`・`reactionNotices/{skyId}`）コメントつきで足し、`skies` の `match` の前にコメントを1行足し、冒頭の書き手の一覧に「リアクションと、リアクションの通知の記録」を足した（行番号はdesign.mdの値と一致した）。差分はコメントと新しい2つの `match` だけで、既存の `match` の条件は1つも変えていないことを差分で確かめた。`storage.rules` と `firestore.indexes.json` は変えていない。shasum の頭は、`firestore.rules` が `7e2c64c4c9d2`、`scripts/rules_test_soratomo.py` が `6f3d1a83a090`
    - `scripts/rules_test_soratomo.py`: 先頭のspecの一覧にこのspecを足し、リアクションの付いた投稿を作る `reacted_sky` を足した。`CASES` に6件（更新のDENYが3件・削除のALLOWとDENYが1件ずつ・非メンバーの取得のDENYが1件）、`closed_collection_cases()` に2つ（`soratomoGroups/g1/reactionNotifyState/author` と `soratomoGroups/g1/reactionNotices/s1`。立場は投稿者・付けた人・ほかのメンバー・未ログインで、`get`・`list`・`create`・`update`・`delete` の40件）、`MUTANTS` に2つ（それぞれの `if false` を `if true` へ）を足した
    - 流し方: rules test API で評価だけをした（本番のデータと deploy 済みのルールには触れない・サンドボックスの外）。最初の実行は firebase CLI のトークンが古く HTTP 401 だったので、台本の説明どおり `firebase projects:list` を一度呼んでから流し直した。直す前のルールの基準は123件・すべて期待どおり
    - 結果（通常の実行）: 169件（基準の123件に46件）・すべて期待どおり
    - 陽性対照（C1）: `--mutants` で、壊し方25個（既存の23個に2個）がどれも1件以上を期待外れにし、どの壊し方でも期待外れにならないケースは0件、置き換え元が1回でない壊し方は0個。新しいケースは、更新のDENYの3件が「投稿の更新を許す」（4件中3件）、削除のALLOWが「登録済みの判定を常に偽」と「匿名の判定を逆にする」、削除のDENYが「削除の投稿者判定を外す」と「削除の条件をすべて外す」、非メンバーの取得が「メンバー判定を外す」と「ログイン・匿名・メンバーの判定をすべて外す」で期待外れになった。新しい2つの壊し方は、それぞれのコレクションの20件だけを期待外れにした（ほかの壊し方では、新しい閉じたコレクションのケースは期待外れにならない）
    - デプロイはしていない（12.5で行う）

## (f) Functionsとルールのまとめ

- [x] 6. Functionsとルールのテストをすべて通し、既存の動きを変えていないことを点検する
  - 前提: 2〜5
  - `functions/` で `npm run lint`・`npm test`・`npm run test:emulator` を通す。リポジトリの直下で `rules_test_soratomo.py`（通常と `--mutants`）を通す。変えていない `rules_test_storage_soratomo.py` と `rules_test_post_update.py` も通ることを見る。件数を、着手のときに測った基準値と並べる
  - 差分で確かめる:
    - 既存のそらとものCallable（作成・参加・再発行・投稿・通報・同意・退会・抜ける）の受け付けの条件と応答が変わっていない（退会と抜けるの応答の形も同じ）
    - 退会・利用停止・抜ける・アカウントの無い人の後始末・開発者の削除の、リアクション以外の消す範囲と既存の件数が変わっていない（既存のテストの変更が、1.3で数えた `reactionsDeleted: 0` の追加と、公開する関数の数だけ）
    - リアクションは投稿の文書の2項目と、2つのサーバー専用のコレクションだけに書き、ルートの投稿・いいね・`likesCount`・ランキング・既存の通知の関数（`index.js`）に触れていない
    - 新着投稿の通知（`onSoratomoSkyCreated`）と `notifyState` の扱いが変わっていない。投稿の更新のトリガーを足していない
    - `storage.rules`・`firestore.indexes.json` は差分なし。既存のコレクションとStorageのパスの、クライアントのアクセスの条件を緩めていない。投稿の作成と更新は、クライアントから行えないまま
  - 古い版（1.15.0）からの要求: 作成・参加・投稿・通報・同意・退会・抜けるの既存のテストが、要求の形を変えずに通る。規則はすべてサーバーにあり、どのクライアントの要求にも同じく効く
  - サーバーのログ: 新しいログ（`soratomoSetReaction: ok`・`rejected`・`soratomoReaction: sky_deleted`・`sky_deleted_failed`・`notifyReaction` の `warn`）と、`reactionsDeleted` を足したログの項目に、グループ名・表示名・キャプション・招待コード・通知トークンが無いことを、コードから項目を抜き出して許可リストと突き合わせて確かめる
  - D4の読み方の確かめ: 利用者へ返す応答の形は変わらず、戻り値とログに `reactionsDeleted` が足されただけ
  - 既存のテストのうちmainで既に落ちているものは、変更前のmainでも同じく落ちることを確かめて区別する
  - 陽性対照: 差分の確かめは、わざと既存のルールに1行足した写しで引っかかることを先に確かめる。ログの確かめは、わざと新しいログに `name` を足した写しで引っかかることを先に確かめる
  - _Requirements: 4.16, 11.1, 11.2, 12.1, 12.4, 12.5, 12.6, 12.8, 12.12, 12.13, 12.14, 12.15, 12.16, 14.2, 14.3_
  - 結果（2026-10-20 16:19）: `HEAD` `ef8b91d8`（1〜5の後。着手の前に `git fetch -q origin` をして、`origin/main` が進んでいないことを確かめた。取り込みなし）の作業ツリーで、テストを流し、`origin/main` との差分を点検した。作業ツリーの45ファイル（`functions/*.js`・`scripts/*.test.js`・ルールのテスト・2つのルールとインデックス）の shasum を流す前に控え、すべて流した後に一致することを確かめた（`git status` は空のまま）
    - テスト（件数を、着手のときの基準値と並べる）: `npm run lint` は緑。`npm test` は417本・0失敗（基準417。サンドボックスの外・Node 22.20.0）。エミュレーターのテスト（`test:emulator` の `node --test` の部分をそのまま）は357本・0失敗・0中断（基準357・約5分）。`rules_test_soratomo.py` は169件・すべて期待どおり（基準169）。`--mutants` は壊し方25個がどれも1件以上を期待外れにし、どの壊し方でも期待外れにならないケースは0件・終了コード0（基準25個・0件）。変えていない `rules_test_storage_soratomo.py` は27件、`rules_test_post_update.py` は13件で、どちらもすべて期待どおり（投稿の更新のテストは `origin/main` のルールでも13件・すべて期待どおりで、件数は同じ。Storageのルールは `origin/main` とバイト一致）
    - 流し方: 8080 が別のセッションのエミュレーターに使われていた（9199・4400も）ので、4.1〜4.3と同じポートを替えた設定（firestore 8186・websocket 9166・storage 9196・hub 4426・logging 4526。規則は作業ツリーの絶対パス）を `--config` で渡し、`emulators:exec --only firestore,storage`・`demo-soramoyou-security` の1回で流した（サンドボックスの外・空の `XDG_CONFIG_HOME`・JBR・Storageの一時置き場は専用の `TMPDIR`・`nice`）。終わった後、そのポートで待ち受けるプロセスが無いことを `lsof` で確かめた。ルールのテストは、最初の実行が firebase CLI のトークンが古く HTTP 401 だったので、`firebase projects:list` を一度呼んでから流し直した（rules test API で評価するだけで、本番のデータに触れない）
    - 既存のテストのうちmainで既に落ちているもの: どのテストも0失敗だったので、該当なし（区別の必要がなかった）
    - 点検の道具: scratchpadに使い捨ての台本を置いた（コミットしない）。ルールの差分 `check_rules_diff.py`（頭 `3db8603f4d96`。新しい2つの `match` を取り除いた残りのコードの行（コメント・空行を除く）が `origin/main` と同じ並びか、新しい `match` の中身が `allow read, write: if false;` だけか、`storage.rules`・`firestore.indexes.json` がバイト一致か）、Functionsのコードの差分 `js_codediff.py`（`e37732e3c5b0`。コメント・空行を除いたコードの行で、消えた・変わった行と、増えた行の書き込みと触れてはいけない名前を列挙）、既存のテストの差分 `test_diffcheck.py`（`ecc8354fd0b6`。消えた・変わった行を「`reactionsDeleted: 0` の追加だけ」「数字（本数）だけ」「その他」に分け、`origin/main` の既存の `test(...)` の中に増えた行と外に増えた行を分ける）、ログの項目 `logcheck.py`（`ef8555297566`）と、その陽性対照の写しを作る `make_log_mutants.py`（`429bba22e5f5`）
    - 陽性対照（差分）: 先に写しで NG を取った。p1（既存の `skies` の `match` に `allow update: if true;` を1行足す）で「新しい `match` の外でコードの行が増えた」、p2（新しい `reactionNotices` の中身を `if true` に）で「新しい `match` の中身が拒否だけでない」、p3（既存の `skies` の読み取りから `isSoratomoUser() &&` を外す）で「`origin/main` のコードの行が変わった」、p4（`storage.rules` の写しに2行足す）で「`origin/main` と違う」。4つとも終了コード1。その後、作業ツリーの本物で全体 OK（終了コード0）
    - 陽性対照（ログ）: 先に、`soratomo.js`・`soratomoDeletion.js` の写しで、新しいログと `reactionsDeleted` を足したログの11か所へ1か所ずつ `name` を足した写し（置き換え元が本物に1回だけ現れることを確かめて作った）で NG を取った。11個とも、狙ったログだけが NG（拒否の `fields` と `requestIdFields` に足した2個は、`fields` を展開する `internal` も NG）。その後、本物で OK
    - 既存のそらとものCallable（作成・参加・再発行・投稿・通報・同意・退会・抜ける）: `soratomo.js` のコードの行で消えた・変わったのは `require` の1行（`onDocumentDeleted` を足す）だけ。既存のCallableの中に増えたコードは、退会と抜けるの `okLogFields` の `reactionsDeleted` の1行ずつだけで、関門（`requireSoratomoUser`・`allowAnonymous`）・本体・`respond` の行は変わっていない。`REASON_TO_CODE` は新しい理由2つ（`self_reaction`・`invalid_reaction`）を足しただけ。`soratomoStore.js` は `require` の1行（`FieldPath`）と理由の型のJSDocだけが変わり、ほかは新しい関数・定数・exportsの追加。`soratomoCore.js` は追加だけ。応答の形（退会の `{ done }`・抜けるの `{ done, groupDeleted }`）は同じ
    - 削除の範囲と既存の件数: `soratomoDeletion.js` で消えた・変わったコードは3か所だけ。`require` の1行（`FieldPath`）、`finishLeaveTx` の `if (kind === "leave") tx.delete(…NOTIFY_STATE…)` を、同じ削除を残したまま `reactionNotifyState/{uid}` の削除を足すブロックにしたもの、`deleteSoratomoUserData` の `totals` を改行し直して `reactionsDeleted: 0` を足したもの。増えたコードは、手順2b（`leave` のときだけ）・手順3の `reactionNotifyState/{uid}` の削除・結果と合計の `reactionsDeleted`・抜けるのテスト用の口 `wrapReactionCheck` だけで、投稿・画像・メンバー・写し・`notifyState` を消す既存の行は変わっていない
      - 既存のテストの変更（`test_diffcheck.py`）: `soratomoDeletion.test.js` は、既存の64本について、`reactionsDeleted: 0` の追加だけの塊が13個と、既存のテストの中に増えた `reactionsDeleted: 0,` の行が10行（計23か所＝4.2の12か所と4.3の11か所。1.3で数えた32か所は、共有の定数 `ZERO_TOTALS`・`NOTHING` を通してこれで直る）。ほかは末尾に足した新しいテストの塊1つ。`soratomo.test.js` は、`reactionsDeleted: 0` の追加だけが7塊（4.2の3か所と4.3の4行）、数字だけが5塊（関門の4本の名前の「7本」→「8本」と、公開する関数の一覧のテストの名前の「11本」→「13本」）、その一覧のテストの中に増えた行が2行（`onSoratomoSkyDeleted`・`soratomoSetReaction`）
      - このタスクの文言（`reactionsDeleted: 0` と公開する関数の数だけ）より2種類多い。（1）関門のテストの表 `CALLABLES` に `soratomoSetReaction` の行を1つ足した（3.1。既存の7本の行は変えていない。関門の4本の名前の本数はこのため）。（2）偽の送信の記録 `record` に `otherSends` を足し、記録するだけの偽の `sendToToken`・`sendToUid` と、テストごとの初期化の1行を足した（3.1。リアクションで既存のほかの通知の送信が呼ばれないことを見るため）。どちらも3.1の結果に記録済みで、既存のテストの assert の期待値は変えていない
      - `soratomoStore.test.js`・`soratomoCore.test.js`・`scripts/soratomo-admin.emulator.test.js` は、既存のテストに変更が無く、末尾に新しいテストの塊を1つ足しただけ
    - 書き込みの範囲: 増えたコードの書き込みは、投稿の文書の `reactions.{uid}`（`FieldPath`）と `reactorIds`（`setReactionTx` の `tx.update` 2つと、手順2bの `update`）、`reactionNotices`（`claimReactionNotifySlot` の `set(merge)`・手順2bの `update`・削除のトリガーの `delete`）、`reactionNotifyState`（`claimReactionNotifySlot` の `set`・手順3と `finishLeaveTx` の `delete`）だけ（`skyRef`・`noticeRef`・`stateRef` の定義も確かめた）。増えたコードに `posts`・`likes`・`likesCount`・`ranking` と既存の通知の関数の名前は0件。`functions/index.js` はコードの行の変更が0（580行のコメントの本数だけ）
    - 新着投稿の通知と `notifyState`: `onSoratomoSkyCreated`（`handleSoratomoSkyCreated`）と `claimNotifySlot` のコードの行は変わっていない。`notifyState/{uid}` を消す2か所（`deleteUserDataInGroup` の手順3と `finishLeaveTx`）は同じ行のまま（後者はブロックの中へ移っただけ）。増えたコードに `onDocumentUpdated`・`onDocumentWritten` は0件で、文書のトリガーは `onSoratomoSkyCreated` と `onSoratomoSkyDeleted` だけ（投稿の更新のトリガーは無い）。既存の新着投稿の通知のテストは変わらずに通り、C4（2.3）とリアクションとの独立のテスト（3.1）も通った
    - ルールとインデックス: `firestore.rules` の新しい2つの `match` の外のコードの行（320行）は `origin/main` と同じ並びで、差分はコメントと空行だけ。新しい `match` は各1回で、中身は `allow read, write: if false;` だけ。`storage.rules`（13067バイト）と `firestore.indexes.json`（4921バイト）は `origin/main` とバイト一致（`git diff --quiet` も0）。既存のコレクションとStorageのパスのアクセスの条件は1行も変わっていない。投稿の作成と更新の拒否は、`--mutants` の「投稿の作成を許す」（13件）と「投稿の更新を許す」（4件）で効き目を確かめたまま、通常の実行で期待どおり
    - 古い版（1.15.0）からの要求: 既存のテストの要求（`CALLABLES` の既存の7行と、作成・参加・投稿・通報・同意・退会・抜けるの各テストで Callable に渡す本文）は変わっていない（上の仕分けで、既存の `test(...)` の中の変更は期待値の `reactionsDeleted` と公開する関数の一覧の名前だけ）。その形のまま全部通った。リアクションの規則（利用停止・メンバー・投稿の有無・自分の投稿・7種類）はすべてサーバーの `setReactionTx` にあり、ルールはクライアントからの投稿の更新を拒否したまま（`reactions` を直接書く道は無い）なので、どの版のクライアントの要求にも同じく効く
    - サーバーのログ（`logcheck.py`）: spread（`...okLogFields(result, data)`・`...requestIdFields(data)`・`...fields`・`...totals`）を実体まで辿って項目を抜き出し、許可リスト（内部ID・件数・結果の名前・理由・`errorName`・`errorCode` などの22個）と突き合わせた。10本ともOK。`soratomoSetReaction: ok`（`uid`・`groupId`・`skyId`・`outcome`・`kind`・`notify`）、`rejected`（`uid`・`groupId`・`skyId`・`reason`）、`internal`（それに `errorName`・`errorCode`）、`notify_failed`（このタスクの「`notifyReaction` の `warn`」の実名。`uid`・`groupId`・`skyId`・`errorName`・`errorCode`）、`soratomoReaction: sky_deleted`（`groupId`・`skyId`・`reactionsDeleted`）、`sky_deleted_failed`（`groupId`・`skyId`・`errorName`・`errorCode`）、`reactionsDeleted` を足した `soratomoDeleteMyData: ok`（8項目）・`soratomoLeaveGroup: ok`（11項目）・`soratomoLeave: swept`（12項目）・`soratomoDeletion: summary`（9項目）。グループ名・表示名・キャプション・招待コード・通知トークンの項目は0
    - D4の読み方の確かめ: 利用者へ返す応答は、退会が `{ done }`、抜けるが `{ done, groupDeleted }` のまま（`respond` の行の変更なし）。足したのは、削除の戻り値（`deleteUserDataInGroup`・`leaveSoratomoGroup` の結果と `deleteSoratomoUserData` の合計）と、上の4本のログの `reactionsDeleted` だけ

## (g) iOS: モデル・変換・計測・サービス

- [ ] 7. iOSの土台を作る

- [x] 7.1 7種類の絵文字・投稿の中のリアクション・画面に出す数の型を作る
  - 前提: 1.1, 1.3（Functionsと別のセッションで並行してよい）
  - `Models/SoratomoReactions.swift`（新規）に、design.mdの形で `SoratomoReactionKind`（7つ・並び・`rawValue` は保存と計測の名前・`emoji`・`spokenName`）・`SoratomoReaction`・`SoratomoReactions`（`decode` は投げない）・`SoratomoReactionOverride`・`SoratomoReactionSummary`（`make`・`accessibilityLabel`）・`SoratomoReactorEntry` を置く
  - `SoratomoSky`（`Models/SoratomoModels.swift`）に `var reactions: SoratomoReactions = .empty` を足し、型の説明の「作成と削除だけで、更新しない」を「リアクションはサーバーが更新する」に直す。既存の `SoratomoSky(...)` の呼び出しは変えない。`Post` へ変換する口は作らない
  - `SoratomoReactionKindTests`（新規）: 7つの並び・名前・絵文字のスカラー（FE0Fを含む）・日本語名を固定する（2.1のFunctionsの値と同じ）
  - `SoratomoReactionsTests`（新規）: `decode`（無い→空・地図でない→空・知らない名前→その1人だけ飛ばす・値の形の違い）。`make`（絵文字の並び順で1以上だけ・0件は空・自分の印・ブロックの一覧の人を除く・自分の上書き・一覧の人数＝数の合計・一覧は新しい順で、時刻が同じか無いものはuidの順・投稿者本人のキーがあっても数える）。`accessibilityLabel` の文（例: 「リアクション、夕焼け3人、虹1人。あなたは夕焼けを付けています」）
  - 陽性対照: ブロックの除外を外した写しで除外のテストが、上書きを使わない写しで上書きのテストが、数の多い順に並べ替える写しで並び順のテストが、それぞれ赤になることを先に確かめる
  - _Requirements: 1.2, 2.1, 2.2, 2.3, 2.4, 2.7, 3.6, 5.1, 5.3, 12.2, 12.3, 13.2, 13.3, 15.4_
  - 結果（2026-10-20 19:00）: `HEAD` `a6332c78`（着手の前に `git fetch -q origin` をして、`origin/main`（`ca372cdb`）が `HEAD` の祖先であることを `git merge-base --is-ancestor` で確かめた。取り込みなし）の作業ツリーで、`Models/SoratomoReactions.swift`（新規）・`SoratomoModels.swift`（2か所）・テスト2つ（新規）を足した。テストは iPhone 17e `C2E3F752` で、`-only-testing` の2クラスだけ・`nice -n 19`・`-jobs 4`・`-parallel-testing-enabled NO`・`-test-timeouts-enabled YES`。xcresult で28本・28合格・0失敗（`SoratomoReactionKindTests` 6本・`SoratomoReactionsTests` 22本）。触った4ファイルの警告・エラーは0行（数え方が、ほかのファイルの警告8行を拾えることも確かめた）。アプリとテストのターゲットの全体がビルドできたので、既存の `SoratomoSky(...)` の呼び出しは変えずに通っている
    - 値: `SoratomoReactionKind` の並び・名前・絵文字は `functions/soratomoCore.js` の `REACTION_KINDS`（587〜594行）と同じ。絵文字は実装を `\u{...}` のエスケープで書き、テストはコードポイントの数値（`unicodeScalars`）とUTF-16の単位数で7行とも固定した（`soratomoCore.test.js` の `EXPECTED_REACTION_KINDS` と同じ値）。日本語名・名前の英小文字のスネークケース・`rawValue` がケース名や絵文字を受けないことも固定した
    - `SoratomoSky`: `var reactions: SoratomoReactions = .empty` を `createdAt` の後に足し、型の説明を「リアクション（`reactions`）はサーバーが更新する（ほかの項目は作成の後に変わらない）」に直した。`git diff` はこの2か所だけ（整形のフックの巻き込みなし）。`Post` へ変換する口は作っていない
    - design.mdに書いていなかったことを、次のとおり決めてテストで固定した（どれも後で変えられる）。（1）`decode` に既定値つきの `path: String? = nil` を足した（「地図でないときはパスと項目名を出す」のため。7.2の1引数の呼び方はそのまま使え、文書のパスを渡せる）。コンソールに出すのはパスと項目名 `reactions` だけで、値は出さない。（2）1人分の値が地図でない・`kind` が文字列でない・知らない名前はその1人だけ飛ばし、`at` が無い・`Timestamp` でないときはリアクションを残して時刻を nil にする。（3）一覧の並びは、時刻の新しい順・時刻の無いものは最後・同じ時刻どうしと時刻の無いものどうしは uid の順。（4）上書き `.set` の行の時刻は、サーバーに自分の分があればその時刻のまま（確定の前後で一覧の中の位置を動かさない）、無ければ nil。ログアウト中（`myUid` が nil）は上書きを使わない。ブロックの一覧に自分の uid があっても自分の分は除かない。（5）`accessibilityLabel` は0件で「リアクションなし」、自分の印が無いときは「。あなたは…を付けています」を付けない
    - 陽性対照: 作業ツリーの本物の `SoratomoReactions.swift` を Edit で1か所ずつ壊し、赤を確かめてから逆の Edit で戻し、そのたびに shasum が控え（頭 `cf311d2c9eac`。写しは scratchpad）と一致することを確かめた。（1）ブロックの除外を外す（`blockedUserIds` の代わりに空の集合）→ `testBlockedReactorsAreExcludedFromCountsTotalAndList`・`testReactorCountEqualsTotal` の2本が赤（このとき整形のフックが、使われなくなった引数を `blockedUserIds _:` に変えた。壊した関数の引数の1行で、戻すEditで一緒に戻した）。（2）上書きを使わない（条件に `myUid.isEmpty` を足す）→ 上書きの3本と `testReactorCountEqualsTotal` の4本が赤。（3）数の多い順に並べ替える → `testCountsFollowEmojiOrderNotCountOrder` と、数が1と2になる上書きのテストの2本が赤。（4）くもの絵文字から `\u{FE0F}` を落とす（このタスクの壊し方に足した）→ `testEmojiCodePointsIncludeVariationSelector` が赤（コードポイントとUTF-16の単位数の2か所）。どれもほかのテストは緑のまま。戻した後に4ファイルの shasum が控えと一致し、本物で上の28本が緑
    - shasum の頭（コミットするもの）: `SoratomoReactions.swift` `cf311d2c9eac`・`SoratomoModels.swift` `395998312ca0`・`SoratomoReactionsTests.swift` `02ff3763cc46`・`SoratomoReactionKindTests.swift` `54c76f78f3a6`
    - 実行の環境: サンドボックスの中では xcodebuild がパッケージを解決できず（`permissionDenied`。DerivedDataが外付けのSSD）、`pgrep` と `simctl` も動かないので、ビルド・テスト・`pgrep`・`simctl`・xcresultの読み取りはサンドボックスの外で流した。途中で1分平均が193と227に跳ね（ほかの `xcodebuild` は無かった）、40を切るまで待ってから流した。負荷の見張りのフックが「シミュレーターが2台動いている」と止めたが、2台は別の端末（iPhone 17 Pro `BF678DA1`・`DCFBF2D6`）で閉じず、1分平均が40以下（33）だったので `LOAD_OK=1` で流した

- [x] 7.2 投稿の変換と投稿1件の監視に、リアクションを載せる（陽性対照C7・C8・要確認Q6の反映）
  - 前提: 1.3, 7.1
  - `SoratomoSkyService.swift`: `Field` に `reactions` を足す（`reactorIds` はアプリでは読まない）。`decodeSky` の最後に `SoratomoReactions.decode(data[Field.reactions])` を入れる（壊れていても投稿を飛ばさない）。`resolveObservedSky` に `data` の引数を足し、`.present(SoratomoReactions.decode(...))` を返す。監視は1本のまま（同じ文書へ2本目のリスナーを張らない）
  - `SoratomoServiceContracts.swift` の `SoratomoSkyPresence` を `case present(SoratomoReactions)` にする。1.3（Q6）で数えた `.present` の一致（詳細の `case .success(.present)`・`SoratomoServiceMocks.swift`・既存のテスト）を、`.present(_)` か `.present(.empty)` に直す
  - `SoratomoTimelineViewModel`: 変換後の投稿の並びの比較（design.mdのF3の行）で、リアクションだけの変化でも `skies` が変わることを、テストで固定する。`removeGoneSky(_:)` を足す（中身は既存の非公開の `removeFromTimeline` を呼ぶだけ・ほかは変えない）
  - `SoratomoSkyServiceTests`: `decodeSky` がリアクションを読む・壊れたリアクションで投稿を飛ばさない・`resolveObservedSky` が `.present(reactions)` を返す。`SoratomoTimelineViewModelTests`: リアクションだけが変わった結果で `skies` が変わる・`removeGoneSky` で消える
  - 陽性対照（C8）: `decode` が壊れた値で投げる（`decodeSky` の変換を失敗させる）写しで、壊れたリアクションの投稿が `decodeSkies` で飛ばされ、「投稿を飛ばさない」が赤になることを先に確かめる
  - 陽性対照（C7）: `SoratomoSky` の `Equatable` をリアクションを比べない形にした写しで、リアクションだけを変えた結果で `skies` が変わらず、テストが赤になることを先に確かめる
  - _Requirements: 2.5, 2.7, 8.6, 9.13, 11.2_
  - 結果（2026-10-21 00:21）: `HEAD` `c63fa2d1`（着手の前に `git fetch -q origin` をして、`HEAD..origin/main` が空であることを確かめた。取り込みなし）の作業ツリーで、アプリ3ファイル・テスト3ファイル・design.md を直した。テストは `-only-testing` の3クラスだけ・`nice -n 19`・`-jobs 4`・`-parallel-testing-enabled NO`・`-test-timeouts-enabled YES`。本物の緑は iPhone 17e `885A74C7`（下の「端末」）で流し、xcresult で99本・99合格・0失敗だった。内訳は `SoratomoSkyServiceTests` 36本・`SoratomoTimelineViewModelTests` 47本・`SoratomoServiceContractsTests` 16本で、このタスクで足したのは7本。この回で触った8ファイル（投稿詳細と `SoratomoModels.swift` を含む）がすべてコンパイルされ、その警告・エラーは0行（同じ数え方で、ほかのファイルの警告29行を拾えることも確かめた）
    - `SoratomoServiceContracts.swift`: `SoratomoSkyPresence` を `case present(SoratomoReactions)` にした
    - `SoratomoSkyService.swift`: `Field` に `reactions` を足した（`reactorIds` は置かない）。`decodeSky` は最後に `SoratomoReactions.decode(data[Field.reactions], path: path)` を入れる（投げないので、壊れていても投稿を飛ばさない）。`resolveObservedSky` に `data:` を足し、`.present(SoratomoReactions.decode(data?[Field.reactions], path: path))` を返す。`observeSky` は、同じ1本の監視の中で `snapshot?.data(with: .estimate)` と `snapshot?.reference.path` を渡す（2本目のリスナーは張らない）
    - `SoratomoTimelineViewModel.swift`: `removeGoneSky(_:)` を足した（中身は既存の非公開の `removeFromTimeline` を呼ぶだけ・ほかは変えない）
    - テスト: `SoratomoSkyServiceTests` に5本を足した。`decodeSky` がリアクションを読む・項目が無ければ空・`resolveObservedSky` がリアクションを運ぶ（キャッシュの結果でも）・壊れていても `.present(.empty)` の4本と、C8の1本である。C8の1本は、壊れたリアクション（地図でない文字列と数・1人分が地図でない・知らない名前）の投稿を `decodeSkies` が飛ばさず、変換の失敗にも数えないことを見る。`SoratomoTimelineViewModelTests` には2本を足した。リアクションだけが変わった結果で `skies` と覚えが作り直される（外して空に戻ったときも・C7）1本と、`removeGoneSky` の1本である。後者は、投稿が消えて画像と記録に触れず、遅れた古い結果にも出ないことを見る。C7のテストは投稿の配列どうしでなく `reactions` を比べる（`SoratomoSky` の比較が壊れたとき、壊れた比較で緑に化けないため）
    - design.md: 型の節の `SoratomoReactions.decode` に、既定値つきの `path:` を書き足した（7.1の結果の（1）。利用者の決定 2026-10-20）
    - 要確認Q6の反映（1.3の一覧のとおり）: `.present` の5か所のうち4か所を直した。アプリの値1か所は `SoratomoSkyService.swift` の `resolveObservedSky` である。テストの値3か所（`SoratomoServiceContractsTests.swift` の2か所と `SoratomoSkyServiceTests.swift` の1か所）は `.present(.empty)` にした。モックは0か所のまま。`resolveObservedSky` の呼び出し8か所（アプリ1・テスト7）に `data:` を渡した。投稿詳細の `case .success(.present), .failure:`（`SoratomoSkyDetailView.swift:145`）は直していない（下の「整形のフック」）。Swiftは関連値のある case を値を書かずに当てられるので、そのままで値つきの `.present` に当たる。投稿詳細を元のままにした回でビルドが通ったことで確かめた。値を受け取る形（`.present(let reactions)`）にするのは8.3
    - design.mdに書いていなかったことを、次のとおり決めた（どれも後で変えられる）。（1）`decodeSky` に既定値つきの `path: String? = nil` を足し、`decodeSkies` が文書のパスを渡す（壊れたリアクションのコンソールの行で文書を特定するため。既存の呼び出しはそのまま通る）。（2）`resolveObservedSky` には `data:`（既定値なし。呼び出し8か所に渡した）と、既定値つきの `path:` を足した。（3）`observeSky` は、タイムラインと同じく `.estimate` で読む。（4）壊れたリアクションは、投稿の変換の失敗（`DecodeFailure`・`soratomo_sky_decode_failed`）として数えない。残るのは `decode` のコンソールの1行（パスと項目名だけ）
    - 陽性対照（C8）: 作業ツリーの本物の `decodeSky` を Edit で壊し（`reactions` があって地図でなければ `invalidField("reactions")` を投げる＝`decode` が壊れた値で投げる形）、iPhone 17e `C2E3F752` で流した。99本のうち赤は `testDecodeSkiesKeepsSkiesWhoseReactionsAreBroken` の1本だけ（assert 3つ。投稿が4件でなく1件になる・変換の失敗が3件残る・リアクションの並びが合わない）。ほかの98本は緑。逆の Edit で戻し、shasum が控え（頭 `f85ca72d396f`）と一致した
    - 陽性対照（C7）: `SoratomoSky` に、リアクションを比べない `==` を Edit で足した。iPhone 17e `885A74C7` で流し、99本のうち赤は `testReactionOnlyChangeUpdatesSkies` の1本だけだった（assert 4つ。リアクションが変わらない・覚え直しが2回目と3回目に起きない）。ほかの98本は緑。逆の Edit で戻し、shasum が控え（頭 `395998312ca0`＝7.1のコミットのまま）と一致した
    - 端末: C7の1回目は `C2E3F752` に `com.apple.instruments.deviceservice.lockdown` が120秒つながらず、テストの実行役が接続の前に止まった（943秒・0本。赤として数えない）。2回目は `Unable to find a device matching the provided destination specifier` で始まらなかった。`simctl list` から `C2E3F752` が消えていて、共用の `AC2D43EF` と、7.1で見たほかのセッションの `BF678DA1` も無かった。このセッションは端末を消していない。だれがなぜ消したかは確かめていない。利用者の決定で iPhone 17e（iOS 27.0）を新しく作り、`iPhone 17e soratomo`（`885A74C7-404F-46B8-8882-68A2C9D7F92F`）とした。C7の3回目と本物の緑はこの端末で流した。7.3以降もこの端末を使う
    - 整形のフック（1）: `decodeSky` の引数と、それを使う行を別々の Edit で足したところ、間のフックが引数を `path _:` に変えた。使う行を足した後に、同じ行を Edit で `path:` に戻した（関係ない行の巻き込みはない）
    - 整形のフック（2）: 投稿詳細の145行目だけを Edit したところ、フックが関係ない159行目まで書き換えた。`withActionMenu` の引数の書き方が、型の名前 `<Content: View>` から `some View` に変わった。そこで止めて利用者に知らせ、利用者が `git restore` で戻した。7.2では投稿詳細を触らない（利用者の決定）。8.3で投稿詳細を直す前に、同じ相談をする
    - shasum の頭（コミットするもの）: `SoratomoServiceContracts.swift` `f9b3ef204dd6`・`SoratomoSkyService.swift` `f85ca72d396f`・`SoratomoTimelineViewModel.swift` `7d0b7c01f158`・`SoratomoServiceContractsTests.swift` `e65f092a355b`・`SoratomoSkyServiceTests.swift` `41a181a7b419`・`SoratomoTimelineViewModelTests.swift` `2c767938212c`
    - 実行の環境: ビルド・テスト・`pgrep`・`simctl`・xcresultの読み取りは、7.1と同じくサンドボックスの外で流した。途中で1分平均が74.89に、5分平均が407に跳ねた（ほかの `xcodebuild` は無かった）。そこで1分平均が40を切るまで（2回目は、あわせて5分平均が80を切るまで）待ってから流した

- [x] 7.3 リアクションの通知のタップのテストを先に書き、今の現物（1.15.0と同じルーター）で赤を確かめる（陽性対照C6）
  - 前提: 1
  - 1.15.0の出し元を確かめる: 1.15.0（build 113）のarchiveの出し元は `08023ea7`（public-launch 12.1の結果。design.mdのF1も2026-10-18のタスクの承認のときに `9a56d5e8` から直した）。`git log --oneline 08023ea7..HEAD -- <SoratomoSkyService.swift・SoratomoModels.swift・SoratomoRouter.swift・GoldenHourNotificationManager.swift・project.pbxproj>` が空であることを確かめ、今のルーターが1.15.0のルーターと同じであることを結果に書く（空でなければ、`08023ea7` のルーターを写して同じテストを流す）
  - `SoratomoRouterTests` にテストを足す。今のAPIだけで書く（`receive(userInfo:)` に `["type": "soratomoReaction", "groupId": …, "postId": …]` を渡し、`resolvePending` → `reportAccessible` の後の `path` と、記録したイベントの名前とパラメータの文字列を見る）ので、今の現物でコンパイルできる
    - 期待: 一覧の上にそのグループのタイムラインが開き、`soratomo_notification_opened` が `type` = `reaction`・`result` = `opened` で1回記録される。起動していない状態からのタップ（保留→判定→表示）も同じ。抜けたグループ・未ログイン・匿名では、`soratomoPost` と同じ扱い（開かない・その結果で1回記録）
    - 既存の `soratomoPost` のテストは変えない（`post_created` のまま）
  - テストだけを足した作業ツリー（コミットしない）で、今の現物で流す。そのときの `HEAD` とテストのファイルの shasum の頭を結果に書く。新しいテストが「`path` が空・記録が0件」で赤になることを記録する。これは、1.15.0のアプリがリアクションの通知をタップされても、落ちず、遷移せず、新着投稿として記録しないことの証拠でもある
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 11.4, 11.5, 15.5_
  - 結果（2026-10-21 01:02）: 着手の前に `git fetch -q origin` をした。`origin/main` が #192（`2cbc5645`・ブロックまわりのアプリの直し）の1つだけ進んでいたので、マージで取り込んだ（`df32776b`）。この枝の変更とファイルが重ならず、衝突は無かった。その作業ツリーで `SoratomoRouterTests.swift` に7本を足し（コミットしない）、今の現物で流した
    - 1.15.0の出し元: 5ファイルの `git log --oneline 08023ea7..HEAD` は空でなかった。出たのはこのspecの7.1（`c63fa2d1`・`SoratomoModels.swift`）と7.2（`41035868`・`SoratomoSkyService.swift`）だけで、どちらも `parse`・`receive` に触れていない
    - `git diff 08023ea7 HEAD` は、`SoratomoRouter.swift`・`GoldenHourNotificationManager.swift`・`SoratomoAnalytics.swift`・`project.pbxproj`・`SoratomoRouterTests.swift` で差分が0だった。`SoramoyouApp.swift` は #188（`97c34a43`）の2か所だけが変わっていた（テストのときだけ接続先をEmulatorにする切り替えと、DEBUGだけの見えない目印）。通知のデリゲートの配線は変わっていない。そこで、今のルーターは1.15.0のルーターと同じと判断し、`08023ea7` のルーターを写さずに今の現物で流した
    - 足したテスト（7本）: 赤を取るのは6本。`testParse_readsReactionPayload`（読めて `groupId`・`postId` が合う）と `testReactionTap_` の5本で、5本は開いて読めたら `opened`・冷えた起動（判定の前とWhat's Newの間は保留、表示できたら開く）・抜けたグループで `not_member`・未ログインで `signed_out`・匿名で `flag_off` を見る。どれも記録は `type` = `reaction` で1回だけ
    - 残りの1本 `testPostTap_logsPostCreatedOpenedWithSameComparison` は対照で、同じ比べ方で `soratomoPost` が `post_created` の `opened` になることを見る（今の現物でも緑）。赤が「比べ方が壊れている」せいでないことを確かめるため。既存の `soratomoPost` のテストは変えていない
    - 書き方: 今のAPIだけで書いた。記録はイベントの値でなく、`name` と `parameters` の文字列で比べる（テストの中の `SentEvent`）。保留は値で比べず `XCTAssertNotNil` にした（7.4で種類が付くと、`SoratomoNotificationPayload(groupId:postId:)` と等しくならないため）。そのため、赤はコンパイルのエラーでなく期待外れで取れている
    - 赤（陽性対照C6）: iPhone 17e `885A74C7` で `-only-testing:SoramoyouTests/SoratomoRouterTests` を流した（`nice -n 19`・`-jobs 4`・`-parallel-testing-enabled NO`・`-test-timeouts-enabled YES`）。xcresultで59本・53合格・6失敗。失敗の6本は足した赤の6本そのもので、対照の1本と既存の52本は緑
    - 失敗のassertは16個（ログの「16 failures」と一致）。`parse` が nil で3・開くテストが `isPresented` 偽と `path` が `[]` と記録が `[]` で3・冷えた起動が4・抜けたグループが4・未ログインと匿名が記録 `[]` で1ずつ。どれも「`path` が空・記録が0件（`parse` は nil）」の形で、1.15.0のアプリがリアクションの通知をタップされても、遷移せず、新着投稿として記録しないことの証拠になる（11.4・11.5）
    - テストのファイルの警告は0行（同じ数え方で、ログ全体の警告35行を拾えることも確かめた）。終了コードは65（テストの失敗）
    - 赤の証拠: `HEAD` `df32776b`・`SoratomoRouterTests.swift` の shasum（SHA-256の頭）`69953763ad18`（流す前と後で同じ）・`SoratomoRouter.swift` `e802061b62d2`。このテストのファイルはコミットせず、作業ツリーに残す。7.4で緑にしてから、実装と一緒にコミットする
    - design.md: SoratomoSkyServiceの節の `decodeSky` と `resolveObservedSky` の行に、7.2で足した既定値つきの `path:` を書き足した（7.2の結果の（1）（2）。利用者の決定 2026-10-21）
    - 実行の環境: ビルド・テスト・`pgrep`・`simctl`・xcresultの読み取りは、7.1・7.2と同じくサンドボックスの外で流した。DerivedDataはXcodeの設定（`IDECustomDerivedDataLocation`＝外付けのSSD）のままで、`-derivedDataPath` は渡していない
    - 負荷: 流す前に、ほかのセッションの `xcodebuild`（followersのworktreeの `test-without-building`・別の端末）が動いていたので、終わるのを待った。その直後に1分平均が90.51に跳ねたので、40を切る（36.53）まで待ってから流した。テストは00:52ごろに終わったが、xcodebuildが抜けたのは01:02だった（gRPCの後始末の待ち。止めずに自分で抜けた）

- [x] 7.4 ルーターと計測に、リアクションの通知と4つのイベントを足す（陽性対照C6・要確認Q6の反映）
  - 前提: 7.1, 7.3
  - `SoratomoRouter.swift`: `SoratomoNotificationKind`（`post`・`reaction`）と `reactionTypeValue = "soratomoReaction"` を足し、`parse` は2つの `type` で、`groupId` と `postId` が揃うときだけ返す。結果待ちを、グループIDと種類の組にする。記録は `.notificationOpened(result, type: kind.analyticsType)`。`signed_out`・`flag_off`・抜けたグループも同じ種類で記録する。`soratomoPost` の振る舞いと記録は変えない
  - `SoratomoAnalytics.swift`: design.mdの形で `SoratomoNotificationOpenType`・`SoratomoReactionFailAction`・`SoratomoReactionFailReason`（`init(_ error:)` の写し）と、`reactionAdded`・`reactionRemoved`・`reactionFailed`・`reactionsViewed` を足す。`notificationOpened` に `type`（既定は `.postCreated`）を足し、パラメータの `type` を `type.rawValue` にする。イベントの数のコメントに、このspecの4個を足す
  - 1.3（Q6）で数えた `notificationOpened` のパターンの一致を、値つきの形に直す
  - パラメータは列挙の値と数と真偽値だけにし、uid・グループID・投稿ID・名前・キャプション・招待コードが型の上で入らない
  - `SoratomoAnalyticsTests`: 4つのイベントの名前とパラメータ（`kind` は名前・`source` は `timeline`/`detail`・`replaced`・`action`・`reason`・`reaction_count`）・失敗の理由の写し方・`notificationOpened` の `type`（`post_created`・`reaction`）・名前とパラメータ名が英小文字のスネークケース。`SoratomoRouterTests`: 7.3で足したテストが緑になる
  - 陽性対照（C6）: 7.3で赤だったテストが、この変更で緑になったことを並べて記録する。イベントのパラメータ名を1つ変えた写しで計測のテストが、`parse` が `soratomoReaction` を `post` として返す写しで種類のテストが、それぞれ赤になることも確かめる
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 11.5, 15.1, 15.2, 15.3, 15.4, 15.5_
  - 結果（2026-10-21 01:56）: `HEAD` `381f1e4c`（着手の前に `git fetch -q origin` をして、`HEAD..origin/main` が空であることを確かめた。取り込みなし）の作業ツリーで、アプリ2ファイル・テスト2ファイルを直した。コードとテストはサブエージェント（触ってよいファイルの一覧・Editだけ・Editのたびに `git diff`・xcodebuildとコミットはしない、の約束）が書き、メインが差分を読んで、予定の範囲に収まっていることを確かめた。7.5と並行で書いたので、緑は7.5の作業ツリーと同じビルドで流した
    - `SoratomoRouter.swift`: `SoratomoNotificationKind`（`post`・`reaction`。`analyticsType` で `.postCreated`・`.reaction` に写す）と `reactionTypeValue = "soratomoReaction"` を足した。`SoratomoNotificationPayload` に既定値 `.post` の `kind` を足したので、`SoratomoNotificationPayload(groupId:postId:)` はそのまま新着投稿になる。`parse` は、`type` が2つの値のどちらかと完全に一致し、`groupId` と `postId` が既存の `isUsableId` を通るときだけ返す。結果待ちを `awaitingGroupId` から、グループIDと種類の組の `awaiting` にした。記録の5か所（`not_member`・`opened` の2つの道・`signed_out`・`flag_off`）は、どれも `.notificationOpened(result, type: kind.analyticsType)` にした。`soratomoPost` の行き先・保留・結果待ち・記録の回数は変えていない
    - `SoratomoAnalytics.swift`: `SoratomoNotificationOpenType`・`SoratomoReactionFailAction`・`SoratomoReactionFailReason`（`init(_ error:)` は `.network`→`network`・`.skyGone`→`not_found`・`.notMember`→`not_member`・`.suspended`→`suspended`・ほかは `unknown`。`offline` は失敗の種類から作らない）と、4つのイベントを足した。`notificationOpened` に既定値 `.postCreated` の `type` を足した。イベントの数のコメントに、このspecの4個を足した
    - テスト: `SoratomoAnalyticsTests` に4本を足した（4つのイベントの名前とパラメータ・7種類の `kind` が名前の文字列になる・`notificationOpened` の `type`・失敗の理由の写し方）。既存の2本（スネークケース・列挙の値）の対象に、新しい表と3つの列挙を加えた。`SoratomoRouterTests` には新しいテストを足していない。`testParse_readsSoratomoPayload` に `kind == .post`、`testParse_readsReactionPayload` に `kind == .reaction` の assert を足し、後者の説明の1行を直した
    - 7.3のテストが変わっていないこと: 今の `SoratomoRouterTests.swift` を scratchpad に写し、上の3か所（assert 2つとその説明の1行・直した説明の1行）だけを元に戻した写しの shasum の頭が、7.3の赤の証拠の `69953763ad18` と一致した。7.3で足した7本のほかの部分は変わっていない
    - 緑: iPhone 17e `885A74C7` で、`-only-testing` に `SoratomoRouterTests`・`SoratomoAnalyticsTests`・`SoratomoReactionServiceTests`（7.5）の3クラスを渡した1回の `test` を流した（`nice -n 19`・`-jobs 4`・`-parallel-testing-enabled NO`・`-test-timeouts-enabled YES`）。xcresultで90本・90合格・0失敗だった。内訳は `SoratomoRouterTests` 59本（7.3の59本のまま）・`SoratomoAnalyticsTests` 17本（`HEAD` の13本に4本）・`SoratomoReactionServiceTests` 14本（7.5の結果）。触った8ファイル（7.5の4ファイルを含む）がすべてコンパイルされ、その警告・エラーは0行（同じ数え方で、ログ全体の警告45行を拾えることも確かめた）
    - 陽性対照（C6）の緑: 7.3で赤だった6本が、すべて緑になった。`testParse_readsReactionPayload`・`testReactionTap_opensTimelineAndLogsReactionOpenedOnce`・`testReactionTap_fromColdStartWaitsThenOpensTimelineAndLogsOnce`・`testReactionTap_leftGroupDoesNotOpenTimelineAndLogsReactionNotMember`・`testReactionTap_signedOutDiscardsAndLogsReactionSignedOut`・`testReactionTap_anonymousDiscardsAndLogsReactionFlagOff`。対照の `testPostTap_logsPostCreatedOpenedWithSameComparison` と既存の52本も緑
    - 陽性対照（パラメータ名）: 作業ツリーの本物の `SoratomoAnalytics.swift` の `"reaction_count"` を Edit で `"reactions_count"` にし、`-only-testing:SoramoyouTests/SoratomoAnalyticsTests` を流した。17本のうち赤は `testReactionEventsHaveFixedNamesAndParameters` の1本だけ（assert 1つ。`soratomo_reactions_viewed` のパラメータが表と違う）。ほかの16本は緑。逆の Edit で戻し、shasum が控え（頭 `dc9478735960`）と一致した
    - 陽性対照（種類）: 本物の `SoratomoRouter.swift` の `notificationKind(ofType:)` で `soratomoReaction` を `.post` として返すように Edit で変え、`-only-testing:SoramoyouTests/SoratomoRouterTests` を流した。59本のうち赤は6本で、7.3で赤だった6本と同じ（assert 7つ。`kind` が `.post`・記録の `type` が `post_created`）。対照の1本とほかの52本は緑。逆の Edit で戻し、shasum が控え（頭 `3867a18052ac`）と一致した
    - 要確認Q6の反映（1.3の一覧のとおり）: `SoratomoAnalytics.swift` の `case let .notificationOpened(result):`（1.3では353行）を `case let .notificationOpened(result, type):` にした。`case .notificationOpened:`（1.3では314行・値を束ねない）は直していない。値を作る側のアプリの5か所は、どれも種類を渡す形にした。テストの値の比較30か所は字面を変えておらず、既定値 `.postCreated` で `post_created` のまま通ることを、このビルドと緑で確かめた
    - design.mdに書いていなかったことを、次のとおり決めた（どれも後で変えられる）。（1）結果待ちの名前を `awaiting`（名前つきのタプル）にした。（2）`discardPending` に保留の行き先を引数で渡す（記録の種類を、保留していたタップから取るため）。（3）`SoratomoNotificationKind` を型の一番上の階層に置き、`Equatable, Sendable` にした（`SoratomoNotificationPayload` に合わせた）。（4）種類の写しの関数名を `notificationKind(ofType:)` にした（`parse` の中の `let kind` とプロパティの `kind` と名前がぶつからないように）。（5）次の通知で前の結果待ちを `opened` に確定するときは、前のタップの種類で記録する
    - テストの無い道（新しいテストを足さない約束のため・足すかは後で決める）: リアクションの通知で、タイムラインが読めなかったとき（`reportNotAccessible`）。リアクションの結果待ちを、閉じる・入口から開き直す・次の通知で置き換える、で決めるとき（`settleAwaitingAsOpened`）。新着投稿の結果待ちが残ったままリアクションの通知が来て、前の分が `post_created` で記録されるとき
    - 整形のフック: 作業の途中で、フックが `SoratomoRouter.swift` の `belongsTo` の4行を整形した（`case let .timeline(groupId), …` の形と、`return` を省いた switch 式。意味は同じ）。利用者が受け入れた（2026-10-21）ので戻していない。ほかの3ファイルに巻き込みはない
    - 古くなったコメント: `GoldenHourNotificationManager.swift:250` の「ルーターは type が soratomoPost のものだけを保留にし」は、この変更で古くなった。利用者の決定（2026-10-21）で今回は直さず、ここに記録だけする。直すのは8.xか11のときに相談する
    - shasum の頭（コミットするもの）: `SoratomoRouter.swift` `3867a18052ac`・`SoratomoAnalytics.swift` `dc9478735960`・`SoratomoRouterTests.swift` `f87d93243eb3`・`SoratomoAnalyticsTests.swift` `a697294edaab`
    - 実行の環境: ビルド・テスト・`pgrep`・`simctl`・xcresultの読み取りは、7.1〜7.3と同じくサンドボックスの外で流した。DerivedDataはXcodeの設定のままで、`-derivedDataPath` は渡していない。負荷を見るフックが2回、流す前に止めた（1分平均48・スワップ8.0G、と、負荷123・スワップ8.1G）。どちらも押し切らず、1分平均が40を切るまで（2回目は、あわせて5分平均が80を切るまで）待ってから流した。種類の陽性対照の回は、テストが01:45に終わり、xcodebuildが抜けたのは01:55だった（gRPCの後始末の待ち。止めずに自分で抜けた）

- [x] 7.5 リアクションのサービス `SoratomoReactionService` を作る
  - 前提: 1.2（要確認Q3の結果の契約）, 7.1
  - `SoratomoServiceContracts.swift` に、design.mdの形で `SoratomoReactionOutcome`・`SoratomoReactionChange`・`SoratomoReactionServiceProtocol`・`SoratomoReactionDataSource` を置く。既存の `SoratomoSkyServiceProtocol` にはメソッドを足さない
  - `Services/SoratomoReactionService.swift`（新規）: Callable `soratomoSetReaction`、制限時間は既存の `SoratomoGroupService.callTimeout`。送る値は `groupId`・`skyId`・`kind`（外すときは1.2の結果の形）。失敗は `SoratomoGroupService.mapCallableError` で写す（`not_member`→`.notMember`・`sky_not_found`→`.skyGone`・`suspended`→`.suspended`・通信と制限時間切れ→`.network`。`self_reaction`・`invalid_reaction`・`invalid_input` は種類を作らず `.unknown`）。戻り値の形が違うときは失敗にせず、`SoratomoError.record`（固定の文脈）に残し、`outcome: .unchanged` と送った `kind` で返す
  - テスト用のモックは、`SoratomoServiceMocks.swift` に新しいクラスとして足す。`SoratomoReactionServiceTests`（新規・DataSourceのモック）: 送る値（名前・外す形）・応答の読み方・失敗の写し方（`not_member`・`sky_not_found`・`suspended`・`self_reaction`・通信）・形の違い
  - 陽性対照: 外すときの形を1.2の結果と違う形にした写しで送る値のテストが、`sky_not_found` を `.unknown` に写す写しで写し方のテストが、それぞれ赤になることを先に確かめる
  - _Requirements: 1.3, 1.4, 1.5, 4.15, 10.4, 10.7_
  - 結果（2026-10-21 02:14）: 7.4と同じ作業ツリー（`HEAD` `381f1e4c`）で、アプリ2ファイル・テスト2ファイルを書いた。コードとテストは7.4と並行で、サブエージェントが7.4と同じ約束で書き、メインが現物を読んで確かめた。緑は7.4と同じ1回の `test` で流し、7.4をコミット（`31276f3`）した後に陽性対照を流した
    - `SoratomoServiceContracts.swift`（末尾）: `SoratomoReactionOutcome`（`added`・`replaced`・`removed`・`unchanged`）・`SoratomoReactionChange`（`outcome` と書いた後の `kind`）・`SoratomoReactionServiceProtocol`（`setReaction(groupId:skyId:kind:) async throws(SoratomoError)`）・`SoratomoReactionDataSource`（`callCallable(_:payload:timeout:)`）を置いた。`SoratomoSkyServiceProtocol` にはメソッドを足していない
    - `Services/SoratomoReactionService.swift`（新規）: Callable `soratomoSetReaction`・制限時間は `SoratomoGroupService.callTimeout`（20秒）・region は `SoratomoGroupService.region`。送る値は `groupId`・`skyId`・`kind` の3つで、外すときは `kind` の鍵を残して値を `NSNull()` にする（1.2の結果の形）。失敗は `SoratomoGroupService.mapCallableError` で写して投げる。戻り値の形が違うときは投げず、`SoratomoError.record`（文脈 `soratomo.setReaction.response`・IDを持たない固定のエラー）に残し、`outcome: .unchanged` と送った `kind` で返す
    - `SoratomoServiceMocks.swift`（末尾）: `MockSoratomoReactionService`（返す結果・呼ばれる前に流す処理・呼ばれた引数）を新しいクラスとして足した
    - `SoratomoReactionServiceTests`（新規・14本）: 窓口の偽物（`FakeReactionDataSource`）で、送る値（Callableの名前と20秒・付けるときの3つの値・7種類の名前・外すときの鍵と `NSNull`）・応答の読み方（`added`・`replaced`・`unchanged` と名前、`removed` と `unchanged` と null）・失敗の写し方（`not_member`→`.notMember`・`sky_not_found`→`.skyGone`・`suspended`→`.suspended`、`self_reaction`・`invalid_reaction`・`invalid_input`→`.unknown`、`unavailable`・`deadlineExceeded`・`NSURLErrorNotConnectedToInternet`・`NSURLErrorTimedOut`→`.network`、失敗では結果を返さない）・形の違い（8通りで `.unchanged` と送った `kind`・外すときは `nil`）・応答を読む純関数を見る。期待値は実装から組み立てず、文字列と値を直に書いた
    - 緑: 7.4の結果の「緑」の1回（iPhone 17e `885A74C7`・90本・90合格）のうち、`SoratomoReactionServiceTests` は14本・14合格・0失敗。4ファイルがすべてコンパイルされ、その警告・エラーは0行（数え方は7.4の結果と同じ）
    - 陽性対照（送る値）: 作業ツリーの本物の `payload` を Edit で、`kind` が nil のとき鍵を省く形に変え、`-only-testing:SoramoyouTests/SoratomoReactionServiceTests` を流した。14本のうち赤は `testSendsNullKindWithKeyWhenRemoving` の1本だけ（assert 3つ。鍵が無い・値が `NSNull` でない・項目が2つ）。ほかの13本は緑。逆の Edit で戻し、shasum が控え（頭 `37ed94538732`）と一致した
    - 陽性対照（写し方）: 本物の `setReaction` の catch で、写した `.skyGone` を `.unknown` に置き換える1行を Edit で足し、同じく流した。14本のうち赤は `testMapsDomainFailures` の1本だけ（assert 1つ。`sky_not_found` が `.skyGone` でなく `.unknown`）。ほかの13本は緑。逆の Edit で戻し、shasum が控えと一致した。共用の `mapCallableError` は壊していない（ほかのサービスのテストに響かないように）
    - design.mdに書いていなかったことを、次のとおり決めた（どれも後で変えられる）。（1）失敗の記録は、design 798行と手本の `SoratomoGuidelineService` に合わせ、写した結果が `.unknown` か `.permissionDenied` のときだけ、元のエラーを文脈 `soratomo.setReaction` で `SoratomoError.record` に残す。（2）形の違いの記録には、IDも中身も持たない非公開の `SoratomoReactionFailure.malformedResponse` を使う（要件14.1）。（3）送る値と応答の読み方は、テストで直に見られるように `static` の純関数 `payload(groupId:skyId:kind:)`・`change(from:)` にした。（4）本物の窓口 `SoratomoReactionFirebaseDataSource` は状態を持たず、呼ばれるたびに `Functions` を引く（単体テストで作っても Firebase に触れない）。（5）応答の `kind` の鍵が無いときは、形の違いとして扱う（null は `NSNull` として鍵ごと残るため、区別できる）
    - 確かめていないこと: `SoratomoError.record` が呼ばれること・呼ばれないことは、テストで見ていない（記録の差し替え口が無いため）。配備した関数やエミュレーターへ実際に送るのは、13.1の通しで見る
    - 7.6への持ち越し: このサービスが `.unknown` を元のエラーで記録するので、7.6のdesign（「`.unknown` なら `SoratomoError.record`」）のままViewModelでも記録すると二重になる。7.6の着手の前に利用者に相談する
    - shasum の頭（コミットするもの）: `SoratomoServiceContracts.swift` `cdf8895c7f26`・`SoratomoReactionService.swift` `37ed94538732`・`SoratomoServiceMocks.swift` `5d5bc50b8d83`・`SoratomoReactionServiceTests.swift` `31a668026264`
    - 実行の環境: 7.4の結果と同じ。負荷を見るフックが、2回の陽性対照の前にそれぞれ止めた（負荷80・メモリ逼迫・スワップ8.9G・ほかのセッションのシミュレーター331%、と、負荷193・スワップ8.9G・Spotlight 161%）。どちらも押し切らず、1分平均が40を切り、5分平均が80を切るまで待ってから流した。起動中のiOSのシミュレーターは0台で、331%はこのセッションの端末ではなかった

- [x] 7.6 リアクションの操作の状態 `SoratomoReactionViewModel` を作る
  - 前提: 7.4, 7.5
  - `ViewModels/SoratomoReactionViewModel.swift`（新規）: design.mdの形で、`overlays`・`notice`・`canReact`・`isSending`・`summary(for:server:)`・`choose(_:for:server:source:)`・`didOpenReactors(count:)` と `SoratomoReactionNotice` を作る。依存はinitで受け取る（`groupId`・リアクションのサービス・`SoratomoBlockedAuthors`・`currentUid`・`isOnline`・`onSkyGone`・確定の上書きを手放すまでの時間・`sleep`・`logEvent`）
  - `choose`: 操作を出してよくない・送っている間は何もしない→同じ絵文字なら外す・違えば付ける→通信が無ければ送らずに通信の文言と `soratomo_reaction_failed`（`offline`）→上書きを `.sending` で入れて送る→成功なら `.confirmed` にして10秒後に同じ札のときだけ消し、`added`・`replaced`・`removed` を記録→失敗なら上書きをすぐ消し、文言を出し、`.skyGone` なら `onSkyGone`、`soratomo_reaction_failed` を記録（`.unknown` でも `SoratomoError.record` は呼ばない。想定外の記録は7.5のサービスの1か所だけ・利用者の決定・2026-10-21）
  - D3の読み方（承認済み）: サーバーが `unchanged` を返したときは、`soratomo_reaction_added`・`soratomo_reaction_removed` を記録しない
  - `SoratomoBlockedAuthors` の `$ids` を購読し、変わったら `objectWillChange` を送る（ブロックの保存で、手動で更新しなくても数が変わる）
  - 文言はdesign.mdの表のとおり（内部のエラーコードを出さない・利用停止は既存の停止とお問い合わせの文言）。端末に操作を積まない
  - `SoratomoReactionViewModelTests`（新規）: オフラインでは呼ばない（`offline`）・送っている間は重ねない・自分の投稿とログアウト中は `canReact` が偽・同じ絵文字で外す/違う絵文字で付ける・成功の記録（`added`・`replaced`・`removed`、`unchanged` は記録しない）・失敗で上書きを戻す・各失敗の文言と理由・`skyGone` で `onSkyGone`・`.unknown` は文言と理由 `unknown` だけ（記録はサービスの1か所で、ViewModelは呼ばない。記録の差し替え口が無いのでテストでは見ず、ViewModelのファイルに `SoratomoError.record` が0件であることを grep で確かめる・利用者の決定・2026-10-21）・上書きは10秒後（差し替えた `sleep`）に消え、新しい上書きは消さない・ブロックの変化で `objectWillChange`・計測の値に名前やIDが入らない
  - 陽性対照: 失敗で上書きを戻さない写しで「失敗で戻す」が、札を見ずに10秒後に消す写しで「新しい上書きは消さない」が、`unchanged` でも記録する写しでD3のテストが、オフラインでも呼ぶ写しでオフラインのテストが、それぞれ赤になることを先に確かめる
  - _Requirements: 1.3, 1.4, 1.5, 1.6, 1.9, 1.10, 2.6, 5.2, 8.8, 10.1, 10.2, 10.3, 10.4, 10.5, 10.7, 14.1, 15.1, 15.3_
  - 結果（2026-10-21 07:21）: 7.5の作業ツリー（`HEAD` `72394b64`）で、アプリ1ファイル・テスト1ファイルを新しく書いた。コードとテストは、同じ契約（`.claude/handoffs/2026-10-21-soratomo-reactions-7-6-契約.md`）を読んだサブエージェント2人が並行で書き、メインが現物を読んで契約と突き合わせた
    - `ViewModels/SoratomoReactionViewModel.swift`（新規・367行）: design.mdの形で、ファイルの上のほうに `SoratomoReactionNotice`、その下に `SoratomoReactionViewModel` を置いた。`choose` は、出してよくない・送っている間は何もしない→上書きを反映した自分の絵文字と同じなら外す（`kind: nil`・`action: remove`）、違えば付ける・選び直す（`action: add`）→通信が無ければ送らずに `notice = .failed(.network)` と `reason: offline`→札を作って `.sending` の上書きを入れる→`setReaction`（送るグループIDはViewModelの `groupId`）→成功なら応答の `kind` で `.confirmed` にし、10秒後に札が同じときだけ手放す→失敗なら札が同じときだけ上書きを消し、文言・`.skyGone` なら `onSkyGone`・`soratomo_reaction_failed`。ブロックの購読はタイムラインと同じ形（`dropFirst`・`receive(on:)` なし・`MainActor.assumeIsolated`）
    - `SoratomoError.record` の数（利用者の決定・2026-10-21）: ViewModelのファイルで、`grep -c "SoratomoError.record"` も呼び出しの形の `grep -c "SoratomoError\.record("` も0件。陽性対照として、呼び出しの形の grep をサービス（`Services/SoratomoReactionService.swift`）に掛けると2件（69・78行）。素の形だとサービスは13行目のコメントも拾って3件になるので、呼び出しの数は呼び出しの形で数えた
    - `SoratomoReactionViewModelTests`（新規・787行・29本）: `canReact`（相手の投稿だけ真・自分の投稿・nil・空文字は偽、偽のときの `choose` は呼ばない・記録0・知らせなし・上書きなし）・オフライン（付ける `add`・外す `remove`）・送っている間は重ねない・同じ絵文字で外す／違う絵文字で付ける／確定の上書きを反映して外す・送っている間の表示と応答の `kind` での確定・成功の記録（`added`・`replaced`・`removed`）・D3（`unchanged` で記録なし。1回送ったことと `.confirmed` も同じテストで見る）・失敗で戻す（付ける・外す）・失敗の文言と理由（`network`・`not_found`・`not_member`・`suspended`・`unknown`・`permissionDenied`→`unknown` を、選び直しと外すの両方で）・4種類以外のすべての `SoratomoError` の文言・`skyGone` で `onSkyGone` を1回・ほかの失敗では呼ばない・10秒後の手放し（`[10_000_000_000]`）・新しい上書きは消さない・ブロックの変化で `objectWillChange`・`didOpenReactors`・計測の値にIDが入らない。期待値は実装から組み立てず、文字列と値を直に書いた。sleepは門（`SleepGate`）で、サービスは門（`ServiceGate`）で止める
    - 緑: iPhone 17e `885A74C7` で、`-only-testing:SoramoyouTests/SoratomoReactionViewModelTests` を流した（`nice -n 19`・`-jobs 4`・`-parallel-testing-enabled NO`・`-test-timeouts-enabled YES`）。xcresultで29本・29合格・0失敗だった。ViewModelは先に流したアプリだけの `build` で、テストはこの回でコンパイルされ、2ファイルの警告・エラーは0行（同じ数え方で、ログ全体の既存の警告6行（`FirestoreServiceTests`・`StorageServiceTests`・リンカ）を拾えることも確かめた）
    - 陽性対照（失敗で戻す）: 作業ツリーの本物の `fail` で、札が同じときに上書きを消す3行を Edit で外して流した。29本のうち赤は3本で、`testFailureRestoresServerStateRightAway`・`testRemovalFailureRestoresMyReaction`（上書きが `.sending` のまま残る）と `testAnalyticsValuesCarryNoIdsAndKindIsName`（残った `.sending` で後の操作が捨てられ、記録の並びが違う）。ほかの26本は緑
    - 陽性対照（新しい上書きは消さない）: 本物の `releaseConfirmed` の札の `guard` を Edit で外して流した。赤は `testOlderExpiryDoesNotRemoveNewerOverlay` の1本だけ（1本目の手放しが虹の上書きを消して nil になる）。テストは止まらずに終わった。ほかの28本は緑
    - 陽性対照（D3）: 本物の `confirm` の `case .added, .replaced:` に `.unchanged` を足して流した。赤は `testUnchangedOutcomeLogsNothing` の1本だけ（`events` が空でない）。ほかの28本は緑
    - 陽性対照（オフライン）: 本物の `choose` の通信の確認を `guard isOnline() || true` にして流した。赤は3本で、`testOfflineAddDoesNotSendAndLogsOffline`・`testOfflineRemoveLogsRemoveAction`（`setReactionCalls` が空でない）と `testAnalyticsValuesCarryNoIdsAndKindIsName`（`offline` の代わりに送った結果が記録される）。ほかの26本は緑
    - 4つとも、緑の前にViewModelとテストを scratchpad に写して shasum を控え、壊すたびに `diff -u`（ViewModelは未追跡なので `git diff` には出ない）で壊した1か所だけが違うことを見て、毎回ビルドからやり直した。逆の Edit で戻すたびに `diff -u` が空で、shasum が控え（頭 `320c223abc31`）と一致した。テストのファイルは一度も触っておらず、shasum は控え（頭 `28d86870e9b0`）のまま
    - design.mdに書いていなかったことを、契約で次のとおり決めた（どれも後で変えられる）。（1）確定の上書きを手放すタスクを `expiryTasks: [String: Task<Void, Never>]` で公開する（単体テストで完了を待つため・タイムラインの `imageCleanupTask` の前例）。（2）成功のときは札を変えず、上書きの値は応答の `change.kind` にする。（3）記録の `kind` は `change.kind ?? 送ったkind`（両方 nil なら記録しない）。（4）失敗の `action` は外すなら `remove`、それ以外（選び直しも）は `add`。（5）送るグループIDはViewModelの `groupId`。（6）`currentUid()` が nil か空文字ならログアウト中として扱う
    - 要件10.7: 「記録に残し、アプリを落とさない」の2本立てで、後半はViewModelにも残るので、この節の `_Requirements:` と design.md 354・806行の10.7は外していない。design.md 138行（対応表）と865行（失敗の手順6）は、利用者の決定に合わせて書き直した。design.md 1031行の「記録に残す（10.7）」は記録の場所を言っていないので、そのままにした
    - テストの担当が契約の文面から変えたところ（どれも契約の意図の範囲）: ブロックの変化のテストでブロックする相手を、投稿者でなく第三者（`uid-friend-m4t6`）にした（投稿者をブロックすると投稿ごと隠れる場面になるため）。サービスの門は続きを配列で持つ（2回目を受け付けてしまう実装でも止まらずに赤にするため）。失敗の文言に `testNoticeMessageForOtherErrorsIsGenericReactionMessage` を1本足した
    - 確かめていないこと: ViewModelが `SoratomoError.record` を呼ばないことは、テストでは見ていない（記録の差し替え口が無いため。上の grep で確かめた）。画面への配線と実機は8.xで見る
    - 整形のフック: テストの担当が書いた行のうち3行（`.map { $0.kind }`→`.map(\.kind)` を2か所、`.flatMap { $0.parameters.values }`→`.flatMap(\.parameters.values)` を1か所）を書き換えた。意味は同じで、ほかのファイルとViewModelに巻き込みはない
    - shasum の頭（コミットするもの）: `SoratomoReactionViewModel.swift` `320c223abc31`・`SoratomoReactionViewModelTests.swift` `28d86870e9b0`
    - 実行の環境: ビルド・テスト・`pgrep`・`simctl`・xcresultの読み取りは、サンドボックスの外で流した。DerivedDataはXcodeの設定のままで、`-derivedDataPath` は渡していない。負荷を見るフックが3回、流す前に止めた（負荷101・スワップ7.3G、と、負荷161・スワップ7.2G、と、負荷109・Spotlight 68%）。どれも押し切らず、1分平均が40を切り、5分平均が80を切るまで待ってから流した。失敗で戻す回とオフラインの回は、始めてから抜けるまで約12分かかった（ほかの回は2〜3分）

## (h) iOS: 画面と配線

- [ ] 8. iOSの画面を変える

- [x] 8.1 リアクションの部品の画面（数の表示・メニュー・押した人の一覧）を作る
  - 前提: 7.1, 7.6
  - `Views/Soratomo/SoratomoReactionViews.swift`（新規）に、design.mdの「リアクションの部品の画面」のとおり3つを作る
    - `SoratomoReactionSummaryView`: 絵文字と数のカプセルを、絵文字の並び順に並べる（押せない）。自分の絵文字は色付きの枠と太字。0件なら何も出さない。VoiceOverでは `summary.accessibilityLabel` の1つの要素
    - `SoratomoReactionMenuButton`: `Menu` の中に7つのボタン（「{絵文字} {日本語名}」・いまの絵文字に `checkmark`）。見た目は、付けていなければ `face.smiling`、付けていればその絵文字。押せる範囲は44pt四方以上。VoiceOverのラベル（「リアクションを付ける」か「リアクションを変える。いまは{日本語名}」）とヒント（「同じ絵文字をもう一度選ぶと外れます」）。項目は日本語名で読み、いまの絵文字に `isSelected`。送っている間は無効
    - `SoratomoReactorsSheet`: 行は `UserAvatarView`・表示名・絵文字（表示名とアイコンは `SoratomoProfileStore` から出し、未設定と未取得はメンバー一覧と同じ代替）。開いたときに `prefetch`。行はVoiceOverで「{表示名}、{日本語名}」の1つの要素。ほかの人の分を外す・変える操作を置かない。題は「リアクション（{人数}人）」・右上に「閉じる」。中身を1件も読めていないときは「リアクションを読み込めませんでした」、開いている間に投稿が消えた・グループから外れたら「この投稿は表示できなくなりました」
  - シートは新しい画面にしない（ルーターの行き先と、画面名の計測 `logScreen` を足さない）。開いたことは `soratomo_reactions_viewed` で記録する（記録を呼ぶのは8.3）
  - ビルドが通り、Previewで3つの見た目（0件・自分の印あり・一覧の代替表示）を確かめる
  - _Requirements: 1.2, 2.1, 2.2, 2.3, 3.2, 3.3, 3.4, 3.7, 3.8, 8.7, 13.1, 13.2, 13.3, 13.5, 15.6_
  - 結果（2026-10-21 07:55）: 7.6の作業ツリー（`HEAD` `5dba27d9`）で、アプリ1ファイルを新しく書いた（サブエージェントは使っていない）。着手前に `git fetch` し、`HEAD..origin/main` は空だった
    - `Views/Soratomo/SoratomoReactionViews.swift`（新規・433行）: 3つの部品と、`#Preview` を5つ（求められた3つと、「一覧（読み込めない）」「一覧（表示できない）」）。部品はViewModelを持たず、7.1の `SoratomoReactionSummary`・`SoratomoReactorEntry`・`SoratomoReactionKind`（`emoji`・`spokenName`）と、7.6の `summary(for:server:)`・`isSending(_:)` の値を引数で受け取る
    - `SoratomoReactionSummaryView(summary:)`: `summary.counts`（並び順のまま・1以上だけ）をカプセルで並べる。折り返しは既存の `FlowLayout`（`Views/PostInfoView.swift:899`）を使った。自分の絵文字は、グループのアイコンの濃い青（`SoratomoGroupIcon` の2色目と同じ値）の枠と太字。`total == 0` なら何も出さない。VoiceOverは `.accessibilityElement(children: .ignore)` と `summary.accessibilityLabel` の1つの要素
    - `SoratomoReactionMenuButton(summary:isSending:onChoose:)`: `onChoose` は同期のクロージャで、`choose` を `Task` で呼ぶのは置く側（8.2・8.3）。項目は `ForEach(SoratomoReactionKind.allCases, id: \.self)` で、いまの絵文字だけ `Label(…, systemImage: "checkmark")`、VoiceOverは日本語名と `isSelected`。見た目は `face.smiling` かいまの絵文字で、`frame(minWidth: 44, minHeight: 44)` と `contentShape`。ラベルとヒントと `.disabled(isSending)` は `Menu` そのものに付けた。ラベルの文は `static func accessibilityLabel(myKind:)`
    - 送っている間の見た目（利用者の決定・2026-10-21）: 1回目の画像で、`.disabled` だけでは、いまの絵文字を出しているボタンが送っている間でも見た目が変わらないと分かった（絵文字は自分の色で描かれ、無効の灰色にならない）。フォロー一覧のボタン（`Views/Components/UserRowComponents.swift:106`）と同じ `.opacity(isSending ? 0.5 : 1)` を足した版を焼き直し、前後の2枚を見比べて、利用者が足した版を選んだ
    - `SoratomoReactorsSheet(entries:isUnavailable:profileStore:)`: `profileStore` はメンバー一覧（`SoratomoMembersView.swift:36-46`）と同じく、明示の `init` で `@ObservedObject` に入れる。`NavigationStack` の中に `.soratomoSkyBackground()`・`.plain` の `List`・行は `.soratomoClearRowBackground()`。「閉じる」は右上（`.navigationBarTrailing`・iOS 16で使える置き場所）で、`@Environment(\.dismiss)` で閉じる。`prefetch` は `.task(id:)`（行の人の uid の集合）で、一覧を出すときだけ呼ぶ。出し分けは `isUnavailable`→「この投稿は表示できなくなりました」、行が0件→「リアクションを読み込めませんでした」、それ以外→一覧
    - 行のVoiceOver: メンバー一覧の行は `.combine` だが、それだと絵文字の字を読むので、ここは `.ignore` と「{表示名}、{日本語名}」（`static func rowAccessibilityLabel(displayName:kind:)`）にした
    - design.mdに書いていなかったことを、次のとおり決めた（どれも後で変えられる）。（1）題の人数は一覧を出しているときだけ。代わりの文を出しているときは「リアクション」だけ（消えた投稿の数を出さない・8.6、読めていないのに「0人」と言わない・3.8）。（2）この引数の形では「0件」と「読めていない」を見分けられないので、行が0件は「読めていない」として扱う（詳細は1人以上のときだけ入口を出す・design.md）
    - 計測: シートは `logScreen` も `didOpenReactors(count:)` も呼ばない（開いたことの記録は8.3の詳細）。ルーターの行き先も足していない
    - ビルド: iPhone 17e `885A74C7` でアプリだけの `build` が通った（07:39:36〜07:40:09）。ログに `SwiftCompile … SoratomoReactionViews.swift` の行があり、このファイルの警告・エラーは0行。同じ数え方で、ほかのファイルの既存の警告（`Services/PaymentService.swift:47`・`GeneratedAssetSymbols.swift:79`）は拾えた。`.opacity` を足した後は、下の焼き直しの回（`test`・07:49:07〜07:51:15）でこのファイルがもう一度コンパイルされ、警告・エラーは0行（既存の警告は12行拾えた）
    - Previewの見た目: 利用者が「私がして見せて」を選んだので、一時のテスト（`SoramoyouTests/SoratomoReactionViewsSnapshotScratch.swift`・コミットしていない・見せた後に消した）で、Previewと同じ値の5つを `885A74C7` の中で `UIHostingController` の窓ごとPNGに焼いた（テストは1本・失敗0）。5枚はメインが先に見てから利用者に送った。0件＝カプセル無しで右に `face.smiling` だけ。自分の印あり＝🌅2だけ青い枠と太字で、🌈1・💙1は枠なし、ボタンは🌅。一覧の代替表示＝題「リアクション（4人）」・右上に「閉じる」・「そら」は名前、表示名が空白だけの人と取れない人は「ユーザー」と人型のアイコン・並びは新しい順。読み込めない・表示できない＝題「リアクション」と真ん中の文
    - 確かめていないこと: Xcodeの Canvas そのものでは見ていない（`#Preview` の本体はビルドでコンパイルされたところまで）。メニューを開いた中身（7つ・`checkmark`）は画像に焼けないので見ていない。VoiceOverの読み上げ（`Menu` の項目で `isSelected` が読まれるか・行の読み上げ）は実機で未確認。画面への配線は8.2・8.3
    - 整形のフック: 本物のファイルは、Writeの前に同じ中身を scratchpad に置き、Writeの後に `diff -u` で比べて差が無かった。`.opacity` の Edit の差分は足した3行だけ。一時のテストはフックが書き換えたが、消したので残っていない
    - shasum の頭（コミットするもの）: `SoratomoReactionViews.swift` `de28ac27e108`
    - 実行の環境: ビルド・テスト・`pgrep`・`simctl` はサンドボックスの外で流した。DerivedDataはXcodeの設定のままで、`-derivedDataPath` は渡していない。負荷を見るフックは1回も止めなかった（流す前の1分平均は3.4〜3.7）

- [x] 8.2 容れ物とタイムラインに、リアクションのViewModelと操作を配線する
  - 前提: 7.2, 8.1
  - `SoratomoDependencies`: `reactionService` を足し、`live` で本物を入れる。`weak var activeReactionViewModel` を足す。`init` の引数が増えるので、組み立てている箇所を `grep -rn "SoratomoDependencies(" Soramoyou` で探して全部直す（`SoratomoDependenciesTests` とPreviewを含む）
  - `SoratomoTimelineView`: ViewModelの組（`makeViewModels`）に `SoratomoReactionViewModel` を足して3つにする（`onSkyGone` は `[weak timeline] in timeline?.removeGoneSky($0)`）。`@StateObject` で持ち、`.task` で `dependencies.activeReactionViewModel` に入れる
  - カード（`row(for:)`）をdesign.mdの形に組み直す。数の表示はカードの `Button` のラベルの中（押すと詳細へ進む）、リアクションのメニューはラベルの外の `overlay(alignment: .bottomTrailing)`（自分以外の投稿だけ）。`contextMenu` は `overlay` より先に付け、中身（削除、または通報とブロック）は変えない。`accessibilityHint("投稿を大きく表示します")` は変えず、`.accessibilityElement(children: .contain)` でカードのボタンとメニューを別の要素にする。自分以外の投稿では、右下のボタンの分の高さと幅を空けておく
  - 隠した投稿（ブロックした投稿者・この端末で通報した投稿）は今までどおり行ごと出ないので、操作も出ない
  - 失敗の知らせ（`reactionViewModel.notice`）は、タイムラインが一番上のときだけ出す（既存の `isShowingModerationNotice` と同じ型）
  - ビルドが通り、`SoratomoDependenciesTests` と `SoratomoTimelineViewModelTests` が通る
  - _Requirements: 1.1, 1.6, 1.7, 1.8, 1.11, 8.8, 12.9, 12.10, 13.4_
  - 結果（2026-10-21 08:35）: 8.1の作業ツリー（`HEAD` `34965367`）で、アプリ2ファイル・テスト1ファイルを Edit で直した（サブエージェントは使っていない）。着手前に `git fetch` し、`HEAD..origin/main` は空だった
    - `SoratomoDependencies`: `reactionService: any SoratomoReactionServiceProtocol`（`leftGroups` の後・`currentUid` の前）と `weak var activeReactionViewModel` を足し、`live` に `SoratomoReactionService()` を入れた。組み立ては `grep -rn "SoratomoDependencies(" Soramoyou` で `live` と `SoratomoDependenciesTests.swift:55` の2か所だけ（design.mdが言うPreviewの組み立ては現物に無い）。テストは `MockSoratomoReactionService()` を1行足しただけで、新しいアサーションは足していない（design 1108の「組み立ての引数」のとおり）
    - `SoratomoTimelineView`: ViewModelの組を3つにした（`ViewModelPair`→`ViewModelSet`・init の取り出しも3つ）。リアクションのViewModelは `onSkyGone: { [weak timeline] in timeline?.removeGoneSky($0) }`・`isOnline` はタイムラインと同じ・`blockedAuthors` と `currentUid` は容れ物から。`.task` で `activeTimelineViewModel` の次に `activeReactionViewModel` を入れる
    - カード（`row(for:)`）: ラベルを `VStack`（行と、数の行）にした。数の行は「自分以外の投稿」か「1件以上」のときだけ置き、自分以外の投稿では右端に44pt四方の空き（`Color.clear`・VoiceOverから隠す）を置いて、数が0件でもボタンの幅と高さを空ける。数の表示（`FlowLayout`）と `Spacer` を並べると幅を半分ずつ分けて早く折り返すので、0件のときだけ `Spacer` にした。修飾子の順は `.buttonStyle(.plain)`→`.soratomoCard()`→`.accessibilityHint`（変えない）→`.contextMenu`（中身は変えない）→`.overlay(alignment: .bottomTrailing)`（`canReact` のときだけメニュー・右と下に14ptの内寄せで空きに重ねる・`onChoose` は `Task` の中で `choose(…, source: .timeline)`）→`.accessibilityElement(children: .contain)`→`.onAppear`（続き読み・変えない）
    - 失敗の知らせ: `isShowingReactionNotice` を `isShowingModerationNotice` と同じ形（`router.path.last == .timeline(groupId:)` だけ）で足した。1回目に既存の修飾子の列の中へ `.alert` を足したら、2回目のビルドで `body` が「型の推論が時間内に終わらない」で落ちた。既存の列は動かさずに `private var timelineBody` へ入れ、リアクションの知らせだけ `body` の側で外から付けた
    - 整形のフック: `SoratomoDependencies` で、引数と代入を別々の Edit で足したら、引数が `reactionService _:` に、代入が `self.` の消えた自己代入にされた（メモの10/4と同じ型）。触られたのは足した2行だけで、2行をまたぐ1回の Edit で直し、`git diff -U0` で足した5か所だけが差分であることを確かめた。タイムラインとテストのファイルに巻き込みは無い
    - 緑: iPhone 17e `885A74C7` で、`-only-testing` に `SoratomoDependenciesTests`・`SoratomoTimelineViewModelTests`・一時の見た目のテストを並べて流した（`nice -n 19`・`-jobs 4`・`-parallel-testing-enabled NO`・`-test-timeouts-enabled YES`）。xcresultで `SoratomoDependenciesTests` 6本・6合格、`SoratomoTimelineViewModelTests` 47本・47合格（`removeGoneSky` のテストは7.2のもの）、一時のテスト1本・1合格。変えた3ファイルは3回のどれかでコンパイルされ（1回目に容れ物、2回目にテスト、3回目にタイムライン）、その警告・エラーは0行。同じ数え方で、ほかのファイルの既存の警告（`GeneratedAssetSymbols.swift:79`・`PaymentService.swift:47`）は拾えた。1回目は一時のテストの `store` が async 版に決まって `try await` が無く、テストのターゲットのコンパイルで落ちた（本物は関係ない）
    - 見た目（利用者が「私がPNGに焼いて見せて」を選んだ）: 一時のテスト（`SoramoyouTests/SoratomoTimelineReactionSnapshotScratch.swift`・コミットしていない・見せた後に消した）で、モックの監視に投稿を流した本物の `SoratomoTimelineView` を、`885A74C7` の中で窓ごとPNGに焼いた。サムネイルは先にメモリの覚えへ入れ、本番の Storage には問い合わせていない。3枚（他人の投稿3件・自分の投稿まじり・文字を大きくした設定）をメインが先に見てから利用者に送った。0件の他人の投稿＝右下に `face.smiling` があり、2行のキャプションに重ならず、角丸からはみ出ない。自分の印あり＝🌅2だけ枠と太字で、ボタンは🌅。7種類＝2行に折り返しても右下の空きに入らない（大きい文字でも同じ）。自分の投稿＝メニューは出ず、0件は今までと同じ高さ。0件の他人の投稿は44ptの行の分だけ下が空いて見えるが、利用者が「このままでいい」を選んだ
    - 確かめていないこと: リストの行の中でメニューが1回目のタップで開くか・カードのボタンのタップに巻き込まれないか・メニューの上の長押しで長押しのメニューが出ないか・VoiceOverでカードとメニューが別の要素になるか（9.2の要確認Q2の前半と13.1・14.3）。メニューを開いた中身は画像に焼けないので見ていない。失敗の知らせが実際に出ることも画面では見ていない（8.3の詳細と13.1）
    - shasum の頭（コミットするもの）: `SoratomoDependencies.swift` `328be57e23ea`・`SoratomoTimelineView.swift` `fb8d6ffd980a`・`SoratomoDependenciesTests.swift` `0e169614f2fb`
    - 実行の環境: ビルド・テスト・`pgrep`・`simctl`・xcresultの読み取りは、サンドボックスの外で流した。DerivedDataはXcodeの設定のままで、`-derivedDataPath` は渡していない。流す前の1分平均は4.7で、負荷を見るフックは1回も止めなかった

- [x] 8.3 投稿詳細に、リアクションの欄と押した人の一覧の入口を置く
  - 前提: 8.2
  - `dependencies.activeReactionViewModel` を、グループIDが一致するときだけ借りる（`activeTimelineViewModel` と同じ）。借りられないとき（起きない想定）は数の表示だけを出し、ブロックの除外は `dependencies.blockedAuthors` で行う
  - `@State private var liveReactions` を足し、監視の `.success(.present(let reactions))` で入れる。表示に使う値は `liveReactions ?? sky.reactions`（覚えの値は最初の表示だけ）
  - `detail(sky)` の投稿者の行の下に、数の表示と、自分以外の投稿ならメニューを並べ、1人以上なら「押した人を見る（{人数}人）」のボタンを置く。押すとシートを出し、`didOpenReactors(count:)` を呼ぶ。投稿が消えた・グループから外れたら、シートは「この投稿は表示できなくなりました」を出す
  - 失敗の知らせは、詳細が開いている間は詳細が出す。「…」のメニュー（削除、または通報とブロック）は変えない
  - シミュレーター（`C2E3F752`）でビルドし、詳細の欄の並び（0件で数を出さない・自分の投稿にメニューが出ない）を目視する。本番のデータでの表示は13.1で行う
  - _Requirements: 1.1, 1.6, 2.4, 2.5, 3.1, 3.5, 8.7, 12.10, 15.1_
  - 結果（2026-10-21 12:20）: 8.2の作業ツリー（`HEAD` `ff413056`）で、アプリ1ファイル（`SoratomoSkyDetailView.swift`）だけを Edit で直した（サブエージェントは使っていない）。着手前に `git fetch` し、`HEAD..origin/main` は空だった
    - 借りる: init で、`activeTimelineViewModel` と同じ形で `dependencies.activeReactionViewModel` をグループIDが一致するときだけ `private let reactionViewModel` に借りる
    - 監視: `observeSky` の `case .success(.present), .failure: break` を分け、`case let .success(.present(reactions))` で `@State liveReactions` に入れる。表示の値は `liveReactions ?? sky.reactions`。「`.present` には反応しない」と書いていた doc コメントを同じ Edit で直した
    - 欄: 投稿者の行（`.accessibilityElement(children: .combine)`）の外、その直後に `reactionSection(sky)` を置いた（メニューを読み上げの別の要素にするため）。詳細の画面そのものはViewModelを監視していないので、欄は `@ObservedObject` で持つ部品 `SoratomoSkyReactionSection` に分けた（送っている間・確定の上書き・ブロックの変化で描き直す）。並びは8.2のカードと同じで、1件以上なら数、0件なら `Spacer` で、自分以外の投稿ならメニューを右端に置く。自分の投稿で0件なら欄ごと出さない（親の `VStack(spacing: 16)` の間隔を増やさない）。1人以上なら「押した人を見る（{人数}人）」のボタンで、押すと `didOpenReactors(count: summary.reactors.count)` を呼んでからシートを出す。`choose` の `source` は `.detail`
    - 借りられないとき: `SoratomoBlockedAuthors` を監視する部品 `SoratomoSkyReactionCounts` で、数の表示だけを出す（上書きなし・メニューと入口なし）
    - シート: `.sheet` は `detail(sky)` の中でなく、body の外側（`.navigationTitle` などと同じ並び）に付けた。中身は投稿が消えると「表示できなくなりました」に切り替わって消えるので、中に付けるとシートが勝手に閉じて8.7の文を出せない。`isUnavailable` は `becameUnavailable || 覚えに無い`
    - 失敗の知らせ: 通報とブロックの知らせ（`SoratomoModerationNoticeAlert`）と同じ二段の形で `SoratomoReactionNoticeAlert` を足した（借りたViewModelが無ければ何もしない・閉じたら知らせを消すだけで、詳細は閉じない）。タイムラインは一番上のときだけ出すので、二重にはならない
    - 「…」のメニュー（`SoratomoSkyDeleteMenu`・`SoratomoSkyModerationMenu`）は触っていない。差分で消えた行は、書き換えた監視のコメント2行と `case` の1行だけ
    - 緑: iPhone 17e `885A74C7`（tasks.mdの `C2E3F752` は引き継ぎの端末に無いので、こちらで焼いた）で、`-only-testing` に `SoratomoDependenciesTests` と一時の見た目のテストを並べて流した（`nice -n 19`・`-jobs 4`・`-parallel-testing-enabled NO`・`-test-timeouts-enabled YES`）。xcresultで6本・6合格と1本・1合格。`SoratomoSkyDetailView.swift` はこの回でコンパイルされ、その警告・エラーは0行。同じ数え方で、ほかのファイルの既存の警告は5行拾えた。8.3に列挙されたテストは無いので、この緑は「コンパイルが通り、既存のテストが壊れていない」の意味だけ
    - 見た目: 8.2と同じく、一時のテスト（`SoramoyouTests/SoratomoSkyDetailReactionSnapshotScratch.swift`・コミットしていない・見せた後に消した）で本物の `SoratomoSkyDetailView` を窓ごとPNGに焼いた。画像はサムネイルと表示用の2枚とも先にメモリの覚えへ入れ、本番の Storage には問い合わせていない。容れ物の `activeReactionViewModel` は弱参照なので、テストのローカルで強く持ってから入れた。4枚をメインが先に見てから利用者に送り、利用者が「このままでいい」を選んだ。他人の投稿（覚えは1人・監視で4人を流した）＝監視の4人で出た（🌅2は枠と太字・🌈1・💙1・右端のボタンは🌅・「押した人を見る（4人）」）。これが `liveReactions` の配線の目視の証拠。他人・0件＝数は出ず、右端に `face.smiling` だけ。自分・数あり＝メニューは出ず、数と「押した人を見る（2人）」。自分・0件＝欄ごと出ず、キャプションは今までの位置
    - 確かめていないこと: メニューのタップで実際に付く・外れること、シートを開いた中身と、開いている間に投稿が消えたときの切り替わり、失敗の知らせが実際に出ること、VoiceOverの読み上げ（9.2・13.1・14.3）。本番のデータでの表示は13.1
    - shasum の頭（コミットするもの）: `SoratomoSkyDetailView.swift` `3cb139f739bd`
    - 実行の環境: ビルド・テスト・`pgrep`・`simctl`・xcresultの読み取りは、サンドボックスの外で流した。DerivedDataはXcodeの設定のまま。流す前の1分平均は6.0で、負荷を見るフックは1回も止めなかった

- [x] 8.4 設定の「そらとも通知」の説明と What's New を、下書きの文言で直す
  - 前提: 1
  - `SettingsView` の「そらとも通知」の説明だけを、design.mdのU3の下書き「そらともで友達が空を投稿したときと、あなたの空にリアクションが付いたときにお知らせします」にする（確定は10）。グループごとにオフにできるとは書かない。「リアクション通知」の名前・説明・既定値、ほかの2つの通知設定、通知の事前説明の文言は変えない
  - `WhatsNewContent`: `currentID` を `"2026-10-soratomo-reactions"` にし、過去の値の一覧のコメントに `2026-10-soratomo-public` を足す。`pages` をリアクションの1ページだけにする（U1のA）。下書き: 記号 `face.smiling`・題「空にリアクション」・本文「友達の空に、7つの絵文字から1つを選んで\n気持ちを送れます\nカードの右下のボタンから」・バッジ「新機能」（絵文字は本文に入れない。確定は10）。オンボーディングは変えない
  - `WhatsNewGateTests.testCurrentIDDiffersFromPastIDs` の過去の値に `2026-10-soratomo-public` を足す（6つ）。既存の判定のテスト（オンボを終えた既存の利用者に1回だけ・オンボの完了で既読）はそのまま通す
  - 陽性対照: `currentID` を一時的に `2026-10-soratomo-public` に戻した写しで、過去の値と違うことのテストが赤になることを先に確かめる
  - _Requirements: 7.7, 7.8, 7.9, 7.10, 16.1, 16.2, 16.3_
  - 結果（2026-10-21 13:40）: 8.3の作業ツリー（`HEAD` `9f5b58d0`）で、アプリ2ファイル・テスト1ファイルを Edit で直した（サブエージェントは使っていない）。着手前に `git fetch` し、`HEAD..origin/main` は空だった
    - 現物が設計の前提と違った: 設計（10/18）は「いまの `currentID` は `2026-10-soratomo-public`」の前提だが、#192（C 項目 3・10/19）の取り込みで、`currentID` は `2026-10-block-from-profile`、`pages` は「プロフィールからブロック」の1ページ（文言は利用者が10/19に承認済み）になっていた。テストの過去の値には `2026-10-soratomo-public` がもう入っていて6つだった。main の版数は 1.15.0 / build 113（10/15 に公開済み）のままなので、このブロックのページはまだどの版でも出ていない
    - 利用者の決定（2026-10-21）: What's New は2ページにする（1枚目＝リアクション・2枚目＝プロフィールからブロック）。設計の U1（「リアクションの1ページだけ」）は「リアクションのページは1枚」と読む。リアクションだけにするとブロックの案内が一度も出ないまま消えるため
    - `SettingsView`: 「そらとも通知」の説明だけを U3 の下書き「そらともで友達が空を投稿したときと、あなたの空にリアクションが付いたときにお知らせします」にした（確定は10）。「リアクション通知」の名前・説明・既定値、ほかの2つの通知設定、通知の事前説明の文言は変えていない
    - `WhatsNewContent`: `currentID` を `"2026-10-soratomo-reactions"` にし、過去の値の一覧のコメントに `2026-10-block-from-profile`（未リリース。リアクションと2ページにしたので使わなかった）を足して7つにした。`pages` の先頭にリアクションのページ（記号 `face.smiling`・題「空にリアクション」・本文「友達の空に、7つの絵文字から1つを選んで／気持ちを送れます／カードの右下のボタンから」・バッジ「新機能」・絵文字は本文に入れない）を足し、ブロックのページは文言を変えずに2枚目に残した。本文の改行は、Edit ツールが `\n` を生の改行に変えることがあるので、Swift の複数行の文字列で書いた（ほかのページの `\n` と同じ文字列になる）。オンボーディングは変えていない
    - `WhatsNewGateTests.testCurrentIDDiffersFromPastIDs`: 過去の値に `2026-10-block-from-profile` を足した（7つ。設計の「`2026-10-soratomo-public` を足して6つ」は、もう入っていたので、1つ前の値を足した）
    - 陽性対照: 設計の「`2026-10-soratomo-public` に戻した写し」は、上のとおり1つ前の値が変わっていたので、1つ前の `2026-10-block-from-profile` に戻した写しで取った。壊す前に3ファイルの shasum を控え（`WhatsNewContent.swift` 頭 `33f6394958ef`）、`currentID` の1行を Edit で戻して `-only-testing:SoramoyouTests/WhatsNewGateTests` を流した。xcresultで7本のうち赤は `testCurrentIDDiffersFromPastIDs` の1本だけ（「過去の値 2026-10-block-from-profile と同じ」）、ほかの6本は緑。逆の Edit で戻し、shasum が控えと一致した。この回はテストが1秒で終わった後、xcodebuild が抜けるまで約10分止まった（メモの「テストの後に gRPC の後始末で止まる」と同じ・止めずに待った）
    - 緑: iPhone 17e `885A74C7` で、同じ `-only-testing` を流した（`nice -n 19`・`-jobs 4`・`-parallel-testing-enabled NO`・`-test-timeouts-enabled YES`）。xcresultで7本・7合格（オンボを終えた既存の利用者に1回だけ・オンボの完了で既読、のテストを含む）。変えた3ファイルは赤の回と緑の回のどちらかでコンパイルされ、その警告・エラーは0行。同じ数え方で、ほかのファイルの既存の警告は5行拾えた
    - 確かめていないこと: What's New の2ページと設定の説明を、画面の現物では見ていない（文言の確定と一緒に10で見せる）
    - shasum の頭（コミットするもの）: `WhatsNewContent.swift` `33f6394958ef`・`WhatsNewGateTests.swift` `4c766e573d5c`・`SettingsView.swift` `6a1e6729c3d1`
    - 実行の環境: ビルド・テスト・`pgrep`・xcresultの読み取りは、サンドボックスの外で流した。DerivedDataはXcodeの設定のまま。負荷を見るフックは1回も止めなかった

## (i) iOS全体の点検

- [ ] 9. iOS全体を点検する

- [ ] 9.1 ログと個人情報・変更なしで満たすこと・既存の挙動を点検する
  - 前提: 7, 8
  - そらともの端末のログ・クラッシュの記録・計測のパラメータに、グループ名・表示名（付けた人と投稿者）・キャプション・招待コード・通知トークンが出ていないことを、そらとものSwiftの外へ出る口（print・`SoratomoEvent` の連想値とパラメータ・`LoggingService` などへの直接の送信・`SoratomoError.record` の文脈）を拾って許可リストと突き合わせて確かめる（leave-group 9.1と同じ方法）。陽性対照: 写しに該当の文字列を1か所ずつ植えて、検査が引っかかることを先に確かめる
  - 変更なしで満たす要件を、コードで確かめる:
    - 隠した投稿（ブロック・この端末の通報）に、リアクションの操作が出ない（行ごと出ない）
    - 削除された投稿のリアクションは、投稿ごと出ない（投稿の文書に埋め込んでいるため）
    - 前面での通知の表示は、全種類で `[.banner, .sound, .list]` のまま
    - 抜けたときの `SoratomoSkyLookup.forget(groupId:)` と、サインアウト・退会の `clearSessionState` で、リアクション（`SoratomoSky` の中）の覚えも消える。上書きはメモリだけで、画面が閉じると消える
    - オフラインの間も、監視の端末のキャッシュの数を出したまま
    - ブロックした相手のリアクションを除いたことを、相手にもほかのメンバーにも知らせる表示・通知を足していない
    - リアクションのためにアプリの読み取りのクエリを足していない（タイムラインと投稿1件の監視のまま）
  - 差分で確かめる: 既存の `LikeManager`・お気に入り・おすすめの空・プロフィールの数・ランキングにリアクションを混ぜていない。`SoratomoSky` を `Post` へ変換する口が無い。タイムラインの長押しのメニューと詳細の「…」のメニューの中身・退会と抜けるの確認の文言・退会の8手順・既存の3つの通知設定・既存の通知のタップの挙動と計測（`soratomoPost` の `post_created` を含む）・通知の事前説明が変わっていない。そらともの既存の動き（タイムラインと続きの読み込み・投稿・削除・抜ける・退会・通報・ブロック・メンバー一覧・招待）のテストが変わらずに通る
  - 新しいイベントと値が、要件15の表と名前・パラメータ名・値で一致している
  - _Requirements: 1.11, 5.6, 7.5, 7.6, 7.9, 7.10, 8.6, 9.14, 9.15, 10.6, 12.2, 12.3, 12.9, 12.10, 12.11, 14.1, 15.2, 15.3, 16.7_

- [ ] 9.2 iOSのビルドとテストを通す（要確認Q2の前半）
  - 前提: 9.1
  - ビルドにエラーと新しい警告が無いこと（変更したSwiftファイルが再コンパイルされ、警告0であることをログで確かめる）、そらともと既存のテストが通ることを確かめる（`C2E3F752`・負荷を見て・`nice`・1本ずつ・全体は時間切れ60秒）
  - 既存のテストのうちmainで既に落ちているもの（leave-group 9.2とpublic-launch 9.2で確かめた34本など）は、変更前のmainでも同じく落ちることを確かめて区別する
  - 7〜8の各テストが、陽性対照で赤になった記録があることを確かめる（記録の無いテストは、先に陽性対照を取り直す）
  - 要確認Q2の前半: シミュレーターで、カードの読み上げの要素（`idb ui describe-all` など）が、カードのボタンとリアクションのメニューで別になっていること、メニューのボタンの上の長押しで長押しのメニューが出ないことを見る（実機とVoiceOverは14.3）
  - _Requirements: 1.7, 1.8, 12.9, 12.15, 13.4_

## (j) 文言の確定

- [ ] 10. 設定の説明と What's New の文言を、画面の現物を見せて確定する（ユーザーの入力が要る）
  - 前提: 8.4, 9.2
  - シミュレーターで、リアクションの操作の現物（タイムラインのカードの右下のボタン・メニューの7つの項目・詳細の欄と「押した人を見る」・設定の「そらとも通知」・What's New のページ）を撮り、操作の名前と場所が下書きの文言（例: 「カードの右下のボタンから」）と合っているかを先に確かめる
  - 利用者に読んでもらう文言は2つ。①設定の「そらとも通知」の説明 ②What's New の1ページ（題・本文・記号）。画面の写しを添え、既存の「リアクション通知」と名前が重なることも添えて、細切れに聞かず、1回にまとめて選択肢つき（AskUserQuestion）で聞く
  - 確定した文言を反映する（直しがあれば8.4の文字列を直し、`WhatsNewGateTests` などのテストを流し直す）。承認した日時を記録する（14.3の16.5の確かめと、14.6のリリースノートで使う）
  - What's New の本文とリリースノートには、絵文字を入れない（リリースノートは App Store Connect が絵文字を拒否する）
  - _Requirements: 7.7, 7.8, 16.4_

## (k) ドキュメントの反映

- [ ] 11. ドキュメントを実装に合わせる

- [ ] 11.1 (P) データの置き場の記録と、release-gateの契約の表を直す
  - 前提: 6（実装が設計どおりであること）
  - `docs/firestore-schema.md` のそらともの表の `skies` の行に `reactions`・`reactorIds`（書き手はFunctionsだけ・アプリは知らない項目を読み捨てる前提）を足し、`reactionNotifyState`・`reactionNotices` の行を足す。「一致させる値」に、名前と絵文字の対応表（iOS `SoratomoReactionKind` ⇔ Functions `REACTION_KINDS`）を足す。抜ける・退会・利用停止で消すものに「本人が付けたリアクションと、印の中の本人」を足す
  - release-gate specのdesign.mdの「API Contract（そらとものCallableのまとめ）」の表に、`soratomoSetReaction` の行を足す（または、このspecのdesign.mdを指す1行を足す）
  - 書き終えたら、変えた識別子（`reactions`・`reactorIds`・`reactionNotifyState`・`reactionNotices`・`soratomoSetReaction`・`onSoratomoSkyDeleted`）で docs と soratomo の spec を検索し、実装と食い違う記述が残っていないことを確かめる
  - _Requirements: 8.1, 9.1, 9.5, 12.8_

- [ ] 11.2 (P) 既存のspecに、リアクションを足したことの上書きの注記を足す
  - 前提: 3.1
  - 既存の「⚠️2026-10-xx 上書き（spec名）: …」の書き方にそろえ、本文は書き換えずに1行を足す。行番号は書く前に現物で確かめる（ずれていれば文で探す）
  - design.mdのMigrationの「実装と同時に直す文書」: release-gate specとleave-group specのdesign.mdの削除の範囲に、用語「そらともデータ」と「片づけ」に本人が付けたリアクションを足した旨（このspecを指す）
  - 前例（leave-group 10.2）に合わせて足すもの（要らなければ利用者の判断で外す）: requirements.mdのIntroductionが挙げた、「対象外」を覆す4か所（soratomo specのrequirements.md 6行・372行・432行、design.md 19行。覆すのはリアクションだけ）と、消す範囲と規則を広げる箇所（release-gate specのrequirements.md 31行の用語「そらともデータ」・要件8の6・要件14の4、leave-group specのrequirements.md 38行の用語「片づけ」・要件11の4、soratomo specの要件14の表の `soratomo_notification_opened`）
  - `git diff -U0` で、どの箇所も追加の1行だけであることを確かめる
  - _Requirements: 4.11, 9.1, 9.5, 14.5, 15.5_

## (l) 本番への反映

- [ ] 12. 本番へ反映する（すべてユーザーのGOを取ってから）

- [ ] 12.1 出す前の確認と、pushとPRの作成（ユーザーのGOを取ってから実行）
  - 前提: 6, 9.2, 10, 11
  - ユーザーのGOを取ってから実行する。AIは単独で実行しない
  - `git fetch -q origin` の後、mainが進んでいれば取り込み、`npm run lint`・`npm test`・`npm run test:emulator`・ルールのテスト（通常と `--mutants`）・iOSのビルドとテストを、もう一度通す
  - PRを出す前に `/review-full` でレビューし、新しいCallableが外からの入力を受けるので、続けて直列で `/security-review` を通す。指摘の直しを済ませてから出す
  - 初回のpushは、サンドボックスの外で `git push -u origin 機能-そらともいいね`。PRの本文に、要件・設計・tasks.mdの場所と、順番（マージ→Functionsとルールのデプロイ→リアクションを含む版のTestFlightと審査。デプロイの前にmainからアプリの版を作らない）を書く。本文に半角の `@名前` を書かない（渡す前に `grep -c '@'` で数える）
  - _Requirements: 12.14, 12.15, 16.8_

- [ ] 12.2 mainへマージする（ユーザーのGOを取ってから実行）
  - 前提: 12.1
  - ユーザーのGOを取ってから実行する。AIは単独で実行しない
  - マージの前に、PRの差分で、既存のCallableの受け付けの条件・`isSoratomoUser()`・`requireSoratomoUser` の中身・`storage.rules`・`firestore.indexes.json`・退会の確認と手順（設定画面）が変わっていないことを、もう一度見る。mainの保護（Ruleset）で必要なチェック（security-tests）が緑であることを見る。マージの方式は前例（squash）に合わせる
  - マージから12.3・12.5のデプロイまでの間に、mainからアプリの版を作らない（操作があるのにCallableが無い状態になるため）
  - _Requirements: 12.8, 12.13, 16.8_

- [ ] 12.3 Functionsをデプロイする（ユーザーのGOを取ってから実行）
  - 前提: 12.2
  - ユーザーのGOを取ってから実行する。AIは単独で実行しない
  - 出し元: `git fetch` の後、作業ツリーがcleanで `HEAD == origin/main` のところから出す。出し元のコミットを記録する
  - 出す前の確認: 前回のそらともの関数の出し元を、記録（public-launchとその後のspec・PRの記録）で確かめる（決め打ちしない。分からなければ利用者に聞く）。`git log --stat <前回の出し元>..origin/main -- functions/` を見て、このspecの分と、すでに本番へ出たことが記録で分かる分だけであること（違えば止めて相談する）。本番の `firebase functions:list` の名前・数・リージョン・ランタイムを記録する（22本・asia-northeast1・nodejs22の見込み）
  - コマンド: そらともの関数だけを名前で指定して出す。名前は `functions/soratomo.js` の `module.exports` の13本から機械で作る（手で打たない）。`firebase deploy --only functions:<名前>,…（13本） --project soramoyou-ios --non-interactive`。変わった関数だけにしないのは、共通の部品（`soratomoCore.js`・`soratomoStore.js`・`soratomoDeletion.js`）を、そらともの関数がみな読むため。本番にあってソースに無い関数の削除は行わない
  - 出した後: 出力で、作成2本（`soratomoSetReaction`・`onSoratomoSkyDeleted`）と更新11本がすべて成功。`firebase functions:list` で、追加2行・削除0行・合計24本・リージョンとランタイムが既存と同じ。初めての削除トリガーで権限の伝播の待ちが出たら、出力の指示どおり時間をおいて同じコマンドをもう一度（GO）
  - _Requirements: 8.2, 8.3, 9.6, 11.1, 16.8_

- [ ] 12.4 新しいCallableの公開呼び出しの許可を確かめる（ユーザーのGOを取ってから実行）
  - 前提: 12.3
  - ユーザーのGOを取ってから実行する。AIは単独で実行しない
  - leave-group 11.4（release-gate specの要確認4）と同じ手順で行う。認証の無い `POST https://asia-northeast1-soramoyou-ios.cloudfunctions.net/soratomoSetReaction`（本文 `{"data":{}}`）を1回送り、HTTP 401・`UNAUTHENTICATED`・「ログインが必要です」が返ること（この文言は関数のコードだけが返す。許可が無ければCloud Runが403で止める）。関数のログに `soratomoSetReaction: rejected`（reason unauthenticated）が出ること
  - 失敗したら、呼び出し元の設定を見直す（変える前に利用者に相談する）
  - _Requirements: 4.12_

- [ ] 12.5 Firestoreのルールを本番へ出す（ユーザーのGOを取ってから実行）
  - 前提: 12.2（12.3との順は問わない。新しい `match` は、既定で拒否されていたパスの明示なので、どの順でも挙動は変わらない）
  - ユーザーのGOを取ってから実行する。AIは単独で実行しない
  - 出す前: `scripts/read-deployed-rules.py` で本番のルールを読み、このspecのマージの前の origin/main の `firestore.rules` とハッシュの頭が一致することを確かめる（ルールはファイル全体を出すので、ほかのブランチの未反映の変更を一緒に出さないため。一致しなければ止めて相談する）。差がこのspecの `match` とコメントだけであることを差分で見る
  - コマンド: `firebase deploy --only firestore:rules --project soramoyou-ios --non-interactive`
  - 出した後: 読み返しの道具で、ruleset・更新の時刻・ハッシュの頭が手元の `firestore.rules` と一致すること。保存した本番の本文に `rules_test_soratomo.py`（通常）を流して全件が期待どおりであること
  - _Requirements: 4.13, 12.8, 16.8_

## (m) 受け入れの確認（開発版と本番）

- [ ] 13. 開発版と本番で、リアクションを受け入れる（利用者の操作が要る）

- [ ] 13.1 開発版で、付ける・外す・一覧・ブロック・抜ける・削除を通し、要確認Q4を見る（利用者の操作が要る）
  - 前提: 12.3, 12.5
  - 利用者の操作が要る。本番の読み取り（件数・項目名）とログの読み取り・端末の操作のお願いは、GOを取ってから行う
  - 端末: 始める前に「いまさわれる端末」を利用者に聞き、端末とアカウントの割り当てを決める（前例: シミュレーター2台にテスト用アカウントS3とB）。入っているアプリが、12.3の出し元から作った開発版（Debugビルド）で、`soratomoSetReaction` の名前を含むことを確かめる（アプリの中の文字列を数える）。だれでログインしたかは、Authの最後のログインの時刻で確かめる。ログインのメールは推測しない（記録を見るか利用者に聞く）
  - 付ける・選び直す・外す: BがS3の投稿に、タイムラインのカードの右下のボタンから付け（詳細へ進まない）、別の絵文字に選び直し、同じ絵文字をもう一度選んで外す。カードのほかの場所を押すと詳細へ進む。自分の投稿にはボタンが出ず、数は出る。詳細からも同じく付けられる。押した直後に自分の表示が変わり、処理中は同じ投稿の操作を重ねて受け付けない
  - 数と一覧: S3の画面で、Bの付けた・外した・選び直したが、手動の更新なしで10秒以内に数へ出る（時刻を記録する）。自分が付けた絵文字が見分けられる。0件の投稿では数が出ない。詳細の「押した人を見る」で、一覧の名前とアイコンが正しく（内部IDの頭文字でなく）出て、人数が数の合計と一致する。投稿者でないメンバーにも一覧が出る
  - ブロック: ブロックの確かめに使うアカウントの組は、既存のブロックの状態を本番で読んでから決める（GO。解除の手段が無ければ、使い捨ての組にする）。ブロックした人の画面で、相手のリアクションが手動の更新なしで数と一覧から消え、ブロックしていない人の画面には残る。ブロックされた人の付ける要求は拒否されない
  - ログ（GO）: 各操作の `soratomoSetReaction: ok` が、内部IDと名前（`kind`）と件数だけで出る（`outcome` と `notify` が場面と合う。シミュレーターはトークンを持たないので `no_token` の見込み・ブロックの後は `blocked`）。グループ名・表示名・キャプションが出ていない。サーバーの実行時間を記録する（要確認Q7の前半）
  - 抜ける（要確認Q4）: Bが、S3の投稿にリアクションを付けたまま、そのグループを抜ける。S3の画面で、Bのリアクションが手動の更新なしで消える。`soratomoLeaveGroup: ok` の `reactionsDeleted` が、前に読んだBのリアクションの数と一致する。同じ時間のログに `FAILED_PRECONDITION`（インデックスが要る）や片づけの失敗が無い。デプロイの後に本物の利用者の抜ける・退会が走っていれば、そのログでも見る。本番で壊れたクエリを流す陽性対照は取らない（本番を壊さないため。そう記録する）
  - 投稿の削除: S3がリアクションの付いた自分の投稿を消す。`soratomoReaction: sky_deleted` の `reactionsDeleted` が付いていた数と一致し、本番の `reactionNotices/{skyId}` が無い（GO）
  - 要確認Q1の本番での裏付け（任意）: 使ってよい使い捨てのグループで、リアクションの付いた投稿を残したまま最後の1人が抜け、`sky_deleted` の行の数が `skiesDeleted` と一致することを見る
  - 要確認Q2の続き: シミュレーターで、カードのメニューがカードのボタンと重ならずに押せる
  - 受け入れの確認で直しが出たら、別のPRで直し、12と同じ手順で出し直してから、該当の確認をやり直す
  - _Requirements: 1.1, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 3.5, 3.6, 5.1, 5.2, 5.3, 5.5, 8.1, 8.2, 8.4, 9.1, 9.2, 9.13, 14.3, 14.4, 14.5, 16.7_

- [ ] 13.2 リアクションを持たない1.15.0の端末で、リアクションの付いた投稿と通知を通す（要件11.6の段2と段3・利用者の操作が要る）
  - 前提: 12.3, 12.5（段1＝サーバーを本番へ出したこと）, 13.1
  - 利用者の操作が要る。本番とPostHogの読み取り・端末の操作のお願いは、GOを取ってから行う
  - 端末とアカウント: 1.15.0の端末のアカウントが投稿者で、同じグループに13.1の開発版のアカウントも入っていること・そらとも通知がON・通知のトークンがあることを、先に決めて確かめる（GO）。間引きは投稿者×グループで5分なので、通知を1通だけ確かめる順にする
  - 段2（リアクションを含む版でリアクションを作る）: 1.15.0はリアクションを作れないので、13.1の開発版のテスト用アカウントが、1.15.0の端末のアカウントの投稿にリアクションを付ける。`soratomoSetReaction: ok`（`outcome: added`・`notify: sent`）を確かめる（GO）
  - 段3の前に: 利用者に「いまさわれる端末」を聞き、その端末に入っている版とbuild番号が1.15.0（113）であることを、設定画面の版の表示かTestFlightの画面で確かめる
  - 段3（1.15.0で通す）: 1.15.0の端末で、①リアクションの付いた投稿のタイムライン（続きの読み込みを含む）と投稿詳細がエラーにならずに出る ②リアクションの通知が届き、タップするとアプリが開くだけで、落ちず、別の画面やグループへ進まない ③そのタップの時刻に、そのuidからの `soratomo_notification_opened` がPostHogに無い（新着投稿として計測していない）④リアクションの付いた投稿を1.15.0から消すと消え、`soratomoReaction: sky_deleted` の `reactionsDeleted` が1以上（リアクションを持たない版の削除でも消える）⑤1.15.0から1枚投稿して `soratomoCreateSky: ok`
  - TestFlightの自動更新で、この端末が新しい版に上がる前に済ませる（14.2より前）
  - _Requirements: 6.1, 6.18, 8.3, 11.1, 11.2, 11.4, 11.5, 11.6_

## (n) リアクションを含む版の提出

- [ ] 14. リアクションを含む版を TestFlight で確かめ、審査に出す

- [ ] 14.1 版数を利用者に聞き、build番号を決めて main の値を直す（ユーザーの入力が要る・GOを取ってから実行）
  - 前提: 13.1
  - 版数は、このspecでは決めていない。1.15.0は公開済みなので、新しい版は1.15.0より上にする（承認済みのトレインと同じ版数は拒否される＝ITMS-90062の前例）。候補（例: 1.15.1・1.16.0）とそれぞれの意味を添えて、AskUserQuestionで聞く
  - App Store Connectの最大のbuildを実測で読み（GO）、それより大きく、まだ使っていない番号に決める
  - `project.pbxproj` の `MARKETING_VERSION` と `CURRENT_PROJECT_VERSION` を、アプリとウィジェットの4か所ずつ直す（テスト用のターゲットは変えない）。コマンドの上書きで上げず、値をコミットし、小さなPRでmainへ入れる（push・PR・マージは、それぞれGO）
  - _Requirements: 16.8_

- [ ] 14.2 archive して、内部の TestFlight へ出す（ユーザーのGOを取ってから実行）
  - 前提: 12.3, 12.5, 13.2, 14.1（サーバーを出し終えてから、リアクションを含む版を人の手へ渡す。1.15.0の端末の確かめは、TestFlightの自動更新の前に済ませる）
  - `git fetch` の後、`HEAD == origin/main` のところから作る。gitの管理外の `ExportOptions.plist` が作業ツリーに無ければ、本体のcheckoutから写す
  - `uptime` と `pgrep -x xcodebuild` で負荷を見てから、`~/.claude/scripts/xcode-testflight-upload.sh` と同じフラグに `nice -n 19` と `-jobs 4` を付けて archive と export を行う。`ENABLE_USER_SCRIPT_SANDBOXING=YES` のまま。背景で回すなら `nohup … & disown`。IPAのInfo.plistの版とbuildが14.1の値であることを見る
  - アップロードは別にGOを取る。成否はアップロードのログでなく、App Store Connectでbuildが `VALID` になったことを読んで判定する。内部のTestFlight（開発者とテスト用アカウント）へ配る
  - _Requirements: 16.8_

- [ ] 14.3 実機で、通知・VoiceOver・オフライン・宣伝する操作を通す（要確認Q2・Q7・利用者の操作が要る）
  - 前提: 10, 14.2
  - 利用者の操作が要る。端末の操作を頼む前に「いまさわれる端末」を聞き、入っている版とbuild番号が14.1の値であることを確かめる。ログと本番の読み取りはGOを取ってから
  - 通知: 実機の投稿者へ別のアカウントが付けると、題がグループ名・本文が「{表示名}さんがあなたの空に{絵文字}を付けました」の通知が1分以内に届く（キャプションが無い・バッジは付かず、音は新着投稿の通知と同じ）。前面ではバナーと音で出て、通知センターに残る。未読の新着投稿の通知が置き換わらない。同じグループの新着投稿の通知と同じスレッドにまとまる。タップでそのグループのタイムラインが開く（起動していない状態からも）。5分以内の2通目は届かず、同じ人が外して付け直しても届かない。選び直し・外すでは届かない
  - VoiceOver（要確認Q2）: カードで、詳細へ進むボタンとリアクションのメニューを別々に選べる。数の読み上げが「どの絵文字を何人・自分が付けたか」を日本語の名前で読む。メニューの項目が日本語の名前で読まれ、いまの絵文字が選択中と読まれる。押した人の一覧の各行が「表示名、絵文字の名前」で読まれる。すべてのボタンにラベルがある。試したiOSの版と端末を記録し、ほかの版（iOS 16〜26のうち試していないもの）は「検証済み」と書かない
  - オフライン: 機内モードで付けると、通信が必要と出て、要求が始まらず（ログに呼び出しが無い）、通信が戻っても送り直されない。機内モードの間も、前に読んだ数が出たまま
  - 要確認Q7: 付けてから表示が確定するまでの体感と、ログの実行時間を記録し、楽観的な表示で待ちが目立たないことを確かめる。処理中に連打しても、重ねて送られない
  - 16.5: 10で確定した What's New で宣伝する操作（カードの右下のボタンから絵文字を1つ選ぶ）を、この版のビルドの実データで1回ずつ通す（`docs/pre-release-checklist.md` の§4）。What's New が既存の利用者に1回だけ出ることも見る
  - 16.6: 2〜3件の実データで、数・押した人の一覧の名前とアイコン・通知の届き方を目視する
  - _Requirements: 1.10, 2.5, 6.1, 6.9, 6.10, 6.11, 6.13, 6.14, 6.15, 6.17, 7.1, 7.2, 7.6, 10.1, 10.2, 10.6, 13.1, 13.2, 13.3, 13.4, 13.5, 16.1, 16.5, 16.6_

- [ ] 14.4 計測の着弾を、除外の条件あり・なしで数える（要件15.7）
  - 前提: 14.3
  - 14.3の通しの時間帯で、`soratomo_reaction_added`（`replaced` が真と偽の両方）・`soratomo_reaction_removed`・`soratomo_reaction_failed`・`soratomo_reactions_viewed` と、`soratomo_notification_opened` の `type` = `reaction` の件数を、除外の条件をかけない場合とかける場合で出す（クエリの型と除外の条件は public-launch specの `research.md` のもの）。期待: 除外なしで各1件以上・除外ありで0件。パラメータの値（`kind` が名前・`source`・`reason`・`reaction_count`）が要件15の表と一致し、uid・グループID・名前が入っていない
  - `soratomo_reaction_failed` は、機内モードの `offline` で起こす。届かなければ、public-launch 12.3の `soratomo_leave_failed` の未着と同じ根かを、端末のログ（Console.appで `com.soramoyou` の `LoggingService` に `Analytics event:` の行が出るか）で切り分け、別の理由（例: 投稿者が消した直後の詳細から付けて `not_found`）でも1回起こす。`offline` の経路が届かなかったら「検証済み」と書かず、完了にするかを利用者に聞く
  - _Requirements: 15.1, 15.3, 15.4, 15.5, 15.7_

- [ ] 14.5 プライバシーラベル・ポリシー・審査メモへの影響を確かめ、文案の承認を取る（ユーザーの入力が要る）
  - 前提: 10
  - プライバシーラベル: `docs/app-privacy-label.md` と `PrivacyInfo.xcprivacy` を読み、リアクション（メンバーに見える反応・投稿者への通知）で増える項目があるかを確かめた案を作る（public-launch 10.4の「その他のユーザーコンテンツ」の扱いと比べる）。変えるなら、表とマニフェストを同時に直す（マニフェストのXMLのコメントに連続のハイフンを入れない＝ITMS-91056の前例）
  - プライバシーポリシー（`SettingsView.privacyPolicyText` と `hosting/privacy/index.html`）: そらともの節に、リアクション（付けた人と絵文字がグループのメンバーに見える・投稿者へ通知する・抜ける・退会で消える）を足すかの案を作る。足すなら、最終更新日を直し、`python3 scripts/build-privacy-policy-html.py` で作り直し、小さなPRでmainへ入れ（GO）、`firebase deploy --only hosting --project soramoyou-ios`（GO）で出して読み返す。App Store Connectのポリシーの URL が hosting を指していることも読む（public-launch 13.3の訂正の前例）
  - 審査メモ: いまの公開版の審査メモ（日本語＋英語）を読み（GO）、審査用のグループ（S3がオーナーで投稿がある）で、参加の後にS3の投稿へリアクションを付けられる・押した人を見られる手順を足す案を作る。招待コードは文案に書かず、App Store Connectにだけ入れる。操作の名前は10で確定した画面の名前にする
  - 3つの案を利用者に見せ、1回で承認を取る（AskUserQuestion）。承認の日時を記録する。App Store Connectへの入力は14.6で、版を作った後にGOを取ってから行う
  - _Requirements: 16.9_

- [ ] 14.6 版を作り、リリースノートと審査メモを入れる（ユーザーのGOを取ってから実行）
  - 前提: 14.3, 14.5
  - リリースノート（App Store Connectの「このバージョンの最新情報」）の草案を利用者に聞き、チャットで清書する。リアクションを紹介する文でも、絵文字を書かずに言葉で表す。`fastlane/metadata/ja/release_notes.txt` に入れ、コードポイントで検査して、絵文字・異体字セレクタ（U+FE00〜U+FE0F・U+E0100〜）・私用領域の文字・ZWJ・`PLACEHOLDER` が無いことを確かめる。検査器の陽性対照: U+FE0F単体・☁️（U+2601＋U+FE0F）・💙・U+E000を入れた写しで、それぞれ検出されることを先に確かめる
  - 提出の前のApp Store Connectを読む（GO）: 公開中の版・新しい版が無いこと・審査中や編集中の版が無いこと・14.2のbuildが `VALID` で期限切れでない
  - `scripts/appstore-release.sh prepare --version <版> --build <build>`（GO）。`prepare` は成功と出てもビルドを紐付けないことがあるので、`scripts/asc_ensure_build.py --version <版> --build <build>` で読み返して紐付けを保証する。リリースノートをAPIで読み返し、手元のファイルとバイトで一致する（App Store Connectは末尾の改行を落とす）ことを確かめる
  - 14.5で承認した審査メモ（とラベルの直しがあればその入力）を、新しい版に入れる（GO・入れた後に読み返す）
  - submitはマニフェストと手元の `release_notes.txt` を照合するので、14.7まで `release_notes.txt` を変えない
  - _Requirements: 16.9, 16.10_

- [ ] 14.7 審査に提出する（ユーザーのGOを取ってから実行）
  - 前提: 13.2, 14.4, 14.6
  - 提出の前に、要件11.6（13.2）・15.7（14.4）・16.5と16.6（14.3）・16.9（14.5）・16.10（14.6）の結果がそろっていることを、このファイルの結果で読む。サーバーの反映（12.3・12.5）が、リアクションを含む版を人の手へ渡す（14.2）より前に済んでいることを、時刻で確かめる
  - `scripts/appstore-release.sh submit` は、審査提出のGOを取ってから実行する（最後の判断は自動化しない）。提出の後にApp Store Connectを読み、版が審査待ちになったことを確かめる
  - 提出した版数・build・リリースノートの指紋の頭・提出の時刻を、このタスクの結果に書く
  - _Requirements: 11.6, 16.8, 16.10_
