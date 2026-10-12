# Implementation Plan

## 進め方の約束

- **着手の条件**: leave-group spec（`.kiro/specs/soratomo-leave-group/`）が main に入り、本番へ反映され、受け入れの確認が済んでから着手する（leave-group の `tasks.md` の「結果」で見る＝段0-1＝タスク1）。両 spec とも `functions/soratomo.js`・`firestore.rules`・テストを触るので、spec をまたいだ並行はしない。ブランチは main から切る（切る前に `git fetch -q origin && git log --oneline origin/main..HEAD` で未コミットを数える。origin/main から切ったブランチの初回の push は `git push -u origin <ブランチ名>`）。
- **着手の条件の変更（2026-10-11 19:30・利用者の決定）**: 上の条件を緩める。leave-group が main に入った直後（leave-group の tasks.md の 11.2 の後）から、leave-group の 11.3〜13 と並行して始めてよい。並行してよいのは、main からブランチを切る・コードとテストを書く・PR を作るまで。**main へのマージ（9.3 と 11.2）と本番の操作は、leave-group の 12〜13 が済んでから**行い、タスク1（受け入れが済んだことの確認）はマージの直前に行う。受け入れの開発版に一般公開の変更を混ぜないため。leave-group の受け入れで直しが main に入ったら、PR-A と PR-B のブランチを main に合わせ直す
- **PR は2本**。
  - PR-B（アプリ）: ブランチ `機能-そらとも一般公開-アプリ`。判定・What's New・オンボ（PR #163 の取り込み）・ポリシーの本文・版数・テスト。**先に main へ入れる**（段0-4＝9.3）。
  - PR-A（サーバー）: ブランチ `機能-そらとも一般公開-サーバー`。ルール2本・Functions・テスト・読み返しの道具・文書。PR の作成とレビューは先に済ませてよいが、**マージは切り替えの当日**（段1-1＝11.2）で、そのまま出す。先にマージすると、別の理由で main からルールや Functions を出したときに、予定より早く開くため。
  - **PR-B を main へ入れた後は、1.15.0 以外の版を main から作らない**。1.14.x の急ぎの修正が要るときは、PR-B より前のコミットから枝を切る（PR-B の入ったアプリは、クレームの無い人にも入口を出すので、サーバーを開ける前に配ると「入口は出るのに拒否される」画面になる）。
  - main へ直接コミット・push しない。コミットは日本語（`機能:`・`修正:`・`ドキュメント:`）。`git add .` を使わず、対象のファイルを明示する。
- 「（ユーザーのGOを取ってから実行）」と書いた操作と、次の操作は、利用者のGOを得るまで実行しない。AIが単独で実行しない。1手ずつGOを取る。対象: push・PR の作成と閉じること・マージ。ルール・Functions・hosting のデプロイ。本番の Firestore・Auth・Storage の読み書き（ログと一覧の読み取りを含む）。TestFlight へのアップロード。App Store Connect の読み書き。審査への提出。利用者の端末の操作。`scripts/soratomo-admin.js` の本番への実行。
- App Store Connect の画面の手作業（スクリーンショット・プライバシーラベル・年齢区分・審査メモ）は開発者が行う。AIは文案と確かめ方を用意する（要件8.7）。
- firebase CLI には必ず `--project soramoyou-ios` を付ける（`.firebaserc` が空のため）。
- secret とトークンの値を、コマンドの引数・出力・ログ・チャットのどこにも出さない。読み返しの道具とルールのテストも、firebase CLI のトークンを画面に出さない。本番の設定を REST で読むときは、項目の名前で絞って読む（release-gate tasks.md 14.5 で `signIn` を丸ごと出し、ローテートできない鍵が会話に載った前例）。招待コードは、リポジトリ・ログ・このファイルに書かない。
- **陽性対照**: 各テストは、先に「わざと壊した実装かルール」で赤になることを1回確かめてから、正しいもので通す。design.md の決定どおり、同じブランチで「テストを先に」コミットし、変える前のコードとルールで赤を記録してから実装する。コードを変えた後の「わざと壊す」確かめは、scratchpad の一時的な worktree で行う（作業ツリーのコードを壊して戻す手順をとらない。共有の stash は使わない）。取れなかったときは「検証済み」と書かず、取れなかった理由を記録する。
- **design.md の「要確認」**は、確かめるまで「検証済み」と書かない。確かめる場所は次のとおり。1はタスク1（承認版の突き合わせと、leave-group の現物の数え直し）と 2.2・3.2・11.5。2は2.1と2.3。3は10.2。4は不要（利用者の判断1で「承認されたら自動で公開」のままと決まり、提出の道具を変えないため）。5は13.3。6は12.3。7は10.2。8は11.5。9は15.1。10は2.5。
- **design.md の「要件への差し戻し」1〜5**は、利用者が「設計の読み方のまま進める」で承認済み。読み方は該当タスクに書いた。1は11.5。2は10.1と15.3。3は12.2。4は10.4と13.3。5は6.1と7.1。
- **リリース手順書（design.md の Migration Strategy）の段とタスク**: 0-1＝1、0-2＝10.1、0-3＝10.2、0-4＝9.3、0-5＝10.4、1-1＝11.1と11.2、1-2＝11.3、1-3＝11.4、1-4＝11.5、1-5＝11.6、2-1＝12.1、2-2＝12.2、2-3＝12.3、3-1＝13.1、3-2＝13.2、3-3＝13.3、3-4＝13.4、3-5＝13.5、4-1＝14.1、5-1＝14.2、5-2と5-3＝14.3、6-1＝15.1、6-2＝15.2、6-3＝15.3。
- **結果の書き方**: 各タスクの結果は、そのタスクの `_Requirements:` の行の後に「結果（日時・GOを取ったか）」として足す（release-gate tasks.md 14〜18 と同じ形）。空の結果の行は前もって置かない。
- **本数の数え方を混ぜない**: `functions/soratomo.js` の中は、Callable 8本・トリガー2本・定期実行1本・計11本（leave-group の後の値。本 spec は増やさない）。本番の関数全体は、leave-group の前が21本、後が22本（本 spec は増やさない）。
- Functions のテストは `functions/` で `npm run lint`・`npm test`（単体）・`npm run test:emulator`（firestore と storage のエミュレーター）。8080 などのポートが別のセッションで使われていたら、ポートを変えた設定ファイルを `--config` で渡す（release-gate 14.1 の前例）。
- ルールのテストは `python3 scripts/rules_test_soratomo.py [firestore.rules のパス]` と `python3 scripts/rules_test_storage_soratomo.py [storage.rules のパス]`（どちらも `--mutants` で変異テスト）。ルールのパスは、いまも引数で受け取れる（両ファイルの使い方の行と `main()`）。401 が返るときは `firebase projects:list > /dev/null` を一度実行してから再実行する。
- iOS のビルドとテストは、`uptime` と `pgrep -x xcodebuild` で負荷を見てから、`nice -n 19` と `-jobs 4` で1本ずつ行う（重ねて回すとMacごと落ちた先例がある）。テストのシミュレーターは iPhone 17e の `C2E3F752` を使う（共用の `BF678DA1` は使わない。design.md の Testing Strategy は `DCFBF2D6` と書いているが、この約束を優先する）。新規の利用者のオンボの確かめ（12.2 の 8）だけ `DCFBF2D6` を使う（このシミュレーターのアカウントにクレームは無い）。
- archive は、`~/.claude/scripts/xcode-testflight-upload.sh` に `-jobs` を渡す口が無いので、同じフラグに `nice -n 19` と `-jobs 4` を付けて archive と export を行い、アップロードは別にGOを取る（1.14.1 の前例）。
- 新しい Swift ファイルは、プロジェクトの同期グループが自動で拾う。`project.pbxproj` への手での追加はしない。版数の値の変更（8.2・12.1）だけは `project.pbxproj` を直す。
- `(P)` を付けたタスクは、前提に書いたタスクが済んでいれば、ほかの `(P)` のタスクと同時に進めてよい（触るファイルと資源が重ならない）。付けていないタスクは、同じファイルを触るか、前のタスクの成果物に依存するか、エミュレーター・ビルド・シミュレーターを共有する。iOS のタスクは、ビルド・DerivedData・シミュレーターが1つで1本ずつしか回せないので付けない。運用の段（本番・App Store Connect・端末）にも付けない。同じブランチの `(P)` を別のセッションで進めるときは、同じ作業ツリーで同時にコミットしない。
- Functions・ルール（PR-A）と iOS（PR-B）は別の境界で、契約は design.md で固定済みなので、別のセッションで並行して進めてよい。
- このtasks.mdに `textlint --fix` を掛けない（見出しの番号の後の空白が消える）。

## (a) 着手の条件（段0-1）

- [x] 1. leave-group の反映と受け入れの確認が済んだことを確かめ、承認版と現物で突き合わせる（要確認1）
  - leave-group の `tasks.md` で、main へのマージ・本番への反映（`soratomoLeaveGroup`・定期実行の仕事C・`firestore.rules` の拒否だけの `match`）・受け入れの確認のタスクに「結果」があり、完了していることを読む（2026-10-11 に書かれた leave-group の tasks.md では11・12、結果のまとめは13）。このときのルールの関門は、まだクレームの判定のまま（leave-group は `isSoratomoUser()` に触れない）
  - 要確認1（承認版の design との突き合わせ）: 2026-10-11 に承認版の leave-group `design.md` を読み、本 spec の design.md の P12 と内容の食い違いが無いことを確かめた（tasks.md の作成時）。一致した項目: Callable の名前 `soratomoLeaveGroup`・`requireFlag: false`・8本目の Callable で `module.exports` の11本目・新しい関数は足さず `soratomoHousekeeping` に仕事C・`firestore.rules` に拒否だけの `match /soratomoPendingLeaves/{markerId}` を `soratomoConfig` の後に足し `isSoratomoUser()` に触れない・`storage.rules` は変えない・入口はタイムラインの右上のメニュー（`ellipsis.circle`）の「グループを抜ける」。P12 の行番号（`design.md:452`・`:462`）は承認版では453行・463行（1行ずれ）。承認版は加えて、`firestore.rules` の拒否のコレクションの数のコメント（2つ→3つ）と `functions/index.js` のコメント（Callable 7本→8本）を直し、`scripts/rules_test_soratomo.py` に `soratomoPendingLeaves` のケースと変異を足す。イベントは `soratomo_group_left`・`soratomo_leave_failed`・`soratomo_join_failed` の `reason` の `leave_pending`
  - 要確認1（現物での数え直し・leave-group が main に入った後）: `grep -n "requireFlag" functions/soratomo.js` で、選択肢を渡しているのが `soratomoDeleteMyData` と `soratomoLeaveGroup` の2か所だけ。`module.exports` が11個。`functions/soratomo.js` の頭の説明が Callable 8本・計11本。`firestore.rules` に `soratomoPendingLeaves` の拒否だけの `match` があり、`isSoratomoUser()` は変わっていない。`storage.rules` に leave-group の差分が無い。抜けるの入口の画面の言葉（メニューの項目名）。違っていれば、このファイルの関数の指定（3.1・11.5）・本数・期待値22・What's New（7.1）と審査メモ（10.4）の言葉を直してから進む
  - 本番の関数の数: leave-group の反映の後の `firebase functions:list --project soramoyou-ios` の名前と数（22本）を、leave-group の結果から引く。書かれていなければ、GOを取って読む
  - `git fetch -q origin` の後、`git log --oneline origin/main` で leave-group のマージが入っていることを見てから、PR-A と PR-B のブランチを main から切る
  - _Requirements: 12.3, 12.4_
  - 結果（2026-10-12 08:10・本番は読んでいない＝GO は不要だった）:
    - leave-group の完了: `git fetch` の後の origin/main の leave-group の `tasks.md` で、1〜14 がすべて `[x]` で、11〜14 に結果がある。main へは `d204a9e`（#174・機能）・`7364bb5`（#176・11〜13 の記録）・`72bf527`（#177・14 の隙間の直しと記録。2026-10-11 23:02Z のマージを `gh pr view 177` で確認）で入っている。leave-group 13 の要約: 出し元 `d204a9e`・本番の関数 22 本（11.3）・Firestore のルールの本番の読み返しが main とバイト一致（ruleset `8ba8a746`・11.5）・要確認Q4 と Q1 は 11.4・11.6 で確認済み・受け入れ（12.1・12.2）は 2026-10-12 01:56〜06:45 にシミュレーター 2 台と本番で済んだ
    - 本番の関数の数: 22 本は、leave-group 11.3 の結果（2026-10-12 01:34・出した後の `functions:list`）から引いた。このタスクでは本番を読んでいない
    - 要確認1（現物での数え直し・origin/main `72bf527` の中身）:
      - `grep -n "requireFlag" functions/soratomo.js`: 選択肢として渡しているのは 262 行（`soratomoDeleteMyData`）と 304 行（`soratomoLeaveGroup`）の 2 か所だけ。ほかの該当は関門の定義と説明のコメント
      - `module.exports` は 11 個（Callable 8・トリガー 2・定期実行 1）。ファイルの頭の説明も「Callable 8本・トリガー2本・定期実行1本」と「11 本」。`functions/index.js` の 550 行の説明も Callable 8 本
      - 要確認8 の先取り（数の内訳だけ）: `functions/index.js` の `exports.名前 =` が 9・`functions/skyMotion.js` が 2・`soratomo.js` の `module.exports` が 11 の計 22 で、leave-group 11.3 の本番の 22 本と数が合う。名前の突き合わせは 11.5 で行う
      - `firestore.rules`: `soratomoPendingLeaves` の拒否だけの `match`（読み書きとも `false`）が `soratomoConfig` の後（660 行）にある。`isSoratomoUser()`（573 行）の本体は leave-group の前（`b07da6e`）と同じで、まだクレームの判定（`request.auth.token.get('soratomoBeta', false) == true`）のまま
      - `storage.rules`: `b07da6e..origin/main` の差分は 0 行（leave-group は触れていない）
      - `scripts/rules_test_soratomo.py` に `soratomoPendingLeaves` のケースがある。`functions/soratomo.test.js` の `CALLABLES` はまだ 6 本で、`soratomoLeaveGroup` は無い（3.1 で足して 7 本にする想定のとおり）
      - 抜けるの入口の画面の言葉（`SoratomoTimelineView.swift` の 590〜603 行）: タイムラインの右上のメニュー（アイコン `ellipsis.circle`・VoiceOver の読み上げ「その他の操作」）の項目「グループを抜ける」（アイコン `rectangle.portrait.and.arrow.right`・destructive）。7.1 と 10.4 の言葉はこれにそろえる
      - 食い違いは無かったので、このファイルの関数の指定（3.1・11.5）・本数・期待値 22・7.1 と 10.4 の言葉は直していない
    - ブランチ: origin/main（`72bf527`）から `機能-そらとも一般公開-アプリ`（PR-B）を上流なしで切り、この記録をコミットした。`機能-そらとも一般公開-サーバー`（PR-A）は同じコミットから切る（タスク1の記録を両方の共通の土台にし、PR-B が先に main へ入っても、5 の origin/main の取り込みでこの行がぶつからないようにする）。どちらもまだ push していない（初回は `git push -u origin <ブランチ名>`）
    - leave-group から渡されたもの（後のタスクで拾う）:
      - 相手役 B（`soratomo5@gmail.com`・uid `nhYcDQ…`・クレームあり）は、10.1 の S5（クレーム無し・未作成）とは別人。S5 には別のメールを使う。10.1 で S5 を足すときに、**B の uid も `research.md` の除外の条件に足す**。leave-group の受け入れで、開発版 1.14.1 / 111（出荷していない組み合わせ）のイベントが本番の PostHog に届いている（ID の頭は B と S3）ので、除外の条件で落ちることを 12.3 で見る
      - 実機で未確認のまま渡されたもの（12.2 の通しで見る）: 機内モードの 2 つ・オフラインの一覧・古い通知・抜けたことやオーナーになったことの通知が来ないこと・古い版（1.14.x）での投稿・leave-group 8.5 の (b)(c)・leave-group 14 の「確認を出せない間に画面が詰まらないこと」
      - 12.3 の G4 のイベントに `soratomo_group_left`・`soratomo_leave_failed`・`soratomo_join_failed` の `leave_pending` が入っていることは、leave-group 13 で確認済み。`leave_pending` は本番でふつうには起こせないので、0 件が期待どおり（根拠は leave-group の単体テスト C1）

