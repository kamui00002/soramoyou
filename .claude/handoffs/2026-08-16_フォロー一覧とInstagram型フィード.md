# 引き継ぎ: フォロー一覧 ＋ Instagram 型「あなた向け」フィード

作成: 2026-08-16 / 前セッションのコンテキスト上限により中断

---

## このセッションで何をしたか

### 1. 完了済み（フォローアップ2件）

| 件 | 状態 |
|---|---|
| PrivacyInfo の理由コード `1C8F.1` → `CA92.1` 是正 | **PR #82 作成済み（未マージ）**。ブランチ `修正-プライバシーマニフェスト理由コードCA92`・commit `a16ad97`。`xmllint --noout` / `plutil -lint` 検証済み。次のリリース便（build 95+）に同乗させる |
| PostHog 本番着弾の軽い実査 | 完了。build 94 の着弾は **Apple 審査端末のみ**。オーガニックはゼロだが、Apple の承認メールが「公開後 最大24時間かかる」と明記しており承認から7時間しか経っていなかった＝**想定内**。⚠️ 公開中の旧版 1.9.5 は PostHog 非搭載なので「PostHog ゼロ＝ユーザーゼロ」ではない。**本実査は 8/18〜19** |

ASC 実査で 1.9.6 = `READY_FOR_SALE` / `downloadable: true` を確認済み。**次の単発提出は build 95+**。
承認は **8/16 03:30 JST**（Apple メールは PDT 基準なので JST 台帳に写すと1日ズレる。Submission ID `bee97bc0-c1a5-4291-93cc-18f00a156e64`）。

### 2. 本題 — フォロー機能の計画策定と Wave 1 実行

**計画は承認済み**。全文: `/Users/yoshidometoru/.claude/plans/ultrathink-1-1-instagram-instagram-swift-sparrow.md`
Artifact: https://claude.ai/code/artifact/80147239-a702-4b39-8ae2-9827c624164f

⚠️ **次のセッションは、まずこの計画ファイルを読むこと。** 以下は要約に過ぎない。

---

## 最重要の前提（ここを読み飛ばすと事故る）

### フォロー機能は**既に本番稼働している**
`docs/roadmap.md:12` の「Phase 2 実装予定」は**古い**。`Models/Follow.swift` / `Services/FollowRepository.swift` / `Views/UserProfileView.swift` のフォローボタン / `firestore.rules:181-197` / `functions/index.js:157` のフォロワー向け新着通知が全て動いている。
**今回作るのは「フォロー機能」ではなく、既にあるフォロー関係を可視化・活用する層。**

### 同時に見つかった既存の欠陥（計画に組み込み済み）
- **A**: 他人から見たフォロワー数が永久に 0（書き込み先 `users` と表示元 `publicProfiles` が違い、rules で書けない）
- **B**: `visibility: followers` の投稿がどの一覧にも出てこない（全クエリが public 固定）
- **C**: 他人の投稿詳細で著者名・アイコンが無言で消える（読めない `users` を読んでいる）
- **D**: 他人プロフィールの投稿グリッドが常に空（`fetchUserPosts` に visibility 条件が無く rules が証明できず denied → 握りつぶし）
- **E**: 誰でも他人のフォローカウンタを ±1 できる（rules が `follows` の存在を検証していない）

---

## 確定仕様（ユーザーと合意済み・変更不可）

承認制なし（即フォロー2状態）／ フォロー通知は入れる（**既存 `notifyReactions` に相乗り**・新プレフを作らない）／ 安全弁はフォロワー削除まで ／ フィードは1本に混ぜる ／ 並びは**新しい順（時系列）** ／ タグは明示フォロー＋**自分の投稿タグ頻度上位**で補完 ／ タグ詳細画面を新設 ／ **ホームにセグメント追加・既定は「すべて」**・タブは増やさない ／ followers 投稿は既存分もそのまま見えるように ／ 段階的に複数 PR ／ **検証が失敗したらその場でユーザーに相談**

---

## いま走っているもの（要確認）

**Workflow（ultracode / Opus 5）が Wave 1 をバックグラウンド実行中だった。**

- Task ID: `w23ifdean` / Run ID: `wf_138baa1e-4e5`
- Script: `/Users/yoshidometoru/.claude/projects/-Users-yoshidometoru----iOS---------/c829c843-e92d-4569-805b-2e145f5eefff/workflows/scripts/soramoyou-follow-wave1-wf_138baa1e-4e5.js`
- Transcript: `/Users/yoshidometoru/.claude/projects/-Users-yoshidometoru----iOS---------/c829c843-e92d-4569-805b-2e145f5eefff/subagents/workflows/wf_138baa1e-4e5`
- 内容: **PR-1（著者バグ）＋ PR-2（Functions カウンタ）を並列 → その後 PR-6（タグ詳細）**
- 想定ブランチ名: `修正-投稿詳細の著者表示` / `修正-フォローカウンタをFunctionsで根治` / `機能-タグ詳細画面とタグフォロー`

### ⚠️ 再開時に最初にやること
1. **`git branch` で上記3ブランチができているか確認**（セッション終了で workflow が途中で切れた可能性がある）
2. できていなければ `journal.jsonl` を読んで、どこまで進んだか確認してから `Workflow({scriptPath, resumeFromRunId: "wf_138baa1e-4e5"})` で再開
3. `worktree-wf_138baa1e-4e5-1` / `-2` というブランチが残っていたら、それは worktree の残骸。`git worktree list` で確認して不要なら片付ける

### なぜ3本同時ではなく 2+1 にしたか
PR-1 と PR-6 が両方 Xcode ビルドを走らせるため。**2本同時に回すと失敗が「本物のコンパイルエラー」か「DerivedData の競合」か区別できなくなる**。PR-2 は Swift を触らないので並列で問題ない。

---

## 残タスク

```
[進行中] Wave 1 ─ PR-1（著者バグ）/ PR-2（Functions+index）/ PR-6（タグ詳細）
[未着手] Wave 2 ─ PR-3（クライアント increment 除去・PR-2 必須）/ PR-4（可視性修正＝プローブ）
[未着手] ★人間ゲート ─ PR-4 のプローブを実 Firestore で実行 → A2 の可否と上限 N を確定
[未着手] Wave 3 ─ PR-5（フォロワー/フォロー中一覧＋フォロワー削除）
[未着手] Wave 4 ─ PR-7（ミックスフィード＋ホームセグメント）
[未着手] Wave 5 ─ PR-8（rules クローズ・PR-3 の採用率が上がってから。数週間後）
```

### メインセッションが担当（委譲しない）
- `/review-full` の実行と judge 結果の取捨
- **PR-4 のプローブ実行と結果判断**（実 Firestore が要り、結果次第で設計が変わる）
- **Firebase デプロイ**（`firestore:indexes` / `firestore:rules` / `functions`）— ⚠️**必ず GO 確認を取ってから**。エージェントには絶対にやらせない
- PR-8 の実施判断（旧バージョン採用率の確認が前提）

---

## 技術的な地雷（繰り返し踏みやすいもの）

- **rules はフィルタではなく静的証明**。一覧クエリは「結果集合が安全」と証明できないと全件拒否される。`userId in [...]` だけで絞ると private が入りうるので denied
- ⚠️ **未フォロー相手に `visibility in ['public','followers']` を投げてはいけない**。`followers` 枝が rules を満たせずクエリ全体が denied になり、**公開投稿まで巻き添えで消える**。フォロー状態で分岐すること
- `in` / `array-contains-any` は **30**、クエリ全体は **30 disjunctions**、rules の `exists()`/`get()` は **1リクエスト10回まで**（Firebase 公式で確認済み）
- **R1（最大の未知）**: `exists()` が list クエリの rules で機能するか**公式ドキュメントが明記していない**。PR-4 がこれを確かめる最小プローブ。失敗したら A2 ストリーム断念 → ユーザーに相談
- `LoggingService.sanitizeParameters`（:271-289）は**キー名に `auth` を部分一致で含むと値を丸ごと `[REDACTED]`**。`author_id` は使えない
- `MergedFeedPaginator` は **0件ページを絶対に返してはいけない**。`HomeView.swift:190-193` のページング発火が `.onAppear` なのでフィードが恒久停止する
- **ページ境界のマージバグは通常操作では絶対に発現しない**。`pageSize=3` の作為的シナリオで検証すること
- タグの正規化（小文字化・トリム）は**絶対にしない**。`array-contains` は完全一致で、既存データにマッチしなくなる
- Xcode 16+ の同期グループはディスク上の全ファイルを取り込むので、ソースツリー内の worktree が `Multiple commands produce` を起こす → **PR #83 で `.gitignore` 対処済み**

---

## git の状態（2026-08-16 時点・記録のみ。コミットしないこと）

- 作業ブランチ: `改善-worktree除外でビルド事故を防ぐ`（commit `227ae67`・push 済み・PR #83）
- main: `9c1333e`
- **未コミット変更（並行セッションのものが混ざっている可能性があるため、勝手にコミット・破棄しない）**:
  - modified: `.serena/project.yml`
  - untracked: `.claude/claude-security-guidance.md` / `.claude/handoffs/` / `.claude/security-patterns.json` / `.firebase/` / `.playwright-mcp/` / `.swiftlint.yml` / `Soramoyou/.claude/` / `Soramoyou/marketing/` / `docs/rendering-refactor-plan.md` / `docs/widget-handoff.md` / `reports/` / `screenshots/__pycache__/` / `screenshots/calendar-diary-verify/`

### オープン PR
- **#82** PrivacyInfo 理由コード CA92.1 是正（レビュー・マージ待ち）
- **#83** worktree を `.gitignore` に追加（レビュー・マージ待ち）
- 他に既存のオープン PR が #74 / #44 / #7 / #3

---

## 追記（2026-08-16 深夜・Wave 1 検収セッション）

