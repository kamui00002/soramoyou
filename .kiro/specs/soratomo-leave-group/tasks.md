# Implementation Plan

## 進め方の約束

- 作業ブランチは `機能-そらとも-グループだけ抜ける`（要件と設計のコミットが載っている・まだpushしていない）。mainへ直接コミット・pushしない。コミットは日本語（`機能:`・`修正:`・`ドキュメント:`）にする。コミットの前に `git status` を見て、対象のファイルを名前で `git add` する（`git add .` は使わない）。
- 着手の前に `git fetch -q origin` をして、`git log --oneline origin/main..HEAD` に載っているのが要件と設計のコミットだけであることを確かめる。mainが進んでいれば、取り込んでから始める。
- Functionsのデプロイは、mainを取り込んだ状態から行う（11.3では `HEAD == origin/main` のところから出す）。古いブランチから出すと、既存の関数が古いコードに戻る。
- 「（ユーザーのGOを取ってから実行）」と書いた操作は、利用者のGOを得るまで実行しない。AIが単独で実行しない。GOは1手ずつ取る（まとめて取らない）。確認とGOは、選択肢の形（AskUserQuestion）で聞く。対象は次のとおり。
  - pushとPRの作成・mainへのマージ
  - FirestoreのルールとFunctionsのデプロイ
  - 本番のFirestore・Auth・Storageへの読み書き（件数や項目名だけの読み取りと、クレームの付与を含む）
  - 本番の関数への直接の要求（要確認Q4）と、Cloud Schedulerの手動実行
  - TestFlightへの提出（このspecでは出さない。1.15.0のTestFlightと審査提出は、public-launch specが持つ）
  - 利用者に端末の操作を頼むこと（頼む前に「いまさわれる端末」を聞く）
- firebase CLIには必ず `--project soramoyou-ios` を付ける（`.firebaserc` が空のため）。
- 本番と端末の操作の結果は、そのタスクの下に「結果（日時）」の箇条で書く（release-gate specのtasks.mdの14〜17と同じ形）。書くのは内部IDの頭・件数・時刻・ハッシュの頭だけにする。グループ名・表示名・キャプション・招待コード・トークンは書かない。
- 各テストは、先に「わざと壊した実装かルール」で期待外れ（赤）になることを1回確かめてから、正しいもので通す（陽性対照）。各タスクの `陽性対照:` の行に、何を壊すとどのテストが赤になるかを書いた。取れなかったときは「検証済み」と書かず、取れなかった理由を記録する。
- design.mdのTesting Strategyの陽性対照C1〜C6の置き場は次のとおり。C1は2.1、C2は1.4と3.2、C3は1.4、C4は1.2、C5は6、C6は8.3と8.4。
- design.mdの「要確認」Q1〜Q7は、確かめるまで「検証済み」と書かない。確かめる場所は次のとおり。Q1は11.6、Q2は7.1と12.2、Q3は7.3と12.2、Q4は11.4、Q5は4、Q6は2.1、Q7は8.4と12.2。
- design.mdの「要件への差し戻し」D1〜D4は、利用者が「設計の読み方のまま進める」で承認済み（2026-10-11）。読み方は、D1を8.1と8.5、D2を8.1、D3を1.3と8.5、D4を6と8.1の詳細に書いた。
- もう1本のspec（`soratomo-public-launch`）との約束（public-launchの担当にも同じものを渡している）:
  - 実装の順番は、このspec → public-launch。このspecをmainへ入れ、本番へ反映し、受け入れの確認（12）を済ませてから、public-launchのPR-B（アプリ）とPR-A（サーバー）に進む。どちらのspecも `functions/soratomo.js`・`firestore.rules`・テストを触るので、specをまたいだ並行はしない。
  - 抜けるのCallable `soratomoLeaveGroup`（Callableの8本目）は、退会と同じ `requireFlag: false` で作る。関門の中身の置き換え（クレーム `soratomoBeta` →「登録済みでログイン・匿名は拒否」）と、`requireFlag: false` の1行の削除は、public-launchが行う。このspecは `isSoratomoUser()`・`requireSoratomoUser` の中身・`storage.rules` に触らない。`firestore.rules` には、拒否だけの `match`（`soratomoPendingLeaves`）を足すだけにする。
  - **順番の変更（2026-10-11 19:30・利用者の決定）**: public-launchは、このspecがmainへ入った直後（11.2の後）から、11.3〜13と並行して始めてよい。並行してよいのは、mainからブランチを切る・コードとテストを書く・PRを作るまで。mainへのマージ（public-launchの9.3と11.2）と本番の操作は、このspecの12〜13が済んでから行う（受け入れに使う開発版に、一般公開の変更を混ぜないため）。受け入れで直しが要ったら、このspecの修正としてmainへ入れ、public-launchのブランチをmainに合わせ直す
  - 本数の数え方を混ぜない。`functions/soratomo.js` の中は、Callable 8本・トリガー2本・定期実行1本の計11本（このspecでヘッダーと `functions/index.js:550` のコメントを直す）。本番の関数の全体は、21本から22本になる（public-launchの要確認8が使う）。
  - 本番への反映と受け入れの確認は、このtasks.mdの11と12が持つ。public-launchの手順書の段0-1が、ここの「結果」を見に来る。このときのルールの判定は、まだクレームの判定のまま。
  - 要件12.5（イベントの着弾の確認）は、public-launchのG4（段2-3・6-2）と同じ時点・同じ除外の条件で行う（13）。
- Functionsのテストは、`functions/` で、単体が `npm test`、エミュレーターが `npm run test:emulator`（firestoreとstorageを起こす）。lintは `npm run lint`。このspecは新しいテストのファイルを作らず、既存の `soratomoDeletion.test.js`・`soratomoStore.test.js`・`soratomo.test.js` に足す。新しいファイルを作るなら、`package.json` の `lint`・`test`・`test:emulator` に登録する。エミュレーターのポート（8080など）が別のセッションに使われていたら、ポートを替えた設定ファイルを `--config` で渡す（release-gate 14.1の前例）。
- ルールのテストは、リポジトリの直下で `python3 scripts/rules_test_soratomo.py`（通常）と `python3 scripts/rules_test_soratomo.py --mutants`（陽性対照）。rules test APIで評価するだけで、本番のデータに触れない。401が返るときは、`firebase projects:list` を一度実行してから再実行する。
- エミュレーターは、競合したトランザクションを `INVALID_ARGUMENT` で返すことがある（SDKは再試行しない）。同時実行のテストは、既存の要確認3のテスト（`soratomoDeletion.test.js`）の扱いに合わせる。
- iOSのビルドとテストは、`uptime` と `pgrep -x xcodebuild` で負荷とほかのビルドを見てから、`nice -n 19` と `-jobs 4` で1本ずつ行う（重ねて回すとMacごと落ちた先例がある。8コア・16GBで、Androidのエミュレーターが同時に動いていることが多い）。テストのシミュレーターは iPhone 17e `C2E3F752` を使う（共用の `BF678DA1` は使わない）。まず関係するテストのクラスだけを `-only-testing` で回し、最後に全体を1回回す。結果のログは `Test case`（小文字のc）でgrepする。
- 新しいSwiftファイルは、プロジェクトの同期グループが自動で拾う。pbxprojは触らない。既存のprotocolにはメソッドを足さない（既存のモックを壊さない）。
- `(P)` を付けたタスクは、前提に書いたタスクが済んでいれば、ほかのタスクと同時に進めてよい（触るファイルと資源が重ならない）。付けていないタスクは、同じファイルを触るか、前のタスクの成果物に依存するか、エミュレーターやビルドを共有する。iOSのタスクは、ファイルが別でも、ビルド・DerivedData・シミュレーターが1つで1本ずつしか回せないので `(P)` を付けない。
- Functions側（1〜5）とiOS側（6〜9）は別の境界で、サーバーの契約はdesign.mdのAPI Contractで固定済みなので、別のセッションで並行して進めてよい。
- このtasks.mdに `textlint --fix` を掛けない（見出しの番号の後の空白が消える）。

## (a) Functions: 共通の削除と、1グループ版の片づけ

- [x] 1. 共通の削除の部品を分け、1グループ版の片づけ（`leaveSoratomoGroup`）を作る

- [x] 1.1 共通の削除の部品を分け、消す前の照合の口を足す（退会の動きは変えない）
  - `functions/soratomoDeletion.js` の手順1（`leaveOrDeleteGroupTx`）を、読みの半分（グループ・メンバーの全文書・招待コードを読み、`core.planMembershipRemoval` で計画する）と、書きの半分（計画どおりに書く）の2つの内部関数に分ける。`leaveOrDeleteGroupTx` は、この2つを1つのトランザクションで呼ぶだけにする（戻り値と書き込みは今と同じ）
  - `deleteSkiesByQuery` と `deleteImagesByPrefix` に、省略できる引数 `beforeDelete`（消す前に呼ぶ。偽なら消さずに `{ done: true, deleted, stopped: true }` を返す）を足す。省略したとき（退会・利用停止・後始末・投稿1件の削除）は今と同じ動きにする
  - `deleteUserDataInGroup`・`deleteSoratomoUserData`・`removeMembershipCopyTx`・`finishUserTx` の中身と呼び方は変えない
  - 既存の `soratomoDeletion.test.js`（手順1・手順2〜4・時間の予算・要確認3・統合）と、`scripts/soratomo-admin` の単体とエミュレーターのテストが、無修正のまま通る
  - 陽性対照: `beforeDelete` を省略したときに消さない（既定で偽を返す）実装で、既存の退会のテスト（投稿と画像が消える）が赤になることを先に確かめる。書きの半分に計画を渡し忘れた実装で、既存の手順1のテストが赤になることも確かめる
  - _Requirements: 10.2_
  - 結果（2026-10-11 10:00）: 変更前の基準は `soratomoDeletion.test.js`＋`scripts/soratomo-admin.emulator.test.js` で 49/49（8080 が別セッションで使用中のため、ポート 8180/9160/9299/4420/4520 の設定を `--config` で渡した）。陽性対照 (a) `beforeDelete` の既定を偽にした実装で削除テスト 39 件中 19 件が赤（手順2〜4・時間の予算・利用者単位・投稿1件・統合・要確認3）。(b) 書きの半分で人数とオーナーを書かない実装で 11 件が赤（手順1の 5 件を含む）。正しい実装に戻して（shasum の頭 `dc888c240ff2` で一致を確認）`npm run lint` 通過・`npm test` 290/290・エミュレーター 49/49。テストのファイルは無修正

- [x] 1.2 片づけの手順1（`beginLeaveTx`）と、片づけ中の印を作る（陽性対照C4）
  - 前提: 1.1
  - `leaveSoratomoGroup(deps, { uid, groupId, deadlineMs, origin })` を `soratomoDeletion.js` に作り、`module.exports` に足す。引数の誤り（`uid` が `isUid` でない・`groupId` が `core.isAutoId` でない・締め切りが有限の数でない・`origin` が `self` と `sweep` のどちらでもない）は `TypeError` にして、何も書かない。回の札を作る `deps.newEpisodeId` は、省略したら `crypto.randomUUID()`（テストで差し替える）
  - 手順0: 締め切りを過ぎていれば、何もせずに `done: false` を返す
  - 手順1: 1つのトランザクションで、本人のメンバーの文書・所属の写し・印 `soratomoPendingLeaves/{uid}_{groupId}` を先に読み、design.mdの「手順1（`beginLeaveTx`）の判定」の表の6行どおりに動く（`nothing`・`started`・`stale_marker`・`continued`）。メンバーから外すときは、1.1の読みの半分と書きの半分を使う。人数は残りの数で代入し、オーナーは参加の古い順で1人にそろえ、招待コードは変えない。最後の1人なら、グループと招待コードを消す。同じトランザクションで印（`uid`・`groupId`・`episodeId`・`leftAt`）を書き、コミットした `episodeId` と `leftAt` を返す
  - メンバーでなく、写しと印のどちらも無い人（一度も入っていない・片づけが終わった）には、何も書かずに `state: "nothing"`・`done: true` を返す。素の `deleteUserDataInGroup` と違い、人数とオーナーを書き直さない（design.mdのP1）
  - 写しだけが残った人（印なし・退会の途中など）の `self` は、人数とオーナーを整え、印を新しく書いて続きを進める（`continued`）
  - 通報の記録・利用者の文書（同意と停止の項目）・ほかのグループの写し・`users/{uid}` には触れない。ログは出さない（呼び手が出す）
  - エミュレーターで確かめる: ただのメンバー・ほかにメンバーがいるオーナー（参加の古い人へ引き継ぎ、同じならuidの昇順、オーナーは1人、招待コードは同じ）・最後の1人（グループと招待コードが消える）・写しだけが残った人・メンバーでない人
  - 陽性対照（C4）: 場面は「人数をわざとずらしたグループに、メンバーでない人が抜けるを送る」。期待は、グループの文書・メンバー・写しが1バイトも変わらないこと（読み比べる）。メンバーでない人の判定を外した実装（既存の手順1と同じく人数とオーナーを書き直す）で、このテストが赤になることを先に確かめる。人数を「1減らす」だけの実装で、ずれた状態から始めたテストが赤になることも確かめる
  - _Requirements: 3.1, 3.2, 3.6, 3.7, 3.8, 3.10, 3.14_
  - 結果（2026-10-11 12:57）: `soratomoDeletion.test.js` に「抜ける手順1」のテストを10件足した（ただのメンバー・オーナーの引き継ぎ・最後の1人・写しだけ・印が残った人の続き・C4・stale_marker・sweepで印なし・古い印の上書き・締め切りと引数）。手順2〜4は1.3で足すまで、started と continued は `done: false` を返す。陽性対照C4: (a) メンバーでない人の判定を外した実装で C4 のテストが赤（1件）。(b) 人数を「1減らすだけ」の実装で11件が赤（抜けるの3件と、既存の手順1・統合・要確認3など）。どちらも正しい実装に戻して shasum の頭 `0a568ad36a07` で一致を確認。正しい実装で `npm run lint` 通過・`npm test` 290/290・エミュレーター（削除＋管理）59/59

- [x] 1.3 片づけの手順2〜4（照合・`finishLeaveTx`）と、時間の予算を作る
  - 前提: 1.2
  - 照合 `isLeaveEpisodeCurrent`: 印とメンバーの文書を `getAll` で2件読み、「印があり、`episodeId` が同じで、メンバーの文書が無い」ときだけ真にする
  - 手順2: 残るメンバーがいれば `authorId == uid` の投稿を、最後の1人ならグループの全投稿を、300件ずつ読み、照合し、消す。手順3: 残るメンバーがいれば `soratomo/{groupId}/{uid}/` の下（投稿データの無い取り残しの画像を含む）を、最後の1人なら `soratomo/{groupId}/` の下を、100件ずつ一覧し、照合し、消す。最後の1人なら、照合の後に残りの記録を `recursiveDelete` で消す。順はどれも「読む→照合→消す」（1.1の `beforeDelete` に照合を渡す）。照合が外れたら、何も消さずに `superseded`・`done: true` で止める
  - 手順4（トランザクション）: 利用者の文書・写しの全件・メンバーの文書・印を読む。印が同じ回で、メンバーの文書が無いときだけ、写し・印・（残るメンバーがいれば）通知の間引き `notifyState/{uid}` を消し、所属数を残りの写しの数で代入する。そうでなければ、何も書かずに `superseded`。`finishUserTx` は呼ばない（利用者の文書を消さない）
  - 時間の予算: 手順の前・投稿300件ごと・画像100件ごとに締め切りを確かめ、過ぎたら `done: false` を返す（印と写しが残り、次の呼び出しが続きから進む）。途中の失敗は投げ、印と写しは残す
  - 結果は `done`・`state`・`kind`・`removed`・`ownerTransferred`・`groupDeleted`・`skiesDeleted`・`imagesDeleted`（design.mdの `LeaveResult`）
  - D3の読み方（承認済み）: 確定より前に別の端末で始まった画像のアップロードが、手順3の一覧の後に届いた取り残しは、対象外として受け入れる（退会と同じ既知の隙間。アプリは処理中に投稿させない＝1.9）。テストで追わない
  - エミュレーターで確かめる（画像は偽のゲートウェイに置く）:
    - ただのメンバー: 本人の投稿・画像（取り残しを含む）・通知の間引き・写し・印が消え、人数は残りの数になる。ほかの人の投稿と画像・ほかのグループの投稿と画像と写しと通知の間引き・通報の記録・利用者の文書の同意と停止の項目・`users/{uid}`（そらとも通知の設定）は残る
    - 最後の1人: グループ・招待コード・全投稿・全画像・残りの記録が消え、その後の同じコードの参加は `not_found`
    - 予算: 投稿300件・画像100件の後に締め切りを過ぎると `done: false` で印と写しが残り、続きで消し切る。2回目は状態が変わらず件数が0
    - 途中の失敗: 画像の削除で投げさせると印と写しが残り、再実行で消し切る
  - 陽性対照: ほかのメンバーの投稿まで消す実装（`authorId` の条件を外す）で、残すべき投稿のテストが赤になることを先に確かめる。写しを手順2より先に消す順の実装で、途中の失敗の再実行が消し切れずに赤になることも確かめる
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.7, 3.3, 3.4, 3.5, 3.10, 3.11, 4.1, 4.2, 7.2_
  - 結果（2026-10-11 13:18）: `leaveSoratomoGroup` に手順2〜4を足した。照合の規則は純関数 `episodeMatches` の1か所に置き、`isLeaveEpisodeCurrent`（`getAll` で2件）と `finishLeaveTx`（トランザクション）の両方が使う。締め切りの確認は `deleteUserDataInGroup` と同じ位置（手順0・投稿300件ごと・画像100件ごと）。`soratomoDeletion.test.js` に5件足した（ただのメンバー・最後の1人とその後の `not_found`・予算の投稿・予算の画像・途中の失敗）。1.2のテストのうち印と写しの中身を見ていた6件は、手順4で印と写しが消えるため、`beginLeaveTx` を `module.exports` に足して手順1を直接呼ぶ形に書き直した（`leaveOrDeleteGroupTx` と同じ扱い）。陽性対照: (a) 投稿の `authorId` の条件を外した実装で、ただのメンバーのテストが赤（1件・`skiesDeleted` が2でなく4）。(b) 写しだけを手順2の前に消す実装で3件が赤（予算の2件と途中の失敗）。赤はどれも「写しが残る」の確かめで出た。再実行は印が続きの鍵なので消し切れてしまい、上に書いた「再実行が消し切れずに赤」の形にはならなかった（写しの役目は、片づけ中の参加を断る手がかり＝2.1）。どちらも正しい実装に戻して shasum の頭 `f032f535fa05` で一致を確認。正しい実装で `npm run lint` 通過・`npm test` 290/290・エミュレーター（削除＋管理）64/64（8080 が別セッションで使用中のため、1.1と同じ別ポートの設定を `--config` で渡した）。照合が外れる場面（`superseded`）のテストは1.4で足す

