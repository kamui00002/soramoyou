#!/usr/bin/env python3
# ⭐️☀️ 見た目の検証（Kiro android-ui-ios-parity 1.1・1.2・13.x）で撮る画面のデータを、Firebase エミュレータに毎回同じ形で作り直す
#
# なぜ台本にするか:
#   エミュレータのデータはメモリにだけあり、止めると消える（start-firebase-emulators.sh は import/export をしない）。
#   作業の前（1.2）と後（13.x）で同じデータを撮り比べるため、作り方をここに固定する。
#
# なぜ画像の URL を picsum.photos にしたか（2026-10-17 ユーザー判断）:
#   写真を実際に写すために、外から読める https の画像を使った。id を固定した URL は毎回同じ写真を返す（空の写真とは限らない）。
#   本番の Firebase には一切触れない。
# ⚠️ 検証用のビルドが表示する画像は、エミュレータの Storage のダウンロード URL の形（StorageDownloadUrl.EMULATOR_PATTERN）だけ
#   （全体レビュー 4 回目 R11・ユーザー判断）なので、この台本の picsum の投稿は画像が 1 枚も読めず、フィードとプロフィールの一覧から飛ばされる。アイコンは頭文字の表示になる。
#   写真の写った画面を撮り直すときは、画像をエミュレータの Storage に上げて、その URL を書く形に台本を直す（まだしていない）。
#
# 使い方:
#   1. android/tools/start-firebase-emulators.sh を起動しておく
#   2. python3 android/tools/seed-ui-parity-emulator.py
#   3. 検証用ビルド（emulatorDebug）で、下の ME_EMAIL と ME_PASSWORD でログインする
#
# ⚠️ プロジェクト demo-soramoyou の Firestore の文書と Auth のアカウントを全部消してから作る（エミュレータの中だけ。本番には繋がらない）。
import json
import sys
import urllib.error
import urllib.request

PROJECT_ID = "demo-soramoyou"  # FirebaseEmulator.kt と同じ（demo- は本物のプロジェクトに割り当てられない）
FIRESTORE = "http://127.0.0.1:8080"
AUTH = "http://127.0.0.1:9099"
DOCS = f"{FIRESTORE}/v1/projects/{PROJECT_ID}/databases/(default)/documents"

# ログインに使うアカウント（エミュレータの中だけの値。本番のアカウントではない）
ME_EMAIL = "ui-parity-me@example.com"
ME_PASSWORD = "uiparity-1017"

# uid は Firebase と同じ 28 文字に揃える（読みやすさのため英小文字と数字だけ）
ME = "uiparityme000000000000000001"
OTHER = "uiparityother000000000000001"
BLOCKED = "uiparityblocked0000000000001"

# 画像：picsum の id ごとの本体（1080×1440）とサムネイル（512×683）。iOS・Android の投稿と同じ縦長の比
IMAGE_W, IMAGE_H = 1080, 1440
THUMB_W, THUMB_H = 512, 683


def image_url(picsum_id, w, h):
    return f"https://picsum.photos/id/{picsum_id}/{w}/{h}.jpg"


# ---- 送受信 -------------------------------------------------------------------------------------------------------

def call(method, url, body=None, token="owner"):
    """エミュレータへ送る。token="owner" はルールを通さない管理者として扱われる。戻り値は (状態コード, JSON)。"""
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=20) as res:
            return res.status, parse(res.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:300]}


def parse(text):
    """応答の本文。エミュレータの入口（`/`）は JSON でなく `Ok` の文字を返すので、読めないときは文字のまま返す。"""
    try:
        return json.loads(text) if text else {}
    except json.JSONDecodeError:
        return {"text": text[:300]}


def require(ok, message):
    if not ok:
        print(f"❌ {message}", file=sys.stderr)
        sys.exit(1)


# ---- Firestore の値の書き方（REST の形） ---------------------------------------------------------------------------

def fs(value):
    if isinstance(value, bool):
        return {"booleanValue": value}
    if isinstance(value, int):
        return {"integerValue": str(value)}
    if isinstance(value, str):
        return {"stringValue": value}
    if isinstance(value, Time):
        return {"timestampValue": value.iso}
    if isinstance(value, list):
        return {"arrayValue": {"values": [fs(v) for v in value]}}
    if isinstance(value, dict):
        return {"mapValue": {"fields": {k: fs(v) for k, v in value.items()}}}
    raise TypeError(value)


class Time:
    def __init__(self, iso):
        self.iso = iso


