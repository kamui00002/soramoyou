#!/usr/bin/env python3
"""read-deployed-rules.py ☁️⭐️

本番（soramoyou-ios）に出ている Firestore と Storage のルールを Rules REST API で読み、
手元のファイルと比べられる形で保存する。
spec: .kiro/specs/soratomo-public-launch/（tasks.md 2.5・design.md の「運用」の読み返しの道具・要件 3.3 と 10.6）

⚠️ 読むだけ。本番に書かない（リリースの一覧・リリース・ruleset を GET で読むだけで、ほかの要求は送らない）。
⚠️ 本番の読み取りなので、実行は利用者の GO を取ってから（tasks.md の「進め方の約束」）。
⚠️ トークンは出力しない。画面・ログ・例外の本文のどこにも出さない（HTTP のエラーの本文と例外の文は、
   トークンを伏せてから出す。想定外の例外も、型の名前と伏せた文だけを出し、トレースバックは出さない）。

使い方（リポジトリ直下で）:
  python3 scripts/read-deployed-rules.py <保存先>
      本番のリリース cloud.firestore と Storage のリリース（STORAGE_RELEASE）を読み、リリースごとに
      ruleset の識別子・更新の時刻・本文の sha256 の頭 12 桁を出し、本文を
      <保存先>/firestore.rules と <保存先>/storage.rules に保存する。
      比べる手元のファイル（既定はリポジトリ直下の firestore.rules と storage.rules）の sha256 の頭 12 桁も並べる。
      保存先は scratchpad など、リポジトリの外を渡す（リポジトリの中は断る。手元のファイルを上書きしないため）。
  python3 scripts/read-deployed-rules.py <保存先> --firestore <パス> --storage <パス>
      比べる手元のファイルを変える（陽性対照で、1 行足した写しと比べるときなど）
  python3 scripts/read-deployed-rules.py <保存先> --storage-release <リリースの名前>
      Storage のリリースの名前を変える（下の「要確認10」）
  python3 scripts/read-deployed-rules.py --list-releases
      リリースの一覧（名前・ruleset の識別子・更新の時刻）だけを出す。本文は読まず、何も保存しない
  401 が返るときは firebase CLI のトークンが古いので、`firebase projects:list > /dev/null` を一度実行してから再実行する。

保存した本文には、そのままルールのテストを流せる（テストはルールのパスを引数で受け取る）:
  python3 scripts/rules_test_soratomo.py <保存先>/firestore.rules
  python3 scripts/rules_test_storage_soratomo.py <保存先>/storage.rules

認証:
  ルールのテストと同じ、firebase CLI のログイン情報（~/.config/configstore/firebase-tools.json）のアクセストークンを使う。
  トークンは出力しない。

要確認10（design.md）:
  Storage のリリースの名前 STORAGE_RELEASE は、バケットの名前からの推定で、2026-10-12 に --list-releases の一覧で
  同じ名前であることを確かめた（tasks.md 2.5 の結果）。
  バケットを変えたときは一覧で確かめ直し、違えば一覧の名前を --storage-release で渡す（確かめたら、この定数も直す）。

比べ方:
  本番の本文（API が返した文字列を UTF-8 にした bytes）と、手元のファイルの bytes を、そのまま比べる
  （改行や文字コードをそろえない）。出す頭 12 桁は、保存した bytes と手元のファイルの bytes の sha256。
  ruleset のファイルが 1 個でないときは、どれを比べるか決められないので、読めなかった扱いにする。

終了コード: 0 = 2 本とも本番と手元が一致 / 1 = 一致しないものがある / 2 = 読めなかった
  （API の失敗・手元のファイルが無い・保存先がリポジトリの中・比べる先が保存先のファイルと同じ・使い方の誤り。1 と 2 を分けるのは、
   陽性対照の「1 行足した写しで 1」を、読み取りの失敗と見分けられるようにするため）

テスト: python3 scripts/read-deployed-rules.test.py（ネットワークとトークンの読み込みを差し替える。本番には触れない）
"""
import argparse
import datetime
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PROJECT_ID = "soramoyou-ios"
API = "https://firebaserules.googleapis.com/v1"
TOKEN_FILE = "~/.config/configstore/firebase-tools.json"

FIRESTORE_RELEASE = "cloud.firestore"
# バケットの名前（soramoyou-ios.firebasestorage.app）からの推定。2026-10-12 にリリースの一覧で同じ名前と確かめた（要確認10）
STORAGE_RELEASE = "firebase.storage/soramoyou-ios.firebasestorage.app"

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
JST = datetime.timezone(datetime.timedelta(hours=9))


