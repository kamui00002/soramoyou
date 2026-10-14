#!/usr/bin/env python3
"""soratomo-patrol.py ☁️⭐️

本番（soramoyou-ios）の Functions のログ（Cloud Logging）と使用量（Cloud Monitoring）を読み、
JST の日ごとに集計して出す。そらともの見回り（毎日 1 回）の道具。
spec: .kiro/specs/soratomo-public-launch/（tasks.md 10.3 の目安・15.1 の見回り・要確認9・research.md の除外の条件）

⚠️ 読むだけ。本番に書かない（送る要求は、ログの entries:list への POST（検索の条件を送るだけで、書き込みではない）と、
   Monitoring の timeSeries への GET だけ）。
⚠️ 本番の読み取りなので、実行は利用者の GO を取ってから（tasks.md の「進め方の約束」）。
⚠️ トークンは出力しない。画面・ログ・例外の本文のどこにも出さない（HTTP のエラーの本文と例外の文は、
   トークンを伏せてから出す。想定外の例外も、型の名前と伏せた文だけを出し、トレースバックは出さない）。
⚠️ ログの本文・uid の全体・groupId の全体も出さない。出すのは uid／groupId の頭 6 文字・件数・理由・時刻だけ
   （tasks.md 15.1「ログと記録に出すのは uid の頭 6 文字と件数だけ」）。

使い方（リポジトリ直下で）:
  python3 scripts/soratomo-patrol.py --day 2026-10-15
      JST のその日の 0:00〜24:00 を集計する
  python3 scripts/soratomo-patrol.py --from '2026-10-13 18:27' --to '2026-10-15 00:00'
      JST の任意の窓（始まり以上・終わり未満）を集計する
  --day か（--from と --to）のどちらか一方が必須。両方・どちらも無しは使い方の誤り（終了コード 2）。
  トークンが切れている／切れそう（残り 3 分未満）のときは、ネットワークを呼ぶ前に止まる。
  `firebase projects:list > /dev/null` を一度実行してから再実行する。

出すもの:
  - 日ごと（JST）: メッセージごとの件数／`<関数>: ok` の uid ごとの件数／`<関数>: rejected` の reason ごとの件数
  - 窓全体で、乱用を疑う目安（10.3）: グループの作成・投稿・参加の not_found・registration_required・internal
  - 使用量（Cloud Monitoring・JST の日ごと）: 目安（10.3）を超えた日に ⚠️
  - PostHog はこの道具では読まない。MCP の execute-sql で別に数える（除外の条件は research.md）

認証:
  read-deployed-rules.py と同じ、firebase CLI のログイン情報（~/.config/configstore/firebase-tools.json）の
  tokens.access_token を使う。トークンは出力しない。

終了コード: 0 = 読めて ⚠️ なし / 1 = 読めて ⚠️ あり（目安超え）/ 2 = 読めなかった
  （トークン・API の失敗・使い方の誤り。1 と 2 を分けるのは、陽性対照の「目安を超えるデータで 1」を、
   読み取りの失敗と見分けられるようにするため）

テスト: python3 scripts/soratomo-patrol.test.py（ネットワークとトークンの読み込みを差し替える。本番には触れない）
"""
import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict

PROJECT_ID = "soramoyou-ios"
LOGGING_URL = "https://logging.googleapis.com/v2/entries:list"
MONITORING_URL = f"https://monitoring.googleapis.com/v3/projects/{PROJECT_ID}/timeSeries"
TOKEN_FILE = "~/.config/configstore/firebase-tools.json"
JST = dt.timezone(dt.timedelta(hours=9))

# トークンの残りがこれ（分）未満なら、ネットワークを呼ぶ前に止める（途中で切れて半端な集計になるのを防ぐ）
TOKEN_MIN_MINUTES = 3
# entries:list は 1 分 60 回までなので、ページの間は 1.1 秒待つ
PAGE_INTERVAL_SEC = 1.1