### Wave 1 は完走・検収済み
- PR-1 = `修正-投稿詳細の著者表示`（6b4ddf3）／PR-2 = `修正-フォローカウンタをFunctionsで根治`（3bcf10e）／PR-6 = `機能-タグ詳細画面とタグフォロー`（decac1e）。全ブランチ実在確認済み。
- PR-6 の未実行だった XCTest はメインセッションで追試済み → **TagFeedServiceTests 10/10 green**。原因はテスト用シミュレータクローン8台の残骸（対処: `xcrun simctl --set testing shutdown all`。再発したら同じで直る）。

### /review-full の進捗
- **PR-1: 完了**。4観点→judge keep4/reject1 → keep対応3件を worktree 1 に**コミット済み `c148392`**（著者プレースホルダ＝publicProfiles未作成の旧アカウント・ゲスト・一過性失敗でも著者ブロックを消さない／陳腐化コメント更新／テスト名リネーム）。test_sim 4/4 green。**残 = push + PR 作成 + 実機ハッピーパス（他人の投稿詳細1件＋自分のギャラリー詳細1件の目視）**。
- **PR-2: judge 実行中**。4観点完了（23指摘→dedupe 15件）。注目: codex の blocker 候補「backfill が project ID 未検証・ADC フォールバック」(D14)、general+codex の major「dry-run が publicProfiles 側を比較せず Changed:0 に見える」(D3)、「reconcile 失敗の握りつぶし＋retry なしで恒久ズレ」(D5)、未使用インデックス2本の意図明記(D1=PR-5前倒しは計画に実在)。
- **PR-6: 4観点レビュー実行中**（判定はまだ）。

### 環境メモ
- XcodeBuildMCP プロファイル: `(default)`=worktree 1 / `wf3`=worktree 3。現在アクティブは `(default)`。メインツリーでビルドする時は projectPath を戻すこと。
- swiftformat フック対策: worktree の Swift 編集は Edit ツールでなく **Bash + python の文字列置換**で行う（整形 churn 防止・PR-1/PR-6 エージェントの学び）。

### この後の手順（未実施）
1. PR-2 judge 結果 → keep 対応を worktree 2 にコミット
2. PR-6 judge → keep 対応 → 再ビルド/テスト
3. 3ブランチを push → PR 作成（PR-1 を先にマージ→PR-6 は rebase。PR-2 は独立）
4. マージ GO・Firebase デプロイ GO（Functions→indexes→実データ目視→backfill --dry-run）は**必ずユーザーに確認**
5. その後 Wave 2（PR-3/PR-4）起動

---

## 追記2（2026-08-16 深夜・2度目の引き継ぎ発動時点）

### 走行中だったバックグラウンドエージェント（結果は output ファイルに落ちる）
tasks ディレクトリ = `/private/tmp/claude-501/-Users-yoshidometoru----iOS---------/c829c843-e92d-4569-805b-2e145f5eefff/tasks/`
- **PR-2 妥当性判定（filter-validity-judge）**: ✅**完了 keep9/reject6**（全文= `a0cf8af25d2f00ac6.output`）。**実コード修正が要るのは D3（backfill:121-125 の dry-run 判定に publicProfiles 側の値比較を追加・major）と D14（backfill の確認プロンプト前に接続先 projectId 表示＋期待値ガード・blocker→major 降格）の2件だけ**。D5=reconcile のコメントに「一過性障害時は次イベント or backfill 手動実行が必要」の但し書き（最低線）。D1=インデックス2本の PR-5 前倒し意図を PR 説明に明記。D6/D11=firestore-schema.md の :20（notifyReactions にフォロー追記）と :27（トリガー一覧に follows 追記）は本PR内で修正・SettingsView:314 の文言は次リリース同梱の companion change として申し送り。D7=backfill ヘッダーに実行順序（dry-run で No publicProfile 確認→必要なら migrate→Functions デプロイ→backfill）追記。D10/D12=PR 本文に手動検証6ケース列挙＋What's New 運用フラグ（非ブロック）。reject 6件は対応不要（D2/D4/D8/D9/D13/D15）
- ✅**PR-6 general 完了**: `a4f39d07e20053718.output` — major 1（新規テスト10件が未配線の純関数のみ対象・本番ロジック=toggleFollowTag 上限境界/unfollow/未ログイン/ブロック除外はテストゼロ）・minor 7・nit 3。重要 minor: ①User.toFirestoreData が followedTags を書くため updateProfile 経由で arrayUnion の結果を旧配列で巻き戻す（前例=updateNotificationPreferences 方式で読み取り専用化）②デコード1件スキップと基底の「posts.count<pageSize→打ち切り」が噛み合わずページング早期停止③1ページ目が全件ブロック済みだと偽の「投稿なし」④シート経由の TagDetail→PostDetail→TagDetail 再帰はカード層以外で成立
- ⚠️**ゲスト判定でレビュアー間に事実の相違あり — judge で要決着**: project-rules は「ゲスト=匿名認証で currentUserId 非nil→ガード発火せず」と主張、general は「真ゲスト(enterGuestMode)=Firebase未認証で currentUserId は nil（ガードは発火する）・匿名認証ユーザーとは別物」と区別。AuthViewModel.enterGuestMode / signInAnonymously の実装を読んでどちらの経路が実在するか確定させること
- ✅**PR-6 codex 完了**（3回目の再開で回収済み）: `a84d8132d93fd66ce.output` — 8件（major 6/minor 2）。general と同根: 全件ブロックページでのフィード停止・デコードスキップとページング打ち切り・PostDetail 経由のタグ詳細再帰・テストが未配線純関数のみ。**codex 独自の新規 3件**: ①loadBlockedUsers 失敗時に blockedUserIds=[] の fail-open（ブロック済み投稿が出る）②firestore.rules が followedTags の 30件上限をサーバー側で検証していない（改変クライアントで突破可）③tag_detail_opened / tag_follow_toggled が生タグ文字列を Analytics に送る（自由入力の高カーディナリティ・sanitize はメール等のみ）④retry が refresh() のみで checkLikeStatus 未実行（minor）。これで **PR-6 は4観点完了＝dedupe→judge に進める**（codex 指摘も他観点と同等に扱うこと）
- ✅**PR-6 project-rules 完了**: `a25c7dcc30fa02598.output` — **major 1件が本命**: このアプリのゲストは**匿名認証**（`signInAnonymously`・users ドキュメント無し）なので `currentUserId == nil` によるゲスト判定は常に false → TagDetailViewModel:61/156-172/180-184 の「ログインが必要です」ガードが発火せず、ゲストがフォローを押すと notFound 由来の汎用エラーになる。PR-7 が isGuest を参照すると意味が逆転したまま伝播する危険。minor 1件=firestore-schema.md に followedTags 追記漏れ。gap に「rules に followedTags の30件上限バリデーション無し」（security 領域）。index追加不要・rules変更不要・計装・⭐️マーキング・命名は検証済みで問題なし
- 完了済み **PR-6 simplifier**: `a21c1f4c83eaa8f92.output` — 要旨: major2件（①TagDetailViewModel が HomeViewModel の著者取得/ブロック除外ロジックの3コピー目=PaginatedPostsViewModel へ引き上げ提案 ②fetchInferredTags+HashtagFrequencyRanker が本PR内で未配線）・minor2・nit2。⚠️**②は承認済み計画で PR-7 が使う前倒し実装**なので judge にその文脈を必ず渡すこと
- 完了済みレビューの全文も同ディレクトリ: PR-1 4本＝`a9265e4097ef4aa13`(simplifier)/`abcec9224c38c7414`(general)/`a02fd34a67a554e55`(codex)/`a1898b1200d2d7d18`(project-rules)、PR-1 judge＝`a0ac5de7ac3f949cb`、PR-2 4本＝`a7aec9f0cb608ad8f`(simplifier)/`a1cdcfd91a6cdd3e2`(general)/`a14b83c37e896a4a5`(codex)/`ac13ade5232c4bd4e`(project-rules)

### PR-2 の dedupe 15件の骨子（judge 出力に全文あり・ここは索引）
D1 未使用インデックス2本の意図明記(PR-5前倒しは計画に実在)／D2 クライアントincrement残置(=PR-3スコープ)／D3 backfill dry-run が publicProfiles 側を比較せず Changed:0 に見える(major)／D4 errorCount>0 でも exit 0／D5 reconcile 失敗握りつぶし+retry なしで恒久ズレ(major)／D6 notifyReactions 文言(SettingsView:313+docs)がフォロー未記載／D7 publicProfiles 未作成コホート未救済+実行順序未記載／D8 get()×2→update() 提案／D9 rules が self-follow 許容(PR-8同乗案)／D10 手動検証6ケースをPR本文に／D11 firestore-schema.md 更新漏れ／D12 What's New 運用フラグ／D13 backfill と本番トリガーのレース(codex major)／D14 backfill の project ID 未検証+ADC フォールバック(codex blocker 候補)／D15 count() 課金コメント不正確(現規模はユーザー数十人)

### git 状態（このセッション終了時点・コミットしないこと）
- worktree 1（PR-1）: `c148392`（keep対応済み）← `6b4ddf3` ← main。**push 未実施**
- worktree 2（PR-2）: `3bcf10e`。keep 対応待ち
- worktree 3（PR-6）: `decac1e`。judge 待ち
- メインツリー: `改善-worktree除外でビルド事故を防ぐ`（227ae67）のまま。未コミット変更は前回記録と同じ（触っていない）

---

## 追記3（2026-08-17・レビュー工程続行セッション）