class ReadError(Exception):
    """読めなかったこと（終了コード 2）。文は、トークンを伏せてから作る"""


def load_token():
    """firebase CLI のログイン情報からアクセストークンを読む（ルールのテストと同じ読み方。値は出さない）"""
    try:
        with open(os.path.expanduser(TOKEN_FILE), encoding="utf-8") as f:
            return json.load(f)["tokens"]["access_token"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        # 例外の文には、項目の名前やファイルの中身の一部が載ることがあるので、型の名前だけを出す
        raise ReadError(f"firebase CLI のログイン情報が読めない（{type(e).__name__}）。`firebase login` の状態を確かめる") from None


def redact(text, token):
    """文の中のトークンを伏せる。エラーの本文・例外の文は、出す前に必ずここを通す"""
    text = str(text)
    if token:
        text = text.replace(token, "<伏せた>")
    return text


def auth_headers(token):
    return {"Authorization": "Bearer " + token}


def api_get(path, token):
    """Rules REST API に GET を送り、JSON を返す。失敗は ReadError（文はトークンを伏せる）"""
    req = urllib.request.Request(f"{API}/{path}", headers=auth_headers(token))
    # 接続が切れるなどの一時的な失敗は 3 回まで再試行する（HTTP のエラーは再試行しない。ルールのテストと同じ）
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as res:
                return json.load(res)
        except urllib.error.HTTPError as e:
            # 伏せてから 600 文字に切る（切ってから伏せると、600 文字目をまたぐトークンの頭が伏せきれずに出る）
            body = redact(e.read().decode("utf-8", errors="replace"), token)[:600]
            e.close()
            message = f"HTTP {e.code} {body}"
            if e.code == 401:
                message += "\nトークンが古い。`firebase projects:list > /dev/null` を一度実行してから再実行する"
            raise ReadError(message) from None
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt == 2:
                raise ReadError(redact(f"通信の失敗: {e}", token)) from None
            time.sleep(2)


def read_release(release_name, token):
    """リリースと、その ruleset を読み、ruleset の識別子・更新の時刻・本文の bytes を返す"""
    release = api_get(f"projects/{PROJECT_ID}/releases/{release_name}", token)
    ruleset_name = release.get("rulesetName", "")
    prefix = f"projects/{PROJECT_ID}/rulesets/"
    if not ruleset_name.startswith(prefix):
        raise ReadError(f"{release_name}: リリースの ruleset の名前が想定と違う（{ruleset_name[:80]}）")
    ruleset = api_get(ruleset_name, token)
    files = (ruleset.get("source") or {}).get("files") or []
    if len(files) != 1 or not isinstance(files[0].get("content"), str):
        raise ReadError(f"{release_name}: ruleset のファイルが {len(files)} 個（本文のあるファイルが 1 個のときだけ比べる）")
    return {
        "ruleset_id": ruleset_name[len(prefix):],
        "update_time": release.get("updateTime", "?"),
        "content": files[0]["content"].encode("utf-8"),
    }


def list_releases(token):
    """リリースの一覧を、最後のページまでたどって (名前, ruleset の識別子, 更新の時刻) の並びで返す"""
    rows, page = [], None
    while True:
        query = {"pageSize": "100"}
        if page:
            query["pageToken"] = page
        data = api_get(f"projects/{PROJECT_ID}/releases?" + urllib.parse.urlencode(query), token)
        for release in data.get("releases", []):
            rows.append((
                release.get("name", "").split("/releases/", 1)[-1],
                release.get("rulesetName", "").rsplit("/", 1)[-1],
                release.get("updateTime", "?"),
            ))
        page = data.get("nextPageToken")
        if not page:
            return rows


def digest(data):
    """bytes の sha256 の頭 12 桁"""
    return hashlib.sha256(data).hexdigest()[:12]


def jst(timestamp):
    """API の時刻（RFC3339・UTC）を日本時間の表記にする。読めなければ「?」"""
    try:
        t = datetime.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        return t.astimezone(JST).strftime("%Y-%m-%d %H:%M:%S JST")
    except (ValueError, AttributeError):
        return "?"


def is_inside(path, root):
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root + os.sep)


