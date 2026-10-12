# アカウント削除の申し込みを手で処理する手順 ⭐️☁️

削除の受付ページ（`hosting/delete-account/index.html`・https://soramoyou-ios.web.app/delete-account/ ）からメールで届いた申し込みを、開発者が手で処理するための手順（Kiro android-mvp タスク 26.1）。

- 約束していること：**申し込みから 30 日以内**に削除し、完了をメールで知らせる
- 消す範囲は、アプリの退会と同じもの＋アプリの退会では消えないもの（受付ページの「4. アプリからの削除では残るデータ」）。**通報（`reports`）は消さない**（不正利用の防止のため保持すると公開している）
- ⚠️ **削除は取り消せない**。各手順の前に、対象を一覧にして件数を控えてから消す

## 0. 受け付け

1. 申し込みが届いたら**すぐに**、メールの**送信元のアドレス**で、Firebase コンソール → Authentication → ユーザーを検索し、uid を控える（受け付けの後に本人がアプリで削除しても、控えた uid で続けられる）
   - 送信元が登録のアドレスと違う場合は応じない（本人確認ができないため）。その旨を返信する
   - 見つからない場合は「登録が見つからない」と返信する。アプリで削除した後の申し込み（残った写真などだけを消してほしい）も、Authentication と `users/{uid}` が消えていて uid をたどれず、本人を確認できないので応じられない旨を返信する（受付ページの「4. アプリからの削除では残るデータ」とポリシーの保存期間に、そう書いてある）
2. 受け付けたことを返信する（削除する範囲と、30 日以内に完了することを書く）
3. アカウントは残したまま一部のデータだけの申し込み（例：フィードバックだけ）なら、該当する手順だけを行う

## 1. Storage の画像と動画（先に消す。文書に置き場所が書いてあるため）

バケットは `gs://soramoyou-ios.firebasestorage.app`。置き場所は `storage.rules` の一覧のとおり。そらともの画像（`soratomo/{groupId}/{uid}/`）はここでは消さない（4. の `delete-user` が消す）。

⚠️ `gcloud` にログインしていないと `ls` は失敗する。**エラーを捨てると（`2>/dev/null`）失敗が「0 件」に見える**ので捨てない（2026-10-11 に実際に起きた）。最初に、有るはずの物で `ls` が通ることを確かめる。

```bash
gcloud auth login                       # 初回だけ（ブラウザでログイン）
gcloud config set project soramoyou-ios
TARGET_UID=<控えた uid>   # zsh では UID は書き換えられない特別な変数なので別の名前にする
B=gs://soramoyou-ios.firebasestorage.app
# 有るはずの物（どの利用者の物でもよい・既存の投稿の画像など）で ls が通ることを先に確かめる
gcloud storage ls "$B/posts/" | head -3
# 一覧と件数を控える（「matched no objects」は 0 件。それ以外のエラーが出たら止める）
for p in posts thumbnails originals drafts livingSky; do echo "== $p"; gcloud storage ls -r "$B/$p/$TARGET_UID/"; done
gcloud storage ls "$B/users/$TARGET_UID/profile/"
# 控えた後で消す（取り消せない）。uid が空だと全員の置き場所を指すので、空なら丸ごと実行しない
# （複数行を貼ると、途中の行で止まっても次の行は動くため、1 つの if にまとめてある）
if [ -n "$TARGET_UID" ]; then
  for p in posts thumbnails originals drafts livingSky; do gcloud storage rm -r "$B/$p/$TARGET_UID/"; done
  gcloud storage rm -r "$B/users/$TARGET_UID/profile/"
else
  echo "uid が空なので止めた"
fi
```

## 2. Firestore の文書

アプリの退会と同じ順に消す。相手の投稿のカウンタ（いいね数・コメント数）は、消した分だけ 1 ずつ減らす（アプリの退会と同じ扱い）。

| 順 | 対象 | 探し方 |
|---|---|---|
| 1 | `publicProfiles/{uid}` | 文書 ID |
| 2 | `follows` | `followerId == uid` と `followeeId == uid` の両方（相手のフォロー数は `onFollowDeleted` が数え直す） |
| 3 | `likes` | `userId == uid`。消すたびに、対象の投稿の `likesCount` を 1 減らす（0 未満にしない） |
| 4 | `comments` | `userId == uid`。消すたびに、対象の投稿の `commentsCount` を 1 減らす |
| 5 | `posts` | `userId == uid` |
| 6 | `drafts` | `userId == uid` |
| 7 | `users/{uid}/favorites/*` | サブコレクション |
| 8 | `collections`・`collectionItems` | `userId == uid` |
| 9 | `livingSkyJobs`・`skyMotionPurchases` | `userId == uid` |
| 10 | `livingSkyUsage/{uid}`・`skyMotionBalance/{uid}` | 文書 ID |
| 11 | `recommendationNotices` | `recommenderId == uid` と `ownerId == uid` の両方（おすすめした側とされた側。クライアントからは消せないので、アプリの退会では残る） |
| 12 | `feedback` | `userId == uid`（アカウントのすべての削除、またはフィードバックの削除の申し込みのとき）。消す前に各文書の `createdAt` を控え、下の「Discord の写し」も消す |
| 13 | `users/{uid}` | 文書 ID |

