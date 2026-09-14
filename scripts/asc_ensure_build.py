#!/usr/bin/env python3
"""asc_ensure_build.py ☁️

App Store 版に「指定したビルド」が紐付いていることを保証する。
scripts/appstore-release.sh の prepare から、fastlane release_prepare の直後に呼ばれる。

なぜ必要か:
  fastlane deliver は submit_for_review: false のときビルドを選択しない。
  prepare が「成功」と表示しても ASC 上の「紐づくビルド」は空のままで、
  2026-08（1.9.9）/ 2026-09-11（1.10.0）/ 2026-09-14（1.10.1）と 3 回連続で
  手動の PATCH relationships/build で紐付け直していた。
  → prepare の成否を「表示」でなく「ASC から読み返した現物」で判定する。

処理:
  1. 版を読む（紐づくビルド番号・appStoreState）
  2. 指定ビルドと一致 → OK で終了
  3. 不一致 → 版が編集可能な状態のときだけ PATCH で紐付け → もう一度読み返して一致を確認
     （審査待ち・審査中・公開済みの版には絶対に書き込まない）

入力(引数):
  --version <X.Y.Z> --build <N> [--check-only]
  --check-only: 読み返しだけ行い、不一致なら exit 1（PATCH しない）

認証:
  ASC_KEY_ID / ASC_ISSUER_ID は ENV（appstore-release.sh の load_asc_credentials がセット）から読む。
  ENV に無ければ secret CLI から取得する。値は argv に載せず、出力にも出さない。
  JWT 生成は ~/.claude/scripts/asc_version_check.py の make_jwt を再利用する（依存: python3 + cryptography）。

終了コード: 0 = 紐付いている / 1 = 紐付けられなかった・照会失敗
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

BUNDLE_ID = "com.yoshidometoru.Soramoyou"

# パイプ越し（fastlane の後ろ）でも stdout と stderr の行順が入れ替わらないよう行バッファにする
sys.stdout.reconfigure(line_buffering=True)

# ビルドを差し替えてよい版の状態（これ以外＝審査待ち・審査中・公開済み等には書き込まない）
EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
}

sys.path.insert(0, os.path.expanduser("~/.claude/scripts"))
try:
    from asc_version_check import ASC_BASE, _get, get_app_id, make_jwt  # noqa: E402
except ImportError:
    print("❌ ~/.claude/scripts/asc_version_check.py を import できない（python3 + cryptography も要確認）", file=sys.stderr)
    sys.exit(1)


def credential(name: str) -> str:
    """ENV → secret CLI の順に取得する。値そのものは決して表示しない。"""
    value = os.environ.get(name, "").strip()
    if value:
        return value
    out = subprocess.run(["secret", "get", name], capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        raise RuntimeError(f"{name} を取得できない（ENV 未設定・secret get exit={out.returncode}）")
    return out.stdout.strip()


def _patch(url: str, token: str, body: dict) -> int:
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        method="PATCH",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status


def decide(state: str, attached_build, want_build: str, check_only: bool) -> str:
    """読み返し結果から次の行動を決める純関数。

    Returns: "ok"（一致）/ "mismatch"（check-only で不一致）/ "refuse"（編集不可の版）/ "patch"
    """
    if check_only:
        return "ok" if attached_build == want_build else "mismatch"
    # prepare 直後の版は編集可能なはず。審査待ち等の版で prepare が「成功」扱いになり
    # マニフェストが書かれる（＝submit への道が開く）ことを防ぐため、一致していても止める。
    if state not in EDITABLE_STATES:
        return "refuse"
    if attached_build == want_build:
        return "ok"
    return "patch"


def read_version(token: str, app_id: str, version: str):
    """版の id・状態・紐づくビルド番号を返す。版が無ければ None。"""
    q = urllib.parse.urlencode({
        "filter[versionString]": version,
        "filter[platform]": "IOS",
        "include": "build",
        "fields[appStoreVersions]": "versionString,appStoreState,appVersionState,build",
        "fields[builds]": "version",
    })
    d = _get(f"{ASC_BASE}/v1/apps/{app_id}/appStoreVersions?{q}", token)
    if not d.get("data"):
        return None
    item = d["data"][0]
    attrs = item["attributes"]
    state = attrs.get("appStoreState") or attrs.get("appVersionState") or "UNKNOWN"
    rel = (item.get("relationships", {}).get("build", {}) or {}).get("data")
    attached = None
    if rel:
        for inc in d.get("included", []):
            if inc["type"] == "builds" and inc["id"] == rel["id"]:
                attached = inc["attributes"].get("version")
    return item["id"], state, attached


def find_build_id(token: str, app_id: str, version: str, build: str):
    """版番号 + ビルド番号に一致し、processing 完了（VALID）のビルド id を返す。"""
    q = urllib.parse.urlencode({
        "filter[app]": app_id,
        "filter[version]": build,
        "filter[preReleaseVersion.version]": version,
        "fields[builds]": "version,processingState,expired",
        "limit": "2",
    })
    d = _get(f"{ASC_BASE}/v1/builds?{q}", token)
    for b in d.get("data", []):
        a = b["attributes"]
        if a.get("processingState") == "VALID" and not a.get("expired"):
            return b["id"]
    states = [b["attributes"].get("processingState") for b in d.get("data", [])]
    raise RuntimeError(f"build {build}（{version}）の VALID なビルドが見つからない（見つかった状態: {states or 'なし'}・processing 中なら待って再実行）")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--check-only", action="store_true")
    args = ap.parse_args()

    key_id = credential("ASC_KEY_ID")
    token = make_jwt(key_id, credential("ASC_ISSUER_ID"),
                     os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8"))
    app_id = get_app_id(token, BUNDLE_ID)

    found = read_version(token, app_id, args.version)
    if found is None:
        print(f"❌ ASC に版 {args.version} が無い（prepare が版を作れていない）", file=sys.stderr)
        return 1
    version_id, state, attached = found
    print(f"読み返し: 版 {args.version} / 状態 {state} / 紐づくビルド {attached or 'なし'}")

    action = decide(state, attached, args.build, args.check_only)
    if action == "ok":
        print(f"✅ 版 {args.version} に build {args.build} が紐付いている")
        return 0
    if action == "mismatch":
        print(f"❌ 紐づくビルドが {attached or 'なし'}（期待 {args.build}）", file=sys.stderr)
        return 1
    if action == "refuse":
        print(f"❌ 版の状態が {state} のため書き込まない（編集可能な状態でのみ紐付ける）", file=sys.stderr)
        return 1

    build_id = find_build_id(token, app_id, args.version, args.build)
    status = _patch(f"{ASC_BASE}/v1/appStoreVersions/{version_id}/relationships/build", token,
                    {"data": {"type": "builds", "id": build_id}})
    print(f"PATCH relationships/build → HTTP {status}")

    # PATCH の応答ではなく、読み返した現物で判定する
    _, state, attached = read_version(token, app_id, args.version)
    if attached != args.build:
        print(f"❌ PATCH 後も紐づくビルドが {attached or 'なし'}（期待 {args.build}）", file=sys.stderr)
        return 1
    print(f"✅ 版 {args.version} に build {args.build} を紐付けた（読み返しで確認）")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.HTTPError as e:
        # 応答本文の errors だけを出す（秘密を含みうる例外オブジェクト全体は出さない）
        try:
            errs = json.loads(e.read().decode("utf-8", "replace")).get("errors", [])
            detail = [(x.get("code"), x.get("detail") or x.get("title")) for x in errs]
        except Exception:  # noqa: BLE001
            detail = "unparsable"
        print(f"❌ ASC API HTTPError {e.code}: {detail}", file=sys.stderr)
        sys.exit(1)
    except RuntimeError as e:
        # 自分で組み立てたメッセージだけなので表示してよい
        print(f"❌ {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:  # noqa: BLE001 - 例外メッセージは出さない（パス・鍵の混入防止）
        print(f"❌ asc_ensure_build 失敗 type={type(e).__name__}", file=sys.stderr)
        sys.exit(1)