- [x] 1.4 入り直し・重なった実行・退会との重なりのテストを書く（陽性対照C2・C3）
  - 前提: 1.3
  - 場面の作り方は、既存のテスト（`soratomoDeletion.test.js` の「利用者単位: 並行した別の削除が先に終わり、本人が同意し直して同じグループへ入り直しても…」）と同じにする。偽のゲートウェイの `listFiles` で止める
  - 陽性対照C2（遅れた片づけ）: 1回目の片づけが終わり、本人が入り直して投稿と画像を作った後に、同じ印から片づけをもう一度流す。先に、今の部品 `deleteUserDataInGroup` で同じ場面を流し、入り直したメンバーを外し直して新しい投稿と画像を消す（赤）ことを確かめる。`leaveSoratomoGroup` の `origin: "sweep"` では、印だけを消して `stale_marker` で終え、メンバー・新しい投稿と画像・写し・所属数が変わらない
  - 陽性対照C3（重なった2つの実行）: 実行Aを画像の一覧の中で止め、その間に実行Bが最後まで終え、本人が入り直して新しい投稿と画像を作り、Aを再開する。先に、今の部品ならAの手順3が新しい画像を一覧して消す（赤）ことを確かめる。`leaveSoratomoGroup` では、Aが照合で `superseded` になって何も消さず、Bが消した写しは消えたまま、入り直した後の新しい写しは残る
  - 抜けて、入り直して、また抜ける: 1回目の遅れた実行（`episodeId` が古い）は、2回目の回の写しと印を消さない。2回目は自分で終える。陽性対照: 照合で印の有無だけを見て `episodeId` を比べない実装（research.mdの表B2）で、このテストが赤になることを先に確かめる
  - 退会・利用停止との重なり: 抜けるの途中で、退会（`deleteSoratomoUserData`）か利用停止（`suspendSoratomoUser`）が最後まで走っても、消す範囲・人数・所属数・オーナーが、順に行った場合と同じになる。退会の後に残った印は、続きの `leaveSoratomoGroup`（`sweep`）が `continued` か `stale_marker` として件数0で消す
  - _Requirements: 4.7, 8.6, 8.7, 10.6_
  - 結果（2026-10-11 13:32）: `soratomoDeletion.test.js` に6件足した（C2・C3・抜けて入り直してまた抜ける・退会と利用停止との重なり・退会の後に残った印の `continued`・同じく入り直した後の `stale_marker`）。偽のゲートウェイに `onList`（一覧の名前を作る前に待つ口・省略できる）を足し、実行を画像の一覧の中で止めた。実装（`soratomoDeletion.js`）は変えていない。照合で止まる `superseded` が通った場面は2件（C3の実行Aと、抜けて入り直してまた抜けるの1回目の実行）。重なりの比べ方は、同じ種から順に行った場合を先に流して、グループごとの人数・オーナー・役割・投稿・通知の間引き・写し・利用者の文書・印・画像を読み、重なった場合と突き合わせた（順に行った場合の値そのものも確かめた）。陽性対照: (C2・C3) `leaveSoratomoGroup` の中身を今の部品 `deleteUserDataInGroup` に差し替えた実装で、C2は「入り直したメンバーを外し直さない」で赤、C3は「入り直した後の画像は残る」で赤（n1の画像2枚が消えた）、抜けて入り直してまた抜けるは「2回目の回の写しを消さない」で赤。同じ実装で、印の残った退会の後の2件も赤になったが、これは差し替えた実装が `leftAt` の時計を呼ばないぶん締め切りの数え方がずれたためで、ふるまいの対照ではない。重なりのテストは、今の部品でも緑だった（退会の部品も同じ結果になるため・陽性対照は課していない）。(B2) 照合で `episodeId` を比べない実装で、抜けて入り直してまた抜けるの1件だけが「2回目の回の印を消さない」で赤。どちらも正しい実装に戻して shasum の頭 `f032f535fa05` で一致を確認。正しい実装で `npm run lint` 通過・`npm test` 290/290・エミュレーター（削除＋管理）70/70。エミュレーターの競合（`INVALID_ARGUMENT`）は出なかった（フックで直列に並べたため）

- [x] 2. 参加の判定に、片づけ中の `leave_pending` を足す

- [x] 2.1 `joinGroupTx` で、写しが残っている人の参加を `leave_pending` で断る（陽性対照C1・要確認Q6）
  - 前提: なし（1と同じエミュレーターと `functions/soratomo.js` を使うので、1と同時には進めない）
  - `functions/soratomoStore.js` の `joinGroupTx` の2回目の読み（`tx.getAll(groupRef, memberRef)`）に、所属の写し `soratomoUsers/{uid}/groups/{groupId}` を足す（読みはすべて書きの前）
  - 判定の順: …→コードの不在→既存のメンバー（今のまま）→写しがあれば `leave_pending`→所属10個→満員20人。所属10個より先に見るのは、片づけ中のグループが所属数に数えられたままで、`user_limit` と誤って案内しないため。印の有無は見ない（退会の途中の写しも同じく断る）
  - `SoratomoDomainError` の理由の型（JSDoc）に `leave_pending` を足す。`functions/soratomo.js` の `REASON_TO_CODE` に `leave_pending: "failed-precondition"` を足す
  - 参加の受け付けの条件と応答は、ほかに変えない。写しの重なりで `internal` になることを期待する既存のテストが無いことを、`ALREADY_EXISTS` と `internal` のgrepでもう一度確かめる
  - テスト: `soratomoStore.test.js` で、写しが残りメンバーの文書が無い人の参加が `leave_pending` になり、何も書かない。所属10個で写しが残っている人は、`user_limit` より先に `leave_pending`。`soratomo.test.js` で、参加のCallableが `failed-precondition`・`details.reason: "leave_pending"` を返す
  - 要確認Q6: 読みが1件増えても、既存の同時の参加のテスト（「同時の参加: 19人のグループへ25人が同時に参加しても、20人を超えない」と「同時の参加: 所属9個の人が25のグループへ同時に参加しても、10個を超えない」）がそのまま通るか。通らなければ、原因（エミュレーターの競合の返し方か、判定の誤りか）を切り分けて記録し、設計を変える前に利用者に相談する
  - 陽性対照（C1）: 今の現物（写しの判定が無い）で、同じ場面の参加が `SoratomoDomainError` でない失敗（`ALREADY_EXISTS`）になり、Callableでは `internal` になることを先に確かめる。写しの判定を所属10個の判定より後に置いた実装で、判定の順のテストが赤になることも確かめる
  - _Requirements: 8.4, 10.3_
  - 結果（2026-10-11 13:42）: 変更前の基準は、store・soratomo・削除の3ファイルで 162/162。`joinGroupTx` の2回目の `getAll` に写し（`copyRef`）を同じ呼び出しで足し、「既存のメンバー」の直後・所属10個の前で、写しがあれば `leave_pending` にした（印は見ない）。写しの作成も同じ `copyRef` を使う。`REASON_TO_CODE` に `leave_pending: "failed-precondition"` を、`SoratomoDomainError` のJSDocに理由を足した。テストは `soratomoStore.test.js` に2件（片づけ中の人の参加を印の無い形と有る形で・判定の順）、`soratomo.test.js` に1件（Callableの `failed-precondition`・`details` は `reason` だけ）。写しの重なりで `internal` を期待する既存のテストが無いことをgrepで確かめた（`internal` を期待するのは、要求IDの欠落と語のリストの未読込の3か所だけ）。陽性対照（C1）: テストだけを足した変更前の実装で3件が赤。トランザクション層は `6 ALREADY_EXISTS: entity already exists`（写しの文書）で `SoratomoDomainError` でない失敗、Callableは `internal`、判定の順は `user_limit`。写しの判定を所属10個の後ろに置いた実装で、判定の順のテストだけが赤（`user_limit`）。正しい実装に戻して shasum の頭 `c4bb9b89e36c` で一致を確認。要確認Q6: 同時の参加の2件（19人へ25人・所属9個の人が25のグループへ）は無修正で通った。内訳も変更前と同じ（成功1・`group_full` 24・競合0／成功1・`user_limit` 24・競合0）。正しい実装で `npm run lint` 通過・`npm test` 290/290・エミュレーター（store・soratomo・削除・管理）175/175

- [x] 2.2 片づけの後の入り直しと、同時実行のテストを書く
  - 前提: 1.3, 2.1
  - 片づけの後の入り直し: 新しいメンバーとして参加し、`role` は `member`（抜ける前にオーナーだったとしても戻さない）、`joinedAt` は入り直したときの時刻。人数と所属数がそろって1増える。抜けるで消した投稿と画像は戻らない
  - 同時実行（`soratomoStore.test.js`。既存の要確認3のテストの型）: 抜けると、ほかの人の参加・本人の別のグループへの参加・本人の入り直し・本人の別のグループの抜けるを、20回並べる。終わった後に、人数＝メンバーの文書の数・所属数＝写しの数・20人以下・10個以下で、写しとメンバーの文書が食い違わない。想定内の拒否に `leave_pending` を足す
  - 陽性対照: 人数を数え直さずに1減らすだけの実装と、所属数を1減らすだけの実装で、ずれが少なくとも1回出ることを確かめる。出なければ「この並べ方では検出できない」と記録し、コードの審査で補う
  - _Requirements: 3.12, 8.1, 8.2, 8.3, 8.7_
  - 結果（2026-10-11 13:57）: テストは2件で、置き場は `soratomoDeletion.test.js` にした（上の「`soratomoStore.test.js`」と違う。要確認3の型と、そのための部品＝偽のゲートウェイ・参加日時つきの種・印の読みがこのファイルにあり、写して二重に持たないため）。実装は変えていない。入り直し: オーナーだった人が抜けて入り直すと `member`、`joinedAt` は入り直した時刻、人数2→3・所属数0→1、消した投稿と画像は戻らない。同時実行: 抜けるの手順0を合図に、ほかの2人の参加・本人の別のグループへの参加・本人の入り直し・本人の別のグループの抜けるを0〜38msずらして発火し、20回並べた。どの回も、3つのグループで人数＝メンバーの件数・20人以下・オーナー1人、本人の写しとメンバーの文書がそろい、印が残らず、3人の所属数＝写しの件数・10個以下。分布は1回の例で、入り直しが「既存のメンバー」4・`leave_pending` 9〜11・新しく参加4〜5（3通りとも出た＝競合の場面を作れている）。エミュレーターの競合（`INVALID_ARGUMENT` など）は1回の実行で10〜12回出て、抜けるは続きを流して終えた（本番ならアプリの繰り返しか定期実行に当たる）。所要は約120秒（要確認3は約84秒）。陽性対照: 人数を「1減らすだけ」（`FieldValue.increment(-1)`）にした実装と、所属数を「1減らすだけ」にした実装は、どちらもこの並べ方では検出できなかった（20回とも緑）。人数は手順1と参加がグループの文書を、所属数は手順4と参加が利用者の文書を、どちらもトランザクションで読んで書くので直列になり、正しい値から1減らしても同じ結果になるため（コードの審査）。代わりに、人数の「1減らすだけ」は1.2の陽性対照（ずれた人数から始める11件が赤）が、所属数の「1減らすだけ」は1.4の利用停止との重なりのテスト（停止が所属数を0にした後に手順4が走り `groupCount` が -1）が捕まえることを確かめた。正しい実装に戻して shasum の頭 `f032f535fa05` で一致を確認。正しい実装で `npm run lint` 通過・`npm test` 290/290・エミュレーター（store・soratomo・削除・管理）177/177

## (b) Functions: Callableと定期実行の配線

- [x] 3. 抜けるのCallableと、定期実行の仕事Cを配線する

- [x] 3.1 抜けるのCallable `soratomoLeaveGroup` を作る
  - 前提: 1.3, 2.1（同じ `functions/soratomo.js` を触る）
  - `functions/soratomo.js` の `soratomoDeleteMyData` の直後に、`soratomoCallable` で作る。選択肢は `requireFlag: false` と `runtime: { timeoutSeconds: 120, memory: "512MiB" }`。`requireFlag: false` の理由（機能フラグの状態に関わらず、自分のデータを消す方向の操作を受け付けるため・要件2.6と9.1）をコメントに残す。ログイン（匿名を含む）は既存の関門が求める。関門の中身は変えない
  - 抜ける相手は `request.auth.uid` だけ。要求の本文からは `groupId` だけを読む。`core.isAutoId(groupId)` でなければ `SoratomoDomainError("invalid_input")`（`soratomoCreateSky` と同じ型）。利用停止・同意・機能フラグは確かめない
  - 1回の予算は `DELETE_BUDGET_MS`（45秒）にして、`leaveSoratomoGroup({ db, storage, nowMs }, { uid, groupId, deadlineMs, origin: "self" })` を呼ぶ。応答は `{ done, groupDeleted }`（`groupDeleted` は `kind === "delete_group"`）。メンバーでない人には `{ done: true, groupDeleted: false }` を返し、`not_member` は返さない
  - 成功のログ `soratomoLeaveGroup: ok` の項目は、design.mdのAPI Contractの10項目（`uid`・`groupId`・`done`・`state`・`kind`・`removed`・`ownerTransferred`・`groupDeleted`・`skiesDeleted`・`imagesDeleted`）だけにする
  - `module.exports` に足す（11本目）。`functions/soratomo.js` のヘッダー（2行目のCallableの本数を7から8に・10〜11行目の説明に `soratomoLeaveGroup` を足す・20行目の本数を10から11に）と、`functions/index.js:550` のコメント（Callable 7本から8本に）を直す
  - `soratomo.test.js` の `CALLABLES`（クレームを確かめる6本）には足さない（退会と同じく確かめない側。関門の変更はpublic-launchが扱う）
  - テスト（`soratomo.test.js`・`.run()` で呼ぶ）: 未ログインは `unauthenticated` で何も消さない。クレームの無い人・`soratomoBeta: false` の人・利用停止中の人・ガイドラインに未同意の人も抜けられる。`groupId` が自動IDの形でなければ `invalid_input` で何も書かない。本文に他人の `uid` を書いても、本人だけが抜ける。メンバーでない人には `{ done: true, groupDeleted: false }` で、何も変わらない。応答のキーは `done` と `groupDeleted` だけ。ログの項目に、グループ名・表示名・キャプション・招待コードが無い。関数の設定（120秒・512MiB・リージョン）
  - 陽性対照: `requireFlag: false` を外した実装で、クレームの無い人のテストが赤になることを先に確かめる。本文の `uid` を使う実装で他人のテストが、ログにグループ名を混ぜた実装でログの検査が、それぞれ赤になることも確かめる
  - _Requirements: 2.6, 3.13, 3.14, 4.1, 9.1, 9.2, 9.3, 9.4, 9.6, 11.2, 11.3, 11.4_
  - 結果（2026-10-11 14:05）: `soratomoDeleteMyData` の直後に `soratomoLeaveGroup` を置いた（`requireFlag: false`・120秒・512MiB・予算45秒・`origin: "self"`）。`groupId` が自動IDの形でなければ `invalid_input`。応答は `{ done, groupDeleted }`（`groupDeleted` は `kind === "delete_group"`）、成功のログは design の10項目。ヘッダーの本数（Callable 8本・公開11本）・説明・`soratomoCallable` の `requireFlag` の説明（false にしてよいのは退会と抜けるだけ）・`index.js:550`（Callable 8本）を直した。`CALLABLES` には足さず、そのコメントだけ「退会と抜ける以外」に直した。テストは `soratomo.test.js` に6件（未ログイン・クレーム無し/false/利用停止/未同意の4通り・`invalid_input` の7通りで印も書かず internal にもしない・他人の uid とメンバーでない人・最後の1人の `groupDeleted: true` とログの項目と名前などが出ないこと・関数の設定と公開する関数が11本）。陽性対照: (a) `requireFlag: false` を外した実装で、クレーム無しのテストが `permission-denied`（`flag_off`）で赤（クレーム `{}` の人を使う他人のテストも赤・2件）。(b) 本文の `uid` を使う実装で、他人のテストだけが赤（alice が外れた）。(c) 成功のログにグループ名を混ぜた実装で、ログのテストだけが赤。正しい実装に戻して shasum の頭 `d55a373db2a4` で一致を確認。正しい実装で `npm run lint` 通過・`npm test` 290/290・エミュレーター（store・soratomo・削除・管理）183/183

