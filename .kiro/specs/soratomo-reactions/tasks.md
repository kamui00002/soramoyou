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

- [ ] 3. リアクションのCallableと、投稿の削除トリガーを配線する

- [ ] 3.1 リアクションのCallable `soratomoSetReaction` と、投稿者への通知 `notifyReaction` を作る
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

- [ ] 3.2 投稿の削除トリガー `onSoratomoSkyDeleted` を作り、本数の記載を直す（陽性対照C9）
  - 前提: 3.1（同じ `soratomo.js` を触る）
  - design.mdの「onSoratomoSkyDeleted」のとおり、`onDocumentDeleted({ document: "soratomoGroups/{groupId}/skies/{skyId}", region: REGION })` で作る（再試行は付けない）。消えた文書の `reactions` の鍵の数を数え（地図でなければ0）、`reactionNotices/{skyId}` を消し、`soratomoReaction: sky_deleted`（`groupId`・`skyId`・`reactionsDeleted`）をinfoで出す。失敗は `soratomoReaction: sky_deleted_failed`（`groupId`・`skyId`・`errorName`・`errorCode`）をerrorで出し、投げない
  - `module.exports` に足して13本にし、公開する関数の数を確かめる既存のテストを13本に直す。`functions/soratomo.js` のヘッダー（2行目の本数・説明の箇条に `soratomoSetReaction` と `onSoratomoSkyDeleted`・23行目の「11 本」）と、`functions/index.js` の580行のコメント（Callable 9本・トリガー3本・定期実行1本）を直す
  - `soratomo.test.js`: 印が消える・件数のログ（地図でない `reactions` は0）・2回目も成功（印が無くても成功）・ログに名前などが無い。公開する関数が13本で、選択肢の名前の検査が通る
  - 陽性対照（C9）: 場面は「リアクションの付いた投稿を消し、削除のイベントを渡す」。印を消さない写し（本体を件数のログだけにした形＝トリガーを外したのと同じ結果）で、「印が消える」が赤になることを先に確かめる
  - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 14.3, 14.5_

## (d) Functions: 共通の削除（手順2b）

- [ ] 4. 抜ける・退会・利用停止・後始末で、本人が付けたリアクションを消す

- [ ] 4.1 本人のリアクションが消えることのテストを先に書き、今の現物で赤を確かめる（陽性対照C2）
  - 前提: 1.3（4.1〜4.3は `soratomoDeletion.test.js` とエミュレーターを使うので、2・3と同時に進めない）
  - `soratomoDeletion.test.js` に、リアクションと印をAdmin SDKで直接入れた種を作る部品を足す（ほかのメンバーの投稿に、本人と別の人のリアクション・`reactorIds`・`reactionNotices` の `notifiedReactorIds`、本人あての `reactionNotifyState`）
  - テストを足す（期待は4.2・4.3の後の姿）:
    - 抜ける（`leaveSoratomoGroup`・`origin: "self"`）: 本人がほかのメンバーの投稿に付けたリアクションと、印の中の本人が消え、本人の `reactionNotifyState` が消える。ほかの人のリアクションと印は残る。`done: true` は消し終えた後
    - 退会（`deleteSoratomoUserData`）・利用停止（`suspendSoratomoUser`）・アカウントの無い人（仕事Aの部品）: 所属するすべてのグループで同じく消え、`done: true` は消し終えた後
    - 運用の削除（`scripts/soratomo-admin.js` の、内部IDを指定した削除）: 同じく消える（`scripts/soratomo-admin.emulator.test.js` に1件）
  - テストだけを足した作業ツリー（コミットしない）で、今の現物（4.2の前の `soratomoDeletion.js`）で流す。そのときの `HEAD` とテストのファイルの shasum の頭を結果に書く。赤の理由が「本人のリアクションが残る」であることをテストごとに確かめ、件数で記録する（`reactionsDeleted` の項目が無いことによる赤は、別に数えて分ける）
  - _Requirements: 9.1, 9.5, 9.6, 9.7, 9.8, 9.9_

