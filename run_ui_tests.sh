#!/bin/bash

# そらもよう - UIテスト実行スクリプト
# App Store審査対応修正のUIテストを自動実行します

set -e  # エラーが発生したら即座に終了

# カラー出力用
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# プロジェクトディレクトリ
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR/Soramoyou"

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}そらもよう - UIテスト実行${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""

# シミュレータを選択
SIMULATOR="iPhone 15 Pro"
echo -e "${YELLOW}使用するシミュレータ: ${SIMULATOR}${NC}"
echo ""

# テスト結果の出力先
RESULT_BUNDLE="TestResults_$(date +%Y%m%d_%H%M%S).xcresult"
echo -e "${YELLOW}テスト結果の保存先: ${RESULT_BUNDLE}${NC}"
echo ""

# UIテストを実行
echo -e "${GREEN}UIテストを実行中...${NC}"
echo ""

xcodebuild test \
  -project Soramoyou.xcodeproj \
  -scheme Soramoyou \
  -destination "platform=iOS Simulator,name=${SIMULATOR}" \
  -resultBundlePath "../${RESULT_BUNDLE}" \
  | xcpretty --color

# テスト結果を確認
if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}✅ 全てのテストが成功しました！${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    echo -e "テスト結果: ../${RESULT_BUNDLE}"
else
    echo ""
    echo -e "${RED}======================================${NC}"
    echo -e "${RED}❌ テストが失敗しました${NC}"
    echo -e "${RED}======================================${NC}"
    echo ""
    echo -e "テスト結果: ../${RESULT_BUNDLE}"
    exit 1
fi

# テストレポートを開く（オプション）
read -p "テスト結果を開きますか？ (y/n): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    open "../${RESULT_BUNDLE}"
fi