- [x] 3.2 定期実行に、途中で止まった抜けるを終える仕事Cを足す（陽性対照C2のサーバー版）
  - 前提: 1.4, 3.1
  - `soratomoHousekeeping` の中で、仕事Aより先に、別の `try` で囲んで実行する（失敗しても仕事Aと仕事Bを止めない）。予算は開始から `LEAVE_SWEEP_BUDGET_MS`（120秒）。仕事Aの締め切り（開始から480秒）は今のまま
  - 印を `where("leftAt", "<=", 今−30分)`・`orderBy("leftAt")`・`limit(50)` で読み、`startAfter` で次のページへ進む。30分より新しい印は扱わない（アプリの繰り返し、最大8回×75秒と重ねないため）。`firestore.indexes.json` は変えない（単一項目の自動インデックスで動く見込み。本番では要確認Q1で確かめる）
  - 印の形を確かめる: `uid` が `isUid`・`groupId` が `isAutoId`・文書IDが `${uid}_${groupId}`。外れたら `soratomoLeave: malformed_marker`（`markerId`）をwarnで出して飛ばす（消さない・開発者が確かめる）
  - 各印で `leaveSoratomoGroup(..., { origin: "sweep" })` を呼ぶ。1件の失敗で残りを止めない。ログは次のとおり（内部IDと件数だけ）
    - 1件ごと: `soratomoLeave: swept`（`uid`・`groupId`・結果の項目・`ageMs`）
    - 終わらないか失敗して、`ageMs` が24時間を超えた: `soratomoLeave: overdue`（`uid`・`groupId`・`ageMs`）をwarn
    - 失敗: `soratomoLeave: sweep_item_failed`（`uid`・`groupId`・`errorName`・`errorCode`）をerror
    - 実行ごと: `soratomoHousekeeping: leave_sweep`（`scanned`・`completed`・`unfinished`・`overdue`・`malformed`・`failed`）
  - `functions/soratomo.js` のヘッダー（16〜17行目）と `soratomoHousekeeping` のコメントに、仕事Cを足す
  - テスト（`soratomo.test.js`）: 30分より前の印を終えて `swept` を出す。30分より新しい印は触らない。24時間を過ぎて終わらないものに `overdue` を出す（終わらない状態は、偽のゲートウェイの失敗で作る）。形の違う印は飛ばして `malformed_marker` を出す。仕事Cが例外で止まっても、仕事Aと仕事Bは動く。仕事Cは仕事Aより先に動く。ログに名前などが無い
  - 陽性対照（C2のサーバー版）: `origin: "self"` で呼ぶ実装で、メンバーの文書がある印（入り直した後）のテストが、メンバーを外して赤になることを先に確かめる。30分の条件を外した実装で、新しい印のテストが赤になることも確かめる
  - _Requirements: 4.6, 4.8, 11.2, 11.3, 11.5_
  - 結果（2026-10-11 14:12）: `functions/soratomo.js` に `sweepPendingLeaves` を足し、`soratomoHousekeeping` の中で仕事Aより先に別の `try` で呼ぶ（失敗のログは `soratomoHousekeeping: leave_sweep_failed`）。印は `where("leftAt", "<=", 開始−30分)`・`orderBy("leftAt")`・`limit(50)`・`startAfter` で読む。`firestore.indexes.json` は変えていない（エミュレーターでは単一項目で動いた。本番は要確認Q1＝11.6）。印の形の検査には `soratomoDeletion.js` の `isUid` を export して同じ規則を使った。ヘッダーと `soratomoHousekeeping` のコメントに仕事Cを足した。テストは `soratomo.test.js` に5件（30分より前の印を終えて `swept`・30分より新しい印は触らない・仕事Aより先・ログに名前などが出ない／入り直した後の印は `stale_marker` でメンバーを外さない／24時間を過ぎて失敗したものに `overdue`（warn）と `sweep_item_failed`（error）・印と写しが残り次の実行で終える／形の違う印4通りを消さずに `malformed_marker`／仕事Cがクエリで例外を投げても仕事Aと仕事Bが動く）。仕事Cのテストでは、印の人のアカウントを `claims` に入れて、仕事Aに消されないようにした。陽性対照: (C2のサーバー版) 仕事Cが `origin: "self"` で呼ぶ実装で、入り直した後の印のテストだけが「入り直したメンバーを外し直さない」で赤。30分の条件を外した実装で、30分より前の印のテストだけが「30分より新しい印には触らない」で赤（新しい印の片づけまで進んだ）。正しい実装に戻して shasum の頭 `5fd09cad4ac2` で一致を確認。正しい実装で `npm run lint` 通過・`npm test` 290/290・エミュレーター（store・soratomo・削除・管理）188/188

## (c) Firestoreのルール

- [x] 4. (P) Firestoreのルールに、片づけ中の印の拒否を足す（要確認Q5）
  - `firestore.rules` の `soratomoConfig` の節の直後（いまの657行目の閉じかっこの前）に、`match /soratomoPendingLeaves/{markerId} { allow read, write: if false; }` を、design.mdの2行のコメントつきで足す。既存の行は、641行目のコメントの数（「次の 2 つは」→「次の 3 つは」）を直すだけにする。行番号は、書く前に現物で確かめる
  - `isSoratomoUser()` とその呼び出しの行には触れない（public-launchが変える）。`storage.rules` と `firestore.indexes.json` は変えない
  - `scripts/rules_test_soratomo.py`: `closed_collection_cases()` の `targets` に `soratomoPendingLeaves`（文書IDは `{uid}_{groupId}` の形・項目は印の4つ）を足し、get・list・create・update・deleteが、本人（クレームあり）・ほかのメンバー・未ログインのどれでも拒否されるケースにする。docstringとファイルの先頭のspecの一覧に、このspecを足す
  - 要確認Q5: `MUTANTS` に、`match` の行から `if false` までを置き換え元にした「片づけ中の印の読み書きを許す」を足し、置き換え元が1回だけ現れる検査を通ることを確かめる
  - 差分が「新しい `match` とコメントの数」だけで、既存の `match` の条件を緩めていないことを、差分で確かめる
  - 陽性対照: `--mutants` で、新しい壊し方が新しいケースを期待外れにすること。どの壊し方でも期待外れにならないケースが0件であること。通常の実行がすべて期待どおりであること
  - ここではルールをデプロイしない（11.5で行う）
  - _Requirements: 10.4_
  - 結果（2026-10-11 14:16）: 行番号を現物で確かめた（641行目のコメント・654〜656行目の `soratomoConfig`・657行目の閉じかっこ。design のとおり）。`soratomoConfig` の節の直後に `match /soratomoPendingLeaves/{markerId}` を design の2行のコメントつきで足し、641行目のコメントを「次の 3 つは」に直した。差分はこの2か所だけで、既存の `match` の条件・`isSoratomoUser()`・`storage.rules`・`firestore.indexes.json` は変えていない（`git diff --stat` で firestore.rules とテストのスクリプトの2ファイルだけ）。`scripts/rules_test_soratomo.py`: 閉じたコレクションに「片づけ中の印」（文書IDは `member_g1`・項目は印の4つ）を足し、本人（クレームあり）・ほかのメンバー・投稿者・未ログインの get・list・create・update・delete の20件を拒否のケースにした（印のときだけ立場の呼び名を「本人」にし、既存のケースの名前は変えていない）。docstringとファイルの先頭のspecの一覧に、このspecを足した。要確認Q5: `MUTANTS` に「片づけ中の印の読み書きを許す」（`match` の行から `if false` までを置き換え元）を足し、置き換え元が1回だけ現れる検査を通った。変更前の基準は通常 96/96・壊し方20個で取りこぼし0（401 が返ったので `firebase projects:list` を一度実行してから回した）。陽性対照: `--mutants` で、新しい壊し方が新しい20件をすべて期待外れにした。壊し方21個で、どの壊し方でも期待外れにならないケースは0件（終了コード0）。通常の実行は 116/116（終了コード0）。ルールはデプロイしていない

## (d) Functionsとルールのまとめ

- [x] 5. Functionsとルールのテストをすべて通し、既存の動きを変えていないことを点検する
  - 前提: 1〜4
  - `functions/` で `npm run lint`・`npm test`・`npm run test:emulator` を通す。リポジトリの直下で `rules_test_soratomo.py`（通常と `--mutants`）を通す。ルールを変えていない `rules_test_post_update.py` と `rules_test_storage_soratomo.py` も通ることを見る
  - 差分で確かめる:
    - 既存のそらとものCallable（作成・参加・再発行・投稿・通報・同意・退会）の受け付けの条件と応答が、参加の `leave_pending` を除いて変わっていない
    - 退会・利用停止・アカウントの無い人の後始末・開発者の削除の、消す範囲と結果が変わっていない（既存のテストが無修正で通る）
    - 新着通知の宛先を、通知を作る時点のメンバーの文書から決める処理（`onSoratomoSkyCreated`）が変わっていない。抜けるで通知を送る処理（ほかのメンバーへ・新しいオーナーへ）を足していない
    - 既存のコレクションとStorageのパスの、クライアントのアクセスの条件を緩めていない。メンバー・グループ・所属の写しは、クライアントから書けないまま
  - 古い版（1.14.x）からの要求: 作成・参加・投稿・通報・同意・退会の既存のテストが無修正で通る（要求の形を変えていない）
  - サーバーのログ: 新しいログ（`soratomoLeaveGroup: ok`・`soratomoLeave:` の4つ・`soratomoHousekeeping: leave_sweep`）の項目に、グループ名・表示名・キャプション・招待コードが無いことを、コードで確かめる
  - 既存のテストのうちmainで既に落ちているものは、変更前のmainでも同じく落ちることを確かめて区別する
  - 陽性対照: 差分の確認は、わざと既存のルールに1行足して、確認に引っかかることを先に確かめる。ログの確認は、わざと新しいログに `name` を足して、確認に引っかかることを先に確かめる
  - _Requirements: 6.6, 6.8, 7.1, 9.6, 10.2, 10.3, 10.4, 10.5, 10.6, 11.2_
  - 結果（2026-10-11 14:24）: `functions/` で `npm run lint` 通過・`npm test` 290/290。`npm run test:emulator` に登録した7ファイルは、8080 が別セッションで使用中のため別ポートの設定（`--config`）で回して 213/213。ルールは `rules_test_soratomo.py` が通常 116/116・`--mutants` で壊し方21個・取りこぼし0。変えていない `rules_test_post_update.py` は 13/13、`rules_test_storage_soratomo.py` は 24/24。差分の確かめ（`git diff origin/main...HEAD`）: 既存のテストで消した行は、偽のゲートウェイの引数の説明と宣言（省略できる `onList` を足した）・`CALLABLES` のコメント1行・ルールのテストのループの組み方だけで、確かめ（assertion）は1行も消していない（退会・利用停止・後始末・開発者の削除と、作成・参加・投稿・通報・同意・退会の既存のテストが無修正で通った）。実装で消した行は、コメント・`require` の行（足すための書き換え）・参加の2行（写しの読みと作成の参照）だけで、既存のそらとものCallableの受け付けの条件と応答は、参加の `leave_pending` を除いて変わっていない。`onSoratomoSkyCreated` と通知の送信には差分が無く、抜けるで通知を送る処理も足していない。`storage.rules` と `firestore.indexes.json` は差分なし。検査（scratchpad の `check5.py`）: (1) 新しいログ7種（`soratomoLeaveGroup: ok`・`soratomoLeave:` の4つ・`soratomoHousekeeping: leave_sweep` と `leave_sweep_failed`）の項目をコードから抜き出し、内部IDと件数の許可リストと突き合わせた。グループ名・表示名・キャプション・招待コードの項目は無い。(2) firestore.rules の main との差分が、新しい `match` の6行とコメントの数の1行だけであることを確かめた。陽性対照: ログの検査は、仕事Cの `swept` に `name` を足した写しで引っかかった（終了コード1）。差分の検査は、通報の記録の `match` に `allow read: if isSoratomoUser();` を1行足した写しで「想定外に足した」と引っかかった（終了コード1）。本物はどちらも終了コード0。mainで既に落ちているテストは、このspecの範囲（Functionsとルール）には無かった（すべて通った）
  - 結果（/review-full の指摘F5の追加・2026-10-11 16:25）: 照合の「メンバーの文書が無い」を偽にするテストが無かったので、`soratomoDeletion.test.js` に2本足した（抜けるAを画像の一覧で止めている間に、本人の退会が最後まで走り、同意し直して入り直す。投稿あり／なし）。どちらも A が `superseded` で止まり、入り直した後のメンバー・投稿・画像・写し（所属数1）と印 e1 が残ることを確かめる。陽性対照: (a) `episodeMatches` の `!memberSnap.exists` を外した写しで、ファイル全体64件のうち新しい2本だけが赤（既存のC2・C3などは緑＝この穴は新しい2本でしか埋まらない）。(b) `finishLeaveTx` の照合だけからメンバーの条件を外した写しで、投稿なしの1本だけが赤（投稿なしは手順4の照合だけが守り、投稿ありは画像を消す前の照合で止まることの確かめ）。写しを戻して shasum の一致を確かめた後、`npm run lint` 通過・`npm test` 290/290・エミュレーターの7ファイルは別ポートの設定で 215/215。指摘F7・F8は design.md（U1・API Contract）と `soratomo.js` のコメントに1行ずつ書き、コードは変えていない

## (e) iOSアプリ

- [x] 6. iOSのエラーと計測の土台を作る（陽性対照C5）
  - 前提: なし（Functionsと別のセッションで並行してよい）
  - `SoratomoError.leavePending` を足す。文言は「このグループを抜けたときの片づけが、まだ終わっていません。しばらく時間をおいて（長いときは数時間）、もう一度お試しください」（利用者の判断U1のA）。`SoratomoGroupService.reasonToError` に `"leave_pending"` を足す
  - `SoratomoFailedAction` に、`.leaveGroup`（「グループを抜けられませんでした」）と `.prepareLeave`（「グループの情報を読み込めませんでした」）を足す。通信できないときは `SoratomoError.network.userMessage` を出す
  - 計測: `SoratomoEvent` に、`.groupLeft(role:groupDeleted:completed:)`（`soratomo_group_left`・`role`・`group_deleted`・`completed`）と `.leaveFailed(SoratomoLeaveFailReason)`（`soratomo_leave_failed`・`reason`）を足す。値の列挙 `SoratomoLeaveRole`（`owner`・`member`）と `SoratomoLeaveFailReason`（`network`・`unknown`）を足す。`SoratomoJoinFailReason` の末尾に `leavePending = "leave_pending"` を足し、`.leavePending` から写す（既存の値と並びは変えない）
  - `SoratomoAnalytics.swift` のイベントの数のコメント（「要件 14 の表の 17 個と、release-gate 要件 15.1 の表の 4 個」）に、このspecの2個を足す
  - D4の読み方（承認済み）: `soratomo_leave_failed` は、4.4に加えて「確定の時に通信が無かった」（1.7）でも `network` で記録する（記録を呼ぶのは8.1）。メニューを押したときの通信なしでは記録しない
  - パラメータは列挙の値と真偽値だけにし、グループ名・表示名・キャプション・招待コードが型の上で入らない
  - 単体テスト: `SoratomoGroupServiceTests`（`leave_pending` の写し）・`SoratomoErrorTests`（文言）・`SoratomoAnalyticsTests`（新しい2つのイベントの名前とパラメータ・`leave_pending` の値）
  - 陽性対照（C5）: 今の現物で、`mapCallableError` が `leave_pending` を `.unknown` にすることを先に確かめる。イベントのパラメータ名を1つ変えた実装で、計測のテストが赤になることも確かめる
  - _Requirements: 8.5, 11.1, 12.1, 12.2, 12.3, 12.4_
  - 結果（2026-10-11 17:19）:
    - 陽性対照（17:02〜17:16・C2E3F752・3クラス58件）: `reasonToError` に `leave_pending` が無い現物のままで、`SoratomoGroupServiceTests.testMapCallableError_leavePending` が赤（`.unknown` ≠ `.leavePending`＝C5）。計測の `group_deleted` を `groupDeleted` に変えた実装で `testLeaveGroupEventsHaveFixedNamesAndParameters` と `testNamesAndParameterKeysAreLowerSnakeCase` が赤。参加の写しから `.leavePending` を外した実装で `testJoinFailReasonMapping` が赤。赤はこの4本だけ（54件は通過）
    - 正しい版（写しを戻してshasumの一致を確認・`reasonToError` に1行）で、同じ3クラス58/58通過（17:16〜17:18・`-parallel-testing-enabled NO`）。件数はxcresultで数えた。変更した3ファイルに警告なし
    - `SoratomoLeaveFailReason` には `init(_:)` を付けていない（写す元の `SoratomoLeaveError` は7.1で作り、写し方は8.1で決める）
    - ⚠️ 1回目は並列テストでシミュレーターが複製され、5分平均のロードが一時72まで上がった。以後のiOSのテストは `-parallel-testing-enabled NO` を付ける