## (b) PR-A（サーバー）: ルール2本と読み返しの道具

- [ ] 2. ルール2本の関門を「登録済みでログイン」に置き換える（テストを先に）

- [x] 2.1 (P) Firestore のルールのテストを作り直し、変える前のルールで陽性対照を取る（要確認2）
  - 前提: 1
  - `scripts/rules_test_soratomo.py` の、ログインしたケースのトークンを `{"firebase": {"sign_in_provider": <方式>}, ...クレーム}` で作る。`case()` の `claim` の代わりに方式を持たせる。ログインしたケースには必ず方式を入れる（書き忘れると、許可を期待するケースが「エラーで拒否」になって見つかる）
  - 登場人物: 既存の `MEMBER` などは `password`＋クレーム `soratomoBeta`（1.14.x のクレームのある人も通る）。`NOCLAIM` は残し、`password`＋`skyMotionBeta` だけ（別のクレームに左右されないことも見る）。`ANON`（`anonymous`・g1 のメンバーの文書あり）を足し、メンバー判定のモックの集合に入れる。ファイルの頭の説明と `case()` の説明を、新しい登場人物に合わせる
  - 「機能フラグ」の節を「ログインの種類」の節に替える。クレーム無しのメンバー: グループの取得・メンバー一覧・投稿一覧・自分の投稿の削除・自分の所属数の取得・自分の所属の写しの一覧 → 許可（6件）。投稿の作成 → 拒否（`if false` のまま）。匿名のメンバー: 同じ6つ → 拒否
  - leave-group が足した `soratomoPendingLeaves` のケースと変異は残す（`case()` を通るので、トークンの形の変更がそのまま効く）
  - 要確認2: Rules test API が入れ子の `firebase.sign_in_provider` を受け取ること。匿名のメンバーのケースが「エラーでなく条件で拒否」になり、登録済みが許可されることで見る（受け取れなければ、テストの方式を見直す。判定式は変えない）
  - 陽性対照: テストの変更を先にコミットし、変える前のルール（`git show origin/main:firestore.rules` を scratchpad に写したもの）に通常の実行を流す。期待外れが「クレーム無しのメンバーの許可」の6件だけであることを、件数で記録する（匿名のケースは、古いルールでもクレームが無いので条件で拒否され、緑のまま）
  - ここでは `--mutants` を流さない（置き換え元の新しい式は2.2の後にルールに現れる）
  - _Requirements: 1.1, 1.6, 1.7, 1.9, 4.1, 10.1, 10.4_
  - 結果（2026-10-12 08:26・GO は取っていない）:
    - 変えたもの: `scripts/rules_test_soratomo.py` だけ。ログインしたケースのトークンを `{"firebase": {"sign_in_provider": 方式}, ...クレーム}` の形で作るようにした。方式とクレームは登場人物ごとの表 `TOKENS` から引き、`case()` の `claim` はやめた。既存の登場人物（`AUTHOR`・`OWNER`・`MEMBER`・`OUTSIDER`）は `password`＋`soratomoBeta`、`NOCLAIM` は `password`＋`skyMotionBeta` だけ。新しい `ANON` は `anonymous` で、クレームは何も持たせていない（g1 のメンバーの文書あり・メンバー判定のモックの集合に入れた）。ファイルの頭の説明（spec の一覧・トークンの約束）、登場人物と `case()` の説明、トークンを作る所のコメントも合わせた
    - 「機能フラグ」の節を「ログインの種類」の節に替えた。中身: クレーム有り（1.14.x）のメンバーのグループの取得（許可・既存）。クレーム無しのメンバーの 6 つ（グループの取得・メンバー一覧・投稿一覧・自分の投稿の削除・自分の所属数の取得・自分の所属の写しの一覧）は許可。クレーム無しの投稿の作成は拒否のまま。匿名のメンバーの同じ 6 つは拒否。節は 7 件から 14 件になり、全体は 116 件から 123 件になった。leave-group の片づけ中の印の 20 件と、その変異はそのまま
    - コミット: `7df001c`（テストを先に。`MUTANTS` はこのコミットでは触らず、2.2 で替えた）
    - 基準: 変える前のテストを、`git show origin/main:firestore.rules` の写しに流して 116/116。写しの sha256 の頭 `187ac94b5e73` は、leave-group 11.5 の本番の指紋と同じ。最初は 401 が返ったので、`firebase projects:list > /dev/null` を 1 回してから流し直した
    - 陽性対照: コミットした `7df001c` のテストを同じ写しに流した。123 件中、期待どおり 117 件・期待外れ 6 件（終了コード 1）。期待外れは次の 6 件だけで、どれも許可を期待するケース。「種類 クレーム無しのメンバーがグループを取得」「種類 クレーム無しのメンバーがメンバー一覧を取得」「種類 クレーム無しのメンバーが投稿一覧を取得」「種類 クレーム無しの投稿者が自分の投稿を削除」「種類 クレーム無しの本人が所属数を取得」「種類 クレーム無しの本人が所属の写しの一覧を取得」。匿名の 6 件とクレーム無しの投稿の作成は緑のまま。「エラーで拒否」の注記は 0 件
    - 要確認2（入れ子の `firebase.sign_in_provider` を Rules test API が受け取るか）: 古いルールはこの項目を読まないので、上の 117/6 は要確認2 の証拠にならない。そこでコミットの前に、写しの `isSoratomoUser()` の本文だけを新しい式にしたルールへ、新しいテストを流した。結果は 123/123 で、「エラーで拒否」の注記は 0 件。匿名の 6 件は条件で拒否され、クレーム無しの登録済みの 6 件は許可された。2.2 の本物のルールでも同じ結果になった（2.2 の結果を参照）
    - エラーでの拒否と条件での拒否の見分け方: テストの `is_ok()` で見分ける。拒否を期待するケースで、API の `debugMessages` に `Error` が含まれていたら期待外れにし、行の末尾に「（エラーで拒否: …）」と出す。許可を期待するケースがエラーになると、`state` が `FAILURE` になって期待外れになる。この見分けが効くことを、scratchpad の使い捨ての 4 ケースで確かめた。新しいルールで、トークンから `firebase` を抜いた匿名は「（エラーで拒否: … Property firebase is undefined on object.）」で NG。同じく抜いたクレーム無しの登録済みは `state=FAILURE` で NG。`firebase` のある 2 ケースは、エラー 0 件で OK
    - tasks.md との違い: 方式の書き忘れは、評価の時の「エラーで拒否」より前の段階で止まる。`case()` の `TOKENS[uid]` が `KeyError` を出すので、新しい登場人物を表に足し忘れると、テストが走る前に止まる。評価の時の見分けも残っていることは、上の確かめで見た。また、`ANON` にクレームを持たせないのは design.md に書いていない決めごと。「匿名のケースは古いルールでも条件で拒否され、緑のまま」という design の前提に合わせた
    - ここでは `--mutants` を流していない（tasks.md のとおり）

- [x] 2.2 (P) Firestore のルールの判定式を置き換え、通常と変異テストを通す
  - 前提: 2.1
  - `firestore.rules` の `isSoratomoUser()` の中身だけを `isAuthenticated() && request.auth.token.firebase.sign_in_provider != 'anonymous'` にする。関数の名前と呼ぶ側（6か所）は変えない。`firebase` の項目を `get` の既定値つきで読まない（項目の無いトークンはエラーで拒否＝閉じる側に倒れる）
  - 「匿名でない」を条件にし、「メールとパスワードだけ」にはしない（いまのログイン方式では結果は同じ。research.md の決定）
  - そらとも以外の `match`、`skyMotionBeta` の判定、メンバー判定、投稿者本人の判定には触れない。差分が `isSoratomoUser()` の本文とそらともの節のコメントだけであることを `git diff` で見る
  - コメント: `isSoratomoUser()` の上の説明（「3か所で同じクレームを要求する」「get の既定値 false で読み」）を、「3か所で同じ『登録済みでログイン』を要求する。匿名は拒否。1.15.0で一般公開（soratomo-public-launch）」の内容に書き換える。`isSoratomoMember` の「`isSoratomoUser()` の後ろに && でつなぐ」の注意はそのまま
  - 変異テスト: 置き換え元を `CLAIM` から `REGISTERED`（上の式）に替え、design.md の表の5つ（匿名の判定を外す・匿名の判定を逆にする・登録済みの判定を常に偽・ログインの判定を外す・ログインと匿名とメンバーの判定をすべて外す）を入れる。メンバー判定と削除の投稿者判定の壊し方は既存のまま
  - 要確認1の続き: `REGISTERED` を含むすべての置き換え元が、ルールに1回だけ現れる（既存の検査で、飛ばされる壊し方が0）
  - 通常の実行が全件緑。`--mutants` で「どの壊し方でも期待外れにならないケース」と「どのケースも期待外れにしない壊し方」が0件。件数を記録する
  - 陽性対照: 2.1 で赤だった6件が、この変更で緑になったことを並べて記録する。「ログインの判定を外す」は、未ログインのトークンの読み取りがエラーになることで見つかる（本番の挙動ではエラーでも拒否なので、安全の差は「すべて外す」が受け持つ・research.md）
  - _Requirements: 1.1, 1.5, 1.6, 1.7, 1.9, 4.1, 10.2, 10.3, 13.1, 14.1_
  - 結果（2026-10-12 08:28・GO は取っていない）:
    - 変えたもの: `firestore.rules` の `isSoratomoUser()` の本文を `isAuthenticated() && request.auth.token.firebase.sign_in_provider != 'anonymous'` にした（`get` の既定値つきでは読まない）。関数の上の説明も書き換えた。内容は、3 か所で同じ「登録済みでログイン」を要求すること・匿名は拒否・1.15.0 で一般公開（soratomo-public-launch）・クレーム soratomoBeta は見ないこと・「匿名でない」を条件にした理由・項目の無いトークンはエラーで拒否される（閉じる側に倒れる）こと。`isSoratomoMember` の「`&&` でつなぐ」の注意はそのまま
    - `scripts/rules_test_soratomo.py`: 変異テストの置き換え元を `CLAIM` から `REGISTERED` に替えた。design.md の表の 5 つ（匿名の判定を外す・匿名の判定を逆にする・登録済みの判定を常に偽・ログインの判定を外す・ログインと匿名とメンバーの判定をすべて外す）を入れ、クレームの壊し方 3 つは消した。メンバー判定と、削除の投稿者判定の壊し方は既存のまま。壊し方は 21 個から 23 個になった
    - コミット: `40b48e4`
    - 差分の確かめ: `git diff origin/main -- firestore.rules` は 1 か所（568〜576 行の説明と本文）だけ。呼ぶ側の 6 か所・メンバー判定・投稿者本人の判定・`skyMotionBeta` の判定（474・530 行）・そらとも以外の `match` は変わっていない。`storage.rules` と `functions/` の差分は 0 行。ルールの中に `sign_in_provider != 'anonymous'` は 1 回だけ現れる
    - 通常の実行: 123/123（終了コード 0・「エラーで拒否」の注記 0 件）。そらとも以外に影響が無いことの確かめとして、変えていない `rules_test_post_update.py` を新しいルールに流して 13/13
    - `--mutants`: 壊し方 23 個。どの壊し方でも期待外れにならないケースは 0 件、どのケースも期待外れにしない壊し方は 0 個、置き換え元が 1 回でない壊し方は 0 個（終了コード 0）。最後の 0 個で、要確認1 の続き（`REGISTERED` を含むすべての置き換え元が 1 回だけ現れる）を確かめた。新しい 5 つの期待外れの件数: 匿名の判定を外す 6 件（匿名の 6 件）・逆にする 21 件（許可の 15 件＋匿名の 6 件）・常に偽 15 件（許可のすべて）・ログインの判定を外す 4 件（未ログインのグループの取得・メンバー一覧・投稿一覧・削除）・すべて外す 15 件
    - 「ログインの判定を外す」の 4 件は、エラーでの拒否として見つかったことを使い捨ての確かめで見た。4 件とも「（エラーで拒否: … line [576], column [14]. Null value error.）」と出た。未ログインの投稿の作成と、閉じたコレクションの未ログインのケースは、`isSoratomoUser()` を通らないので緑のまま
    - 陽性対照: 2.1 で赤だった 6 件が、この変更で 6 件とも緑になった。6 件はクレーム無しのメンバーの、グループの取得・メンバー一覧・投稿一覧・自分の投稿の削除・自分の所属数の取得・自分の所属の写しの一覧。匿名の 6 件は、この変更の後も条件で拒否され、エラーは 0 件だった。これで要確認2 を確かめた
    - ルールは deploy していない（本番へ出すのは 11.2 以降）

- [x] 2.3 (P) Storage のルールのテストを作り直し、変える前のルールで陽性対照を取る（要確認2）
  - 前提: 1
  - `scripts/rules_test_storage_soratomo.py` のトークンの形と登場人物を2.1と同じにする（`ANON` を足し、`NOCLAIM` は `password`＋`skyMotionBeta`）。ファイルの頭の説明（「クレームの無い利用者には別のクレーム…」）も合わせる
  - 「機能フラグ」の節を替える。クレーム無しのメンバー: 画像を読む・自分のパスへ保存・自分の画像を削除（内容なし）→ 許可（3件）。匿名のメンバー: 同じ3つ → 拒否
  - 要確認2（Storage）: 匿名のメンバーが「エラーでなく条件で拒否」になり、登録済みが許可されること
  - 陽性対照: テストの変更を先にコミットし、変える前の `storage.rules` の写しに通常の実行を流して、期待外れが「クレーム無しのメンバーの許可」の3件だけであることを記録する
  - _Requirements: 1.1, 1.6, 1.7, 1.9, 4.1, 10.1, 10.4_
  - 結果（2026-10-12 08:29・GO は取っていない）:
    - 基準値（08:20・変える前のテストと origin/main `72bf527` の `storage.rules`）: 通常 24 件すべて期待どおり。`--mutants` は壊し方 27 個・どのケースも期待外れにしない壊し方 0 個・どの壊し方でも期待外れにならないケース 0 件
    - 変えたファイル: `scripts/rules_test_storage_soratomo.py` だけ（`ccf12bc`・本文に「テストを先に（public-launch 2.3）」）
      - トークン: ログインしたケースを `{"firebase": {"sign_in_provider": <方式>}, ...クレーム}` の形で作る。`case()` の `claim` を消し、登場人物から決まる `provider`（`PROVIDERS`・ANON だけ `"anonymous"`、ほかは `"password"`）と `claims`（`CLAIMS`・NOCLAIM は `skyMotionBeta` だけ・ANON はクレーム無し・ほかは `soratomoBeta`）を持たせた。ログインしたケースには方式が必ず入る
      - 登場人物: `ANON`（匿名・クレーム無し・g1 のメンバーの文書あり＝`G1_MEMBERS` に入れた）を足した。`NOCLAIM` は `password`＋`skyMotionBeta` だけ。`MEMBER` などの 4 人は `password`＋`soratomoBeta`（1.14.x のクレームのある人）
      - 「機能フラグ」の節（4 件）を「ログインの種類」の節（7 件）に替えた。クレーム有りのメンバーが画像を読む（許可・残した）。クレーム無しのメンバーが画像を読む・自分のパスへ保存・自分の画像を削除（内容なし）（拒否→許可）。匿名のメンバーの同じ 3 つ（拒否・新規）。ケースは 24 → 27 件
      - ファイルの頭の説明（spec の行・トークンの形・クレーム無しの利用者の行）と `case()` の説明を直した。`MUTANTS` はここでは変えず、2.4 で直した
    - 陽性対照（08:24・変える前の `storage.rules` の写し＝`git show origin/main:storage.rules` を一時置き場に置いたもの）: 27 件中 24 件が期待どおり・期待外れ 3 件。期待外れは「種類 クレーム無しのメンバーが画像を読む」「種類 クレーム無しのメンバーが自分のパスへ保存」「種類 クレーム無しの投稿者が自分の画像を削除（内容なし）」の 3 件だけ。匿名の 3 件は「エラーで拒否」の注記なしで期待どおり（古いルールでもクレームが無いので条件で拒否）。08:29 にコミットした `ccf12bc` の中身で流し直しても同じ 24 件・3 件
    - 要確認2（Storage）: 変える前のルールは `firebase` の項目を読まないので、この実行だけでは決められない。2.4 の新しいルールで確かめた（08:27〜08:28）
      - 新しいルールで、クレーム無しの登録済みの 3 件が許可・匿名の 3 件が拒否（エラーの注記なし）
      - 見分け方 1（式の報告）: 6 件を式の報告つき（`expressionReportLevel: FULL`）で流すと、`isSoratomoUser()` の本文（226 行 37 列）が、匿名では `'anonymous'` を読んで比較が false、クレーム無しの登録済みでは `'password'` を読んで true。どちらもエラーの debugMessages は 0 件＝匿名はエラーでなく条件で拒否
      - 見分け方 2（陽性対照）: 全ケースのトークンから `firebase` を抜いて新しいルールに流すと、匿名の 3 件が「エラーで拒否（Property firebase is undefined）」になり、許可の 10 件も期待外れ（計 13 件）。入れ子の項目が届かなければ、このテストは赤になる
      - 見分け方 3: 変異「匿名の判定を逆にする」で、匿名の 3 件が許可に変わって期待外れになる（項目があるだけでなく、値を読んでいる）
      - 確かめに使った使い捨てのスクリプトは一時置き場に置き、コミットしていない。結果はテストの頭の説明に残した（2.4 のコミット）
    - 2.1 との形のそろえ: この形を書いた時点（08:20 ごろ）で、2.1 の作業フォルダ（`~/dev/soramoyou-pl-rules-fs`）にはコミットも未コミットの変更も無かった。design.md の Testing Strategy の書き方に従って決めた（`PROVIDERS`・`CLAIMS`・`case()` の `provider` と `claims`・節の名前の頭「種類」）。名前は design.md / tasks.md に指定が無く、ここで選んだもの。2.1 が別の名前を選んでいたら、名前だけそろえる