### 完了
- **PR-2 keep 対応 → コミット `800cb75`**（worktree 2）: D14=接続先 projectId 表示＋期待値ガード（EXPECTED_PROJECT_ID='soramoyou-ios'・不一致/特定不能で exit 1）／D3=dry-run 判定に publicProfiles 側の値比較＋ラベル表示／D7=ヘッダーに実行順序（dry-run→migrate→Functions deploy→本実行）／D13(任意)=閑散時間帯推奨／D5=reconcile catch の但し書き＋「自己修復」過剰主張の是正／D6・D11=firestore-schema.md の :20 と :27 追記。`node --check` と functions lint green。
- **PR-1 push 済み → [PR #84](https://github.com/kamui00002/soramoyou/pull/84)**（マージ前に実機ハッピーパス目視が残・本文に明記）
- **PR-2 push 済み → [PR #85](https://github.com/kamui00002/soramoyou/pull/85)**（D1 インデックス意図・D10 手動検証6ケース・D12 What's New フラグ・D6 SettingsView companion change・D9 PR-8 同乗を本文に記載済み）
- **PR-6 の dedupe 完了（26→18件・T1〜T18）**: `/private/tmp/claude-501/-Users-yoshidometoru----iOS---------/7fbaa558-7094-4001-b5be-a550e2896028/scratchpad/pr6-dedupe.md`。ゲスト判定の事実相違（T4）は judge に AuthViewModel 実装読みで決着させる指示済み。fetchInferredTags=PR-7 前倒し（T2）の文脈も judge に渡した。

### PR-6 も完了（2026-08-17）
- **judge 結果: keep 12 / reject 6**（judge output=`a77e71c438147d4fd.output`・このセッションの tasks dir `/private/tmp/claude-501/-Users-yoshidometoru----iOS---------/7fbaa558-7094-4001-b5be-a550e2896028/tasks/`）。T4 事実決着=**general が正しい**（ゲスト=enterGuestMode=Firebase未認証→currentUserId nil→guard 発火。project-rules の major は fabricated 棄却。signInAnonymously は UI から到達不能）。codex major 6件は生き残りゼロ。
- **keep 対応 → コミット `fc8673c`**（implementer/Opus 5 実装・検収済み）: T8=toFirestoreData から followedTags 除去（巻き戻しバグ根治・最重要）／T7=TagDetailViewModelTests 新規4ケース（29件成功/30件上限/unfollow/ゲスト）／T4=未使用 isGuest 削除／T1/T2/T3/T9/T11=コメント整備／T13/T14=loadFollowState 先行・retry 後の checkLikeStatus／T18=schema 追記（PR-2 の :20/:27 とは別位置でコンフリクト回避済み）。ビルド SUCCEEDED・対象テスト 14/14 green（実行ケース名確認済み）。
- **push 済み → [PR #86](https://github.com/kamui00002/soramoyou/pull/86)**。⚠️マージ順: **#84 → #86 rebase → #86**（HomeView/GalleryDetailView 競合対策・計画どおり）。#85 は独立。
- PR-7 への申し送りは #86 本文に記載（T9/T10 の 0件ページ問題を MergedFeedPaginator 設計の適用対象に含める・loadFollowState の真の並行化判断）。

### ユーザー回答済みの GO 方針（2026-08-17 AskUserQuestion）
- **マージ**: 実機確認後に順次（ユーザーが実機ハッピーパス目視→OK後に #84 → #86 rebase → #86 → #85 の順で Claude がマージ）
- **Firebase デプロイ**: #85 マージ後すぐ実施（indexes → functions → 実データ目視 → backfill --dry-run 結果提示 → 本実行前に再確認）
- **Wave 2**: 今すぐ起動 → **起動済み**。Workflow Run ID `wf_22fe29a5-0b0` / Task ID `wtb7ikxls`（PR-3=修正-フォローカウンタのクライアント書き込み除去 → PR-4=修正-他人プロフィールの可視性対応 の直列2本・worktree 分離・Opus 5・main 9c1333e 基点指示済み）。Script: このセッションの workflows/scripts/soramoyou-follow-wave2-wf_22fe29a5-0b0.js

### 残（次のアクション）
- ユーザーの実機ハッピーパス: #84=他人の投稿詳細＋自分のギャラリー詳細の目視／#86=タグタップ→フォロー→再起動→解除＋**T8 実挙動**（タグフォロー後にプロフィール編集保存してもフォローが消えない）
- 実機 OK 後: #84 マージ → worktree 3 で #86 を rebase・再push → #86 マージ → #85 マージ → Firebase デプロイ手順へ
- Wave 2 完了通知後: 検収 → /review-full（PR-3/PR-4）→ judge → keep 対応 → push/PR
- PR-4 プローブ（実 Firestore・exists() の list クエリ判定・上限 N 段階測定）は人間ゲート＝ユーザーと一緒に実施

---

## 追記4（2026-08-17・context-guard によりこのセッション終了）

### ✅ Wave 2 完走済み（2026-08-17・両 agent 成功・push/PR/レビューは未実施）
- **PR-3** = `修正-フォローカウンタのクライアント書き込み除去` @ `7a41d49`（worktree `wf_22fe29a5-0b0-1`・main 基点）。FollowRepository の increment 4箇所除去／`updatePublicProfileFields` 新設（**計画差分: NOT_FOUND 時は createPublicProfile フォールバック**＝publicProfiles 未作成ユーザーの自己修復を維持・理由は journal 参照）／ProfileViewModel 差し替え／回帰テスト2件。BUILD SUCCEEDED・ProfileViewModelTests 新規2件含む 11 pass。
- **PR-4** = `修正-他人プロフィールの可視性対応` @ `d0e5518`（worktree `wf_22fe29a5-0b0-2`・main 基点）。`fetchVisibleUserPosts` 新設（**計画差分: 1要素時は `in` でなく `isEqualTo`**＝プローブ失敗時に原因を followers 枝へ一意帰着させるため）／load() 直列化＋filter 削除＋握りつぶし解消（errorMessage 表示）／toggleFollow 後の再取得／index `visibility+userId+createdAt DESC` を JSON 追加（**未 deploy**）／新規テスト 6/6 green。
- ⚠️ **重要な申し送り3点**:
  1. **PR-3 は users 側の clobber を残置**（計画スコープどおり publicProfiles のみ）。本人の自分プロフィール画面の数字は次のフォローイベントまで古く見えることがある → **実機クロバー回帰確認時に PR-3 の失敗と誤読しない**。users 版ターゲット更新は別 PR 候補。
  2. **PR-4 のプローブ前に index deploy 必須**。失敗モード識別: インデックス欠落=`failed-precondition`（作成リンク付き）／rules 拒否=`permission-denied`。取り違えると R1 判断を誤る。プローブ step1 の失敗は空グリッドでなく**エラーダイアログ**として出る。
  3. main の既知失敗テストに `testLoadProfile` / `testLoadEditTools`（ProfileViewModelTests）を追加推奨（両 agent が main 相当で failing を実証済み）。
- journal 全文: `/Users/yoshidometoru/.claude/projects/-Users-yoshidometoru----iOS---------/7fbaa558-7094-4001-b5be-a550e2896028/subagents/workflows/wf_22fe29a5-0b0/journal.jsonl`
- worktree 罠の再確認: 両 worktree とも `GoogleService-Info.plist` 手動コピーが必要だった（gitignore 済み・コミット非混入確認済み）。`worktree-wf_*` ブランチ残骸は後で片付け。
- **次セッションの Wave 2 残**: /review-full（PR-3/PR-4・4観点→dedupe→judge→keep 対応）→ push → PR 作成。PR-3 のマージは PR-2 デプロイ後。

### PR-6 レビュー資産（判定根拠が要る時）
- dedupe 全文: `/private/tmp/claude-501/-Users-yoshidometoru----iOS---------/7fbaa558-7094-4001-b5be-a550e2896028/scratchpad/pr6-dedupe.md`（4観点全文も同 dir の pr6-*.md）
- PR-6 judge 全文: 同セッション tasks dir の `a77e71c438147d4fd.output`／PR-6 keep 実装レポートは `ac67fd108571b2de2.output`（いずれも jsonl・最終 assistant テキストのみ抽出して読むこと）

### git 状態（セッション終了時点・コミットしないこと）
- worktree 1=`c148392`(push済)/2=`800cb75`(push済)/3=`fc8673c`(push済)。PR #84/#85/#86 オープン
- メインツリー: `改善-worktree除外でビルド事故を防ぐ`（227ae67）のまま。未コミット変更は冒頭記録と同じ＋本ハンドオフ（.claude/handoffs/ 配下・untracked）のみこのセッションで更新
- XcodeBuildMCP プロファイル注意（追記の環境メモ参照）は継続有効

---

## 追記5（2026-08-17・Wave 2 /review-full 完了セッション）

### ✅ Wave 2 のレビュー→keep対応→push→PR 作成まで完了
- **PR-3 → [PR #87](https://github.com/kamui00002/soramoyou/pull/87)**（`修正-フォローカウンタのクライアント書き込み除去`・`7a41d49` ← keep対応 `5112159`）
- **PR-4 → [PR #88](https://github.com/kamui00002/soramoyou/pull/88)**（`修正-他人プロフィールの可視性対応`・`d0e5518` ← keep対応 `5fef778`）
- /review-full: 4観点×2PR（生19件）→ dedupe 17件 → judge **keep 8 / reject 9 / defer 0**。dedupe 全文=このセッション scratchpad の `pr34-dedupe.md`、judge 全文=tasks dir `aa8504c3a36b85594.output`（scratchpad/tasks dir = `/private/tmp/claude-501/-Users-yoshidometoru----iOS---------/f4e06789-b2f7-4abb-a994-0c828bfb0f91/`）

### keep 対応の要点（両 worktree ともビルド成功・テスト green 確認済み）
- **D4（PR-3 major・最重要）**: NOT_FOUND フォールバックの「code 5」判定を廃止し、**update 失敗時に get で存在確認**する方式へ。根拠: rules の publicProfiles update は `resource.data.id` 参照＝不在時に code 7 (PERMISSION_DENIED) が返りうる（静的推論・実測は未。Java 無しでエミュレータ不可・公式文書にも先後の明記なし）。どちらの世界でも正しい構造にしたのでプローブでの事後検証だけ残る
- **D8（PR-4 major）**: fetchIsFollowingSafe の失敗を errorMessage で可視化（false 降格は維持）＋回帰テスト
- **D9（PR-4 major）**: fetchVisibleUserPosts を per-document do/catch（path ログ＋1件スキップ）に
- D1=updatePublicProfile を protocol ごと削除（本番呼び出しゼロ確認済み）／D5=異常系テスト／D7=firestore-schema.md 末尾(207行〜)に publicProfiles 書き込み契約／D11=空状態文言 .custom 化／D15=lastDocument カーソル制約の doc
- テスト実績: PR-3=ProfileViewModelTests 13 pass（fail 2 は main 由来ベースライン一致）／PR-4=UserProfileViewModelTests 7/7

### ⚠️ プローブ手順への追加知見（PR #88 本文にも記載）
- `in` と `isEqualTo` で必要インデックスが別物になりうる → **「フォロー時のみ failed-precondition」の部分的失敗がありうる**。プローブでは FirestoreErrorCode を直接確認すること
- D4 の code 5 vs 7 も同プローブで実測可能（publicProfiles 未作成ユーザーでプロフィール編集）

### 残タスク（変更なし・全部ユーザー GO 待ち）
1. ユーザー実機ハッピーパス → #84 マージ → worktree 3 で #86 rebase・再push → #86 → #85 マージ
2. #85 マージ後 Firebase デプロイ（indexes → functions → 実データ目視 → backfill --dry-run 提示 → 本実行前に再確認）
3. PR-4 プローブ（index deploy 後・ユーザーと一緒に）→ R1 判定 → A2 可否と上限 N
4. **#87 のマージは #85 の Functions デプロイ後**（PR 本文に明記済み）
5. 別タスク chip 発行済み: FirestoreService の同型 compactMap 欠陥の横展開（task_765f92c1）

### git 状態（セッション終了時点）
- worktree 1=`5112159`(push済・#87)／2=`5fef778`(push済・#88)／wf_138baa1e 系 3本は変更なし（#84/#85/#86）
- メインツリー: `改善-worktree除外でビルド事故を防ぐ`（227ae67）のまま。このセッションで触ったのは worktree 2本と本ハンドオフのみ

---

## 追記6（2026-08-19・実機ハッピーパスをシミュレータで代行実施）

### 実施方法の変更: 実機 → シミュレータ（Claude が代行）
iPhone 17 Pro シミュレータ（`DCFBF2D6-0E1B-4614-893F-8A64FC50103B`）に **Soumatou でログイン済みの状態が残っていた**ため、Claude が自分で全手順を実行して screenshot で目視検証した。Firebase は本番バックエンドなので実データ（他人の投稿=NONAME / 紳士 / ひとやすみ）で検証できている。

### ✅ #84（投稿詳細の著者表示）= OK
- 他人（NONAME）の投稿詳細 → **著者ブロックが表示され、名前とアイコン両方が出る**（修正前は無言で消えていた）
- 自分（Soumatou）の投稿詳細（ギャラリー経由 GalleryDetailView）→ 名前・アイコン・編集設定とも従来どおり。デグレなし
- ホームフィードのカード層でも NONAME / 紳士 / ひとやすみ の著者名が出ている

### ✅ #86（タグ詳細＋タグフォロー）= OK
1. 投稿カードの `#風景写真` タップ → タグ詳細画面が開き、そのタグの投稿一覧が出る ✅
2. 「フォロー」→「フォロー中」に変化 ✅
3. `simctl terminate` → `launch` で完全再起動 → **フォロー中が保持** ✅
4. プロフィール編集を開いて（内容変更なしで）保存 → **フォロー中のまま**。`updateProfile()` は変更検知なしで無条件に `updateUser` を呼ぶ実装なので、保存を押した時点で Firestore 書き込みは確実に走っている ✅
5. フォロー解除 → 「フォロー」に戻る。**タグは元の未フォロー状態に復帰済み**（検証の後始末完了）✅
- 静的確認: `Models/User.swift` の `toFirestoreData` に followedTags の書き込みが無く「読み取り専用」コメントのみ＝T8 修正が入っている

### ⚠️ T8 検証の限界（次に誰かが見るとき用）
手順が「フォロー → 再起動 → 保存」の順だったため、再起動で ProfileViewModel の user が読み直されている。**修正前でも消えなかった可能性が残る**＝実機検証の T8 検証力は弱い。T8 の本質的な担保は ①`toFirestoreData` の静的確認 ②keep 対応時の TagDetailViewModelTests 14/14 green の 2 点。より強い再現をするなら「アプリ起動中にプロフィール画面を開いた後（user キャプチャ後）にタグをフォローし、再起動せずに保存」の順で行うこと。

### 副次確認
- タグ詳細画面のカード内タグをタップしても遷移しない＝T9/T10 の「カード層では TagDetail 再帰が起きない」と一致
- ビルド警告3件（PrimaryColor / PaymentService の Swift6 actor / HomeViewModel の `post.id ?? ""`）は **いずれも main 側にも存在する既存警告**。#86 由来のデグレではない
- XcodeBuildMCP の tap 系ツールはこの環境で無効。**`mcp__Claude_Code_iOS_Simulator__control`（座標 402x874 points）で操作し、`mcp__XcodeBuildMCP__screenshot` / `snapshot_ui` で観測**する組み合わせが有効

### この時点の状態
- session defaults の projectPath は **worktree 3 を向いたまま**（メインツリーで作業する時は戻すこと）
- シミュレータには #86 のビルドが入っている
- マージはユーザー GO 待ち（#84 → #86 rebase・再push → #86 → #85 の順）

### 次セッションの残タスク（2026-08-19 時点・全部ユーザー GO 待ち）
1. **マージ GO を確認** → `#84` → worktree 3（`.claude/worktrees/wf_138baa1e-4e5-3`）で `#86` を main に rebase・強制 push → `#86` → `#85` の順
2. `#85` マージ後に **Firebase デプロイ GO を再確認** → `firebase deploy --only firestore:indexes --project soramoyou-ios` → `functions` → 実データ目視 → `backfill --dry-run` の結果を提示 → **本実行前にもう一度確認**
3. **PR-4 プローブ**（`#88`・index deploy 後・ユーザーと一緒に）: 未フォローで public 1件 → フォローで public+followers 2件 → 上限 N を 2→5→8→10→12 で段階測定。⚠️ `FirestoreErrorCode` を直接確認（`failed-precondition`=index 欠落 / `permission-denied`=rules 拒否）。`in` と `isEqualTo` で必要 index が別物になりうるので「フォロー時のみ failed-precondition」がありうる。ついでに D4 の code 5 vs 7 実測（publicProfiles 未作成ユーザーでプロフィール編集）
4. プローブ結果で **R1 判定** → A2 可否と上限 N 確定 → Wave 3（PR-5）起動判断
5. `#87` のマージは `#85` の Functions デプロイ後（PR 本文に明記済み）

### 環境の後始末メモ
- XcodeBuildMCP の session defaults は **worktree 3 を向いたまま**。メインツリーで作業する時は projectPath を戻す
- シミュレータ枯渇時: `xcrun simctl --set testing shutdown all`
- worktree の Swift 編集は Edit ツールでなく **Bash + python 置換**（swiftformat フック対策）
- メインツリーの未コミット変更は前回記録と同一（`.serena/project.yml` ほか・並行セッション由来の可能性があるため触らない）。このセッションで触ったのは本 handoff のみ

---

## 追記7（2026-08-19・マージ5本 + Firebase デプロイ + R1 プローブ **全完了**）

### ✅ PR 5本すべて main にマージ済み
| PR | 内容 | main の squash commit |
|---|---|---|
| #84 | 投稿詳細の著者表示（PR-1） | `72fd1c0` |
| #86 | タグ詳細＋タグフォロー（PR-6） | `aa926b2` |
| #85 | Functions カウンタ根治（PR-2） | `811fa3e` |
| #87 | クライアント increment 除去（PR-3） | `8b0611b` |
| #88 | 他人プロフィールの可視性対応（PR-4） | `5820154` |

⚠️ **手順変更**: `git push --force-with-lease` がこの環境の権限で**ブロックされる**。そのため rebase ではなく **`git merge origin/main` → 通常 push** で統合した（#86/#87/#88 とも）。#86 では rebase 版とツリー差分ゼロを確認済み。次回も force push は使えない前提で。

コンフリクト解消の判断（記録）:
- #86 `HomeView.swift`: `authorSection` は main（#84）の `PublicProfile?` 版を採用
- #87 `FirestoreServiceProtocol+TestDefaults.swift`: `updatePublicProfileFields` を採用し `updatePublicProfile` は破棄（残存呼び出しゼロを grep 確認）／`firestore-schema.md` は両方の追記を併記
- #88 `FirestoreService.swift`: `fetchVisibleUserPosts` を採用（2ハンクとも main 側は空行のみ）。`firestore.indexes.json` は merge で follows インデックス2本が自動的に併合された

### ✅ Firebase デプロイ完了（ユーザー GO 済み）
- `firestore:indexes`: `follows: followerId+createdAt DESC` / `follows: followeeId+createdAt DESC`（#85）＋ `posts: visibility+userId+createdAt DESC`（#88・worktree 2 から前倒し deploy）。**deploy 済みを `firebase firestore:indexes` で実査確認**
- `functions`: `onFollowCreated` / `onFollowDeleted` を**新規作成**、既存10本も更新成功
- ⚠️ **`--force` は付けていない**。#88 のブランチは #85 の follows インデックスを持たない状態だったので、もし `--force` を付けていたら 2 本消えていた。今後も indexes deploy は main から行うこと

### ✅ Functions の実データ検証 = 成功（欠陥 A の根治を本番で実証）
NONAME（`0RfLxnDj…`・**fcmToken 無し＝プッシュは飛ばない**ことを事前確認）で unfollow → refollow を実施:

| 段階 | `users.followersCount` | `publicProfiles.followersCount` | 判定 |
|---|---|---|---|
| 実施前 | 3 | **2**（永久にズレていた） | 欠陥 A |
| unfollow 後 | **2** | 2 | onFollowDeleted ✅（アプリは PR-3 込みで users を書かない＝Functions の仕事と確定） |
| refollow 後 | 3 | **3** | onFollowCreated ✅ publicProfiles への書き込み成功 |
| **アプリ再起動後の画面** | — | **フォロワー 3 と表示** | ✅ 楽観的 ±1 を排除した真値 |

Cloud Logging にも 06:18:02 `onfollowdeleted` / 06:18:34 `onfollowcreated` の AUTOSCALING 起動（＝実イベント受信）を確認。エラーログ 0 件。

### ✅ R1 プローブ = 成功 → **A2 ストリームの前提は成立**
`exists()` は list クエリの rules で**評価される**。詳細は [PR #88 のコメント](https://github.com/kamui00002/soramoyou/pull/88#issuecomment-5338344506) に全文。

- 未フォロー（紳士）→ `visibility isEqualTo 'public'` → 投稿 5 件 ✅（欠陥 D 解消）
- フォロー中（NONAME）→ `visibility in ['public','followers']` → 投稿 24 件 ✅ denied も index 欠落も無し

⚠️ **ただし証明できたのは「`userId` が単一値に固定された形」まで**。プローブの形は `visibility in [2]` + `userId ==`、A2 の形はその転置（`visibility == 'followers'` + `userId in [N]`）。Firestore は `in` を userId ごとの論理和に分解し各枝は今回検証したのと同一構造になるため機構としては通るはずだが、**`exists()` の「1リクエスト10回まで」が分解後のリクエスト全体に効くのか枝ごとなのかは未実測**＝これが R2 で、A2 のチャンクサイズを決める。「実現可能」を「チャンクサイズは自由」と読まないこと。

⭐️ **重要な認識訂正**: 「followers 投稿が本番に 1 件も無いからプローブできない」は**誤り**。rules の list 評価は**クエリ形状に対する静的証明**でドキュメントの実在に依存しないため、followers 投稿ゼロでも R1 は判定できる（実際できた）。第 2 アカウントが要るのは「public+followers の 2 件が出る」という**内容確認だけ**。

### ⚠️ プローブで**できなかった**こと（PR-7 への申し送り）
1. **上限 N の段階測定（2→5→8→10→12）は #88 では原理的に不可能**。`fetchVisibleUserPosts` は `userId` を単一値でしか取らず、`UserProfileView` も 1 著者しか照会しない＝`userId in [N]` を発行する UI 経路が存在しない。**PR-7 の `ForYouFeedSourceBuilder` で測定する**。初期チャンクサイズは rules の `exists()` 上限 10 から余裕を引いた値（8 以下）を暫定に。
2. **D4 の code 5 vs 7 実測も未実施**。`publicProfiles` 未作成のアカウントでプロフィール編集する必要があるが、操作できるアカウントはいずれも `publicProfiles` を持つ。D4 はどちらでも正しい構造なので実害なし。

### 📊 backfill dry-run の**予測**（読み取りのみで先読み計算済み）
follows 全 24 件を数え直して users / publicProfiles と突合した結果:

- **`users` 側は全ユーザー既に正しい**。ズレは **publicProfiles のみ**
- **Changed の予測 ≈ 13 件**（NONAME は上記の Functions 検証で既に直ったので 14 → 13）。⚠️ follow グラフ外の 54 名の `publicProfiles` は読んでいないので、その分の増減と `missingProfileCount` は dry-run の実測を待つこと
- 内訳: 御柴様 0→2 ／ えび 0→2 ／ ゆき 0/0→1/1 ／ ふう・るな・雪原・宙亡・木町・おはぎ 0→1 ／ apple-review 0/0→0/3 ／ まーる・ほう・紳士 0/0→0/1
- ⭐️ **`migrate-public-profiles.js` は「follows に登場する 20 名については」不要**。この 20 名**全員**が `publicProfiles` を持つことを確認済み＝カウンタ修復の観点ではスクリプトヘッダーの手順 2 をスキップしてよい。ただし follow グラフ外のユーザーに未作成が居る可能性は残り、dry-run の `missingProfileCount` が 0 にならないことはありうる（その分はカウンタ 0/0 なので実害なし）

### 🔑 残 = ユーザーの作業（backfill 本実行の資格情報）
`scripts/backfill-follow-counters.js` は `serviceAccountKey.json` か ADC が必要だが、**このマシンにはどちらも無い**（gcloud 未インストール・ADC ファイル無し・鍵ファイル無し）。

1. [Firebase Console → サービスアカウント](https://console.firebase.google.com/project/soramoyou-ios/settings/serviceaccounts/adminsdk) で「新しい秘密鍵の生成」
2. リポジトリ直下に `serviceAccountKey.json` として置く（`.gitignore:98` で除外済み）
3. `node scripts/backfill-follow-counters.js --dry-run` → 結果を上記予測と突合 → 本実行

※ backfill を実行しなくても、**該当ユーザーが次にフォロー/解除されれば Functions が自動で直す**。緊急性は低い。

### ⚠️ 検証で1件だけ不可逆な変更が出た（PR-5 の並び順検証で誤読しないこと）
Functions 検証の unfollow → refollow により `follows/nzvqlZK2…_0RfLxnDj…` の **`createdAt` が `2026-05-04T08:45:00` → `2026-08-19T06:18` にリセット**された。元のフォロー日時は復元できない。
影響: 今回 deploy した `follows: followeeId+createdAt DESC` を PR-5 の `fetchFollowers` / `fetchFollowing` がそのまま使うため、**NONAME のフォロワー一覧で Soumatou が最上位に来る**。バグではなくこの検証の副作用。

### main マージ後の検証（追記7 の最後に実施）
- `build_sim` **SUCCEEDED / errors 0**（メインツリー・全 PR マージ後の状態）
- `PostDetailViewModelTests` + `TagDetailViewModelTests` + `TagFeedServiceTests` + `UserProfileViewModelTests` = **25/25 green**
- `ProfileViewModelTests` = 13 pass / 2 fail（`testLoadProfile` / `testLoadEditTools`）＝**追記4で記録済みの main 由来ベースラインと一致・回帰ではない**
- worktree 5本は `git worktree remove --force` で削除済み（全て clean を確認してから）。残るは main のみ

### 環境の状態（次セッション向け）
- **XcodeBuildMCP session defaults は既にメインツリーへ戻してある**（`/Users/yoshidometoru/開発/iOSアプリ/そらもよう/Soramoyou/Soramoyou.xcodeproj` / scheme `Soramoyou` / sim `DCFBF2D6-…` / bundleId `com.yoshidometoru.Soramoyou`）
- シミュレータ（`DCFBF2D6-0E1B-4614-893F-8A64FC50103B`）には #88 のビルドが入っており Soumatou でログイン済み
- メインツリーの未コミット変更（`.serena/project.yml` ほか）は**引き続き触っていない**
- ⚠️ シミュレータ操作は `mcp__Claude_Code_iOS_Simulator__control`（座標 402x874 points）。**`open_url` はアプリ再起動には使えない**（Safari が開く）。再起動は `stop_app_sim` → `launch_app_sim`

### 次のアクション
1. **Wave 3（PR-5）の起動判断** ← R1 成功により計画どおり進められる。フォロワー/フォロー中一覧＋フォロワー削除。#85 の follows インデックスは deploy 済みなので前提は揃っている
2. backfill dry-run（鍵が用意でき次第）
3. Wave 4（PR-7）で上限 N を測定 → A2 のチャンクサイズ確定
4. PR #82（PrivacyInfo CA92.1）・#83（worktree gitignore）は未マージのまま。次のリリース便（build 95+）に同乗させる
5. What's New（`WhatsNewContent`）の更新 — タグ詳細/タグフォローはユーザーに見える新機能なので、リリース前に必要

---

## 追記8（2026-08-19・Wave 3 = PR-5 実装完了・/review-full 途中で context-guard 発動）

### ✅ 決定事項（ユーザー回答済み）
- Wave 3 起動 = **GO・直接実装**（ultracode/implementer 委譲は不採用。単独PRで並列化メリットなしのため）
- What's New = **PR-7 で一括**（計画どおり）

### ✅ PR-5 実装完了 — ブランチ `機能-フォロー一覧とフォロワー削除`・コミット `b0b9940`（8ファイル +1106/-34）
- `Services/FollowRepository.swift`: protocol+実装に `fetchFollowers`/`fetchFollowing`（等値+createdAt DESC・TagFeedService と同形のページング・デコード失敗はパスをログして1件スキップ・lastDocument は snapshot.documents.last）/`removeFollower`（"{相手}_{自分}" を unfollow と同じ存在確認→削除トランザクションで削除）
- `ViewModels/FollowListViewModel.swift`（新規）: follows ページング→表示uid→publicProfiles を withTaskGroup 並列取得（HomeViewModel :86-103 踏襲）。hasMore は件数ベース（count >= pageSize）。削除は楽観的更新なし・成功後に行を除去。`FollowListType` enum（followers/following）と `displayUserId(for:)` で向きを一元化。pageSize は init 注入可（テスト用）
- `Views/FollowListView.swift`（新規）: グラデ背景+出し分け（LoadingStateView/ErrorStateView/EmptyStateView(.followers/.following)/一覧）。行=アバター+表示名+bio・NavigationLink→UserProfileView（自分の行は遷移なし）。自分のフォロワー一覧のみ「削除」→ confirmationDialog（名前入りタイトル+destructive）。計装 `follow_list_opened {list_type, is_own_list}` / `follower_removed {removed_user_id}`（author_id は auth 部分一致 REDACT で不可のため）
- `Views/UserProfileView.swift` / `Views/ProfileView.swift`: カウンタを NavigationLink 化（呼び出し元は全て NavigationView 内なので push 可）。UserProfileView は targetUserId/ownUserId を view にも保持（VM側が private のため）
- `firestore.rules`: follows delete に `|| resource.data.followeeId == request.auth.uid` 追加。**⚠️ deploy は main マージ後・GO 確認必須・main から実行**（未デプロイの間、本番のフォロワー削除は permission-denied）
- `SoramoyouTests/FollowRepositoryProtocol+TestDefaults.swift`（新規）: protocol 拡張の fatalError デフォルト（既存 MockFollowRepository 互換維持）
- `SoramoyouTests/FollowListViewModelTests.swift`（新規）: 9件（uid の向き×2・hasMore判定・loadMore追加・初回エラー・削除成功/失敗/権限外・プロフィール取得）。モックの記録配列は NSLock 保護（withTaskGroup 並列呼び出しのため。lock/unlock は noasync なので同期ヘルパー経由）

### ✅ 検証済み
- build_sim SUCCEEDED/エラー0（警告は main 由来の既存のみ）・FollowListViewModelTests 9/9 + UserProfileViewModelTests 7/7 green
- シミュレータ実データ検証: 自分のフォロワー一覧5件（紳士/NONAME/まーる/ユーザー/ひとやすみ・カウンタ5と一致・削除ボタンあり・publicProfiles 由来の名前/アバター/bio 表示）→ 行タップで NONAME プロフィールへ push（フォロワー3=Functions検証後の真値）→ NONAME のフォロワー一覧（**Soumatou 最上位=createdAt リセットの既知副作用・バグではない**・他人の一覧なので削除ボタンなし）→ 削除確認ダイアログ表示+キャンセルで5件維持 → フォロー中一覧12件（NONAME 最上位・削除ボタンなし）
- **意図的に未検証**: 削除の実実行（rules 未デプロイで permission-denied になる+本番 createdAt リセット回避のため）。⭐️ **安全な検証手段あり**: 今の本番 rules のまま削除ボタン→実行すれば「エラーアラートが出る=action が走った証明」「何も起きない=confirmationDialog の setter が action より先に走るレースが実在」の切り分けができ、データは変わらない（simplifier の gap 参照）

### 🔄 /review-full — ステージ1（4レビュアー並列）**全完了**・dedupe/judge が未実施
- 対象 diff = `git diff 5820154..HEAD`（次セッションで再生成可）。**4本とも結果回収済み**（codex 含む。再実行不要）
- **次工程**: 下記要約を dedupe（同根集約）→ `filter-validity-judge` → 統合レポート → ユーザー承認 → keep 対応

#### codex の結果（回収済み・gpt-5.6-sol / reasoning high / read-only sandbox）
- MEDIUM: hasMore がデコード後件数判定（下記 #4 と同根・「壊れたdocを含む満杯ページのテスト追加」も推奨）
- MEDIUM: fetchMissingProfiles の未作成ユーザー毎ページ再取得（#3 と同根・「明示リフレッシュ時のみ Set をクリア」も推奨）
- LOW: pull-to-refresh 失敗が既存一覧表示中は不可視（#5 と同根）
- LOW: **[新規] FollowListView:164 の NavigationLink が rowContent（アバター+名前）しか包んでおらず、行の余白・カード背景タップでは遷移しない**＝「行タップで遷移」の意図未達 → 削除ボタン以外を最大幅リンク化 or `.contentShape(Rectangle())`
- MEDIUM(security): removed_user_id で他人の生UIDを分析基盤送信（#10 と同根・codex は「パラメータ削除し削除イベントのみ記録」を推奨。general/project-rules と評価が割れているので judge 案件）
- codex gap: ビルド/テスト未実行・rules エミュレータ未検証・removed_user_id の規約承認は未確認

#### 届いた指摘の要約（dedupe 用・出典付き）
**major 級:**
1. [project-rules/general] ProfileView/UserProfileView に**タスク外の整形差分が大量混入**（Surgical Changes 違反）— ⭐️**真因検証済み: PostToolUse フックのフォーマッタが編集のたびファイル全体を整形した結果**（手編集ではない）。revert しても次の Edit で再整形されるため「フック由来として許容 or 整形を別コミット切り出し」の判断が必要。judge にこの背景を必ず渡すこと
2. [simplifier] removeFollower と unfollow のトランザクションがバイト同一の重複 → `deleteFollowIfExists(_:)` 抽出を推奨
3. [general] fetchMissingProfiles: プロフィール未作成ユーザーが毎ページ再リクエストされる（累積 missing − 取得済み の差分計算のため）→ `attemptedProfileIds: Set` の3行追加を推奨

**minor 級（主要のみ）:**
4. [general+simplifier gap] hasMore がデコード成功件数ベース＝壊れたdoc 1件でページング早期打ち切り → repository が生取得件数 or hasMore を返す形を推奨
5. [general] pull-to-refresh 失敗時、一覧表示済みだと無反応に見える → follows 非空なら errorMessage に出し分け
6. [general] 初回表示で EmptyStateView が1フレーム点滅 → isLoading=true 初期化 or hasLoadedOnce
7. [general] ブロック済みユーザーが一覧に出る（Home/TagDetail/Gallery はフィルタ済みとの不整合）→ 製品判断の明示 or fetchBlockedUserIds 適用（別PR可）
8. [general] ProfileView の `ownUserId: user.id` は「表示中ユーザー」であり認証中の自分ではない（現状 ProfileView は自分専用なので実害なし・将来の外部profile経路で削除ボタン誤表示）→ isOwnProfile 分岐 or authService 由来 uid
9. [general] follows の rules list に limit 上限なし（publicProfiles は limit<=20 で非対称・本PRが list 初実用）→ `allow list: ... && request.query.limit <= 50` 分割を推奨
10. [general] `removed_user_id`（他人の生uid）が Firebase+PostHog 両方に送られる=ソーシャルグラフの一部が外部SaaSへ → パラメータ削除 or ハッシュ化を推奨（project-rules は「内部IDのみ方針には反しない」と評価が割れてる→judge 案件）
11. [general] 削除後に戻り先プロフィールのフォロワー数が古いまま（Functions 反映待ち）→ 一覧を閉じたら loadProfile() 再実行 or 文言表示
12. [simplifier] isOwnFollowersList の `ownUserId != nil` は冗長（Optional==比較で nil は false）
13. [simplifier] confirmationDialog のボタン内 `removalCandidate = nil` が binding setter と二重
14. [general] テストが repository の実フィールド（followeeId/followerId）を担保していない（モックが引数を捨てる）→ フィールド決定の純関数化 or capturedQueries
15. [general] removeFollower ガードの `ownUserId == nil`（ゲスト）経路が未テスト
16. [project-rules] fetchMissingProfiles の bare `try?`（.notFound 以外もログなしで消える）— HomeViewModel と同一の既存パターン踏襲＝既存負債の継承。直すなら両ファイル同時・別issue推奨

**nit:** UserProfileView の targetUserId 二重保持／TestDefaults+モックの fatalError 文言が MockFollowRepository 決め打ち／rules コメントに ⭐️ なし／FollowRepositoryError の return 除去（フォーマッタ由来）

**gap（未消化領域）:** confirmationDialog の setter/action 順序レース（上記の安全な検証手段で確認可）／Functions onFollowDeleted の followee 起点削除での両者カウンタ再計算は本番実証を前提に未読／rules エミュレータテストなし／31件以上でのページング実データ未検証（本番 follows は24件で1ページに収まる）

### 環境メモ（次セッション向け）
- XcodeBuildMCP session defaults は**セッション毎にリセットされる**→ 再設定必要: projectPath=`Soramoyou/Soramoyou.xcodeproj`・scheme=`Soramoyou`・simulatorId=`DCFBF2D6-0E1B-4614-893F-8A64FC50103B`・bundleId=`com.yoshidometoru.Soramoyou`
- シミュレータ操作: `mcp__Claude_Code_iOS_Simulator__control` の tap は **device points（402x874）**。XcodeBuildMCP screenshot は 368x800 で返る→ **座標×1.0925 換算**。タブバー: プロフィール≈(333,789)。アプリは PR-5 ビルド済み・Soumatou ログイン済み
- **PostToolUse フォーマッタフックが Edit のたびにファイル全体を整形する**（整形差分混入の真因）。`.swiftlint.yml` が untracked で存在
- push 時: force-push ブロック環境。統合は `git merge origin/main` + 通常 push
- serviceAccountKey.json は**依然未配置**（backfill はブロック中。予測: Changed ≈13・全部 publicProfiles 側・missingProfileCount は実測待ち）
- メインツリーの未コミット変更（`.serena/project.yml` ほか untracked 群）は並行セッション由来の可能性→**触らない**（今回も未コミットのまま維持）

### 次のアクション（優先順）
1. codex 結果回収（無理なら再実行）→ dedupe → filter-validity-judge → 統合レポート → **ユーザー承認を待って** keep 対応
2. keep 対応後: build_sim + テスト再実行 → push → PR 作成（gh CLI・日本語タイトル「機能: フォロワー/フォロー中一覧とフォロワー削除（Wave 3 / PR-5）」・検証済み/未検証を明記）
3. マージ後: **firestore.rules deploy（main から・GO 確認必須・--force なし）** ← これをやるまで本番のフォロワー削除は動かない
4. backfill dry-run（鍵配置され次第）→ 予測と突合 → 本実行前に再確認
5. Wave 4（PR-7）: ミックスフィード+ホームセグメント+What's New。R2（exists() 上限の実測）は ForYouFeedSourceBuilder で

## 追記9（2026-08-20・PR-5 /review-full 完了・PR #89 作成済み）

### ✅ filter-validity-judge 完了 — 21件 → keep 6・defer 2・drop 13（棄却率62%）
- keep: #10 removed_user_id 除去（最重要）/ #13 confirmationDialog presenting: 化 / #5 refresh 失敗出し分け / #17 行タップ領域拡大 / #9 rules list limit<=50 / #2 deleteFollowIfExists 抽出 → **全対応済み（コミット f71c99b）**
- defer: #7 ブロック済み表示可否 → **ユーザー判断「出す（現状維持）」で確定**（削除導線を残すため）/ #16 bare try? → **issue #90 作成済み**（HomeViewModel と同時・別PR）
- drop 主要: #1 整形差分はフック由来として許容（PR説明に明記済み・squash運用で分割無意味）/ #3・#4 は本番24件で到達不能+rules が壊れdoc生成を遮断 / #10 判定根拠=既存全イベント grep で他者uid前例ゼロ+分析価値ゼロ
- 学習済み例への追記候補（judge提案）: 「他者の内部uidをイベントパラメータに載せる初例は、前例調査+分析価値ゼロ確認で keep。サニタイザ誤検知をキー名変更で回避した経緯は stop シグナル」

### ✅ 安全実験（#13 レース切り分け）— レースは実在しなかった
- rules 未デプロイ状態で削除実実行 → **「Missing or insufficient permissions.」アラート表示 = action は実行され removalCandidate も読めている**（iOS 26.2 sim）。一覧5件のまま=データ不変
- presenting: 化後も同実験を再実行し同結果（action 実行・名前入りタイトル正常）

### ✅ 検証・提出
- build_sim SUCCEEDED/エラー0・FollowListViewModelTests 9/9 + UserProfileViewModelTests 7/7 green
- シミュレータ目視: #17 行余白タップで NONAME プロフィールへ遷移 / #13 presenting: 版ダイアログ正常
- **PR #89 作成済み**: https://github.com/kamui00002/soramoyou/pull/89（コミット b0b9940 + f71c99b）

### 次のアクション
1. ユーザーの PR #89 マージ判断
2. マージ後: **firestore.rules deploy（main から・GO確認必須・--force なし）** `firebase deploy --only firestore:rules --project soramoyou-ios` ← delete 権限+list limit の2変更が同便。これまで本番のフォロワー削除は permission-denied
3. backfill: serviceAccountKey.json **依然未配置**（リポ直下想定・scripts/backfill-follow-counters.js:66）。配置され次第 dry-run → 予測（Changed ≈13・全部 publicProfiles 側）と突合 → 本実行前に再確認
4. Wave 4（PR-7）: ミックスフィード+ホームセグメント+What's New 一括

## 追記10（2026-08-20・PR #89 マージ済み・rules deploy 完了）
- **PR #89 squash マージ済み**（main = `a03628b`・ブランチ削除済み）
- **firestore.rules 本番 deploy 完了**（main から・GO確認済み・released to cloud.firestore）
- deploy 後検証（シミュレータ・新 rules 下）: フォロワー一覧5件 / フォロー中一覧12件が正常読込＝list limit<=50 の影響なし
- **削除の実実行はユーザーが実機で確認する**（AskUserQuestion で「実削除はスキップ」選択）。確認観点: ①行が消える ②Functions がカウンタ再計算 ③follower_removed がパラメータなしで記録（PostHog）
- 残: backfill（serviceAccountKey.json 未配置）／ Wave 4（PR-7）／ issue #90（bare try?）

## 追記11（2026-08-20・Wave 4 = PR-7 実装完了・/review-full 進行中）

### タスク1（削除実実行テストの結果確認）= **未実施と確定**
- PostHog 実査: **`follower_removed` はタクソノミー未登録＝一度も発火していない**。`follow_list_opened` は着弾している（8/20 08:40 JST 頃に followers/following を開いた形跡はあるが削除なし）→ ユーザーの実機削除テストは行われていない。引き続きユーザー待ち。
- ⚠️ 学び: `mcp__firebase__functions_get_logs` は onFollowCreated/Deleted の AUTOSCALING 起動ログを**拾えない**（既知イベントの 8/19 06:18 JST 窓でも0件）。Functions 起動の証跡は Cloud Logging コンソールか PostHog の error_occurred/計装イベントで見ること。

### タスク2（backfill）= 引き続きブロック
- `serviceAccountKey.json` はリポ直下に**未配置**（2026-08-20 確認）。配置され次第 dry-run → 予測（Changed ≈13・全部 publicProfiles 側）と突合。

### タスク3（Wave 4 / PR-7）= **実装・検証完了、/review-full 進行中**
- ブランチ `機能-あなた向けフィードとホームセグメント`・コミット **`805a6dc`**（main a03628b 基点・6ファイル +989/-49）
- 新規: `Services/MergedFeedPaginator.swift`（k-way マージ・Firestore非依存・0件ページ禁止・emit前ブロック除外・生取得数で枯渇判定・部分成功後は throw しない）／`Services/ForYouFeedSourceBuilder.swift`（A1 in≤30 / A2 in≤8 / B array-contains-any≤30・タグは followedTags 優先→0件なら推定 topN=10・CursorBox でカーソル内包）／`ViewModels/ForYouFeedViewModel.swift`（HomeViewModel 継承・executeQuery を paginator.nextPage に差し替え・**isRefreshing ガード**=並行 fetchPosts が新 Paginator の1ページ目を先食いする競合対策）／`SoramoyouTests/MergedFeedPaginatorTests.swift`（必須7＋境界4=11ケース）
- 変更: `Views/HomeView.swift`（セグメント Picker・activeViewModel 化・ゲスト非表示・チップ/OnThisDay は「すべて」のみ・**python 置換でフォーマッタ churn ゼロ**）／`WhatsNewContent.swift`（currentID="2026-08-follow-social"・3ページ: あなた向け/タグフォロー/フォロー一覧）
- 計装: `home_feed_segment_changed {segment}` / `for_you_feed_loaded {post_count, followee_count, tag_count, tag_source}` — **PostHog 着弾実証済み**（post_count=20, followee_count=12, tag_count=10, tag_source=inferred）
- 検証: build SUCCEEDED（警告は main 由来の既知2件のみ）・関連テスト **51/51 green**（MergedFeedPaginator 11 / WhatsNewGate 6 / TagFeedService 10 / UserProfileViewModel 7 / FollowListViewModel 9 / PostDetailViewModel 4 / TagDetailViewModel 4）・シミュレータ実データで What's New 3ページ表示→セグメント往復→あなた向けにフォロー中(NONAME)＋推定タグ由来の投稿がマージ表示
- ⭐️ **R2 実測完了**: A2（visibility=='followers' + userId in [N]）は **N=8 も N=12 も本番 rules を通過**（error_occurred ゼロ・for_you_feed_loaded 正常）＝公式の「exists() 1リクエスト10回」より実際は緩い（in 分解後の枝ごとに予算が効いている可能性）。**出荷値は余裕を持って 8**（コメントに実測記録済み）。現データではフォロー中12人が上限のため N>12 は測定不能。
- /review-full: 4観点並列レビューをバックグラウンド起動済み（このセッションの tasks dir 参照）。次工程 = dedupe → filter-validity-judge → 統合レポート → ユーザー承認 → keep 対応 → push → PR。

## 追記12（2026-08-20・context-guard 発動によりこのセッション終了・レビュー回収から再開）

### 状態スナップショット
- ブランチ: `機能-あなた向けフィードとホームセグメント` にチェックアウト中・コミット `805a6dc`（push 未実施・PR 未作成）
- メインツリーの未コミット変更（**触らない・コミットしない**）: `.serena/project.yml`（並行セッション由来疑い）＋ 従来の untracked 群 ＋ 本 handoff（untracked）
- シミュレータ（DCFBF2D6）には PR-7 の最終ビルド（chunk 8）がインストール済み・Soumatou ログイン済み
- XcodeBuildMCP session defaults は設定済みだが**次セッションではリセットされる**→ 追記8 の値で再設定（projectPath=`Soramoyou/Soramoyou.xcodeproj`・scheme=`Soramoyou`・simulatorId=`DCFBF2D6-0E1B-4614-893F-8A64FC50103B`・bundleId=`com.yoshidometoru.Soramoyou`）

### 🔄 /review-full ステージ1（4観点並列）= バックグラウンド実行中のまま終了
tasks dir = `/private/tmp/claude-501/-Users-yoshidometoru----iOS---------/e2c5cc9c-20de-47e8-b502-f4dffece2db2/tasks/`
- simplifier: `a730a3baeefa5d733.output`
- general: `a1eb9cf3f9840aa30.output`
- codex: `a4290ed92cdf18f7f.output`
- project-rules: `a8d7a19218cb284c0.output`

各 .output は JSONL（サブエージェント transcript 全文）。**最終 assistant テキストのみ抽出して読むこと**（例: `python3 -c` で JSONL の最後の assistant message を取る。全文 cat はコンテキスト溢れ）。ファイルが未完・空なら該当レビュアーを再起動する。再起動時のプロンプト要点: 対象=`git diff a03628b..805a6dc`・背景（0件ページ禁止の理由/emit前ブロック除外/生取得数で枯渇判定/A1・A2分離=exists()消費/A2 chunk8=実測済み/executeQueryのlastDocument無視/isRefreshingガード/二重ブロックフィルタ意図的/ゲスト非表示/タグ正規化禁止/検証済み51-51green+PostHog着弾）・gap申告必須。codex には背景4点（目的/意図/制約/許容CC）を必ず渡す。

### 次の手順（このまま実行）
1. 4つの .output から結果回収（未完なら再実行）→ dedupe（同根集約）→ `filter-validity-judge` 起動 → 統合レポート提示 → **ユーザー承認を待って** keep 対応（コミットは `805a6dc` に積む）
2. keep 対応後: build_sim + MergedFeedPaginatorTests ほか関連テスト再実行 → push（`git push -u origin 機能-あなた向けフィードとホームセグメント`）→ PR 作成（gh CLI・タイトル「機能: あなた向けフィードとホームセグメント（Wave 4 / PR-7）」・検証済み/未検証を明記: A2 は本番に followers 投稿0件のため内容目視は未実施・rules 通過は PostHog error_occurred ゼロで確認）
3. マージはユーザー GO。追加の Firebase deploy は**不要**（A1/A2 の index は #88 で deploy 済み・B は既存 index・rules 変更なし）
4. PR 本文への申し送り: R2 実測結果（8/12 とも通過・出荷値8）・What's New は本PRが同梱（currentID="2026-08-follow-social"）
5. 残りの独立タスク: 実機削除テスト（ユーザー）／backfill（serviceAccountKey.json 待ち）／issue #90／PR #82・#83 は build 95+ 便

### swiftformat フック対策（再掲・今回も有効だった）
既存ファイル（HomeView.swift 等）の編集は Edit ツールでなく **Bash + python 置換**（churn ゼロを実証済み）。新規ファイルは Write でよい。

## 追記13（2026-08-20・PR-7 /review-full 完遂・PR #91 作成済み）

### ✅ /review-full 完了 — 生22件 → dedupe 18件 → judge keep 12 / reject 6（棄却率33%・でっち上げ0）
- レビュアー内訳: simplifier 0（設計確認済みの0件）／general major2+minor7+nit1／codex high2+medium4+low1／project-rules major1+minor3+nit1
- **keep 対応済み（コミット `c5e6cb1`）**: D4=loadMorePosts の isRefreshing ガード（refresh 中の新 Paginator 先食い・codex 独自の major・ゲート式回帰テスト付き）／D3=空・非枯渇ページ残存時は emit しない＋補充周回上限50（時系列逆転と無限ループの防護・回帰テスト2件）／D2=ForYouFeedViewModelTests 新設4件／D6=HomeView の VM 参照冒頭固定2箇所／D11=for_you_feed_loaded を lastError==nil 時のみ発火／D17=ブロック取得失敗の logError／D13=タイブレークのコメント正確化／D7=A2 のフォロー集合固定を許容制限として文書化／D15=firestore-schema.md にクエリ形状+R2 実測を追記／D16=roadmap.md の Phase 2 完了表記
- reject 6: D5(意図的設計+計装済み)/D8(意図的ワークアラウンド)/D9(修正案が空状態固化の新バグ)/D10(タブ破棄で segment リセット=存在しないCC+修正案がスクロール喪失の新バグ)/D12(文言裁量内)/D18(実装慣習が正)
- ⭐️ filter-validity-judge.md の学習済み例に D10 事例（View ライフサイクルを辿ってから判定）を追記済み
- 判定全文: このセッション scratchpad の pr7-judge-result.md / pr7-dedupe.md / pr7-review-*.md（tasks dir と同じ session）

### ✅ 検証・提出
- build SUCCEEDED（新規警告0）・関連テスト **57/57 green**（新規: MergedFeedPaginator +2 / ForYouFeedViewModel 4）
- push 済み → **[PR #91](https://github.com/kamui00002/soramoyou/pull/91)**（805a6dc + c5e6cb1。⚠️リリース前ゲート=実機削除1回+follower_removed 着弾確認、を本文に明記済み）
- **issue #92 作成済み**（D1=ストリーム並列化・フォロー数増加前に対応）

### 残タスク
1. **PR #91 のマージ判断（ユーザー GO 待ち）**。マージ後の Firebase deploy は不要（index/rules 変更なし）
2. ⚠️ **提出前ゲート**: 実機でフォロワー削除1回（①行が消える ②カウンタ再計算 ③follower_removed 着弾）— What's New が削除を訴求するため必須
3. backfill（serviceAccountKey.json 依然未配置）／issue #90・#92／PR #82・#83 は build 95+ 便
4. マージ後: Obsidian 進捗ログ（📂 プロジェクト/2026-08-20 [進捗ログ] そらもよう フォロー可視化 Wave 1〜4）に追記

## 追記14（2026-08-20・PR #91 マージ完了 = Wave 4 完了）
- 最終確認（keep 対応後ビルド c5e6cb1 をシミュレータで実施）: あなた向けフィード表示・スクロールで追加ページ読込・PostHog エラーゼロ・for_you_feed_loaded 正常（20件/12人/inferred）
- **PR #91 squash マージ済み（main = `4441ec0`・ブランチ削除済み）**。ローカルは main にチェックアウト済み。Firebase deploy 不要（実施していない）
- **Wave 4 完了**。残: ⚠️提出前ゲート（実機削除1回+follower_removed 着弾）／backfill（鍵未配置）／issue #90・#92／PR #82・#83 は build 95+ 便／Wave 5（PR-8）は採用率ゲート

## 追記15（2026-08-20・提出前ゲート D14 クリア = 削除実実行テスト完了）
- ⭐️ **テストアカウントの正体判明**: 表示名「ユーザー」= uid `FvPXCfro4PZ709blRz4HEE8BVbP2` = **apple-review@soramoyou-app.com（審査用デモアカウント）**。publicProfiles の displayName 検索では見つからず、**follows → auth_get_users(uid) の経路で特定**した。このアカウントが Soumatou をフォローしていたため、ログイン不要で削除テストが成立した
- **①②③全部クリア**（詳細は [PR #91 コメント](https://github.com/kamui00002/soramoyou/pull/91#issuecomment-5354354972)）: ①一覧5→4行 ②follows doc 消滅+Soumatou 両カウンタ 5→4+apple-review followingCount 3→2+**stale だった publicProfiles 0→2 自己修復** ③follower_removed 着弾・removed_user_id タクソノミー未登録=パラメータなし実証
- **build 95+ 提出のブロッカー解消**。残: リリース便提出（PR #82/#83 同乗・リリースノート草案の要否をユーザーに確認）／backfill（鍵未配置・ただし apple-review の following 側ドリフトは今回のイベントで自動解消済み）／issue #90・#92／Wave 5
- 副作用の記録: apple-review は Soumatou を**フォローしていない状態**になった（審査デモで必要なら apple-review でログインして再フォロー。フォロー中は残り2人なので「あなた向け」デモは現状でも成立）。なお apple-review は blockedUserIds に Soumatou を含む（元からの状態・今回のテストとは無関係）

## 追記16（2026-08-20・1.9.7 / build 95 審査提出完了 = Waiting For Review）
- **提出フロー完遂**: PR #82/#83 マージ → ブランチ `リリース-1.9.7提出` で pbxproj 1.9.7/95 コミット → xcode-testflight-upload.sh --auto-bump で TestFlight アップロード（Delivery `9086eac0-1206-4017-9d09-b01198572806`・ASC照会 max=94→95 正常）→ processing 完了確認 → prepare → ユーザーGO → **submit 成功 = Waiting For Review**（自動公開設定）
- リリースノート（承認済み・fastlane/metadata/ja/release_notes.txt に保存）: フォロー可視化3点＋改善修正3点の文言
- **版数の main 還流も即実施済み**（PR #93 マージ・main=`8ed4577`）＝1.9.6 の「提出ブランチ止まり→同因再発」の再発防止
- ⚠️ 台帳更新: **1.9.7 は build 95 で審査提出済み（2026-08-20）。次の単発提出は build 96+**
- ⚠️ 反省: submit 成功後に詳細ログ確認目的で submit を再実行してしまった（2回目は「Waiting For Review」で ASC が拒否・実害ゼロ）。**不可逆コマンドの結果確認は再実行ではなく出力ファイルを読むこと**
- **issue #94 作成**: 新規ユーザー向けオンボにフォロー機能の案内が無いギャップ（既存ユーザーは What's New でカバー済み・非ブロッカー）
- 残: 審査結果待ち（承認→自動公開）／承認後は PostHog で 1.9.7 着弾実査／backfill（鍵待ち）／issue #90・#92・#94／Wave 5

## 追記17（2026-08-21・1.9.7 審査承認 = READY_FOR_SALE 確認）
- ASC API 実査（`asc_version_check.make_jwt` 流用・`appStoreVersions?filter[versionString]=1.9.7`）: **state=READY_FOR_SALE / releaseType=AFTER_APPROVAL** → 承認済み・自動公開。⭐️ `filter[versionString]` を付ければ appStoreVersions で最新版が取れる（スクリプト注記の「古い版しか返らない」はフィルタ無しの場合）
- 台帳: **1.9.7 / build 95 = 公開済み（2026-08-21 承認）。次の単発提出は build 96+**
- 残: PostHog で 1.9.7 着弾実査（PostHog MCP が要再認証のため未実施）／backfill（鍵待ち）／issue #90・#92・#94／Wave 5（PR-8・1.9.7 採用率ゲート）

## 追記18（2026-08-23・rageclick 由来の UX 修正 → 1.9.8 / build 96 審査提出）
- **PostHog rageclick 実査 → 原因特定 → 修正 → /review-full → PR #95 マージ → 1.9.8 提出**まで1日で完走
- 発見: 編集画面のフィルター行の右端（横91%・縦82%）に rageclick 6件・4日ぶん集中。原因＝フィルターが「なし」＋10種類＝**11個あるのに5個しか映らない** + `showsIndicators:false` でスクロールバー非表示 + padding で右端がぴったり収まって見える三重苦
- 対処: 右端に `chevron.right` ＋黒フェード（右端まで読み切ると消える）。フィルター行と編集ツール行の両方
- **PR #95 マージ済み（main = `d539b3f`）** ／ **版数還流 PR #96 マージ済み（main = `7862325`）**
- **1.9.8 / build 96 = 2026-08-23 審査提出済み**（Delivery `97d10112-ae73-4062-a4ff-b71f8cc8d0f7`・"Successfully submitted the app for review!"・自動公開）。⚠️**次の単発提出は build 97+**
- レビュー: 生14件→dedupe 12件→judge **keep 4 / reject 8**（棄却率67%・でっち上げ0）。⭐️general(iPad Split View) と codex(iPhone 横向き) が**独立に同じ根本原因へ収束**＝`UIScreen.main.bounds` 基準の誤り
- ⭐️ 再利用可能な知見（コード内コメント＋Obsidian に記録）:
  1. **SwiftUI の preference は `.background`/`.overlay` の中では親に伝播しない**（実測で値0）。GeometryReader は実体として置く。その場で消費する値は overlay 内から直接読んでよい
  2. **判定に `UIScreen.main.bounds` を使うな**（iPad Split View で機能が無言で死ぬ／iPhone 横向きで safe area 分ズレる）。コンテナ自身の幅を使う
  3. **暗い UI に黒フェードは効かない**（明度 25→14 のみ・画素解析で実測）。形のある手がかりが要る
  4. **`.mask` はヒットテストにも効く**→ 装飾は `.overlay` + `allowsHitTesting(false)`
  5. 「見えているか」（画素解析）は「押せるか」（実タップ）を保証しない
- 残: 審査結果待ち／backfill（鍵未配置）／issue #90・#92・#94／Wave 5（PR-8）
