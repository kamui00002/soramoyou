#!/usr/bin/env python3
# ⭐️☀️ Play のスクリーンショット（Kiro android-mvp タスク 36）で撮る画面のデータを、Firebase エミュレータに作る台本
#
# なぜ android/tools/seed-ui-parity-emulator.py を使わないか:
#   あちらは見た目の検証用で、表示名・キャプションが検証の言葉（「この投稿はフィードに出ないはず」など）になっている。
#   また 2026-11-07（レビュー R11）から検証用ビルドはエミュレータの Storage のダウンロード URL の形
#   （StorageDownloadUrl.EMULATOR_PATTERN）の画像しか表示しないので、picsum の画像の投稿は一覧から飛ばされる。
#   ここでは利用者が撮った空の写真を Storage のエミュレータに上げ、その URL を投稿に書く。
#
# 使い方:
#   1. android/tools/start-firebase-emulators.sh を起動しておく（Auth 9099・Firestore 8080・Storage 9199）
#   2. derive_photos.swift で写真を縮めておく（NN-body.jpg・NN-thumb.jpg・NN-icon.jpg・manifest.json）
#   3. python3 -I screenshots/playstore-2026-11-08/tools/seed_play_screenshots.py <縮めた写真のフォルダ>
#   4. 検証用ビルド（emulatorDebug）で、下の ME_EMAIL と ME_PASSWORD でログインする
#
# 写真の送り方（Storage）:
#   本人の ID トークンで、multipart の 1 回の要求で送る（functions/postsFollowersStorage.emulator.test.js の upload() と同じ形・
#   Web の SDK の uploadBytes と同じ入口）。ルールを通る（storage.rules の isOwner・画像の種類・5MB 未満）。
#   管理者（Bearer owner）で生のバイト列を POST したらエミュレータ全体が落ちた記録（2026-10-10）があるので、その形は使わない。
#
# 投稿に書く URL:
#   送る先は開発機の 127.0.0.1:9199 だが、投稿に書くのは仮想端末から見た開発機（10.0.2.2:9199）の URL にする
#   （アプリが自分で上げたときに SDK が返す形と同じ。EMULATOR_PATTERN の宛先）。末尾の token はアップロードの応答の downloadTokens。
#   アイコン（users/{uid}/profile/）は「ログインした人だけ読める」ルールなので、token が無いと画像の読み込み（認証なし）で読めない。
#
# ⚠️ プロジェクト demo-soramoyou の Firestore の文書と Auth のアカウントを全部消してから作る（エミュレータの中だけ。本番には繋がらない）。
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

PROJECT_ID = "demo-soramoyou"  # FirebaseEmulator.kt と同じ（demo- は本物のプロジェクトに割り当てられない）
BUCKET = f"{PROJECT_ID}.appspot.com"  # EMULATOR_PATTERN のバケット（検証用の google-services.json と EmulatorBuildIsolationTest が突き合わせる）


def emulator_host(env_name, default):
    """送る先。Firebase の標準の環境変数で替えられる（別の作業が既定のポートを使っているとき）。開発機の中（127.0.0.1）だけ許す"""
    host = os.environ.get(env_name, default)
    if not re.fullmatch(r"127[.]0[.]0[.]1:[0-9]{2,5}", host):
        print(f"❌ {env_name} は 127.0.0.1:<ポート> だけ: {host}", file=sys.stderr)
        sys.exit(1)
    return f"http://{host}"


FIRESTORE = emulator_host("FIRESTORE_EMULATOR_HOST", "127.0.0.1:8080")
AUTH = emulator_host("FIREBASE_AUTH_EMULATOR_HOST", "127.0.0.1:9099")
STORAGE = emulator_host("FIREBASE_STORAGE_EMULATOR_HOST", "127.0.0.1:9199")
# 仮想端末から見た開発機（FirebaseEmulator.HOST・STORAGE_PORT）。送る先のポートを替えても、投稿に書くのはこの形のまま
# （アプリと EMULATOR_PATTERN はこのポートに決め打ち。替えたときは仮想端末の中で宛先を付け替える）
DEVICE_STORAGE = "http://10.0.2.2:9199"
DOCS = f"{FIRESTORE}/v1/projects/{PROJECT_ID}/databases/(default)/documents"

# 契約の StorageDownloadUrl.EMULATOR_PATTERN と同じ文字列（rules は RE2・ここは Python の re。使う記号は同じ意味）
EMULATOR_PATTERN = r"http://10[.]0[.]2[.]2:9199/v0/b/demo-soramoyou[.]appspot[.]com/o/[A-Za-z0-9_.~%-]+([?][A-Za-z0-9_.~%=&-]*)?"