- [x] 2.4 (P) Storage のルールの判定式を置き換え、通常と変異テストを通す
  - 前提: 2.3
  - `storage.rules` のそらともの `match` の中の `isSoratomoUser()` の中身を、2.2と同じ式にする。呼ぶ側（3か所）・メンバー判定・投稿者の一致・ファイル名と種類と大きさの検査・`skyMotionBeta` の判定・そらとも以外のパスは変えない
  - コメント: そらともの節の頭の「機能フラグを持つそのグループのメンバーだけ」と、関数の上の「機能フラグ（カスタムクレーム soratomoBeta）… get の既定値 false で読み」を、新しい判定の説明（登録済みでログイン・匿名は拒否・1.15.0で一般公開）に書き換える
  - 変異テスト: 置き換え元を `CLAIM` から `REGISTERED` に替え、4つ（匿名の判定を外す・逆にする・常に偽・ログインの判定を外す）を入れる。「クレームを直接読む（token.soratomoBeta）」は消す。「読み取りのクレーム判定を外す」と「削除のクレーム判定を外す」は、置き換え先の文字列はそのままで、名前を「読み取りの登録済み判定を外す」「削除の登録済み判定を外す」に変える（匿名のケースが期待外れになる）
  - どの壊し方も置き換え元が1回だけ現れること。通常が全件緑、`--mutants` で見分けられないケースと壊し方が0件。件数を記録する
  - 陽性対照: 2.3 で赤だった3件が緑になったことを並べて記録する
  - _Requirements: 1.1, 1.5, 1.6, 1.7, 1.9, 4.1, 10.2, 10.3, 13.1, 14.1_
  - 結果（2026-10-12 08:31・GO は取っていない）:
    - 変えたファイル: `storage.rules` と `scripts/rules_test_storage_soratomo.py`（`8d66817`）
      - `storage.rules`: そらともの `match` の中の `isSoratomoUser()` の本文を `isAuthenticated() && request.auth.token.firebase.sign_in_provider != 'anonymous'` にした。`git diff origin/main` でコメントを除いた差分は、この本文の 1 行だけ。差分の範囲は 210 行と 219〜223 行（そらともの節の中）で、呼ぶ側 3 か所・メンバー判定・投稿者の一致・ファイル名と種類と大きさの検査・`skyMotionBeta`（200 行）・そらとも以外のパスは変えていない
      - コメント: 節の頭の「機能フラグを持つそのグループのメンバーだけ」を「登録済みのアカウントでログインした（匿名でない）そのグループのメンバーだけ」に、関数の上の 3 行を 5 行（登録済みでログイン・匿名は拒否・1.15.0 で一般公開・3 か所で同じ条件・クレームは見ない・`firebase.sign_in_provider` を get の既定値つきで読まない）に直した。`isSoratomoMember` の「`isSoratomoUser()` の後ろに `&&` でつなぐ」の注意はそのまま。`grep -n "soratomoBeta\|機能フラグ" storage.rules` は 0 件（Migration 1-1 の grep を先に満たす）
      - 変異テスト: 置き換え元を `CLAIM` から `REGISTERED`（design.md の式そのまま）に替え、「匿名の判定を外す」「匿名の判定を逆にする」「登録済みの判定を常に偽」「ログインの判定を外す」の 4 つを入れた。「クレームを直接読む（token.soratomoBeta）」を消し、「読み取りのクレーム判定を外す」「削除のクレーム判定を外す」を「読み取りの登録済み判定を外す」「削除の登録済み判定を外す」に名前だけ変えた（置き換え先はそのまま）。壊し方は 27 → 28 個
      - design.md / tasks.md に無いこととして、テストの頭の説明に要確認2 の確認の結果（2026-10-12・式の報告と `firebase` を抜いたときのエラー）を 3 行足した
    - 置き換え元: `REGISTERED` はルールに 1 回だけ現れる。28 個すべての置き換え元が 1 回だけで、`--mutants` の「1 回のはず」の NG は 0
    - 通常の実行（08:27）: 27 件すべて期待どおり（終了コード 0）
    - 陽性対照（2.3 で期待外れだった 3 件）: 「種類 クレーム無しのメンバーが画像を読む」「種類 クレーム無しのメンバーが自分のパスへ保存」「種類 クレーム無しの投稿者が自分の画像を削除（内容なし）」が、変える前のルールで NG → このルールで OK
    - `--mutants`（08:27）: 壊し方 28 個・どのケースも期待外れにしない壊し方 0 個・どの壊し方でも期待外れにならないケース 0 件（終了コード 0）。新しい壊し方の期待外れの件数: 匿名の判定を外す 3 件（匿名の 3 件だけ）・匿名の判定を逆にする 13 件（許可の 10 件と匿名の 3 件）・登録済みの判定を常に偽 10 件（許可のすべて）・ログインの判定を外す 3 件（未ログインの 3 件）。名前を変えた 2 つは、匿名の読み取りと匿名の削除の 1 件ずつ
    - 「ログインの判定を外す」の見つかり方（08:31）: この壊し方だけを流し直して注記を見ると、未ログインの 3 件（読む・保存・削除）はどれも「エラーで拒否（226 行 16 列・Null value error）」として期待外れに数えられていた（design.md の P6 のとおり）
    - 08:28 に、説明を足した後のコミットする中身で通常と `--mutants` を流し直し、1 回目と同じ結果（27 件すべて期待どおり・壊し方 28 個・見分けられないケース 0 件）
    - 本番には出していない（`firebase deploy --only storage` と本番のルールへの流しは 11.3 と 10.6 の範囲で、GO を取ってから）

- [ ] 2.5 (P) 本番のルールの読み返しの道具を作る（要確認10）
  - 前提: 1
  - `scripts/read-deployed-rules.py`（新規）: Rules REST API を読むだけで、Firestore のリリース `cloud.firestore` と Storage のリリースについて、ruleset の識別子・更新の時刻・本文の sha256 の頭12桁を出し、本文を `<保存先>/firestore.rules` と `<保存先>/storage.rules` に保存する。保存先は scratchpad を引数で受ける。比べる手元のファイル（既定はリポジトリ直下の2本）の sha256 の頭12桁も並べ、一致しなければ終了コード1。本番に書かない
  - 認証は、ルールのテストと同じ firebase CLI のトークン（`~/.config/configstore/firebase-tools.json`）。トークンを出力しない。ファイルの頭に、使い方・読むだけであること・トークンを出さないことを書く
  - 要確認10: Storage のリリースの名前（`firebase.storage/soramoyou-ios.firebasestorage.app` はバケットの名前からの推定）を、リリースの一覧（読むだけ・GOを取ってから）で確かめ、違えば一覧の名前を使う
  - ルールのテスト2本は、いまもルールのパスを引数で受け取る（`main()` の `rules_path = args[0]`）。変更は要らない。保存した本文のパスをそのまま渡せることを確かめる
  - 陽性対照（本番の読み取りなのでGOを取ってから）: いまの本番（leave-group の反映の後）と main のルールで一致（終了コード0）になり、手元の写しに1行足して比べる先にすると、終了コード1になることを確かめる
  - _Requirements: 3.3, 10.6_
  - 結果（2026-10-12 08:32・GO は取っていない）:
    - 枝: `作業-一般公開-読み返し`（土台 `ec9f860`）。コミットは `7708c7c`（テストを先に）・`0aafb9b`（道具）・`287dffb`（表示の字下げ）・`00b963e`（テストの後片づけ）。push はしていない。本番は読んでいない
    - 足したもの: `scripts/read-deployed-rules.py`（新規）。Rules REST API を GET で読むだけ（リリース → ruleset）。リリース `cloud.firestore` と Storage のリリースについて、ruleset の識別子・更新の時刻（UTC と日本時間）・本文の sha256 の頭 12 桁を出し、本文を `<保存先>/firestore.rules` と `<保存先>/storage.rules` に保存する。比べる手元のファイル（既定はリポジトリ直下の 2 本）の頭 12 桁も並べ、一致しなければ終了コード 1。ファイルの頭に、使い方・読むだけであること・トークンを出さないこと・要確認10 を書いた
    - 認証: `rules_test_soratomo.py` と同じファイル（`~/.config/configstore/firebase-tools.json`）の同じ項目を読む。トークンは出さない。HTTP のエラーの本文・通信の失敗の文・想定外の例外の文は、トークンを伏せてから出し、トレースバックは出さない。認証ヘッダーは作るだけで、どこにも出さない
    - 確かめ方（②）: 「ネットワーク（urlopen）とトークンの読み込みを差し替える単体テスト」を選んだ（本番の本文を手元のフォルダから読む口は作っていない）。`scripts/read-deployed-rules.test.py`（新規・unittest・標準ライブラリだけ）。差し替え漏れでネットワークを呼ぶと、道具の受け口でも捕まらない例外で落ちるので、本番には触れない
    - テストを先に: `7708c7c` の時点では道具が無いので、読み込みの段で FileNotFoundError になり、19 件が流れずに赤（ケースごとの赤ではない）
    - 通常: 19/19 が緑（ResourceWarning もエラーとして扱って流した）。① `py_compile` は 2 本とも通る
    - 陽性対照（壊し方）: scratchpad の一時 worktree（使った後に消した）で、道具を 1 か所ずつ壊す 16 個。16 個とも赤（見分けられなかったもの 0）。置き換え元が 1 回だけ現れることも確かめた
      - 常に一致にする → 1 行足した・Storage だけ違う・改行の違いの 3 件 / 読めなかったときを 1 にする → 5 件 / トークンを伏せない → 3 件 / HTTP のエラーで要求のヘッダーを出す → 401・HTTP のエラーの本文の 2 件 / 手元を文字で読み改行をそろえる → 改行の違い / 保存先の確かめを外す → リポジトリの中・直下の 2 件 / 保存するのを手元の本文にする → 1 行足した / POST を送る → 一覧・一致の 2 件 / 401 の手順を出さない → 401 / 再試行しない → 通信の失敗 / 手元のファイルの確かめを外す → 手元のファイルが無い / ログイン情報の例外の文をそのまま出す → ログイン情報が壊れている / 想定外の例外を伏せない → 想定外の例外 / ruleset のファイル数を確かめない → 1 個でない / Storage のリリースの名前の引数を使わない → 名前を変えられる / 一覧の次のページをたどらない → 一覧
      - 1 回目の実行では、保存先の確かめを外した版がリポジトリの中（一時 worktree）に保存先を作って残し、後の壊し方で同じテストが巻き添えで赤になった。テストに「前の残りが無い」の確かめと後片づけを足し（`00b963e`）、作り直した worktree で流し直した結果が上
    - ルールのテストの `--mutants`: 流していない（2.5 ではルールを変えていない）
    - 道具の出力の確かめ（scratchpad の確かめ用の台本・コミットしない）: 偽の API がリポジトリ直下の 2 本を「本番の本文」として返し、`ya29.` で始まる偽の目印をトークンに使った。終了コードは、一致 0 / 手元の写しに 1 行足した先 1（Firestore だけ不一致）/ 401 は 2（手順の文つき）/ 通信の失敗の文に目印 2（`<伏せた>` になる）/ 保存先がリポジトリの中 2（本番を読まない）。頭 12 桁は Firestore `187ac94b5e73`・Storage `7ec51426f1ea` で、保存した本文はリポジトリの 2 本とバイト一致
    - ③ `ya29`・`Bearer`・`access_token`・`refresh_token` は、道具の出力（台本）・単体テストの出力・ルールのテスト 2 本の出力のどれでも 0 件。grep 自体の陽性対照は、目印を 1 行足した写しで 1 件。単体テストの出力だけでは、道具の出力をテストの中で受けているので空振りになりうる。確かめの本体は台本の出力
    - ルールのテストのパス: `scripts/rules_test_soratomo.py` の 373 行、`scripts/rules_test_storage_soratomo.py` の 300 行が `rules_path = args[0] if args else …`（使い方の行は 11〜12 行・9〜10 行）。変えていない。道具が保存した本文のパスをそのまま渡して、`rules_test_soratomo.py` 116/116・`rules_test_storage_soratomo.py` 24/24（通常）。この 2 本は評価の API（`:test`）を本物の firebase CLI のトークンで呼ぶ（本番のデータと出ているルールは読まない）。`nice -n 19`・1 分平均 4.65
    - design.md との違い:
      - 読めなかったとき（API の失敗・手元のファイルが無い・保存先がリポジトリの中・使い方の誤り）は終了コード 2。design.md は不一致の 1 だけを決めていて、ルールのテストは API の失敗も 1。陽性対照の「1 行足した写しで 1」を、読み取りの失敗と見分けるため
      - ログイン情報が読めないときは、例外の文を出さず型の名前だけにした（ルールのテストは例外をそのまま出す。項目の名前や中身の一部が載るのを避けるため）
      - 足した引数: `--firestore`・`--storage`（比べる手元）・`--storage-release`（要確認10）・`--list-releases`（一覧だけ。要確認10 を、トークンを引数に載せずに 1 行で頼めるようにするため）
      - 保存先がリポジトリの中なら断る・手元のファイルが無ければ本番を読まない（手元の 2 本を本番の本文で上書きしないため）
      - 比べるのは本文の bytes 全体（出すのは頭 12 桁）。ruleset のファイルが 1 個でないときは、読めなかった扱い
    - 要確認10: 未確認（本番の読み取りなので GO 待ち）。`STORAGE_RELEASE` は推定のまま
    - 検証済みでないもの: 本物の Rules REST API を一度も呼んでいない（Storage のリリースの名前の `/` を URL にそのまま置く形・本物のログイン情報の読み込み・本番の応答の形）。期待値 `187ac94b5e73` は leave-group の tasks.md 509 行の記録（ruleset `8ba8a746`）と同じだが、記録との突き合わせで、いま本番を読んだのではない。Storage の ruleset と指紋の記録は無い
    - 残り（GO 待ち）: 要確認10（一覧で Storage のリリースの名前を確かめる）と、本番での陽性対照（本番と main で 0・1 行足した写しで 1）

