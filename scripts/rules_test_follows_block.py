#!/usr/bin/env python3
"""rules_test_follows_block.py ☁️⭐️

firestore.rules の follows の作成（ブロックされた人は、ブロックした人をフォローできない・監査 2-3）を、
Firebase の rules test API で評価する。評価だけを行うので、本番のデータにも deploy 済みのルールにも触れない。
Emulator の同じ内容のテストは functions/followsBlockRules.emulator.test.js（CI で回る）。
こちらは Google の本物のルールの仕組みで、同じ約束を確かめる。

使い方（実行はユーザー。Claude は実行しない）:
  python3 scripts/rules_test_follows_block.py [firestore.rules のパス]            # 省略時はリポジトリ直下
  python3 scripts/rules_test_follows_block.py --mutants [firestore.rules のパス]  # 陽性対照（下の MUTANTS）
  401 が返るときは firebase CLI のトークンが古いので、`firebase projects:list > /dev/null` を一度実行してから再実行する。

認証:
  firebase CLI のログイン情報（~/.config/configstore/firebase-tools.json）のアクセストークンを使う。
  トークンは出力しない。

確かめる約束:
  - follows/{自分}_{相手} を作れないのは、相手の users/{相手}.blockedUserIds に自分がいるときだけ
  - 見るのは相手の一覧だけ（ブロックした本人が、ブロックした相手をフォローするのは作れる）
  - 相手の users 文書が無い・blockedUserIds の項目が無い・空のときは作れる
    （一覧は users 文書の中にあるので、無い＝誰もブロックしていない。登録の途中で users を作りそこねた人もいる）
  - 中身のフォロワーが他人・文書の ID と中身の食い違い・未ログイン・欄の不足は今までどおり拒否
  - ブロックの確認が頼っている約束（緩めると確認をすり抜けられる）: 本人以外は他人の blockedUserIds を
    書き換えられない・本人以外は他人の users 文書を消せない（文書が無い＝許可に持ち込めない）・
    follows は作ったあとに書き換えられない（followeeId を変えて迂回できない）

ルールの書き方の約束（MUTANTS が文字列で狙うので、ルールはこの形で書く）:
  - 判定はトップレベルの関数 1 つにまとめる:
        function isNotBlockedByFollowee(followeeId) {
          let followeePath = /databases/$(database)/documents/users/$(followeeId);
          return !exists(followeePath)
                 || !(request.auth.uid in get(followeePath).data.get('blockedUserIds', []));
        }
  - follows の allow create の最後の行を `&& isNotBlockedByFollowee(request.resource.data.followeeId);` にする
    （ほかの条件で落ちる要求では users を読まない＝読み取りの費用がかからない）

テストの書き方の約束（rules_test_soratomo.py・rules_test_storage_followers.py と同じ）:
  - Firestore の読み取りは functionMocks の "exists" と "get" でモックする。引数は文書のパスの文字列。
    ログインしたケースでは「自分」と「相手」の両方の users をモックする
    （向きを逆にした壊し方を、エラーでなく条件で見分けるため）
  - 文書が無い人は exists を false にし、get はモックしない（正しいルールは get まで進まない。
    進む壊し方はモックの無い get がエラーになって見つかる）
  - モックの無い読み取りはエラーで拒否になる。拒否を期待するケースで「エラーで拒否」は期待外れとして数える
  - 未ログインは auth を null で渡す

確かめられないこと:
  - 本物の users の文書の読み取り（モックの値を返しているだけ）。読めていることは Emulator のテストで見る
  - 要確認: get のモックの返り値の形（value に {"data": {...}} を入れる）。Google の文書の例と同じ形のつもり。
    形が違うと、許可を期待するケースがエラーで拒否されて NG になるので、黙って緑にはならない
  - 要確認: 今のルール（ブロックの判定が無い）で流すと、モックが使われない。API がそれを咎めるかは未確認

終了コード: 0 = すべて期待どおり / 1 = 期待外れあり・API 失敗・陽性対照の不足
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

PROJECT_ID = "soramoyou-ios"
D = "/databases/(default)/documents"

# 要求の時刻（ルールは見ないが、本番の要求と同じく渡す）と、フォローの作成日時
T = "2026-10-16T03:00:00Z"

# 登場人物（全員メールとパスワードでログイン）
BLOCKER = "blocker"             # BLOCKED をブロックしている
BLOCKED = "blocked"             # BLOCKER にブロックされている（自分の文書に blockedUserIds の項目は無い）
STRANGER = "stranger"           # 誰にもブロックされていない
NO_FIELD = "nofield"            # users はあるが blockedUserIds の項目が無い
EMPTY_LIST = "emptylist"        # blockedUserIds が空の配列
BLOCKS_OTHERS = "blocksothers"  # 関係の無い人だけをブロックしている
NO_DOC = "nodoc"                # users 文書が無い

# users の文書の中身。ここに無い人は「文書が無い」
USERS = {
    BLOCKER: {"id": BLOCKER, "blockedUserIds": [BLOCKED]},
    BLOCKED: {"id": BLOCKED},
    STRANGER: {"id": STRANGER},
    NO_FIELD: {"id": NO_FIELD},
    EMPTY_LIST: {"id": EMPTY_LIST, "blockedUserIds": []},
    BLOCKS_OTHERS: {"id": BLOCKS_OTHERS, "blockedUserIds": ["someone"]},
}

ALLOW, DENY = "ALLOW", "DENY"


def follow_data(follower, followee, omit=()):
    """follows の文書の中身（アプリの Follow.toFirestoreData と同じ 3 項目）。omit に書いた項目は入れない"""
    data = {"followerId": follower, "followeeId": followee, "createdAt": T}
    return {k: v for k, v in data.items() if k not in omit}


def case(name, expect, uid, path, method, data=None, existing=None, mock_uids=(), target=True):
    """1 ケース。uid=None は未ログイン。data は書き込んだ後の中身（request.resource）、existing は今の中身（resource）。
    mock_uids は users をモックする人（ログインした本人は必ず足す）。
    target=False は陽性対照の数に入れないケース（変えていないルール・本人の対照）"""
    return {"name": name, "expect": expect, "uid": uid, "path": path, "method": method, "data": data,
            "existing": existing, "mock_uids": set(mock_uids), "target": target}


def create(name, expect, uid, doc_id, data, target=True):
    """follows/{doc_id} を作るケース。中身の相手と、文書の ID の相手の users をモックする"""
    return case(name, expect, uid, D + "/follows/" + doc_id, "create", data=data,
                mock_uids={data["followeeId"], doc_id.split("_", 1)[1]}, target=target)


def follow(name, expect, follower, followee):
    """follower が followee をフォローする、ふつうの形のケース"""
    return create(name, expect, follower, follower + "_" + followee, follow_data(follower, followee))


def without_blocked(owner):
    """users/{owner} の中身から、blockedUserIds を空にしたもの（一覧から全員を取り除いた後）"""
    return dict(USERS[owner], blockedUserIds=[])


CASES = [
    # --- ブロック ---
    follow("ブロックされた人が、ブロックした人をフォロー", DENY, BLOCKED, BLOCKER),
    follow("ブロックされていない人が、ブロックしている人（ほかの人を）をフォロー", ALLOW, STRANGER, BLOCKER),
    follow("ブロックした本人が、ブロックした相手をフォロー（見るのは相手の一覧だけ）", ALLOW, BLOCKER, BLOCKED),
    # --- 相手の一覧が無い・空 ---
    follow("相手の users に blockedUserIds の項目が無い", ALLOW, STRANGER, NO_FIELD),
    follow("相手の blockedUserIds が空", ALLOW, STRANGER, EMPTY_LIST),
    follow("相手が関係の無い人だけをブロック", ALLOW, STRANGER, BLOCKS_OTHERS),
    follow("相手の users 文書が無い（一覧が無い＝誰もブロックしていない）", ALLOW, STRANGER, NO_DOC),
    # --- 変えていないルール ---
    # 文書の ID は自分のものにして、中身のフォロワーだけを他人にする（ID の確認でなく、名義の確認で落ちることを見る）
    create("中身のフォロワーが他人", DENY, STRANGER, STRANGER + "_" + EMPTY_LIST,
           follow_data(NO_FIELD, EMPTY_LIST), target=False),
    create("文書の ID と中身の相手が食い違う", DENY, STRANGER, STRANGER + "_" + NO_FIELD,
           follow_data(STRANGER, EMPTY_LIST), target=False),
    create("未ログインで作る", DENY, None, STRANGER + "_" + NO_FIELD,
           follow_data(STRANGER, NO_FIELD), target=False),
    create("createdAt が無い", DENY, STRANGER, STRANGER + "_" + NO_FIELD,
           follow_data(STRANGER, NO_FIELD, omit=("createdAt",)), target=False),
    # --- ブロックの確認が頼っている約束（users の update・delete と follows の update）---
    case("約束: ブロックされた人が、相手の blockedUserIds から自分を消す", DENY, BLOCKED,
         D + "/users/" + BLOCKER, "update", data=without_blocked(BLOCKER), existing=USERS[BLOCKER]),
    # 上の拒否が「本人でないから」であることの対照（同じ書き換えを本人がすると通る）
    case("約束の対照: 本人が、自分の blockedUserIds から取り除く", ALLOW, BLOCKER,
         D + "/users/" + BLOCKER, "update", data=without_blocked(BLOCKER), existing=USERS[BLOCKER], target=False),
    case("約束: ブロックされた人が、相手の users 文書を消す", DENY, BLOCKED,
         D + "/users/" + BLOCKER, "delete", existing=USERS[BLOCKER]),
    case("約束の対照: 本人が、自分の users 文書を消す", ALLOW, BLOCKER,
         D + "/users/" + BLOCKER, "delete", existing=USERS[BLOCKER], target=False),
    case("約束: 作った本人が、フォローの followeeId を書き換える", DENY, STRANGER,
         D + "/follows/" + STRANGER + "_" + NO_FIELD, "update",
         data=follow_data(STRANGER, BLOCKER), existing=follow_data(STRANGER, NO_FIELD), mock_uids={NO_FIELD, BLOCKER}),
]

# 陽性対照: (名前, [(置き換え元, 置き換え先), ...])。置き換え元はルールに 1 回だけ現れること
FN_PATH = "let followeePath = /databases/$(database)/documents/users/$(followeeId);"
NOT_EXISTS = "return !exists(followeePath)\n             || "
IN_LIST = "request.auth.uid in get(followeePath).data.get('blockedUserIds', [])"
CALL = "\n                    && isNotBlockedByFollowee(request.resource.data.followeeId);"
FOLLOWER_CHECK = "\n                    && request.resource.data.followerId == request.auth.uid"

MUTANTS = [
    ("ブロックの確認を外す", [(CALL, ";")]),
    ("ブロックの確認を常に偽", [(CALL, "\n                    && false;")]),
    ("相手でなく自分の一覧を見る（向きが逆）",
     [(FN_PATH, FN_PATH.replace("$(followeeId)", "$(request.auth.uid)")),
      (IN_LIST, IN_LIST.replace("request.auth.uid in", "followeeId in"))]),
    ("否定を外す（ブロックされた人だけ通す）", [("|| !(" + IN_LIST + ")", "|| (" + IN_LIST + ")")]),
    ("既定値を外す（項目が無い相手でエラー）", [(".data.get('blockedUserIds', [])", ".data.blockedUserIds")]),
    ("文書が無い相手を拒否にする", [(NOT_EXISTS, "return exists(followeePath)\n             && ")]),
    ("中身のフォロワーの確認を外す", [(FOLLOWER_CHECK, "")]),
    # ブロックの確認が頼っている約束を緩める壊し方（Emulator のテストの壊し方と同じ文字列）
    ("本人以外も blockedUserIds を書き換えられる",
     [("changedKeys.hasOnly(['followersCount', 'followingCount'])",
       "changedKeys.hasOnly(['followersCount', 'followingCount', 'blockedUserIds'])")]),
    ("本人以外も users 文書を消せる",
     [("|| isFollowCounterUpdate();\n\n      allow delete: if isOwner(userId);",
       "|| isFollowCounterUpdate();\n\n      allow delete: if isAuthenticated();")]),
    ("follows を書き換えられる",
     [("// フォロー関係の更新は不可\n      allow update: if false;",
       "// フォロー関係の更新は不可\n      allow update: if isAuthenticated();")]),
]


def user_mocks(uids):
    """users の exists と get のモック（文書が無い人は exists=false だけ）"""
    mocks = []
    for u in sorted(uids):
        path = D + "/users/" + u
        mocks.append({"function": "exists", "args": [{"exactValue": path}], "result": {"value": u in USERS}})
        if u in USERS:
            mocks.append({"function": "get", "args": [{"exactValue": path}],
                          "result": {"value": {"data": USERS[u]}}})
    return mocks


def build_test_case(c):
    # 未ログインは auth を null で渡す（省くと request.auth が「未定義」になり、エラーで拒否される）
    request = {"path": c["path"], "method": c["method"], "time": T, "auth": None}
    if c["data"] is not None:
        request["resource"] = {"data": c["data"]}
    test_case = {"expectation": c["expect"], "request": request}
    if c["existing"] is not None:
        test_case["resource"] = {"data": c["existing"]}
    if c["uid"]:
        request["auth"] = {"uid": c["uid"], "token": {"firebase": {"sign_in_provider": "password"}}}
        # 自分と相手の users をすべてモックする（向きを逆にした壊し方も条件で見分ける）
        test_case["functionMocks"] = user_mocks(c["mock_uids"] | {c["uid"]})
    return test_case


def evaluate(source, token):
    """ルールの本文で全ケースを評価し、rules test API の testResults を返す（通信の失敗・testResults が無いときは None）。
    HTTP が 200 以外なら、その場で終了コード 1 で止める（401 のまま --mutants を続けると、
    全部の壊し方とケースが NG と出て、ルールの問題と見分けがつかないため）"""
    body = json.dumps({
        "source": {"files": [{"name": "firestore.rules", "content": source}]},
        "testSuite": {"testCases": [build_test_case(c) for c in CASES]},
    }).encode()
    req = urllib.request.Request(
        f"https://firebaserules.googleapis.com/v1/projects/{PROJECT_ID}:test",
        data=body,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
    )
    # --mutants は壊し方の数だけ呼ぶので、接続が切れるなどの一時的な失敗は 3 回まで再試行する（HTTP のエラーは再試行しない）
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
        for old, new in replacements:
            count = mutated.count(old)
            if count != 1:
                print(f"NG 壊し方「{name}」の置き換え元が {count} 回現れる（1 回のはず）: {old[:80]!r}")
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
    # 変えていないルールのケースと本人の対照は、ここの壊し方では見分けられなくて当然なので数えない
    targets = [c["name"] for c in CASES if c["target"]]
    unkilled = [n for n in targets if not killed_by[n]]
    print(f"\n壊し方 {len(MUTANTS)} 個 / どの壊し方でも期待外れにならない、確かめる対象のケース {len(unkilled)} 件")
    for case_name in unkilled:
        print("NG  見分けられていない:", case_name)
    return 0 if problems == 0 and not unkilled else 1


def main():
    args = sys.argv[1:]
    mutants = "--mutants" in args
    args = [a for a in args if a != "--mutants"]
    here = os.path.dirname(os.path.abspath(__file__))
    rules_path = args[0] if args else os.path.join(here, "..", "firestore.rules")
    source = open(rules_path, encoding="utf-8").read()
    token = json.load(open(os.path.expanduser("~/.config/configstore/firebase-tools.json")))["tokens"]["access_token"]
    return run_mutants(source, token) if mutants else run_normal(source, token)


if __name__ == "__main__":
    sys.exit(main())