- [x] 7. iOSの部品を作る

- [x] 7.1 抜けるのサービス `SoratomoLeaveService` を作る（要確認Q2の前半）
  - 前提: 6
  - `SoratomoServiceContracts.swift` に、`SoratomoLeaveResult`・`SoratomoLeaveError`（`network`・`incomplete`・`unknown`）・`SoratomoMembershipCheck`（`member`・`notMember`・`unknown`）・`SoratomoLeaveServiceProtocol`・`SoratomoLeaveDataSource` を、design.mdの形で置く。既存の `SoratomoGroupServiceProtocol` にはメソッドを足さない
  - `Services/SoratomoLeaveService.swift`: 型は `SoratomoAccountDeletionService` にそろえる（Callableの窓口はDataSourceで差し替える）。`soratomoLeaveGroup` を、1回75秒・最大8回で、`done` が真になるまで呼ぶ。8回で終わらなければ `.incomplete`。失敗したら呼び直さずに投げる。応答の `groupDeleted` は、どれか1回で真なら真にする。戻り値の形の違いは `.unknown`
  - 失敗の写しは `SoratomoGroupService.mapCallableError` を使う。通信・制限時間切れは `.network`。それ以外は、`SoratomoError.record`（文脈は固定の文字列・IDを入れない）に残して `.unknown`
  - `membershipOnServer`: 自分のメンバーの文書を、キャッシュを使わずに（`source: .server`）読む。文書がある→`.member`。権限の拒否→`.notMember`。通信の失敗とそれ以外→`.unknown`
  - 要確認Q2: メンバーでない人の読みが `permissionDenied` で届くか（`notFound` でないか）は、12.2で、本番につないだ開発版で確かめる。違えば写しを直す。確かめるまで「検証済み」と書かない
  - テスト用のモックは、`SoratomoServiceMocks.swift` に新しいクラスとして足す。`SoratomoLeaveServiceTests`（新規・DataSourceのモック）: `done` まで呼ぶ・8回で `.incomplete`・通信の失敗は `.network`・形の違いは `.unknown`・`groupDeleted` はどれか1回で真なら真・権限の拒否は `.notMember`・通信の失敗は `.unknown`
  - 陽性対照: 1回で戻る実装で、繰り返しのテストが赤になることを先に確かめる。権限の拒否を `.unknown` に写す実装で、`.notMember` のテストが赤になることも確かめる
  - _Requirements: 4.3, 4.4, 4.5_
  - 結果（2026-10-11 18:07）:
    - 陽性対照（17:58〜18:02・C2E3F752・`SoratomoLeaveServiceTests` 16件＋`SoratomoServiceContractsTests` 16件＝32件）: 繰り返しを1回で戻す実装（`0 ..< Self.maxCalls` を `0 ..< 1`）で、`testLeaveCallsAgainUntilDone`・`testLeaveGivesUpAfterMaxCallsWithIncomplete`・`testLeaveSucceedsWhenDoneOnLastCall`・`testLeaveGroupDeletedIsTrueIfAnyCallSaysTrue`・`testLeaveStopsOnFailureAfterPartialProgress` が赤。権限の拒否を `.unknown` に写す実装で、`testMembershipIsNotMemberWhenPermissionDenied` が赤。赤はこの6本だけ（26件は通過）
    - 正しい版（写しを戻してshasumの一致を確認）で、同じ32/32通過（18:05〜18:07・`-parallel-testing-enabled NO`）。件数はxcresultで数えた。変更した4ファイルに警告なし
    - 下書きの判断: 「読めて文書が無い」は、design.mdに無い枝。ルールは読みを同じ文書の存在で許すので本番では起きないが、`resolveObservedGroup` の前例に合わせて `.notMember` にし、テスト（`testMembershipIsNotMemberWhenDocumentIsAbsentOnServer`）で固定した
    - `notFound` は `.unknown` にして記録に残す（文脈 `soratomo.leaveGroup.membership`）。12.2で `notFound` が来たかは、Crashlyticsのこの文脈で見られる。要確認Q2は未確認（検証済みでない）
    - モックは `MockSoratomoLeaveService`（`SoratomoServiceMocks.swift`。グループごとの結果と `onLeave` を持つ・8.1と8.4用）。窓口の偽物は、退会のテストの前例に合わせてテストのファイルの中に置いた
    - ⚠️ 陽性対照の回で、C2E3F752の起動と別のセッションの2台（BF678DA1・DCFBF2D6）が重なり、1分平均のロードが一時300まで上がった（メモリの空きは27%）。15未満に落ちるのを待ってから正しい版を回した

- [x] 7.2 抜けたグループの端末の記録 `SoratomoLeftGroups` を作る
  - 前提: 6
  - `Services/SoratomoLeftGroups.swift`: 利用者ごとのUserDefaultsのキー `soratomo.leftGroups.{uid}` に、グループIDのJSONの配列を持つ。上限は50件で、超えたら古いものから捨てる。メモリに持たず、毎回読む。保存の仕方は `SoratomoReportedSkies`（`SoratomoHiddenContent.swift`）にそろえる
  - 口は `contains`・`insert`・`remove`（どれも `uid` つき）。サインアウトでは消さない（同じ人が入り直したときも隠す）。退会の手順には足さない（退会を変えないため）
  - `SoratomoLeftGroupsTests`（新規）: 利用者ごとに分かれる（AのものがBに見えない）・作り直しても残る・上限50件・外せる
  - 陽性対照: 利用者ごとに分けず1つのキーに入れる実装で、「AのものがBに見えない」が赤になることを先に確かめる
  - _Requirements: 5.3, 5.6, 5.7_
  - 結果（2026-10-11 18:29）:
    - 陽性対照（18:14〜18:26・C2E3F752・`SoratomoLeftGroupsTests` 7件）: 読み書きのキーを `uid` によらず1つにした実装で、`testLeftGroupsAreSeparatedPerUser`（「Aの記録がBに見えている」）・`testRemoveTakesOutOnlyThatGroupOfThatUser`（「Aが外したらBの記録まで消えた」）・`testRemoveOfUnknownGroupDoesNothing` が赤。赤はこの3本だけ（上限・作り直し・キーの名前・読めない記録の4本は通過）。走らせる前に書いた予想と一致した
    - 正しい版（写しを戻してshasumの一致を確認）で、7/7通過（18:26〜18:28・`-parallel-testing-enabled NO`）。件数はxcresultで数えた。変更した2ファイルに警告なし（同じログに既存の `PaymentService.swift` の警告がファイル名つきで載ることで、検査が効いていることも確かめた）
    - design.mdとの違い: 型は `struct SoratomoLeftGroups: Sendable` でなく `@unchecked Sendable` にした。`UserDefaults` が `Sendable` でないため、素の `Sendable` だとSwift 5のモードでも警告が出る（`swiftc -typecheck` で確かめた）。`UserDefaults` はスレッド安全で、この型が持つのはその参照1本だけ（前例は `SoratomoProfileFirestoreFetcher`）。口（`maxCount`・`storageKey`・`init(defaults:)`・`contains`・`insert`・`remove`）は design のまま
    - 同じグループを足し直したら最新の扱いに移す（`SoratomoReportedSkies.add` と同じ）。消す口（`clear`・`erase`）は作らない（サインアウトで消さない・退会に足さない、を型で守る）
    - ⚠️ 陽性対照の回で、C2E3F752の起動と別のセッションの2台（BF678DA1・DCFBF2D6）が重なり、1分平均のロードが一時230まで上がった（メモリの空きは29%）。正しい版の回の終わりにも一時190を見た

- [x] 7.3 画像のキャッシュをグループごとに分け、投稿の覚えをグループ単位で消せるようにする（要確認Q3の前半）
  - 前提: 6
  - `SoratomoImageCache`（`SoratomoStorageImageProvider.swift`）に `cache(forStoragePath:)` を足す。パス `soratomo/{groupId}/…` のグループIDごとに、`ImageCache(name: "soratomo.{groupId}", cacheDirectoryURL: 親のフォルダ)` を返す（メモ化）。親のフォルダは `Caches/soratomo-images/`（テストでは一時フォルダに差し替えられる形にする）。パスの形が違えば、グループ外の共通のキャッシュを返す（壊れた値で落とさない）
  - メモリの上限は、1つのキャッシュの既定（物理メモリの1/4）を、所属の上限10で割った値にする（10個そろっても今と同じ合計）
  - `removeGroup(_:)`（そのグループのキャッシュのメモリとディスクを消し、フォルダを消す）を足す。`remove(_ paths:)` は、パスのグループのキャッシュから消す。`clear()`（サインアウト）は、すべてのグループのキャッシュと親のフォルダに加え、1.14.xの共通のキャッシュ `soratomo` も消す。`purgeLegacyIfNeeded()`（1.14.xの共通のキャッシュを1回だけ消す。印はUserDefaultsの `soratomo.legacyImageCachePurged`）を足す（呼ぶ場所は8.5）
  - KFImageの3か所（`SoratomoTimelineView.swift` の1か所・`SoratomoSkyDetailView.swift` の2か所）を、`.targetCache(SoratomoImageCache.cache(forStoragePath: path))` に替える。processorを付けない決まりは変えない。`.targetCache(SoratomoImageCache.shared)` を指すコメント（`SoratomoStorageImageProvider.swift`・`SoratomoSkyDetailView.swift`・`SoratomoTimelineView.swift`）も直す
  - `SoratomoSkyLookup.forget(groupId:)`（そのグループの投稿の覚えだけを消す）を足す
  - 要確認Q3: Kingfisher 8.6.2で、`ImageCache(name:cacheDirectoryURL:)` の置き場（`<親>/com.onevcat.Kingfisher.ImageCache.<name>`）・メモリの上限の変更・`clearCache` とフォルダの削除が期待どおりかを、シミュレーターのテストで確かめる。実機での確かめは12.2
  - テスト: 2つのグループに鍵を入れ、片方を `removeGroup` すると、もう片方が残る（一時フォルダで行う）。`forget(groupId:)` の後も、ほかのグループの覚えが残る
  - 陽性対照: `removeGroup` がすべてのグループを消す実装で、もう片方が残るテストが赤になることを先に確かめる
  - _Requirements: 5.4, 5.5_
  - 結果（2026-10-11 18:55）:
    - 陽性対照（18:39〜18:51・C2E3F752・`SoratomoImageCacheTests` 9件＋`SoratomoImageStoreTests` 17件＋`SoratomoDependenciesTests` 3件＝29件）: `removeGroup` がすべてのグループのメモリと親のフォルダを消す実装で `testRemoveGroupDropsOnlyThatGroup`（「ほかのグループのメモリまで消えた」「ほかのグループのディスクまで消えた」）が赤。`forget(groupId:)` がすべてを忘れる実装で `testSkyLookupForgetGroupKeepsOtherGroups` が赤。赤はこの2本だけ（27件は通過）。走らせる前に書いた予想と一致した
    - 正しい版（写しを戻してshasumの一致を確認）で、同じ29/29通過（18:51〜18:53・`-parallel-testing-enabled NO`）。件数はxcresultで数えた。変更した4つのソースと3つのテストのファイルに警告なし
    - 要確認Q3の前半（シミュレーター）: Kingfisher 8.6.2で、置き場が `親/com.onevcat.Kingfisher.ImageCache.soratomo.{groupId}` になること（`diskStorage.directoryURL` と自分で組む規則の一致）・メモリの上限の変更（物理メモリの1/4を `SoratomoGroupService.maxListedGroups`＝10で割った値）・`removeGroup` と `clear` のフォルダの削除を、テストで確かめた。実機での確かめは12.2（検証済みでない）
    - 中身は `SoratomoGroupImageCaches`（親のフォルダと受け皿を注入できるクラス・ロックで守る）。`SoratomoImageCache` の static の口（`cache(forStoragePath:)`・`remove`・`removeGroup`・`clear`・`purgeLegacyIfNeeded`）は design のまま、本番用の1つへ流す
    - design.mdとの違い: 「グループ外の共通のキャッシュ」は、1.14.xの共通のキャッシュ `shared`（名前 `soratomo`）をそのまま受け皿にした（パスの形が違うときだけ使う・ふつうは空）。上限は既定の1/4のままなので、10グループと合わせた合計は1/4を少し超えうる
    - キャッシュを作れない（フォルダを作れない）ときは、覚えずに受け皿を返し、IDを持たない専用のエラーで記録する（文脈 `soratomo.imageCache.create`）。Kingfisherのエラーはパス（グループIDを含む）を持つので、そのまま記録しない（要件11.1）
    - ⚠️ 8.5への申し送り: Kingfisherは書き込むときにフォルダが無ければ作り直す。`removeGroup` は、タイムラインを閉じて監視を止めた後に呼ぶ（画面が残ると、再描画でキャッシュとフォルダが戻る）。doc コメントに書いた
    - 既存のテスト `testRemoveDropsBothKeysOfThePostAndKeepsOthers` は、共通のキャッシュに入れていたので、グループのキャッシュに入れる形に直した（同じグループの別の投稿が残ることを見る）
    - 整形のフックが、Viewの2ファイルで無関係の行（`withActionMenu` のジェネリクス・コメントの字下げ）を書き換えたので、元に戻してPythonで変更だけを入れ直した
    - ⚠️ 正しい版の回の終わりに、1分平均のロードが一時302まで上がった（C2E3F752の起動と別のセッションの2台が重なった）

- [x] 7.4 容れ物 `SoratomoDependencies` に、新しい部品を載せる
  - 前提: 7.1, 7.2
  - `leaveService: any SoratomoLeaveServiceProtocol` と `leftGroups: SoratomoLeftGroups` を足し、`live` で本物を入れる
  - `init` の引数が増えるので、組み立てている箇所を `grep -rn "SoratomoDependencies(" Soramoyou` で探して全部直す（いまは `live` と `SoramoyouTests/SoratomoDependenciesTests.swift:48` の2か所）
  - ビルドが通り、既存の `SoratomoDependenciesTests` が通る
  - _Requirements: 4.3, 5.3_
  - 結果（2026-10-11 19:05）:
    - 容れ物に `leaveService`（本物は `SoratomoLeaveService()`）と `leftGroups`（本物は `SoratomoLeftGroups()`）を足した。組み立ては `live` とテストの2か所だけ（`grep -rn "SoratomoDependencies(" Soramoyou` で確認）。テストは `MockSoratomoLeaveService()` と、通報の記録と同じテスト用のUserDefaultsを渡す `SoratomoLeftGroups(defaults:)` にした。initの引数に既定値は付けていない（既存のinitの方針のまま）
    - `SoratomoDependenciesTests` 3/3通過（19:02〜19:04・C2E3F752・`-parallel-testing-enabled NO`）。件数はxcresultで数えた。ログで、変更した2ファイルがコンパイルされたことと、2ファイルに警告が無いことを確かめた
    - 陽性対照は取っていない（検証済みとは書かない）。このタスクは新しいテストを足さず、完了の条件はビルドと既存のテストのため。組み立ての取りこぼしは、initの引数が増えたことでコンパイラが拾う
    - design.mdの「`live` で `SoratomoRouter.shared.isLeftGroup` を配線する」は、ここではしない。`isLeftGroup` は8.3で作り、配線も8.3の本文が持つ（`live` は `static let` なので、ルーターへの代入を置く場所は8.3で決める）
    - ⚠️ テストの終わりに、1分平均のロードが一時253まで上がった（別のセッションのシミュレーターの起動と重なった）

- [x] 8. iOSの画面と配線を変える