# 除外の頭（research.md の「除外の条件」の uid の頭 6 文字）。記録に印を付けるだけで、数からは除かない
# （除くと、テスト用アカウントの操作が本番の動きに見えなくなり、陽性対照も取れなくなる）
TEST_PREFIXES = {
    "8Ar2DV": "S3", "Qk9lcs": "S5", "nhYcDQ": "B", "1xPRKe": "S4",
    "FvPXCf": "審査デモ", "nzvqlZ": "開発者", "bOigAs": "開発者",
}

# 乱用を疑う目安（tasks.md 10.3「乱用を疑う目安（初期値・7 日目に見直す）」）。以上で ⚠️
GROUP_CREATE_LIMIT = 3      # 1 人が 24 時間にグループを 3 件以上作る
SKY_CREATE_LIMIT = 21       # 1 人が 1 つのグループに 24 時間で 21 件以上投稿する
JOIN_NOT_FOUND_LIMIT = 10   # 1 人の参加の not_found が 1 時間に 10 件以上
# registration_required と internal は 1 件でも ⚠️（要確認3: 本番は匿名ログインが無効なので、出たらアプリ以外からの要求を疑う）

# 使用量の目安（tasks.md 10.3・10.2 の 7 日の最大の 2 倍。7 日目に見直す）。超えた日に ⚠️
USAGE_LIMITS = {
    "Firestore 読み取り": 153368,
    "Firestore 書き込み": 4612,
    "Firestore 削除": 158,
    "Storage 転送（送信）GB": 8.26,
    "Functions 呼び出し（Cloud Run）": 4782,
}
# (表示名, 指標, 日ごとの集め方, 割る数)。Storage の保存量は伸びの目安（10.3）を人が前日と比べる（道具は値だけ出す）
USAGE_METRICS = [
    ("Firestore 読み取り", "firestore.googleapis.com/document/read_count", "ALIGN_SUM", 1),
    ("Firestore 書き込み", "firestore.googleapis.com/document/write_count", "ALIGN_SUM", 1),
    ("Firestore 削除", "firestore.googleapis.com/document/delete_count", "ALIGN_SUM", 1),
    ("Storage 転送（送信）GB", "storage.googleapis.com/network/sent_bytes_count", "ALIGN_SUM", 1e9),
    ("Storage 保存量（日の最大）GB", "storage.googleapis.com/storage/total_bytes", "ALIGN_MAX", 1e9),
    ("Functions 呼び出し（Cloud Run）", "run.googleapis.com/request_count", "ALIGN_SUM", 1),
]

WARN = "⚠️"
MAX_LABEL = 80  # ログ由来の文字列（メッセージ・reason）を出すときの上限。想定外に長い本文を出さないため


class ReadError(Exception):
    """読めなかったこと（終了コード 2）。文は、トークンを伏せてから作る"""


def load_token(now=None):
    """firebase CLI のログイン情報からアクセストークンを読む（値は出さない）。
    期限が切れている／切れそうなら、ネットワークを呼ぶ前に ReadError にする"""
    try:
        with open(os.path.expanduser(TOKEN_FILE), encoding="utf-8") as f:
            tokens = json.load(f)["tokens"]
        token = tokens["access_token"]
        expires_ms = tokens.get("expires_at", 0)
        left_min = (float(expires_ms) / 1000 - (time.time() if now is None else now)) / 60
    except (OSError, ValueError, KeyError, TypeError) as e:
        # 例外の文には、項目の名前やファイルの中身の一部が載ることがあるので、型の名前だけを出す
        raise ReadError(f"firebase CLI のログイン情報が読めない（{type(e).__name__}）。`firebase login` の状態を確かめる") from None
    # 空白・改行・制御文字の混ざったトークンは、http.client がヘッダーの検査で例外にし、その文にトークンを
    # repr（改行を \n と書いた形）で載せる。redact の完全一致では伏せられないので、送る前に止める（値は出さない）
    if not isinstance(token, str) or not token or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in token):
        raise ReadError("firebase CLI のログイン情報のトークンの形がおかしい（空・文字列でない・空白や改行を含む）。"
                        "`firebase projects:list > /dev/null` を一度実行してから再実行する")
    if left_min < TOKEN_MIN_MINUTES:
        raise ReadError(
            f"トークンが切れている／切れそう（残り {left_min:.0f} 分）。"
            "`firebase projects:list > /dev/null` を一度実行してから再実行する")
    return token