# ログインに使うアカウント（エミュレータの中だけの値。本番のアカウントではない。メールは画面に写さない）
ME_EMAIL = "play-shot-me@example.com"
ME_PASSWORD = "playshot-1108"

# uid は Firebase と同じ 28 文字に揃える（読みやすさのため英小文字と数字だけ）
ME = "playshotme000000000000000001"
CLOUD = "playshotcloud000000000000001"
DUSK = "playshotdusk0000000000000001"

# uid, メール, 表示名, 自己紹介, アイコンにする写真の番号
PEOPLE = [
    (ME, ME_EMAIL, "そらみ", "見上げた空を、少しずつ残しています。", "03"),
    (CLOUD, "play-shot-cloud@example.com", "くもの観測者", "雲のかたちが好きです。晴れた日は山のほうへ。", "08"),
    (DUSK, "play-shot-dusk@example.com", "ゆうやけ通信", "夕方の空を中心に撮っています。", "06"),
]

# 投稿（新しい順）：番号, 投稿者, 作成日時（UTC。日本時間は +9 時間）, キャプション, ハッシュタグ, 時間帯, 写真の番号の並び, いいねの数
# 撮影日時（capturedAt）は書かない（写真の本当の撮影日時を知らないので、作った日時を見せない）
# ログインする人（そらみ）を 6 件にして、プロフィールの写真の一覧をちょうど 2 段（3 列×2）にする
POSTS = [
    ("P1", CLOUD, "2026-11-07T05:10:00Z", "山の上に、大きな入道雲がひとつ #入道雲 #青空", ["入道雲", "青空"], "afternoon", ["08"], 24),
    ("P2", DUSK, "2026-11-06T07:50:00Z", "すじ雲が夕日に染まって、山の向こうまで #夕焼け #すじ雲", ["夕焼け", "すじ雲"], "evening", ["06"], 18),
    ("P3", ME, "2026-11-05T08:00:00Z", "うろこ雲が空いっぱいに。日が沈むまで見ていました #うろこ雲 #夕方の空", ["うろこ雲", "夕方の空"], "evening", ["03"], 15),
    ("P4", ME, "2026-11-04T04:20:00Z", "電柱の向こうに、もくもく #入道雲", ["入道雲"], "afternoon", ["01"], 9),
    ("P5", ME, "2026-11-03T03:30:00Z", "真っ青な空に、白い雲がひとつ #青空", ["青空"], "afternoon", ["07"], 11),
    ("P6", DUSK, "2026-11-02T07:40:00Z", "帰り道に見上げた夕焼け #夕焼け", ["夕焼け"], "evening", ["05"], 7),
    ("P7", ME, "2026-11-01T07:20:00Z", "夕方の雲と、草のにおい #夕方の空", ["夕方の空"], "evening", ["09"], 6),
    ("P8", ME, "2026-10-31T05:00:00Z", "雲が低くて、空が近い日 #雲", ["雲"], "afternoon", ["02"], 5),
    ("P9", ME, "2026-10-30T04:00:00Z", "山の上を雲が流れていく #雲 #山", ["雲", "山"], "afternoon", ["04"], 8),
]

# ログインする人（そらみ）がいいねを付けた投稿（投稿の詳細でハートが付いた状態を撮るため）
ME_LIKES = ["P1", "P2"]

CREATED = "2026-10-01T00:00:00Z"
ID_NAMESPACE = uuid.UUID("ffffffff-ffff-4fff-8fff-ffffffffffff")  # 何度作り直しても同じ ID にするための名前空間


def stable_id(name):
    """アプリと同じ大文字の UUID の形の ID を、名前から毎回同じ値で作る"""
    return str(uuid.uuid5(ID_NAMESPACE, name)).upper()


# ---- 送受信 -------------------------------------------------------------------------------------------------------

def request(method, url, body=None, headers=None):
    """送って (状態コード, 本文のバイト列) を返す。HTTP の失敗も状態コードで返す"""
    req = urllib.request.Request(url, data=body, method=method)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return res.status, res.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def call(method, url, body=None, token="owner"):
    """JSON を送る。token="owner" はルールを通さない管理者（Firestore・Auth だけに使う）。戻り値は (状態コード, JSON)"""
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    status, raw = request(method, url, None if body is None else json.dumps(body).encode(), headers)
    return status, parse(raw.decode(errors="replace"))