- [x] 8.1 抜けるの画面の状態 `SoratomoLeaveViewModel` を作る
  - 前提: 7.1, 7.2, 7.3
  - `ViewModels/SoratomoLeaveViewModel.swift`: `phase`（`idle`・`preparing`・`confirming`・`leaving`）と `alertMessage`、`requestLeave()`・`cancel()`・`confirm()`・`absorbLostMembership(groupId:)`・純関数の `predict(members:ownerId:uid:)` を、design.mdの形で作る。依存はinitで受け取る（`groupId`・抜けるのサービス・グループのサービスの `fetchMembers`・`currentUid`・`isOnline`・`currentGroup`・`displayName`・`suspendTimeline`・`resumeTimeline`・`onLeft`・`logEvent`）
  - `requestLeave()`: 通信が無ければ、通信の文言だけを出す（計測は記録しない）。`preparing` にして、監視しているグループ（名前と `ownerId`）とメンバー一覧を読む。どれかが無い・失敗・自分がメンバー一覧にいないときは、「グループの情報を読み込めませんでした」を出して確認を出さずに `idle` へ戻る。予測（自分を除いた残りを `SoratomoGroupService.sortedForMembers` で並べ、先頭を引き継ぐ人にする。サーバーの `pickNextOwner` と同じ規則）をして、design.mdの「確認の文言」の表の3通り（共通・オーナーで引き継ぎあり・最後の1人）で確認を作る
  - D2の読み方（承認済み）: 引き継ぐ人の表示名だけが読めない（未設定・読み込みの失敗）ときは、メンバー一覧と同じ代替の「ユーザー」で確認を出す。1.8の「読めない」は、メンバー一覧（とグループ）を読めない場合とする
  - `confirm()`: もう一度通信を確かめ、無ければ通信の文言を出し、`soratomo_leave_failed`（`network`）を記録して `idle` へ戻る（D4）。あれば `leaving` にし、タイムラインの監視を止めてから、抜けるのサービスを呼ぶ。成功なら「抜けた後」へ進む（`completed: true`）
  - 失敗の後は、`membershipOnServer` で分ける。`.notMember` なら、4.5として「抜けた後」へ進む（`completed: false`。文言は「…を抜けました。残りの片づけは自動で終わります」）。`.member` か `.unknown` なら、4.4として失敗の文言を出し、監視を張り直し、`soratomo_leave_failed`（`network` か `unknown`）を記録して `idle` へ戻る（もう一度選べる）
  - D1の読み方（承認済み）: `.unknown` のときは「未確定の抜ける」を覚える。後で張り直した監視が `.notMember` を届けたら（`absorbLostMembership` が真を返す）、「グループを開けませんでした」を出さずに、4.5と同じく「抜けた後」へ進む（`completed: false`）。もう一度メニューを押して、メンバー一覧が `.notMember` で読めないときも同じに扱う
  - 「抜けた後」の順: 端末の記録（`SoratomoLeftGroups.insert`）→画像と投稿の覚え（`SoratomoImageCache.removeGroup` と `SoratomoSkyLookup.forget(groupId:)`。ブロックの一覧・通報の記録・表示名とアイコンの覚えには触れない）→計測（`soratomo_group_left`。`role` は予測の `isOwner`、`group_deleted` はサーバーの値か4.5なら予測の `isLastMember`、`completed` は上の値）→ルーター（一覧へ戻す）。一覧へ戻った時点で、抜けたグループが端末のどこにも出ないようにするため
  - 確認に出す引き継ぐ人の表示名は、画面にだけ出し、ログと計測に出さない
  - `SoratomoLeaveViewModelTests`（新規）: オフラインでは呼ばない・メンバー一覧を読めなければ確認を出さない・キャンセルで何も呼ばない・予測（オーナーで残りあり・参加日時が同じときのuidの順・最後の1人・ただのメンバー）・表示名の代替・成功の順（記録→キャッシュ→計測→ルーター）・計測の値に表示名が入らない・`.member` なら監視を張り直して `leave_failed`・`.notMember` なら `completed: false` で抜けた扱い・`.unknown` の後に監視が `.notMember` を届けたら抜けた扱い・確定の時の通信なしで `leave_failed`（`network`）・処理中の二重の確定を受け付けない
  - 陽性対照: 成功の後の順を入れ替えた実装（ルーターを先に呼ぶ）で、順のテストが赤になることを先に確かめる。`.notMember` を4.4として扱う実装と、計測に表示名を入れた実装で、それぞれ赤になることも確かめる
  - _Requirements: 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 4.3, 4.4, 4.5, 5.1, 5.4, 11.1, 12.1_
  - 結果（2026-10-11 20:20）:
    - 書き手と、別の点検役の 2 人で書いた（並列の Workflow `wf_91c2eb82-d64`・名前と型は契約 `.claude/handoffs/2026-10-11-材料/leave-group-8/contract.md` の「3」で固定）。書き手が回したのは構文の確かめ（`swiftc -parse`）だけで、型検査は下のビルドが初めて（20:08・エラーなし）
    - 陽性対照（20:10〜20:12・C2E3F752・8.1〜8.4 の壊した版 6 本をまとめて当てた 1 回・6 クラス 184 件）: ①成功の後の順を入れ替える（`onLeft` を先に呼ぶ）②`.notMember` を `.member` と同じ失敗として扱う ③計測の `role` を逆にする、を 1 つの壊した版にまとめた。このクラスの赤は `testConfirmSuccessRunsStepsInOrder`・`testGroupLeftEventMatchesExactlyAndCarriesNoNames`・`testFailureButNotMemberFinishesAsLeftWithoutCompletion`・`testUnknownMembershipThenLostMembershipFinishesAsLeft`・`testUnknownMembershipThenMenuWithNotMemberFinishesAsLeft`・`testConfirmIgnoresSecondConfirmWhileLeaving` の 6 本だけ（24 件は通過）。走らせる前に書いた予想と、名前の集合で一致した。どれも assert の失敗で、落ちて止まったテストは無い
    - ①②③を 1 版にまとめたので、「①だけで順のテストが赤」は単独では確かめていない（`testConfirmSuccessRunsStepsInOrder` は③でも赤になる）。①だけで赤になるのは `testConfirmIgnoresSecondConfirmWhileLeaving`（計測を見ず、呼んだ順だけを見る）で、失敗の文も `onLeft` が `rememberLeft` より前に来たことを示した
    - 「計測に表示名を入れた実装」は型の上で作れない（`SoratomoEvent.groupLeft` の引数は列挙と真偽値だけで、文字列が入らない）。代わりに③で、計測が `.groupLeft(...)` と完全に一致することを見るテストが赤になることを確かめた。同じテストが、パラメータのキーが `role`・`group_deleted`・`completed` の 3 つだけで、値にグループ名・表示名・グループ ID が無いことも見ている
    - 正しい版（写しを戻して shasum の一致を確認）で、30/30 通過（20:16〜20:17・`-parallel-testing-enabled NO`・6 クラス 184/184 の回）。件数は xcresult で数えた。ビルドのログで、このファイルとテストのファイルがコンパイルされたことと、警告が無いことを確かめた（同じログに既存の `PaymentService.swift` の警告がファイル名つきで載る＝検査は効いている）
    - design.md との違い①: design の「ViewModel は計測だけを行い、`onLeft` が記録・キャッシュ・ルーター（1・2・4）を行う」をやめ、記録とキャッシュを別のクロージャ（`rememberLeft`・`purgeLocalData`）に分け、ViewModel が 記録→画像と投稿の覚え→計測→ルーター の順に 1 回ずつ呼ぶ。design の分け方では、この tasks.md の順（計測は記録とキャッシュの後・ルーターの前）を守れないため
    - 確認の題は `{グループ名}を抜けますか？`（鉤括弧なし）にした。design.md 567 行は「{グループ名}」を抜けますか？（鉤括弧つき）。8.5 の本文の書き方と、既存のブロックの確認（`{表示名}さんをブロックしますか？`）にそろえた。画面に出すのは 8.5
    - 契約に無い小さな足し: 引き継ぐ人の表示名が空白・改行だけのときも代替の「ユーザー」にする（`RankingDisplayText.authorName` の規則と同じ）。メンバー一覧を読めなかったときは、固定の文脈 `soratomo.prepareLeave` で非致命エラーとして記録する（D1 の `.notMember` の経路では記録しない）。`requestLeave` の各 `await` の後で、`phase` が `.preparing` のままかを確かめ直す（待つ間に `absorbLostMembership` が「抜けた後」へ進めていたら、`.leaving` を上書きしないため）
    - uid は確認を出すときに読んだものを覚えて、`confirm()`・`absorbLostMembership`・「抜けた後」で使う（`currentUid()` を読み直さない）。テストの代役（処理中で止める門）はテストのファイルの中に `private` で置き、`SoratomoServiceMocks.swift` は変えていない
    - ⚠️ 陽性対照の回と正しい版の回の終わりに、C2E3F752 の起動と別のセッションの 2 台（BF678DA1・DCFBF2D6）が重なり、1 分平均のロードが一時 195・210 まで上がった。15 未満に落ちるのを待ってから次を回した

- [x] 8.2 タイムラインのViewModelに、監視を止める口を足す
  - 前提: 6
  - `SoratomoTimelineViewModel` に `suspendObservation()` を足す。グループとタイムラインの監視の札（`groupToken`・`timelineToken`）を手放して、監視を止める。再開は、既存の `start()` をもう一度呼ぶ（札が無いときだけ張る）
  - 止めた後は、監視の結果（`.notMember` を含む）がルーターへ届かず、「グループを開けませんでした」が出ない
  - `SoratomoTimelineViewModelTests`: `suspendObservation()` の後は監視の結果が届かない・`start()` で張り直す
  - 陽性対照: 札を手放さない実装で、止めた後に結果が届いてテストが赤になることを先に確かめる
  - _Requirements: 5.2_
  - 結果（2026-10-11 20:20）:
    - 陽性対照（20:10〜20:12・C2E3F752・8.1〜8.4 の壊した版 6 本をまとめて当てた 1 回・6 クラス 184 件）: `suspendObservation()` の中身を空にした版（札を手放さない）で、`testSuspendObservationStopsGroupResultsFromReachingRouter`・`testSuspendObservationStopsTimelineResultsFromReachingScreen`・`testSuspendObservationCancelsBothObservations`・`testStartAfterSuspendObservationObservesAgain`・`testSuspendObservationWithoutObservationDoesNotCrash` の 5 本が赤（既存の 40 件は通過）。走らせる前に書いた予想と一致した
    - 正しい版（写しを戻して shasum の一致を確認）で、45/45 通過（20:16〜20:17・同じ 184/184 の回）。件数は xcresult で数えた。変更した 2 ファイルに警告なし
    - 札は `cancel()` してから nil にする（ほかが札を持っていても止まるように）。再開は既存の `start()`（札が無いので、グループもタイムラインも張り直す）。張っていないときや 2 回続けて呼んでも何も起きない
    - ファイルの先頭のヘッダーの 8.2 の行は、点検役が足した（書き手が書き忘れていた）

- [x] 8.3 ルーターに、抜けた後の遷移と、抜けたグループの通知の扱いを足す（陽性対照C6の前半）
  - 前提: 7.2, 7.4
  - `SoratomoRouter.finishLeaving(groupId:notice:)` を足す。パスにそのグループの画面があれば `path = []` にし、`notice` を出す（既存の3秒の一時表示）。文言は「{グループ名}を抜けました」で、`SoratomoError.notMember.userMessage` とは違う固定の文にする
  - `resolvePending` の「フラグが有効」の枝で、行き先の `groupId` が抜けたグループの記録にあれば、タイムラインを開かない。`pending = nil`・`path = []`・`isPresented = true`・`notice = SoratomoError.notMember.userMessage` にして、`notificationOpened(.notMember)` を1回記録する。判定の口は `isLeftGroup: @MainActor (String) -> Bool` のプロパティ（既定は常に偽）。本物は `SoratomoLeftGroups` と `currentUid` から作り、`SoratomoDependencies.live` の組み立てで `SoratomoRouter.shared` に入れる
  - オンラインで、記録に無いグループの通知は今のまま
  - `SoratomoRouterTests`: `finishLeaving` は `path = []` にして、文言が「グループを開けませんでした」でない。抜けたグループの通知はタイムラインを開かず、`notificationOpened(.notMember)` を1回記録する
  - 陽性対照（C6）: 今の現物で、抜けたグループの通知がタイムラインを開くことを先に確かめる
  - _Requirements: 5.1, 5.2, 5.7_
  - 結果（2026-10-11 20:20）:
    - 陽性対照（20:10〜20:12・C2E3F752・8.1〜8.4 の壊した版 6 本をまとめて当てた 1 回・6 クラス 184 件・C6 の前半）: `resolvePending` の抜けたグループの枝を消し、`finishLeaving` の文言を `SoratomoError.notMember.userMessage` にした版で、`testResolvePending_leftGroupDoesNotOpenTimelineAndLogsNotMember`・`testResolvePending_leftGroupIsLoggedOnlyOnceEvenWhenCalledAgainOrClosed`・`testResolvePending_leftGroupSettlesPreviousAwaitingAsOpenedFirst`・`testFinishLeaving_clearsPathAndShowsLeftNoticeForTimeline`・`testFinishLeaving_clearsPathWhenMembersOrSkyDetailOfSameGroupIsOnPath`・`testFinishLeaving_clearsPathWhenInviteOfSameGroupIsOnPath` の 6 本が赤。「タイムラインを開かない」は `[.timeline(groupId: …)]` が開いて赤になった（＝今の現物では、抜けたグループの通知がタイムラインを開く）。緑のまま残る想定の 4 本（開けない間は保留のまま・別のグループの画面なら変えない・計測しない・記録に無いグループは今のまま）は通過
    - 容れ物: `isLeftGroup` が常に偽の版で `testIsLeftGroupIsTrueForRecordedGroupOfCurrentUser` だけが赤。走らせる前に書いた予想と、どちらも一致した
    - 正しい版（写しを戻して shasum の一致を確認）で、`SoratomoRouterTests` 53/53・`SoratomoDependenciesTests` 6/6 通過（20:16〜20:17・同じ 184/184 の回）。件数は xcresult で数えた。変更した 4 ファイルに警告なし
    - design.md との違い②: design と上の本文の「`SoratomoDependencies.live` の組み立てで `SoratomoRouter.shared` に入れる」をやめ、`SoratomoRouter.shared` の組み立てで、判定のたびに `SoratomoDependencies.live.isLeftGroup` を引く。`live` は遅延で初期化され、最初に触るのはそらともの全画面のカバーの中身（`MainTabView.swift:107`）なので、通知で冷えた起動をすると `resolvePending` が `live` より先に走り、`live` の中で代入すると判定が間に合わないため（引いた時点で `live` が作られる）
    - 初期化の輪が無いこと: `SoratomoRouter.shared` に触れるのは、View（`MainTabView`・`ContentView`・`SoratomoEntryButton`）と、通知のタップのデリゲートの `receive`（`GoldenHourNotificationManager.swift:253`）だけで、`live` に並ぶサービスの init からは触れない（grep で確認）。ルーターのファイルの先頭のヘッダーに、そらともの型 `SoratomoDependencies` を引くようになったことを書いた
    - パスの判定は `SoratomoRouter.swift` の末尾の `private extension SoratomoDestination`（`belongsTo(groupId:)`）。点検役が、メンバー一覧と投稿詳細のテストのパスにタイムラインを一緒に入れていた（`.timeline` だけを見る実装でも通ってしまう）のを、1 つずつ置く形に直した

