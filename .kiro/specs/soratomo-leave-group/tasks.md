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

- [ ] 1. 共通の削除の部品を分け、1グループ版の片づけ（`leaveSoratomoGroup`）を作る

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

- [ ] 1.3 片づけの手順2〜4（照合・`finishLeaveTx`）と、時間の予算を作る
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

- [ ] 1.4 入り直し・重なった実行・退会との重なりのテストを書く（陽性対照C2・C3）
  - 前提: 1.3
  - 場面の作り方は、既存のテスト（`soratomoDeletion.test.js` の「利用者単位: 並行した別の削除が先に終わり、本人が同意し直して同じグループへ入り直しても…」）と同じにする。偽のゲートウェイの `listFiles` で止める
  - 陽性対照C2（遅れた片づけ）: 1回目の片づけが終わり、本人が入り直して投稿と画像を作った後に、同じ印から片づけをもう一度流す。先に、今の部品 `deleteUserDataInGroup` で同じ場面を流し、入り直したメンバーを外し直して新しい投稿と画像を消す（赤）ことを確かめる。`leaveSoratomoGroup` の `origin: "sweep"` では、印だけを消して `stale_marker` で終え、メンバー・新しい投稿と画像・写し・所属数が変わらない
  - 陽性対照C3（重なった2つの実行）: 実行Aを画像の一覧の中で止め、その間に実行Bが最後まで終え、本人が入り直して新しい投稿と画像を作り、Aを再開する。先に、今の部品ならAの手順3が新しい画像を一覧して消す（赤）ことを確かめる。`leaveSoratomoGroup` では、Aが照合で `superseded` になって何も消さず、Bが消した写しは消えたまま、入り直した後の新しい写しは残る
  - 抜けて、入り直して、また抜ける: 1回目の遅れた実行（`episodeId` が古い）は、2回目の回の写しと印を消さない。2回目は自分で終える。陽性対照: 照合で印の有無だけを見て `episodeId` を比べない実装（research.mdの表B2）で、このテストが赤になることを先に確かめる
  - 退会・利用停止との重なり: 抜けるの途中で、退会（`deleteSoratomoUserData`）か利用停止（`suspendSoratomoUser`）が最後まで走っても、消す範囲・人数・所属数・オーナーが、順に行った場合と同じになる。退会の後に残った印は、続きの `leaveSoratomoGroup`（`sweep`）が `continued` か `stale_marker` として件数0で消す
  - _Requirements: 4.7, 8.6, 8.7, 10.6_

- [ ] 2. 参加の判定に、片づけ中の `leave_pending` を足す

- [ ] 2.1 `joinGroupTx` で、写しが残っている人の参加を `leave_pending` で断る（陽性対照C1・要確認Q6）
  - 前提: なし（1と同じエミュレーターと `functions/soratomo.js` を使うので、1と同時には進めない）
  - `functions/soratomoStore.js` の `joinGroupTx` の2回目の読み（`tx.getAll(groupRef, memberRef)`）に、所属の写し `soratomoUsers/{uid}/groups/{groupId}` を足す（読みはすべて書きの前）
  - 判定の順: …→コードの不在→既存のメンバー（今のまま）→写しがあれば `leave_pending`→所属10個→満員20人。所属10個より先に見るのは、片づけ中のグループが所属数に数えられたままで、`user_limit` と誤って案内しないため。印の有無は見ない（退会の途中の写しも同じく断る）
  - `SoratomoDomainError` の理由の型（JSDoc）に `leave_pending` を足す。`functions/soratomo.js` の `REASON_TO_CODE` に `leave_pending: "failed-precondition"` を足す
  - 参加の受け付けの条件と応答は、ほかに変えない。写しの重なりで `internal` になることを期待する既存のテストが無いことを、`ALREADY_EXISTS` と `internal` のgrepでもう一度確かめる
  - テスト: `soratomoStore.test.js` で、写しが残りメンバーの文書が無い人の参加が `leave_pending` になり、何も書かない。所属10個で写しが残っている人は、`user_limit` より先に `leave_pending`。`soratomo.test.js` で、参加のCallableが `failed-precondition`・`details.reason: "leave_pending"` を返す
  - 要確認Q6: 読みが1件増えても、既存の同時の参加のテスト（「同時の参加: 19人のグループへ25人が同時に参加しても、20人を超えない」と「同時の参加: 所属9個の人が25のグループへ同時に参加しても、10個を超えない」）がそのまま通るか。通らなければ、原因（エミュレーターの競合の返し方か、判定の誤りか）を切り分けて記録し、設計を変える前に利用者に相談する
  - 陽性対照（C1）: 今の現物（写しの判定が無い）で、同じ場面の参加が `SoratomoDomainError` でない失敗（`ALREADY_EXISTS`）になり、Callableでは `internal` になることを先に確かめる。写しの判定を所属10個の判定より後に置いた実装で、判定の順のテストが赤になることも確かめる
  - _Requirements: 8.4, 10.3_