## (c) PR-A（サーバー）: Functions

- [x] 3. Callable の関門と新着通知の宛先を置き換える（テストを先に）

- [x] 3.1 (P) Functions のテストを先に作り直し、変える前のコードで陽性対照を取る
  - 前提: 1
  - `functions/soratomoCore.test.js`: `isRegisteredToken` のテストを足す（`password`・`apple.com` → 真。`anonymous`・`firebase` 無し・トークン無し・方式が文字列でない → 偽）。`classifyRecipient` のテストから `hasFlag` を外し、順序のテストを「設定OFF → ブロック → トークン無し」にする。クレームの無い宛先が `eligible` になるケースを足す
  - `functions/soratomo.test.js` のトークン: `ON` と `authOf` の既定を、登録済み `{ firebase: { sign_in_provider: "password" } }` にする。クレームのある1.14.xの人は `{ soratomoBeta: true, firebase: { sign_in_provider: "password" } }` で表す。leave-group が足した抜けるのテストのトークンも同じ形にそろえる（`firebase` の無いトークンは拒否されるようになるため）
  - `CALLABLES` に `soratomoLeaveGroup`（`{ groupId }`）が無ければ足して7本にする（leave-group が足していれば二重に足さない）
  - 置き換え: 「クレームが無い・true でなければ flag_off」のテストを、「クレームの無い登録済みは、7本とも関門で止められない（拒否されるならドメインの理由で、`registration_required` でも `flag_off` でもない）」と「クレーム無しで作成・参加・投稿・通報・同意が通る」に替える
  - 足す: 「匿名は7本とも `permission-denied`・`details.reason` `registration_required` で、何も書かない」「`firebase` の無いトークンも同じく拒否」「クレームのある登録済みも通る」「未ログインは今までどおり `unauthenticated`」「選択肢 `requireFlag` を渡すと、読み込みの時点で例外になる」
  - 残す: 退会の削除の匿名のテスト（匿名でも自分のデータを消せる）
  - 通知: 種のクレームに関係なく、クレームの無い宛先へ送られる（集計の `flagOff` は0・`sent` が1増える）。宛先の絞り込みで Auth を読まない（`getUsers` の呼び出しが0回）。「フラグの確認に失敗」のテストは「Auth が失敗しても送る」に替える。既存の規則（設定OFF・ブロック・トークン無し・5分の間引き）のテストは残す
  - 陽性対照: テストの変更を先にコミットし、変える前の `soratomo.js`・`soratomoCore.js` で `npm test` と `npm run test:emulator` を流す。赤になるのが「`isRegisteredToken`」「クレーム無しのケース」「匿名の拒否の理由」「選択肢の名前の検査」「通知のケース」だけであることを、件数で記録する
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.6, 1.7, 1.8, 1.9, 4.1, 10.1, 10.4_
  - 結果（2026-10-12 09:05・GO は取っていない）:
    - 準備: `functions/package-lock.json` は git の管理外（`functions/.gitignore`）で作業フォルダに無かったので、本体の checkout から写して（読むだけ・コミットしない）`npm ci` を1回。基準値は土台 `ec9f860` で `npm run lint` 通過・`npm test` 290/290・エミュレーター 215/215（leave-group 11.1 と同じ）
    - エミュレーター: 開始のときは 8080 などは空いていたが、並行のセッションとぶつからないよう、ポートを 8280・9260・9399・4430・4530・9098 に替えた設定（ルールのパスは作業フォルダの絶対パス）を scratchpad に置き、`firebase emulators:exec --config <その設定> --only firestore,storage` で `npm run test:emulator` と同じ7ファイルを流した。TMPDIR は scratchpad の `emu/`。以下のエミュレーターの件数はすべてこの形
    - テストのコミット `3ade394`（テストを先に・public-launch 3.1）:
      - `soratomoCore.test.js`: `isRegisteredToken` のテストを4件足した（password・apple.com → 真／匿名とクレームつきの匿名 → 偽／トークン無し・null・firebase 無し・firebase が null や文字列・方式が数値や真偽値や null やオブジェクトや配列 → 偽／クレームを読まない）。`classifyRecipient` から `hasFlag` を外し、順序のテストを「設定OFF → ブロック → トークン無し」に。「hasFlag は true のときだけ」を消し、「宛先のクレームを見ない（hasFlag を渡されても読まずに eligible・flag_off を返さない）」を足した。集計のテスト（`flagOff` を含む）は変えていない
      - `soratomo.test.js`: トークンを REGISTERED（`{ firebase: { sign_in_provider: "password" } }`・既定）・CLAIMED（クレームつきの登録済み＝1.14.x の人）・ANONYMOUS にした。偽の Auth の customClaims は BETA_CLAIMS に名前を分けた（定期実行の場面の中身は同じ）。`CALLABLES` に `soratomoLeaveGroup`（`{ groupId }`）を足して7本
      - 「クレームが無い・true でなければ flag_off」を消し、6件を足した: 匿名（クレームつきの匿名も）は7本とも `permission-denied`・`registration_required`（詳細は理由だけ）で何も書かない／方式の読めないトークン（`{}`・クレームだけ・`firebase: {}`・方式が数値・トークン無し）も7本とも同じく拒否／クレームの無い登録済みは7本とも関門で止められない／クレームの無い登録済みの2人で同意・作成・参加・投稿・通報・再発行・抜けるが通る／CLAIMED でも同じ流れが通る／`soratomoCallable` に知らない選択肢（`requireFlag: false`・`requireFlag: true`・`allowAnonymus`）を渡すと読み込みの時点で例外（対照: 知っている選択肢だけなら読み込めて、同じ11本を公開する）
      - 選択肢の名前の検査は、`soratomoCallable` を公開していない（公開は11本だけ）ので、`soratomo.js` の本文の `module.exports` の前に1行足した写しを、偽物の読み込みを入れた間だけ `Module._compile` して確かめる形にした
      - 抜けるのテスト: 「クレーム無し（匿名）」を「クレーム無し（登録済み）」に、「クレームが false」・利用停止中・未同意も登録済みのトークンに、メンバーでない carol の `{}` も登録済みにした（匿名と方式の無いトークンは関門で拒否されるようになるため。匿名の抜けるは上の7本の拒否のテストが受け持つ）。退会の削除の匿名と `{}` のテストは残した
      - 通知: b（クレーム無し）にも送る＝送り先 a・b・f・`sent` 3・`flagOff` 0・`getUsers` 0回。重複と間引きは 3 件、1人の送信の失敗は `sent` 2。「フラグの確認に失敗」は「Auth が失敗しても送る」に替えた。要確認6 も `sent` 3・`flagOff` 0
    - 陽性対照（変える前の `soratomo.js`・`soratomoCore.js` のまま、`3ade394` のテストで流した）:
      - `npm test`: 294 件中 285 緑・9 赤。`isRegisteredToken` の4件（`core.isRegisteredToken is not a function`）と `classifyRecipient` の5件（実際の値が `flag_off`）
      - エミュレーター: 220 件中 189 緑・31 赤。tap の出力でテストごとに落ち方を見て、5種類に分けた:
        - 匿名の拒否の理由 2件: 匿名の7本・方式の読めないトークン（実際は `flag_off`、期待は `registration_required`）
        - 選択肢の名前の検査 1件（`Missing expected exception: { requireFlag: false }`）
        - クレーム無しのケース 23件: 新しい2件（関門で止められない・2人で通る）と、既定のトークンがクレーム無しになった既存の21件（作成3・参加2・再発行1・作成と参加2・投稿2・拒否のログ1・通報1・同意1・転送3・release-gate 4.5 の節の投稿1・語のリスト1・通報2・同意1）。すべて `flag_off` で落ちた。既定のトークンを design のとおりクレーム無しにしたので、成功の経路の既存のテストは、古いコードではすべて赤になる
        - 通知のケース 5件: トリガーの4件（送り先に b が無い・件数が 2）と要確認6（古いコードでは先に投稿の作成の `flag_off` で落ちる。分類は通知だが、落ち方はクレーム無し）
      - 緑のままだったもの: CLAIMED の通し・未ログインの7本・抜けるの4件（古いコードでも抜けるはクレームを見ない）・退会・定期実行・トリガーの残り4件（最新の活動時刻2・表示名・グループが無い）
      - 5種類のどれにも入らない赤は無かった
    - `--mutants` はルールのテストのもので、このタスクでは流していない

- [x] 3.2 (P) 関門と通知の宛先を置き換え、わざと壊した実装で確かめる
  - 前提: 3.1
  - `functions/soratomoCore.js`: 純粋関数 `isRegisteredToken(token)` を足す（`firebase.sign_in_provider` が文字列で `"anonymous"` でないときだけ真。クレームを読まない）。`classifyRecipient` の引数から `hasFlag` を消し、`flag_off` の分岐を消す。集計 `summarizeNotifyOutcomes` と対応表は変えない（`flagOff` の項目は残し、公開後はいつも0になる。1.14期のログと同じ形で読める）。`classifyRecipient` の説明から `hasFlag` とフラグOFFを消す
  - `functions/soratomo.js` の関門: `requireSoratomoUser(request, { allowAnonymous })` は、未ログインなら `unauthenticated`、`allowAnonymous` が偽で `isRegisteredToken` が偽なら `permission-denied`・`details.reason` `registration_required`。クレーム `soratomoBeta` を読まない
  - `soratomoCallable` の選択肢 `requireFlag` を、逆向きの既定を持つ `allowAnonymous`（既定 `false`）に置き換える。知らない選択肢の名前（`requireFlag` を含む）を受け取ったら、モジュールの読み込みの時点で例外を投げる（消し忘れを、テストもデプロイもその時点で止める）
  - `soratomoDeleteMyData` は `allowAnonymous: true` にし、理由（匿名と、一度もそらともを使っていない人のデータも消すため）をコメントに残す。`soratomoLeaveGroup` の `requireFlag: false` の1行を消し、選択肢を何も渡さない（既定＝匿名を拒否。要確認1の続き: leave-group の現物でこの1行があることをタスク1で確かめたうえで消す）。抜けるが利用停止中・未同意の人も受け付けるのはトランザクションの側の判定で、関門は変えない
  - `REASON_TO_CODE` に `registration_required: "permission-denied"` を足し、`flag_off` を消す。`soratomoStore.js` の JSDoc の `flag_off` も消す。拒否のログは既存の形 `{name}: rejected { uid, reason }`
  - 通知: `fetchFlaggedUids` とその呼び出しを消す（通知のたびの `getAuth().getUsers` が1回減る）。`getAuth` の読み込みは定期実行が使うので残す。匿名の宛先を除く分岐は足さない（匿名は参加できない）
  - 説明: ファイルの頭の説明（本数は leave-group の後の Callable 8本・トリガー2本・定期実行1本・計11本のまま。「soratomoBeta のクレームを確かめ」「クレームは確かめない」を登録済みと匿名の説明に）と、関門・選択肢・退会の削除・通知の説明の「クレーム」「フラグ」を直す
  - アプリの変更が要らないことを現物で確かめる: 1.15.0 のアプリは `registration_required` を知らないが、`SoratomoGroupService` の `mapCallableError` が理由を知らない `permission-denied` を `.permissionDenied` に写し、Callable を呼ぶほかのサービスも同じ写しを通る
  - `npm run lint`・`npm test`・`npm run test:emulator` が緑。3.1 で赤だったケースが緑になったことを並べて記録する
  - 陽性対照（実装の後）: scratchpad の一時的な worktree（このブランチの先頭から）で、①匿名の判定を外す → 匿名のテストが赤 ②`allowAnonymous` の既定を `true` にする → 同じく赤 ③クレームの確認を戻す → クレーム無しのテストが赤 ④宛先の絞り込みを戻す → 通知のテストが赤、を1つずつ確かめ、終わったら worktree を消す
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.6, 1.7, 1.8, 1.9, 4.1, 10.1, 14.1_
  - 結果（2026-10-12 09:05・GO は取っていない）:
    - 実装のコミット `ecc5c6d`:
      - `soratomoCore.js`: 純粋関数 `isRegisteredToken` を足した（`firebase.sign_in_provider` が文字列で `anonymous` でないときだけ真・クレームを読まない）。`classifyRecipient` から `hasFlag` と `flag_off` の分岐を消し、説明を「設定OFF → ブロック → トークン無し・クレームで絞らない・匿名を除く分岐は持たない」に直した。集計 `summarizeNotifyOutcomes` と対応表は変えていない（`flag_off` の行に「1.15.0 からは返さない・1.14 期のログと同じ形のために残す」のコメントを1行足しただけ）
      - `soratomo.js`: `requireSoratomoUser(request, { allowAnonymous })` は、未ログインなら `unauthenticated`、`allowAnonymous` が true でなく `isRegisteredToken` が偽なら `permission-denied`・`registration_required`。選択肢 `requireFlag` を `allowAnonymous`（既定 false）に替え、受け付ける名前（`allowAnonymous`・`runtime`・`respond`・`okLogFields`）以外を渡すと `soratomoCallable` が例外を投げる（Callable は最上位で作るので、読み込みの時点で止まる）。`soratomoDeleteMyData` は `allowAnonymous: true`（理由のコメントつき）。`soratomoLeaveGroup` の `requireFlag: false` の1行とそのコメントを消し、選択肢を渡さない形にした（タスク1で 304 行にあることを確かめた行）。`REASON_TO_CODE` に `registration_required` を足し、`flag_off` を消した。`fetchFlaggedUids` とその呼び出しを消した（`getAuth` は定期実行が使うので読み込みは残した）。匿名の宛先を除く分岐は足していない。ファイルの頭（本数は Callable 8本・トリガー2本・定期実行1本・計11本のまま）・関門・選択肢・退会の削除・抜ける・通知の説明を、登録済みと匿名の説明に直した
      - `soratomoStore.js`: `SoratomoDomainError` の JSDoc から `flag_off` を消した（`registration_required` はドメインのエラーではないので足していない）
      - コメントに `soratomoBeta`・`requireFlag` の文字列を残さない書き方にした。`grep -rn "requireFlag\|soratomoBeta" functions/*.js` はテストのファイル以外で 0 件（5・11.2 の検査の先取り。ルール2本の該当は 2.2・2.4 の範囲なので残っている）
    - テストの直し `cef17a2`（3.1 のテストの1か所）: 匿名の拒否のテストが、拒否のログの uid に認証の uid を期待していた。既存の `soratomoCallable` は関門の前に uid を決めないので、関門の拒否の uid は null になる（1.14 期の `flag_off` も同じ）。design の「拒否のログは既存の形」に合わせ、uid が null・理由が `registration_required`・項目が uid・groupId・skyId・reason だけ、を見る形に直した。3.1 の赤の記録は `3ade394` の版で取った。直した版を古いコードで流し直してはいないが、このテストは古いコードでは最初の `assert.rejects` で先に落ちる（下の陽性対照①②でも、直した版が同じ場所で赤になった）
    - 結果: `npm run lint` 通過・`npm test` 294/294・エミュレーター 220/220。基準値（290/290・215/215）からの差は、単体が −1＋5、エミュレーターが −1＋6
    - 3.1 で赤だった単体の9件とエミュレーターの31件（3.1 の一覧のとおり）は、すべて緑になった
    - 陽性対照（実装の後。scratchpad の一時 worktree を `ecc5c6d` から作り、`node_modules` は作業フォルダへのリンク。1つ壊す → 単体とエミュレーターを流す → `git checkout -- functions/` で戻す、を4回）:
      - ① 匿名の判定を外す（`soratomoCore.js` の `isRegisteredToken` の `!== "anonymous"` を消す）: 単体 1 赤（`isRegisteredToken: 匿名は偽`）・エミュレーター 1 赤（匿名の7本。関門を通って同意の拒否 `failed-precondition` まで進んだ）
      - ② `allowAnonymous` の既定を true にする: 単体 0 赤・エミュレーター 2 赤（匿名の7本・方式の読めないトークン）
      - ③ クレームの確認を戻す（関門の後に「クレームが true でなければ flag_off」を足す）: 単体 0 赤・エミュレーター 28 赤（3.1 のクレーム無しの 23 件・抜けるの 4 件・要確認6）。どれも `flag_off` で落ちた。CLAIMED の通しは緑のまま
      - ④ 宛先の絞り込みを戻す（通知で `getUsers` を呼び、クレームの無い宛先を `flag_off` にする）: 単体 0 赤・エミュレーター 5 赤（トリガーの4件・要確認6）
      - 終わってから `git worktree remove --force` で消し、`git worktree list` に残っていないこと、作業フォルダの `soratomo.js`・`soratomoCore.js` がコミットと同じ（sha256 の頭 `fcacaf61620f`・`d943eaf6e68b`）ことを見た
    - design.md・tasks.md と違えたこと:
      - ① は design の「わざと壊した soratomo.js」でなく、匿名の判定がある `soratomoCore.js` を壊した
      - ④ は `soratomo.js` だけを壊した。`soratomoCore.js` の `classifyRecipient` に `hasFlag` を戻す壊し方は、3.1 の古い `soratomoCore.js` での赤（`classifyRecipient` の5件）が受け持つとみなし、別には流していない
      - `OUTCOME_TO_SUMMARY_KEY` にコメントを1行足した（表の中身は変えていない）
    - アプリの変更が要らないことの現物（作業フォルダの iOS のコードを読んだだけ・ビルドしていない）: `Soramoyou/Soramoyou/Services/SoratomoGroupService.swift` の `mapCallableError`（353〜380 行）は、`reasonToError`（388〜424 行）が知らない理由（`registration_required`）で nil を返し、375〜376 行で `permission-denied` を `.permissionDenied` に写す。この写しを通る呼び出し元は `SoratomoSkyService.swift:280`・`SoratomoModerationService.swift:102`・`SoratomoGuidelineService.swift:110`・`SoratomoAccountDeletionService.swift:107` と、design の一覧に無い `SoratomoLeaveService.swift:140`（抜けると退会は、通信以外をすべて `.unknown` にして記録に残す）。Callable の呼び出し（`httpsCallable`）は、この6つのそらとものサービス（Group:141・Sky:641・Moderation:215・Guideline:161・AccountDeletion:135・Leave:187）にしか無い
    - `--mutants` はルールのテストのもので、このタスクでは流していない

