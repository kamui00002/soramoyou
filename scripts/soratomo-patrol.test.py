#!/usr/bin/env python3
"""soratomo-patrol.test.py ☁️⭐️

soratomo-patrol.py の単体テスト（unittest・標準ライブラリだけ）。
spec: .kiro/specs/soratomo-public-launch/（tasks.md 10.3・15.1 の見回りの道具）

実行: python3 scripts/soratomo-patrol.test.py [-v]

本番には触れない:
  - ネットワークの呼び出し（urllib.request.urlopen）を、どのテストでも差し替える。差し替えの無いテストが
    ネットワークを呼ぼうとしたら NetworkCalled（BaseException の仲間なので、道具の「想定外のエラー」の受け口でも
    捕まらない）で落ちる
  - firebase CLI のログイン情報の読み込み（load_token）も、どのテストでも差し替える（本物のトークンのファイルを読まない）。
    トークンの読み方そのものを試すテストだけ、load_token を戻したうえで TOKEN_FILE を一時ファイルに向ける。
    代わりに渡すトークンは、漏れたら目で見つかる目印の文字列（TOKEN）にしている
  - 待ち（time.sleep）も差し替える（ページの間の 1.1 秒・再試行の 2 秒で遅くならないように）

確かめること:
  - JST の日ごとの集計（UTC 14:59:59.999999999Z はその日・15:00:00Z は翌日）・ページ送り
  - uid・groupId の全体が出力に出ない（頭 6 文字とテスト用の印は出る）
  - 乱用を疑う目安の陽性対照（目安ちょうどで ⚠️・終了コード 1）と陰性対照（1 つ手前で ⚠️ なし・終了コード 0）
  - 使用量の目安超え・トークンの期限切れ（ネットワークを呼ばずに 2）・HTTP のエラー（2・トークンが出ない）
  - 送る要求は、logging の entries:list への POST と monitoring の timeSeries への GET だけ
  - 使い方の誤りは終了コード 2
"""
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("soratomo_patrol", os.path.join(HERE, "soratomo-patrol.py"))
sp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sp)

# 漏れたら目で見つかる目印（本物のトークンではない）。出力に 1 回でも出たらテストが落ちる
TOKEN = "ya29.SENTINEL-DO-NOT-PRINT-0123456789"

JST = sp.JST
WARN = "⚠️"

# 目印の長い uid・groupId（全体が出力に出ないことを確かめる）
UID_S3 = "8Ar2DV" + "a1B2c3D4e5F6g7H8i9J0kL"
UID_S5 = "Qk9lcs" + "zZyYxXwWvVuUtTsSrRqQpP"
UID_PLAIN = "jHcHjQ" + "mMnNoOpPqQrRsStTuUvVwW"
GROUP_A = "y2PpRM" + "GROUPGROUPGROUPGROUP"
GROUP_B = "1wd6CJ" + "OTHEROTHEROTHEROTHER"

# 窓: JST の 10/13 0:00〜10/16 0:00（日ごとの集計と目安の検査に使う）
WIDE = ["--from", "2026-10-13 00:00", "--to", "2026-10-16 00:00"]
BASE_TIME = dt.datetime(2026, 10, 14, 1, 0, tzinfo=JST)

READ_METRIC = "firestore.googleapis.com/document/read_count"
SENT_METRIC = "storage.googleapis.com/network/sent_bytes_count"


class NetworkCalled(BaseException):
    """差し替えの無いままネットワークを呼んだ（本番へ出ようとした）"""


def refuse_network(*args, **kwargs):
    raise NetworkCalled("ネットワークを呼んだ（差し替え漏れ）")


def http_error(url, code, body):
    return urllib.error.HTTPError(url, code, "error", {}, io.BytesIO(body.encode("utf-8")))


def utc_z(t, frac="000000000"):
    """JST の時刻を、Cloud Logging の形（UTC・小数部 9 桁）の文字列にする"""
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + frac + "Z"


def entry(t, message, uid=None, **extra):
    """ログの 1 項目。t は JST の時刻"""
    payload = {"message": message}
    if uid is not None:
        payload["uid"] = uid
    payload.update(extra)
    return {"timestamp": utc_z(t), "jsonPayload": payload}


def at(minutes):
    return BASE_TIME + dt.timedelta(minutes=minutes)