def redact(text, token):
    """文の中のトークンを伏せる。エラーの本文・例外の文は、出す前に必ずここを通す"""
    text = str(text)
    if token:
        text = text.replace(token, "<伏せた>")
    return text


def api_call(url, token, body=None):
    """GET（body なし）か POST（body あり）を送り、JSON を返す。失敗は ReadError（文はトークンを伏せる）"""
    headers = {"Authorization": "Bearer " + token, "x-goog-user-project": PROJECT_ID}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if body is not None else "GET")
    # 接続が切れるなどの一時的な失敗は 3 回まで再試行する（HTTP のエラーは再試行しない）
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=90) as res:
                return json.load(res)
        except urllib.error.HTTPError as e:
            # 伏せてから 600 文字に切る（切ってから伏せると、境界をまたぐトークンの頭が伏せきれずに出る）
            text = redact(e.read().decode("utf-8", errors="replace"), token)[:600]
            e.close()
            message = f"HTTP {e.code} {text}"
            if e.code == 401:
                message += "\nトークンが古い。`firebase projects:list > /dev/null` を一度実行してから再実行する"
            raise ReadError(message) from None
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt == 2:
                raise ReadError(redact(f"通信の失敗: {e}", token)) from None
            time.sleep(2)


def z(t):
    """JST の時刻を、検索の条件に書く UTC の文字列にする"""
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(s):
    """Cloud Logging の時刻（UTC・小数部は 9 桁まで）を JST の時刻にする。
    fromisoformat は 6 桁を超える小数部を読めない版があるので、6 桁に切ってから読む"""
    base, _, frac = s.rstrip("Z").partition(".")
    return dt.datetime.fromisoformat(base + ("." + frac[:6] if frac else "") + "+00:00").astimezone(JST)


def _now():
    """今の時刻（JST）。テストで固定できるように関数にしている（使用量の注記が日によって変わらないように）"""
    return dt.datetime.now(JST)


def day_key(t):
    return t.strftime("%m/%d")


def tag(uid):
    """uid を頭 6 文字だけにし、テスト用アカウントなら印を付ける"""
    if not isinstance(uid, str) or not uid:
        return "（uid なし）"
    p = uid[:6]
    return f"{p}({TEST_PREFIXES[p]})" if p in TEST_PREFIXES else p


def short(value):
    """ログ由来の文字列を、上限までに切って出す"""
    return str(value)[:MAX_LABEL]


def sliding_max(times, width):
    """時刻の並びのうち、幅 width の窓に入る件数の最大"""
    times = sorted(times)
    best, j = 0, 0
    for i, t in enumerate(times):
        while times[j] < t - width:
            j += 1
        best = max(best, i - j + 1)
    return best


def fetch_entries(start, end, token):
    """窓のログを最後のページまで読み、([(JST の時刻, jsonPayload)], ページ数) を返す"""
    flt = (f'timestamp>="{z(start)}" AND timestamp<"{z(end)}" AND resource.type="cloud_run_revision" '
           f'AND jsonPayload.message=~"^(soratomo|onSoratomo)"')
    entries, pages, page_token = [], 0, None
    while True:
        body = {"resourceNames": [f"projects/{PROJECT_ID}"], "filter": flt, "orderBy": "timestamp asc", "pageSize": 1000}
        if page_token:
            body["pageToken"] = page_token
        res = api_call(LOGGING_URL, token, body)
        pages += 1
        for e in res.get("entries", []):
            entries.append((parse_ts(e["timestamp"]), e.get("jsonPayload") or {}))
        page_token = res.get("nextPageToken")
        if not page_token:
            return entries, pages
        time.sleep(PAGE_INTERVAL_SEC)