## (d) PR-A（サーバー）: 文書と全体の点検

- [x] 4. 文書と説明を、フラグの確認を外した後の姿に直す（PR-A に入れる）

- [x] 4.1 (P) データの置き場の記録と、付与のスクリプトの説明を直す
  - 前提: 1
  - `docs/firestore-schema.md` のそらともの節の「読み書きの条件」（2026-10-11 の342行。leave-group の追記でずれるので文言で探す）: 「クレーム `soratomoBeta` とメンバー判定」を「登録済みでログイン（`firebase.sign_in_provider` が `anonymous` でない）とメンバー判定」に直す。「1.15.0 から、Android 版のアカウントを含むログインした全員に開いている」を1行足す。leave-group が足した行は残す
  - `scripts/set-soratomo-beta-claim.js` の説明（12行の「一般の利用者には付けない」・29行の「付与されたテスターは、アプリの次の起動で入口が出る」）を、「1.15.0 からはそらともの利用に影響しない。1.14.x での確認のためだけに残す。公開の後は新しく付けない。取り消すときも skyMotionBeta は消さない（合成の仕組みのまま）」の内容に直す。コメントだけの変更にし、`set-soratomo-beta-claim.test.js`（`npm test` に入っている）が通ることを確かめる
  - _Requirements: 4.4, 6.3, 6.4, 6.5, 14.1, 14.3_
  - 結果（2026-10-12 08:21・GO は取っていない）:
    - 変えたもの: `docs/firestore-schema.md` のそらともの節の「読み書きの条件」を、「クレーム `soratomoBeta` とメンバー判定」から「登録済みでログイン（`firebase.sign_in_provider` が `anonymous` でない）とメンバー判定」に直し、「1.15.0 から、Android 版のアカウントを含むログインした全員に開いている」を1行足した。leave-group が足した行は触っていない。`scripts/set-soratomo-beta-claim.js` はコメントだけ（ヘッダーの「一般の利用者には付けない」と「付与されたテスターは…入口が出る」の2か所）。「1.15.0 からはそらともの利用に影響しない。1.14.x での確認のためだけに残す。公開の後は新しく付けない。取り消すときも skyMotionBeta は消さない（合成の仕組みのまま）」に直した。コードは1文字も変えていない。
    - コミット: f05f3ba
    - テスト: `cd functions && nice -n 19 npm test` が 290 件中 290 件緑・失敗 0・スキップ 0。set-soratomo-beta-claim.test.js の `mergeSoratomoClaim` 系も、この実行に入って緑。
    - 補足（手順と違うこと）: この worktree には node_modules も package-lock.json も無く（lock は gitignore）、最初の `npm ci` は lock が無くて失敗し、そのまま走った `npm test` は依存の欠落で 280 件中 4 件が赤だった（`@apple/app-store-server-library` と firebase-admin が見つからない）。soratomo worktree の lock を functions/ にコピーして `npm ci` し直し、全件緑にした。lock は gitignore なのでコミットには入らない。
    - 陽性対照: 文書とコメントだけの変更でコードを変えていないため取っていない。この `npm test` の緑は「コメントを直してもテストが壊れていない」の確認であり、新しい挙動の検証ではない。
    - 検証: `git diff` で変わった行が、狙いの3行（firestore-schema 1行直し＋1行追加、スクリプトのコメント2か所）だけであることを確かめた。

- [x] 4.2 (P) 既存の spec に上書きの注記を足す
  - 前提: 1
  - 既存の文は消さず、「（⚠️2026-10-xx 上書き: 一般公開（`.kiro/specs/soratomo-public-launch/` の要件N）で…に変わった）」の注記を足す（soratomo spec の要件13の9・10と同じ形）。日付は PR-A を main へ入れる日。leave-group が足した「⚠️上書き」の注記は残す。行番号は design.md の「文書の更新」の表（2026-10-11 の行）で、leave-group の注記でずれるので文言で探す
  - soratomo `requirements.md`: 要件1の1・3・6・7、要件10の10・14、要件17、決定事項13・14。1の6・7は「クレームでなく、登録済みでログインかで判定する（匿名は拒否）」、1の1・3と10の10・14は「1.15.0 から登録済みの全員に表示」、17は「G1〜G5 の記録は1.15.0の公開判断で残した（public-launch tasks.md 13.5）」
  - soratomo `design.md`: 7・30・322〜327・810・917・956・1135・1169行の付近。1135行（3か所を同時に変える）には「3か所を同時に変えた（1.15.0）。Android 版のアカウントを含むログインした全員に開いている」と書く。30行と322〜327行は要件に挙がっていないが、同じ「クレームで判定」の記述なので合わせて直す
  - release-gate `requirements.md`: 要件3の7（「1.15.0 から、登録済みの全員の退会の確認に1文を含める（public-launch 要件2の5）」）と、要件12の2（「判断の時点は1.15.0の提出の前」）
  - 書き終えたら、`soratomoBeta`・「機能フラグ」・「クレーム」で3つのファイルを検索し、注記の無い「クレームで判定」の記述が残っていないことを確かめる
  - _Requirements: 4.4, 14.1, 14.2, 14.3_
  - 結果（2026-10-12 08:21・GO は取っていない）:
    - 変えたもの: 既存の文は消さず、行末に「（⚠️2026-10-xx 上書き: 一般公開（`.kiro/specs/soratomo-public-launch/`の要件N）で…に変わった）」を足した（表の行は最後の ` |` の前）。soratomo `requirements.md` に12行、soratomo `design.md` に17行、release-gate `requirements.md` に5行、計34か所。leave-group が足した注記は残っている。Edit ツールは使わず Python の完全一致の置換で行い、書き換えのたびに「消えた行が1行もなく、新しい行が古い行の頭に注記を足しただけ」を機械で確かめた（最初に表の2行で注記が ` |` の外に出たのを見つけて直し、30 行・不一致 0 を確認）。textlint は掛けていない。
    - 日付: 置き目印の `2026-10-xx` を使った。先に `grep -rn "2026-10-xx" .kiro/specs docs` で、public-launch の tasks.md（文例1行）と design.md（文例1行）以外に既存の置き目印が無いことを確かめた。**11.2 で当日の日付に置き換える（`grep -rn '2026-10-xx' .kiro/specs` で拾う。public-launch の tasks.md の文例は除く）**。いまの数は soratomo/requirements.md 12・soratomo/design.md 17・release-gate/requirements.md 5・public-launch の tasks.md 1・public-launch の design.md 1（この2つは文例で置き換えない）。
    - 書いた中身: 要件の1の1・2・3・6・7と補足（クレームでなく登録済みでログインかで判定／1.15.0 から登録済みの全員に表示）、要件10の10・14（1.15.0 から登録済みの全員に表示）、要件17の1・2と決定事項13・14（G1〜G5 の記録は1.15.0の公開判断で残した＝public-launch tasks.md 13.5）。design.md は 7・30・323・328・329・330・798・811・918・957・1086・1099・1105・1119・1136・1170・1203 行（元の行番号の表から1〜2行ずれていた）。1136行には「3か所を同時に変えた（1.15.0）。Android 版のアカウントを含むログインした全員に開いている」と書いた。release-gate は 39・73・80・156（要件3の7＝登録済みの全員の退会の確認に1文を含める）・294（要件12の2＝判断の時点は1.15.0の提出の前）。
    - 設計の表にない行も足した: soratomo requirements の 58・59・66 行、design の 329・330・798・1086・1099・1105・1119・1203 行、release-gate の 39・73・80 行。どれも「クレームで判定する」とそのまま読める記述だったため。1203行は public-launch design.md の254行（`flag_off` は返さなくなる、拒否の理由は `registration_required`）に合わせた。
    - 最後の検索（`soratomoBeta`・機能フラグ・クレーム）で、注記が無いまま残る行と理由: soratomo requirements 8・16・18・26・32・54・55・414・434 行は、公開前ゲートを完了してから開く順序や用語の定義・見出しで、判定方法の記述でない（17の注記と決定事項13の注記が覆う）。61行（フラグ導入前と同じ挙動の保持）と200行（ログの「フラグOFF」の区分名。public-launch design 304行で `flagOff` は残してつねに0）は変わらない。344行（G3）・414行は G3 の時期の話で変わらない。design の 12・23・167・258・419・955・958・1160・1180 行は、概念の語・図のノード・当時の検証記録・スクリプトの手順で、判定の記述でない。258行（図の「機能フラグ ON か」）と1160行（図のノード）は図の中で注記を入れると壊れるため、同じ図の節にある323行・1170行の注記に任せた。1180行は2026-10-02 の検証済みの記録で、歴史として残す。release-gate の 27行は用語の定義、82行は1.13.0の事実、120行は退会削除がフラグに関わらない点で今も正しい。
    - コミット: 5722424
    - 陽性対照: 文書だけの変更で、実行するコードを変えていないため取っていない。「消えた行が無く追記だけ」の機械検査は、最初に表の2行で赤（BAD 2）を出してから直して 0 にした。
    - 4.2 は 4.1 と同じブランチで、触ったファイルは指示された5つ（firestore-schema.md・set-soratomo-beta-claim.js・soratomo の requirements.md と design.md・release-gate の requirements.md）だけ。

- [ ] 5. PR-A（サーバー）をまとめて確かめ、PR を作る（マージは切り替えの当日）
  - 前提: 2.2, 2.4, 2.5, 3.2, 4.1, 4.2
  - origin/main を取り込む（PR-B が先に入っていれば、それも入る）。`npm run lint`・`npm test`・`npm run test:emulator`・ルールのテスト2本（通常と `--mutants`）をもう一度通し、件数を記録する
  - `grep -rn "requireFlag\|soratomoBeta" functions/*.js firestore.rules storage.rules` が、テストのファイル以外で0件（段1-1と同じ検査）。陽性対照: 写しのファイルに1つ入れて、検査が引っかかることを先に確かめる
  - 差分で確かめる: そらとも以外の `match` とパス、`skyMotionBeta` の判定、メンバー判定・投稿者本人の判定、同意・NGワード・利用停止・1人10グループと1グループ20人の上限・招待コード（`soratomoStore.js` のトランザクション）、定期実行の仕事A（アカウントの無い人の後始末。Android 版の退会で残ったデータも24時間以内に拾う）が変わっていない。陽性対照: 既存のルールにわざと1行足して、差分の確かめが引っかかることを先に確かめる
  - 上限・同意・NGワード・利用停止の既存のテストが、トークンの形を変えた後も同じ件数で通っている
  - 既存のテストのうち main で既に落ちているものは、変更前の main でも同じく落ちることを確かめて区別する
  - push と PR の作成（ユーザーのGOを取ってから実行）。PR の本文に「マージは切り替えの当日（段1-1）。先にマージしない」と書く。ここではマージしない
  - _Requirements: 1.5, 4.1, 4.2, 5.1, 10.1, 10.2, 10.3, 13.1_
  - 結果（2026-10-12 09:29・GO は取っていない）:
    - 取り込み: 5 本の枝を、先頭が係の報告と一致することを見てから `git merge --no-ff` で入れた。衝突は 0。ルールFS `40b48e4`→`c453cdc`・ルールST `8d66817`→`f3331b5`・Functions `ecc5c6d`→`b044ab0`・文書 `5722424`→`7970755`・読み返し `00b963e`→`fcc8b50`。`git diff --stat ec9f860..HEAD` の合計（16 ファイル・追加 1069・削除 218）が 5 本の和と一致（取りこぼし・二重の取り込みなし）
    - origin/main: `git fetch -q origin` の後も 72bf527 のままで、取り込むものは無かった（PR #177 は `gh pr view 177` で MERGED・72bf527 を確認）
    - テスト（fcc8b50 で実行）: `npm ci` の後、`npm run lint` 緑・`npm test` 294/294・`npm run test:emulator` 220/220（ポートは既定のまま空いていたので package.json のコマンドをそのまま実行）・`rules_test_soratomo.py` 123/123・`--mutants` 壊し方 23・取りこぼし 0・置き換え元が 1 回でない壊し方 0・`rules_test_storage_soratomo.py` 27/27・`--mutants` 壊し方 28・取りこぼし 0・置き換え元が 1 回でない壊し方 0・`read-deployed-rules.test.py` 19/19。基準値（leave-group の後の main）は 290・215・116・壊し方 21 で、増えた分は 2.1〜3.2 で足したケースと壊し方
    - grep の検査（段1-1 と同じ `grep -rn "requireFlag\|soratomoBeta" functions/*.js firestore.rules storage.rules`・テストのファイルを除く）: 陽性対照として、一時置き場の写しの soratomo.js に `requireFlag` を 1 行混ぜて流し、その行が引っかかった。本物では `firestore.rules` 571 行のコメント（「クレーム soratomoBeta は見ない」）の 1 件が引っかかった（写しでも同じ行が出ており、検査が本物を見ていた）。storage.rules と同じ「クレームは見ない」の言い回しに直して 0 件にした（`3495cc5`・コメント 1 行だけ）。直した後に Firestore のルールのテストを流し直し、123/123・壊し方 23・取りこぼし 0。fcc8b50 と 3495cc5 の違いはこの 1 行だけなので、ほかのテストは流し直していない
    - 差分の確かめ: 一時置き場に小さな検査（72bf527 と比べた差分の塊が、許した範囲の外にあれば終了コード 1）を書いた。許した範囲は、ルール 2 本が `isSoratomoUser()` とその上の説明（Storage はそらともの節の頭の説明も）、soratomo.js は「仕事Aの締め切り」の定義から最後まで（仕事A・B・C・定期実行・exports）を守る範囲にした。陽性対照: HEAD の写しの `skyMotionBeta` の行の次（ルール 2 本）と `sweepUsersWithoutAccount` の中（soratomo.js）に 1 行ずつ足すと、3 つとも範囲の外に 1 個が出て終了コード 1。本物: firestore.rules 差分の塊 2 個・storage.rules 3 個・soratomo.js 25 個で、範囲の外はどれも 0 個
    - 差分の確かめ（補助）: ルール 2 本の `match /` の行（Firestore 28・Storage 14）・`skyMotionBeta` の行（5・2）・メンバー判定の行・`authorId` の行は、72bf527 と HEAD で中身が同じ（sha256 で比べた）。`functions/index.js`・`soratomoDeletion.js`・`soratomoNgWords.js`・`soratomoStorage.js`・`package.json`・`firebase.json`・`firestore.indexes.json` は差分なし。`soratomoStore.js` の差分は SoratomoDomainError の JSDoc から `flag_off` を消した 1 行だけで、トランザクション（上限・同意・NGワード・利用停止・招待コード）は変わっていない
    - 上限・同意・NGワード・利用停止の既存のテスト: 係の報告には件数が無かったので、72bf527 の一時 worktree（node_modules は symlink）で `npm test` 290/290 と `npm run test:emulator` 215/215 を流し、テストの名前で前後を突き合わせた。上限 13→13・NGワード 10→10・利用停止 25→25 は名前も同じで、すべて緑。同意は基の 20 件がすべて後でも緑（19 件は同じ名前、1 件は抜けるのテストで、匿名を関門へ移した言い換え）で、新しい 2 件（クレームの無い登録済み・クレームのある登録済みで同意から抜けるまで通る）を足して 22 件
    - 名前が消えたテストは、`classifyRecipient` の hasFlag と古い順序の 2 件（単体）と、クレームの確認・フラグの確認の失敗・送り先の分類・抜けるの言い換え・未ログインの 6 本の 5 件（エミュレーター）だけで、どれも design.md の置き換えのとおり
    - 落ちるテストは無かった（72bf527 でも HEAD でも 0 件）。一時 worktree は、symlink を外してから消した
    - 残り: push と PR の作成（GO 待ち）。2.5 の本番での陽性対照（GO 待ち）。PR の本文には「マージは切り替えの当日（段1-1）。先にマージしない」と書く