- [ ] 4.2 手順2b `removeUserReactionsInGroup` を作り、退会・利用停止・後始末・運用の削除に差し込む（陽性対照C2）
  - 前提: 4.1, 3.2（`soratomo.js` のログの項目を触るので、3の後）
  - `functions/soratomoDeletion.js` に、design.mdの「共通の削除」のService Interfaceのとおりに作る。`skies` を `where("reactorIds", "array-contains", uid)` で300件ずつ読み、`beforeDelete`（省略可）を呼び、各文書を `update`（`reactions.{uid}` を `FieldPath` で `delete`・`reactorIds` から `arrayRemove`・前提条件 `{ lastUpdateTime: 読んだ文書の updateTime }`）で同時に10件まで書く。`NOT_FOUND` と `FAILED_PRECONDITION` は数えずに飛ばす（後者は次の区切りで読み直す）。`set(merge)` は使わない。続けて `reactionNotices` を `where("notifiedReactorIds", "array-contains", uid)` で同じく読み、同じ前提条件で `arrayRemove(uid)`。区切りごとに締め切りを確かめる
  - `deleteUserDataInGroup` の手順2の後、残るメンバーがいる（`leave`）ときだけ手順2bを呼ぶ（照合なし）。手順3で `reactionNotifyState/{uid}` も消す。`delete_group` では行わない。行番号はdesign.md（`abaa3bdb` の現物で確かめた値）を目安にし、書く前に現物で確かめる
  - D4の読み方（承認済み）: 戻り値に `reactionsDeleted`（消した投稿のリアクションの数）を足し、`deleteSoratomoUserData` の合計に足す。`soratomo.js` の `soratomoDeleteMyData` の `okLogFields` に足す（`soratomoDeletion: summary` は合計をそのまま出すので自動で載る）。リアクション以外の消す範囲・既存の件数の値・利用者へ返す応答（`{ done }`）は変えない。既存のテストは、1.3（Q5）で数えた箇所の期待値に `reactionsDeleted: 0` を足す以外は変えない
  - D1の読み方（承認済み）: 印の中の本人のuidを、退会・利用停止・アカウントの無い人の片づけで外す
  - `soratomoDeletion.test.js` に足す: 最後の1人では手順2bを行わず全部が消える／締め切り（300件を超えるリアクションで `done: false`・続きで消し切る・2回目は件数0）／更新の前に投稿が消えた（`NOT_FOUND`・投げずに飛ばし数えない）／更新の前に投稿が書き換わった（`FAILED_PRECONDITION`・投げずに飛ばし、次の区切りで読み直して消す）／何度呼んでも1回で成功した場合と同じ／利用停止の解除で消したリアクションが戻らない
  - 4.1の退会・利用停止・アカウントの無い人・運用の削除のテストが緑になったことを並べて記録する
  - 陽性対照: `set(merge)` で書く写しで「消えた投稿を作り直さない」が、`reactions` の地図を丸ごと消す写しで「ほかの人のリアクションは残る」が、`arrayRemove` をしない写しでI1が、それぞれ赤になることを先に確かめる
  - _Requirements: 9.2, 9.3, 9.5, 9.6, 9.7, 9.8, 9.9, 9.10, 9.11, 9.12, 12.12, 12.13, 14.5_