def parse(text):
    """応答の本文。エミュレータの入口（`/`）は JSON でなく `Ok` の文字を返すので、読めないときは文字のまま返す"""
    try:
        return json.loads(text) if text else {}
    except json.JSONDecodeError:
        return {"text": text[:300]}


def require(ok, message):
    if not ok:
        print(f"❌ {message}", file=sys.stderr)
        sys.exit(1)


# ---- Storage ------------------------------------------------------------------------------------------------------

def upload(path, data, id_token):
    """本人の ID トークンで 1 枚送り、仮想端末から読むダウンロード URL を返す（ルールを通る）"""
    boundary = "play-shot-boundary"
    meta = json.dumps({"name": path, "contentType": "image/jpeg"})
    body = b"".join([
        f"--{boundary}\r\nContent-Type: application/json; charset=utf-8\r\n\r\n{meta}\r\n".encode(),
        f"--{boundary}\r\nContent-Type: image/jpeg\r\n\r\n".encode(),
        data,
        f"\r\n--{boundary}--\r\n".encode(),
    ])
    status, raw = request("POST", f"{STORAGE}/v0/b/{BUCKET}/o?name={urllib.parse.quote(path, safe='')}", body, {
        "Authorization": f"Firebase {id_token}",
        "x-goog-upload-protocol": "multipart",
        "Content-Type": f"multipart/related; boundary={boundary}",
    })
    require(status == 200, f"{path} を送れない: {status} {raw[:300]!r}")
    tokens = parse(raw.decode(errors="replace")).get("downloadTokens", "")
    token = tokens.split(",")[0] if tokens else ""
    require(token != "", f"{path} の応答に downloadTokens が無い（URL を作れない）")
    url = f"{DEVICE_STORAGE}/v0/b/{BUCKET}/o/{urllib.parse.quote(path, safe='')}?alt=media&token={token}"
    require(re.fullmatch(EMULATOR_PATTERN, url) is not None, f"URL が EMULATOR_PATTERN に合わない: {url}")
    # 確かめ：同じ URL を開発機の宛先に替え、認証なし（アプリの画像の読み込みと同じ）で読めて、送った中身と同じか
    status, got = request("GET", url.replace(DEVICE_STORAGE, STORAGE, 1))
    require(status == 200 and got == data, f"{path} を token 付きの URL で読めない: {status}・{len(got)} バイト（送ったのは {len(data)}）")
    return url


# ---- Firestore の値の書き方（REST の形） ---------------------------------------------------------------------------

class Time:
    def __init__(self, iso):
        self.iso = iso


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


# ---- 手順 --------------------------------------------------------------------------------------------------------

