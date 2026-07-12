#!/usr/bin/env bash
# appstore-release.sh
#
# App Store Connect への「版作成・新機能欄記入・ビルド選択・審査提出」を
# fastlane deliver 経由で自動化するラッパースクリプト。
# TestFlight へのバイナリアップロードは対象外
# （既存 ~/.claude/scripts/xcode-testflight-upload.sh が担当・本スクリプトはその先の工程）。
#
# 前提:
# - macOS Keychain に secret CLI (~/.claude/bin/secret) で
#   `secret save ASC_KEY_ID` / `secret save ASC_ISSUER_ID` 登録済み
# - ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 配置済み
# - fastlane/metadata/ja/release_notes.txt が提出前に実際のリリースノート草案で
#   更新済み（PLACEHOLDER のままだと prepare/submit 実行前に止まる）
#
# 重要方針: 「審査提出 GO の最終判断は自動化しない」。
#   submit サブコマンドは既定で対話確認（SUBMIT と入力）を要求する。
#   AIエージェントがユーザーのGO確認を得た上で呼ぶ場合のみ --yes を付ける。
#
# マニフェストによる改変検知:
#   prepare 成功時に fastlane/.release-manifest（version/build/リリースノートのSHA-256）を
#   書き出す。submit はこの内容と現在の状態を照合し、prepare 後に release_notes.txt や
#   version/build が変わっていれば「再度 prepare からやり直して」と表示して止まる
#   （prepare→ASCで内容確認→submit の間の確認漏れ防止）。
#
# Usage:
#   scripts/appstore-release.sh <status|prepare|submit> [--version <X.Y.Z>] [--build <N>] [--yes]
#
# Examples:
#   scripts/appstore-release.sh status
#   scripts/appstore-release.sh prepare --version 1.9.3 --build 73
#   scripts/appstore-release.sh submit --version 1.9.3 --build 73 --yes

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PBX="$REPO_ROOT/Soramoyou/Soramoyou.xcodeproj/project.pbxproj"
RELEASE_NOTES="$REPO_ROOT/fastlane/metadata/ja/release_notes.txt"
MANIFEST="$REPO_ROOT/fastlane/.release-manifest"

usage() {
    cat <<EOF >&2
Usage: $(basename "$0") <status|prepare|submit> [--version <X.Y.Z>] [--build <N>] [--yes]

  status   App Store Connect API 認証の疎通確認（最新TestFlightビルド番号を表示）
  prepare  App Store版の作成・新機能欄記入・ビルド選択（審査提出はしない）
  submit   審査提出（不可逆）。確認プロンプトあり（--yes でスキップ）

Options:
  --version <X.Y.Z>  App Store版番号（既定値: pbxprojのMARKETING_VERSION）
  --build <N>         ビルド番号（既定値: pbxprojのCURRENT_PROJECT_VERSION）
  --yes               submit時の確認プロンプトをスキップ（AIエージェントがGO確認済みで呼ぶ用）

Examples:
  $(basename "$0") status
  $(basename "$0") prepare --version 1.9.3 --build 73
  $(basename "$0") submit --version 1.9.3 --build 73 --yes
EOF
}

# pbxproj から値を読む小関数（既存 xcode-testflight-upload.sh と同方式）。
# 最初の出現＝アプリ本体ターゲット。テストターゲットは別値のため head -1 で除外する。
read_pbx_first() { grep "$1 = " "$PBX" | head -1 | sed -E "s/.*$1 = ([^;]+);.*/\\1/"; }

# --version / --build が未指定なら pbxproj の現在値をデフォルトにする。
# prepare / submit の両方から呼ぶことで、フォールバックロジックの重複を防ぐ。
resolve_version_and_build() {
    if [[ -z "$VERSION" ]]; then
        VERSION="$(read_pbx_first MARKETING_VERSION)"
    fi
    if [[ -z "$BUILD" ]]; then
        BUILD="$(read_pbx_first CURRENT_PROJECT_VERSION)"
    fi
}

# リリースノートが PLACEHOLDER のままでないかをシェル側でも確認する
# （fastlane 側の Fastfile にも同じガードがあり、二重ガードにしている）。
check_release_notes() {
    if [[ ! -f "$RELEASE_NOTES" ]]; then
        echo "❌ リリースノートファイルが見つからない: $RELEASE_NOTES" >&2
        exit 1
    fi
    if [[ ! -s "$RELEASE_NOTES" ]]; then
        echo "❌ リリースノートが空。$RELEASE_NOTES を草案で埋めてから実行して" >&2
        exit 1
    fi
    if grep -q "PLACEHOLDER" "$RELEASE_NOTES"; then
        echo "❌ リリースノートが PLACEHOLDER のまま。$RELEASE_NOTES を実際の草案で置き換えてから実行して" >&2
        exit 1
    fi
}

# release_notes.txt の SHA-256 を計算する（macOS 標準の shasum を使用、ハッシュ値のみ切り出す）。
notes_sha256() { shasum -a 256 "$RELEASE_NOTES" | awk '{print $1}'; }

# prepare 成功時にマニフェストを書き出す。
# version / build / release_notes.txt のハッシュを記録し、submit 時の改変検知に使う。
write_manifest() {
    {
        echo "version=$VERSION"
        echo "build=$BUILD"
        echo "notes_sha256=$(notes_sha256)"
    } > "$MANIFEST"
}

