# アカウント削除の申し込みを手で処理する手順 ⭐️☁️

削除の受付ページ（`hosting/delete-account/index.html`・https://soramoyou-ios.web.app/delete-account/ ）からメールで届いた申し込みを、開発者が手で処理するための手順（Kiro android-mvp タスク 26.1）。

- 約束していること：**申し込みから 30 日以内**に削除し、完了をメールで知らせる
- 消す範囲は、アプリの退会と同じもの＋アプリの退会では消えないもの（受付ページの「4. 残るデータ」）。**通報（`reports`）は消さない**（不正利用の防止のため保持すると公開している）
- ⚠️ **削除は取り消せない**。各手順の前に、対象を一覧にして件数を控えてから消す

## 0. 受け付け

1. 申し込みのメールの**送信元のアドレス**で、Firebase コンソール → Authentication → ユーザーを検索し、uid を控える
   - 送信元が登録のアドレスと違う場合は応じない（本人確認ができないため）。その旨を返信する
   - 見つからない場合は「登録が見つからない」と返信する
2. 受け付けたことを返信する（削除する範囲と、30 日以内に完了することを書く）
3. 一部のデータだけの申し込み（例：iOS 版で退会した後の画像だけ）なら、該当する手順だけを行う

## 1. Storage の画像と動画（先に消す。文書に置き場所が書いてあるため）

バケットは `gs://soramoyou-ios.firebasestorage.app`。置き場所は `storage.rules` の一覧のとおり。

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
| 11 | `recommendationNotices` | `recommenderId == uid` |
| 12 | `feedback` | `userId == uid`（アカウントのすべての削除、またはフィードバックの削除の申し込みのとき） |
| 13 | `users/{uid}` | 文書 ID |

- `reports` は消さない
- 本番の文書を読むときは項目名で絞り、トークンを画面に出さない（`firebase-tools` のトークンで REST を使う場合）

## 3. 認証のアカウント

Firebase コンソール → Authentication → 該当のユーザー → 「アカウントを削除」。

## 4. 完了

1. Storage の `ls` と、Firestore の各コレクションの `userId == uid` の数が 0 であることを確かめる（`reports` を除く）
2. 完了をメールで知らせる
3. 処理の記録（受付日・完了日・範囲）を残す。uid やメールアドレスはリポジトリに書かない
