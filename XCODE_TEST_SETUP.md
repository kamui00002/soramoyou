# Xcode UIテストターゲット設定手順

## 📋 概要

作成したUIテストファイルをXcodeプロジェクトに正しく追加し、テストを実行できるようにするための手順書です。

---

## ✅ 手順1: Xcodeでプロジェクトを開く

```bash
open Soramoyou/Soramoyou.xcodeproj
```

---

## ✅ 手順2: テストターゲットの確認

1. **プロジェクトナビゲーター**（左側）でプロジェクトファイル（一番上の青いアイコン）を選択
2. **TARGETS**セクションを確認
3. `SoramoyouUITests`ターゲットが存在するか確認

### ターゲットが存在しない場合

1. TARGETSセクションの下部にある**"+"ボタン**をクリック
2. "iOS" → "Testing" → **"UI Testing Bundle"**を選択
3. "Next"をクリック
4. **Product Name:** `SoramoyouUITests`
5. **Target to be Tested:** `Soramoyou`を選択
6. **Language:** `Swift`
7. "Finish"をクリック

---

## ✅ 手順3: テストファイルをターゲットに追加

### 既存のテストファイルを確認

プロジェクトナビゲーターで `Soramoyou/SoramoyouUITests/` フォルダを確認。
以下のファイルが存在するはずです：

- ✅ SoramoyouUITests.swift（既存）
- ✅ SoramoyouUITests+EditFeatures.swift（新規）
- ✅ SoramoyouUITests+PostDetail.swift（新規）
- ✅ SoramoyouUITests+Drafts.swift（新規）
- ✅ SoramoyouUITests+SearchFeatures.swift（新規）
- ✅ SoramoyouUITests+Ads.swift（新規）
- ✅ SoramoyouUITests+E2E.swift（新規）

### ファイルがプロジェクトに表示されない場合

1. Finderで `Soramoyou/SoramoyouUITests/` フォルダを開く
2. 上記の新規ファイルが存在することを確認
3. Xcodeのプロジェクトナビゲーターで `SoramoyouUITests` フォルダを**右クリック**
4. **"Add Files to 'Soramoyou'..."**を選択
5. 追加されていないテストファイルを選択
6. **Options:**
   - ✅ "Copy items if needed"にチェック
   - ✅ "Add to targets:"で`SoramoyouUITests`にチェック
7. "Add"をクリック

### Target Membershipの確認

1. プロジェクトナビゲーターで各テストファイルを選択
2. 右側の**File Inspector**（一番右のアイコン）を開く
3. **Target Membership**セクションで`SoramoyouUITests`にチェックが入っているか確認
4. チェックが入っていない場合、チェックを入れる

---

## ✅ 手順4: 依存関係の設定

1. `SoramoyouUITests`ターゲットを選択
2. **"Build Phases"**タブを開く
3. **"Dependencies"**セクションを展開
4. **"+"ボタン**をクリック
5. `Soramoyou`を選択して"Add"

---

## ✅ 手順5: ビルド設定の確認

1. `SoramoyouUITests`ターゲットを選択
2. **"Build Settings"**タブを開く
3. 検索バーで"Test Host"を検索
4. **TEST_HOST**が以下のように設定されていることを確認：
   ```
   $(BUILT_PRODUCTS_DIR)/Soramoyou.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Soramoyou
   ```
5. **BUNDLE_LOADER**が以下のように設定されていることを確認：
   ```
   $(TEST_HOST)
   ```

---

## ✅ 手順6: Info.plistの確認

`SoramoyouUITests` フォルダに `Info.plist` ファイルが存在するか確認。
存在しない場合は、Xcodeが自動的に生成します。

---

## ✅ 手順7: テストのビルドと実行

### ビルドエラーの確認

1. **Product** → **Build For** → **Testing**（または `Cmd + Shift + U`）
2. ビルドエラーが表示される場合は、エラーメッセージを確認して修正

### よくあるビルドエラーと対処法

#### エラー: "No such module 'XCTest'"

**原因:** テストファイルが正しいターゲットに追加されていない

**対処法:**
- 手順3を再確認
- 各テストファイルのTarget Membershipを確認

#### エラー: "Use of undeclared type 'SoramoyouUITests'"

**原因:** 拡張ファイル（extension）が元のクラスを見つけられない

**対処法:**
- `SoramoyouUITests.swift`がターゲットに追加されているか確認
- すべてのテストファイルが同じターゲットに属しているか確認

#### エラー: "Missing required module 'XCUIApplication'"

**原因:** テストターゲットが正しく設定されていない