# submit 前にマニフェストと現在の状態を照合する。
# prepare 未実行、または prepare 後に release_notes.txt / version / build が
# 変わっていれば、どれが不一致かを明示して止める（通信前に検証できるようにする）。
verify_manifest() {
    if [[ ! -f "$MANIFEST" ]]; then
        echo "❌ マニフェストが見つからない: $MANIFEST ・先に prepare を実行して" >&2
        exit 1
    fi

    local m_version="" m_build="" m_notes_sha256=""
    while IFS='=' read -r key value; do
        case "$key" in
            version)      m_version="$value" ;;
            build)        m_build="$value" ;;
            notes_sha256) m_notes_sha256="$value" ;;
        esac
    done < "$MANIFEST"

    local current_notes_sha256
    current_notes_sha256="$(notes_sha256)"

    local mismatches=()
    if [[ "$m_version" != "$VERSION" ]]; then
        # 注意: macOS 標準 bash(3.2) は set -u 下で「$VAR」直後にマルチバイト文字（全角括弧等）が
        # 続くと変数名の境界を誤認識し "unbound variable" になることがあるため ${VERSION} と明示する。
        mismatches+=("version（マニフェスト=$m_version 現在=${VERSION}）")
    fi
    if [[ "$m_build" != "$BUILD" ]]; then
        mismatches+=("build（マニフェスト=$m_build 現在=${BUILD}）")
    fi
    if [[ "$m_notes_sha256" != "$current_notes_sha256" ]]; then
        mismatches+=("notes_sha256（release_notes.txt の内容が変わっている）")
    fi

    if [[ ${#mismatches[@]} -gt 0 ]]; then
        echo "❌ release_notes.txt か version/build が prepare 後に変わっている。再度 prepare からやり直して" >&2
        echo "   不一致: ${mismatches[*]}" >&2
        exit 1
    fi
}

# ASC_KEY_ID / ASC_ISSUER_ID を secret CLI から取得して ENV にセットする。
# 値は一切 echo せず、引数にも直書きしない。
load_asc_credentials() {
    if ! command -v secret >/dev/null 2>&1; then
        echo "❌ secret コマンドが見つからない（~/.claude/bin を PATH に追加するか確認して）" >&2
        exit 1
    fi

    if ! ASC_KEY_ID="$(secret get ASC_KEY_ID)"; then
        echo "❌ secret get ASC_KEY_ID に失敗した（Keychain 登録を確認して: secret save ASC_KEY_ID）" >&2
        exit 1
    fi
    export ASC_KEY_ID

    if ! ASC_ISSUER_ID="$(secret get ASC_ISSUER_ID)"; then
        echo "❌ secret get ASC_ISSUER_ID に失敗した（Keychain 登録を確認して: secret save ASC_ISSUER_ID）" >&2
        exit 1
    fi
    export ASC_ISSUER_ID

    local p8_path="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
    if [[ ! -f "$p8_path" ]]; then
        echo "❌ APIキーの秘密鍵が見つからない: $p8_path" >&2
        exit 1
    fi
}

# --- 引数チェック ---
if [[ $# -eq 0 ]]; then
    usage
    exit 64
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
    status|prepare|submit) ;;
    *)
        usage
        exit 64
        ;;
esac

VERSION=""
BUILD=""
YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            # set -u 環境で値なしの --version を弾く（$# -lt 2 が true なら "$2" を評価しない）
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "❌ --version には値が必要（例: --version 1.9.3）" >&2
                usage
                exit 64
            fi
            VERSION="$2"
            shift 2
            ;;
        --build)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "❌ --build には値が必要（例: --build 73）" >&2
                usage
                exit 64
            fi
            BUILD="$2"
            shift 2
            ;;
        --yes)
            YES=true
            shift
            ;;
        *)
            echo "❌ 不明なオプション: $1" >&2
            usage
            exit 64
            ;;
    esac
done

# fastlane のテレメトリ・自動アップデートチェックを無効化（非対話実行のため）
export FASTLANE_OPT_OUT_USAGE=1
export FASTLANE_SKIP_UPDATE_CHECK=1

case "$SUBCOMMAND" in
    status)
        load_asc_credentials
        cd "$REPO_ROOT"
        fastlane asc_status
        ;;
    prepare)
        # チェック順: release_notes → resolve → secret → fastlane（オフラインでもプレースホルダ検知だけは検証できる）
        check_release_notes
        resolve_version_and_build
        load_asc_credentials
        cd "$REPO_ROOT"
        fastlane release_prepare "version:$VERSION" "build:$BUILD"
        # fastlane が成功した後にのみマニフェストを書き出す（失敗時は set -e で到達しない）
        write_manifest
        ;;
    submit)
        # チェック順: release_notes → resolve → verify_manifest → secret → サマリ表示 → 確認 → fastlane
        # verify_manifest を secret 取得より前に置くことで、マニフェスト不一致は通信なしで検出できる。
        check_release_notes
        resolve_version_and_build
        verify_manifest
        load_asc_credentials

        # 対象サマリは --yes でも必ず表示する（--yes でスキップするのは SUBMIT 入力プロンプトだけ）
        echo "対象: version=$VERSION build=$BUILD"
        echo "リリースノート冒頭:"
        head -n 3 "$RELEASE_NOTES"

        # 審査提出は不可逆操作。--yes が無ければ対話確認で明示的な同意を取る。
        if [[ "$YES" != "true" ]]; then
            read -r -p "審査提出は不可逆です。実行するなら SUBMIT と入力: " ans
            if [[ "$ans" != "SUBMIT" ]]; then
                echo "中止した"
                exit 1
            fi
        fi

        cd "$REPO_ROOT"
        fastlane release_submit "version:$VERSION" "build:$BUILD"
        ;;
esac