- [x] 8.4 グループ一覧で抜けたグループを隠し、参加で記録を外す（陽性対照C6の後半・要確認Q7の判断）
  - 前提: 6, 7.1, 7.4
  - 一覧（`SoratomoGroupListViewModel.load()`）: 読んだグループのうち、記録にあるものは `membershipOnServer` を呼ぶ。`.member` なら記録から外して出す（別の端末で入り直した場合）。`.notMember` と `.unknown` なら出さない。オフラインでは `.unknown` になるので、端末のキャッシュに残った抜けたグループは出ない。記録に無いグループは今のまま（呼ばない）
  - 参加（`SoratomoGroupFormViewModel.submitJoin()`）: 成功したら、そのグループを記録から外す。`leave_pending` の失敗は、既存の失敗の表示で文言を出し、入力した招待コードを残す。`soratomo_join_failed` の `reason` は `leave_pending`
  - 要確認Q7: 入り直しの成功で、そのグループの端末の覚え（画像のキャッシュと投稿の覚え）も消すかを、実装の時に判断して結果に書く。消さない場合に古い投稿が一瞬出うるのは、見た目の問題として不具合にしない
  - `SoratomoGroupListViewModelTests`: 記録にあるグループは `.member` のときだけ出して記録から外す・`.notMember` と `.unknown` では出さない・記録に無いグループでは再確認を呼ばない。`SoratomoGroupFormViewModelTests`: `leave_pending` で入力が残り、`reason` が `leave_pending`・参加の成功で記録から外れる
  - 陽性対照（C6）: 今の現物で、記録にあるグループが（端末のキャッシュから）一覧に出ることを先に確かめる。参加の失敗で入力を消す実装で、テストが赤になることも確かめる
  - _Requirements: 5.3, 5.6, 8.1, 8.5, 12.3_
  - 結果（2026-10-11 20:20）:
    - 陽性対照（20:10〜20:12・C2E3F752・8.1〜8.4 の壊した版 6 本をまとめて当てた 1 回・6 クラス 184 件・C6 の後半）: 新しい init のまま、`load()` が記録を見ずに読んだグループをすべて出す版（前の一覧からも外さない）で、`testLeftGroupIsShownOnlyWhenServerSaysMemberAndRemovedFromRecord`・`testLeftGroupIsHiddenWhenServerSaysNotMember`・`testLeftGroupIsHiddenWhenMembershipUnknown`・`testOnlyMemberGroupAppearsWhenTwoAreRecorded`・`testOpenedGroupCountIsCountAfterHiding`・`testLeftGroupDisappearsFromPreviousListBeforeReloadFinishes` の 6 本が赤（＝今の現物の振る舞いでは、記録にあるグループが一覧に出る）。`testGroupNotInRecordIsShownWithoutMembershipCheck` は通過
    - 参加: 新しい init のまま、失敗のときに `inviteCodeInput = ""` にし、成功で記録を外さない版で、`testJoinLeavePendingKeepsInviteCodeAndLeftRecord`・`testJoinSuccessRemovesGroupFromLeftRecord` と、既存の `testJoinFailureKeepsInputAndShowsFixedMessage`・`testConsentRequiredOnJoinKeepsInviteCode`・`testRejectionMessagesKeepInputAndDoNotRevealWord` の 5 本が赤。走らせる前に書いた予想と、どちらも一致した
    - 正しい版（写しを戻して shasum の一致を確認）で、`SoratomoGroupListViewModelTests` 17/17・`SoratomoGroupFormViewModelTests` 33/33 通過（20:16〜20:17・同じ 184/184 の回）。件数は xcresult で数えた。View の 2 ファイルを含め、変更した 4 つのソースと 2 つのテストのファイルに警告なし
    - 要確認Q7の判断（design.md との違い④の扱い）: 入り直しの成功では、端末の画像のキャッシュと投稿の覚えを消さない。この端末で抜けたなら、抜けたときにもう消している。Q7 の「古い投稿が一瞬出る」は Firestore の端末のキャッシュ由来で、画像のキャッシュを消しても防げない。理由は `submitJoin` のコメントに残した。実機での確かめは 12.2（検証済みでない）
    - `leftGroups` の引数には既定値を付けていない（既定の `SoratomoLeftGroups()` は本物の UserDefaults に書くので、テストが本物の記録を汚す）。呼び出し（View の 2 か所・テスト）は全部直した。テストはテストごとの UserDefaults の suite を使い、`tearDown` で消す
    - design.md との違い⑤（点検役が足し、メインが残すと決めた）: `load()` で、最初の `await` より前に、前に読んだ一覧から記録にあるグループを外す。抜けた直後に一覧へ戻ると、読み直し（一覧の問い合わせと所属の確認）が終わるまで前の一覧が出たままになり、抜けたグループのカードを押すと「グループを開けませんでした」が出るため（要件 5.2・5.3）。サーバーで `.member` と分かったグループは読み直しで戻る。計測（`soratomo_opened` の 1 回）には触れない。テストは `testLeftGroupDisappearsFromPreviousListBeforeReloadFinishes`（問い合わせを止めておける代役をテストのファイルの中に置いた）
    - `leave_pending` の失敗は、ViewModel を変えずに既存の失敗の表示（`showSubmitFailure`・`SoratomoJoinFailReason(error)`）のまま通ることを、テストで固定した
    - 書き手の報告の「`makeViewModel` に `leftGroups` の引数を足した」は誤りで、現物は毎回テストの suite の記録を渡す（コードの問題ではない）

- [x] 8.5 タイムラインの画面に入口・確認・処理中の表示を置き、抜けた後の後片づけを配線する
  - 前提: 8.1, 8.2, 8.3, 8.4
  - 入口: 右上の `ToolbarItemGroup` の最後に `Menu`（`ellipsis.circle`）を足し、中身は「グループを抜ける」（`role: .destructive`）だけにする。既存の3つのボタン（メンバー一覧・招待・投稿）と、タイムラインの `init` の形は変えない。`SoratomoLeaveViewModel` は、タイムラインの `init` で `@StateObject` として作る
  - 確認: `phase` が `confirming` のとき、`.alert` に見出し「{グループ名}を抜けますか？」と本文、「キャンセル」（`.cancel`）と「抜ける」（`.destructive`）を出す（既存のブロックの確認と同じ型）。`alertMessage` はOKだけのアラートで出す
  - 処理中: `phase` が `leaving` の間、画面全体に半透明の覆いと `ProgressView` と「グループを抜けています…」を出し、内容・右上のボタン・戻るボタン（`navigationBarBackButtonHidden`）を無効にする。投稿の画面は開けない（D3の隙間を広げないため）
  - 配線: 監視を止める口と張り直す口に、8.2の `suspendObservation()` と `start()` をつなぐ。`reportNotAccessible` のクロージャは、先に `absorbLostMembership(groupId:)` を呼び、真ならルーターへ知らせない（D1）。抜けた後は、8.1の順（記録→画像と投稿の覚え→計測→`finishLeaving`）で進める
  - `SoratomoImageCache.purgeLegacyIfNeeded()` を、起動の後で、そらともの画像を読む前に1回呼ぶ場所に置く（置いた場所を結果に書く）
  - 確認と処理中は、新しい画面にしない（画面名を足さない）
  - シミュレーター（`C2E3F752`）でビルドして、メニューと、見られる組み合わせの確認の文言（キャンセルまで）を目視する。テスト用アカウントでのログインと、本番のデータの表示は、利用者のGOを取ってから行う。「抜ける」の確定は、本番にCallableがまだ無いのでここでは押さない（12.1で行う）
  - _Requirements: 1.1, 1.2, 1.3, 1.6, 1.9, 5.1, 5.4, 5.5_
  - 結果（2026-10-11 21:00）:
    - 入口: 右上の `ToolbarItemGroup` の最後に `Menu`（`ellipsis.circle`・VoiceOver は「その他の操作」）を足し、中身は「グループを抜ける」（`role: .destructive`）だけにした。既存の 3 つのボタンと、タイムラインの `init` の形は変えていない。画面名は足していない
    - 2 つの `@StateObject`: `init` のローカルの `var pair` と入れ子の関数 `makePair()` で、`_viewModel` と `_leaveViewModel` が同じ組を受け取る（オートクロージャは画面が最初に置かれたときだけ評価される）。組は `static makeViewModels` が作り、互いを弱参照でつなぐ（`weak var weakLeave`・`[weak timeline]`・`[weak router]`）。タイムラインの `reportNotAccessible` は先に `absorbLostMembership` を呼び、真ならルーターへ知らせない（D1）
    - 配線: `suspendTimeline` は `suspendObservation()`、`resumeTimeline` は `start()`、`rememberLeft` は `SoratomoLeftGroups.insert`、`purgeLocalData` は `SoratomoImageCache.removeGroup` と `SoratomoSkyLookup.forget(groupId:)`、`onLeft` は `SoratomoRouter.finishLeaving`。`displayName` は `profileStore.prefetch` の後、読めた人だけ表示名を返す（読めなければ nil → 代替の「ユーザー」・D2）
    - 確認: `.alert` に題 `confirmation.title`・本文 `confirmation.message`・「キャンセル」（`.cancel`・`cancel()`）と「抜ける」（`.destructive`・`Task { await confirm() }`）を出す。isPresented は `phase` から直接作らず、`phase` の変化（`onChange`）で `@State` の `leaveConfirmation` に写し、setter はそれを消すだけにした。setter で `cancel()` を呼ぶと確定が空振りし、getter を `phase` にすると閉じた直後に出し直しうるため。`alertMessage` は OK だけのアラートで出す
    - 処理中: `.leaving` の間、中身に `.disabled` と `.accessibilityHidden` を掛け、覆い（黒 30% の上に、素材の角丸で `ProgressView` と「グループを抜けています…」。VoiceOver では 1 つの要素で `.isModal`）を出し、`navigationBarBackButtonHidden` で戻るを隠す。投稿のシートは、右上の投稿と空の案内のボタンがどちらも無効なので開けない（D3）
    - `purgeLegacyIfNeeded()` の置き場: `SoratomoRootView` の `.task { await checkEntry() }` の先頭（変更前の 67 行の `.task`）。61 行の `.task(id: router.notice)` は一時表示のたびに走り、179 行の `.task` は一覧を出した後にしか走らないので使わない。一覧と通知の行き先は `checkEntry` の後に出るので、そらともの画像を読む前になる
    - design.md との違い⑥: 右上の 4 つ（メンバー・招待・投稿・メニュー）を、`.leaving` だけでなく `phase != .idle` の間（確認の材料を読む間と、確認を出している間を含む）無効にした。`.preparing` の間に別の画面へ進むと、確認がその画面の下で出ようとするため。中身は `.preparing` の間は止めない（止めると、読み込みの間に画面が固まって見えるため）
    - design.md との違い⑦: 確認と知らせは、タイムラインが一番上（`router.path.last`）で、投稿のシートと投稿の削除・通報・ブロックの確認が出ていないときだけ出す（`canPresentLeaveDialogs`）。既存の削除の失敗・通報とブロックの知らせと同じ門に、`.preparing` の間に開きうるシートと確認を足した。覆っていたものが閉じた時点で出る（内容は `@State` と ViewModel に残る）
    - design.md との違い⑧: 画像のキャッシュの消去を 2 回にした。1 回目は 8.1 の後片づけ（`purgeLocalData`）、2 回目はタイムラインの `.onDisappear` で、端末の記録にあるときだけ。閉じるまでの再描画と読み込み途中の画像で、Kingfisher がフォルダを作り直しうるため（7.3 の申し送り）。判定を記録で行うので、抜けられたか未確定のまま画面が閉じたときは消さない。投稿詳細を上に積んだときにも呼ばれるが、記録に無いので何もしない
    - ビルド（20:35・C2E3F752・`build-for-testing`）: エラー 0。ログで、変更した 2 ファイルがコンパイルされたことと、2 ファイルに警告が無いことを確かめた（同じログに既存の `PaymentService.swift` の警告が載る）。画面の配線だけなので、テストは足していない。全体のテストは 9.2 で回す
    - 敵対的な点検（Workflow `wf_b2af29a3-e3f`・opus）: 4 観点の点検役（① 2 つの `@StateObject` の組と弱参照 ② 確認と `phase` の競合 ③ 後片づけの順・2 回目の消去・purge の置き場・`.leaving` の画面 ④ 個人情報と VoiceOver）と、指摘ごとの反証役で見た。指摘 6 件（①0・②3・③2・④1）は、すべて反証された。直したものは無い
    - 反証された指摘のうち、実機で見る価値があるとされたもの: (a) iOS 26 の画面の中ほどからの戻るスワイプが、`.leaving` の間に止まるか（戻るボタンを隠すと止まる見込み・未確認）(b) `.preparing` の間に投稿詳細へ進んで戻ると、確認が出るか (c) 覆いが出たときに、VoiceOver の焦点が覆いへ移るか（改善の候補で、不具合ではない）。(a) と (c) は確定を押さないと見られないので 12.1 で見る
    - シミュレーターの目視（利用者の GO・20:38〜20:59・C2E3F752・テスト用アカウント S3）: このビルドを入れて起動し、前から入っていたアカウントはログアウトした（シミュレーターの中だけ）。最初の 3 回はログインに失敗した（記録の「+soratomo3」に、無いはずの頭を付けて推測したメールで 2 回、S4 で 1 回。どれも「メールアドレスまたはパスワードが正しくありません」）。利用者に正しいメールを聞いて、4 回目で入れた
    - 見たこと: メンバー 1 人のグループのタイムラインで、右上に 4 つ（メンバー・招待・投稿・「…」）が潰れずに並ぶ。「…」のメニューには赤字の「グループを抜ける」だけが出る。押すと、題「{グループ名}を抜けますか？」と、本文（共通の文＋空行＋最後の 1 人の文）、「キャンセル」と赤字の「抜ける」の確認が出る。確認の間は右上の 4 つが薄く（無効に）なる。「キャンセル」で確認が閉じ、タイムラインと人数は変わらず、右上が戻り、メニューをもう一度開ける。画面の写しは利用者へ送った。「抜ける」は押していない
    - 見られなかったもの（検証済みでない）: 確認の 3 通りのうち、オーナーで引き継ぎがある文と、ただのメンバーの文（S3 の 2 つのグループは、どちらもメンバーが 1 人のため）。`.leaving` の覆い・戻るの禁止・右上の無効（確定を押さないと出ない）。上の (a)〜(c)。どれも 12.1 で見る

- [x] 9. iOS全体を点検する