def fmt_items(pairs, limit):
    """(名前, 件数) の並びを「名前=件数」にし、limit 以上には ⚠️ を付ける。(文字列, ⚠️ があるか) を返す"""
    warned = False
    cells = []
    for name, n in pairs:
        mark = ""
        if n >= limit:
            mark = WARN
            warned = True
        cells.append(f"{name}={n}{mark}")
    return ", ".join(cells), warned


def summarize_logs(entries, start, end, pages):
    """ログの項目から、出力の行と、⚠️ の有無を作る（純関数）"""
    lines = [f"== ログ（JST {start:%m/%d %H:%M}〜{end:%m/%d %H:%M}・{len(entries)} 件・{pages} ページ）"]
    by_day = defaultdict(list)
    for t, jp in entries:
        by_day[day_key(t)].append((t, jp))

    group_create = defaultdict(list)   # uid -> 時刻（同じ groupId の送り直しは最初の 1 件だけ）
    group_seen = set()                 # (uid, groupId)。送り直しを見分ける
    sky_create = defaultdict(list)     # (uid, groupId) -> 時刻（created が false でないものだけ）
    join_not_found = defaultdict(list)  # uid -> 時刻
    registration_required = 0
    internal = Counter()               # 関数名 -> 件数

    for day in sorted(by_day):
        rows = by_day[day]
        lines.append("")
        lines.append(f"[{day}] {len(rows)} 件")
        for m, n in sorted(Counter(short(jp.get("message")) for _, jp in rows).items()):
            lines.append(f"  {m}: {n}")
        ok_uid = defaultdict(Counter)
        rejected = defaultdict(Counter)
        for t, jp in rows:
            fn, _, kind = (jp.get("message") or "").partition(": ")
            fn = short(fn)
            if kind == "ok":
                ok_uid[fn][tag(jp.get("uid"))] += 1
                # 同じ要求 ID の送り直しは、サーバーが前回のグループを返して同じ groupId で ok を出す
                # （soratomoStore.js の冪等の枝）ので、(uid, groupId) が 2 回目以降のものは数えない。
                # groupId の無い項目は見分けられないので、そのまま数える
                if fn == "soratomoCreateGroup":
                    key = (jp.get("uid"), jp.get("groupId"))
                    if key[1] is None or key not in group_seen:
                        group_seen.add(key)
                        group_create[jp.get("uid")].append(t)
                # created が false のものは、再送で同じ投稿を返しただけ（新しい投稿ではない）なので数えない
                if fn == "soratomoCreateSky" and jp.get("created") is not False:
                    sky_create[(jp.get("uid"), jp.get("groupId"))].append(t)
            elif kind == "rejected":
                reason = jp.get("reason")
                rejected[fn][short(reason)] += 1
                if reason == "registration_required":
                    registration_required += 1
                if fn == "soratomoJoinGroup" and reason == "not_found":
                    join_not_found[jp.get("uid")].append(t)
            elif kind == "internal":
                internal[fn] += 1
        for fn in sorted(ok_uid):
            lines.append(f"  ok の uid ごと {fn}: " + ", ".join(f"{u}×{n}" for u, n in ok_uid[fn].most_common()))
        for fn in sorted(rejected):
            lines.append(f"  rejected の理由ごと {fn}: " + ", ".join(f"{r}×{n}" for r, n in rejected[fn].most_common()))

    warned = False
    lines.append("")
    lines.append("== 乱用を疑う目安（10.3・窓全体）")

    day = dt.timedelta(hours=24)
    gc = sorted(((tag(u), sliding_max(ts, day)) for u, ts in group_create.items()), key=lambda x: -x[1])
    text, w = fmt_items(gc, GROUP_CREATE_LIMIT)
    warned |= w
    lines.append(f"  グループの作成（1 人の 24 時間の最大・同じグループの送り直しを除く・目安 {GROUP_CREATE_LIMIT} 以上）: "
                 + (text or "0 件"))

    sc = sorted(((f"{tag(u)}/{(g or '')[:6]}", sliding_max(ts, day)) for (u, g), ts in sky_create.items()), key=lambda x: -x[1])
    text, w = fmt_items(sc[:10], SKY_CREATE_LIMIT)
    warned |= w
    lines.append(f"  投稿（1 人×1 グループの 24 時間の最大・目安 {SKY_CREATE_LIMIT} 以上・上位 10）: " + (text or "0 件"))

    nf = sorted(((tag(u), sliding_max(ts, dt.timedelta(hours=1))) for u, ts in join_not_found.items()), key=lambda x: -x[1])
    text, w = fmt_items(nf, JOIN_NOT_FOUND_LIMIT)
    warned |= w
    lines.append(f"  参加の not_found（1 人の 1 時間の最大・目安 {JOIN_NOT_FOUND_LIMIT} 以上）: " + (text or "0 件"))

    mark = WARN if registration_required >= 1 else ""
    warned |= registration_required >= 1
    lines.append(f"  registration_required（目安 1 件でも）: {registration_required}{mark}")

    text, w = fmt_items(sorted(internal.items()), 1)
    warned |= w
    lines.append("  <関数>: internal（目安 1 件でも）: " + (text or "0 件"))
    return lines, warned


