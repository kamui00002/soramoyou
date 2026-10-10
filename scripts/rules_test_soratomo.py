#!/usr/bin/env python3
"""rules_test_soratomo.py ☁️⭐️

firestore.rules の「そらとも」（招待制の小さなグループで空を共有する）の部分を、
Firebase の rules test API で評価する。評価だけを行うので、本番のデータにも deploy 済みのルールにも触れない。
spec: .kiro/specs/soratomo/（tasks.md 2.3・要件 11 の各項目を許可と拒否の両方で確かめる）
      .kiro/specs/soratomo-release-gate/（tasks.md 5・投稿の作成を閉じ、通報の記録と語のリストを誰にも読み書きさせない）

使い方:
  python3 scripts/rules_test_soratomo.py [firestore.rules のパス]            # 省略時はリポジトリ直下
  python3 scripts/rules_test_soratomo.py --mutants [firestore.rules のパス]  # 陽性対照（下の MUTANTS）
  401 が返るときは firebase CLI のトークンが古いので、`firebase projects:list` を一度実行してから再実行する。

認証:
  firebase CLI のログイン情報（~/.config/configstore/firebase-tools.json）のアクセストークンを使う。
  トークンは出力しない。

テストの書き方の約束（2026-10-01 に rules test API で確かめた）:
  - メンバー判定の exists() は functionMocks でモックする。モックの無い exists() はエラーになり、
    エラーは「拒否」として返る。そのままだと拒否を期待するケースが条件を見ずに通ってしまうため、
    全ケースでモックを渡し、さらに「エラーで拒否された」ケースは期待外れとして数える
  - request.time と作成日時は RFC3339 の文字列で渡すと timestamp 型として届く
  - 1080 は int、1080.5 は float として届く
  - 一覧（list）は、コレクションの中の文書のパスに method "list" を付けて評価する
  - 未ログインは auth を null で渡す（省くと request.auth が未定義になり、エラーで拒否される）

陽性対照（--mutants）:
  MUTANTS は、ルールの条件を 1 つずつわざと壊す置き換え。壊したルールで全ケースを流し、
  「どの壊し方でも期待外れにならないケース」と「どのケースも期待外れにしない壊し方」が無いことを確かめる。
  置き換え元の文字列がルールに 1 回だけ現れることも確かめる（ルールを直して置き換えが空振りするのを防ぐ）。

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
GROUP = D + "/soratomoGroups/g1"
SKY = GROUP + "/skies/s1"

# 要求の時刻（request.time）と、端末の時計で作った作成日時
T = "2026-10-01T03:00:00Z"
DEVICE_T = "2026-10-01T02:59:00Z"

# 登場人物
AUTHOR = "author"      # g1 のメンバー・投稿者
OWNER = "owner"        # g1 のオーナー（メンバー）
MEMBER = "member"      # g1 のほかのメンバー
NOCLAIM = "noclaim"    # g1 のメンバーの文書はあるが、機能フラグのクレームが無い
OUTSIDER = "outsider"  # クレームはあるが g1 のメンバーではない
G1_MEMBERS = {AUTHOR, OWNER, MEMBER, NOCLAIM}

# 旧ルールで正しかった投稿（5 項目）。作成日時は要求の時刻と同じ。
# 作成は Callable（soratomoCreateSky）だけになったので、これもアプリからは拒否される（release-gate 5）
VALID_SKY = {"authorId": AUTHOR, "caption": "夕焼け", "width": 1080, "height": 1440, "createdAt": T}


def sky(**fields):
    """VALID_SKY の一部を書き換えた（None なら消した）投稿を返す"""
    data = dict(VALID_SKY)
    for key, value in fields.items():
        if value is None:
            data.pop(key, None)
        else:
            data[key] = value
    return data


def case(name, expect, uid, method, path, data=None, existing=None):
    """1 ケース。uid=None は未ログイン。uid=NOCLAIM は soratomoBeta の無い利用者（別のクレームは持つ）"""
    return {"name": name, "expect": expect, "uid": uid, "claim": uid != NOCLAIM,
            "method": method, "path": path, "data": data, "existing": existing}


ALLOW, DENY = "ALLOW", "DENY"

CASES = [
    # --- 機能フラグ（要件 1.6）---
    case("フラグ クレーム有りのメンバーがグループを取得", ALLOW, MEMBER, "get", GROUP),
    case("フラグ クレーム無しのメンバーがグループを取得", DENY, NOCLAIM, "get", GROUP),
    case("フラグ クレーム無しのメンバーがメンバー一覧を取得", DENY, NOCLAIM, "list", GROUP + "/members/x"),
    case("フラグ クレーム無しのメンバーが投稿一覧を取得", DENY, NOCLAIM, "list", GROUP + "/skies/x"),
    case("フラグ クレーム無しのメンバーが投稿を作成", DENY, NOCLAIM, "create", SKY, sky(authorId=NOCLAIM)),
    case("フラグ クレーム無しの投稿者が自分の投稿を削除", DENY, NOCLAIM, "delete", SKY, existing=sky(authorId=NOCLAIM)),
    case("フラグ クレーム無しの本人が所属数を取得", DENY, NOCLAIM, "get", D + "/soratomoUsers/" + NOCLAIM),

    # --- 読み取り（要件 11.1・11.2）---
    case("読取 メンバーがメンバー一覧を取得", ALLOW, MEMBER, "list", GROUP + "/members/x"),
    case("読取 メンバーがメンバーを 1 件取得", ALLOW, MEMBER, "get", GROUP + "/members/" + OWNER),
    case("読取 メンバーが投稿一覧を取得", ALLOW, MEMBER, "list", GROUP + "/skies/x"),
    case("読取 メンバーが投稿を 1 件取得", ALLOW, MEMBER, "get", SKY),
    case("読取 非メンバーがグループを取得", DENY, OUTSIDER, "get", GROUP),
    case("読取 非メンバーがメンバー一覧を取得", DENY, OUTSIDER, "list", GROUP + "/members/x"),
    case("読取 非メンバーが投稿一覧を取得", DENY, OUTSIDER, "list", GROUP + "/skies/x"),
    case("読取 非メンバーが投稿を 1 件取得", DENY, OUTSIDER, "get", SKY),
    case("読取 未ログインでグループを取得", DENY, None, "get", GROUP),
    case("読取 未ログインでメンバー一覧を取得", DENY, None, "list", GROUP + "/members/x"),
    case("読取 未ログインで投稿一覧を取得", DENY, None, "list", GROUP + "/skies/x"),
    case("読取 メンバーがグループの一覧を取得", DENY, MEMBER, "list", D + "/soratomoGroups/x"),

    # --- メンバーと招待コード（要件 11.8・11.9）---
    case("招待 メンバーがグループの招待コードを読む（グループの取得）", ALLOW, OWNER, "get", GROUP),
    case("招待 非メンバーがグループの招待コードを読む（グループの取得）", DENY, OUTSIDER, "get", GROUP),
    case("招待 招待コードの一覧を取得", DENY, MEMBER, "list", D + "/soratomoInviteCodes/x"),
    case("招待 招待コードを 1 件取得", DENY, OUTSIDER, "get", D + "/soratomoInviteCodes/ABCD2345"),
    case("招待 招待コードを作成", DENY, OWNER, "create", D + "/soratomoInviteCodes/ABCD2345",
         {"groupId": "g1", "createdAt": T}),
    case("メンバー 非メンバーが自分をメンバーに追加", DENY, OUTSIDER, "create", GROUP + "/members/" + OUTSIDER,
         {"uid": OUTSIDER, "role": "member", "joinedAt": T}),
    case("メンバー メンバーが自分の役割をオーナーへ更新", DENY, MEMBER, "update", GROUP + "/members/" + MEMBER,
         {"uid": MEMBER, "role": "owner", "joinedAt": T}, existing={"uid": MEMBER, "role": "member", "joinedAt": T}),
    case("メンバー オーナーがメンバーを削除", DENY, OWNER, "delete", GROUP + "/members/" + MEMBER,
         existing={"uid": MEMBER, "role": "member", "joinedAt": T}),
    case("メンバー メンバーがメンバー数を更新", DENY, MEMBER, "update", GROUP,
         {"name": "n", "ownerId": OWNER, "inviteCode": "ABCD2345", "memberCount": 5},
         existing={"name": "n", "ownerId": OWNER, "inviteCode": "ABCD2345", "memberCount": 4}),
    case("メンバー クレーム有りの利用者がグループを作成", DENY, OUTSIDER, "create", D + "/soratomoGroups/g2",
         {"name": "n", "ownerId": OUTSIDER, "inviteCode": "ABCD2345", "memberCount": 1}),

    # --- 通知の間引きの状態 ---
    case("間引き 受信者本人が自分の状態を取得", DENY, MEMBER, "get", GROUP + "/notifyState/" + MEMBER),
    case("間引き 受信者本人が自分の状態を書く", DENY, MEMBER, "create", GROUP + "/notifyState/" + MEMBER,
         {"lastSentAt": T, "lastSkyId": "s1"}),

    # --- 利用者ごとの所属数と所属の写し ---
    case("所属 本人が所属数を取得", ALLOW, MEMBER, "get", D + "/soratomoUsers/" + MEMBER),
    case("所属 本人が所属の写しの一覧を取得", ALLOW, MEMBER, "list", D + "/soratomoUsers/" + MEMBER + "/groups/x"),
    case("所属 他人の所属数を取得", DENY, OUTSIDER, "get", D + "/soratomoUsers/" + MEMBER),
    case("所属 他人の所属の写しの一覧を取得", DENY, OUTSIDER, "list", D + "/soratomoUsers/" + MEMBER + "/groups/x"),
    case("所属 本人が所属数を 0 へ更新", DENY, MEMBER, "update", D + "/soratomoUsers/" + MEMBER,
         {"groupCount": 0}, existing={"groupCount": 10}),
    case("所属 本人が所属の写しを作成", DENY, OUTSIDER, "create", D + "/soratomoUsers/" + OUTSIDER + "/groups/g1",
         {"groupId": "g1", "joinedAt": T}),

    # --- 投稿の作成（release-gate 要件 8.6・11.5）---
    # 作成は Callable（soratomoCreateSky）のトランザクションだけ。旧ルールで許していた正しい 5 項目・4 項目も、
    # アプリからは拒否する（直接書けると、利用停止と NG ワードの検査を飛ばせる）。
    # キャプションと幅・高さの値の検査は functions/soratomoCore.test.js（validateSkyInput）へ移した
    case("作成 メンバーが自分の投稿者 ID で 5 項目の投稿（作成は Callable だけ）", DENY, AUTHOR, "create", SKY, sky()),
    case("作成 キャプション無しの 4 項目の投稿（作成は Callable だけ）", DENY, AUTHOR, "create", SKY, sky(caption=None)),
    case("作成 非メンバー（クレーム有り）が投稿", DENY, OUTSIDER, "create", SKY, sky(authorId=OUTSIDER)),
    case("作成 他人の投稿者 ID で投稿", DENY, MEMBER, "create", SKY, sky()),
    case("作成 未ログインで投稿", DENY, None, "create", SKY, sky()),
    case("作成 画像のパスの項目（imagePath）を足す", DENY, AUTHOR, "create", SKY,
         sky(imagePath="soratomo/g1/author/s1/display.jpg")),
    case("作成 画像の URL の項目（url）を足す", DENY, AUTHOR, "create", SKY, sky(url="https://example.com/a.jpg")),
    case("作成 端末の時刻の作成日時", DENY, AUTHOR, "create", SKY, sky(createdAt=DEVICE_T)),
    case("作成 作成日時が無い", DENY, AUTHOR, "create", SKY, sky(createdAt=None)),
    case("作成 投稿者 ID が無い", DENY, AUTHOR, "create", SKY, sky(authorId=None)),
    case("作成 幅が無い", DENY, AUTHOR, "create", SKY, sky(width=None)),
    case("作成 高さが無い", DENY, AUTHOR, "create", SKY, sky(height=None)),

    # --- 投稿の更新と削除（要件 11.6・11.15）---
    case("更新 投稿者が自分の投稿のキャプションを更新", DENY, AUTHOR, "update", SKY,
         sky(caption="朝焼け"), existing=sky()),
    case("削除 投稿者が自分の投稿を削除", ALLOW, AUTHOR, "delete", SKY, existing=sky()),
    case("削除 オーナーが他人の投稿を削除", DENY, OWNER, "delete", SKY, existing=sky()),
    case("削除 ほかのメンバーが他人の投稿を削除", DENY, MEMBER, "delete", SKY, existing=sky()),
    case("削除 未ログインで削除", DENY, None, "delete", SKY, existing=sky()),

    # --- 利用者の文書の同意と利用停止（release-gate 要件 8.9・10.14）---
    # 本人の読み取り（同意と利用停止の項目を含む）と他人の拒否は、上の「所属」の get のケースで見る。
    # ここでは、本人が停止を外す・同意を書く書き込みを見る（停止と解除は開発者の運用手順、同意は Callable だけ）
    case("利用者 本人が利用停止の項目（suspendedAt）を消す", DENY, MEMBER, "update", D + "/soratomoUsers/" + MEMBER,
         {"groupCount": 1}, existing={"groupCount": 1, "suspendedAt": T}),
    case("利用者 本人が同意の版（guidelineVersion）を書く", DENY, MEMBER, "update", D + "/soratomoUsers/" + MEMBER,
         {"groupCount": 1, "guidelineVersion": 1, "guidelineAgreedAt": T}, existing={"groupCount": 1}),
]


def closed_collection_cases():
    """通報の記録と語のリスト（release-gate 要件 6.10・11.10）。
    Functions（Admin SDK）だけが読み書きする。どの立場の利用者にも get・list・create・update・delete を許さない"""
    report = {"groupId": "g1", "skyId": "s1", "authorId": AUTHOR, "reporterId": MEMBER, "reason": "spam",
              "createdAt": T, "forwardStatus": "pending", "forwardAttempts": 0}
    ng_words = {"words": ["てすとごい"]}  # ダミーの語（実在の語は書かない）
    targets = [
        # 通報の記録の ID は「グループ ID_投稿 ID_通報者」（soratomoCore.reportDocId）
        ("通報の記録", "soratomoReports", "g1_s1_" + MEMBER, report, dict(report, forwardStatus="sent")),
        ("語のリスト", "soratomoConfig", "ngWords", ng_words, {"words": []}),
    ]
    roles = [("通報者", MEMBER), ("投稿者", AUTHOR), ("ほかのメンバー", OWNER), ("未ログイン", None)]
    cases = []
    for label, collection, doc_id, data, updated in targets:
        doc = D + "/" + collection + "/" + doc_id
        for role, uid in roles:
            cases += [
                case(f"{label} {role}が 1 件取得", DENY, uid, "get", doc),
                case(f"{label} {role}が一覧を取得", DENY, uid, "list", D + "/" + collection + "/x"),
                case(f"{label} {role}が作成", DENY, uid, "create", doc, data),
                case(f"{label} {role}が更新", DENY, uid, "update", doc, updated, existing=data),
                case(f"{label} {role}が削除", DENY, uid, "delete", doc, existing=data),
            ]
    return cases


CASES += closed_collection_cases()

# 陽性対照: (名前, [(置き換え元, 置き換え先), ...])。置き換え元はルールに 1 回だけ現れること
# 細かい壊し方（条件を 1 つ外す・境界を 1 つずらす）で「その条件をテストが見ている」ことを、
# 粗い壊し方（if false を if true に）で「パスや種類の書き間違いで拒否されているだけではない」ことを確かめる。
# 同じ文字列が複数回出る箇所は、直前の match の行ごと置き換え元にする（インデントも含めて完全一致）。
CLAIM = "isAuthenticated() && request.auth.token.get('soratomoBeta', false) == true"
MEMBER_EXISTS = "return exists(/databases/$(database)/documents/soratomoGroups/$(groupId)/members/$(request.auth.uid));"
# 投稿の作成と更新は同じ「if false」なので、2 行の組で置き換え元を 1 回にする
SKY_CREATE_UPDATE = "allow create: if false;\n        allow update: if false;"
SKY_DELETE = "allow delete: if isSoratomoUser() && resource.data.authorId == request.auth.uid;"
USERS_READ = "match /soratomoUsers/{uid} {\n      allow read: if isSoratomoUser() && isOwner(uid);"
USER_GROUPS_READ = "match /groups/{groupId} {\n        allow read: if isSoratomoUser() && isOwner(uid);"
REPORTS_CLOSED = "match /soratomoReports/{reportId} {\n      allow read, write: if false;"
CONFIG_CLOSED = "match /soratomoConfig/{docId} {\n      allow read, write: if false;"

MUTANTS = [
    # 共通の判定
    ("クレームの判定を外す", [(CLAIM, "isAuthenticated()")]),
    ("クレームの判定を常に偽", [(CLAIM, "false")]),
    ("メンバー判定を外す", [(MEMBER_EXISTS, "return true;")]),
    ("メンバー判定を常に偽", [(MEMBER_EXISTS, "return false;")]),
    ("ログイン・クレーム・メンバーの判定をすべて外す", [(CLAIM, "true"), (MEMBER_EXISTS, "return true;")]),
    # グループ・メンバー・間引き・招待コード
    ("グループの一覧を許す", [("allow list: if false;", "allow list: if true;")]),
    ("グループの書き込みを許す", [("再発行は Callable のトランザクションだけ（要件 11.8）\n      allow write: if false;",
                                  "再発行は Callable のトランザクションだけ（要件 11.8）\n      allow write: if true;")]),
    ("メンバーの書き込みを許す", [("参加の Callable だけ（要件 11.8）\n        allow write: if false;",
                                  "参加の Callable だけ（要件 11.8）\n        allow write: if true;")]),
    ("通知の間引きの状態の読み書きを許す", [("match /notifyState/{uid} {\n        allow read, write: if false;",
                                            "match /notifyState/{uid} {\n        allow read, write: if true;")]),
    ("招待コードの読み書きを許す", [("match /soratomoInviteCodes/{code} {\n      allow read, write: if false;",
                                    "match /soratomoInviteCodes/{code} {\n      allow read, write: if true;")]),
    # 所属数と所属の写し
    ("所属数の本人判定を外す", [(USERS_READ, USERS_READ.replace(" && isOwner(uid)", ""))]),
    ("所属の写しの本人判定を外す", [(USER_GROUPS_READ, USER_GROUPS_READ.replace(" && isOwner(uid)", ""))]),
    ("所属数の書き込みを許す", [("isOwner(uid);\n      allow write: if false;", "isOwner(uid);\n      allow write: if true;")]),
    ("所属の写しの書き込みを許す", [("isOwner(uid);\n        allow write: if false;",
                                    "isOwner(uid);\n        allow write: if true;")]),
    # 投稿の作成・更新・削除
    ("投稿の作成を許す", [(SKY_CREATE_UPDATE, SKY_CREATE_UPDATE.replace("create: if false", "create: if true"))]),
    ("投稿の更新を許す", [(SKY_CREATE_UPDATE, SKY_CREATE_UPDATE.replace("update: if false", "update: if true"))]),
    ("削除の投稿者判定を外す", [(SKY_DELETE, "allow delete: if isSoratomoUser();")]),
    ("削除の条件をすべて外す", [(SKY_DELETE, "allow delete: if true;")]),
    # 通報の記録と語のリスト
    ("通報の記録の読み書きを許す", [(REPORTS_CLOSED, REPORTS_CLOSED.replace("if false", "if true"))]),
    ("語のリストの読み書きを許す", [(CONFIG_CLOSED, CONFIG_CLOSED.replace("if false", "if true"))]),
]


def build_test_case(c):
    # 未ログインは auth を null で渡す（本番と同じ形）。省くと request.auth が「未定義」になり、
    # isAuthenticated() の request.auth != null がエラーで拒否されて、条件で拒否されたことを確かめられない
    request = {"path": c["path"], "method": c["method"], "time": T, "auth": None}
    mocks = []
    if c["uid"]:
        # 別のクレーム（skyMotionBeta）を持たせ、soratomoBeta 以外では通らないことも同時に見る
        token = {"soratomoBeta": True} if c["claim"] else {"skyMotionBeta": True}
        request["auth"] = {"uid": c["uid"], "token": token}
        # メンバー判定（g1 のメンバーの文書の存在）。全ケースで明示する
        mocks.append({"function": "exists",
                      "args": [{"exactValue": GROUP + "/members/" + c["uid"]}],
                      "result": {"value": c["uid"] in G1_MEMBERS}})
    if c["data"] is not None:
        request["resource"] = {"data": c["data"]}
    test_case = {"expectation": c["expect"], "request": request}
    if c["existing"] is not None:
        test_case["resource"] = {"data": c["existing"]}
    if mocks:
        test_case["functionMocks"] = mocks
    return test_case


def evaluate(source, token):
    """ルールの本文で全ケースを評価し、rules test API の testResults を返す（失敗時は None）"""
    body = json.dumps({
        "source": {"files": [{"name": "firestore.rules", "content": source}]},
        "testSuite": {"testCases": [build_test_case(c) for c in CASES]},
    }).encode()
    req = urllib.request.Request(
        f"https://firebaserules.googleapis.com/v1/projects/{PROJECT_ID}:test",
        data=body,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
    )
    # --mutants は壊し方の数（len(MUTANTS)）だけ呼ぶので、接続が切れるなどの一時的な失敗は 3 回まで再試行する（HTTP のエラーは再試行しない）
    for attempt in range(3):
        try:
            result = json.load(urllib.request.urlopen(req, timeout=60))
            break
        except urllib.error.HTTPError as e:
            print("HTTP", e.code, e.read().decode()[:600])
            return None
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
                print(f"NG 壊し方「{name}」の置き換え元が {count} 回現れる（1 回のはず）: {old[:80]}")
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
    unkilled = [n for n, ms in killed_by.items() if not ms]
    print(f"\n壊し方 {len(MUTANTS)} 個 / どの壊し方でも期待外れにならないケース {len(unkilled)} 件")
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