class FakeGoogleApi:
    """Cloud Logging と Cloud Monitoring の代わり。呼ばれた要求を記録して、決めた JSON を返す。
    log_pages: ページごとの項目の並び（nextPageToken は "page-1" のように作る）
    usage: {指標: {"MM/DD": 値}}（Monitoring の日ごとの点にして返す。無い指標は点なし）
    errors: {URL に含まれる文字列: 投げる例外}"""

    def __init__(self, log_pages=None, usage=None, errors=None):
        self.log_pages = log_pages if log_pages is not None else [[]]
        self.usage = usage or {}
        self.errors = errors or {}
        self.calls = []  # (メソッド, URL, Authorization, x-goog-user-project, 本文の JSON)

    def __call__(self, req, timeout=None):
        url = req.full_url
        body = json.loads(req.data.decode("utf-8")) if req.data else None
        self.calls.append((req.get_method(), url, req.get_header("Authorization"),
                           req.get_header("X-goog-user-project"), body))
        for key, exc in self.errors.items():
            if key in url:
                raise exc
        if url == sp.LOGGING_URL:
            idx = int(body["pageToken"].split("-")[1]) if body.get("pageToken") else 0
            res = {"entries": self.log_pages[idx]}
            if idx + 1 < len(self.log_pages):
                res["nextPageToken"] = f"page-{idx + 1}"
            return io.BytesIO(json.dumps(res).encode("utf-8"))
        if url.startswith(sp.MONITORING_URL + "?"):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
            metric = query["filter"][0].split('"')[1]
            points = []
            for day, value in self.usage.get(metric, {}).items():
                month, d = day.split("/")
                start = dt.datetime(2026, int(month), int(d), tzinfo=JST).astimezone(dt.timezone.utc)
                points.append({"interval": {"startTime": start.strftime("%Y-%m-%dT%H:%M:%SZ")},
                               "value": {"doubleValue": value}})
            res = {"timeSeries": [{"points": points}] if points else []}
            return io.BytesIO(json.dumps(res).encode("utf-8"))
        raise http_error(url, 404, "{}")