- [ ] 4.3 抜けるに手順2bを照合つきで差し込み、入り直しとの競合を確かめる（陽性対照C2・C3・C10）
  - 前提: 4.2
  - `leaveSoratomoGroup` の手順2の後、`leave` のときだけ手順2bを呼び、`beforeDelete` に照合（`isLeaveEpisodeCurrent`）を渡す。外れたら `superseded` で止める。`finishLeaveTx` で `reactionNotifyState/{uid}` も消す。結果に `reactionsDeleted` を足す
  - `functions/soratomo.js` の `soratomoLeaveGroup` の `okLogFields` と、仕事Cの `soratomoLeave: swept` に `reactionsDeleted` を足す。応答（`{ done, groupDeleted }`）は変えない
  - 止め方: 実行を手順2bの照合の前後で止める口は、`leaveSoratomoGroup` のdepsに省略できるテスト用の口を足すか、`removeUserReactionsInGroup` を直接呼ぶ形にする（どちらにしたかを結果に書く。口を足すなら、本番の既定は何もしない形にする）
  - 陽性対照（C2）: 4.1の抜けるのテストが緑になったことを記録する
  - 陽性対照（C3）: 場面は「抜けるの実行Aを手順2bの照合の前で止め、その間に実行Bが最後まで終え、本人が入り直して同じ投稿に付け直し、Aを再開する」。期待は、Aが照合で `superseded` になり、新しいリアクションが残ること。手順2bに照合を渡さない写しで、新しいリアクションが消えて赤になることを先に確かめる
  - 陽性対照（C10）: 場面は「実行Aの手順2bで、照合が真を返した直後・更新の前に、実行Bが最後まで終え、本人が入り直して同じ投稿に付け直す」（照合の口を包み、本物の照合が真を返した後に、Bと入り直しと付け直しを行ってから真を返す）。期待は、Aの更新が `FAILED_PRECONDITION` で何も消さず、次の区切りの読み直しで照合が外れて `superseded` になり、新しいリアクションが残ること。更新の前提条件（`lastUpdateTime`）を外した写しで、新しいリアクションが消えて赤になることを先に確かめる
  - 入り直したがまだ付けていない場合は、抜ける前のリアクションを消す（文書が変わっていないため）。ほかのメンバーが同じ投稿に付けた・外した場合は、次の区切りで読み直して消す。最後の1人の抜けるでは手順2bを行わず、グループごと消える
  - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.10, 9.11, 12.12, 12.13, 14.5_

## (e) Firestoreのルール

- [ ] 5. (P) Firestoreのルールに、リアクションの通知の記録の拒否を足す（陽性対照C1）
  - 前提: 1.1（ルールとルールのテストだけを触る。エミュレーターを使わないので、2〜4と同時に進めてよい）
  - `firestore.rules` の `soratomoGroups/{groupId}` の中、`notifyState` の `match` の後に、design.mdの「Backend: ルール・インデックス・ルールのテスト」のとおり拒否だけの `match` を2つ（`reactionNotifyState/{uid}`・`reactionNotices/{skyId}`）、コメントつきで足す。`skies` の `match` の条件は変えず、コメントを1行足す。冒頭のコメントの書き手の一覧に「リアクションと、リアクションの通知の記録」を足す。行番号は書く前に現物で確かめる
  - `storage.rules` と `firestore.indexes.json` は変えない
  - `scripts/rules_test_soratomo.py`: design.mdのとおり、`CASES` に6件（他人の投稿へのリアクションの `update`・投稿者の `reactions` の `update`・非メンバーの `update` はDENY／リアクションの付いた自分の投稿の削除はALLOW／付けた人の他人の投稿の削除はDENY／非メンバーのリアクションの付いた投稿の取得はDENY）、`closed_collection_cases()` に2つのコレクション（立場は投稿者・付けた人・ほかのメンバー・未ログイン。`get`・`list`・`create`・`update`・`delete` をすべてDENY）、`MUTANTS` に2つ（それぞれの `if false` を `if true` へ）を足す。ファイルの先頭のspecの一覧に、このspecを足す
  - 差分が「新しい `match` とコメント」だけで、既存の `match` の条件を緩めていないことを、差分で確かめる
  - 陽性対照（C1）: `--mutants` で、既存の壊し方「投稿の更新を許す」が、新しい `update` のDENYのケースを期待外れにする。新しい2つの壊し方が、新しい閉じたコレクションのケースを期待外れにする。どの壊し方でも期待外れにならないケースが0件・どのケースも期待外れにしない壊し方が0個・置き換え元が1回でない壊し方が0個。通常の実行がすべて期待どおり。件数を記録する
  - ここではルールをデプロイしない（12.5で行う）
  - _Requirements: 4.13, 12.8, 12.14, 12.16_

## (f) Functionsとルールのまとめ

- [ ] 6. Functionsとルールのテストをすべて通し、既存の動きを変えていないことを点検する
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

## (g) iOS: モデル・変換・計測・サービス

- [ ] 7. iOSの土台を作る