# ---- データ（契約 DocumentBuilders の userCreate・publicProfileCreate・postCreate と同じキー） ------------------------

CREATED = Time("2026-10-01T00:00:00Z")

PEOPLE = [
    # uid, メール, 表示名, 自己紹介, アイコンの picsum id（None はアイコンなし＝頭文字の表示）
    (ME, ME_EMAIL, "そらみ", "朝と夕方の空をあつめています。", None),
    (OTHER, "ui-parity-other@example.com", "くもの観測者",
     "毎日おなじ場所から空を撮っています。雲のかたちが好きです。", 1018),
    (BLOCKED, "ui-parity-blocked@example.com", "ブロック中のひと", None, None),
]

# postId, 投稿者, 公開範囲, 作成日時, キャプション, ハッシュタグ, 時間帯, 画像の picsum id の並び
# フィードは公開の投稿を新しい順に並べる。ブロック中のひとの投稿をいちばん新しくして、フィードに出たら除外が効いていないと分かるようにする
POSTS = [
    ("UIPARITY-BLOCKED-1", BLOCKED, "public", "2026-10-16T10:00:00Z", "この投稿はフィードに出ないはず", [], "evening", [1069]),
    ("UIPARITY-OTHER-1", OTHER, "public", "2026-10-16T09:00:00Z",
     "雨上がりの夕方、西の空だけ晴れて、雲の縁が金色に光っていました。しばらく見とれて、帰り道を少し遠回りしました #夕焼け #雲",
     ["夕焼け", "雲"], "evening", [1015, 1016]),
    ("UIPARITY-ME-1", ME, "public", "2026-10-16T08:00:00Z", "今日の朝焼け #朝焼け #空", ["朝焼け", "空"], "morning", [1036]),
    ("UIPARITY-OTHER-2", OTHER, "public", "2026-10-15T09:00:00Z", "高い空 #秋の空", ["秋の空"], "afternoon", [1043]),
    ("UIPARITY-ME-2", ME, "public", "2026-10-15T08:00:00Z", "3枚まとめて", [], "afternoon", [1044, 1056, 1018]),
    ("UIPARITY-OTHER-3", OTHER, "public", "2026-10-14T09:00:00Z", None, [], "night", [1056]),
    ("UIPARITY-ME-3", ME, "private", "2026-10-14T08:00:00Z", "自分だけの空", [], "night", [1069]),
]


def post_fields(post_id, uid, visibility, created, caption, hashtags, time_of_day, picsum_ids):
    images = []
    for order, pid in enumerate(picsum_ids):
        image_id = f"{post_id}-{order}"
        images.append({
            "url": image_url(pid, IMAGE_W, IMAGE_H),
            "width": IMAGE_W,
            "height": IMAGE_H,
            "order": order,
            "thumbnail": image_url(pid, THUMB_W, THUMB_H),
            "storagePath": f"posts/{uid}/{visibility}/{image_id}.jpg",
            "thumbnailStoragePath": f"thumbnails/{uid}/{visibility}/{image_id}_thumb.jpg",
        })
    doc = {
        "postId": post_id,
        "userId": uid,
        "images": images,
        "visibility": visibility,
        "likesCount": 0,
        "commentsCount": 0,
        "createdAt": Time(created),
        "updatedAt": Time(created),
        "capturedAt": Time(created),
        "timeOfDay": time_of_day,
    }
    if caption is not None:
        doc["caption"] = caption
    if hashtags:
        doc["hashtags"] = hashtags
    return doc


def counts(uid):
    mine = [p for p in POSTS if p[1] == uid]
    return len(mine), len([p for p in mine if p[2] == "public"])


def profile_fields(uid, name, bio, icon):
    out = {}
    if name:
        out["displayName"] = name
    if icon is not None:
        out["photoURL"] = image_url(icon, 200, 200)
    if bio:
        out["bio"] = bio
    return out


def user_fields(uid, email, name, bio, icon):
    all_count, _ = counts(uid)
    doc = {
        "id": uid, "createdAt": CREATED, "updatedAt": CREATED, "email": email,
        "followersCount": 0, "followingCount": 0, "postsCount": all_count,
        "notifyReactions": True, "notifyNewPostsFromFollowing": True, "notifyNewPostsFromEveryone": False,
    }
    doc.update(profile_fields(uid, name, bio, icon))
    if uid == ME:
        doc["blockedUserIds"] = [BLOCKED]
    return doc


