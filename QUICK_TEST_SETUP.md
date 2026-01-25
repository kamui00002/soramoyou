# 🚀 UIテスト設定クイックガイド

## ✅ 良いニュース！

あなたのXcodeプロジェクトは **PBXFileSystemSynchronizedRootGroup** を使用しているため、
ファイルシステムと自動的に同期します。

つまり、**テストファイルは既にプロジェクトに認識されているはずです**！

---

## 📝 確認手順（3ステップ）

### Step 1: Xcodeでプロジェクトを開く

```bash
open Soramoyou/Soramoyou.xcodeproj
```

### Step 2: プロジェクトをクリーンビルド

1. **Product** メニュー → **Clean Build Folder** (`Cmd + Shift + K`)
2. **Product** メニュー → **Build** (`Cmd + B`)

### Step 3: テストを確認

1. **Test Navigator**を開く（`Cmd + 6`）
2. `SoramoyouUITests`を展開
3. 以下の新しいテストファイルが表示されるはずです：
   - ✅ SoramoyouUITests+EditFeatures
   - ✅ SoramoyouUITests+PostDetail
   - ✅ SoramoyouUITests+Drafts
   - ✅ SoramoyouUITests+SearchFeatures
   - ✅ SoramoyouUITests+Ads
   - ✅ SoramoyouUITests+E2E

---

## 🧪 テストの実行

### 全テストを実行

1. Test Navigatorで`SoramoyouUITests`の横の **▶️ボタン** をクリック
2. または、`Cmd + U`

### 特定のテストのみ実行

1. Test Navigatorで実行したいテストファイルまたはテストケースを選択
2. 横の **▶️ボタン** をクリック

---

## ⚠️ もしテストが表示されない場合

### オプション1: プロジェクトをリフレッシュ

1. Xcodeを完全に終了
2. 以下のコマンドを実行：
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData
   ```
3. Xcodeを再度開く
4. プロジェクトをクリーンビルド

### オプション2: ファイルを手動で追加（最終手段）

1. Project Navigatorで `SoramoyouUITests` フォルダを右クリック
2. **"Add Files to 'Soramoyou'..."** を選択
3. `Soramoyou/SoramoyouUITests/` フォルダから以下のファイルを選択：
   - SoramoyouUITests+EditFeatures.swift
   - SoramoyouUITests+PostDetail.swift
   - SoramoyouUITests+Drafts.swift
   - SoramoyouUITests+SearchFeatures.swift
   - SoramoyouUITests+Ads.swift
   - SoramoyouUITests+E2E.swift
4. **Options:**
   - ✅ "Copy items if needed"にチェック（不要だが安全のため）
   - ✅ "Add to targets:"で`SoramoyouUITests`にチェック
5. "Add"をクリック

---

## 📊 テスト実行結果の確認

テスト実行後、以下で結果を確認できます：

- **Test Navigator** (`Cmd + 6`) - テストの成功/失敗
- **Report Navigator** (`Cmd + 9`) - 詳細なログ

---

## 🎯 期待される結果

すべてが正しく設定されていれば、**合計約110個以上のテストケース**が表示されます：

- 基本テスト（SoramoyouUITests.swift）: 約35個
- 編集機能テスト（EditFeatures）: 15個
- 投稿詳細テスト（PostDetail）: 13個
- 下書きテスト（Drafts）: 9個
- 検索機能テスト（SearchFeatures）: 20個
- 広告テスト（Ads）: 10個
- E2Eテスト（E2E）: 9個

---

**設定完了後、テスト結果をお知らせください！**