- [ ] 7.1 7種類の絵文字・投稿の中のリアクション・画面に出す数の型を作る
  - 前提: 1.1, 1.3（Functionsと別のセッションで並行してよい）
  - `Models/SoratomoReactions.swift`（新規）に、design.mdの形で `SoratomoReactionKind`（7つ・並び・`rawValue` は保存と計測の名前・`emoji`・`spokenName`）・`SoratomoReaction`・`SoratomoReactions`（`decode` は投げない）・`SoratomoReactionOverride`・`SoratomoReactionSummary`（`make`・`accessibilityLabel`）・`SoratomoReactorEntry` を置く
  - `SoratomoSky`（`Models/SoratomoModels.swift`）に `var reactions: SoratomoReactions = .empty` を足し、型の説明の「作成と削除だけで、更新しない」を「リアクションはサーバーが更新する」に直す。既存の `SoratomoSky(...)` の呼び出しは変えない。`Post` へ変換する口は作らない
  - `SoratomoReactionKindTests`（新規）: 7つの並び・名前・絵文字のスカラー（FE0Fを含む）・日本語名を固定する（2.1のFunctionsの値と同じ）
  - `SoratomoReactionsTests`（新規）: `decode`（無い→空・地図でない→空・知らない名前→その1人だけ飛ばす・値の形の違い）。`make`（絵文字の並び順で1以上だけ・0件は空・自分の印・ブロックの一覧の人を除く・自分の上書き・一覧の人数＝数の合計・一覧は新しい順で、時刻が同じか無いものはuidの順・投稿者本人のキーがあっても数える）。`accessibilityLabel` の文（例: 「リアクション、夕焼け3人、虹1人。あなたは夕焼けを付けています」）
  - 陽性対照: ブロックの除外を外した写しで除外のテストが、上書きを使わない写しで上書きのテストが、数の多い順に並べ替える写しで並び順のテストが、それぞれ赤になることを先に確かめる
  - _Requirements: 1.2, 2.1, 2.2, 2.3, 2.4, 2.7, 3.6, 5.1, 5.3, 12.2, 12.3, 13.2, 13.3, 15.4_

- [ ] 7.2 投稿の変換と投稿1件の監視に、リアクションを載せる（陽性対照C7・C8・要確認Q6の反映）
  - 前提: 1.3, 7.1
  - `SoratomoSkyService.swift`: `Field` に `reactions` を足す（`reactorIds` はアプリでは読まない）。`decodeSky` の最後に `SoratomoReactions.decode(data[Field.reactions])` を入れる（壊れていても投稿を飛ばさない）。`resolveObservedSky` に `data` の引数を足し、`.present(SoratomoReactions.decode(...))` を返す。監視は1本のまま（同じ文書へ2本目のリスナーを張らない）
  - `SoratomoServiceContracts.swift` の `SoratomoSkyPresence` を `case present(SoratomoReactions)` にする。1.3（Q6）で数えた `.present` の一致（詳細の `case .success(.present)`・`SoratomoServiceMocks.swift`・既存のテスト）を、`.present(_)` か `.present(.empty)` に直す
  - `SoratomoTimelineViewModel`: 変換後の投稿の並びの比較（design.mdのF3の行）で、リアクションだけの変化でも `skies` が変わることを、テストで固定する。`removeGoneSky(_:)` を足す（中身は既存の非公開の `removeFromTimeline` を呼ぶだけ・ほかは変えない）
  - `SoratomoSkyServiceTests`: `decodeSky` がリアクションを読む・壊れたリアクションで投稿を飛ばさない・`resolveObservedSky` が `.present(reactions)` を返す。`SoratomoTimelineViewModelTests`: リアクションだけが変わった結果で `skies` が変わる・`removeGoneSky` で消える
  - 陽性対照（C8）: `decode` が壊れた値で投げる（`decodeSky` の変換を失敗させる）写しで、壊れたリアクションの投稿が `decodeSkies` で飛ばされ、「投稿を飛ばさない」が赤になることを先に確かめる
  - 陽性対照（C7）: `SoratomoSky` の `Equatable` をリアクションを比べない形にした写しで、リアクションだけを変えた結果で `skies` が変わらず、テストが赤になることを先に確かめる
  - _Requirements: 2.5, 2.7, 8.6, 9.13, 11.2_