- [x] 9.1 ログと個人情報・変更なしで満たすこと・既存の挙動を点検する
  - 前提: 6〜8
  - そらともの端末のログ・クラッシュ記録・計測のパラメータに、グループ名・表示名（確認に出す引き継ぐ人の表示名を含む）・キャプション・招待コードが出ていないことを、コードの検索で確かめる。検索は、わざと1か所に該当の文字列を入れて、引っかかることを先に確かめる（陽性対照）
  - 変更なしで満たす要件を、コードで確かめる:
    - オーナーを引き継いだ人に、招待コードの再発行の操作が出る構造（`SoratomoInviteViewModel` のオーナーの判定）
    - 消えたグループのコードで「招待コードが見つかりません」が出る
    - ほかのメンバーのタイムラインが、監視で削除された投稿と人数を直す。投稿詳細が「この投稿は表示できなくなりました」を出し、落ちない。メンバー一覧と一覧が、開くたびに読み直し、オーナーに印を付ける
    - 抜けたことの知らせを、タイムラインや一覧に足していない
    - 端末の通知の許可と、そらとも以外の通知の設定に触れていない
    - ガイドラインに未同意のメンバーの入口で、一覧より先に全文が出る判定を変えていない
  - 差分で確かめる: 退会の確認の文言・手順・結果（設定画面と `SoratomoAccountDeletionService`）が変わっていない。新しいイベントと理由が、要件12の表と名前・パラメータ名で一致している
  - _Requirements: 3.9, 3.11, 6.1, 6.2, 6.3, 6.4, 6.5, 6.7, 7.3, 9.5, 10.1, 11.1, 12.2, 12.4_
  - 結果（2026-10-11 23:21）:
    - ログと個人情報の検索（scratchpad の `check91.py`）: キーワードではなく、そらともの Swift 48 本（`Soratomo*.swift`）の外へ出る口を全部拾い、渡す中身を許可リストと突き合わせた。A: print 系の補間と文字列でない引数（7 か所・許すのは内部 ID のパス・uid・エラーの説明だけ）、B: `SoratomoEvent` の連想値の型（23 種・Int・Bool・String の生の値を持つ列挙だけ）と `.value(` の中身（22 か所・`<名前>.rawValue` か固定の文字列だけ）、C: `LoggingService`・`ErrorHandler`・Crashlytics・PostHog・Analytics への直接の送信（4 か所だけ許す）、D: `SoratomoError.record` の context（47 か所・固定の文字列か、`StaticString` の引数をそのまま渡す形だけ）。本物は終了コード 0
    - 陽性対照（21:31）: 写しに 5 種類を 1 つずつ植えた（print に `\(groupName)`・`.value(displayName)`・`case leakTest(groupName: String)`・`LoggingService.shared.logEvent(..., ["name": groupName])`・record の context に `\(groupName)`）。どれも終了コード 1 で、違反は植えた行の 1 件だけ。数は grep と一致した（print 7・record はコメントの例を除いて 47）
    - 消毒（`LoggingService` の sanitize）はメール・パスワード・トークンしか消さず、名前は消えない。守っているのは型（計測は列挙と真偽値だけ・記録の文脈は `StaticString`）と、出口の数
    - 間接の経路（Workflow `wf_8049c519-79c` の点検と反証・opus・コードを読むだけで実行はしていない）: record に渡るエラーは、ViewModel 側は連想値の無い `SoratomoError` だけ、サービス側の失敗の型（新しい `SoratomoLeaveFailure`・`SoratomoImageCacheFailure` を含む）は固定の文か内部 ID のパスだけ。サーバーの `HttpsError` の文言は固定か理由のコードで、details は `currentVersion`（数字）だけ（`functions/soratomo.js:91,94,109,111`）。SDK の `FunctionsError` の userInfo も、サーバーの文言・region・url・details だけで要求の本文を含まない（firebase-ios-sdk 12.6.0 の `FunctionsError.swift:185-235`）。確認の題（グループ名）と本文（引き継ぐ人の表示名）はアラートにしか渡らない。抜けた後の一時表示（グループ名を含む）は画面の Text と VoiceOver の読み上げにしか渡らない。端末に新しく書くもの（`soratomo.leftGroups.{uid}` の groupId の配列・画像のキャッシュのフォルダ `soratomo.{groupId}`・古いキャッシュを消したかの印）は内部 ID と固定のキーだけ。壊れた投稿の記録（`soratomo_sky_decode_failed`）に入るのは、case 名と項目名と内部 ID のパスだけ
    - 検査器の限界: 点検役と反証役が、検査器をすり抜ける書き方を合わせて 15 種類挙げた（生の文字列 `#"…\#(…)"#` の補間・`$0` を print に渡す・`logger?.`・複数行の case・型名を付けた `SoratomoAnalyticsValue.value(`・`FileHandle` への書き出し・既存の `malformedDocument(path:)` に値を入れる、など）。本物の 48 本に、どれも無いことを検索で確かめた（`#"`・`\#(`・`logger?.`・`Logger`・`os_log`・`OSLog`・`SoratomoAnalyticsValue.value(`・`FileHandle`・`fputs`・`fwrite`・`NSLog`・`debugPrint`・`dump(`・print に `$0` が 0 件・SoratomoEvent の case はすべて 1 行）。この検索の陽性対照として、同じ検索が `LoggingService.swift` では当たる（`#"` 3・`Logger` 1・`logger.` 10）ことを確かめた。`malformedDocument` を作る 3 か所（`SoratomoGroupService.swift:217・251・313`）はどれも内部 ID のパス
    - 変更なしで満たす要件（同じ Workflow・点検役の主張 26 件はすべて反証役が現物で確認・違反 0）:
      - 3.9: 画面から画面へ渡るのは groupId だけ（`SoratomoRouter.swift:67-75` の行き先は groupId しか持たない）。招待画面の ViewModel が自分でグループの文書を監視し、届くたびに `isOwner = currentUid() == group.ownerId` を決め直す（`SoratomoInviteViewModel.swift:93-109`）。サーバーは引き継ぎで同じ文書の ownerId を書き換える（`functions/soratomoDeletion.js` の applyRemovalPlan）。`SoratomoInviteViewModel`・`SoratomoInviteView` は差分なし
      - 3.11: 最後の 1 人ではグループと招待コードの文書を同じトランザクションで消し、`joinGroupTx` はコードの文書が無くてもグループの文書が無くても `not_found`（`functions/soratomoStore.js:274・282`。`leave_pending` の判定はその後ろ）。iOS は `not_found` → `.notFound` →「招待コードが見つかりません」（`SoratomoGroupService.swift:396-397`・`SoratomoError.swift:83-84`）。差分はこの写しを変えていない
      - 6.1・6.3: タイムラインは投稿のクエリとグループの文書をスナップショットで監視し、届くたびに作り直す。`SoratomoTimelineViewModel` の差分は行を足しただけで、既存の行と a922c92 の監視の処理は変えていない
      - 6.2: 投稿詳細は `.gone`・`.notMember` で「この投稿は表示できなくなりました」を出す（`SoratomoSkyDetailView.swift:136-154`）。差分は画像のキャッシュの指定 2 か所とコメントだけ
      - 6.4: メンバー一覧は開くたびに読み直し、オーナーの印はメンバーの文書の role（引き継ぎでサーバーが書き換える）。`SoratomoMembersViewModel`・`SoratomoMembersView` は差分なし
      - 6.5: グループ一覧は表示・戻ったとき・引き下げで読み直し、memberCount を出す。差分で変えた既存の行は、読んだ結果を `visibleGroups` に通す 1 行だけ（外すのは、この端末・この uid で抜けた記録のあるグループだけ）
      - 6.7: 差分で足した知らせ（`router.notice` の 2 経路・覆い・確認）は、どれも抜けた本人の端末で、本人の操作か本人の端末だけにある抜けた記録がきっかけ。ほかのメンバーの端末では出ない
      - 7.3: アプリの差分を通知の許可・登録・カテゴリ・トークン・配信済みの通知・バッジの識別子で検索して 0 件（同じ検索が、写しに `requestAuthorization` を足すと当たることを確かめた）。通知の API に触れるファイル（`AppDelegate`・`PushNotificationManager`・`GoldenHourNotificationManager`・`SoratomoNotificationPrimer` など）は差分なし
      - 9.5: `SoratomoRootView` の差分は、`await checkEntry()` の直前の同期の呼び出し `SoratomoImageCache.purgeLegacyIfNeeded()` だけ。間に await・return・guard が無いので、全文と一覧の判定の順は変わらない
    - 差分で確かめたこと:
      - 10.1: 退会の確認の文言・手順・そらとも分の削除（`SettingsView`・`SettingsViewModel`・`SoratomoAccountDeletionService`・`AuthService`・`ContentView`）は差分なし。退会に触れる 13 本のうち差分に入る 4 本（`SoratomoLeaveService`・`SoratomoLeftGroups`・`SoratomoServiceContracts`・`SoratomoDependencies`）は、削除の行が 0 で、退会に触れるのは足したコメントだけ。退会が呼ぶ部品の変化: 失敗の写しに `leave_pending` の行が増えたが、退会の Callable は返さず、返っても結果は前と同じ `.unknown`。サインアウトの `SoratomoImageCache.clear()` は、グループごとのキャッシュに合わせて中身が変わったが、消す範囲はそらともの画像キャッシュ全部のまま。抜けた記録 `SoratomoLeftGroups` は設計どおり退会では消さない（design.md の 7.2）
      - 12: `soratomo_group_left`（`role`＝`owner`/`member`・`group_deleted`・`completed`）・`soratomo_leave_failed`（`reason`＝`network`/`unknown`）・`soratomo_join_failed` の新しい値 `leave_pending` が、要件 12 の表と名前・パラメータ名・値で一致（`SoratomoAnalytics.swift:69・298・300・377-381`。テストは `testLeaveGroupEventsHaveFixedNamesAndParameters`・`testJoinFailReasonMapping`）。既存のイベント・値・並びは変わっていない（計測のファイルで消えた行は MARK のコメント 1 行だけ）。記録を呼ぶのは、抜けた後 1 回（`SoratomoLeaveViewModel.swift:426`）と、抜けられなかったとき 1 回
    - 違反ではないが記録すること（12・13 と /review-full で扱う）:
      - `SoratomoRouter.swift:318` のコメントは一時表示を「固定の文」と書いているが、実際の値はグループ名を差し込んだ文（出口は画面と VoiceOver だけで漏れではない）
      - 3.9 の引き継ぎそのもの（監視の途中で ownerId が自分に替わると再発行が出る）の単体テストは無い（`SoratomoInviteViewModelTests` は最初の 1 回の判定だけ）
      - 6.5 の境界: この端末で抜けた後、別の端末で入り直した人は、この端末に抜けた記録が残る。圏外でサーバーに確かめられない間は、そのグループが一覧に出ない（設計 5.6 の「確かめるまで出さない」どおり）
      - 抜けた記録はサーバーで確かめないので、別の端末で入り直した後、この端末で一覧を開く前に新着通知を開くと、「開けませんでした」の一時表示と `not_member` の計測になりうる（その後の一覧の読み直しで記録が外れる）。12.2 で見る
      - D1 の失敗の後、監視の `.notMember` が届く前に一覧へ戻ると、ViewModel の中の未確定の覚えが消え、`soratomo_group_left` が記録されない。13 の集計で、抜けた件数が少なく出うる
      - `leave_pending` は、退会の途中で写しだけが残った人の参加でも返る（設計で受け入れ済み・/review-full の F7）

- [x] 9.2 iOSのビルドとテストを通す
  - 前提: 9.1
  - ビルドにエラーと新しい警告が無いこと、そらともと既存のテストが通ることを確かめる（`C2E3F752`・負荷を見て・`nice`・1本ずつ）
  - 既存のテストのうちmainで既に落ちているもの（例: `ProfileViewModelTests` の一部）は、変更前のmainでも同じく落ちることを確かめて区別する
  - 6〜8の各テストが、陽性対照で赤になったことの記録を確かめる（記録の無いテストは、先に陽性対照を取り直す）
  - 退会の手順に差分が無いことを、もう一度差分で確かめる
  - _Requirements: 10.1, 10.6_
  - 結果（2026-10-12 00:14）:
    - ビルド（2026-10-11 21:34・C2E3F752・`build-for-testing`）: エラー 0。警告は、差分の Swift 32 本（アプリ 17・テスト 15）の更新時刻だけを変えて再コンパイルさせたビルド（23:15）で見た。32 本すべてがコンパイルされ、32 本の警告は 0。ログ全体の警告は差分に無い `GeneratedAssetSymbols.swift` 5 件と `PaymentService.swift:47` 1 件だけで、`PaymentService.swift:47` は main のビルドにも同じく出る（新しい警告は 0）
    - 全体のテスト: 単体テストのターゲット `SoramoyouTests` 全部（UI テスト 36 本は外した。アプリを起動して画面を操作し、ログインの状態と本番に左右されるため）。1 回目（21:35）は、そらともと関係の無い `StorageServiceTests.testUploadProgress`（本物の Storage へ上げる）で 75 分固まったので止めた（そこまでの 1,473 本は 2 分で走っていた）。1 本 60 秒の時間切れを付けて回し直した 2 回目（22:53〜22:57）: 1,551 本のうち通過 1,513・失敗 34・飛ばし 4。そらとものテスト 527 本はすべて通過し、差分で足した 92 本もすべて通過。件数は xcresult で数えた
    - main で既に落ちるものの区別: 失敗 34 本の内訳は `FirestoreServiceTests` 20（エミュレーター前提）・`StorageServiceTests` 4（`testUploadProgress` の時間切れを含む）・`ProfileViewModelTests` 2（`testLoadProfile`・`testLoadEditTools`）・`FilterGraphBuilderTests` 2・`AuthServiceTests`・`AuthViewModelTests`・`EditViewModelTests`（`testRealtimeEditingFlag`）・`ImageServiceTests`（`testGeneratePreviewWithRecipe`）・`IntegrationTests`・`UserModelTests` が各 1。変更前の main（origin/main = a922c92 を scratchpad に worktree で取り出し・git 管理外の `GoogleService-Info.plist` は写して shasum の一致を確認・DerivedData は別）をビルドし（23:07〜23:12・成功）、この 34 本だけを回した（23:13〜23:15）。34 本とも同じく失敗（`testUploadProgress` も同じく時間切れ）。今回の変更で落ちるようになったテストは 0
    - 6〜8 の陽性対照の記録: 差分で足したテスト 92 本のうち、6〜8 の結果に「赤になった」と名前のあるものは 40 本、無いものは 52 本（7.4 は新しいテストなし）。52 本は取り直した。壊し方は Workflow `wf_01ab0227-1f9`（設計と反証・opus）で、アプリのコードだけを変える置き換え 47 個を 7 組に分けて作った（置き換え前の文字列がファイルに 1 回だけあることを機械で確認）。組ごとに、元を写して shasum を記録 → 当てる → ビルド → そらとものテスト 32 クラス（527 本）→ 写しから戻して shasum の一致を確認 → 赤の集合を予想（狙い＋巻き添え）と突き合わせた（2026-10-11 23:22〜10-12 00:13・C2E3F752）
      - 容れ物 8/8・抜けるのサービス 11/11・抜けた記録 13/13・ルーター 23/23・画像のキャッシュ 9/9・抜けるの画面の状態（前半）16/16・同（後半）13/13 が予想どおり赤。7 組とも、予想外の赤 0・予想したのに緑 0。52 本はすべて、どれかの組で赤になった（92 本のうち 73 本がこの 7 組で赤）
      - 1 つの組に複数の置き換えをまとめて当てたので、組の中で「どの置き換えで赤になったか」は設計の予想による（8.1〜8.4 と同じやり方）
      - ルーター・画像のキャッシュ・画面の状態（前半）の 3 組は、テストの後に xcodebuild が終了処理（gRPC の後始末）で止まり、TERM で止めたため xcresult が読めなかった。この 3 組は、ログの「Test Case … passed/failed」を名前で数えて突き合わせた（527 本すべてに結果あり）。同じ読み方は、xcresult の読めた 2 組で xcresult と同じ結果になった
      - 全部の組の後、作業ツリーは HEAD と差分なし（`git diff --quiet HEAD`）・写しの残りなし
      - 陽性対照の間に、自動のセキュリティの点検が、当てていた壊した版（抜けるのサービスの判定の向きを逆にした行など 3 件）を指摘した。戻した後に、その行が HEAD と同じ（`? .member : .notMember`）であることを確かめた
    - 退会の差分（もう一度）: 退会の確認・手順・削除（`SettingsView`・`SettingsViewModel`・`SoratomoAccountDeletionService`・`AuthService`・`ContentView`）は差分なし。退会に触れる Swift 13 本のうち差分に入る 4 本は、削除の行が 0 で、退会に触れるのは足したコメントだけ
    - ⚠️ 次に回す人へ: `-test-timeouts-enabled` を付けた実行は、テストが全部終わった後に xcodebuild が gRPC の後始末で 10 分ほど止まることがある。PATH の `xcodebuild` は同時実行を 1 本にする包み（`~/.claude/bin/xcodebuild-serial`）なので、止めるときは孫の本物の xcodebuild に INT（効かなければ TERM）を送る。TERM で止めると xcresult は読めないので、ログで数える
  - 結果（/review-full・iOS の差分・2026-10-12 01:01）: Workflow `wf_16579a08-93d`（simplifier・general・codex・project-rules の 4 観点を並列 → 同じ根の集約 → filter-validity-judge → 通過した指摘ごとに反証・opus。codex は scratchpad に HEAD を取り出して `codex exec -s read-only` に背景 4 点を渡した）。投入 15 件 → 集約 14 件 → 通過 5・棄却 9（許容範囲 5・存在しないコーナーケース 4）。blocker・major の通過は 0。利用者の判断で、通過 5 件と、棄却から保留に上げた 1 件（D1）をすべて直した
    - D2（minor・general と codex）: 抜けた後の画像の消去（1 回目・2 回目）の後に届いた読み込み途中の画像が、消す前に受け取ったキャッシュのインスタンスへ保存し、抜けたグループのフォルダを作り直していた（Kingfisher の provider の読み込みは取り消せない）。`SoratomoGroupImageCaches.removeGroup` で、外したインスタンスのディスクとメモリの期限を `.expired` にしてから消すようにした（Kingfisher 8.6.2 の保存は期限切れなら書く前に戻る・`DiskStorage.swift:162`・`MemoryStorage.swift:146`）。テスト `SoratomoImageCacheTests.testLateStoreAfterRemoveGroupDoesNotRecreateFolder`（本物の保存の入口 `store(_:original:forKey:toDisk:)` で、消した後に古いインスタンスへ保存する）
    - D1（codex の major・判定役は「存在しないコーナーケース」で棄却・起きたら戻せないので保留に上げた）: 抜けるの繰り返し（最大 8 回）は、回ごとにその時点の利用者のトークンで送る。途中でサインアウトして、同じグループに入っている別のアカウントでサインインすると、確認なしにその人が抜けて投稿も消える。窓口 `SoratomoLeaveDataSource` に `currentUid()` を足し（この spec で作った protocol・既存のモックは変えない）、`leave(groupId:)` の最初に uid を覚え、各回の前に同じかを確かめ、替わっていたら（サインアウトを含む）次を送らずに `.unknown` を投げる（`soratomo.leaveGroup.accountChanged` で記録）。最初からサインインしていないときは今までどおり。テスト `SoratomoLeaveServiceTests.testLeaveStopsWhenAccountChangesBetweenCalls`（別のアカウント・サインアウトの 2 通り）
    - 振る舞いを変えない片づけ: D5（タイムラインの `onDisappear` の判定を `dependencies.isLeftGroup` に寄せた）・D13（`SoratomoLeaveService` の「自動 ID の形でない値は送らない」を実際の検査〔空・「/」〕に合わせた）・9.1 で記録した `SoratomoRouter.finishLeaving` の「固定の文」を実際（グループ名入り・画面と VoiceOver だけ）に合わせた・D9（`SoratomoRouter.isLeftGroup` を `private let` に）・D6（`SoratomoDependenciesTests` の setUp を `makeDependencies(uid:)` に寄せた）
    - 陽性対照（00:56〜00:58・C2E3F752・そらともの 32 クラス）: 新しいテスト 2 本と片づけを当て、守りの本体（期限切れの 2 行・uid の確かめ）だけを入れていない版で、529 本のうち新しい 2 本だけが赤（「フォルダが作り直された」「メモリに戻った」／8 回呼んで `.incomplete`）。守りを入れた版（00:59〜01:00）で 529/529 通過（xcresult とログで一致）。変えた 8 ファイルは再コンパイルされ、警告 0
    - 棄却した 9 件の主なもの: D3（D1 の未確定の抜けるは画面を離れると消える）は承認済みの D1 の読み方の範囲、D4（古い一覧の読み込みが抜けたグループを出し直す）と D12（引き継ぐ人の予測とサーバーの食い違い）は成り立つ条件が現物に無い、ほか書き方の好み。詰め切れなかった領域（失敗の直後の確認と、サーバーの前の呼び出しの競合・D1 の未確定の間のサインアウトで監視の拒否が「抜けた後」へ進めうる・確認の門が既存のアラートを見ていない）は、12.1・12.2 の実機の確認で見る
    - コミット: `c657ea5`（D2）・`0ed8390`（D1）・`0157b0c`（D5・D13・D9・コメント）・`0370171`（D6）。判定役の基準（`~/.claude/agents/filter-validity-judge.md`）に「不可逆・他者への被害の経路は、存在しないコーナーケースで棄却しない」の例を 1 つ足した

## (f) ドキュメントの反映

- [x] 10. ドキュメントを実装に合わせる