**対処法:**
- 手順2でテストターゲットを正しく作成
- Build Settingsで"Enable Testing Search Paths"が"Yes"になっているか確認

---

## ✅ 手順8: テストの実行

### 方法1: テストナビゲーターから実行（推奨）

1. **Test Navigator**を開く（`Cmd + 6`）
2. `SoramoyouUITests`を展開
3. テストクラスとテスト関数が表示されることを確認

テスト実行オプション：
- **全テスト実行:** `SoramoyouUITests`の横の▶️ボタンをクリック
- **特定のクラスのテスト実行:** クラス名（例: `SoramoyouUITests+EditFeatures`）の横の▶️ボタンをクリック
- **特定のテスト実行:** テスト関数名（例: `testEditView_FilterTab_Display`）の横の▶️ボタンをクリック

### 方法2: メニューから実行

1. **Product** → **Test**（または `Cmd + U`）
2. すべてのテストが実行される

### 方法3: 特定のテストをコードから実行

1. テストファイルを開く
2. テスト関数の左側に表示される**◇マーク**をクリック
3. テストが実行される

---

## ✅ 手順9: テスト実行前の準備

### シミュレータの設定

1. **テストデバイスを選択**
   - Xcodeツールバーのデバイス選択メニューから`iPhone 14 Pro`などを選択

2. **シミュレータの言語設定**
   - シミュレータを起動
   - **Settings** → **General** → **Language & Region**
   - **iPhone Language:** `日本語`
   - **Region:** `日本`

3. **テスト用の写真を追加**（オプション）
   - シミュレータを起動
   - Safari等で画像をダウンロードして写真アプリに保存
   - または、Xcodeから`Soramoyou`アプリを実行して、テスト画像を追加

### Firebase設定の確認

1. `GoogleService-Info.plist`が正しく配置されているか確認
2. テスト用のFirebaseアカウントを作成（推奨）:
   ```
   メールアドレス: test@example.com
   パスワード: testpassword123
   ```

---

## ✅ 手順10: テスト結果の確認

テスト実行後：

1. **Test Navigator**（`Cmd + 6`）で結果を確認
   - ✅ 緑のチェックマーク: 成功
   - ❌ 赤いXマーク: 失敗

2. 失敗したテストをクリックして詳細を確認
3. **Report Navigator**（`Cmd + 9`）で詳細なログを確認

### テストレポートの確認

1. **Report Navigator**を開く
2. 最新のテスト実行を選択
3. テスト結果、実行時間、失敗の詳細を確認

---

## 🐛 トラブルシューティング

### テストが見つからない

**問題:** Test Navigatorにテストが表示されない

**対処法:**
1. **Product** → **Clean Build Folder**（`Cmd + Shift + K`）
2. Xcodeを再起動
3. テストターゲットが正しく設定されているか再確認

### テストがタイムアウトする

**問題:** `waitForExistence(timeout:)`でタイムアウトエラー

**対処法:**
1. タイムアウト時間を延長（例: `timeout: 10.0`）
2. UI要素のアクセシビリティIDを確認
3. 画面遷移のタイミングを調整（必要に応じて`sleep()`を追加）

### Firebase接続エラー

**問題:** Firebaseに接続できない

**対処法:**
1. インターネット接続を確認
2. `GoogleService-Info.plist`が正しく設定されているか確認
3. テスト用のFirebaseプロジェクトを使用

### 写真選択のテスト失敗

**問題:** 写真ピッカーで写真を選択できない

**対処法:**
1. iOS 14以降のPHPickerは自動操作に制限があります
2. テストでは「写真ピッカーが表示される」ことまでを確認
3. 実際の写真選択はモックまたは手動操作が必要

---

## 📝 チェックリスト

テスト実行前に以下を確認してください：

- [ ] Xcodeでプロジェクトを開いている
- [ ] `SoramoyouUITests`ターゲットが存在する
- [ ] すべてのテストファイルが`SoramoyouUITests`ターゲットに追加されている
- [ ] 依存関係が正しく設定されている
- [ ] ビルドエラーがない
- [ ] シミュレータが選択されている
- [ ] シミュレータの言語設定が日本語
- [ ] Firebaseの設定が完了している
- [ ] テスト用アカウントを作成済み（オプション）

---

## 🎯 次のステップ

1. ✅ この手順書に従ってテストターゲットを設定
2. ✅ 小さなテストから実行して動作確認
3. ✅ 全テストを実行してカバレッジを確認
4. ✅ 失敗したテストをデバッグ
5. ✅ CI/CDへの統合を検討（GitHub Actions等）

---

**最終更新日:** 2026-01-25