- [ ] 7.3 リアクションの通知のタップのテストを先に書き、今の現物（1.15.0と同じルーター）で赤を確かめる（陽性対照C6）
  - 前提: 1
  - 1.15.0の出し元を確かめる: 1.15.0（build 113）のarchiveの出し元は `08023ea7`（public-launch 12.1の結果。design.mdのF1も2026-10-18のタスクの承認のときに `9a56d5e8` から直した）。`git log --oneline 08023ea7..HEAD -- <SoratomoSkyService.swift・SoratomoModels.swift・SoratomoRouter.swift・GoldenHourNotificationManager.swift・project.pbxproj>` が空であることを確かめ、今のルーターが1.15.0のルーターと同じであることを結果に書く（空でなければ、`08023ea7` のルーターを写して同じテストを流す）
  - `SoratomoRouterTests` にテストを足す。今のAPIだけで書く（`receive(userInfo:)` に `["type": "soratomoReaction", "groupId": …, "postId": …]` を渡し、`resolvePending` → `reportAccessible` の後の `path` と、記録したイベントの名前とパラメータの文字列を見る）ので、今の現物でコンパイルできる
    - 期待: 一覧の上にそのグループのタイムラインが開き、`soratomo_notification_opened` が `type` = `reaction`・`result` = `opened` で1回記録される。起動していない状態からのタップ（保留→判定→表示）も同じ。抜けたグループ・未ログイン・匿名では、`soratomoPost` と同じ扱い（開かない・その結果で1回記録）
    - 既存の `soratomoPost` のテストは変えない（`post_created` のまま）
  - テストだけを足した作業ツリー（コミットしない）で、今の現物で流す。そのときの `HEAD` とテストのファイルの shasum の頭を結果に書く。新しいテストが「`path` が空・記録が0件」で赤になることを記録する。これは、1.15.0のアプリがリアクションの通知をタップされても、落ちず、遷移せず、新着投稿として記録しないことの証拠でもある
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 11.4, 11.5, 15.5_

- [ ] 7.4 ルーターと計測に、リアクションの通知と4つのイベントを足す（陽性対照C6・要確認Q6の反映）
  - 前提: 7.1, 7.3
  - `SoratomoRouter.swift`: `SoratomoNotificationKind`（`post`・`reaction`）と `reactionTypeValue = "soratomoReaction"` を足し、`parse` は2つの `type` で、`groupId` と `postId` が揃うときだけ返す。結果待ちを、グループIDと種類の組にする。記録は `.notificationOpened(result, type: kind.analyticsType)`。`signed_out`・`flag_off`・抜けたグループも同じ種類で記録する。`soratomoPost` の振る舞いと記録は変えない
  - `SoratomoAnalytics.swift`: design.mdの形で `SoratomoNotificationOpenType`・`SoratomoReactionFailAction`・`SoratomoReactionFailReason`（`init(_ error:)` の写し）と、`reactionAdded`・`reactionRemoved`・`reactionFailed`・`reactionsViewed` を足す。`notificationOpened` に `type`（既定は `.postCreated`）を足し、パラメータの `type` を `type.rawValue` にする。イベントの数のコメントに、このspecの4個を足す
  - 1.3（Q6）で数えた `notificationOpened` のパターンの一致を、値つきの形に直す
  - パラメータは列挙の値と数と真偽値だけにし、uid・グループID・投稿ID・名前・キャプション・招待コードが型の上で入らない
  - `SoratomoAnalyticsTests`: 4つのイベントの名前とパラメータ（`kind` は名前・`source` は `timeline`/`detail`・`replaced`・`action`・`reason`・`reaction_count`）・失敗の理由の写し方・`notificationOpened` の `type`（`post_created`・`reaction`）・名前とパラメータ名が英小文字のスネークケース。`SoratomoRouterTests`: 7.3で足したテストが緑になる
  - 陽性対照（C6）: 7.3で赤だったテストが、この変更で緑になったことを並べて記録する。イベントのパラメータ名を1つ変えた写しで計測のテストが、`parse` が `soratomoReaction` を `post` として返す写しで種類のテストが、それぞれ赤になることも確かめる
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 11.5, 15.1, 15.2, 15.3, 15.4, 15.5_