def compare_and_save(label, release_name, remote, local_path, out_path):
    """本番の本文を out_path に保存し、手元のファイルと bytes で比べて結果を出す。一致なら True"""
    # 手元を先に読んでから保存する（同じファイルを指していても、比べる先を本番の本文で上書きしてから読まないため。
    # 同じファイルは main で読む前に断っている。ここは念のための順序）
    with open(local_path, "rb") as f:
        local = f.read()
    with open(out_path, "wb") as f:
        f.write(remote["content"])
    same = remote["content"] == local
    print(f"[{label}] リリース {release_name}")
    print(f"  ruleset   : {remote['ruleset_id']}")
    print(f"  更新の時刻: {remote['update_time']}（{jst(remote['update_time'])}）")
    print(f"  本番      : {digest(remote['content'])}（保存した先: {out_path}）")
    print(f"  手元      : {digest(local)}（{local_path}）")
    print("  → 一致" if same else "  → 不一致")
    return same


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="本番の Firestore と Storage のルールを読み（読むだけ）、手元のファイルと比べて保存する。トークンは出さない。")
    parser.add_argument("out_dir", nargs="?", help="本番の本文の保存先（scratchpad など、リポジトリの外）")
    parser.add_argument("--firestore", default=os.path.join(REPO_ROOT, "firestore.rules"),
                        help="比べる手元の Firestore のルール（既定はリポジトリ直下）")
    parser.add_argument("--storage", default=os.path.join(REPO_ROOT, "storage.rules"),
                        help="比べる手元の Storage のルール（既定はリポジトリ直下）")
    parser.add_argument("--storage-release", default=STORAGE_RELEASE,
                        help="Storage のリリースの名前（既定はバケットの名前からの推定。要確認10）")
    parser.add_argument("--list-releases", action="store_true",
                        help="リリースの一覧だけを出す（本文は読まず、何も保存しない）")
    args = parser.parse_args(argv)
    if not args.list_releases and not args.out_dir:
        parser.error("保存先を渡す（または --list-releases）")
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    token = None
    try:
        if args.list_releases:
            token = load_token()
            for name, ruleset_id, update_time in list_releases(token):
                print(f"{name}  ruleset {ruleset_id}  更新の時刻 {update_time}（{jst(update_time)}）")
            return 0

        # 本番を読む前に、保存先と手元のファイルを確かめる（だめなら本番を読まない）
        if is_inside(args.out_dir, REPO_ROOT):
            raise ReadError(f"保存先がリポジトリの中（{args.out_dir}）。scratchpad など、リポジトリの外を渡す")
        targets = [
            ("Firestore", FIRESTORE_RELEASE, args.firestore, "firestore.rules"),
            ("Storage", args.storage_release, args.storage, "storage.rules"),
        ]
        for _, _, local_path, _ in targets:
            if not os.path.isfile(local_path):
                raise ReadError(f"比べる手元のファイルが無い（{local_path}）")
        # 比べる先が保存先のファイル（どちらの名前でも）と同じなら断る。保存すると比べる先が本番の本文で上書きされ、
        # 中身が違っても「一致」になる（または写しが消える）。samefile なので、シンボリックリンクとハードリンクも見分ける
        for _, _, local_path, _ in targets:
            for _, _, _, file_name in targets:
                out_file = os.path.join(args.out_dir, file_name)
                if os.path.exists(out_file) and os.path.samefile(local_path, out_file):
                    raise ReadError(f"比べる手元のファイルが、保存先のファイルと同じ（{local_path}）。保存先の外に置いた写しを渡す")

        token = load_token()
        os.makedirs(args.out_dir, exist_ok=True)
        failed = mismatched = False
        for label, release_name, local_path, file_name in targets:
            try:
                remote = read_release(release_name, token)
            except ReadError as e:
                print(f"[{label}] リリース {release_name}: 読めなかった")
                print("  " + str(e).replace("\n", "\n  "))
                failed = True
                continue
            if not compare_and_save(label, release_name, remote, local_path, os.path.join(args.out_dir, file_name)):
                mismatched = True
    except ReadError as e:
        print("読めなかった:", e)
        return 2
    except Exception as e:  # 想定外の例外も、トレースバックを出さず、型の名前とトークンを伏せた文だけを出す
        print(f"想定外のエラー（{type(e).__name__}）: {redact(e, token)}")
        return 2

    if failed:
        print("結果: 読めなかったものがある（終了コード 2）")
        return 2
    if mismatched:
        print("結果: 一致しないものがある（終了コード 1）")
        return 1
    print("結果: 2 本とも本番と手元が一致（終了コード 0）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
