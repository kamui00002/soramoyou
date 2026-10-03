#!/usr/bin/env python3
"""rules_test_storage_soratomo.py ☁️⭐️

storage.rules の「そらとも」（招待制の小さなグループで空を共有する）の画像のパスを、
Firebase の rules test API で評価する。評価だけを行うので、本番のデータにも deploy 済みのルールにも触れない。
spec: .kiro/specs/soratomo/（tasks.md 4.2・要件 1.6 と 11 の各項目を許可と拒否の両方で確かめる）

使い方:
  python3 scripts/rules_test_storage_soratomo.py [storage.rules のパス]            # 省略時はリポジトリ直下
  python3 scripts/rules_test_storage_soratomo.py --mutants [storage.rules のパス]  # 陽性対照（下の MUTANTS）
  401 が返るときは firebase CLI のトークンが古いので、`firebase projects:list > /dev/null` を一度実行してから再実行する。

認証:
  firebase CLI のログイン情報（~/.config/configstore/firebase-tools.json）のアクセストークンを使う。
  トークンは出力しない。

テストの書き方の約束（2026-10-02 に rules test API で確かめた。research.md の要確認 2）:
  - Storage のルールの中の Firestore の読み取り（メンバー判定）は、functionMocks の関数名 "firestore.exists" でモックする
    （"exists" では効かない）。引数はメンバーの文書のパスの文字列で、"(default)" はエンコードしない
  - モックの無い firestore.exists はエラーになり、エラーは「拒否」として返る。そのままだと拒否を期待するケースが
    条件を見ずに通ってしまうため、全ケースでモックを渡し、さらに「エラーで拒否された」ケースは期待外れとして数える
  - 保存（create・update）は request.resource に contentType と size を渡す。削除（delete）では渡さない
    （本番の削除の要求にも内容が無い。内容を参照する削除のルールは、投稿者本人の削除（許可を期待）がエラーで拒否されて見つかる）
  - ただし && の片方が false のときは、もう片方のエラーは捨てられて false になる（エラーにならない）。
    拒否を期待するケースでは「内容を参照したか」は結果に表れない（2026-10-03 確認。下の MUTANTS の削除の項）
  - 未ログインは auth を null で渡す（省くと request.auth が未定義になり、エラーで拒否される）
  - クレームの無い利用者には別のクレーム（skyMotionBeta）を持たせ、soratomoBeta 以外では通らないことも同時に見る

陽性対照（--mutants）:
  MUTANTS は、ルールの条件を 1 つずつわざと壊す置き換え。壊したルールで全ケースを流し、
  「どの壊し方でも期待外れにならないケース」と「どのケースも期待外れにしない壊し方」が無いことを確かめる。
  置き換え元の文字列がルールに 1 回だけ現れることも確かめる（ルールを直して置き換えが空振りするのを防ぐ）。

確かめられないこと:
  Storage から Firestore を読む権限（IAM の付与）と、本物のメンバーの文書の読み取りは、この方式では確かめられない
  （tasks 4.3 と 15.1 で確かめる）。

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
MEMBER_DOC = "/databases/(default)/documents/soratomoGroups/g1/members/"

# 要求の時刻（ルールは見ないが、本番の要求と同じく渡す）
T = "2026-10-02T03:00:00Z"

# 登場人物
AUTHOR = "author"      # g1 のメンバー・投稿者
OWNER = "owner"        # g1 のオーナー（Storage のルールにオーナーの区別は無く、メンバーの 1 人として扱われる）
MEMBER = "member"      # g1 のほかのメンバー
NOCLAIM = "noclaim"    # g1 のメンバーの文書はあるが、機能フラグのクレームが無い
OUTSIDER = "outsider"  # クレームはあるが g1 のメンバーではない
G1_MEMBERS = {AUTHOR, OWNER, MEMBER, NOCLAIM}

# 画像のパス（バケットより下）
AUTHOR_DIR = "soratomo/g1/" + AUTHOR + "/s1/"
DISPLAY = AUTHOR_DIR + "display.jpg"
THUMB = AUTHOR_DIR + "thumb.jpg"


def own_path(uid, file_name="display.jpg"):
    """その利用者自身の投稿者のパス（g1・投稿 s2）"""
    return "soratomo/g1/" + uid + "/s2/" + file_name


# 保存できる大きさの上限（バイト。要件 11.5）
DISPLAY_MAX = 1572864
THUMB_MAX = 204800


def jpeg(size):
    return {"contentType": "image/jpeg", "size": size}


def case(name, expect, uid, method, path, upload=None):
    """1 ケース。uid=None は未ログイン。upload は保存する内容（request.resource）で、削除では渡さない"""
    return {"name": name, "expect": expect, "uid": uid, "claim": uid != NOCLAIM,
            "method": method, "path": path, "upload": upload}


ALLOW, DENY = "ALLOW", "DENY"

CASES = [
    # --- 機能フラグ（要件 1.6）---
    case("フラグ クレーム有りのメンバーが画像を読む", ALLOW, MEMBER, "get", DISPLAY),
    case("フラグ クレーム無しのメンバーが画像を読む", DENY, NOCLAIM, "get", DISPLAY),
    case("フラグ クレーム無しのメンバーが自分のパスへ保存", DENY, NOCLAIM, "create", own_path(NOCLAIM), jpeg(1000)),
    case("フラグ クレーム無しの投稿者が自分の画像を削除（内容なし）", DENY, NOCLAIM, "delete", own_path(NOCLAIM)),

    # --- 読み取り（要件 11.1・11.2）---
    case("読取 投稿者が自分のサムネイルを読む", ALLOW, AUTHOR, "get", THUMB),
    case("読取 オーナーが他人の画像を読む", ALLOW, OWNER, "get", DISPLAY),
    case("読取 非メンバー（クレーム有り）が読む", DENY, OUTSIDER, "get", DISPLAY),
    case("読取 未ログインで読む", DENY, None, "get", DISPLAY),

    # --- 保存（要件 11.5）---
    case("保存 表示用 上限ちょうど（1,572,864）", ALLOW, AUTHOR, "create", DISPLAY, jpeg(DISPLAY_MAX)),
    case("保存 表示用 上限+1", DENY, AUTHOR, "create", DISPLAY, jpeg(DISPLAY_MAX + 1)),
    case("保存 サムネイル 上限ちょうど（204,800）", ALLOW, AUTHOR, "create", THUMB, jpeg(THUMB_MAX)),
    case("保存 サムネイル 上限+1", DENY, AUTHOR, "create", THUMB, jpeg(THUMB_MAX + 1)),
    case("保存 ほかのメンバーが自分のパスへサムネイル", ALLOW, MEMBER, "create", own_path(MEMBER, "thumb.jpg"),
         jpeg(1000)),
    case("保存 PNG", DENY, AUTHOR, "create", DISPLAY, {"contentType": "image/png", "size": 1000}),
    case("保存 他のファイル名（other.jpg）", DENY, AUTHOR, "create", AUTHOR_DIR + "other.jpg", jpeg(1000)),
    case("保存 メンバーが他人のパスへ", DENY, MEMBER, "create", DISPLAY, jpeg(1000)),
    case("保存 非メンバー（クレーム有り）が自分のパスへ", DENY, OUTSIDER, "create", own_path(OUTSIDER), jpeg(1000)),
    case("保存 未ログインで保存", DENY, None, "create", DISPLAY, jpeg(1000)),

    # --- 上書き ---
    case("上書き 投稿者が自分の画像を上書き", DENY, AUTHOR, "update", DISPLAY, jpeg(1000)),

    # --- 削除（要件 11.6・11.7・11.15）。どれも内容（request.resource）を渡さない ---
    case("削除 投稿者が自分の画像を削除（内容なし）", ALLOW, AUTHOR, "delete", DISPLAY),
    case("削除 オーナーが他人の画像を削除", DENY, OWNER, "delete", DISPLAY),
    case("削除 ほかのメンバーが他人の画像を削除", DENY, MEMBER, "delete", DISPLAY),
    case("削除 投稿者が他人のパスの画像を削除", DENY, AUTHOR, "delete", own_path(MEMBER)),
    case("削除 未ログインで削除", DENY, None, "delete", DISPLAY),
]

# 陽性対照: (名前, [(置き換え元, 置き換え先), ...])。置き換え元はルールに 1 回だけ現れること
# 細かい壊し方（条件を 1 つ外す・境界を 1 つずらす）で「その条件をテストが見ている」ことを、
# 粗い壊し方（条件を true に）で「パスや種類の書き間違いで拒否されているだけではない」ことを確かめる。
# 投稿者 ID の一致（request.auth.uid == authorId）は作成と削除の 2 か所にあるので、作成の側は改行とインデントごと置き換え元にする。
CLAIM = "isAuthenticated() && request.auth.token.get('soratomoBeta', false) == true"
MEMBER_EXISTS = ("return firestore.exists(/databases/(default)/documents/soratomoGroups/$(groupId)"
                 "/members/$(request.auth.uid));")
READ = "allow read: if isSoratomoUser() && isSoratomoMember();"
CREATE = ("allow create: if isSoratomoUser()\n"
          "                    && request.auth.uid == authorId\n"
          "                    && isSoratomoMember()\n"
          "                    && fileName in ['display.jpg', 'thumb.jpg']\n"
          "                    && request.resource.contentType == 'image/jpeg'\n"
          "                    && request.resource.size <= maxSoratomoImageSize(fileName);")
CREATE_LINE = "\n                    && "
JPEG_CHECK = "request.resource.contentType == 'image/jpeg'"
SIZE_LIMIT = "return name == 'display.jpg' ? 1572864 : 204800;"
UPDATE = "allow update: if false;"
DELETE = "allow delete: if isSoratomoUser() && request.auth.uid == authorId;"

MUTANTS = [
    # 機能フラグ（クレーム）
    ("クレームの判定を外す", [(CLAIM, "isAuthenticated()")]),
    ("クレームの判定を常に偽", [(CLAIM, "false")]),
    ("クレームを直接読む（token.soratomoBeta）", [(CLAIM, "isAuthenticated() && request.auth.token.soratomoBeta == true")]),
    # メンバー判定（読み取りと保存の共通）
    ("メンバー判定を外す", [(MEMBER_EXISTS, "return true;")]),
    ("メンバー判定を常に偽", [(MEMBER_EXISTS, "return false;")]),
    # 読み取り
    ("読み取りのメンバー判定を外す", [(READ, "allow read: if isSoratomoUser();")]),
    ("読み取りのクレーム判定を外す", [(READ, "allow read: if isAuthenticated() && isSoratomoMember();")]),
    ("読み取りを全員に許す", [(READ, "allow read: if true;")]),
    # 保存
    ("保存の条件をすべて外す", [(CREATE, "allow create: if true;")]),
    ("保存の投稿者の一致を外す", [(CREATE_LINE + "request.auth.uid == authorId", "")]),
    ("保存のメンバー判定を外す", [(CREATE_LINE + "isSoratomoMember()", "")]),
    ("保存のファイル名の制限を外す", [(CREATE_LINE + "fileName in ['display.jpg', 'thumb.jpg']", "")]),
    ("保存の種類の検査を外す", [(CREATE_LINE + JPEG_CHECK, "")]),
    ("保存の種類を image/.* に緩める", [(JPEG_CHECK, "request.resource.contentType.matches('image/.*')")]),
    ("保存の大きさの検査を外す", [(CREATE_LINE + "request.resource.size <= maxSoratomoImageSize(fileName)", "")]),
    ("表示用の上限を 1 下げる", [(SIZE_LIMIT, SIZE_LIMIT.replace("1572864", "1572863"))]),
    ("表示用の上限を 1 上げる", [(SIZE_LIMIT, SIZE_LIMIT.replace("1572864", "1572865"))]),
    ("サムネイルの上限を 1 下げる", [(SIZE_LIMIT, SIZE_LIMIT.replace("204800", "204799"))]),
    ("サムネイルの上限を 1 上げる", [(SIZE_LIMIT, SIZE_LIMIT.replace("204800", "204801"))]),
    ("表示用とサムネイルの上限を取り違える", [(SIZE_LIMIT, SIZE_LIMIT.replace("'display.jpg'", "'thumb.jpg'"))]),
    # 上書き
    ("上書きを許す", [(UPDATE, "allow update: if true;")]),
    # 削除
    ("削除の投稿者判定を外す", [(DELETE, "allow delete: if isSoratomoUser();")]),
    ("削除のクレーム判定を外す", [(DELETE, "allow delete: if isAuthenticated() && request.auth.uid == authorId;")]),
    ("削除の条件をすべて外す", [(DELETE, "allow delete: if true;")]),
    # 要件 11.7: 削除に内容の検査を混ぜる。後ろに足しても前に足しても、投稿者本人の削除（許可を期待）がエラーで拒否されて見つかる。
    # 拒否を期待するケースは、前に足しても期待外れにならない。Rules の && は、もう片方が false ならエラーを捨てて false を返す
    # （2026-10-03 に rules test API で確認。debugMessages は空で、式の報告でもエラーと「評価しなかった」が同じ値になる）。
    # つまり拒否の結果は内容を参照してもしなくても同じで、11.7 の検査は許可を期待するケースが受け持つ
    ("削除に内容の検査を混ぜる（後ろ）", [(DELETE, DELETE.replace(";", " && " + JPEG_CHECK + ";"))]),
    ("削除に内容の検査を混ぜる（前）", [(DELETE, DELETE.replace("if ", "if " + JPEG_CHECK + " && "))]),
    # PR #141 と同じ型: 作成と削除（と更新）を 1 つの allow write にまとめる。
    # 許可は OR で合わさるので、別の allow delete を残すと見つけられない。更新と削除の行は消す
    ("作成と削除を allow write にまとめる（PR #141 の型）",
     [("allow create: if isSoratomoUser()\n", "allow write: if isSoratomoUser()\n"), (UPDATE, ""), (DELETE, "")]),
]


def build_test_case(c):
    # 未ログインは auth を null で渡す（本番と同じ形）。省くと request.auth が「未定義」になり、
    # isAuthenticated() の request.auth != null がエラーで拒否されて、条件で拒否されたことを確かめられない
    request = {"path": BUCKET_PATH + c["path"], "method": c["method"], "time": T, "auth": None}
    test_case = {"expectation": c["expect"], "request": request}
    if c["uid"]:
        token = {"soratomoBeta": True} if c["claim"] else {"skyMotionBeta": True}
        request["auth"] = {"uid": c["uid"], "token": token}
        # メンバー判定（g1 のメンバーの文書の存在）。全ケースで明示する
        test_case["functionMocks"] = [{"function": "firestore.exists",
                                       "args": [{"exactValue": MEMBER_DOC + c["uid"]}],
                                       "result": {"value": c["uid"] in G1_MEMBERS}}]
    if c["upload"] is not None:
        request["resource"] = c["upload"]
    return test_case


def evaluate(source, token):
    """ルールの本文で全ケースを評価し、rules test API の testResults を返す（失敗時は None）"""
    body = json.dumps({
        "source": {"files": [{"name": "storage.rules", "content": source}]},
        "testSuite": {"testCases": [build_test_case(c) for c in CASES]},
    }).encode()
    req = urllib.request.Request(
        f"https://firebaserules.googleapis.com/v1/projects/{PROJECT_ID}:test",
        data=body,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
    )
    # --mutants は 30 回近く呼ぶので、接続が切れるなどの一時的な失敗は 3 回まで再試行する（HTTP のエラーは再試行しない）
    for attempt in range(3):
        try:
            result = json.load(urllib.request.urlopen(req, timeout=60))
            break
        except urllib.error.HTTPError as e:
            print("HTTP", e.code, e.read().decode()[:600])
            if e.code == 401:
                print("トークンが古い。`firebase projects:list > /dev/null` を一度実行してから再実行する")
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
    rules_path = args[0] if args else os.path.join(here, "..", "storage.rules")
    source = open(rules_path, encoding="utf-8").read()
    token = json.load(open(os.path.expanduser("~/.config/configstore/firebase-tools.json")))["tokens"]["access_token"]
    return run_mutants(source, token) if mutants else run_normal(source, token)


if __name__ == "__main__":
    sys.exit(main())