- [ ] 7.5 リアクションのサービス `SoratomoReactionService` を作る
  - 前提: 1.2（要確認Q3の結果の契約）, 7.1
  - `SoratomoServiceContracts.swift` に、design.mdの形で `SoratomoReactionOutcome`・`SoratomoReactionChange`・`SoratomoReactionServiceProtocol`・`SoratomoReactionDataSource` を置く。既存の `SoratomoSkyServiceProtocol` にはメソッドを足さない
  - `Services/SoratomoReactionService.swift`（新規）: Callable `soratomoSetReaction`、制限時間は既存の `SoratomoGroupService.callTimeout`。送る値は `groupId`・`skyId`・`kind`（外すときは1.2の結果の形）。失敗は `SoratomoGroupService.mapCallableError` で写す（`not_member`→`.notMember`・`sky_not_found`→`.skyGone`・`suspended`→`.suspended`・通信と制限時間切れ→`.network`。`self_reaction`・`invalid_reaction`・`invalid_input` は種類を作らず `.unknown`）。戻り値の形が違うときは失敗にせず、`SoratomoError.record`（固定の文脈）に残し、`outcome: .unchanged` と送った `kind` で返す
  - テスト用のモックは、`SoratomoServiceMocks.swift` に新しいクラスとして足す。`SoratomoReactionServiceTests`（新規・DataSourceのモック）: 送る値（名前・外す形）・応答の読み方・失敗の写し方（`not_member`・`sky_not_found`・`suspended`・`self_reaction`・通信）・形の違い
  - 陽性対照: 外すときの形を1.2の結果と違う形にした写しで送る値のテストが、`sky_not_found` を `.unknown` に写す写しで写し方のテストが、それぞれ赤になることを先に確かめる
  - _Requirements: 1.3, 1.4, 1.5, 4.15, 10.4, 10.7_

- [ ] 7.6 リアクションの操作の状態 `SoratomoReactionViewModel` を作る
  - 前提: 7.4, 7.5
  - `ViewModels/SoratomoReactionViewModel.swift`（新規）: design.mdの形で、`overlays`・`notice`・`canReact`・`isSending`・`summary(for:server:)`・`choose(_:for:server:source:)`・`didOpenReactors(count:)` と `SoratomoReactionNotice` を作る。依存はinitで受け取る（`groupId`・リアクションのサービス・`SoratomoBlockedAuthors`・`currentUid`・`isOnline`・`onSkyGone`・確定の上書きを手放すまでの時間・`sleep`・`logEvent`）
  - `choose`: 操作を出してよくない・送っている間は何もしない→同じ絵文字なら外す・違えば付ける→通信が無ければ送らずに通信の文言と `soratomo_reaction_failed`（`offline`）→上書きを `.sending` で入れて送る→成功なら `.confirmed` にして10秒後に同じ札のときだけ消し、`added`・`replaced`・`removed` を記録→失敗なら上書きをすぐ消し、文言を出し、`.skyGone` なら `onSkyGone`、`.unknown` なら `SoratomoError.record`、`soratomo_reaction_failed` を記録
  - D3の読み方（承認済み）: サーバーが `unchanged` を返したときは、`soratomo_reaction_added`・`soratomo_reaction_removed` を記録しない
  - `SoratomoBlockedAuthors` の `$ids` を購読し、変わったら `objectWillChange` を送る（ブロックの保存で、手動で更新しなくても数が変わる）
  - 文言はdesign.mdの表のとおり（内部のエラーコードを出さない・利用停止は既存の停止とお問い合わせの文言）。端末に操作を積まない
  - `SoratomoReactionViewModelTests`（新規）: オフラインでは呼ばない（`offline`）・送っている間は重ねない・自分の投稿とログアウト中は `canReact` が偽・同じ絵文字で外す/違う絵文字で付ける・成功の記録（`added`・`replaced`・`removed`、`unchanged` は記録しない）・失敗で上書きを戻す・各失敗の文言と理由・`skyGone` で `onSkyGone`・`.unknown` で記録・上書きは10秒後（差し替えた `sleep`）に消え、新しい上書きは消さない・ブロックの変化で `objectWillChange`・計測の値に名前やIDが入らない
  - 陽性対照: 失敗で上書きを戻さない写しで「失敗で戻す」が、札を見ずに10秒後に消す写しで「新しい上書きは消さない」が、`unchanged` でも記録する写しでD3のテストが、オフラインでも呼ぶ写しでオフラインのテストが、それぞれ赤になることを先に確かめる
  - _Requirements: 1.3, 1.4, 1.5, 1.6, 1.9, 1.10, 2.6, 5.2, 8.8, 10.1, 10.2, 10.3, 10.4, 10.5, 10.7, 14.1, 15.1, 15.3_

