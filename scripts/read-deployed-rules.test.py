#!/usr/bin/env python3
"""read-deployed-rules.test.py ☁️⭐️

read-deployed-rules.py の単体テスト（unittest・標準ライブラリだけ）。
spec: .kiro/specs/soratomo-public-launch/（tasks.md 2.5・本番のルールの読み返しの道具）

実行: python3 scripts/read-deployed-rules.test.py [-v]
  一時ファイルは tempfile の置き場（TMPDIR）に作り、テストの後に消す。

本番には触れない:
  - ネットワークの呼び出し（urllib.request.urlopen）を、どのテストでも差し替える。差し替えの無いテストが
    ネットワークを呼ぼうとしたら NetworkCalled（BaseException の仲間なので、道具の「想定外のエラー」の受け口でも
    捕まらない）で落ちる
  - firebase CLI のログイン情報の読み込み（load_token）も、どのテストでも差し替える（本物のトークンを読まない）。
    代わりに渡すトークンは、漏れたら目で見つかる目印の文字列（TOKEN）にしている

確かめること:
  - 本番と手元が一致なら終了コード 0、手元に 1 行足した写し・Storage だけ違う・改行の違いなら終了コード 1
  - 読めないとき（HTTP のエラー・通信の失敗・想定外の例外・ruleset のファイルが 1 個でない・手元のファイルが無い・
    保存先がリポジトリの中）は終了コード 2（不一致の 1 と見分ける）
  - 保存するのは本番の本文（手元の本文ではない）で、出した頭 12 桁は保存した bytes の sha256
  - トークンは、HTTP のエラーの本文・通信の失敗の文・想定外の例外の文に混ざっても出力に出ない
  - 送るのは GET だけ・接続先は Rules API の soramoyou-ios の下だけ
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
import urllib.error
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("read_deployed_rules", os.path.join(HERE, "read-deployed-rules.py"))
rdr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rdr)

# 漏れたら目で見つかる目印（本物のトークンではない）。出力に 1 回でも出たらテストが落ちる
TOKEN = "ya29.SENTINEL-DO-NOT-PRINT-0123456789"

BASE = f"{rdr.API}/projects/{rdr.PROJECT_ID}"
REMOTE_FS = "rules_version = '2';\nservice cloud.firestore {\n  // 本番の Firestore のルール（テスト用）\n}\n"
REMOTE_ST = "rules_version = '2';\nservice firebase.storage {\n  // 本番の Storage のルール（テスト用）\n}\n"


class NetworkCalled(BaseException):
    """差し替えの無いままネットワークを呼んだ（本番へ出ようとした）"""


def refuse_network(*args, **kwargs):
    raise NetworkCalled("ネットワークを呼んだ（差し替え漏れ）")


def head12(text_or_bytes):
    data = text_or_bytes.encode("utf-8") if isinstance(text_or_bytes, str) else text_or_bytes
    return hashlib.sha256(data).hexdigest()[:12]


def http_error(url, code, body):
    return urllib.error.HTTPError(url, code, "error", {}, io.BytesIO(body.encode("utf-8")))


class FakeRulesApi:
    """Rules REST API の代わり。呼ばれた要求（メソッド・URL・認証ヘッダー・本文）を記録して、決めた JSON を返す"""

    def __init__(self, firestore=REMOTE_FS, storage=REMOTE_ST, storage_release=None, errors=None, routes=None):
        storage_release = storage_release or rdr.STORAGE_RELEASE
        self.calls = []
        self.errors = errors or {}
        self.routes = {
            f"{BASE}/releases/{rdr.FIRESTORE_RELEASE}": {
                "name": f"projects/{rdr.PROJECT_ID}/releases/{rdr.FIRESTORE_RELEASE}",
                "rulesetName": f"projects/{rdr.PROJECT_ID}/rulesets/fs-ruleset-1",
                "updateTime": "2026-10-09T22:09:59.123456Z",
            },
            f"{BASE}/releases/{storage_release}": {
                "name": f"projects/{rdr.PROJECT_ID}/releases/{storage_release}",
                "rulesetName": f"projects/{rdr.PROJECT_ID}/rulesets/st-ruleset-2",
                "updateTime": "2026-10-03T01:02:03.5Z",
            },
            f"{BASE}/rulesets/fs-ruleset-1": {"source": {"files": [{"name": "firestore.rules", "content": firestore}]}},
            f"{BASE}/rulesets/st-ruleset-2": {"source": {"files": [{"name": "storage.rules", "content": storage}]}},
        }
        self.routes.update(routes or {})

    def __call__(self, req, timeout=None):
        url = req.full_url
        self.calls.append((req.get_method(), url, req.get_header("Authorization"), req.data))
        if url in self.errors:
            raise self.errors[url]
        if url not in self.routes:
            raise http_error(url, 404, '{"error": {"code": 404, "status": "NOT_FOUND"}}')
        return io.BytesIO(json.dumps(self.routes[url]).encode("utf-8"))


class ReadDeployedRulesTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.out = os.path.join(self.tmp, "読み返し")
        self.local_fs = self.write("local/firestore.rules", REMOTE_FS)
        self.local_st = self.write("local/storage.rules", REMOTE_ST)
        self.patchers = {
            "urlopen": mock.patch.object(rdr.urllib.request, "urlopen", refuse_network),
            "load_token": mock.patch.object(rdr, "load_token", return_value=TOKEN),
            "sleep": mock.patch.object(rdr.time, "sleep"),
        }
        for patcher in self.patchers.values():
            patcher.start()
            self.addCleanup(patcher.stop)
        self.addCleanup(self._tmp.cleanup)

    # MARK: - 補助

    def write(self, rel, content, mode="w"):
        path = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if mode == "wb":
            with open(path, "wb") as f:
                f.write(content)
        else:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(content)
        return path

    def run_tool(self, argv, api=None):
        """道具の main を、差し替えた API で動かし、(終了コード, 標準出力と標準エラーをまとめた文字列) を返す"""
        buf = io.StringIO()
        patcher = mock.patch.object(rdr.urllib.request, "urlopen", api) if api else contextlib.nullcontext()
        with patcher, contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            code = rdr.main(argv)
        return code, buf.getvalue()

    def default_argv(self, firestore=None, storage=None):
        return [self.out, "--firestore", firestore or self.local_fs, "--storage", storage or self.local_st]

    def read_saved(self, name):
        with open(os.path.join(self.out, name), "rb") as f:
            return f.read()

    def assert_no_token(self, out):
        self.assertNotIn(TOKEN, out)
        self.assertNotIn("SENTINEL", out)
        self.assertNotIn("Bearer", out)

    # MARK: - 一致と不一致

    def test_本番と手元が一致なら終了コード0で本文を保存する(self):
        api = FakeRulesApi()
        code, out = self.run_tool(self.default_argv(), api)
        self.assertEqual(code, 0, out)
        self.assertEqual(self.read_saved("firestore.rules"), REMOTE_FS.encode("utf-8"))
        self.assertEqual(self.read_saved("storage.rules"), REMOTE_ST.encode("utf-8"))
        # 本番と手元の頭 12 桁が、それぞれ 2 回（本番・手元）出る
        self.assertEqual(out.count(head12(REMOTE_FS)), 2, out)
        self.assertEqual(out.count(head12(REMOTE_ST)), 2, out)
        self.assertIn("fs-ruleset-1", out)
        self.assertIn("st-ruleset-2", out)
        self.assertIn("2026-10-09T22:09:59.123456Z", out)
        self.assertIn("2026-10-10 07:09:59 JST", out)
        self.assertNotIn("不一致", out)
        self.assert_no_token(out)
        # 2 本とも、トークンを付けた GET を送っている（差し替えが空振りしていない）
        self.assertEqual(len(api.calls), 4)
        for method, url, auth, data in api.calls:
            self.assertEqual(method, "GET")
            self.assertIsNone(data)
            self.assertTrue(url.startswith(BASE + "/"), url)
            self.assertEqual(auth, "Bearer " + TOKEN)

    def test_手元に1行足した写しと比べると終了コード1で保存するのは本番の本文(self):
        local = self.write("copy/firestore.rules", REMOTE_FS + "// 1 行足した\n")
        code, out = self.run_tool(self.default_argv(firestore=local), FakeRulesApi())
        self.assertEqual(code, 1, out)
        self.assertIn("不一致", out)
        self.assertEqual(self.read_saved("firestore.rules"), REMOTE_FS.encode("utf-8"))
        self.assertIn(head12(REMOTE_FS + "// 1 行足した\n"), out)
        self.assert_no_token(out)

    def test_Storageだけ違っても終了コード1(self):
        local = self.write("copy/storage.rules", REMOTE_ST.replace("Storage", "storage"))
        code, out = self.run_tool(self.default_argv(storage=local), FakeRulesApi())
        self.assertEqual(code, 1, out)
        self.assertEqual(out.count("不一致"), 1, out)

    def test_改行の違いも不一致として見分ける(self):
        local = self.write("copy/firestore.rules", REMOTE_FS.replace("\n", "\r\n"))
        code, out = self.run_tool(self.default_argv(firestore=local), FakeRulesApi())
        self.assertEqual(code, 1, out)

    def test_出した頭12桁は保存したbytesのsha256(self):
        text = "rules_version = '2';\n// 日本語と絵文字 ☁️ を含む本文\n"
        local = self.write("copy/firestore.rules", text)
        code, out = self.run_tool(self.default_argv(firestore=local), FakeRulesApi(firestore=text))
        self.assertEqual(code, 0, out)
        self.assertIn(head12(self.read_saved("firestore.rules")), out)

    # MARK: - 読めないとき（終了コード 2）

    def test_本番が読めなければ終了コード2で不一致の1と見分ける(self):
        url = f"{BASE}/releases/{rdr.STORAGE_RELEASE}"
        api = FakeRulesApi(errors={url: http_error(url, 500, '{"error": {"code": 500}}')})
        code, out = self.run_tool(self.default_argv(), api)
        self.assertEqual(code, 2, out)
        self.assertIn("HTTP 500", out)

    def test_401ならトークンを出さずに更新の手順を出す(self):
        url = f"{BASE}/releases/{rdr.FIRESTORE_RELEASE}"
        body = '{"error": {"code": 401, "message": "Request had invalid authentication credentials."}}'
        api = FakeRulesApi(errors={url: http_error(url, 401, body)})
        code, out = self.run_tool(self.default_argv(), api)
        self.assertEqual(code, 2, out)
        self.assertIn("HTTP 401", out)
        self.assertIn("firebase projects:list > /dev/null", out)
        self.assert_no_token(out)
        self.assertTrue(any(auth == "Bearer " + TOKEN for _, _, auth, _ in api.calls))

    def test_HTTPのエラーの本文にトークンが混ざっても伏せる(self):
        url = f"{BASE}/releases/{rdr.FIRESTORE_RELEASE}"
        api = FakeRulesApi(errors={url: http_error(url, 403, '{"error": {"message": "token ' + TOKEN + ' denied"}}')})
        code, out = self.run_tool(self.default_argv(), api)
        self.assertEqual(code, 2, out)
        self.assertIn("HTTP 403", out)
        self.assert_no_token(out)

    def test_通信の失敗は3回まで試しトークンが混ざっても伏せる(self):
        url = f"{BASE}/releases/{rdr.FIRESTORE_RELEASE}"
        api = FakeRulesApi(errors={url: urllib.error.URLError("接続先が " + TOKEN + " を返した")})
        code, out = self.run_tool(self.default_argv(), api)
        self.assertEqual(code, 2, out)
        self.assertEqual(sum(1 for _, u, _, _ in api.calls if u == url), 3)
        self.assertIn("通信の失敗", out)
        self.assert_no_token(out)

    def test_想定外の例外の文にトークンが混ざっても伏せる(self):
        def broken(req, timeout=None):
            raise ValueError("想定外: " + TOKEN)

        code, out = self.run_tool(self.default_argv(), broken)
        self.assertEqual(code, 2, out)
        self.assertIn("ValueError", out)
        self.assert_no_token(out)

    def test_rulesetのファイルが1個でなければ終了コード2(self):
        two_files = {"source": {"files": [{"name": "a.rules", "content": REMOTE_FS}, {"name": "b.rules", "content": ""}]}}
        api = FakeRulesApi(routes={f"{BASE}/rulesets/fs-ruleset-1": two_files})
        code, out = self.run_tool(self.default_argv(), api)
        self.assertEqual(code, 2, out)

    def test_手元のファイルが無ければ本番を読まずに終了コード2(self):
        # ネットワークは差し替えない（呼んだら NetworkCalled で落ちる）
        code, out = self.run_tool(self.default_argv(firestore=os.path.join(self.tmp, "無い.rules")))
        self.assertEqual(code, 2, out)
        self.assertFalse(os.path.exists(self.out))

    def test_保存先がリポジトリの中なら本番を読まずに断る(self):
        inside = os.path.join(rdr.REPO_ROOT, "読み返しの保存先-テスト")
        code, out = self.run_tool([inside, "--firestore", self.local_fs, "--storage", self.local_st])
        self.assertEqual(code, 2, out)
        self.assertFalse(os.path.exists(inside))

    def test_保存先がリポジトリの直下そのものでも断る(self):
        code, out = self.run_tool([rdr.REPO_ROOT])
        self.assertEqual(code, 2, out)

    # MARK: - 引数・一覧・トークンの読み方

    def test_既定の比べる先はリポジトリ直下の2本(self):
        args = rdr.parse_args([self.out])
        self.assertEqual(os.path.realpath(args.firestore), os.path.realpath(os.path.join(HERE, "..", "firestore.rules")))
        self.assertEqual(os.path.realpath(args.storage), os.path.realpath(os.path.join(HERE, "..", "storage.rules")))
        self.assertEqual(args.storage_release, rdr.STORAGE_RELEASE)
        self.assertEqual(rdr.FIRESTORE_RELEASE, "cloud.firestore")
        self.assertEqual(rdr.PROJECT_ID, "soramoyou-ios")

    def test_Storageのリリースの名前を引数で変えられる(self):
        other = "firebase.storage/another-bucket.appspot.com"
        api = FakeRulesApi(storage_release=other)
        code, out = self.run_tool(self.default_argv() + ["--storage-release", other], api)
        self.assertEqual(code, 0, out)
        self.assertIn(f"{BASE}/releases/{other}", [u for _, u, _, _ in api.calls])

    def test_リリースの一覧を最後のページまで出し本文は読まない(self):
        page1 = {"releases": [{"name": f"projects/{rdr.PROJECT_ID}/releases/cloud.firestore",
                               "rulesetName": f"projects/{rdr.PROJECT_ID}/rulesets/r-1", "updateTime": "2026-10-09T22:09:59Z"}],
                 "nextPageToken": "p2"}
        page2 = {"releases": [{"name": f"projects/{rdr.PROJECT_ID}/releases/firebase.storage/b.firebasestorage.app",
                               "rulesetName": f"projects/{rdr.PROJECT_ID}/rulesets/r-2", "updateTime": "2026-10-03T01:02:03Z"}]}
        api = FakeRulesApi(routes={f"{BASE}/releases?pageSize=100": page1,
                                   f"{BASE}/releases?pageSize=100&pageToken=p2": page2})
        code, out = self.run_tool(["--list-releases"], api)
        self.assertEqual(code, 0, out)
        self.assertIn("cloud.firestore", out)
        self.assertIn("firebase.storage/b.firebasestorage.app", out)
        self.assertIn("r-1", out)
        self.assertIn("r-2", out)
        self.assertEqual(len(api.calls), 2)
        self.assertTrue(all(method == "GET" and data is None for method, _, _, data in api.calls))
        self.assert_no_token(out)

    def test_トークンはfirebase_CLIのログイン情報から読む(self):
        self.patchers["load_token"].stop()  # 本物の load_token を使う（ネットワークの差し替えは残す）
        path = self.write("configstore/firebase-tools.json", json.dumps({"tokens": {"access_token": "x-token"}}))
        with mock.patch.object(rdr, "TOKEN_FILE", path):
            self.assertEqual(rdr.load_token(), "x-token")

    def test_ログイン情報が壊れていても中身を出さない(self):
        self.patchers["load_token"].stop()  # 本物の load_token を使う（ネットワークの差し替えは残す）
        path = self.write("configstore/firebase-tools.json", json.dumps({"tokens": {"refresh_token": TOKEN}}))
        with mock.patch.object(rdr, "TOKEN_FILE", path):
            code, out = self.run_tool(self.default_argv())
        self.assertEqual(code, 2, out)
        self.assert_no_token(out)
        self.assertNotIn("refresh_token", out)
        self.assertNotIn("access_token", out)


if __name__ == "__main__":
    unittest.main()