## (e) PR-B（アプリ）

- [ ] 6. アプリの判定を「登録済みでログイン」に替える

- [ ] 6.1 判定（`SoratomoFeatureGate`）を、トークンを読まない形に替える（テストを先に）
  - 前提: 1
  - 陽性対照: まず古い窓口のまま「クレームの無い登録済み（`claims` が空）→ 有効」のテストを足して赤を見てから、判定を変える
  - 判定は `currentAccountKind()` だけで決める: `nil` → 無効（未ログイン）・匿名 → 無効（匿名）・登録済み → 有効。通信しない（起動時に通信できなくても、登録済みなら入口が出る）。`evaluate()` は同期の関数にし、呼ぶ側（`ContentView` の `.task(id:)`）の `await` を外す（警告を残さない）
  - 消すもの: `DisabledReason.claimMissing` と `.tokenUnavailable`・`claimKey`・`needsForcedRefresh` と世代・`reevaluateIfTokenUnavailable()` と、その呼び出し（`SoramoyouApp.swift` の前面に戻ったときの Task）
  - 窓口のプロトコル `SoratomoClaimsProviding` を `SoratomoAccountProviding` に、本番の窓口を `FirebaseSoratomoAccountProvider` に名前を変え、実装している4か所（`ContentView`・`GuestTabView`・`MainTabView`・テストのモック）を合わせて直す
  - 型と、環境オブジェクトとして読む5つの画面は残す。入口（`SoratomoEntryButton`）・通知設定の「そらとも通知」・退会の文は `isEnabled` を読むので書き換えない
  - `SoratomoFeatureGateTests` を書き直す: 登録済み → 有効（クレームの有無に関係ない）・匿名 → 無効（匿名）・未ログイン → 無効（未ログイン）・初期値は判定前・`reset()` で判定前・`evaluate()` はモックの `currentAccountKind()` だけを読む。トークンの強制更新・世代・再評価のテストは消す
  - ゲストと匿名のホームに入口が出ないこと（切り替えの前と同じ）を、判定のテストで受け持つ
  - 差し戻し5（承認済みの読み方）: 匿名でログインすると `MainTabView` が出るので、全員向けの What's New（そらともの紹介）は匿名にも出る。匿名で入る画面が無いので受け入れ、匿名でそらとものページを除く判定は足さない
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 9.5, 10.4, 10.5, 13.2_

- [ ] 6.2 通知のタップの解決から、クレームの理由を外す
  - 前提: 6.1
  - `SoratomoRouter.resolvePending` の `case .unknown, .disabled(.tokenUnavailable)` を `case .unknown` にする。無効（匿名）は今までどおり保留を捨てて `flag_off` を記録する。クレームが無いことで `flag_off` を記録する経路は無くなる。イベントの名前と値（`flag_off` を含む）は変えない
  - leave-group が足した「抜けたグループの通知」の枝は壊さない
  - 説明のコメントの「フラグ」を「そらともを使えない（匿名）」に直す
  - `SoratomoRouterTests`: `.claimMissing` を `.anonymous` に替える。`testResolvePending_tokenUnavailableKeepsPendingUntilEnabled` を消す。未ログインと判定前のテストと、leave-group の分は残して通す。登録済みが通知をタップすると、soratomo spec の要件10の7〜9のとおりに開くテストが通る
  - 陽性対照: 匿名でも保留を残す側にわざと変えた実装で、匿名で `flag_off` を記録するテストが赤になることを確かめて戻す
  - 既存の3つの通知設定と、既存の通知のタップの挙動と計測に差分が無いことを、差分で確かめる
  - _Requirements: 2.6, 9.4, 9.5, 10.5, 13.3_

- [ ] 6.3 退会の確認の文を、単体テストで確かめられる形にする
  - 前提: 6.1
  - 文を作る部分を、純粋な静的関数 `SettingsView.deleteAccountConfirmationMessage(isSoratomoEnabled:)` に出す（`MainTabView.canShowWhatsNewAfterDelay` と同じ型）。文そのものは変えない
  - テスト: 真ならそらともの1文（そらともの投稿とグループへの参加も削除される）を含み、偽なら含まない。陽性対照: 1文を足す条件を逆にした実装で赤になることを先に確かめる
  - 通知設定の「そらとも通知」は変えない（`isEnabled` で出る）。退会の既存の8手順の対象と順序は変えない（差分で確かめる）
  - _Requirements: 2.4, 2.5, 10.5, 13.4_

- [ ] 7. 案内を全員向けに載せ直す

- [ ] 7.1 全員向けの What's New にそらともと「グループを抜ける」を載せ、先行公開の紹介をやめる
  - 前提: 6.1
  - `WhatsNewContent.currentID` を `"2026-10-soratomo-public"` にする。過去の値（`2026-09-sky-camera`・`2026-09-sky-ae`・`2026-09-ranking-recommended`・`2026-09-ranking-sky-ae`・`2026-10-soratomo-beta`）の一覧と、「1.15.0 で全員向けに載せ直した」経緯をコメントに書く（先行公開の節にあった「1.14 で全員に公開するときは…」のコメントは、節ごと消える）
  - `pages` を2ページに替える（下書き。確定は9.1）。1ページ目「そらとも」: 家族や友達だけの小さなグループで空を見せ合える・「ホーム右上の（アイコン）ボタン」から始める。アイコンは入口と同じ `person.2.circle`。2ページ目「グループの出入り」: 招待コードで参加できる・タイムラインの右上のメニューの「グループを抜ける」で、あとから抜けられる。抜けるの言葉は、タスク1で確かめた leave-group の画面の言葉にそろえる。バッジは「新機能」。先行公開の文「ホームの『そらとも』から」は画面と合わないので使わない
  - 消すもの: `soratomoIntroID`・`soratomoIntroSeenKey`・`soratomoIntroHeadline`・`soratomoPages`・`WhatsNewGate.shouldPresentSoratomoIntro`・`MainTabView` の `WhatsNewKind.soratomo`・`lastSeenSoratomoIntro`・`maybeShowSoratomoIntro()`。端末に残る既読のキーは消さない（読まれなくなるだけ）。全画面のカバーの `item:` の仕組みは、種類が1つになっても形を変えない（実機で直した経緯があるため）
  - `WhatsNewGateTests`: 先行公開の紹介のテストを消す。「`currentID` が過去の5つの値のどれとも違う」を足す（1.12.0 までを既読にした人にも出ることの柵。陽性対照: `currentID` を一時的に過去の値に戻すと赤）。`testRealCurrentIDBehavior` は残す
  - 案内の表示の判定: 全員向けの判定はアカウントの種類を受け取らず、既存のテストのまま受け持つ。ゲストは `MainTabView` に来ないので出ない。匿名には出る（差し戻し5）。オンボを終えた既存の利用者に1回だけ出て、オンボの完了で新しい識別子が既読になる（オンボの後に重ねて出ない）
  - _Requirements: 6.1, 7.1, 7.2, 7.3, 7.5, 7.7, 10.5, 14.1_

- [ ] 7.2 オンボーディングのそらとものページ（PR #163）を取り込む
  - 前提: 7.1
  - PR #163 の5つのコミット（`47e5fcc` オンボのページ、`c858133`・`4926acc`・`bd61b95`・`86e4987` スクリーンショットの素材と作り方）を、PR-B のブランチへ cherry-pick で取り込む。2026-10-11 の時点で、`Soramoyou/Soramoyou/Views/OnboardingView.swift`（blob `6c9e15e0`）と `screenshots/screenshot-gen/src/app/page.tsx`（`74efe4f6`）は PR の差分の元と一致し、ほかは新しいファイルなので当たる見込み。leave-group の後の main で、衝突しないことを確かめる
  - 直すもの: オンボのページのコメントの「1.14」（3か所）を「1.15.0」に。コメントの「What's New の『そらとも』ページ（`WhatsNewContent.soratomoPages`）と揃えている」を、7.1 の新しいページを指すように。`screenshots/make-soratomo-store-sizes.py` の「1.14 時点」と `page.tsx` の「Slide 7 … 1.14 で公開」も1.15.0に合わせる
  - 説明の文「ホーム右上のボタンから始めよう」は、7.1 の1ページ目と同じ言い方にそろえる（確定は9.1）。オンボのページは1枚で、抜けるには触れない
  - 完了の処理（`completeOnboarding`）は変えない。新しい `currentID` を既読にするので、オンボの後に全員向けの What's New は出ない
  - スクリーンショットの画像はリポジトリに入れるだけで、App Store Connect には触れない（1.15.0 の版にだけ入れるのは13.2）
  - #163 は、PR-B のマージの後に、PR-B へのリンクを書いて閉じる（9.3。squash でマージするので自動では閉じない）
  - _Requirements: 7.4, 7.5, 7.6, 7.7, 7.9_

- [ ] 8. ポリシーの本文・版数・説明を直す

- [ ] 8.1 プライバシーポリシーの本文に、そらともで変わる内容を足す（G5 のアプリ側）
  - 前提: 1
  - 原本は `SettingsView.privacyPolicyText`。足す内容（下書き。確定は9.1）: そらとも（招待したグループのメンバーだけに見える投稿・画像・表示名）・退会でそらともの投稿と参加も消える・通報の記録は通報者や投稿者が退会しても残す・通報の内部IDと理由と時刻を、開発者の通知用の Discord へ送る（キャプション・名前・画像は送らない）・ガイドラインへの同意の版と日時を残す。最終更新日を直す
  - release-gate spec の「後続への引き継ぎ（G5）」（`docs/firestore-schema.md` のそらともの節）の内容が、すべて入っていることを確かめる
  - `python3 scripts/build-privacy-policy-html.py` で、git で追跡している `hosting/privacy/index.html` を作り直し、PR-B に含める（アプリ内とホストの本文をずらさない）。hosting へのデプロイは13.3で行う
  - 利用規約の本文と、設定の「お問い合わせ」は変えない
  - _Requirements: 8.3, 8.4_

- [ ] 8.2 版数を1.15.0にする
  - 前提: 1
  - `project.pbxproj` の `MARKETING_VERSION` を 1.15.0、`CURRENT_PROJECT_VERSION` を 113 にする（アプリとウィジェットの4か所とも。テスト用のターゲットは変えない）。コマンドの上書きで上げず、値をコミットする
  - 113 は仮の値。App Store Connect の最大の build（2026-10-11 の時点で112＝1.14.1・TestFlight だけ）より大きければよい。archive の直前に、ASC の実測で決め直す（12.1）
  - 1.14.1（build 112）は審査に出さない
  - _Requirements: 12.1, 12.2_

- [ ] 8.3 そのほかの説明を直し、残りを検索する
  - 前提: 6.1, 6.2, 7.1
  - `SoratomoEntryButton` の説明（判定の意味＝登録済みでログイン）、`SoratomoError` の `flagOff` の説明（「1.14.x までのサーバーの理由。1.15.0 のサーバーは返さない」）、`SoratomoGroupService` の `flag_off` の写しの説明を直す。計測の列挙の `flagOff` は残す（1.14.x から届くイベントと同じ集計で数えるため）
  - `grep -rn "soratomoIntroID\|claimMissing\|tokenUnavailable\|soratomoBeta" Soramoyou/Soramoyou` が0件（段0-4の検査）。陽性対照: 写しのファイルに1つ入れて、検査が引っかかることを先に確かめる。`Soramoyou/SoramoyouTests` に残る該当は、テストの意図（クレームがあっても結果が変わらない）として残したものだけであることを見る
  - _Requirements: 6.1, 9.4, 9.5_

- [ ] 9. PR-B（アプリ）を点検し、main へ入れる

- [ ] 9.1 新しい文言を確認してもらう（ユーザーの入力が要る）
  - 前提: 7.1, 7.2, 8.1
  - 利用者に読んでもらう文言は3つ。①全員向けの What's New の2ページ ②オンボのそらとものページ ③プライバシーポリシーに足す文と最終更新日。細切れに聞かず、1回にまとめて選択肢つきで聞く
  - 見せる前に、文言が1.15.0 の画面（入口の位置と名前・抜けるの操作の名前）と一致していることを確かめる
  - 1.15.0 のアプリに入る文字列なので、PR-B を main へ入れる前に承認を取り、直しがあれば反映する。承認した日時を記録する（13.5 の G3 で使う）
  - _Requirements: 7.7, 7.10, 8.3_

- [ ] 9.2 アプリのビルドとテストを通し、変えていないものを差分で確かめる
  - 前提: 6.1〜6.3, 7.1, 7.2, 8.1〜8.3, 9.1
  - origin/main を取り込む。ビルドにエラーと新しい警告が無く、そらともと既存のテストが通る（`C2E3F752`・`uptime` と `pgrep -x xcodebuild` で負荷を見てから・`nice -n 19`・`-jobs 4`・1本ずつ）。既存のテストのうち main で既に落ちているものは、変更前の main でも同じく落ちることを確かめて区別する
  - 6〜8 の各テストが、陽性対照で赤になった記録があることを確かめる（記録の無いテストは取り直す）
  - 差分で確かめる: 退会の既存の8手順の対象と順序・既存の3つの通知設定・既存の通知のタップの挙動と計測・ゲストのホーム・計測のイベントの名前とパラメータの値（`flag_off` を含む）・利用規約とお問い合わせが、変わっていない
  - _Requirements: 2.1, 9.4, 13.2, 13.3, 13.4_