- [ ] 2.2 片づけの後の入り直しと、同時実行のテストを書く
  - 前提: 1.3, 2.1
  - 片づけの後の入り直し: 新しいメンバーとして参加し、`role` は `member`（抜ける前にオーナーだったとしても戻さない）、`joinedAt` は入り直したときの時刻。人数と所属数がそろって1増える。抜けるで消した投稿と画像は戻らない
  - 同時実行（`soratomoStore.test.js`。既存の要確認3のテストの型）: 抜けると、ほかの人の参加・本人の別のグループへの参加・本人の入り直し・本人の別のグループの抜けるを、20回並べる。終わった後に、人数＝メンバーの文書の数・所属数＝写しの数・20人以下・10個以下で、写しとメンバーの文書が食い違わない。想定内の拒否に `leave_pending` を足す
  - 陽性対照: 人数を数え直さずに1減らすだけの実装と、所属数を1減らすだけの実装で、ずれが少なくとも1回出ることを確かめる。出なければ「この並べ方では検出できない」と記録し、コードの審査で補う
  - _Requirements: 3.12, 8.1, 8.2, 8.3, 8.7_

## (b) Functions: Callableと定期実行の配線

- [ ] 3. 抜けるのCallableと、定期実行の仕事Cを配線する

- [ ] 3.1 抜けるのCallable `soratomoLeaveGroup` を作る
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

- [ ] 3.2 定期実行に、途中で止まった抜けるを終える仕事Cを足す（陽性対照C2のサーバー版）
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

## (c) Firestoreのルール

- [ ] 4. (P) Firestoreのルールに、片づけ中の印の拒否を足す（要確認Q5）
  - `firestore.rules` の `soratomoConfig` の節の直後（いまの657行目の閉じかっこの前）に、`match /soratomoPendingLeaves/{markerId} { allow read, write: if false; }` を、design.mdの2行のコメントつきで足す。既存の行は、641行目のコメントの数（「次の 2 つは」→「次の 3 つは」）を直すだけにする。行番号は、書く前に現物で確かめる
  - `isSoratomoUser()` とその呼び出しの行には触れない（public-launchが変える）。`storage.rules` と `firestore.indexes.json` は変えない
  - `scripts/rules_test_soratomo.py`: `closed_collection_cases()` の `targets` に `soratomoPendingLeaves`（文書IDは `{uid}_{groupId}` の形・項目は印の4つ）を足し、get・list・create・update・deleteが、本人（クレームあり）・ほかのメンバー・未ログインのどれでも拒否されるケースにする。docstringとファイルの先頭のspecの一覧に、このspecを足す
  - 要確認Q5: `MUTANTS` に、`match` の行から `if false` までを置き換え元にした「片づけ中の印の読み書きを許す」を足し、置き換え元が1回だけ現れる検査を通ることを確かめる
  - 差分が「新しい `match` とコメントの数」だけで、既存の `match` の条件を緩めていないことを、差分で確かめる
  - 陽性対照: `--mutants` で、新しい壊し方が新しいケースを期待外れにすること。どの壊し方でも期待外れにならないケースが0件であること。通常の実行がすべて期待どおりであること
  - ここではルールをデプロイしない（11.5で行う）
  - _Requirements: 10.4_

