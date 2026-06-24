# Soramoyou TestFlight automation
#
# 共通スクリプト経由で TestFlight 自動 upload。
# 詳細: ~/Library/Mobile Documents/com~apple~CloudDocs/toru/📋 リファレンス/
#       2026-05-17 App Store Connect API Key で TestFlight 自動 upload セットアップ.md

PROJECT := Soramoyou/Soramoyou.xcodeproj
SCHEME  := Soramoyou
UPLOAD  := $(HOME)/.claude/scripts/xcode-testflight-upload.sh

.PHONY: testflight build-only no-bump help

help:
	@echo "Available targets:"
	@echo "  make testflight  - build bump → archive → IPA → TestFlight upload"
	@echo "  make build-only  - bump + archive + IPA だけ (upload しない)"
	@echo "  make no-bump     - build 番号据え置きで再 archive + upload"

testflight:
	@$(UPLOAD) $(PROJECT) $(SCHEME)

build-only:
	@$(UPLOAD) $(PROJECT) $(SCHEME) --build-only

no-bump:
	@$(UPLOAD) $(PROJECT) $(SCHEME) --no-bump
