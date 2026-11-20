#!/usr/bin/env python3
"""firestore_shape_diff.py ⭐️☁️

本番の Firestore のドキュメントを 2 つ（Android が書いたもの・iOS 版で同じ操作をして書いたもの）読み取り専用で取得し、
キーごとの型を並べて差分を出す（Kiro android-mvp タスク 17.2・要件 17.7）。

なぜ必要か:
  Android の書き込みは契約モジュール（android/contract の ShapeContracts.kt）で形を縛っているが、
  それが「iOS 版が実際に書いている形」と合っているかは、本物のドキュメントを並べないと分からない。
  片方の OS だけが読めない事故（型の違い・キーの欠け）を、出荷前に見つけるための手順。

出すもの・出さないもの:
  - 出すのはキーの道筋（`images[].url` のように配列の要素とマップの中まで）と型の名前だけ。
  - **値は一切出さない**（メールアドレス・通知のトークンなどが入っているため）。取得に使うトークンも出さない。
  - 取得の失敗は HTTP の状態コードだけを出す（応答の本文は出さない）。

使い方:
  # 本番から 2 つ取得して比べる（コレクションは同じであること）
  python3 android/tools/firestore_shape_diff.py --android users/<AndroidのUID> --ios users/<iOSのUID>
  python3 android/tools/firestore_shape_diff.py --android publicProfiles/<UID> --ios publicProfiles/<UID>
  # 手元の JSON（REST の Document 形式 {"fields": {...}}）同士を比べる（通信しない）
  python3 android/tools/firestore_shape_diff.py --android-file a.json --ios-file b.json --collection users

  401 が返るときは firebase CLI のトークンが古いので、`firebase projects:list` を一度実行してから再実行する。

認証:
  firebase CLI のログイン情報（~/.config/configstore/firebase-tools.json）のアクセストークンを使う（管理者として読む）。
  使うのは GET だけ。書き込みの要求は作らない。

終了コード: 0 = 想定外の差分なし / 1 = 想定外の差分あり / 2 = 使い方の誤り・取得の失敗

想定外の差分が出たときは、どちらが正しいかを iOS のコードで確かめ、契約（ShapeContracts.kt）とテストのフィクスチャを直す。
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

PROJECT_ID = "soramoyou-ios"
DOCUMENTS_URL = f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}/databases/(default)/documents/"
TOKEN_FILE = os.path.expanduser("~/.config/configstore/firebase-tools.json")

MATCH = "一致"
EXPECTED = "想定内"
UNEXPECTED = "⚠️想定外"

# ---- 想定内の差分（「片方にだけある」ことが分かっているキー。トップレベルのキーか、`images[].externalEditInfo` のような道筋） ----
# ここに無い差分は全て想定外として目立たせる。両方にあって型が違うものは、ここに載っていても想定外。
# マイルストーンが進んだら（M3 のいいね・M4 の投稿）、コレクションをここに足す。

# iOS だけが書く（Android は書かない）キー。理由は表に出す。
EXPECTED_IOS_ONLY = {
    "users": {
        # 要件 2.10：1 ユーザー 1 トークン。Android が書くと iOS 端末への通知が途切れる（ShapeContracts.USER_CREATE の注）
        "fcmToken": "通知のトークン（Android は書かない・要件 2.10）",
        "fcmTokenUpdatedAt": "通知のトークンの更新日時（Android は書かない・要件 2.10）",
        # 以下は Android MVP に機能が無い（User.swift:106-156 toFirestoreData と各機能の書き込み）
        "iapAccountToken": "課金（Android MVP に無い）",
        "followedTags": "タグのフォロー（Android MVP に無い）",
        "customEditTools": "編集ツールの装備（Android MVP に無い）",
        "customEditToolsOrder": "編集ツールの並び（Android MVP に無い）",
        "blockedUserIds": "ブロック（M5 で作る）",
    },
    "publicProfiles": {
        # PublicProfile.swift:80-116 toFirestoreData。Android の PUBLIC_PROFILE_CREATE は書かない
        "customEditTools": "編集ツールの装備（Android MVP に無い）",
        "customEditToolsOrder": "編集ツールの並び（Android MVP に無い）",
        "recommendedPostIds": "おすすめの空（Android MVP に無い）",
    },
    # M3（タスク 19.2）：iOS も userId・postId・createdAt の 3 項目だけを書く（Like.swift toFirestoreData）ので、差分は無いはず
    "likes": {},
    # M4（タスク 25.3）：Post.swift:119-210 toFirestoreData・ImageInfo.swift:55-77。Android の POST_CREATE は書かない（設計書「Androidが書かないキー」）
    "posts": {
        "editSettings": "編集の設定（Android MVP に無い・要件 8.1）",
        "editRecipeV1": "編集のレシピ（Android MVP に無い・要件 8.1）",
        "originalImages": "編集前の画像（Android MVP に無い）",
        "mood": "気分（Android MVP に無い）",
        "frameId": "フレーム（Android MVP に無い）",
        "frameCaption": "フレーム（Android MVP に無い）",
        "frameTextColorHex": "フレーム（Android MVP に無い）",
        "frameFontStyle": "フレーム（Android MVP に無い）",
        "postKind": "コラージュ（Android MVP に無い。iOS も single のときは書かない）",
        "collageLayout": "コラージュ（Android MVP に無い）",
        "panelLabels": "コラージュ（Android MVP に無い）",
        "location": "位置情報（Android MVP に無い）",
        "skyColors": "空の色の解析（Android MVP に無い・要件 7.17）",
        "skyType": "空の種類の判定（Android MVP に無い・要件 7.17）",
        "colorTemperature": "色温度の解析（Android MVP に無い・要件 7.17）",
        # 配列の中のマップのキーも、道筋で書ける（その下の道筋も想定内になる）
        "images[].externalEditInfo": "写真の編集歴（Android は書かない・ImagePickerService.swift:188-190）",
    },
}

# Android だけが書くキー。今は無い（あれば iOS が読まずに捨てる＝契約の誤りの疑い）。
EXPECTED_ANDROID_ONLY = {
    "users": {},
    "publicProfiles": {},
    "likes": {},
    "posts": {},
}

# REST の値の種類 → 表に出す型の名前
_VALUE_TYPES = {
    "stringValue": "string",
    "integerValue": "integer",
    "doubleValue": "double",
    "timestampValue": "timestamp",
    "booleanValue": "boolean",
    "nullValue": "null",
    "mapValue": "map",
    "arrayValue": "array",
    "referenceValue": "reference",
    "geoPointValue": "geopoint",
    "bytesValue": "bytes",
}


def _add(shape, path, type_name):
    shape.setdefault(path, set()).add(type_name)


def _walk(shape, path, value):
    """1 つの値の型を shape に足し、マップと配列は中まで降りる（値そのものは見るだけで持たない）"""
    kinds = [k for k in value if k in _VALUE_TYPES]
    type_name = _VALUE_TYPES[kinds[0]] if kinds else "unknown"
    _add(shape, path, type_name)
    if type_name == "map":
        for key, child in (value["mapValue"].get("fields") or {}).items():
            _walk(shape, f"{path}.{key}", child)
    elif type_name == "array":
        # 要素は位置でなく「要素たち」として 1 本の道筋にまとめる（images[0] と images[1] を区別しない）
        for element in value["arrayValue"].get("values") or []:
            _walk(shape, f"{path}[]", element)


def shape_of(fields):
    """REST の fields（{キー: 値}）から {道筋: 型の集合} を作る"""
    shape = {}
    for key, value in fields.items():
        _walk(shape, key, value)
    return shape


@dataclass
class Row:
    path: str
    android: set
    ios: set
    status: str
    note: str = ""


def _expected_key(path, expected):
    """path が想定内のキー（道筋）そのものか、その下（`.` か `[` で続く）なら、そのキーを返す。無ければ None

    `images[].externalEditInfo.isHDR` → `images[].externalEditInfo`、`followedTags[]` → `followedTags`。
    `images[].externalEditInfoV2` は区切りが続かないので、`images[].externalEditInfo` の下ではない。
    """
    for key in expected:
        if path == key or path.startswith(key + ".") or path.startswith(key + "["):
            return key
    return None


def compare(android_shape, ios_shape, collection):
    """2 つの shape を道筋ごとに並べ、一致・想定内・想定外を付ける"""
    if collection not in EXPECTED_IOS_ONLY:
        raise ValueError(f"想定内の差分が定まっていないコレクション: {collection}（EXPECTED_IOS_ONLY に足すこと）")
    ios_only = EXPECTED_IOS_ONLY[collection]
    android_only = EXPECTED_ANDROID_ONLY[collection]
    rows = []
    for path in sorted(set(android_shape) | set(ios_shape)):
        a, i = android_shape.get(path, set()), ios_shape.get(path, set())
        ios_key, android_key = _expected_key(path, ios_only), _expected_key(path, android_only)
        if a == i:
            rows.append(Row(path, a, i, MATCH))
        elif not a and ios_key and ios_key not in android_shape:
            rows.append(Row(path, a, i, EXPECTED, ios_only[ios_key]))
        elif not i and android_key and android_key not in ios_shape:
            rows.append(Row(path, a, i, EXPECTED, android_only[android_key]))
        else:
            rows.append(Row(path, a, i, UNEXPECTED, "型の違い" if a and i else "片方にだけある"))
    return rows


def has_unexpected(rows):
    return any(r.status == UNEXPECTED for r in rows)


def _types(t):
    return " / ".join(sorted(t)) if t else "（なし）"


def render(rows):
    """Markdown の表。想定外を先頭に、次に想定内、最後に一致を並べる"""
    order = {UNEXPECTED: 0, EXPECTED: 1, MATCH: 2}
    lines = ["| 判定 | キー | Android | iOS | 理由 |", "|---|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: (order[r.status], r.path)):
        lines.append(f"| {r.status} | `{r.path}` | {_types(r.android)} | {_types(r.ios)} | {r.note} |")
    counts = {s: sum(1 for r in rows if r.status == s) for s in (UNEXPECTED, EXPECTED, MATCH)}
    lines.append("")
    lines.append(f"想定外 {counts[UNEXPECTED]} 件・想定内 {counts[EXPECTED]} 件・一致 {counts[MATCH]} 件")
    return "\n".join(lines)


def load_token():
    """firebase CLI のアクセストークン。値は返すだけで、どこにも出さない"""
    with open(TOKEN_FILE) as f:
        return json.load(f)["tokens"]["access_token"]


def _collection_of(doc_path):
    parts = doc_path.strip("/").split("/")
    if len(parts) % 2 != 0 or not all(parts):
        raise ValueError(f"ドキュメントの道筋ではない（コレクション/ID の組で書く）: {doc_path}")
    # サブコレクション（posts/P/likes/L）なら最後のコレクション名（likes）
    return parts[-2]


def fetch_fields(doc_path, token, opener):
    """本番から 1 件を GET で取得し、fields を返す"""
    url = DOCUMENTS_URL + urllib.parse.quote(doc_path.strip("/"), safe="/")
    req = urllib.request.Request(url, method="GET", headers={"Authorization": "Bearer " + token})
    with opener(req, timeout=30) as resp:
        return json.load(resp).get("fields") or {}


def _load_file(path):
    with open(path) as f:
        data = json.load(f)
    return data.get("fields", data) if isinstance(data, dict) else {}


class _UsageError(Exception):
    pass


def _parse(argv):
    p = argparse.ArgumentParser(description="Android と iOS 版が書いた Firestore のドキュメントの、キーと型の差分を出す（値は出さない）")
    p.add_argument("--android", help="Android が書いたドキュメントの道筋（例: users/UID）")
    p.add_argument("--ios", help="iOS 版で同じ操作をして書いたドキュメントの道筋")
    p.add_argument("--android-file", help="手元の JSON（REST の Document 形式）")
    p.add_argument("--ios-file", help="手元の JSON（REST の Document 形式）")
    p.add_argument("--collection", help="ファイル同士を比べるときのコレクション名（users / publicProfiles / likes / posts）")
    try:
        args = p.parse_args(argv)
    except SystemExit as e:
        raise _UsageError("引数の誤り") from e
    remote, local = bool(args.android or args.ios), bool(args.android_file or args.ios_file)
    if remote == local:
        raise _UsageError("--android と --ios の組か、--android-file と --ios-file の組のどちらか一方を指定する")
    if remote and not (args.android and args.ios):
        raise _UsageError("--android と --ios は両方指定する")
    if local and not (args.android_file and args.ios_file and args.collection):
        raise _UsageError("ファイル同士を比べるときは --android-file・--ios-file・--collection を全て指定する")
    return args


def main(argv=None, stdout=sys.stdout, stderr=sys.stderr, token_loader=load_token, opener=urllib.request.urlopen):
    try:
        args = _parse(sys.argv[1:] if argv is None else argv)
        if args.android:
            collection = _collection_of(args.android)
            if _collection_of(args.ios) != collection:
                raise _UsageError("Android と iOS のドキュメントは同じコレクションのものを指定する")
        else:
            collection = args.collection
        if collection not in EXPECTED_IOS_ONLY:
            raise _UsageError(f"想定内の差分が定まっていないコレクション: {collection}")
    except (_UsageError, ValueError) as e:
        print(f"使い方の誤り: {e}", file=stderr)
        return 2

    try:
        if args.android:
            token = token_loader()
            android_fields = fetch_fields(args.android, token, opener)
            ios_fields = fetch_fields(args.ios, token, opener)
        else:
            android_fields, ios_fields = _load_file(args.android_file), _load_file(args.ios_file)
    except urllib.error.HTTPError as e:
        # 本文には要求の中身が入ることがあるので出さない。状態コードだけ
        e.close()
        print(f"取得に失敗: HTTP {e.code}（401 なら `firebase projects:list` を一度実行してから再実行）", file=stderr)
        return 2
    except (urllib.error.URLError, OSError, KeyError, json.JSONDecodeError) as e:
        # 例外の文字列には値やトークンが載りうるので、種類の名前だけを出す
        print(f"取得に失敗: {type(e).__name__}", file=stderr)
        return 2

    rows = compare(shape_of(android_fields), shape_of(ios_fields), collection)
    print(f"コレクション: {collection}", file=stdout)
    print(render(rows), file=stdout)
    return 1 if has_unexpected(rows) else 0


if __name__ == "__main__":
    sys.exit(main())
