#!/bin/bash

# そらもよう - Firebaseデプロイスクリプト（CI/CDトークン使用）
# 使用方法: ./firebase-deploy-with-token.sh [token] [project-id]

set -e

# 色付きログ
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}そらもよう - Firebase デプロイ${NC}"
echo -e "${GREEN}(CI/CDトークン使用)${NC}"
echo -e "${GREEN}==================================${NC}"
echo ""

# トークンの確認
if [ -z "$1" ]; then
  echo -e "${RED}エラー: Firebaseトークンが指定されていません${NC}"
  echo -e "${YELLOW}使用方法: $0 [token] [project-id]${NC}"
  echo ""
  echo -e "${YELLOW}トークンの生成方法:${NC}"
  echo -e "  1. Macで 'firebase login:ci' を実行"
  echo -e "  2. 生成されたトークンをコピー"
  echo -e "  3. このスクリプトの引数に指定"
  echo ""
  exit 1
fi

FIREBASE_TOKEN="$1"

# プロジェクトIDの確認
if [ -n "$2" ]; then
  PROJECT_ID="$2"
  echo -e "${YELLOW}プロジェクトID: ${PROJECT_ID}${NC}"

  # .firebasercを更新
  cat > .firebaserc <<EOF
{
  "projects": {
    "default": "${PROJECT_ID}"
  }
}
EOF
  echo -e "${GREEN}✓ .firebasercを更新しました${NC}"
else
  echo -e "${YELLOW}プロジェクトIDが指定されていません${NC}"
  echo -e "${YELLOW}.firebasercの設定を使用します${NC}"
fi

echo ""

# Firebase CLIのバージョン確認
echo -e "${YELLOW}Firebase CLI バージョン:${NC}"
firebase --version
echo ""

# デプロイ対象の確認
echo -e "${YELLOW}デプロイ対象ファイル:${NC}"
echo -e "  - firestore.rules"
echo -e "  - firestore.indexes.json"
echo -e "  - storage.rules"
echo ""

# Firestoreルールのデプロイ
echo -e "${YELLOW}[1/3] Firestoreセキュリティルールをデプロイ中...${NC}"
if firebase deploy --only firestore:rules --token "$FIREBASE_TOKEN"; then
  echo -e "${GREEN}✓ Firestoreルールのデプロイ成功${NC}"
else
  echo -e "${RED}✗ Firestoreルールのデプロイ失敗${NC}"
  exit 1
fi

echo ""

# Firestoreインデックスのデプロイ
echo -e "${YELLOW}[2/3] Firestoreインデックスをデプロイ中...${NC}"
if firebase deploy --only firestore:indexes --token "$FIREBASE_TOKEN"; then
  echo -e "${GREEN}✓ Firestoreインデックスのデプロイ成功${NC}"
else
  echo -e "${RED}✗ Firestoreインデックスのデプロイ失敗${NC}"
  exit 1
fi

echo ""

# Storageルールのデプロイ
echo -e "${YELLOW}[3/3] Storageセキュリティルールをデプロイ中...${NC}"
if firebase deploy --only storage --token "$FIREBASE_TOKEN"; then
  echo -e "${GREEN}✓ Storageルールのデプロイ成功${NC}"
else
  echo -e "${RED}✗ Storageルールのデプロイ失敗${NC}"
  exit 1
fi

echo ""
echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}✓ すべてのデプロイが完了しました！${NC}"
echo -e "${GREEN}==================================${NC}"
echo ""

# デプロイ後の確認
echo -e "${YELLOW}次のステップ:${NC}"
echo -e "  1. Firebase Console でルールを確認"
echo -e "  2. テストデータで動作確認"
echo -e "  3. アプリで接続テスト"
echo ""
