#!/usr/bin/env python3
"""rules_test_soratomo.py ☁️⭐️

firestore.rules の「そらとも」（招待制の小さなグループで空を共有する）の部分を、
Firebase の rules test API で評価する。評価だけを行うので、本番のデータにも deploy 済みのルールにも触れない。
spec: .kiro/specs/soratomo/（tasks.md 2.3・要件 11 の各項目を許可と拒否の両方で確かめる）

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

# 正しい投稿（5 項目）。作成日時は要求の時刻と同じ
VALID_SKY = {"authorId": AUTHOR, "caption": "夕焼け", "width": 1080, "height": 1440, "createdAt": T}

# キャプションの入力は research.md の要確認 1 と同じもの（数え方はコードポイント）
EMOJI = "\U0001F600"          # サロゲートペア（UTF-16 で 2）
E_ACUTE = "é"           # e＋結合文字（コードポイント 2・書記素 1）
MIX_100 = EMOJI * 20 + E_ACUTE * 20 + "あ" * 40  # コードポイント 100・UTF-16 120


def sky(**fields):
    """VALID_SKY の一部を書き換えた（None なら消した）投稿を返す"""
    data = dict(VALID_SKY)
    for key, value in fields.items():
        if value is None:
            data.pop(key, None)
        else:
            data[key] = value
    return data


def case(name, expect, uid, method, path, data=None, existing=None, claim=True):
    """1 ケース。uid=None は未ログイン。claim=False は soratomoBeta の無い利用者（別のクレームは持つ）"""
    return {"name": name, "expect": expect, "uid": uid, "claim": claim and uid != NOCLAIM,
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

    # --- 投稿の作成（要件 11.3・11.4・11.12・11.13）---
    case("作成 メンバーが自分の投稿者 ID で 5 項目の投稿", ALLOW, AUTHOR, "create", SKY, sky()),
    case("作成 キャプション無しの 4 項目の投稿", ALLOW, AUTHOR, "create", SKY, sky(caption=None)),
    case("作成 幅 1・高さ 2048（境界）", ALLOW, AUTHOR, "create", SKY, sky(width=1, height=2048)),
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
    case("作成 幅 0", DENY, AUTHOR, "create", SKY, sky(width=0)),
    case("作成 幅 2049", DENY, AUTHOR, "create", SKY, sky(width=2049)),
    case("作成 高さ 0", DENY, AUTHOR, "create", SKY, sky(height=0)),
    case("作成 高さ 2049", DENY, AUTHOR, "create", SKY, sky(height=2049)),
    case("作成 幅が小数（1080.5）", DENY, AUTHOR, "create", SKY, sky(width=1080.5)),
    case("作成 高さが文字列（\"1440\"）", DENY, AUTHOR, "create", SKY, sky(height="1440")),

    # --- 投稿の更新と削除（要件 11.6・11.15）---
    case("更新 投稿者が自分の投稿のキャプションを更新", DENY, AUTHOR, "update", SKY,
         sky(caption="朝焼け"), existing=sky()),
    case("削除 投稿者が自分の投稿を削除", ALLOW, AUTHOR, "delete", SKY, existing=sky()),
    case("削除 オーナーが他人の投稿を削除", DENY, OWNER, "delete", SKY, existing=sky()),
    case("削除 ほかのメンバーが他人の投稿を削除", DENY, MEMBER, "delete", SKY, existing=sky()),
    case("削除 未ログインで削除", DENY, None, "delete", SKY, existing=sky()),

    # --- キャプション（要件 11.11・入力は research.md の要確認 1）---
    case("キャプション コードポイント 100（絵文字 20＋結合文字 20＋かな 40・UTF-16 120）", ALLOW, AUTHOR, "create", SKY,
         sky(caption=MIX_100)),
    case("キャプション ASCII 100", ALLOW, AUTHOR, "create", SKY, sky(caption="a" * 100)),
    case("キャプション 絵文字 50（UTF-16 100）", ALLOW, AUTHOR, "create", SKY, sky(caption=EMOJI * 50)),
    case("キャプション 絵文字 50＋a（コードポイント 51・UTF-16 101）", ALLOW, AUTHOR, "create", SKY,
         sky(caption=EMOJI * 50 + "a")),
    case("キャプション かな 100（UTF-8 300 バイト）", ALLOW, AUTHOR, "create", SKY, sky(caption="あ" * 100)),
    case("キャプション タブを含む", ALLOW, AUTHOR, "create", SKY, sky(caption="a\tb")),
    case("キャプション コードポイント 101（上の 100＋a）", DENY, AUTHOR, "create", SKY, sky(caption=MIX_100 + "a")),
    case("キャプション ASCII 101", DENY, AUTHOR, "create", SKY, sky(caption="a" * 101)),
    case("キャプション e＋U+0301 ×60（書記素 60・コードポイント 120）", DENY, AUTHOR, "create", SKY,
         sky(caption=E_ACUTE * 60)),
    case("キャプション 空文字", DENY, AUTHOR, "create", SKY, sky(caption="")),
    case("キャプション 数値", DENY, AUTHOR, "create", SKY, sky(caption=123)),
    case("キャプション 改行 LF", DENY, AUTHOR, "create", SKY, sky(caption="a\nb")),
    case("キャプション 改行 LF が 2 つ", DENY, AUTHOR, "create", SKY, sky(caption="a\nb\nc")),
    case("キャプション 改行 CR", DENY, AUTHOR, "create", SKY, sky(caption="a\rb")),
    case("キャプション 改行 CRLF", DENY, AUTHOR, "create", SKY, sky(caption="a\r\nb")),
    case("キャプション 改行 U+0085", DENY, AUTHOR, "create", SKY, sky(caption="a\u0085b")),
    case("キャプション 改行 U+2028", DENY, AUTHOR, "create", SKY, sky(caption="a b")),
    case("キャプション 改行 U+2029", DENY, AUTHOR, "create", SKY, sky(caption="a b")),
    case("キャプション 末尾の LF", DENY, AUTHOR, "create", SKY, sky(caption="ab\n")),
]

# 陽性対照: (名前, [(置き換え元, 置き換え先), ...])。置き換え元はルールに 1 回だけ現れること
# 細かい壊し方（条件を 1 つ外す・境界を 1 つずらす）で「その条件をテストが見ている」ことを、
# 粗い壊し方（if false を if true に）で「パスや種類の書き間違いで拒否されているだけではない」ことを確かめる。
# 同じ文字列が複数回出る箇所は、直前の match の行ごと置き換え元にする（インデントも含めて完全一致）。
CLAIM = "isAuthenticated() && request.auth.token.get('soratomoBeta', false) == true"
MEMBER_EXISTS = "return exists(/databases/$(database)/documents/soratomoGroups/$(groupId)/members/$(request.auth.uid));"
CAPTION_RE = r"[^\\r\\n\\x{85}\\x{2028}\\x{2029}]{1,100}"
DIMENSION = "return value is int && value >= 1 && value <= 2048;"
SKY_CREATE = ("allow create: if isSoratomoUser()\n"
              "                      && isSoratomoMember(groupId)\n"
              "                      && isValidSoratomoSky(request.resource.data);")
SKY_DELETE = "allow delete: if isSoratomoUser() && resource.data.authorId == request.auth.uid;"
USERS_READ = "match /soratomoUsers/{uid} {\n      allow read: if isSoratomoUser() && isOwner(uid);"
USER_GROUPS_READ = "match /groups/{groupId} {\n        allow read: if isSoratomoUser() && isOwner(uid);"

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
    # 投稿の作成
    ("作成の条件をすべて外す", [(SKY_CREATE, "allow create: if true;")]),
    ("項目の制限（hasOnly）を外す",
     [("data.keys().hasOnly(['authorId', 'caption', 'width', 'height', 'createdAt'])\n             && ", "")]),
    ("必須の項目（hasAll）を外す", [("data.keys().hasAll(['authorId', 'width', 'height', 'createdAt'])\n             && ", "")]),
    ("投稿者の一致を外す", [("\n             && data.authorId == request.auth.uid", "")]),
    ("作成日時の一致を外す", [("\n             && data.createdAt == request.time", "")]),
    ("幅の検査を外す", [("\n             && isValidSoratomoDimension(data.width)", "")]),
    ("高さの検査を外す", [("\n             && isValidSoratomoDimension(data.height)", "")]),
    ("幅・高さの整数の判定を外す", [(DIMENSION, "return value >= 1 && value <= 2048;")]),
    ("幅・高さの範囲を外す", [(DIMENSION, "return value is int;")]),
    ("幅・高さの下限を 1 ずらす（> 1）", [(DIMENSION, "return value is int && value > 1 && value <= 2048;")]),
    ("幅・高さの上限を 1 ずらす（< 2048）", [(DIMENSION, "return value is int && value >= 1 && value < 2048;")]),
    # キャプション
    ("キャプションの検査を外す", [("\n             && isValidSoratomoCaption(data)", "")]),
    ("キャプションの型の判定を外す", [("(data.caption is string\n                 && ", "(")]),
    ("キャプションを size()（UTF-16）で数える",
     [(CAPTION_RE + "')", r"[^\\r\\n\\x{85}\\x{2028}\\x{2029}]+') && data.caption.size() <= 100")]),
    ("キャプションの上限を外す（{1,}）", [(CAPTION_RE, CAPTION_RE.replace("{1,100}", "{1,}"))]),
    ("キャプションの上限を 1 ずらす（{1,99}）", [(CAPTION_RE, CAPTION_RE.replace("{1,100}", "{1,99}"))]),
    ("キャプションの下限を外す（{0,100}）", [(CAPTION_RE, CAPTION_RE.replace("{1,100}", "{0,100}"))]),
    ("改行類の検査をすべて外す", [(CAPTION_RE, r"[\\s\\S]{1,100}")]),
    ("改行類から CR を外す", [(CAPTION_RE, CAPTION_RE.replace(r"\\r", ""))]),
    ("改行類から LF を外す", [(CAPTION_RE, CAPTION_RE.replace(r"\\n", ""))]),
    ("改行類から U+0085 を外す", [(CAPTION_RE, CAPTION_RE.replace(r"\\x{85}", ""))]),
    ("改行類から U+2028 を外す", [(CAPTION_RE, CAPTION_RE.replace(r"\\x{2028}", ""))]),
    ("改行類から U+2029 を外す", [(CAPTION_RE, CAPTION_RE.replace(r"\\x{2029}", ""))]),
    ("改行類の代わりに空白類（\\s）を禁じる", [(CAPTION_RE, r"[^\\s\\x{85}\\x{2028}\\x{2029}]{1,100}")]),
    # 投稿の更新と削除
    ("投稿の更新を許す", [("isValidSoratomoSky(request.resource.data);\n        allow update: if false;",
                          "isValidSoratomoSky(request.resource.data);\n        allow update: if true;")]),
    ("削除の投稿者判定を外す", [(SKY_DELETE, "allow delete: if isSoratomoUser();")]),
    ("削除の条件をすべて外す", [(SKY_DELETE, "allow delete: if true;")]),
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
    # --mutants は 40 回あまり呼ぶので、接続が切れるなどの一時的な失敗は 3 回まで再試行する（HTTP のエラーは再試行しない）
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
