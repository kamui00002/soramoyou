#!/usr/bin/env python3
"""rules_test_storage_followers.py ☁️⭐️

storage.rules のフォロワー限定の画像（posts・thumbnails・originals の followers）を、
Firebase の rules test API で評価する。評価だけを行うので、本番のデータにも deploy 済みのルールにも触れない。
Emulator の同じ内容のテストは functions/postsFollowersStorage.emulator.test.js（CI で回る）。
こちらは Google の本物のルールの仕組みで、同じ約束を確かめる。

使い方（実行はユーザー。Claude は実行しない）:
  python3 scripts/rules_test_storage_followers.py [storage.rules のパス]            # 省略時はリポジトリ直下
  python3 scripts/rules_test_storage_followers.py --mutants [storage.rules のパス]  # 陽性対照（下の MUTANTS）
  401 が返るときは firebase CLI のトークンが古いので、`firebase projects:list > /dev/null` を一度実行してから再実行する。

認証:
  firebase CLI のログイン情報（~/.config/configstore/firebase-tools.json）のアクセストークンを使う。
  トークンは出力しない。

確かめる約束:
  - 読み取り（get）は「本人」か「持ち主をフォローしている人」だけ。
    フォローしている＝follows/{読む人}_{持ち主} の文書がある（firestore.rules の isFollowing と同じ条件）
  - 一覧（list）は誰にも許さない。保存・削除・public・private は今までどおり

ルールの書き方の約束（MUTANTS が文字列で狙うので、ルールはこの形で書く）:
  - 判定はトップレベルの関数 1 つにまとめる（3 か所に同じ式を書かない）:
        function canReadFollowersImage(userId) {
          return isOwner(userId)
                 || (isAuthenticated()
                     && firestore.exists(/databases/(default)/documents/follows/$(request.auth.uid + '_' + userId)));
        }
  - 3 つの match の直後の行に `allow get: if canReadFollowersImage(userId);` を置く（コメントは match の上に書く）

テストの書き方の約束（rules_test_storage_soratomo.py と同じ）:
  - Firestore の読み取りは functionMocks の関数名 "firestore.exists" でモックする。引数は文書のパスの文字列。
    ログインしたケースでは「読む人→持ち主」と「持ち主→読む人」の両方の向きを必ずモックする
    （向きを逆にした壊し方を、エラーでなく条件で見分けるため）
  - モックの無い firestore.exists はエラーで拒否になる。拒否を期待するケースで「エラーで拒否」は期待外れとして数える
  - 未ログインは auth を null で渡す
  - 一覧は、フォルダの中のファイルのパスに method "list" を付けて評価する

確かめられないこと:
  - フォロー解除（文書が消えた後）は、この方式では「文書が無い」と同じ。消える動きそのものは Emulator のテストで見る
  - Storage から Firestore を読む権限（IAM の付与）と、本物の follows の文書の読み取り
  - 要確認: 今のルール（フォローの判定が無い）で流すと、モックが使われない。API がそれを咎めるかは未確認

終了コード: 0 = すべて期待どおり / 1 = 期待外れあり・API 失敗・陽性対照の不足
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

PROJECT_ID = "soramoyou-ios"
BUCKET_PATH = "/b/soramoyou-ios.firebasestorage.app/o/"
FOLLOWS_DOC = "/databases/(default)/documents/follows/"

# 要求の時刻（ルールは見ないが、本番の要求と同じく渡す）
T = "2026-10-16T03:00:00Z"

# 登場人物（全員メールとパスワードでログイン）
OWNER = "owner"        # 写真の持ち主
FOLLOWER = "follower"  # 持ち主をフォローしている
STRANGER = "stranger"  # フォローしていない
REVERSE = "reverse"    # 持ち主の方が reverse をフォローしているだけ（逆向き）

# フォローの関係（読む人, 持ち主）。ここに無い組は「文書が無い」
FOLLOWS = {(FOLLOWER, OWNER), (OWNER, REVERSE)}

FOLLOWERS_DIRS = ["posts", "thumbnails", "originals"]


def jpeg(size):
    return {"contentType": "image/jpeg", "size": size}


def case(name, expect, uid, method, path, upload=None):
    """1 ケース。uid=None は未ログイン。upload は保存する内容（request.resource）で、削除では渡さない"""
    return {"name": name, "expect": expect, "uid": uid, "method": method, "path": path, "upload": upload}


ALLOW, DENY = "ALLOW", "DENY"

CASES = []
for d in FOLLOWERS_DIRS:
    img = d + "/" + OWNER + "/followers/p1.jpg"
    CASES += [
        case(f"{d} 本人が読む", ALLOW, OWNER, "get", img),
        case(f"{d} フォロワーが読む", ALLOW, FOLLOWER, "get", img),
        case(f"{d} フォローしていない他人が読む", DENY, STRANGER, "get", img),
        case(f"{d} 逆向き（持ち主がフォローしているだけ）の人が読む", DENY, REVERSE, "get", img),
        case(f"{d} 未ログインで読む", DENY, None, "get", img),
        case(f"{d} 他人が一覧", DENY, STRANGER, "list", img),
        case(f"{d} フォロワーが一覧", DENY, FOLLOWER, "list", img),
        case(f"{d} 本人が一覧", DENY, OWNER, "list", img),
    ]
CASES += [
    # --- 変えていないルール（posts だけで代表して見る）---
    case("posts 本人が followers へ保存", ALLOW, OWNER, "create", "posts/" + OWNER + "/followers/w1.jpg", jpeg(1000)),
    case("posts フォロワーが持ち主の followers へ保存", DENY, FOLLOWER, "create",
         "posts/" + OWNER + "/followers/w1.jpg", jpeg(1000)),
    case("posts 本人が followers の画像を削除（内容なし）", ALLOW, OWNER, "delete", "posts/" + OWNER + "/followers/p1.jpg"),
    case("posts フォロワーが持ち主の followers の画像を削除", DENY, FOLLOWER, "delete",
         "posts/" + OWNER + "/followers/p1.jpg"),
    case("posts 未ログインで public を読む", ALLOW, None, "get", "posts/" + OWNER + "/public/p1.jpg"),
    case("posts 本人が private を読む", ALLOW, OWNER, "get", "posts/" + OWNER + "/private/p1.jpg"),
    case("posts フォロワーが private を読む", DENY, FOLLOWER, "get", "posts/" + OWNER + "/private/p1.jpg"),
]

# 陽性対照: (名前, [(置き換え元, 置き換え先[, 現れる回数]), ...])。回数を書かない置き換え元はルールに 1 回だけ現れること
FOLLOWS_ID = "$(request.auth.uid + '_' + userId)"
FOLLOWS_EXISTS = "firestore.exists(/databases/(default)/documents/follows/" + FOLLOWS_ID + ")"
ALLOW_GET = "allow get: if canReadFollowersImage(userId);"


def back_to_old(d):
    """その場所だけ、直す前のルール（ログインしていれば誰でも読める）に戻す"""
    head = "match /" + d + "/{userId}/followers/{imageId} {\n      "
    return (f"{d} だけ直す前のルールに戻す", [(head + ALLOW_GET, head + "allow read: if isAuthenticated();")])


MUTANTS = [
    ("フォロー判定を外す", [(FOLLOWS_EXISTS, "true")]),
    ("フォロー判定を常に偽", [(FOLLOWS_EXISTS, "false")]),
    ("フォローの向きを逆にする", [(FOLLOWS_ID, "$(userId + '_' + request.auth.uid)")]),
    ("本人の判定を外す", [("return isOwner(userId)\n             || ", "return ")]),
    # 未ログインでは request.auth が null なので、uid の読み取りがエラーで拒否されて見つかる
    ("ログインの確認を外す", [("|| (isAuthenticated()\n", "|| (true\n")]),
    ("読み取りを全員に許す", [("return isOwner(userId)", "return true || isOwner(userId)")]),
    ("一覧も許す（get を read に）", [(ALLOW_GET, ALLOW_GET.replace("allow get", "allow read"), 3)]),
] + [back_to_old(d) for d in FOLLOWERS_DIRS]


def build_test_case(c):
    # 未ログインは auth を null で渡す（省くと request.auth が「未定義」になり、エラーで拒否される）
    request = {"path": BUCKET_PATH + c["path"], "method": c["method"], "time": T, "auth": None}
    test_case = {"expectation": c["expect"], "request": request}
    if c["uid"]:
        request["auth"] = {"uid": c["uid"], "token": {"firebase": {"sign_in_provider": "password"}}}
        # 両方の向きをモックする（本人のときは同じパスになるので 1 つにまとめる）
        pairs = {(c["uid"], OWNER), (OWNER, c["uid"])}
        test_case["functionMocks"] = [
            {"function": "firestore.exists",
             "args": [{"exactValue": FOLLOWS_DOC + a + "_" + b}],
             "result": {"value": (a, b) in FOLLOWS}}
            for a, b in sorted(pairs)
        ]
    if c["upload"] is not None:
        request["resource"] = c["upload"]
    return test_case


def evaluate(source, token):
    """ルールの本文で全ケースを評価し、rules test API の testResults を返す（通信の失敗・testResults が無いときは None）。
    HTTP が 200 以外なら、その場で終了コード 1 で止める（401 のまま --mutants を続けると、
    全部の壊し方とケースが NG と出て、ルールの問題と見分けがつかないため）"""
    body = json.dumps({
        "source": {"files": [{"name": "storage.rules", "content": source}]},
        "testSuite": {"testCases": [build_test_case(c) for c in CASES]},
    }).encode()
    req = urllib.request.Request(
        f"https://firebaserules.googleapis.com/v1/projects/{PROJECT_ID}:test",
        data=body,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
    )
    # --mutants は 10 回ほど呼ぶので、接続が切れるなどの一時的な失敗は 3 回まで再試行する（HTTP のエラーは再試行しない）
    for attempt in range(3):
        try:
            resp = urllib.request.urlopen(req, timeout=60)
            if resp.status != 200:
                # 4xx・5xx は下の HTTPError に来る。ここは 2xx の 200 以外（ふつうは来ない）
                print("HTTP", resp.status, resp.read().decode()[:600])
                sys.exit(1)
            result = json.load(resp)
            break
        except urllib.error.HTTPError as e:
            print("HTTP", e.code, e.read().decode()[:600])
            if e.code == 401:
                print("トークンが古い。`firebase projects:list > /dev/null` を一度実行してから再実行する")
            sys.exit(1)
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt == 2:
                print("通信の失敗:", e)
                return None
            time.sleep(2)
    if "testResults" not in result:
        # 構文エラーなどはここに来る
        print(json.dumps(result, ensure_ascii=False)[:1500])
        return None
    return result["testResults"]


def is_ok(c, res):
    """期待どおりか。拒否を期待するケースは、エラーでなく条件で拒否されたことまで求める"""
    if res.get("state") != "SUCCESS":
        return False, ""
    errors = [m for m in res.get("debugMessages", []) if "Error" in m]
    if c["expect"] == DENY and errors:
        return False, "（エラーで拒否: " + errors[0][:120] + "）"
    return True, ""


def run_normal(source, token):
    results = evaluate(source, token)
    if results is None:
        return 1
    failures = 0
    for c, res in zip(CASES, results):
        ok, note = is_ok(c, res)
        failures += 0 if ok else 1
        print("OK " if ok else "NG ", f"期待 {c['expect']:5}", "|", c["name"], note)
    print(f"\n合計 {len(CASES)} 件 / 期待どおり {len(CASES) - failures} 件 / 期待外れ {failures} 件")
    return 0 if failures == 0 else 1


def run_mutants(source, token):
    killed_by = {c["name"]: [] for c in CASES}
    problems = 0
    for name, replacements in MUTANTS:
        mutated = source
        for rep in replacements:
            old, new = rep[0], rep[1]
            want = rep[2] if len(rep) > 2 else 1
            count = mutated.count(old)
            if count != want:
                print(f"NG 壊し方「{name}」の置き換え元が {count} 回現れる（{want} 回のはず）: {old[:80]}")
                problems += 1
                break
            mutated = mutated.replace(old, new)
        else:
            results = evaluate(mutated, token)
            if results is None:
                problems += 1
                continue
            flipped = [c["name"] for c, res in zip(CASES, results) if not is_ok(c, res)[0]]
            for case_name in flipped:
                killed_by[case_name].append(name)
            print(("OK " if flipped else "NG "), f"壊し方「{name}」で期待外れ {len(flipped)} 件")
            for case_name in flipped:
                print("     -", case_name)
            problems += 0 if flipped else 1
    # 変えていないルールのケースは、この壊し方では見分けられなくて当然なので数えない
    targets = [c["name"] for c in CASES if "/followers/" in c["path"] and c["method"] in ("get", "list")]
    unkilled = [n for n in targets if not killed_by[n]]
    print(f"\n壊し方 {len(MUTANTS)} 個 / どの壊し方でも期待外れにならない読み取り・一覧のケース {len(unkilled)} 件")
    for case_name in unkilled:
        print("NG  見分けられていない:", case_name)
    return 0 if problems == 0 and not unkilled else 1


def main():
    args = sys.argv[1:]
    mutants = "--mutants" in args
    args = [a for a in args if a != "--mutants"]
    here = os.path.dirname(os.path.abspath(__file__))
    rules_path = args[0] if args else os.path.join(here, "..", "storage.rules")
    source = open(rules_path, encoding="utf-8").read()
    token = json.load(open(os.path.expanduser("~/.config/configstore/firebase-tools.json")))["tokens"]["access_token"]
    return run_mutants(source, token) if mutants else run_normal(source, token)


if __name__ == "__main__":
    sys.exit(main())