- [ ] 9.3 PR-B を main へ入れる（段0-4・ユーザーのGOを取ってから実行）
  - 前提: 1, 9.2。10.4 でプライバシーマニフェストを変えることになった場合は、その変更も PR-B に入れる（マージの前に10.4を済ませるのが望ましい。マージの後なら、12.1 の archive より前に小さな PR で main へ入れる。1.15.0 のまま）
  - push・PR の作成・マージは、それぞれGOを取ってから。PR の本文に、PR #163 を取り込んだことと、マージの後は1.15.0以外の版を main から作らないことを書く
  - 段0-4 の読み返し: 単体テスト緑・ビルドの警告なし・8.3 の検索が0件
  - マージの後: #163 を、PR-B へのリンクを書いて閉じる（GO）。ここから、1.15.0 以外の版を main から作らない。1.15.0 の版は、サーバーを開けた後（11.5の後）にだけ TestFlight へ出す。開ける前に1.15.0の開発版を触るのは、クレームのあるテスト用アカウント（S3）だけにする
  - _Requirements: 2.1, 6.1, 7.6, 12.1, 12.3_

## (f) 切り替えの前の準備（段0-2・0-3・0-5）

- [ ] 10. 切り替えの前に準備する

- [ ] 10.1 クレームの無いテスト用アカウント S5 を作り、基準値を出し直す（段0-2・利用者の操作が要る）
  - 前提: 1（切り替えの当日より前ならいつでもよい）
  - 利用者の操作: App Store の 1.14.0 で新規登録する（クレームは付けない）。操作を頼む前に、いまさわれる端末を聞き、端末に入っている版と build を確かめる
  - 本番の Auth で、S5 の作成の時刻とクレームが無いことを読む（ユーザーのGOを取ってから実行。出すのは uid の頭6文字・時刻・クレームの名前だけ）
  - 差し戻し2（承認済みの読み方）: 基準値・予測・クエリは、gitの管理外の `.claude/handoffs/` でなく、本 spec の `research.md` の「公開前の基準値と、比べるためのクエリ」を正とする
  - S5 の uid を、`research.md` の除外の条件（`<S5のuid>`）に足し、公開前の基準値の表を同じクエリで出し直して、差を記録する（除外の条件を変えたので、比べる前に出し直す）
  - S5 は、1.14.0・クレーム無しの「入口が出ない」の確かめ（11.1・11.6）と、1.15.0 の本番の通し（12.2）に使う
  - _Requirements: 3.4, 3.5, 11.6_

- [ ] 10.2 切り替えの前の使用量と、本番の設定を読む（段0-3・要確認3・7。利用者の操作が要る）
  - 前提: なし（切り替えの当日の7日前から）
  - 利用者の操作: Firebase のコンソールで、切り替えの前の7日分（日ごと）の Firestore の読み取り・書き込み・削除、Storage の保存量と転送量、Functions の呼び出し回数を読み、表にしてこのタスクの結果に書く。公開後の見回りの目安（7日の最大の2倍）の土台にする
  - 要確認3: 本番の Auth で有効なログイン方式。release-gate tasks.md 14.5（2026-10-09）では、匿名ログインは無効で、有効なのはメールとパスワードだけだった。変わっていないかを、開発者がコンソールで読む（読むだけ）。AIが REST で読む場合は、GOを取り、`signIn` の中の方式ごとの有効かどうかの項目だけに絞って出す（`signIn` を丸ごと出さない）。どの結果でも設計は変えない。匿名が有効なら、見回りで `registration_required` を見る意味が増える
  - 要確認7: GCP の予算のアラートがあるかを、開発者がコンソールで読む。無ければ、見回りの補助に足すかを開発者に聞く（費用がかかる。任意）
  - _Requirements: 5.2, 5.4_

- [ ] 10.3 見回りの手順と、「効果あり」の基準を、公開の前に記録する
  - 前提: 10.2
  - 見回りの手順（見る場所・見るもの・乱用を疑う目安の初期値）は、design.md の「公開後14日の見回り」の表のとおりとする。このタスクの結果に、公開の前に決めた日時を書く。目安は7日目に見直す
  - 「効果あり」の基準は、利用者の判断2の C（2026-10-11 決定）。主: 公開から2週の時点で「そらともを開いた人」が30人以上、かつ「グループを作成または参加した人」が10人以上。従: 公開から4週の「直近7日の利用者」が、予測の「中（新規110/週）×毎週1割減」の312を上回る。届かなかったときの読み方も design.md の表のとおり。数字はどれも除外の条件をかけた値で、1.15.0 の普及率を添えて読む
  - 測る前に決める（`docs/roadmap.md` の段階Bの判定ゲートと同じ）。変えるなら、公開の前にこのタスクに書き直す
  - _Requirements: 5.4, 11.5_

- [ ] 10.4 G5 の文案を用意し、開発者の承認を取る（段0-5・ユーザーの入力が要る）
  - 前提: 1（PR-B のマージより前に済ませるのが望ましい。プライバシーマニフェストを変える場合に PR-B へ入れられる）
  - プライバシーラベル: `docs/app-privacy-label.md`（ASC の入力表）と `PrivacyInfo.xcprivacy` を読み、増える項目があるかを確かめた案を作る（写真・その他のユーザーコンテンツ・ユーザーID・名前は申告済み。通報の理由と同意の記録が「その他のユーザーコンテンツ」に入るか）。変えるなら、表とマニフェストを同時に直す。マニフェストの XML のコメントに連続のハイフンを入れない（ITMS-91056 の前例）
  - 年齢区分: ユーザー生成コンテンツと、利用者どうしのやりとり（非公開のグループ）の答えを、そらともを含めて見直した案を作る
  - 審査メモ: 下の文案を、これまでの審査メモと同じ言語の形で用意する（英語を併記していれば、そろえる）。招待コードは文案に書かず、13.3 で ASC にだけ入れる。「グループを抜ける」の言葉は、タスク1で確かめた leave-group の画面の名前にする
  - 審査メモの文案:
    - 1. 新機能「そらとも」: 招待コードで参加する、最大20人の非公開グループで、空の写真を見せ合う機能です。ホーム右上のボタン（人が2人のアイコン）から開きます。
    - 2. 確かめ方（デモのアカウントで）: デモのアカウントでログインし、ホーム右上のボタンを押します。ガイドラインの全文が出たら「同意する」を押します。「招待コードで参加」に、次のコードを入れます（ASC にだけ書くコード）。表示名を求められたら入力します。タイムラインで写真を1枚投稿します。ほかのメンバーの投稿の「…」（または長押し）から「通報」と「ブロック」を試せます。タイムラインの右上のメニューの「グループを抜ける」で、グループを抜けられます。グループの一覧の「グループを作る」で、新しいグループを作れます。
    - 3. 退会の削除: デモのアカウントを削除すると次の審査で使えなくなるため、新しく登録したアカウントで「設定 → アカウントの削除」を試してください（登録で確認メールは送らないので、すぐに試せます）。そらともの投稿とグループへの参加も削除されます。
    - 4. モデレーション（ガイドライン1.2）: 不適切な言葉を含むグループ名とキャプションは受け付けません。通報は24時間以内に確認します。ブロックした人の投稿は表示されません。違反した利用者は、そらともの利用を停止します。連絡先は、設定の「お問い合わせ」とサポートURLです。
  - 差し戻し4（承認済みの読み方）: 退会の削除の確かめ方は「新しく登録したアカウントで」と書く（デモのアカウントを消さない）
  - デモのアカウント（既存・uid `FvPXCf…`）は、表示名が無ければ参加の前に入力を求められ、ガイドラインに未同意なら全文が出る。文案の2の手順に入れてある
  - ラベル・年齢区分・審査メモの案を利用者に見せ、1回で承認を取る。承認の日時を記録する（13.5 の G5 で使う）。ASC への入力は13.3で開発者が行う
  - _Requirements: 8.3, 8.4, 8.5, 8.7_

## (g) 切り替えの当日（段1-1〜1-5）

- [ ] 11. サーバーを開ける（すべてユーザーのGOを取ってから）

- [ ] 11.1 開ける前の見え方を確かめる（組み合わせの「前」の列・利用者の操作が要る）
  - 前提: 5, 9.3, 10.1
  - 端末の割り当て（どの端末にどの版とアカウントを入れるか）を開発者に聞く。いまさわれる端末を先に確かめ、端末に入っている版と build を確かめる
  - 1.14.x・クレーム無し（App Store の 1.14.0・S5）: ホームの右上にそらともの入口が出ない
  - 1.14.x・クレームあり（1.14.x・S3）: タイムラインの表示と投稿ができる。ログ `soratomoCreateSky: ok`（uid S3。ログの読み取りはGOを取ってから）
  - Android 版: `~/dev/soramoyou-android` で `soratomo` を grep して、Kotlin のコードに0件（読むだけ。リポジトリの外で、書き込まない）。Android 版の作業と公開を待たずに1.15.0を出す。サーバーの規則がどのクライアントにも同じに効くことは、自動テスト（2・3）が受け持つ
  - _Requirements: 1.9, 3.4, 4.1, 4.3_

- [ ] 11.2 PR-A を main へ入れ、出し元を確かめる（段1-1）
  - 前提: 11.1
  - PR-A のマージ（ユーザーのGOを取ってから実行）。`git fetch` の後、`git log` で main の先頭に leave-group・PR-B・PR-A が入っていることを見る。作業ツリーが clean で `HEAD == origin/main` のところから出す。出し元のコミットを記録する
  - `grep -rn "requireFlag\|soratomoBeta" functions/*.js firestore.rules storage.rules` が、テストのファイル以外で0件
  - マージの後の main（PR-B が先に入った、実際に出す状態）で、`npm test`・`npm run test:emulator`・ルールのテスト2本（通常）をもう一度流して、すべて通ってから11.3へ進む（release-gate 14.1 と同じ）
  - 出す前の本番のルール2本を、読み返しの道具（2.5）で読み、PR-A の前の main（leave-group の反映の後）と一致することを記録する（出す前の状態。GOを取ってから）
  - 11.3〜11.5 のどれかのデプロイが失敗したら、1.15.0 を配らずに止める。直して出し直すか、出した分を Firebase のコンソールで前の ruleset へ戻す。戻してよいのは、1.15.0 をクレームの無いアカウントへ配る前だけ
  - _Requirements: 3.2, 3.3_

- [ ] 11.3 Firestore のルールを出し、読み返してテストを流す（段1-2・ユーザーのGOを取ってから実行）
  - 前提: 11.2
  - `firebase deploy --only firestore:rules --project soramoyou-ios --non-interactive`
  - 読み返しの道具で、ruleset の識別子・更新の時刻・ハッシュの頭が手元の `firestore.rules` と一致する。保存した本番の本文に `rules_test_soratomo.py`（通常）を流して全件緑（release-gate tasks.md 17 と同じ）
  - この日から見回り（15.1）を始める（開けた日から）
  - _Requirements: 3.3, 10.6_

- [ ] 11.4 Storage のルールを出し、読み返してテストを流す（段1-3・ユーザーのGOを取ってから実行）
  - 前提: 11.3
  - `firebase deploy --only storage --project soramoyou-ios --non-interactive`
  - 読み返しの道具で、同じく手元の `storage.rules` と一致する。保存した本番の本文に `rules_test_storage_soratomo.py`（通常）を流して全件緑
  - _Requirements: 3.3, 10.6_

- [ ] 11.5 そらともの関数を名前で指定して出す（段1-4・要確認8・差し戻し1。ユーザーのGOを取ってから実行）
  - 前提: 11.4
  - 要確認8: 出す前に、公開する関数を数えて期待値にする。2026-10-11 の数え方は、`functions/index.js` の `exports.名前 =` が9本、`functions/skyMotion.js` の `exports.名前 =` が2本、`functions/soratomo.js` の `module.exports` が leave-group の後で11本の、計22本。本番の `firebase functions:list --project soramoyou-ios` の名前と数がこれと一致すること
  - 出す前に、本番の Functions を最後に出したとき（leave-group の反映）から、main の `functions/` の差が PR-A の分だけであることを `git log` で確かめる
  - コマンド: `firebase deploy --only functions:soratomoCreateGroup,functions:soratomoJoinGroup,functions:soratomoRegenerateInviteCode,functions:soratomoCreateSky,functions:soratomoReportSky,functions:soratomoAgreeGuideline,functions:soratomoDeleteMyData,functions:soratomoLeaveGroup,functions:onSoratomoSkyCreated,functions:onSoratomoReportCreated,functions:soratomoHousekeeping --project soramoyou-ios --non-interactive`。名前は `functions/soratomo.js` の `module.exports` の11本から作り、手で打たない（上の一覧と一致することを確かめる。leave-group の反映と同じやり方）。本番にあってソースに無い関数の削除は行わない
  - デプロイの出力で、11本の更新がすべて成功。出した後の `functions:list` の名前と数（22本）・リージョン（asia-northeast1）・ランタイム（nodejs22）が、出す前と同じ
  - 差し戻し1（承認済みの読み方）: Functions は本番のコードを読み返す手段が無いので、「出し元のコミットが origin/main の先頭・デプロイの出力で全部の更新が成功・関数の一覧が `index.js` の公開と一致・新しい挙動がログに出る（クレームの無い uid の `ok` と、通知の集計の `flagOff` が0。12.2 で見る）」を、「一致を読み返して確かめた」とみなす
  - _Requirements: 3.3_

- [ ] 11.6 開けた後の1.14.xの見え方を確かめる（段1-5・組み合わせの「途中」の列・利用者の操作が要る）
  - 前提: 11.5
  - 1.14.x・クレームあり（S3）が投稿する。ログ `soratomoCreateSky: ok`（uid S3）
  - 1.14.x・クレーム無し（App Store の 1.14.0・S5）: 開けた後も入口が出ない（1.14.x はクレームの無い人に入口を出さない）
  - _Requirements: 1.9, 3.4_

## (h) 1.15.0 の TestFlight と本番の通し（段2-1〜2-3）

- [ ] 12. 1.15.0 を TestFlight で確かめる

- [ ] 12.1 build 番号を決めて archive し、内部の TestFlight へ出す（段2-1・ユーザーのGOを取ってから実行）
  - 前提: 11.5（クレームの無いアカウントが1.15.0を手にする前に、3か所を開け終えて確かめる）
  - App Store Connect の最大の build を実測で読む（GO）。113以上でまだ使っていない番号に決め、main の pbxproj の値（8.2）と違えば、小さな PR で main の値を直してから出す（コマンドの上書きで上げない）
  - git の管理外の `ExportOptions.plist` が worktree に無ければ、本体の checkout から写す
  - `uptime` と `pgrep -x xcodebuild` で負荷を見てから、`~/.claude/scripts/xcode-testflight-upload.sh` と同じフラグに `nice -n 19` と `-jobs 4` を付けて archive と export を行う。`ENABLE_USER_SCRIPT_SANDBOXING=YES` のまま。背景で回すなら `nohup … & disown`。IPA の Info.plist の版と build が 1.15.0 / N であることを見る
  - アップロードは別にGOを取る。成否はアップロードのログでなく、ASC で build が `VALID` になったことを読んで判定する。内部の TestFlight（開発者とテスト用アカウント）へ配る
  - 1.14.1（build 112）は審査に出さない
  - _Requirements: 3.1, 12.1, 12.2_