- [x] 10.1 (P) データの置き場の記録と、release-gateの契約の表を直す
  - 前提: 1〜4（実装が設計どおりであること）
  - `docs/firestore-schema.md` のそらともの表に、`soratomoPendingLeaves`（文書ID `{uid}_{groupId}`・`uid`・`groupId`・`episodeId`・`leftAt`・書き手はFunctionsだけ）の行を足す。抜けるで消すもの（抜けた人のそのグループの投稿と画像・通知の間引き・所属の写し。最後の1人ならグループごと）の1文も足す
  - release-gate specのdesign.mdの「API Contract（そらとものCallableのまとめ）」の表に、`soratomoLeaveGroup` の行と、`soratomoJoinGroup` の `failed-precondition`・`leave_pending` を足す（または、このspecのdesign.mdを指す1行を足す）
  - 書き終えたら、変更した識別子で検索し、実装と食い違う記述が残っていないことを確かめる
  - _Requirements: 4.6, 8.4, 10.3, 10.4_
  - 結果（2026-10-11 20:20）:
    - `docs/firestore-schema.md` のそらともの表に `soratomoPendingLeaves` の行（334 行）と、抜けるで消すものの 1 文（337 行）を足した。release-gate の design.md の API Contract の表に `soratomoLeaveGroup` の行を足し、`soratomoJoinGroup` の行の末尾に `leave_pending` を足した（置き換えたのはこの 1 行だけで、ほかは追加だけ）
    - 実装との照合: `functions/soratomo.js`（`leave_pending` は `failed-precondition`・`soratomoLeaveGroup` は `requireFlag: false` で応答は `{ done, groupDeleted }`・メンバーでない人にも `{ done: true, groupDeleted: false }`）・`functions/soratomoDeletion.js`（印の項目 `uid`・`groupId`・`episodeId`・`leftAt`）・`firestore.rules`（`soratomoPendingLeaves` は読み書きとも false）と一致。書き手と点検役が別々に照らした
    - 変えた識別子（`soratomoPendingLeaves`・`soratomoLeaveGroup`・`leave_pending`）で docs と soratomo の spec を検索し、実装と食い違う記述が残っていないことを確かめた。`git diff -U0` で、md は足した行と上の 1 行だけが変わったことを確かめた。`textlint --fix` は掛けていない

- [x] 10.2 (P) 「退出は対象外」と書いた既存のspecに、上書きの注記を足す
  - 前提: 3.1
  - 既存の「⚠️2026-10-09 上書き（soratomo-release-gate …）: …」の書き方にそろえ、本文は書き換えずに1行を足す。場所は、soratomo specのrequirements.md 6行（対象外（v1）の「退出」）と373行・design.md 19行（Non-Goalsの「退出」）、release-gate specのrequirements.md 347行・tasks.md 536行（「グループから抜ける機能は無い」の記録）の5か所
  - 書く内容: 本人が1つのグループだけを抜けることは、soratomo-leave-groupで対象に入れた。オーナーによるグループの削除・除名・オーナーの手動の譲渡は、引き続き対象外
  - 行番号は書く前に現物で確かめる（ほかの作業で行がずれていれば、文で探す）
  - _Requirements: 1.1, 3.13_
  - 結果（2026-10-11 20:20）:
    - 5 か所（soratomo の requirements.md 6 行・373 行、design.md 19 行、release-gate の requirements.md 347 行・tasks.md 536 行）の直後に「⚠️2026-10-11 上書き（soratomo-leave-group）: …」を 1 行ずつ足した。行番号は現物と一致していた。本文は書き換えていない。箇条の中は子の箇条にし、requirements.md 6 行目は段落なので行頭から書いた
    - `git diff -U0` で、5 か所とも追加の 1 行だけであることを確かめた

## (g) 本番への反映

- [ ] 11. 本番へ反映する（すべてユーザーのGOを取ってから）

- [ ] 11.1 出す前の確認と、pushとPRの作成（ユーザーのGOを取ってから実行）
  - 前提: 5, 9.2, 10
  - ユーザーのGOを取ってから実行する。AIは単独で実行しない
  - `git fetch -q origin` の後、mainが進んでいれば取り込み、`npm run lint`・`npm test`・`npm run test:emulator`・ルールのテスト（通常と `--mutants`）・iOSのビルドとテストを、もう一度通す
  - PRを出す前に `/review-full` でレビューし、新しいCallableが外からの入力を受けるので、続けて `/security-review` を通す。指摘の直しを済ませてから出す
  - 初回のpushは `git push -u origin 機能-そらとも-グループだけ抜ける`（上流を自分のブランチにする）。PRの本文に、要件・設計・tasks.mdの場所と、public-launchとの順番（このPRのマージ・本番への反映・受け入れの確認の後に、public-launchへ進む）を書く
  - _Requirements: 10.2, 10.3, 10.4, 10.6_
  - 結果（途中・2026-10-11 16:45）: Functions とルール（1〜5）の後に `/review-full`（指摘 F5・F7・F8 を直した）と `/security-review`（指摘なし）を通し、GO を取って push した（`3cb318d`・上流は自分のブランチ）。前提の 9.2 と 10 がまだなので、PR は下書き（Draft）の #174 で作った。iOS と文書をこのブランチに足し、済んだらこのタスクの再確認（main の取り込み・全テスト）を通してから Ready に切り替える。このタスクはまだ完了ではない

- [ ] 11.2 mainへマージする（ユーザーのGOを取ってから実行）
  - 前提: 11.1
  - ユーザーのGOを取ってから実行する。AIは単独で実行しない
  - マージの前に、PRの差分で、退会の確認と手順（設定画面）・既存のCallableの受け付けの条件・`isSoratomoUser()`・`requireSoratomoUser` の中身・`storage.rules` が変わっていないことを、もう一度見る
  - マージから11.3のデプロイまでの間に、mainからアプリの版を作らない（入口があるのにCallableが無い状態になるため）
  - _Requirements: 10.1, 10.5_

- [ ] 11.3 Functionsをデプロイする（ユーザーのGOを取ってから実行）
  - 前提: 11.2
  - ユーザーのGOを取ってから実行する。AIは単独で実行しない
  - 出し元: `git fetch` の後、作業ツリーがcleanで `HEAD == origin/main` のところから出す。出し元のコミットを記録する
  - 出す前の確認: 前回の本番の出し元（`b07da6e`。10/10に本番と一致を確かめた）からorigin/mainまでの変更を `git log --stat b07da6e..origin/main -- functions/ firestore.rules` で見て、このspecのマージの分だけであること。本番の `firebase functions:list` の名前・リージョン・ランタイムを記録する（21本・asia-northeast1・nodejs22の見込み）
  - コマンド: そらともの関数だけを名前で指定して出す。名前は `functions/soratomo.js` の `module.exports` の11本から作る（手で打たない）。`firebase deploy --only functions:<名前>,functions:<名前>,…（11本） --project soramoyou-ios --non-interactive`。変わった3本（抜ける・参加・定期実行）だけにしないのは、共通の部品（`REASON_TO_CODE`・`soratomoStore.js`・`soratomoDeletion.js`）を、そらともの関数がみな読むため
  - 出した後: 出力で、全部の更新が成功し、`soratomoLeaveGroup` が作られた（作成1本・削除なし）。`firebase functions:list` で、追加1行（`soratomoLeaveGroup`）・削除0行・合計22本・リージョンとランタイムが既存と同じ
  - _Requirements: 2.6, 4.1, 9.1, 10.3, 10.5_

- [ ] 11.4 新しいCallableの公開呼び出しの許可を確かめる（要確認Q4。ユーザーのGOを取ってから実行）
  - 前提: 11.3
  - ユーザーのGOを取ってから実行する。AIは単独で実行しない
  - release-gate 14.5の要確認4と同じ手順で行う。認証の無い `POST https://asia-northeast1-soramoyou-ios.cloudfunctions.net/soratomoLeaveGroup`（本文 `{"data":{}}`）を1回送り、HTTP 401・`UNAUTHENTICATED`・「ログインが必要です」が返ること（この文言は関数のコードだけが返す。許可が無ければCloud Runが403で止める）。関数のログに `soratomoLeaveGroup: rejected`（reason unauthenticated）が出ること
  - 失敗したら、呼び出し元の設定を見直す（変える前に利用者に相談する）
  - _Requirements: 9.2_

- [ ] 11.5 Firestoreのルールを本番へ出す（ユーザーのGOを取ってから実行）
  - 前提: 11.2（11.3との順は問わない。新しい `match` は、既定で拒否されていたパスの明示なので、どの順でも挙動は変わらない）
  - ユーザーのGOを取ってから実行する。AIは単独で実行しない
  - 出す前: 本番のルールを読み返し、`b07da6e` の `firestore.rules` とハッシュの頭が一致すること、origin/mainとの差が `soratomoPendingLeaves` の `match` とコメントの数だけであることを確かめる。このときのルールの判定は、まだクレームの判定のまま（関門の置き換えはpublic-launch）
  - コマンド: `firebase deploy --only firestore:rules --project soramoyou-ios --non-interactive`
  - 出した後: 本番のルールを読み返し（release-gate 17と同じく、RulesのRESTでreleaseとrulesetを読む）、手元の `firestore.rules` とハッシュの頭が一致すること。読み返した本文に `rules_test_soratomo.py` を流して、全件が期待どおりであること
  - _Requirements: 10.4_

- [ ] 11.6 最初の定期実行で、仕事Cのクエリが動くことを確かめる（要確認Q1。ユーザーのGOを取ってから実行）
  - 前提: 11.3
  - ユーザーのGOを取ってから実行する。AIは単独で実行しない
  - 次の予定（6時間ごと）を待つか、Cloud Schedulerの `firebase-schedule-soratomoHousekeeping-asia-northeast1` を、RESTの `:run` で手動で1回起こす（release-gate 14.5の前例）
  - ログで、`soratomoHousekeeping: leave_sweep` が出て、`FAILED_PRECONDITION`（インデックスが要る）や仕事Cの失敗が無いこと。仕事Aの `soratomoHousekeeping: sweep` と仕事Bの `soratomoHousekeeping: reforward` も、今までどおり出ること
  - 印が0件でも、インデックスが要るクエリは件数に関わらず失敗するので、0件の実行も確かめになる。本番で壊れたクエリを流す陽性対照は取らない（そう記録する）
  - 24時間を過ぎても終わらないものの見つけ方（Cloud Loggingで `soratomoLeave: overdue` に絞る・Firestoreのコンソールで `soratomoPendingLeaves` の `leftAt` を見る）を、結果の欄に書いておく
  - _Requirements: 4.6, 4.8, 11.5_

## (h) 受け入れの確認

- [ ] 12. 開発版と本番で、抜けるを受け入れる（利用者の操作が要る）

- [ ] 12.1 抜けるを3通り通し、ほかのメンバーの画面を見る（利用者の操作が要る）
  - 前提: 11.3, 11.5
  - 利用者の操作が要る。本番の読み取り（件数・項目名）・クレームの付与・端末の操作のお願いは、GOを取ってから行う。1.15.0のTestFlightと審査提出は、この段ではしない（public-launchが持つ）
  - 端末: 始める前に「いまさわれる端末」を利用者に聞き、端末とアカウントの割り当てを決める。入っているアプリが、11.3の出し元から作った開発版（Debugビルド）で、`soratomoLeaveGroup` の名前を含むことを確かめる（release-gate 16.4の前例: アプリの中の文字列を数える）。だれでログインしたかは、Authの最後のログインの時刻で確かめる
  - アカウント: クレームのあるテスト用アカウントS3と、もう1つのクレームのあるアカウント（以下B）。Bが無ければ新しく登録し、`set-soratomo-beta-claim.js` でクレームを付けて読み返す（GO）
  - ①ただのメンバー: BがS3のグループに参加して2枚投稿する。Bがメニューの「グループを抜ける」を押すと、確認に共通の文が出る。「キャンセル」で何も変わらない。機内モードでメニューを押すと通信の文言が出て、何も始まらない。確認を出してから機内モードにして「抜ける」を押すと、通信の文言が出てタイムラインのまま。つないで抜けると、処理中の覆いが出た後に一覧へ戻り、「…を抜けました」が出る。「グループを開けませんでした」は出ない。一覧にそのグループが無い
  - ほかのメンバー（S3）の画面: Bの投稿が、タイムラインから手動の更新なしで消える。Bの投稿の詳細を開いたままなら「この投稿は表示できなくなりました」になり、落ちない。タイムラインの人数が減り、メンバー一覧とグループ一覧にBがいない。抜けたことの通知と知らせは、S3にもBにも出ない。抜けた後にS3が投稿しても、Bに通知が届かない
  - ②オーナー: Bが同じコードで入り直し、S3（オーナー）が抜ける。確認に、オーナーの引き継ぎとBの表示名が出る。Bがオーナーになり（オーナーの印）、招待の画面に再発行の操作が出る。招待コードは変わらない（最後の4文字で見る）。オーナーになったことの通知は来ない
  - ③最後の1人: 1人だけのグループ（使ってよいグループを利用者に確かめる）で抜ける。確認に、グループと招待コードが消えて、だれも参加できなくなる文が出る。控えた古いコードで参加すると「招待コードが見つかりません」
  - 本番の読み取り（GO）: 各回の前と後に、抜けた人のそのグループの投稿の文書と画像（Storage）・所属の写し・印（`soratomoPendingLeaves`）・人数とオーナー・招待コードの対応表（③は404）を読み、件数を記録する。抜けた後は、抜けた人の分が0で、ほかのメンバーの投稿と画像は残る。読み取りの道具は、前例の `~/dev/soratomo-gate-tools/`（リポジトリの外）の形にし、出すのは件数・時刻・IDの頭・ハッシュの頭だけにする
  - ログ: 各回の `soratomoLeaveGroup: ok` が、内部IDと件数だけで出る（`done` が真・`kind`・`ownerTransferred`・`groupDeleted` が場面と合う・`skiesDeleted` と `imagesDeleted` が前に読んだ件数と一致）
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.9, 2.1, 2.2, 3.1, 3.2, 3.6, 3.8, 3.9, 3.10, 3.11, 5.1, 5.2, 5.3, 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 6.8, 7.1, 11.2, 11.4_

- [ ] 12.2 入り直し・端末の後片づけ・古い通知・古い版を確かめ、要確認Q2・Q3・Q7を見る（利用者の操作が要る）
  - 前提: 12.1
  - 利用者の操作が要る。本番の読み取りとCloud Schedulerの手動実行は、GOを取ってから行う
  - 入り直し: 12.1の後に、抜けた人が同じコードで入り直して1枚投稿する。次の定期実行（またはCloud Schedulerの手動実行）の後も、新しい投稿と画像が残る。抜ける前の投稿は戻っていない。人数と所属数が、実際の数と合う（本番の読み取り）
  - 片づけ中の参加（`leave_pending`）: ふつうの操作では起こせない（サーバーは、端末が切れても片づけを続ける）。起こせなければ、C1（2.1）と8.4の単体テストを根拠とし、そう記録する
  - オフライン: 抜けた後に機内モードにして、そらともの一覧を開くと、抜けたグループが出ない
  - 古い通知: 抜ける前に届いていたそのグループの通知を、抜けた後に開くと、タイムラインを開かずに一覧が出て、開けなかったことが伝わる
  - 要確認Q2: 開発版をXcodeにつないで、抜けた後に一覧を開いたとき（記録にあるグループの再確認が走る）の読みのエラーのコードを、ブレークポイントで見る。`permissionDenied` でなければ、7.1の写しを直して出し直す
  - 要確認Q3: 開発版で、抜けた後に、端末の `Caches/soratomo-images/` の下からそのグループのフォルダが消え、ほかのグループのフォルダが残る。端末の中を覗けなければ、シミュレーターで同じ操作をして見て、そう記録する
  - 要確認Q7: 入り直した直後のタイムラインに、消えた自分の古い投稿が一瞬出るかを見る。出ても不具合として扱わず、8.4の判断と合わせて記録する
  - 古い版: 1.14.x（TestFlightの1.14.0 / 111か1.14.1 / 112）のS3で、投稿が通る（`soratomoCreateSky: ok`）。1.14.xには抜けるの入口が無い
  - 受け入れの確認で直しが出たら、別のPRで直し、11と同じ手順で出し直してから、該当の確認をやり直す
  - _Requirements: 5.4, 5.6, 5.7, 8.1, 8.3, 8.4, 8.5, 8.6, 10.5_

- [ ] 13. 受け入れの結果をまとめ、イベントの着弾の確認をpublic-launchへ渡す
  - 前提: 12.1, 12.2
  - 要件12.5（イベントの着弾）は、public-launchのtasks.mdのG4（手順書の段2-3・6-2）で、同じ時点・同じ除外の条件で確かめる。このspecでは行わない
  - public-launchのtasks.mdのG4のイベントの一覧に、`soratomo_group_left`・`soratomo_leave_failed`・`soratomo_join_failed`（`reason` が `leave_pending`）が入っているかを見る（2026-10-11に書かれた版では、G4のタスクに3つとも入っている）。無ければ利用者に伝える（public-launchのファイルは、このタスクでは書き換えない）。`leave_pending` は本番でふつうには起こせない（12.2）ので、その扱いもあわせて伝える
  - public-launchの段0-1が見に来るよう、11と12の結果の要約（出し元のコミット・関数の本数22本・ルールの読み返しの一致・受け入れの確認の日時と結果）を、このタスクの下に書く
  - _Requirements: 12.5_
