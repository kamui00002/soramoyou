#!/bin/zsh
# ⭐️☀️ 結合テスト用の Firebase Local Emulator Suite（Auth・Firestore・Storage）を、リポジトリの rules の写しで起動する（Kiro android-mvp 17.1・レビュー R14）
#
# なぜ写しを作るか:
#   firebase.json は iOS 版と共有で、Android の作業では変えない（変更は android/ と .gitignore に限る）。
#   はじめはリポジトリの firebase.json に emulators の設定が無く、Auth のエミュレータが起動しなかった（2026-10-05 実測）。
#   その後 main（ec3428f6）が emulators の設定を足したが、CLI は --config のファイルより上にある rules を読まない（2026-10-05 実測）ので、
#   一時ディレクトリに firebase.json と rules の写しを置いて起動する形は続ける。
#   写しは make-emulator-rules.sh が作る：storage.rules は原本のまま、firestore.rules は画像の URL の形に Android のエミュレータの
#   Storage の URL の形を 1 行だけ足したもの（足した所以外が原本と同じことを sha256 で確かめる。作れなければここで止まる）。
#
# 使い方: android/tools/start-firebase-emulators.sh   （止めるときは Ctrl+C）
# ポートは CLI の既定（Auth 9099・Firestore 8080・Storage 9199）で、アプリの FirebaseEmulator.kt と同じ値。
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/soramoyou-emulators.XXXXXX")
trap 'rm -r "$WORK"' EXIT

zsh "$ROOT/android/tools/make-emulator-rules.sh" "$ROOT" "$WORK"

cat > "$WORK/firebase.json" <<'EOF'
{
  "firestore": { "rules": "firestore.rules" },
  "storage": { "rules": "storage.rules" },
  "emulators": {
    "auth": { "port": 9099 },
    "firestore": { "port": 8080 },
    "storage": { "port": 9199 },
    "ui": { "enabled": false }
  }
}
EOF

# エミュレータは Java が要る。macOS の /usr/bin/java は中身の無い入口のことがあるので、Android Studio 同梱の JDK を使う
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"

# Storage のエミュレータは送信中のファイルを TMPDIR の下（firebase/storage/blobs）に置き、止めるときに丸ごと消す。
# 共有の TMPDIR のままだと、同じ Mac の別のセッションがエミュレータを止めた瞬間に置き場が消え、こちらのアップロードが ENOENT で落ちる。
# そこで専用の TMPDIR を使う（片付けは上の trap が WORK ごと消す。tasks.md 25.4 ⑦(2)・レビュー R25）
mkdir "$WORK/tmp"
export TMPDIR="$WORK/tmp"

cd "$WORK"
# demo- のプロジェクト ID は本物の Firebase に割り当てられない（エミュレータ以外へは繋がらない）
firebase emulators:start --only auth,firestore,storage --project demo-soramoyou --config "$WORK/firebase.json"