## (h) iOS: 画面と配線

- [ ] 8. iOSの画面を変える

- [ ] 8.1 リアクションの部品の画面（数の表示・メニュー・押した人の一覧）を作る
  - 前提: 7.1, 7.6
  - `Views/Soratomo/SoratomoReactionViews.swift`（新規）に、design.mdの「リアクションの部品の画面」のとおり3つを作る
    - `SoratomoReactionSummaryView`: 絵文字と数のカプセルを、絵文字の並び順に並べる（押せない）。自分の絵文字は色付きの枠と太字。0件なら何も出さない。VoiceOverでは `summary.accessibilityLabel` の1つの要素
    - `SoratomoReactionMenuButton`: `Menu` の中に7つのボタン（「{絵文字} {日本語名}」・いまの絵文字に `checkmark`）。見た目は、付けていなければ `face.smiling`、付けていればその絵文字。押せる範囲は44pt四方以上。VoiceOverのラベル（「リアクションを付ける」か「リアクションを変える。いまは{日本語名}」）とヒント（「同じ絵文字をもう一度選ぶと外れます」）。項目は日本語名で読み、いまの絵文字に `isSelected`。送っている間は無効
    - `SoratomoReactorsSheet`: 行は `UserAvatarView`・表示名・絵文字（表示名とアイコンは `SoratomoProfileStore` から出し、未設定と未取得はメンバー一覧と同じ代替）。開いたときに `prefetch`。行はVoiceOverで「{表示名}、{日本語名}」の1つの要素。ほかの人の分を外す・変える操作を置かない。題は「リアクション（{人数}人）」・右上に「閉じる」。中身を1件も読めていないときは「リアクションを読み込めませんでした」、開いている間に投稿が消えた・グループから外れたら「この投稿は表示できなくなりました」
  - シートは新しい画面にしない（ルーターの行き先と、画面名の計測 `logScreen` を足さない）。開いたことは `soratomo_reactions_viewed` で記録する（記録を呼ぶのは8.3）
  - ビルドが通り、Previewで3つの見た目（0件・自分の印あり・一覧の代替表示）を確かめる
  - _Requirements: 1.2, 2.1, 2.2, 2.3, 3.2, 3.3, 3.4, 3.7, 3.8, 8.7, 13.1, 13.2, 13.3, 13.5, 15.6_