- `reports` は消さない
- Discord の写し：`feedback` の文書ができると、`notifyFeedbackToDiscord`（`functions/index.js`）が種別・本文・アプリのバージョン・端末・ユーザー ID を開発者の Discord のフィードバックのチャンネルへ送っている。控えた `createdAt` の時刻の投稿を探し、「ユーザーID」の欄が uid と同じことを確かめてから消す（ポリシーの第三者の 6 番に書いてある送信。消さないと、削除を約束したフィードバックが Discord に残る）
- 本番の文書を読むときは項目名で絞り、トークンを画面に出さない（`firebase-tools` のトークンで REST を使う場合）

## 3. 認証のアカウント

Firebase コンソール → Authentication → 該当のユーザー → 「アカウントを削除」。

- 0. で控えた uid のアカウントが既に無ければ（受け付けの後に本人がアプリで削除した）、ここは飛ばして 4. へ進む

## 4. そらとものデータ（3. の後に行う）

表（2.）と Storage の手順（1.）は、そらとも（`soratomoUsers`・グループの中のメンバーと投稿・`soratomo/{groupId}/{uid}/` の画像）を扱わない。アプリの退会は先にそらとものデータを消すが、この手順では `scripts/soratomo-admin.js` の `delete-user` で消す。6 時間ごとの定期実行の掃除に任せきりにしない（完了のメールの時点で残りうるため。消し残しは 5. で確かめる）。

- `delete-user` は **Auth のアカウントがあると拒否する**ので、3. の後に行う
- 使い方の正本はスクリプトの頭のコメント。要点：
  - 認証は ADC（`gcloud auth application-default login`。Auth の Admin API で quota project を求められたら `gcloud auth application-default set-quota-project soramoyou-ios`）。鍵ファイルは使わない
  - `functions/` で `npm install` 済みであること。リポジトリ直下で実行する
  - エミュレーターを指す環境変数（名前が `_EMULATOR_HOST` で終わるもの）が 1 つでもあると、何もせずに止まる
  - 出すのは内部 ID と件数だけ（名前・キャプション・画像・メールアドレスは出さない）
- ⚠️ どちらのコマンドも本番のデータに対して動く（読み取りだけの `find-orphans` も本番を読む）。Claude に実行させるときは、開発者が GO を出してから
- 通報の記録（`soratomoReports`）は消さない（`reports` と同じ。共通の削除も触れない）

```bash
# 1) 対象の uid が「アカウントの無い uid」に出ること・データの残るグループ ID を控える
node scripts/soratomo-admin.js find-orphans --deep
# 2) 消す（--group は 1) で控えたグループごとに繰り返す。無ければ付けない）
node scripts/soratomo-admin.js delete-user "$TARGET_UID" --group <groupId> --group <groupId>
```

- 対象の uid が 1) に出なくても 2) は実行してよい（そらともを使っていない人は、何も消さずに「完了: はい」になる）
- 出力の「完了: はい」を確かめる。「完了: いいえ」は 10 分の予算で止まっただけなので、同じコマンドをもう一度実行する（二重には消えず、続きから消える）
- 「❌ 失敗しました: …」が出たら、出た code で原因（ADC のログイン・quota project など）を直してから、同じコマンドをもう一度実行する
- 「❌ Auth のアカウントがあるので消さない」が出たら、3. が済んでいない

## 5. 完了

1. 消し残しが無いことを確かめる（`reports`・`soratomoReports` は残す）
   - Storage：1. の `ls` がすべて 0 件
   - Firestore：2. の表の「探し方」のとおりに、各行が 0 件（文書 ID の行は、その文書が無いこと）
   - Discord：控えた `createdAt` の投稿が、フィードバックのチャンネルに残っていないこと
   - そらとも：`find-orphans --deep` をもう一度実行し、対象の uid が出ないこと。「soratomoGroups の下で ID の形でないグループ」の行も出ていないこと
   - 対象の uid が「データの残るグループ: （なし）」で出たら、そらともで利用停止中だった人の停止の記録（`soratomoUsers/{uid}`）が残っている（`delete-user` は停止の記録を消さない）。6 時間ごとの定期実行が消すので、その後にもう一度 `find-orphans --deep` を実行し、出なくなってから 2. へ進む
2. 完了をメールで知らせる
3. 処理の記録（受付日・完了日・範囲）を残す。uid やメールアドレスはリポジトリに書かない