class SoratomoPatrolTest(unittest.TestCase):
    def setUp(self):
        self.patchers = {
            "urlopen": mock.patch.object(sp.urllib.request, "urlopen", refuse_network),
            "load_token": mock.patch.object(sp, "load_token", return_value=TOKEN),
            "sleep": mock.patch.object(sp.time, "sleep"),
        }
        for patcher in self.patchers.values():
            patcher.start()
            self.addCleanup(patcher.stop)

    # MARK: - 補助

    def run_tool(self, argv, api=None):
        """道具の main を、差し替えた API で動かし、(終了コード, 標準出力と標準エラーをまとめた文字列) を返す"""
        buf = io.StringIO()
        patcher = mock.patch.object(sp.urllib.request, "urlopen", api) if api else contextlib.nullcontext()
        with patcher, contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            code = sp.main(argv)
        return code, buf.getvalue()

    def run_wide(self, entries, usage=None):
        api = FakeGoogleApi(log_pages=[entries], usage=usage)
        code, out = self.run_tool(WIDE, api)
        return code, out, api

    def line_with(self, out, key):
        lines = [line for line in out.splitlines() if key in line]
        self.assertEqual(len(lines), 1, f"{key!r} を含む行が {len(lines)} 行\n{out}")
        return lines[0]

    def assert_no_token(self, out):
        self.assertNotIn(TOKEN, out)
        self.assertNotIn("SENTINEL", out)
        self.assertNotIn("Bearer", out)

    def creates(self, offsets_minutes, uid=UID_S3):
        return [entry(at(m), "soratomoCreateGroup: ok", uid) for m in offsets_minutes]

    def skies(self, n, uid=UID_S3, group=GROUP_A, **extra):
        return [entry(at(i), "soratomoCreateSky: ok", uid, groupId=group, **extra) for i in range(n)]

    # MARK: - 日ごとの集計・ページ送り

    def test_UTCの1459は当日で1500は翌日のJSTの日に入る(self):
        # JST 10/13 23:59:59.999999999 = UTC 10/13 14:59:59.999999999 → 10/13、UTC 15:00:00 = JST 10/14 0:00 → 10/14
        entries = [
            {"timestamp": "2026-10-13T14:59:59.999999999Z", "jsonPayload": {"message": "soratomoCreateGroup: ok", "uid": UID_S3}},
            {"timestamp": "2026-10-13T15:00:00Z", "jsonPayload": {"message": "soratomoCreateGroup: ok", "uid": UID_S3}},
            {"timestamp": "2026-10-13T15:00:00.000000000Z", "jsonPayload": {"message": "soratomoJoinGroup: ok", "uid": UID_S5}},
        ]
        code, out, _ = self.run_wide(entries)
        self.assertEqual(code, 0, out)
        day13 = out.split("[10/13]")[1].split("[10/14]")[0]
        day14 = out.split("[10/14]")[1].split("==")[0]
        self.assertIn("[10/13] 1 件", out)
        self.assertIn("[10/14] 2 件", out)
        self.assertIn("soratomoCreateGroup: ok: 1", day13)
        self.assertNotIn("soratomoJoinGroup", day13)
        self.assertIn("soratomoCreateGroup: ok: 1", day14)
        self.assertIn("soratomoJoinGroup: ok: 1", day14)

    def test_日ごとにメッセージとuidとrejectedの理由を数える(self):
        entries = [
            entry(at(0), "soratomoCreateSky: ok", UID_S3, groupId=GROUP_A),
            entry(at(1), "soratomoCreateSky: ok", UID_S3, groupId=GROUP_A),
            entry(at(2), "soratomoCreateSky: ok", UID_PLAIN, groupId=GROUP_A),
            entry(at(3), "soratomoJoinGroup: rejected", UID_S5, reason="not_found"),
            entry(at(4), "soratomoJoinGroup: rejected", UID_S5, reason="not_found"),
            entry(at(5), "soratomoJoinGroup: rejected", UID_S5, reason="full"),
            entry(at(6), "soratomoHousekeeping: sweep"),
        ]
        code, out, _ = self.run_wide(entries)
        self.assertEqual(code, 0, out)
        self.assertIn("[10/14] 7 件", out)
        self.assertIn("soratomoCreateSky: ok: 3", out)
        self.assertIn("soratomoHousekeeping: sweep: 1", out)
        self.assertIn("ok の uid ごと soratomoCreateSky: 8Ar2DV(S3)×2, jHcHjQ×1", out)
        self.assertIn("rejected の理由ごと soratomoJoinGroup: not_found×2, full×1", out)

    def test_nextPageTokenを2回たどって全件を数える(self):
        pages = [
            [entry(at(0), "soratomoJoinGroup: ok", UID_S3), entry(at(1), "soratomoJoinGroup: ok", UID_S3)],
            [entry(at(2), "soratomoJoinGroup: ok", UID_S3)],
            [entry(at(3), "soratomoJoinGroup: ok", UID_S3), entry(at(4), "soratomoJoinGroup: ok", UID_S3)],
        ]
        api = FakeGoogleApi(log_pages=pages)
        code, out = self.run_tool(WIDE, api)
        self.assertEqual(code, 0, out)
        self.assertIn("5 件・3 ページ", out)
        self.assertIn("soratomoJoinGroup: ok: 5", out)
        posts = [c for c in api.calls if c[0] == "POST"]
        self.assertEqual(len(posts), 3)
        self.assertEqual([c[4].get("pageToken") for c in posts], [None, "page-1", "page-2"])

    def test_窓の指定がログの条件と使用量の範囲に出る(self):
        api = FakeGoogleApi()
        code, out = self.run_tool(["--from", "2026-10-13 18:27", "--to", "2026-10-15 00:00"], api)
        self.assertEqual(code, 0, out)
        flt = [c for c in api.calls if c[0] == "POST"][0][4]["filter"]
        self.assertIn('timestamp>="2026-10-13T09:27:00Z"', flt)
        self.assertIn('timestamp<"2026-10-14T15:00:00Z"', flt)
        self.assertIn('jsonPayload.message=~"^(soratomo|onSoratomo)"', flt)
        # 使用量は、始まりの日の 0 時から、終わり（ちょうど 0 時）まで
        query = urllib.parse.parse_qs(urllib.parse.urlparse([c for c in api.calls if c[0] == "GET"][0][1]).query)
        self.assertEqual(query["interval.startTime"], ["2026-10-12T15:00:00Z"])
        self.assertEqual(query["interval.endTime"], ["2026-10-14T15:00:00Z"])

    def test_dayは1日分で終わりが0時でないときは翌日の0時まで使用量を読む(self):
        api = FakeGoogleApi()
        code, out = self.run_tool(["--day", "2026-10-15"], api)
        self.assertEqual(code, 0, out)
        flt = [c for c in api.calls if c[0] == "POST"][0][4]["filter"]
        self.assertIn('timestamp>="2026-10-14T15:00:00Z"', flt)
        self.assertIn('timestamp<"2026-10-15T15:00:00Z"', flt)
        api2 = FakeGoogleApi()
        code, out = self.run_tool(["--from", "2026-10-13 18:27", "--to", "2026-10-14 12:00"], api2)
        self.assertEqual(code, 0, out)
        query = urllib.parse.parse_qs(urllib.parse.urlparse([c for c in api2.calls if c[0] == "GET"][0][1]).query)
        self.assertEqual(query["interval.endTime"], ["2026-10-14T15:00:00Z"])

    # MARK: - uid・groupId を出さない

    def test_uidとgroupIdの全体は出ず頭6文字とテスト用の印が出る(self):
        entries = (
            self.skies(2, uid=UID_S3, group=GROUP_A)
            + [entry(at(10), "soratomoCreateGroup: ok", UID_S5),
               entry(at(11), "soratomoDeleteMyData: ok", UID_PLAIN),
               entry(at(12), "soratomoJoinGroup: rejected", UID_PLAIN, reason="not_found")]
        )
        code, out, _ = self.run_wide(entries)
        self.assertEqual(code, 0, out)
        for full in (UID_S3, UID_S5, UID_PLAIN, GROUP_A):
            self.assertNotIn(full, out)
            self.assertNotIn(full[7:], out)  # 頭の 6 文字を除いた残りも出ない
        self.assertIn("8Ar2DV(S3)", out)
        self.assertIn("Qk9lcs(S5)", out)
        self.assertIn("jHcHjQ", out)
        self.assertIn("8Ar2DV(S3)/y2PpRM", out)
        self.assert_no_token(out)

    def test_テスト用アカウントも数からは除かない(self):
        code, out, _ = self.run_wide(self.creates([0, 10, 20], uid=UID_S3))
        self.assertEqual(code, 1, out)  # S3 の 3 件で目安に当たる
        self.assertIn("8Ar2DV(S3)=3", out)

    def test_uidが無い項目は印を付けて数える(self):
        code, out, _ = self.run_wide([entry(at(0), "soratomoCreateGroup: ok")])
        self.assertEqual(code, 0, out)
        self.assertIn("（uid なし）", out)

    # MARK: - 目安の陽性対照と陰性対照

    def test_グループの作成は24時間に3件で警告と終了コード1(self):
        code, out, _ = self.run_wide(self.creates([0, 600, 1200]))
        self.assertEqual(code, 1, out)
        self.assertIn(WARN, self.line_with(out, "グループの作成"))
        self.assertIn("8Ar2DV(S3)=3" + WARN, out)

    def test_グループの作成は24時間に2件なら警告なしで終了コード0(self):
        code, out, _ = self.run_wide(self.creates([0, 600]))
        self.assertEqual(code, 0, out)
        self.assertNotIn(WARN, out)

    def test_グループの作成は24時間をまたぐ3件なら警告なし(self):
        # 0 分・12 時間・25 時間: どの 24 時間にも 2 件までしか入らない
        code, out, _ = self.run_wide(self.creates([0, 720, 1500]))
        self.assertEqual(code, 0, out)
        self.assertNotIn(WARN, out)

    def test_グループの作成は人ごとに数える(self):
        entries = self.creates([0, 10], uid=UID_S3) + self.creates([20, 30], uid=UID_S5)
        code, out, _ = self.run_wide(entries)
        self.assertEqual(code, 0, out)

    def test_投稿は1人1グループの24時間に21件で警告(self):
        code, out, _ = self.run_wide(self.skies(21))
        self.assertEqual(code, 1, out)
        self.assertIn(WARN, self.line_with(out, "投稿（1 人×1 グループ"))

    def test_投稿は20件なら警告なし(self):
        code, out, _ = self.run_wide(self.skies(20))
        self.assertEqual(code, 0, out)
        self.assertNotIn(WARN, out)

    def test_createdがfalseの投稿は数えない(self):
        # 21 件のうち 1 件が created: false（再送で同じ投稿を返しただけ）なので、数えるのは 20 件
        entries = self.skies(20) + [entry(at(30), "soratomoCreateSky: ok", UID_S3, groupId=GROUP_A, created=False)]
        code, out, _ = self.run_wide(entries)
        self.assertEqual(code, 0, out)
        self.assertNotIn(WARN, out)
        # created: true と、created の無い項目は数える
        entries = self.skies(19) + [entry(at(30), "soratomoCreateSky: ok", UID_S3, groupId=GROUP_A, created=True),
                                    entry(at(31), "soratomoCreateSky: ok", UID_S3, groupId=GROUP_A)]
        code, out, _ = self.run_wide(entries)
        self.assertEqual(code, 1, out)

    def test_投稿は別のグループに分けると合算しない(self):
        entries = self.skies(11, group=GROUP_A) + self.skies(10, group=GROUP_B)
        code, out, _ = self.run_wide(entries)
        self.assertEqual(code, 0, out)

    def test_参加のnot_foundは1時間に10件で警告(self):
        entries = [entry(at(i * 5), "soratomoJoinGroup: rejected", UID_PLAIN, reason="not_found") for i in range(10)]
        code, out, _ = self.run_wide(entries)
        self.assertEqual(code, 1, out)
        self.assertIn(WARN, self.line_with(out, "参加の not_found"))

    def test_参加のnot_foundは1時間に9件なら警告なし(self):
        entries = [entry(at(i * 5), "soratomoJoinGroup: rejected", UID_PLAIN, reason="not_found") for i in range(9)]
        code, out, _ = self.run_wide(entries)
        self.assertEqual(code, 0, out)

    def test_参加のnot_foundを25時間に散らした10件は警告なし(self):
        # 168 分おき（2.8 時間）: 10 件の幅は 25.2 時間で、どの 1 時間にも 1 件しか入らない
        entries = [entry(at(i * 168), "soratomoJoinGroup: rejected", UID_PLAIN, reason="not_found") for i in range(10)]
        code, out, _ = self.run_wide(entries)
        self.assertEqual(code, 0, out)
        self.assertNotIn(WARN, out)

    def test_参加のnot_found以外の理由は数えない(self):
        entries = [entry(at(i), "soratomoJoinGroup: rejected", UID_PLAIN, reason="full") for i in range(10)]
        code, out, _ = self.run_wide(entries)
        self.assertEqual(code, 0, out)

    def test_registration_requiredは1件でも警告(self):
        code, out, _ = self.run_wide([entry(at(0), "soratomoCreateSky: rejected", UID_PLAIN, reason="registration_required")])
        self.assertEqual(code, 1, out)
        self.assertIn(WARN, self.line_with(out, "registration_required（目安"))

    def test_registration_requiredが無ければ警告なし(self):
        code, out, _ = self.run_wide([entry(at(0), "soratomoCreateSky: rejected", UID_PLAIN, reason="not_member")])
        self.assertEqual(code, 0, out)
        self.assertIn("registration_required（目安 1 件でも）: 0", out)

    def test_internalは1件でも警告(self):
        code, out, _ = self.run_wide([entry(at(0), "soratomoCreateSky: internal", UID_PLAIN)])
        self.assertEqual(code, 1, out)
        self.assertIn("soratomoCreateSky=1" + WARN, out)

    # MARK: - 使用量

    def test_使用量が目安ちょうどなら警告なしで1つ超えると警告(self):
        code, out, _ = self.run_wide([], usage={READ_METRIC: {"10/13": 153368, "10/14": 100}})
        self.assertEqual(code, 0, out)
        self.assertNotIn(WARN, out)
        self.assertIn("Firestore 読み取り: 10/13 153,368, 10/14 100（目安 153,368）", out)
        code, out, _ = self.run_wide([], usage={READ_METRIC: {"10/13": 153369, "10/14": 100}})
        self.assertEqual(code, 1, out)
        line = self.line_with(out, "Firestore 読み取り")
        self.assertIn(f"10/13 153,369（{WARN}目安超え）", line)
        self.assertNotIn(WARN, line.split("10/14")[1])

    def test_Storage転送はGBで比べる(self):
        code, out, _ = self.run_wide([], usage={SENT_METRIC: {"10/13": 8.27e9}})
        self.assertEqual(code, 1, out)
        self.assertIn(f"10/13 8.27（{WARN}目安超え）", out)
        code, out, _ = self.run_wide([], usage={SENT_METRIC: {"10/13": 8.26e9}})
        self.assertEqual(code, 0, out)

    def test_Storageの保存量は目安なしで値だけ(self):
        usage = {"storage.googleapis.com/storage/total_bytes": {"10/14": 99e9}}
        code, out, _ = self.run_wide([], usage=usage)
        self.assertEqual(code, 0, out)
        line = self.line_with(out, "Storage 保存量（日の最大）GB")
        self.assertIn("10/14 99.00", line)
        self.assertNotIn("目安", line)
        self.assertIn("日付が 1 日ずれて見える", out)

    def test_使用量のデータが無い指標はデータなしと出す(self):
        code, out, _ = self.run_wide([])
        self.assertEqual(code, 0, out)
        self.assertIn("Firestore 削除: データなし", out)

    def test_PostHogは別に数える案内が最後の方に出る(self):
        code, out, _ = self.run_wide([])
        self.assertIn("PostHog はこの道具では読まない。MCP の execute-sql で別に数える", out)

    # MARK: - トークン

    def test_トークンの期限が切れていればネットワークを呼ばずに終了コード2(self):
        self.patchers["load_token"].stop()  # 本物の load_token を使う（ネットワークは差し替えのまま＝呼ぶと NetworkCalled）
        self.addCleanup(self.patchers["load_token"].start)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "firebase-tools.json")
            expired_ms = (time.time() - 3600) * 1000
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"tokens": {"access_token": TOKEN, "expires_at": expired_ms}}, f)
            with mock.patch.object(sp, "TOKEN_FILE", path):
                code, out = self.run_tool(WIDE)  # api を渡さない: ネットワークを呼んだら NetworkCalled で落ちる
        self.assertEqual(code, 2, out)
        self.assertIn("firebase projects:list > /dev/null", out)
        self.assert_no_token(out)

    def test_トークンの残りが3分未満なら止まり3分以上なら読める(self):
        self.patchers["load_token"].stop()
        self.addCleanup(self.patchers["load_token"].start)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "firebase-tools.json")

            def write(minutes_left):
                with open(path, "w", encoding="utf-8") as f:
                    json.dump({"tokens": {"access_token": TOKEN, "expires_at": (time.time() + minutes_left * 60) * 1000}}, f)

            with mock.patch.object(sp, "TOKEN_FILE", path):
                write(2)
                with self.assertRaises(sp.ReadError) as cm:
                    sp.load_token()
                self.assertNotIn(TOKEN, str(cm.exception))
                write(10)
                self.assertEqual(sp.load_token(), TOKEN)

    def test_ログイン情報が壊れていても中身を出さない(self):
        self.patchers["load_token"].stop()
        self.addCleanup(self.patchers["load_token"].start)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "firebase-tools.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"tokens": {"refresh_token": TOKEN}}, f)
            with mock.patch.object(sp, "TOKEN_FILE", path):
                code, out = self.run_tool(WIDE)
        self.assertEqual(code, 2, out)
        self.assert_no_token(out)
        self.assertNotIn("refresh_token", out)
        self.assertNotIn("access_token", out)

    # MARK: - 読めないとき（終了コード 2）

    def test_HTTP403の本文にトークンが混ざっても伏せて終了コード2(self):
        err = http_error(sp.LOGGING_URL, 403, '{"error": {"message": "token ' + TOKEN + ' denied"}}')
        code, out = self.run_tool(WIDE, FakeGoogleApi(errors={"logging.googleapis.com": err}))
        self.assertEqual(code, 2, out)
        self.assertIn("HTTP 403", out)
        self.assert_no_token(out)

    def test_HTTPのエラーの本文で600文字目をまたぐトークンも伏せる(self):
        err = http_error(sp.LOGGING_URL, 403, "x" * 590 + TOKEN)
        code, out = self.run_tool(WIDE, FakeGoogleApi(errors={"logging.googleapis.com": err}))
        self.assertEqual(code, 2, out)
        self.assertNotIn(TOKEN[:10], out)
        self.assert_no_token(out)

    def test_401ならトークンの更新の手順を出す(self):
        err = http_error(sp.LOGGING_URL, 401, '{"error": {"code": 401}}')
        code, out = self.run_tool(WIDE, FakeGoogleApi(errors={"logging.googleapis.com": err}))
        self.assertEqual(code, 2, out)
        self.assertIn("firebase projects:list > /dev/null", out)

    def test_Monitoringの失敗も終了コード2で警告の1と見分ける(self):
        err = http_error(sp.MONITORING_URL, 500, "{}")
        api = FakeGoogleApi(log_pages=[self.skies(21)], errors={"monitoring.googleapis.com": err})
        code, out = self.run_tool(WIDE, api)
        self.assertEqual(code, 2, out)  # ログ側が目安超えでも、読めなかった 2 を優先する
        self.assertIn("HTTP 500", out)

    def test_通信の失敗は3回まで試しトークンが混ざっても伏せる(self):
        err = urllib.error.URLError("接続先が " + TOKEN + " を返した")
        api = FakeGoogleApi(errors={"logging.googleapis.com": err})
        code, out = self.run_tool(WIDE, api)
        self.assertEqual(code, 2, out)
        self.assertEqual(len(api.calls), 3)
        self.assertIn("通信の失敗", out)
        self.assert_no_token(out)

    def test_想定外の例外の文にトークンが混ざっても伏せる(self):
        def broken(req, timeout=None):
            raise ValueError("想定外: " + TOKEN)

        code, out = self.run_tool(WIDE, broken)
        self.assertEqual(code, 2, out)
        self.assertIn("ValueError", out)
        self.assert_no_token(out)

    # MARK: - 送る要求

    def test_送る要求はloggingのPOSTとmonitoringのGETだけでprojectとヘッダーが付く(self):
        api = FakeGoogleApi(log_pages=[self.skies(2), self.skies(1)])
        code, out = self.run_tool(WIDE, api)
        self.assertEqual(code, 0, out)
        posts = [c for c in api.calls if c[0] == "POST"]
        gets = [c for c in api.calls if c[0] == "GET"]
        self.assertEqual(len(posts) + len(gets), len(api.calls))
        self.assertEqual(len(posts), 2)
        self.assertEqual(len(gets), len(sp.USAGE_METRICS))
        for _, url, auth, project, body in posts:
            self.assertEqual(url, "https://logging.googleapis.com/v2/entries:list")
            self.assertEqual(body["resourceNames"], ["projects/soramoyou-ios"])
            self.assertEqual(body["orderBy"], "timestamp asc")
        for _, url, auth, project, body in gets:
            self.assertTrue(url.startswith("https://monitoring.googleapis.com/v3/projects/soramoyou-ios/timeSeries?"), url)
            self.assertIsNone(body)
        for _, url, auth, project, _ in api.calls:
            self.assertEqual(auth, "Bearer " + TOKEN)
            self.assertEqual(project, "soramoyou-ios")
        # 6 つの指標を全部読む
        metrics = {urllib.parse.parse_qs(urllib.parse.urlparse(c[1]).query)["filter"][0] for c in gets}
        self.assertEqual(len(metrics), 6)

    def test_ページの間は待つ(self):
        api = FakeGoogleApi(log_pages=[[], [], []])
        self.run_tool(WIDE, api)
        sleeps = [c.args[0] for c in sp.time.sleep.call_args_list]
        self.assertEqual(sleeps.count(sp.PAGE_INTERVAL_SEC), 2)

    # MARK: - 使い方の誤り

    def test_dayとfromの両方は終了コード2(self):
        code, out = self.run_tool(["--day", "2026-10-15", "--from", "2026-10-13 00:00", "--to", "2026-10-14 00:00"])
        self.assertEqual(code, 2, out)

    def test_どちらも無ければ終了コード2(self):
        code, out = self.run_tool([])
        self.assertEqual(code, 2, out)

    def test_fromだけ_toだけも終了コード2(self):
        self.assertEqual(self.run_tool(["--from", "2026-10-13 00:00"])[0], 2)
        self.assertEqual(self.run_tool(["--to", "2026-10-13 00:00"])[0], 2)

    def test_日付の形が違う_終わりが始まり以前なら終了コード2(self):
        self.assertEqual(self.run_tool(["--day", "10/15"])[0], 2)
        self.assertEqual(self.run_tool(["--from", "2026-10-13", "--to", "2026-10-14 00:00"])[0], 2)
        self.assertEqual(self.run_tool(["--from", "2026-10-14 00:00", "--to", "2026-10-13 00:00"])[0], 2)

    def test_parse_tsは9桁の小数部を読んでJSTにする(self):
        t = sp.parse_ts("2026-10-13T14:59:59.999999999Z")
        self.assertEqual((t.month, t.day, t.hour, t.minute, t.second), (10, 13, 23, 59, 59))
        t = sp.parse_ts("2026-10-13T15:00:00Z")
        self.assertEqual((t.month, t.day, t.hour), (10, 14, 0))


if __name__ == "__main__":
    unittest.main()