- [ ] 8.2 容れ物とタイムラインに、リアクションのViewModelと操作を配線する
  - 前提: 7.2, 8.1
  - `SoratomoDependencies`: `reactionService` を足し、`live` で本物を入れる。`weak var activeReactionViewModel` を足す。`init` の引数が増えるので、組み立てている箇所を `grep -rn "SoratomoDependencies(" Soramoyou` で探して全部直す（`SoratomoDependenciesTests` とPreviewを含む）
  - `SoratomoTimelineView`: ViewModelの組（`makeViewModels`）に `SoratomoReactionViewModel` を足して3つにする（`onSkyGone` は `[weak timeline] in timeline?.removeGoneSky($0)`）。`@StateObject` で持ち、`.task` で `dependencies.activeReactionViewModel` に入れる
  - カード（`row(for:)`）をdesign.mdの形に組み直す。数の表示はカードの `Button` のラベルの中（押すと詳細へ進む）、リアクションのメニューはラベルの外の `overlay(alignment: .bottomTrailing)`（自分以外の投稿だけ）。`contextMenu` は `overlay` より先に付け、中身（削除、または通報とブロック）は変えない。`accessibilityHint("投稿を大きく表示します")` は変えず、`.accessibilityElement(children: .contain)` でカードのボタンとメニューを別の要素にする。自分以外の投稿では、右下のボタンの分の高さと幅を空けておく
  - 隠した投稿（ブロックした投稿者・この端末で通報した投稿）は今までどおり行ごと出ないので、操作も出ない
  - 失敗の知らせ（`reactionViewModel.notice`）は、タイムラインが一番上のときだけ出す（既存の `isShowingModerationNotice` と同じ型）
  - ビルドが通り、`SoratomoDependenciesTests` と `SoratomoTimelineViewModelTests` が通る
  - _Requirements: 1.1, 1.6, 1.7, 1.8, 1.11, 8.8, 12.9, 12.10, 13.4_

- [ ] 8.3 投稿詳細に、リアクションの欄と押した人の一覧の入口を置く
  - 前提: 8.2
  - `dependencies.activeReactionViewModel` を、グループIDが一致するときだけ借りる（`activeTimelineViewModel` と同じ）。借りられないとき（起きない想定）は数の表示だけを出し、ブロックの除外は `dependencies.blockedAuthors` で行う
  - `@State private var liveReactions` を足し、監視の `.success(.present(let reactions))` で入れる。表示に使う値は `liveReactions ?? sky.reactions`（覚えの値は最初の表示だけ）
  - `detail(sky)` の投稿者の行の下に、数の表示と、自分以外の投稿ならメニューを並べ、1人以上なら「押した人を見る（{人数}人）」のボタンを置く。押すとシートを出し、`didOpenReactors(count:)` を呼ぶ。投稿が消えた・グループから外れたら、シートは「この投稿は表示できなくなりました」を出す
  - 失敗の知らせは、詳細が開いている間は詳細が出す。「…」のメニュー（削除、または通報とブロック）は変えない
  - シミュレーター（`C2E3F752`）でビルドし、詳細の欄の並び（0件で数を出さない・自分の投稿にメニューが出ない）を目視する。本番のデータでの表示は13.1で行う
  - _Requirements: 1.1, 1.6, 2.4, 2.5, 3.1, 3.5, 8.7, 12.10, 15.1_

- [ ] 8.4 設定の「そらとも通知」の説明と What's New を、下書きの文言で直す
  - 前提: 1
  - `SettingsView` の「そらとも通知」の説明だけを、design.mdのU3の下書き「そらともで友達が空を投稿したときと、あなたの空にリアクションが付いたときにお知らせします」にする（確定は10）。グループごとにオフにできるとは書かない。「リアクション通知」の名前・説明・既定値、ほかの2つの通知設定、通知の事前説明の文言は変えない
  - `WhatsNewContent`: `currentID` を `"2026-10-soratomo-reactions"` にし、過去の値の一覧のコメントに `2026-10-soratomo-public` を足す。`pages` をリアクションの1ページだけにする（U1のA）。下書き: 記号 `face.smiling`・題「空にリアクション」・本文「友達の空に、7つの絵文字から1つを選んで\n気持ちを送れます\nカードの右下のボタンから」・バッジ「新機能」（絵文字は本文に入れない。確定は10）。オンボーディングは変えない
  - `WhatsNewGateTests.testCurrentIDDiffersFromPastIDs` の過去の値に `2026-10-soratomo-public` を足す（6つ）。既存の判定のテスト（オンボを終えた既存の利用者に1回だけ・オンボの完了で既読）はそのまま通す
  - 陽性対照: `currentID` を一時的に `2026-10-soratomo-public` に戻した写しで、過去の値と違うことのテストが赤になることを先に確かめる
  - _Requirements: 7.7, 7.8, 7.9, 7.10, 16.1, 16.2, 16.3_

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