## (d) Functionsとルールのまとめ

- [ ] 5. Functionsとルールのテストをすべて通し、既存の動きを変えていないことを点検する
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

## (e) iOSアプリ

- [ ] 6. iOSのエラーと計測の土台を作る（陽性対照C5）
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

- [ ] 7. iOSの部品を作る

- [ ] 7.1 抜けるのサービス `SoratomoLeaveService` を作る（要確認Q2の前半）
  - 前提: 6
  - `SoratomoServiceContracts.swift` に、`SoratomoLeaveResult`・`SoratomoLeaveError`（`network`・`incomplete`・`unknown`）・`SoratomoMembershipCheck`（`member`・`notMember`・`unknown`）・`SoratomoLeaveServiceProtocol`・`SoratomoLeaveDataSource` を、design.mdの形で置く。既存の `SoratomoGroupServiceProtocol` にはメソッドを足さない
  - `Services/SoratomoLeaveService.swift`: 型は `SoratomoAccountDeletionService` にそろえる（Callableの窓口はDataSourceで差し替える）。`soratomoLeaveGroup` を、1回75秒・最大8回で、`done` が真になるまで呼ぶ。8回で終わらなければ `.incomplete`。失敗したら呼び直さずに投げる。応答の `groupDeleted` は、どれか1回で真なら真にする。戻り値の形の違いは `.unknown`
  - 失敗の写しは `SoratomoGroupService.mapCallableError` を使う。通信・制限時間切れは `.network`。それ以外は、`SoratomoError.record`（文脈は固定の文字列・IDを入れない）に残して `.unknown`
  - `membershipOnServer`: 自分のメンバーの文書を、キャッシュを使わずに（`source: .server`）読む。文書がある→`.member`。権限の拒否→`.notMember`。通信の失敗とそれ以外→`.unknown`
  - 要確認Q2: メンバーでない人の読みが `permissionDenied` で届くか（`notFound` でないか）は、12.2で、本番につないだ開発版で確かめる。違えば写しを直す。確かめるまで「検証済み」と書かない
  - テスト用のモックは、`SoratomoServiceMocks.swift` に新しいクラスとして足す。`SoratomoLeaveServiceTests`（新規・DataSourceのモック）: `done` まで呼ぶ・8回で `.incomplete`・通信の失敗は `.network`・形の違いは `.unknown`・`groupDeleted` はどれか1回で真なら真・権限の拒否は `.notMember`・通信の失敗は `.unknown`
  - 陽性対照: 1回で戻る実装で、繰り返しのテストが赤になることを先に確かめる。権限の拒否を `.unknown` に写す実装で、`.notMember` のテストが赤になることも確かめる
  - _Requirements: 4.3, 4.4, 4.5_

- [ ] 7.2 抜けたグループの端末の記録 `SoratomoLeftGroups` を作る
  - 前提: 6
  - `Services/SoratomoLeftGroups.swift`: 利用者ごとのUserDefaultsのキー `soratomo.leftGroups.{uid}` に、グループIDのJSONの配列を持つ。上限は50件で、超えたら古いものから捨てる。メモリに持たず、毎回読む。保存の仕方は `SoratomoReportedSkies`（`SoratomoHiddenContent.swift`）にそろえる
  - 口は `contains`・`insert`・`remove`（どれも `uid` つき）。サインアウトでは消さない（同じ人が入り直したときも隠す）。退会の手順には足さない（退会を変えないため）
  - `SoratomoLeftGroupsTests`（新規）: 利用者ごとに分かれる（AのものがBに見えない）・作り直しても残る・上限50件・外せる
  - 陽性対照: 利用者ごとに分けず1つのキーに入れる実装で、「AのものがBに見えない」が赤になることを先に確かめる
  - _Requirements: 5.3, 5.6, 5.7_

