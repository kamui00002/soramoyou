#!/usr/bin/env bash
# ☀️ UI テストの抜け道の見張り（セキュリティ監査 2026-10-14 の 5-1・REPORT §7 ②）
#
# UI テストは Soramoyou/SoramoyouUITests/XCUIApplication.swift（同じ名前の版）を通して起動すると、
# アプリに「Firebase を Emulator へ切り替える目印」が必ず渡る。次の 2 つを見つけたら失敗する（終了コード 1）。
#   1. XCTest（や XCUIAutomation）のモジュール名を付けて XCUIApplication を書いている
#      → 同じ名前の版を通らずに起動でき、テストが本番につながる。例外は同じ名前の版の宣言 1 行だけ
#   2. 同じ名前の版の宣言が無い → UI テストの XCUIApplication() が XCTest の素の版になる
#
# 使い方：bash scripts/check-uitests-launch-guard.sh [見張るフォルダ]（既定は Soramoyou/SoramoyouUITests）
# CI（.github/workflows/security-tests.yml）が PR ごとに回す。
set -euo pipefail

dir="${1:-Soramoyou/SoramoyouUITests}"
shadow="$dir/XCUIApplication.swift"
# 同じ名前の版の宣言。この形の 1 行だけを例外にする
# （元の型の置き場は Xcode 27 で XCUIAutomation。XCTest のモジュール名では、同じ名前のクラスに取られて書けない）
declaration='^class XCUIApplication: XCUIAutomation\.XCUIApplication \{$'

if [ ! -d "$dir" ]; then
  echo "❌ 見張るフォルダがありません: $dir" >&2
  exit 2
fi

# 1. モジュール名付きの書き方を探す
#    grep は 1 件も見つけないと終了コード 1 を返すので、|| true で受け止める（見つからない＝正常）
violations=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  file="${line%%:*}"      # 「ファイル:行番号:中身」のファイル
  rest="${line#*:}"       # 「行番号:中身」
  content="${rest#*:}"    # 「中身」
  if [ "$file" = "$shadow" ] && printf '%s\n' "$content" | grep -qE "$declaration"; then
    continue
  fi
  violations+="$line"$'\n'
done < <(grep -rnE '(XCTest|XCUIAutomation)[[:space:]]*\.[[:space:]]*XCUIApplication' --include='*.swift' "$dir" || true)

if [ -n "$violations" ]; then
  echo "❌ UI テストに、同じ名前の版（${shadow}）を通らない XCUIApplication の書き方があります。" >&2
  echo "   この書き方で起動したアプリは、Firebase の本番につながります。モジュール名を付けずに XCUIApplication() と書いてください。" >&2
  printf '%s' "$violations" >&2
  exit 1
fi

# 2. 同じ名前の版の宣言があるか
if ! grep -qE "$declaration" "$shadow" 2>/dev/null; then
  echo "❌ 同じ名前の版の宣言が $shadow にありません。" >&2
  echo "   無いと、UI テストの XCUIApplication() が XCTest の素の版になり、目印が渡りません。" >&2
  exit 1
fi

echo "✅ UI テストの起動は、すべて同じ名前の版（${shadow}）を通ります"
