# ビルド・デプロイ・運用ガイド ☀️

## テスト・動作確認（コミット前必須）

### チェックリスト
- [ ] 実装した機能が正常に動作するか
- [ ] 既存機能に影響がないか
- [ ] エラー・警告が発生しないか（Xcodeコンソール確認）
- [ ] UI/UXが期待通りか（各デバイスサイズで確認）
- [ ] パフォーマンスに問題はないか
- [ ] メモリリークがないか（Instruments使用）
- [ ] 画像の読み込み・表示が正常か
- [ ] Firebase連携が正常に動作するか

### iOS開発時の確認方法
```bash
# Xcodeでビルド＆実行
# Command + R または ▶ボタン

# 確認すべきデバイス・OS
- iPhone SE (小画面)
- iPhone 14 Pro (標準)
- iPhone 14 Pro Max (大画面)
- iOS最小サポートバージョン
```

### 確認項目詳細

#### 画像関連
- [ ] 写真選択が正常に動作
- [ ] 編集機能（フィルター・ツール）が正常に動作
- [ ] 画像圧縮が適切に行われている
- [ ] サムネイル生成が正常
- [ ] カメラロール保存が正常

#### Firebase関連
- [ ] 認証（ログイン・新規登録）が正常
- [ ] Firestoreへの保存・読み込みが正常
- [ ] Firebase Storageへの画像アップロードが正常
- [ ] セキュリティルールが正しく動作

#### UI/UX
- [ ] タブバーが正常に表示・動作
- [ ] 画面遷移がスムーズ
- [ ] AdMobバナー広告が適切に表示
- [ ] ダークモード対応（実装時）
- [ ] ローディング表示が適切

### Xcodeコンソールでの確認
```
# エラー・警告がないことを確認
# 特に以下をチェック
- Thread 1: signal SIGABRT（クラッシュ）
- EXC_BAD_ACCESS（メモリ関連エラー）
- Firebase関連のエラーログ
```

---

## ポート設定（Web開発時）

### React Native / Expo
- **Metro Bundler**: `http://localhost:8081`
- **Expo Dev Server**: `http://localhost:19000`

### Webアプリ開発時
- **フロントエンド**: `http://localhost:3000`
- **バックエンドAPI**: `http://localhost:8000`

⚠️ **これらのポート番号は変更しないこと**

### ポート使用中の場合
```bash
# ポート確認
lsof -i :[ポート番号]

# プロセス終了
kill -9 <PID>
```

---

## PR作成時のガイドライン

### PRタイトル
```
[機能] 空の写真にフィルター機能を追加
[修正] アルバム画面のクラッシュを解消
[改善] 画像読み込み速度の向上
```

### PR本文に含める内容
```markdown
## 変更内容
- [具体的な変更内容を箇条書き]

## 実装詳細
- [技術的な詳細]

## テスト結果
- [x] iOS シミュレータで動作確認
- [x] 実機で動作確認
- [x] 既存機能への影響なし

## スクリーンショット（該当する場合）
[画像を添付]

## 備考
[特記事項があれば]
```

---

## .gitignore 管理

### 必ず除外すべきファイル（iOS開発）
```gitignore
# Xcode
*.xcworkspace/xcuserdata/
*.xcuserstate
DerivedData/
*.xccheckout
*.moved-aside
*.hmap
*.ipa
*.dSYM.zip
*.dSYM

# CocoaPods
Pods/
*.podspec
Podfile.lock

# Swift Package Manager
.swiftpm/
.build/
Package.resolved

# Firebase設定ファイル（APIキー含む場合は除外）
GoogleService-Info.plist  # 要確認：公開するかどうか

# 環境変数
.env
.env.local
.env.*.local

# ビルド生成物
build/
dist/

# OS生成ファイル
.DS_Store
Thumbs.db

# ログファイル
*.log

# テスト結果
*.xcresult
fastlane/report.xml
fastlane/Preview.html
fastlane/screenshots
fastlane/test_output
```

**新規ファイル作成時**: GitHubに上げるべきでないファイルは必ず`.gitignore`に追加

---

## Info.plist 必要な権限

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>写真を選択して投稿するために使用します</string>

<key>NSPhotoLibraryAddUsageDescription</key>
<string>編集した写真を保存するために使用します</string>

<key>NSCameraUsageDescription</key>
<string>写真を撮影するために使用します（Phase 3）</string>

<key>NSLocationWhenInUseUsageDescription</key>
<string>投稿に位置情報を追加するために使用します</string>
```

---

## 修正時の注意事項

### 慎重に確認すること
1. **影響範囲の確認**
   - 修正によって他の処理に問題がないか
   - 関連する機能すべてをチェック

2. **既存の期待動作を維持**
   - 他の動作も修正が必要な場合は対応
   - 既存機能が正常に動作するよう修正

3. **段階的な実装**
   - 大きな変更は小さく分割
   - 各ステップで動作確認

---

## デバッグ・トラブルシューティング

### エラー発生時の対応
1. **エラーメッセージを正確に確認**
2. **関連するコードを特定**
3. **段階的に原因を切り分け**
4. **修正後は必ず動作確認**

### よくある問題と対処

#### Firebase関連
```
問題: "Permission denied"
対処: Firestoreセキュリティルールを確認
```

#### ビルドエラー
```
問題: "Module not found"
対処: 依存関係を再インストール
npm install / pod install
```

---

## Issue作成時のガイドライン

### タイトル形式
```
[機能] 具体的な機能名
[修正] 具体的な問題
[改善] 具体的な改善内容
```

### Issue本文のテンプレート
```markdown
## 背景・目的
[なぜこのIssueが必要か]

## 実装内容
[何を実装するか（具体的に）]

## 期待される動作
[完成後の状態]

## 技術的な考慮事項
[注意すべき点、技術的な制約など]

## タスク
- [ ] ブランチ作成
- [ ] 実装
- [ ] テスト
- [ ] PR作成

## 備考
[その他の情報]
```

---

## 最終確認チェックリスト（作業完了前）

- [ ] 全ての機能が正常に動作する
- [ ] 既存機能に影響がない
- [ ] エラー・警告が表示されない
- [ ] コードに適切なコメントがある
- [ ] 不要なコンソールログを削除した
- [ ] `.gitignore`に必要なファイルを追加した
- [ ] コミットメッセージが適切
- [ ] PRの説明が十分