- [ ] 7.3 画像のキャッシュをグループごとに分け、投稿の覚えをグループ単位で消せるようにする（要確認Q3の前半）
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

- [ ] 7.4 容れ物 `SoratomoDependencies` に、新しい部品を載せる
  - 前提: 7.1, 7.2
  - `leaveService: any SoratomoLeaveServiceProtocol` と `leftGroups: SoratomoLeftGroups` を足し、`live` で本物を入れる
  - `init` の引数が増えるので、組み立てている箇所を `grep -rn "SoratomoDependencies(" Soramoyou` で探して全部直す（いまは `live` と `SoramoyouTests/SoratomoDependenciesTests.swift:48` の2か所）
  - ビルドが通り、既存の `SoratomoDependenciesTests` が通る
  - _Requirements: 4.3, 5.3_

- [ ] 8. iOSの画面と配線を変える

- [ ] 8.1 抜けるの画面の状態 `SoratomoLeaveViewModel` を作る
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

- [ ] 8.2 タイムラインのViewModelに、監視を止める口を足す
  - 前提: 6
  - `SoratomoTimelineViewModel` に `suspendObservation()` を足す。グループとタイムラインの監視の札（`groupToken`・`timelineToken`）を手放して、監視を止める。再開は、既存の `start()` をもう一度呼ぶ（札が無いときだけ張る）
  - 止めた後は、監視の結果（`.notMember` を含む）がルーターへ届かず、「グループを開けませんでした」が出ない
  - `SoratomoTimelineViewModelTests`: `suspendObservation()` の後は監視の結果が届かない・`start()` で張り直す
  - 陽性対照: 札を手放さない実装で、止めた後に結果が届いてテストが赤になることを先に確かめる
  - _Requirements: 5.2_

- [ ] 8.3 ルーターに、抜けた後の遷移と、抜けたグループの通知の扱いを足す（陽性対照C6の前半）
  - 前提: 7.2, 7.4
  - `SoratomoRouter.finishLeaving(groupId:notice:)` を足す。パスにそのグループの画面があれば `path = []` にし、`notice` を出す（既存の3秒の一時表示）。文言は「{グループ名}を抜けました」で、`SoratomoError.notMember.userMessage` とは違う固定の文にする
  - `resolvePending` の「フラグが有効」の枝で、行き先の `groupId` が抜けたグループの記録にあれば、タイムラインを開かない。`pending = nil`・`path = []`・`isPresented = true`・`notice = SoratomoError.notMember.userMessage` にして、`notificationOpened(.notMember)` を1回記録する。判定の口は `isLeftGroup: @MainActor (String) -> Bool` のプロパティ（既定は常に偽）。本物は `SoratomoLeftGroups` と `currentUid` から作り、`SoratomoDependencies.live` の組み立てで `SoratomoRouter.shared` に入れる
  - オンラインで、記録に無いグループの通知は今のまま
  - `SoratomoRouterTests`: `finishLeaving` は `path = []` にして、文言が「グループを開けませんでした」でない。抜けたグループの通知はタイムラインを開かず、`notificationOpened(.notMember)` を1回記録する
  - 陽性対照（C6）: 今の現物で、抜けたグループの通知がタイムラインを開くことを先に確かめる
  - _Requirements: 5.1, 5.2, 5.7_

