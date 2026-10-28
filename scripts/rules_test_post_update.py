#!/usr/bin/env python3
"""rules_test_post_update.py ☁️

firestore.rules の「他人による投稿の update」と「写真・原画像の多い投稿の作成・持ち主の再編集」を
Firebase の rules test API で評価する。
評価だけを行うので、本番のデータにも deploy 済みのルールにも触れない。

なぜ必要か:
  isCountOnlyUpdate() は「キーの数」と一部のフィールドしか固定していなかったため、
  ログインしていれば（匿名でも）他人の投稿の originalImages / postId などを書き換えられた。
  - postId を別の投稿の ID にすると、持ち主がその投稿を消したときに別の投稿が消える
  - originalImages の storagePath に持ち主の別画像のパスを入れると、
    持ち主が投稿を消したときに本人の権限でその画像まで消える
  → 「変わったキーが likesCount / commentsCount だけ」であることを rules で強制し、
    その効き目をここで確かめる。

  写真 10 枚・原画像 10 個の作成と再編集:
  ルールが 1 回の評価で数える式の数には上限（1,000）がある。エミュレーターの数え方が本番と同じとは
  限らないので、本番の仕組みでも通ることをここで確かめる。

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

# Storage のダウンロード URL と同じ形（本番の現物と同じ :443 付き。token は作りもの）
STORAGE_URL = ("https://firebasestorage.googleapis.com:443/v0/b/soramoyou-ios.firebasestorage.app/o/"
               "posts%2Fowner%2Fpublic%2Fa.jpg?alt=media&token=0a1b2c3d-4e5f")


def image_list(n, thumbnail):
    """写真・原画像の配列（アプリの ImageInfo と同じ項目）。thumbnail が False なら thumbnail の項目を入れない"""
    entries = []
    for i in range(n):
        entry = {"url": STORAGE_URL, "width": 1080, "height": 1440, "order": i,
                 "storagePath": f"posts/owner/public/{i}.jpg"}
        if thumbnail:
            entry["thumbnail"] = STORAGE_URL
        entries.append(entry)
    return entries


# アプリが書く形（写真は thumbnail あり・原画像は thumbnail なし）の投稿
def post_with(n_images, n_originals):
    return changed(BASE_POST, images=image_list(n_images, True), originalImages=image_list(n_originals, False))


# (名前, 期待, 書き込む人, 既存データ, 書き込み後のデータ)。既存データが None なら作成（create）、あれば更新（update）
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
    # 退会処理の段 B（FirestoreService.deleteUserData）は「カウント更新は公開範囲を見ない」ことに依存している
    ("正規 他人が非公開投稿のいいねを -1（退会処理の段 B）", "ALLOW", OTHER, changed(BASE_POST, visibility="private"),
     changed(BASE_POST, visibility="private", likesCount=2)),
    # 対照: 修正前から拒否されていたもの（変わらないことの確認）
    ("対照 他人が caption を書き換え", "DENY", OTHER, BASE_POST, changed(BASE_POST, caption="x")),
    ("対照 他人がいいねを +2", "DENY", OTHER, BASE_POST, changed(BASE_POST, likesCount=5)),
    ("対照 未ログインでいいね +1", "DENY", None, BASE_POST, changed(BASE_POST, likesCount=4)),
    # 写真・原画像の多い投稿（持ち主の作成と再編集）
    ("正規 持ち主が写真 10 枚・原画像 10 個で投稿を作成", "ALLOW", OWNER, None, post_with(10, 10)),
    ("正規 持ち主の再編集で写真 10 枚・原画像 10 個に替える", "ALLOW", OWNER, post_with(1, 1), post_with(10, 10)),
    ("対照 持ち主が写真 10 枚・原画像 1 個で投稿を作成", "ALLOW", OWNER, None, post_with(10, 1)),
]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    rules_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "firestore.rules")
    source = open(rules_path, encoding="utf-8").read()
    token = json.load(open(os.path.expanduser("~/.config/configstore/firebase-tools.json")))["tokens"]["access_token"]

    test_cases = []
    for _, expectation, uid, existing, new_data in CASES:
        method = "create" if existing is None else "update"
        request = {"path": POST_PATH, "method": method, "resource": {"data": new_data}}
        if uid:
            request["auth"] = {"uid": uid}
        test_case = {"expectation": expectation, "request": request}
        if existing is not None:
            test_case["resource"] = {"data": existing}
        test_cases.append(test_case)

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
        if not ok:
            # 断られた理由（式の数の上限など）を切り分けるため、API が返した説明と位置を短く出す
            for message in res.get("debugMessages", [])[:3]:
                print("      理由:", str(message)[:300])
            if res.get("errorPosition"):
                print("      位置:", json.dumps(res["errorPosition"], ensure_ascii=False)[:200])
    print(f"\n合計 {len(CASES)} 件 / 期待どおり {len(CASES) - failures} 件 / 期待外れ {failures} 件")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
