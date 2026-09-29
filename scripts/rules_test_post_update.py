#!/usr/bin/env python3
"""rules_test_post_update.py ☁️

firestore.rules の「他人による投稿の update」を Firebase の rules test API で評価する。
評価だけを行うので、本番のデータにも deploy 済みのルールにも触れない。

なぜ必要か:
  isCountOnlyUpdate() は「キーの数」と一部のフィールドしか固定していなかったため、
  ログインしていれば（匿名でも）他人の投稿の originalImages / postId などを書き換えられた。
  - postId を別の投稿の ID にすると、持ち主がその投稿を消したときに別の投稿が消える
  - originalImages の storagePath に持ち主の別画像のパスを入れると、
    持ち主が投稿を消したときに本人の権限でその画像まで消える
  → 「変わったキーが likesCount / commentsCount だけ」であることを rules で強制し、
    その効き目をここで確かめる。

使い方:
  python3 scripts/rules_test_post_update.py [firestore.rules のパス]   # 省略時はリポジトリ直下
  401 が返るときは firebase CLI のトークンが古いので、`firebase projects:list` を一度実行してから再実行する。

認証:
  firebase CLI のログイン情報（~/.config/configstore/firebase-tools.json）のアクセストークンを使う。
  トークンは出力しない。

終了コード: 0 = すべて期待どおり / 1 = 期待外れあり・API 失敗
"""
import json
import os
import sys
import urllib.error
import urllib.request

PROJECT_ID = "soramoyou-ios"
POST_PATH = "/databases/(default)/documents/posts/p1"
OWNER, OTHER = "owner", "other"

# 既存の投稿（いいね・コメント数つき・originalImages あり）
BASE_POST = {
    "postId": "p1",
    "userId": OWNER,
    "images": [{"url": "u", "storagePath": "posts/owner/public/a.jpg"}],
    "originalImages": [{"url": "o", "storagePath": "originals/owner/public/a.jpg"}],
    "visibility": "public",
    "createdAt": 1,
    "updatedAt": 1,
    "caption": "c",
    "likesCount": 3,
    "commentsCount": 2,
}


def changed(base, **fields):
    """base の一部のフィールドを書き換えた新しいデータを返す"""
    data = dict(base)
    data.update(fields)
    return data


# originalImages を持たない投稿（合成投稿など）
POST_WITHOUT_ORIGINALS = {k: v for k, v in BASE_POST.items() if k != "originalImages"}
# updatedAt を消して originalImages を足す＝キーの数は変わらない書き換え
SWAPPED_KEYS = {k: v for k, v in POST_WITHOUT_ORIGINALS.items() if k != "updatedAt"}
SWAPPED_KEYS["originalImages"] = [{"url": "o", "storagePath": "users/owner/profile/profile.jpg"}]

# (名前, 期待, 書き込む人, 既存データ, 書き込み後のデータ)
CASES = [
    # 攻撃: すべて拒否されるべき
    ("攻撃 他人が originalImages の storagePath を持ち主の別画像へ", "DENY", OTHER, BASE_POST,
     changed(BASE_POST, originalImages=[{"url": "o", "storagePath": "posts/owner/public/OTHER.jpg"}])),
    ("攻撃 他人が postId を別の投稿の ID へ", "DENY", OTHER, BASE_POST, changed(BASE_POST, postId="p2")),
    ("攻撃 他人が updatedAt を消して originalImages を足す", "DENY", OTHER, POST_WITHOUT_ORIGINALS, SWAPPED_KEYS),
    ("攻撃 他人が いいね+1 と同時に originalImages も書き換え", "DENY", OTHER, BASE_POST,
     changed(BASE_POST, likesCount=4, originalImages=[{"url": "o", "storagePath": "posts/owner/public/OTHER.jpg"}])),
    # 正規: アプリが他人の投稿に書くのは 1 つのキーの ±1 だけ（FirestoreService の FieldValue.increment）
    ("正規 他人のいいね +1", "ALLOW", OTHER, BASE_POST, changed(BASE_POST, likesCount=4)),
    ("正規 他人のいいね取り消し -1", "ALLOW", OTHER, BASE_POST, changed(BASE_POST, likesCount=2)),
    ("正規 他人のコメント +1", "ALLOW", OTHER, BASE_POST, changed(BASE_POST, commentsCount=3)),
    ("正規 他人のコメント削除 -1", "ALLOW", OTHER, BASE_POST, changed(BASE_POST, commentsCount=1)),
    ("正規 持ち主が自分の投稿にいいね +1", "ALLOW", OWNER, BASE_POST, changed(BASE_POST, likesCount=4)),
    # 対照: 修正前から拒否されていたもの（変わらないことの確認）
    ("対照 他人が caption を書き換え", "DENY", OTHER, BASE_POST, changed(BASE_POST, caption="x")),
    ("対照 他人がいいねを +2", "DENY", OTHER, BASE_POST, changed(BASE_POST, likesCount=5)),
    ("対照 未ログインでいいね +1", "DENY", None, BASE_POST, changed(BASE_POST, likesCount=4)),
]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    rules_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "firestore.rules")
    source = open(rules_path, encoding="utf-8").read()
    token = json.load(open(os.path.expanduser("~/.config/configstore/firebase-tools.json")))["tokens"]["access_token"]

    test_cases = []
    for _, expectation, uid, existing, new_data in CASES:
        request = {"path": POST_PATH, "method": "update", "resource": {"data": new_data}}
        if uid:
            request["auth"] = {"uid": uid}
        test_cases.append({"expectation": expectation, "request": request, "resource": {"data": existing}})

    body = json.dumps({
        "source": {"files": [{"name": "firestore.rules", "content": source}]},
        "testSuite": {"testCases": test_cases},
    }).encode()
    req = urllib.request.Request(
        f"https://firebaserules.googleapis.com/v1/projects/{PROJECT_ID}:test",
        data=body,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
    )
    try:
        result = json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, e.read().decode()[:600])
        return 1

    failures = 0
    for (name, expectation, *_), res in zip(CASES, result["testResults"]):
        ok = res.get("state") == "SUCCESS"
        failures += 0 if ok else 1
        print("OK " if ok else "NG ", f"期待 {expectation:5}", "|", name)
    print(f"\n合計 {len(CASES)} 件 / 期待どおり {len(CASES) - failures} 件 / 期待外れ {failures} 件")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