- [ ] 8.4 グループ一覧で抜けたグループを隠し、参加で記録を外す（陽性対照C6の後半・要確認Q7の判断）
  - 前提: 6, 7.1, 7.4
  - 一覧（`SoratomoGroupListViewModel.load()`）: 読んだグループのうち、記録にあるものは `membershipOnServer` を呼ぶ。`.member` なら記録から外して出す（別の端末で入り直した場合）。`.notMember` と `.unknown` なら出さない。オフラインでは `.unknown` になるので、端末のキャッシュに残った抜けたグループは出ない。記録に無いグループは今のまま（呼ばない）
  - 参加（`SoratomoGroupFormViewModel.submitJoin()`）: 成功したら、そのグループを記録から外す。`leave_pending` の失敗は、既存の失敗の表示で文言を出し、入力した招待コードを残す。`soratomo_join_failed` の `reason` は `leave_pending`
  - 要確認Q7: 入り直しの成功で、そのグループの端末の覚え（画像のキャッシュと投稿の覚え）も消すかを、実装の時に判断して結果に書く。消さない場合に古い投稿が一瞬出うるのは、見た目の問題として不具合にしない
  - `SoratomoGroupListViewModelTests`: 記録にあるグループは `.member` のときだけ出して記録から外す・`.notMember` と `.unknown` では出さない・記録に無いグループでは再確認を呼ばない。`SoratomoGroupFormViewModelTests`: `leave_pending` で入力が残り、`reason` が `leave_pending`・参加の成功で記録から外れる
  - 陽性対照（C6）: 今の現物で、記録にあるグループが（端末のキャッシュから）一覧に出ることを先に確かめる。参加の失敗で入力を消す実装で、テストが赤になることも確かめる
  - _Requirements: 5.3, 5.6, 8.1, 8.5, 12.3_

- [ ] 8.5 タイムラインの画面に入口・確認・処理中の表示を置き、抜けた後の後片づけを配線する
  - 前提: 8.1, 8.2, 8.3, 8.4
  - 入口: 右上の `ToolbarItemGroup` の最後に `Menu`（`ellipsis.circle`）を足し、中身は「グループを抜ける」（`role: .destructive`）だけにする。既存の3つのボタン（メンバー一覧・招待・投稿）と、タイムラインの `init` の形は変えない。`SoratomoLeaveViewModel` は、タイムラインの `init` で `@StateObject` として作る
  - 確認: `phase` が `confirming` のとき、`.alert` に見出し「{グループ名}を抜けますか？」と本文、「キャンセル」（`.cancel`）と「抜ける」（`.destructive`）を出す（既存のブロックの確認と同じ型）。`alertMessage` はOKだけのアラートで出す
  - 処理中: `phase` が `leaving` の間、画面全体に半透明の覆いと `ProgressView` と「グループを抜けています…」を出し、内容・右上のボタン・戻るボタン（`navigationBarBackButtonHidden`）を無効にする。投稿の画面は開けない（D3の隙間を広げないため）
  - 配線: 監視を止める口と張り直す口に、8.2の `suspendObservation()` と `start()` をつなぐ。`reportNotAccessible` のクロージャは、先に `absorbLostMembership(groupId:)` を呼び、真ならルーターへ知らせない（D1）。抜けた後は、8.1の順（記録→画像と投稿の覚え→計測→`finishLeaving`）で進める
  - `SoratomoImageCache.purgeLegacyIfNeeded()` を、起動の後で、そらともの画像を読む前に1回呼ぶ場所に置く（置いた場所を結果に書く）
  - 確認と処理中は、新しい画面にしない（画面名を足さない）
  - シミュレーター（`C2E3F752`）でビルドして、メニューと、見られる組み合わせの確認の文言（キャンセルまで）を目視する。テスト用アカウントでのログインと、本番のデータの表示は、利用者のGOを取ってから行う。「抜ける」の確定は、本番にCallableがまだ無いのでここでは押さない（12.1で行う）
  - _Requirements: 1.1, 1.2, 1.3, 1.6, 1.9, 5.1, 5.4, 5.5_

- [ ] 9. iOS全体を点検する

