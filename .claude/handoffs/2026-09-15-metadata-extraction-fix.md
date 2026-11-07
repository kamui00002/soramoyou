# 引き継ぎノート: 投稿メタデータ抽出の是正（2026-09-15）

## 状況
- 計画は承認済み: `~/.claude/plans/system-reminder-you-are-operating-snazzy-wilkes.md`（Artifact: https://claude.ai/artifact/Y5ozDNcXm1HqJGSZPn1Bh8）。決定事項・各 PR の仕様・テスト・検証手順はすべてそこにある。**まずこれを読む。**
- メモリ: `~/.claude/projects/-Users-yoshidometoru----iOS---------/memory/project-metadata-extraction-fix-2026-09.md`（MEMORY.md にポインタ済み）。
- 実装は 2 本のバックグラウンドエージェントに委譲中（引き継ぎ時点で完了通知は未着）:
  - **PR-A**（EXIF 経路・fable）: ワークツリー `.claude/worktrees/favorites-review-commit-33b00c`、ブランチ `修正-撮影日時をEXIFから取得`（origin/main `0a24956` から作成済み）。手順=実装 → `build_sim`/`test_sim` → シミュレータで EXIF 付き JPEG を `simctl addmedia` して投稿情報画面に撮影時刻が出るか確認（本番投稿はしない）→ `review-orchestrator` → push → `gh pr create`。
  - **PR-C**（バックフィルスクリプト・sonnet）: ワークツリー `.claude/worktrees/agent-adf9c020ffe1ee539`（locked）、ブランチ `改善-投稿capturedAtバックフィルスクリプト`。手順=`scripts/backfill-post-captured-at.js` 新規 → `node --check` + `node -e` で timeOfDayInTokyo / sourceTimestamp を assert → `review-orchestrator` → push → PR。鍵は取得しない。
- **PR-C = PR #108 作成済み（OPEN）**。鍵配置後にユーザーが dry-run → `--apply --limit 3` → 全件。
- **PR-A = PR #109 squash マージ済み（2026-09-16 02:17 JST・main `930af7f`）**（旧 commit `cc48db9`・14 ファイル）。/review-full keep 6 件対応済み・build 成功（新規警告ゼロ）・変更関連 13 スイート 145 件中 142 成功（失敗 3 件は既知 2＋本番 Firestore 権限拒否のサインアップ 1）・シミュレータで EXIF 付き JPEG を選んで投稿情報画面に「撮影時刻 2026/03/15 18:05・時間帯 夕方」表示を確認（写真権限なし＝EXIF 経路・投稿はしていない）。**残＝マージ判断はユーザー → マージ後に本番投稿で Firestore の capturedAt / timeOfDay / images[0].externalEditInfo.exifCapturedAt と post_completed の captured_at_source を実査 → PR-B 着手**。
- opus はセッション上限（5:40 JST 復帰）で使えず、fable/sonnet で代替した。

## 残タスク（順番）
1. PR-A / PR-C の完了を確認する（`gh pr list --head 修正-撮影日時をEXIFから取得` / `--head 改善-投稿capturedAtバックフィルスクリプト`。PR が無ければ各ワークツリーの `git log origin/main..HEAD` と `git status` で到達点を見る）。
2. 検収は証拠で: `build_sim` の警告数、`test_sim` の pass/fail、レビュー keep の対応 diff、実データ確認のスクショ。「報告は証拠でない」。
3. PR-A の本番ハッピーパス（ユーザー実施 or ログイン済みシミュレータ）: カメラ写真を投稿 → Firestore doc に `capturedAt` / `timeOfDay` / `images[0].externalEditInfo.exifCapturedAt`。`post_completed` に `captured_at_source: exif`。
4. PR-A マージ後に **PR-B**（空マスク色分析）を計画の PR-B 節どおり着手（ブランチ `改善-空の色と色温度を空領域から抽出`、陽性対照テスト＝夕焼け＋青い地上で masked <3500K / unmasked >6000K）。
5. PR-C は `serviceAccountKey.json` をユーザーがリポジトリ直下に置いてから dry-run → `--apply --limit 3` → 全件 → 再実行で candidates 0。
6. 版数還流・提出時にリリースノート 1 行（「撮影時刻と時間帯が正しく記録されるようになりました」「空の色と色温度を写真の空の部分から求めるようにしました」）。What's New は出さない。
7. 配布後: PostHog で `captured_at_source` / `colors_from_sky` を見て、不具合3（SkyTypeClassifier の閾値・上部 60% 矩形のマスク移行）を再評価。

## 注意点
- このワークツリーには `GoogleService-Info.plist` が無い。ビルド前に本体 `Soramoyou/Soramoyou/GoogleService-Info.plist` をコピー（中身は表示しない）。
- `.claude/worktrees/` は gitignore 済み（Xcode 同期の巻き込みなし）。PR-C のワークツリーはエージェント終了後に自動整理されるはずだが、残っていれば `git worktree remove` で片付ける。
- Edit 整形フックが無関係な行を書き換えることがある → diff を毎回確認。
- 検証コマンドは `~/.claude/build-commands.md`、XcodeBuildMCP は `session_show_defaults` で projectPath がワークツリーを指すか確認。