def public_profile_fields(uid, name, bio, icon):
    _, public_count = counts(uid)
    doc = {"id": uid, "createdAt": CREATED, "updatedAt": CREATED,
           "followersCount": 0, "followingCount": 0, "postsCount": public_count}
    doc.update(profile_fields(uid, name, bio, icon))
    return doc


# ---- 手順 --------------------------------------------------------------------------------------------------------

def main():
    # 1. エミュレータが起動しているか
    try:
        call("GET", f"{FIRESTORE}/")
        call("GET", f"{AUTH}/")
    except urllib.error.URLError as e:
        require(False, f"エミュレータに繋がらない（start-firebase-emulators.sh を起動したか）: {e}")

    # 2. 前のデータを消す（demo-soramoyou の中だけ）
    status, _ = call("DELETE", f"{FIRESTORE}/emulator/v1/projects/{PROJECT_ID}/databases/(default)/documents")
    require(status == 200, f"Firestore の消去が {status}")
    status, _ = call("DELETE", f"{AUTH}/emulator/v1/projects/{PROJECT_ID}/accounts")
    require(status == 200, f"Auth の消去が {status}")

    # 3. Auth のアカウント（uid を固定して作る。管理者の作成の呼び方）
    for uid, email, name, _, _ in PEOPLE:
        password = ME_PASSWORD if uid == ME else f"{ME_PASSWORD}-{uid[-4:]}"
        status, body = call("POST", f"{AUTH}/identitytoolkit.googleapis.com/v1/projects/{PROJECT_ID}/accounts",
                            {"localId": uid, "email": email, "password": password, "displayName": name})
        require(status == 200 and body.get("localId") == uid, f"アカウントの作成 {uid}: {status} {body}")

    # 4. 文書（1 回のコミットでまとめて書く）
    writes = []

    def put(path, fields):
        writes.append({"update": {"name": f"projects/{PROJECT_ID}/databases/(default)/documents/{path}",
                                  "fields": {k: fs(v) for k, v in fields.items()}}})

    for uid, email, name, bio, icon in PEOPLE:
        put(f"users/{uid}", user_fields(uid, email, name, bio, icon))
        put(f"publicProfiles/{uid}", public_profile_fields(uid, name, bio, icon))
    for post in POSTS:
        put(f"posts/{post[0]}", post_fields(*post))
    status, body = call("POST", f"{DOCS}:commit", {"writes": writes})
    require(status == 200, f"文書の書き込みが {status} {body}")

    # 5. 確かめる：ログインする人の権限（ルールを通す）で、フィードと同じ問い合わせを流す
    status, body = call("POST", f"{AUTH}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake",
                        {"email": ME_EMAIL, "password": ME_PASSWORD, "returnSecureToken": True}, token=None)
    require(status == 200 and body.get("localId") == ME, f"ログインの確認が {status}")
    id_token = body["idToken"]
    query = {"structuredQuery": {
        "from": [{"collectionId": "posts"}],
        "where": {"fieldFilter": {"field": {"fieldPath": "visibility"}, "op": "EQUAL", "value": {"stringValue": "public"}}},
        "orderBy": [{"field": {"fieldPath": "createdAt"}, "direction": "DESCENDING"}],
        "limit": 20,  # QuerySpec.PublicFeed.PAGE_SIZE と同じ
    }}
    status, rows = call("POST", f"{DOCS}:runQuery", query, token=id_token)
    require(status == 200, f"フィードの問い合わせが {status} {rows}")
    feed = [r["document"]["name"].rsplit("/", 1)[1] for r in rows if "document" in r]
    expected = [p[0] for p in POSTS if p[2] == "public"]
    require(feed == expected, f"公開の投稿の並びが想定と違う: {feed}")

    status, me_doc = call("GET", f"{DOCS}/users/{ME}", token=id_token)
    require(status == 200, f"自分のユーザー文書の読み取りが {status}")
    blocked = [v["stringValue"] for v in me_doc["fields"]["blockedUserIds"]["arrayValue"]["values"]]
    require(blocked == [BLOCKED], f"blockedUserIds が想定と違う: {blocked}")

    print(f"✅ アカウント {len(PEOPLE)}・文書 {len(writes)}（users と publicProfiles 各 {len(PEOPLE)}・posts {len(POSTS)}）を作った")
    print(f"   ログインする人の権限での公開の投稿（新しい順）: {feed}")
    print(f"   アプリのフィードには、ブロック中の {BLOCKED} の投稿を除いた {len(feed) - 1} 件が出るはず")
    print(f"   ログイン: {ME_EMAIL}")


if __name__ == "__main__":
    main()