- [ ] 9.1 ログと個人情報・変更なしで満たすこと・既存の挙動を点検する
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

- [ ] 9.2 iOSのビルドとテストを通す
  - 前提: 9.1
  - ビルドにエラーと新しい警告が無いこと、そらともと既存のテストが通ることを確かめる（`C2E3F752`・負荷を見て・`nice`・1本ずつ）
  - 既存のテストのうちmainで既に落ちているもの（例: `ProfileViewModelTests` の一部）は、変更前のmainでも同じく落ちることを確かめて区別する
  - 6〜8の各テストが、陽性対照で赤になったことの記録を確かめる（記録の無いテストは、先に陽性対照を取り直す）
  - 退会の手順に差分が無いことを、もう一度差分で確かめる
  - _Requirements: 10.1, 10.6_

## (f) ドキュメントの反映

- [ ] 10. ドキュメントを実装に合わせる

- [ ] 10.1 (P) データの置き場の記録と、release-gateの契約の表を直す
  - 前提: 1〜4（実装が設計どおりであること）
  - `docs/firestore-schema.md` のそらともの表に、`soratomoPendingLeaves`（文書ID `{uid}_{groupId}`・`uid`・`groupId`・`episodeId`・`leftAt`・書き手はFunctionsだけ）の行を足す。抜けるで消すもの（抜けた人のそのグループの投稿と画像・通知の間引き・所属の写し。最後の1人ならグループごと）の1文も足す
  - release-gate specのdesign.mdの「API Contract（そらとものCallableのまとめ）」の表に、`soratomoLeaveGroup` の行と、`soratomoJoinGroup` の `failed-precondition`・`leave_pending` を足す（または、このspecのdesign.mdを指す1行を足す）
  - 書き終えたら、変更した識別子で検索し、実装と食い違う記述が残っていないことを確かめる
  - _Requirements: 4.6, 8.4, 10.3, 10.4_

- [ ] 10.2 (P) 「退出は対象外」と書いた既存のspecに、上書きの注記を足す
  - 前提: 3.1
  - 既存の「⚠️2026-10-09 上書き（soratomo-release-gate …）: …」の書き方にそろえ、本文は書き換えずに1行を足す。場所は、soratomo specのrequirements.md 6行（対象外（v1）の「退出」）と373行・design.md 19行（Non-Goalsの「退出」）、release-gate specのrequirements.md 347行・tasks.md 536行（「グループから抜ける機能は無い」の記録）の5か所
  - 書く内容: 本人が1つのグループだけを抜けることは、soratomo-leave-groupで対象に入れた。オーナーによるグループの削除・除名・オーナーの手動の譲渡は、引き続き対象外
  - 行番号は書く前に現物で確かめる（ほかの作業で行がずれていれば、文で探す）
  - _Requirements: 1.1, 3.13_

## (g) 本番への反映

- [ ] 11. 本番へ反映する（すべてユーザーのGOを取ってから）

- [ ] 11.1 出す前の確認と、pushとPRの作成（ユーザーのGOを取ってから実行）
  - 前提: 5, 9.2, 10
  - ユーザーのGOを取ってから実行する。AIは単独で実行しない
  - `git fetch -q origin` の後、mainが進んでいれば取り込み、`npm run lint`・`npm test`・`npm run test:emulator`・ルールのテスト（通常と `--mutants`）・iOSのビルドとテストを、もう一度通す
  - PRを出す前に `/review-full` でレビューし、新しいCallableが外からの入力を受けるので、続けて `/security-review` を通す。指摘の直しを済ませてから出す
  - 初回のpushは `git push -u origin 機能-そらとも-グループだけ抜ける`（上流を自分のブランチにする）。PRの本文に、要件・設計・tasks.mdの場所と、public-launchとの順番（このPRのマージ・本番への反映・受け入れの確認の後に、public-launchへ進む）を書く
  - _Requirements: 10.2, 10.3, 10.4, 10.6_

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