def fetch_series(metric, aligner, mstart, mend, token):
    """指標を JST の日ごとに集めた {"MM/DD": 値}。データが無ければ空"""
    q = {"filter": f'metric.type="{metric}"', "interval.startTime": z(mstart), "interval.endTime": z(mend),
         "aggregation.alignmentPeriod": "86400s", "aggregation.perSeriesAligner": aligner,
         "aggregation.crossSeriesReducer": "REDUCE_SUM"}
    res = api_call(MONITORING_URL + "?" + urllib.parse.urlencode(q), token)
    out = {}
    for s in res.get("timeSeries", []):
        for p in s.get("points", []):
            # 日付は区切りの終わり（endTime）の 1 秒前で付ける。件数（DELTA）の点は startTime が区切りの始まりだが、
            # 保存量（GAUGE）の点は startTime が endTime と同じ（＝翌日の 0 時）なので、startTime で付けると
            # 保存量だけが 1 日先の日付になる（2026-10-15 の試作の実行で、保存量だけ 1 日ずれて出たことと合う。
            # GAUGE の点の形は一次資料では未確認＝要確認。--day の見回りで保存量がその日の日付で出れば合っている）
            end_t = dt.datetime.fromisoformat(p["interval"]["endTime"].replace("Z", "+00:00"))
            t = (end_t - dt.timedelta(seconds=1)).astimezone(JST)
            v = p["value"]
            out[day_key(t)] = out.get(day_key(t), 0) + float(v.get("int64Value", v.get("doubleValue", 0)))
    return dict(sorted(out.items()))


def usage_range(start, end):
    """使用量を読む範囲。窓の始まりの日の 0 時から、終わりを含む日の翌 0 時まで（日ごとの境目を JST の 0 時にそろえる）"""
    mstart = start.replace(hour=0, minute=0, second=0, microsecond=0)
    if end.hour == 0 and end.minute == 0 and end.second == 0 and end.microsecond == 0:
        return mstart, end
    return mstart, (end + dt.timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)


def summarize_usage(series):
    """[(表示名, {日: 生の値}, 割る数)] から、出力の行と ⚠️ の有無を作る（純関数）"""
    lines = ["", "== 使用量（Cloud Monitoring・JST の日ごと・その日の 0 時から）"]
    warned = False
    for name, values, div in series:
        if not values:
            lines.append(f"  {name}: データなし")
            continue
        limit = USAGE_LIMITS.get(name)
        cells = []
        for d, raw in values.items():
            val = raw / div
            s = f"{val:,.2f}" if div != 1 else f"{int(val):,}"
            if limit is not None and val > limit:
                s += f"（{WARN}目安超え）"
                warned = True
            cells.append(f"{d} {s}")
        lines.append(f"  {name}: " + ", ".join(cells) + (f"（目安 {limit:,}）" if limit is not None else ""))
    lines.append("  ※ Storage の保存量は、伸びの目安（tasks.md 10.3: 7 日で +0.51 GB＝1 日あたり約 0.07 GB の 2 倍＝"
                 "約 0.15 GB／日）を、前日の値と人が比べる（道具は警告の印を付けない）")
    return lines, warned