- [ ] 12.2 組み合わせの確認と本番の通しを行う（段2-2・差し戻し3・利用者の操作が要る）
  - 前提: 12.1
  - 端末の割り当てを開発者に聞く。試す前に、端末に入っている版と build（TestFlight の 1.15.0 / N）を確かめる。ログと本番の読み取りはGOを取ってから
  - 組み合わせ: 1.15.0・クレーム無し（S5。1.14.0 の上に入れる）→ 使える（下の通し）。1.15.0・クレームあり（S3）→ タイムラインの表示と投稿ができる。どちらにも、先行公開の紹介（「先行公開」のバッジ）が出ない
  - 差し戻し3（承認済みの読み方）: 表の「後」の列（1.15.0 を公開した後）は、サーバーの状態が「途中」と同じで版も同じなので、この確かめで確かめたものとする。「1.14.x・クレーム無しは、更新すれば使える」は、S5 を 1.14.0 から 1.15.0 へ上げて使えることで見る
  - 本番の通し（S5・相手は S3。上から順に）:
    - 1. 1.14.0 で使っていた端末に1.15.0を入れて開くと、全員向けの What's New がそらともと抜けるの2ページで1回出る。閉じて開き直すと出ない
    - 2. 作成: S5 がグループを作る（ガイドラインの全文 → 同意 → 表示名 → 作成）。ログ `soratomoAgreeGuideline: ok`・`soratomoCreateGroup: ok`（uid S5）。招待の共有を1回行う
    - 3. 参加: S3 のグループに、S5 が招待コードで参加する。ログ `soratomoJoinGroup: ok`
    - 4. 投稿と通知: S5 が1枚投稿する（`soratomoCreateSky: ok`）。S3 が同じグループに投稿し、S5 の端末に通知が届く。集計のログ `onSoratomoSkyCreated: summary` で `sent` が1以上・`flagOff` が0（クレームの無い宛先へ届く）。S5 が通知をタップすると、そのグループのタイムラインが開く
    - 5. 通報: S5 が S3 の投稿を通報する（`soratomoReportSky: ok`・Discord の通報のチャンネルへの転送）。`scripts/soratomo-admin.js review-report <ID> --result no_violation` で閉じる（GO）
    - 6. ブロック: S5 が S3 をブロックし、S3 の投稿が S5 のタイムラインから消える
    - 7. 抜ける: S5 が S3 のグループを、タイムラインの右上のメニューから抜ける（ログ `soratomoLeaveGroup: ok`・uid S5）。その前に、確定のときに機内モードにして1回失敗させる（12.3 の `soratomo_leave_failed` のため）
    - 8. オンボ（新規の利用者）: 共用でないシミュレーター `DCFBF2D6` に1.15.0の開発版を新しく入れ、オンボにそらとものページが1枚出て、その後に What's New が出ないことを見る
  - 2〜7 で、案内で宣伝する操作（作成・招待コードでの参加・投稿・グループを抜ける）を、1.15.0 のビルドの実データで1回ずつ通したことになる（`docs/pre-release-checklist.md` の§4）。通報・ブロックを含めて、クレームの無い登録済みのアカウントで、本番で1回ずつ通したことになる
  - 結果は13.5 の G3（1と8）に使う
  - _Requirements: 1.3, 1.9, 2.1, 2.6, 3.4, 3.5, 6.1, 7.1, 7.4, 7.5, 7.8_

- [ ] 12.3 G4: 計測の着弾を、除外の条件あり・なしで数える（段2-3・要確認6）
  - 前提: 12.2
  - 通しの時間帯で、`soratomo_opened`・`soratomo_group_created`・`soratomo_group_joined`・`soratomo_post_created`・`soratomo_invite_shared`・`soratomo_report_submitted`・`soratomo_user_blocked`・`soratomo_guideline_result` の件数を、除外の条件をかけない場合とかける場合で出す（クエリの型は `research.md` の G4）。期待: 除外なしで各イベントが1件以上・除外ありで0件（TestFlight の版は除外の条件2で、S5 は条件4でも除かれる）
  - leave-group の要件12の5（同じ時点・同じ除外の条件）: 抜けるのイベント `soratomo_group_left`（`role`・`group_deleted`・`completed`）と `soratomo_leave_failed`（`reason`）、`soratomo_join_failed` の `reason` の `leave_pending` も、同じクエリに足して数える（イベントの名前は leave-group の design.md の SoratomoAnalytics のとおり）
  - `leave_pending` は、片づけが途中で止まった人の参加でしか起きない。投稿の少ないグループの片づけは1回の呼び出しで終わり、アプリを止めてもサーバーは続けるので、通しでは起こしにくい。起こせなければ「本番では起こせなかった」と記録し、`soratomo_join_failed` 自体の着弾（例: 架空の招待コードでの参加の失敗を1回）と leave-group の単体テストを根拠に挙げる。その場合は「検証済み」と書かず、完了にするかを利用者に聞く
  - 要確認6: 1.15.0 の TestFlight のイベントを1件読み、`$app_version` の値の形（例 `1.15.0`）を確かめる。普及率のクエリ（15.3）の条件に使う
  - 結果は13.5 の G4 に使う
  - _Requirements: 9.1, 9.2_

## (i) App Store Connect の準備と公開判断の記録（段3-1〜3-5）

- [ ] 13. App Store Connect を準備し、公開判断を記録する

- [ ] 13.1 版を作り、リリースノートを入れる（段3-1・ユーザーのGOを取ってから実行）
  - 前提: 12.2
  - リリースノート（ASC の「このバージョンの最新情報」）の草案を利用者に聞き、チャットで清書する。`fastlane/metadata/ja/release_notes.txt` に入れ、コードポイントで検査して、絵文字・異体字セレクタ（U+FE0F を含む）・私用領域の文字・`PLACEHOLDER` が無いことを確かめる
  - 提出の前の ASC を読む（GO）: 公開中は 1.14.0（READY_FOR_SALE）、1.15.0 の版は無く、審査中・編集中の版も無い。build N は VALID で期限切れでない
  - `scripts/appstore-release.sh prepare --version 1.15.0 --build <N>`（GO）。`prepare` は成功と出てもビルドを紐付けないことがあるので、`scripts/asc_ensure_build.py --version 1.15.0 --build <N>` で読み返して紐付けを保証する。リリースノートを API で読み返し、手元のファイルとバイトで一致することを確かめる
  - _Requirements: 12.1, 12.5_

- [ ] 13.2 スクリーンショットを1.15.0の版にだけ入れる（段3-2・利用者の操作）
  - 前提: 13.1
  - 開発者が、PR #163 の6.5インチ用（`screenshots/appstore-2026-10-07/6.5/02-soratomo-1284x2778.png`）と iPad 用（`screenshots/appstore-2026-10-07/ipad/02-soratomo-2048x2732.png`）を、既存の8枚の2枚目として1.15.0 の版に入れる（アルファの無い PNG・同じ入れ物に大きさを混ぜない）
  - ASC の1.15.0 の版のスクリーンショットの並びと、公開中の1.14.0 が変わっていないことを見る（読み取りはGOを取ってから）
  - _Requirements: 7.9_

- [ ] 13.3 G5 を反映し、審査用のグループを用意する（段3-3・要確認5・差し戻し4。利用者の操作が要る）
  - 前提: 9.3, 10.4, 13.1
  - ポリシー: `python3 scripts/build-privacy-policy-html.py` の出力が main の `hosting/privacy/index.html` と同じであることを確かめてから、`firebase deploy --only hosting --project soramoyou-ios`（GO）。https://soramoyou-ios.web.app/privacy/ を開いて、新しい本文と最終更新日が出ることを見る
  - 開発者の手作業（ASC）: プライバシーラベル・年齢区分・審査メモを、10.4 で承認した案で入れる。審査メモの招待コードは、下の審査用のグループのものを ASC にだけ書く。差し戻し4のとおり、退会の削除は「新しく登録したアカウントで」と書いてあることを見る。AIは、ASC の画面で何を見ればよいかを示す
  - 要確認5: プライバシーラベルと年齢区分が、版ごとか App 全体かを、ASC の画面で見る。App 全体なら、1.15.0 の公開の少し前に申告が先に出ることを受け入れる（多めの申告は、少なめの申告より安全）
  - 審査用のグループ: S3 がオーナーのグループを1つ作り、空の写真を2〜3枚投稿しておく。デモのアカウントはメンバーにしない（審査の人が参加から試せるように）。審査の間は招待コードを再発行しない。審査の人が抜けても S3 が残る
  - `docs/app-privacy-label.md` に、G5 の結果（変えた項目があれば）と最終確認の日付を書く（小さな PR で main へ）
  - _Requirements: 8.3, 8.4, 8.5, 8.6, 8.7_

- [ ] 13.4 サポートURLを現物で確かめる（段3-4・release-gate tasks.md 19）
  - 前提: 13.1
  - 登録された App Store のサポートURLを ASC から読み（GO）、実際に開いて、連絡先が載っていることを確かめ、確かめた日時を記録する
  - release-gate の `tasks.md` の19の「結果」に、同じ日時と、開いて見た連絡先を書く（release-gate 要件12の2）
  - _Requirements: 8.2_

- [ ] 13.5 公開判断の記録（G1〜G5）を残す（段3-5・利用者の判断）
  - 前提: 9.1, 10.4, 12.2, 12.3, 13.3, 13.4
  - soratomo spec の要件17の2の記録として、このタスクの結果と、release-gate の `tasks.md` の19の「結果」に次を書く
    - G1・G2: release-gate spec で完了（16.1〜16.4・17・18の結果の要約と、ガイドラインの本文の承認の日時と版＝release-gate 12.1 の 2026-10-09 08:17・v1）
    - G3: 1.15.0 の What's New とオンボの文言の承認の日時（9.1）と、12.2 の1と8の結果
    - G4: 12.3 の結果（公開から7日の分は、15.2 で追記する）
    - G5: 13.3 の結果（ポリシーの URL と最終更新日・ラベル・年齢区分・審査メモの入力の日時）と、10.4 の承認の日時
    - サポートURL: 13.4 の日時と、開いて見た連絡先
  - release-gate の19を [x] にしてよいかは、利用者に聞く
  - _Requirements: 8.1_

## (j) 審査への提出と公開（段4-1〜5-3）

- [ ] 14. 審査に出し、公開を迎える

- [ ] 14.1 1.15.0 を審査へ提出する（段4-1・ユーザーのGOを取ってから実行）
  - 前提: 1（leave-group の受け入れの確認が済んでいる）, 13.1〜13.5
  - 審査に出す build は、12.1 で配って12.2 で確かめたもの。違う場合は差分を示して、利用者に確認する。1.14.1（build 112）は出さない
  - 提出の直前に、3か所が開いたままであることをもう一度確かめる（読み返しの道具で本番のルール2本が main と一致・`functions:list` の22本）。審査の人が1.15.0を手にする間、サーバーは要件1の状態にある
  - `scripts/appstore-release.sh submit --version 1.15.0 --build <N> --yes`（GO。審査提出のGOの最終判断は自動化しない）
  - 読み返し: `scripts/asc_ensure_build.py --version 1.15.0 --build <N> --check-only` で、`WAITING_FOR_REVIEW`・build・リリースノートの一致を見る
  - 提出の道具は「承認されたら自動で公開」のまま（利用者の判断1の B）
  - _Requirements: 3.1, 12.2, 12.4_

- [ ] 14.2 公開を知った日のうちに見回りを始める（段5-1）
  - 前提: 14.1
  - 承認と同時に自動で公開される。公開の知らせ（ASC のメール・`asc_ensure_build.py --check-only` の `READY_FOR_SALE`）を受けた日のうちに、見回り（15.1）の公開後の分を始め、通報には24時間以内に対応する（release-gate 要件8の1）
  - `READY_FOR_SALE` と公開の日時を記録する（15.3 の比較に添える）
  - 公開の後は、そらともを全員に対して閉じ直さない（ルールと Functions を戻さない）。止める手段は、利用者ごとの利用停止（`soratomo-admin.js suspend`）と、次の版での修正だけ（決定事項2）
  - _Requirements: 3.6, 11.4, 12.6_

- [ ] 14.3 審査の後片づけと、クレームの扱い（段5-2・5-3）
  - 前提: 14.2
  - 審査用のグループの招待コードを、S3 が再発行する（審査の人へ渡したコードを使えなくする）。再発行の時刻を記録する。審査の人の投稿・通報が残っていれば見る
  - 公開の後は、新しくクレームを付けない。すでに付けたクレームは取り消さない（1.14.x のままのクレームのある人が、1.15.0 に更新するまで使い続けられるように）。後で取り消す場合は、付与のスクリプトの `--revoke`（既存のクレームと合成して書く仕組み）を使い、`skyMotionBeta` を消さない
  - _Requirements: 6.2, 6.3, 6.5_

## (k) 公開後の見回りと比較（段6-1〜6-3）

- [ ] 15. 公開後14日の見回りと、公開の前後の比較

- [ ] 15.1 毎日1回、見回る（段6-1・要確認9）
  - 前提: 10.3, 11.3（開けた日から、公開の後14日まで毎日1回）
  - 10.3 で記録した手順のとおり、Functions のログ（前日の `soratomoCreateGroup: ok`・`soratomoJoinGroup: ok`・`soratomoCreateSky: ok`・`soratomoReportSky: ok` の件数と uid ごとの件数・`rejected` の理由ごとの件数）、Firebase のコンソールの使用量、PostHog のそらとものイベントの日ごとの件数（除外の条件をかける）、Discord の通報のチャンネルを見て、このタスクの結果に1日1行で書く。ログと記録に出すのは uid の頭6文字と件数だけ。本番のログの読み取りはGOを取ってから
  - 乱用を疑う目安（初期値）: 1人が24時間にグループを3件以上作る／1人が1つのグループに24時間で21件以上投稿する（アプリの上限を超える＝改造したアプリ）／1人の参加の `not_found` が1時間に10件以上（招待コードの総当たり）／`registration_required` が出る（アプリ以外からの要求）／使用量が10.2 の7日の最大の2倍を超えた日／PostHog の件数がログの件数と大きく食い違う。7日目に目安を見直す
  - 乱用を疑ったら、`scripts/soratomo-admin.js` で調べ、`suspend <uid>` で、その利用者のそらともの利用を止める（GO。release-gate 要件8）
  - 通報は24時間以内に `show-report` → `review-report`（GO）
  - 要確認9: 初日に、Functions のログを uid ごとに数える方法（`gcloud logging read` の権限、または `functions_get_logs` の1回1000件の上限）を1回試す。足りなければ時間帯を分けて読む
  - _Requirements: 5.2, 5.3_

- [ ] 15.2 公開から7日で、G4 の残りを確かめる（段6-2）
  - 前提: 12.3, 14.2（公開から7日）
  - 12.3 と同じイベント（抜けるのイベントを含む）を、公開の日時から7日の範囲で、除外の条件をかけて出し、0件でないことを確かめる。0件のイベントがあれば、そのイベントを出す画面がまだ使われていないのか、届いていないのかを分けて記録する
  - 13.5 の G4 と、release-gate の `tasks.md` の19の記録に追記する
  - _Requirements: 9.3_

- [ ] 15.3 公開から1週・2週・4週で比べる（段6-3・差し戻し2）
  - 前提: 10.1, 10.3, 14.2
  - 差し戻し2（承認済みの読み方）: 定義・除外の条件・区切り（日本時間・月曜始まりの週）・クエリの型・基準値・予測は、`research.md` の「公開前の基準値と、比べるためのクエリ」を正とする（10.1 で S5 を足して出し直した値）
  - 各時点で、次を1つの表に並べる: 直近7日の利用者・日ごとの利用者・週ごとの利用者・新規登録（Firestore の `users`。読み取りはGOを取ってから）・投稿した人÷週ごとの利用者・1週後の継続率、そらともを開いた人の数とグループを作成または参加した人の数（除外の条件をかける）、公開の日時と、直近7日の利用者のうち1.15.0で開いた人の割合（要確認6の値の形を使う）、予測の幅
  - 10.3 の基準（利用者の判断2の C）に照らして読む。結果は言い切らず、新規の流入の波と App Store での露出の変化が混ざることを添える。除外の条件を変えたら（issue #173 の修正で、テストのイベントの形が変わる場合を含む）、公開前の基準値を新しい条件で出し直してから比べる
  - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.6, 11.7_