def main():
    require(len(sys.argv) == 2, "使い方: seed_play_screenshots.py <縮めた写真のフォルダ>")
    photos = Path(sys.argv[1])
    manifest = json.loads((photos / "manifest.json").read_text())

    # 1. エミュレータが起動しているか（どれも読むだけ）
    try:
        call("GET", f"{FIRESTORE}/")
        call("GET", f"{AUTH}/")
        request("GET", f"{STORAGE}/v0/b/{BUCKET}/o/{urllib.parse.quote('probe/none.jpg', safe='')}")
    except urllib.error.URLError as e:
        require(False, f"エミュレータに繋がらない（start-firebase-emulators.sh を起動したか）: {e}")

    # 2. 前のデータを消す（demo-soramoyou の中だけ。Storage は同じ名前で上書きする）
    status, _ = call("DELETE", f"{FIRESTORE}/emulator/v1/projects/{PROJECT_ID}/databases/(default)/documents")
    require(status == 200, f"Firestore の消去が {status}")
    status, _ = call("DELETE", f"{AUTH}/emulator/v1/projects/{PROJECT_ID}/accounts")
    require(status == 200, f"Auth の消去が {status}")

    # 3. Auth のアカウント（uid を固定して作る）と、各人の ID トークン（Storage へ本人として送るため）
    tokens = {}
    for uid, email, name, _, _ in PEOPLE:
        password = ME_PASSWORD if uid == ME else f"{ME_PASSWORD}-{uid[-4:]}"
        status, body = call("POST", f"{AUTH}/identitytoolkit.googleapis.com/v1/projects/{PROJECT_ID}/accounts",
                            {"localId": uid, "email": email, "password": password, "displayName": name})
        require(status == 200 and body.get("localId") == uid, f"アカウントの作成 {uid}: {status} {body}")
        status, body = call("POST", f"{AUTH}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake",
                            {"email": email, "password": password, "returnSecureToken": True}, token=None)
        require(status == 200 and body.get("localId") == uid, f"ログインの確認 {uid}: {status}")
        tokens[uid] = body["idToken"]

    # 4. 写真を送る（アイコン → 投稿の本体とサムネイル）
    icons = {}
    for uid, _, _, _, icon in PEOPLE:
        icons[uid] = upload(f"users/{uid}/profile/profile.jpg", (photos / f"{icon}-icon.jpg").read_bytes(), tokens[uid])

    post_docs = {}
    for key, uid, created, caption, hashtags, time_of_day, numbers, likes in POSTS:
        post_id = stable_id(f"post-{key}")
        images = []
        for order, n in enumerate(numbers):
            image_id = stable_id(f"image-{key}-{order}")
            body_path = f"posts/{uid}/public/{image_id}.jpg"
            thumb_path = f"thumbnails/{uid}/public/{image_id}_thumb.jpg"
            images.append({
                "url": upload(body_path, (photos / f"{n}-body.jpg").read_bytes(), tokens[uid]),
                "width": manifest[n]["width"],
                "height": manifest[n]["height"],
                "order": order,
                "thumbnail": upload(thumb_path, (photos / f"{n}-thumb.jpg").read_bytes(), tokens[uid]),
                "storagePath": body_path,
                "thumbnailStoragePath": thumb_path,
            })
        post_docs[key] = (post_id, {
            "postId": post_id, "userId": uid, "images": images, "visibility": "public",
            "likesCount": likes, "commentsCount": 0,
            "createdAt": Time(created), "updatedAt": Time(created),
            "caption": caption, "hashtags": hashtags, "timeOfDay": time_of_day,
        })

    # 5. 文書（1 回のコミットでまとめて書く。契約 DocumentBuilders の userCreate・publicProfileCreate・postCreate・likeCreate と同じキー）
    writes = []

    def put(path, fields):
        writes.append({"update": {"name": f"projects/{PROJECT_ID}/databases/(default)/documents/{path}",
                                  "fields": {k: fs(v) for k, v in fields.items()}}})

    for uid, email, name, bio, _ in PEOPLE:
        count = len([p for p in POSTS if p[1] == uid])
        profile = {"displayName": name, "photoURL": icons[uid], "bio": bio}
        common = {"id": uid, "createdAt": Time(CREATED), "updatedAt": Time(CREATED),
                  "followersCount": 0, "followingCount": 0, "postsCount": count}
        put(f"users/{uid}", {**common, "email": email, "notifyReactions": True,
                             "notifyNewPostsFromFollowing": True, "notifyNewPostsFromEveryone": False, **profile})
        put(f"publicProfiles/{uid}", {**common, **profile})
    for post_id, doc in post_docs.values():
        put(f"posts/{post_id}", doc)
    for key in ME_LIKES:
        post_id = post_docs[key][0]
        put(f"likes/{ME}_{post_id}", {"userId": ME, "postId": post_id, "createdAt": Time("2026-11-07T09:00:00Z")})
    status, body = call("POST", f"{DOCS}:commit", {"writes": writes})
    require(status == 200, f"文書の書き込みが {status} {body}")

    # 6. 確かめる：ログインする人の権限（ルールを通す）で、フィードと同じ問い合わせを流す
    query = {"structuredQuery": {
        "from": [{"collectionId": "posts"}],
        "where": {"fieldFilter": {"field": {"fieldPath": "visibility"}, "op": "EQUAL", "value": {"stringValue": "public"}}},
        "orderBy": [{"field": {"fieldPath": "createdAt"}, "direction": "DESCENDING"}],
        "limit": 20,  # QuerySpec.PublicFeed.PAGE_SIZE と同じ
    }}
    status, rows = call("POST", f"{DOCS}:runQuery", query, token=tokens[ME])
    require(status == 200, f"フィードの問い合わせが {status} {rows}")
    feed = [r["document"]["name"].rsplit("/", 1)[1] for r in rows if "document" in r]
    expected = [post_docs[p[0]][0] for p in POSTS]
    require(feed == expected, f"公開の投稿の並びが想定と違う: {feed}")

    uploaded = len(PEOPLE) + 2 * sum(len(p[6]) for p in POSTS)
    print(f"✅ アカウント {len(PEOPLE)}・写真 {uploaded} 枚（どれも token 付きの URL を認証なしで読めた）・文書 {len(writes)} を作った")
    print(f"   フィードの並び（新しい順）: {', '.join(p[0] for p in POSTS)}")
    print(f"   投稿の詳細で撮る投稿（いいね済み）: {', '.join(ME_LIKES)}")
    print(f"   ログイン: {ME_EMAIL}")


if __name__ == "__main__":
    main()