def usage_notes(end, mend, now):
    """使用量の注記の行（純関数）。窓の終わりが 0 時でないときと、最後の日がまだ終わっていないときだけ出す"""
    last_day = day_key(mend - dt.timedelta(seconds=1))
    notes = []
    if mend > end:
        notes.append(f"  ※ 使用量は日ごとの値なので、{last_day} は窓の終わり（{end:%H:%M}）を越えて、その日の終わりまでを数えている")
    if mend > now:
        notes.append(f"  ※ {last_day} はまだ終わっていないので、読んだ時刻までの途中の値")
    return notes


def parse_window(args):
    """引数から (始まり, 終わり) を JST で返す。使い方の誤りは ValueError"""
    try:
        if args.day:
            if args.from_ or args.to:
                raise ValueError("--day と --from／--to は一緒に使えない")
            start = dt.datetime.strptime(args.day, "%Y-%m-%d").replace(tzinfo=JST)
            return start, start + dt.timedelta(days=1)
        if not (args.from_ and args.to):
            raise ValueError("--day か、--from と --to の両方を渡す")
        start = dt.datetime.strptime(args.from_, "%Y-%m-%d %H:%M").replace(tzinfo=JST)
        end = dt.datetime.strptime(args.to, "%Y-%m-%d %H:%M").replace(tzinfo=JST)
    except ValueError as e:
        raise ValueError(f"窓の指定が読めない: {e}") from None
    if end <= start:
        raise ValueError("--to は --from より後にする")
    return start, end


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="本番の Functions のログと使用量を読み（読むだけ）、JST の日ごとに集計する。トークン・uid の全体は出さない。")
    parser.add_argument("--day", help="JST の日（YYYY-MM-DD）。その日の 0:00〜24:00")
    parser.add_argument("--from", dest="from_", help="JST の始まり（'YYYY-MM-DD HH:MM'）")
    parser.add_argument("--to", help="JST の終わり（'YYYY-MM-DD HH:MM'・含まない）")
    args = parser.parse_args(argv)
    try:
        args.window = parse_window(args)
    except ValueError as e:
        parser.error(str(e))
    return args


def main(argv=None):
    try:
        args = parse_args(sys.argv[1:] if argv is None else argv)
    except SystemExit as e:  # 使い方の誤り（argparse が文を出す）は終了コード 2
        return e.code if isinstance(e.code, int) else 2
    start, end = args.window
    token = None
    lines = []
    try:
        token = load_token()  # 期限が切れていたら、ここで止まる（ネットワークはまだ呼ばない）
        entries, pages = fetch_entries(start, end, token)
        log_lines, log_warned = summarize_logs(entries, start, end, pages)
        lines += log_lines
        mstart, mend = usage_range(start, end)
        series = [(name, fetch_series(metric, aligner, mstart, mend, token), div)
                  for name, metric, aligner, div in USAGE_METRICS]
        usage_lines, usage_warned = summarize_usage(series)
        lines += usage_lines + usage_notes(end, mend, _now())
    except ReadError as e:
        _emit(lines)
        print("読めなかった:", e)
        return 2
    except Exception as e:  # 想定外の例外も、トレースバックを出さず、型の名前とトークンを伏せた文だけを出す
        _emit(lines)
        print(f"想定外のエラー（{type(e).__name__}）: {redact(e, token)}")
        return 2

    lines.append("")
    lines.append("PostHog はこの道具では読まない。MCP の execute-sql で別に数える（除外の条件は research.md）")
    _emit(lines)
    if log_warned or usage_warned:
        print(f"結果: 目安を超えたものがある（{WARN}・終了コード 1）")
        return 1
    print("結果: 読めて、目安超えなし（終了コード 0）")
    return 0


def _emit(lines):
    for line in lines:
        print(line)


if __name__ == "__main__":
    sys.exit(main())
