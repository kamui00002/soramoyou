# そらもよう - UIテスト自動化 完了サマリー

## 📋 作成したファイル一覧

### 1. UIテストファイル

| ファイル名 | パス | 説明 |
|---|---|---|
| **AppStoreReviewUITests.swift** | `Soramoyou/SoramoyouUITests/` | App Store審査対応修正の主要なUIテスト |
| **ATTPermissionUITests.swift** | `Soramoyou/SoramoyouUITests/` | ATT（App Tracking Transparency）のテスト |
| **UITestHelpers.swift** | `Soramoyou/SoramoyouUITests/` | UIテスト用のヘルパークラス・拡張機能 |
| **Info.plist** | `Soramoyou/SoramoyouUITests/` | UITestsターゲットの設定ファイル |
| **README_UITests.md** | `Soramoyou/SoramoyouUITests/` | UIテスト実行ガイド |

### 2. ドキュメント・ガイド

| ファイル名 | パス | 説明 |
|---|---|---|
| **ACCESSIBILITY_IDENTIFIERS_GUIDE.md** | プロジェクトルート | アクセシビリティ識別子の追加ガイド |
| **run_ui_tests.sh** | プロジェクトルート | UIテスト実行スクリプト |
| **UI_TESTS_SUMMARY.md** | プロジェクトルート | このファイル（サマリー） |

---

## 🎯 テスト対象機能（審査対応修正）

### ✅ 1. ホームスクロール機能
- **テストメソッド**: `testHomeViewScrolling()`, `testPostCardTappable()`
- **内容**: HomeViewのDragGesture競合を解消し、正常にスクロールできることを確認

### ✅ 2. プロフィール読み込み機能
- **テストメソッド**: `testProfileLoading()`, `testProfileReloadsOnAuthStateChange()`
- **内容**: ProfileViewModelのAuth状態復元対応を確認

### ✅ 3. アカウント削除機能
- **テストメソッド**: `testAccountDeletion()`, `testAccountDeletionConfirmation()`
- **内容**: 設定画面からのアカウント削除フローが正常に動作することを確認

### ✅ 4. 通報機能（UGC対策）
- **テストメソッド**: `testReportPost()`, `testReportReasonSelection()`
- **内容**: 投稿詳細から通報機能が動作し、通報理由を選択できることを確認

### ✅ 5. ブロック機能（UGC対策）
- **テストメソッド**: `testBlockUser()`, `testBlockedUserPostsHiddenInFeed()`
- **内容**: ユーザーブロック機能が動作し、フィードから非表示になることを確認

### ✅ 6. ATT（App Tracking Transparency）
- **テストメソッド**: `testATTDialogAppearsAfterLaunch()`, `testATTDialogNotShownDuringInit()`, 他
- **内容**: ATTダイアログが適切なタイミング（ContentView.onAppear）で表示されることを確認

---

## 🚀 次のステップ（実行手順）

### ステップ1: UIテストファイルをXcodeプロジェクトに追加

1. Xcodeで `Soramoyou.xcodeproj` を開く
2. **SoramoyouUITests** フォルダを右クリック → **Add Files to "Soramoyou"...**
3. 以下のファイルを選択して追加：
   - `AppStoreReviewUITests.swift`
   - `ATTPermissionUITests.swift`
   - `UITestHelpers.swift`
   - `Info.plist`
4. **Target Membership** で `SoramoyouUITests` にチェック

### ステップ2: アクセシビリティ識別子を追加

**📘 詳細ガイド**: `ACCESSIBILITY_IDENTIFIERS_GUIDE.md` を参照

以下のファイルに `.accessibilityIdentifier()` を追加：

- [ ] `WelcomeView.swift`
- [ ] `ContentView.swift`
- [ ] `HomeView.swift`（PostCard, PostDetailView, メニューボタン、通報・ブロックボタン）
- [ ] `ProfileView.swift`（ProfileView, profileImage, displayName）
- [ ] `SettingsView.swift`（SettingsView, アカウント削除ボタン）
- [ ] `GalleryDetailView.swift`（メニューボタン、通報・ブロックボタン）
- [ ] `BannerAdView.swift`

### ステップ3: テストを実行

#### 方法1: Xcode GUIから実行

```
⌘ + U (Command + U)
```

または

```
Product → Test
```

#### 方法2: コマンドラインから実行

```bash
cd /Users/yoshidometoru/そらもよう
./run_ui_tests.sh
```

### ステップ4: テスト結果を確認

1. **Test Navigator** を開く（左サイドバー、ダイヤモンドアイコン）
2. テスト結果を確認：
   - ✅ 緑チェック: 成功
   - ❌ 赤バツ: 失敗
3. 失敗したテストがあれば、エラーメッセージを確認して修正

---

## 📊 テストケース一覧

### AppStoreReviewUITests.swift（10テストケース）

1. `testHomeViewScrolling()` - ホーム画面のスクロール機能
2. `testPostCardTappable()` - 投稿カードのタップ機能
3. `testProfileLoading()` - プロフィール読み込み
4. `testProfileReloadsOnAuthStateChange()` - Auth状態復元
5. `testAccountDeletion()` - アカウント削除フロー
6. `testAccountDeletionConfirmation()` - アカウント削除確認
7. `testReportPost()` - 投稿通報機能
8. `testReportReasonSelection()` - 通報理由選択
9. `testBlockUser()` - ユーザーブロック機能
10. `testBlockedUserPostsHiddenInFeed()` - ブロック後のフィルタリング

### ATTPermissionUITests.swift（4テストケース）

1. `testATTDialogAppearsAfterLaunch()` - ATTダイアログの表示
2. `testATTDialogNotShownDuringInit()` - init()中は表示されないことの確認
3. `testAdInitializationAfterATTResponse()` - ATT許可後の広告初期化
4. `testAdNotInitializedBeforeATTPermission()` - ATT許可前は広告が初期化されないことの確認

**合計: 14テストケース**

---

## ⚙️ テスト環境の設定（オプション）

### UI Testing用の起動引数を追加

**ファイル**: `Soramoyou/SoramoyouApp.swift`

```swift
import SwiftUI
import Firebase

@main
struct SoramoyouApp: App {

    init() {
        FirebaseApp.configure()

        // UI Testing モードの検出
        if CommandLine.arguments.contains("UI-TESTING") {
            // テスト用の設定
            print("🧪 UI Testing モードで起動")

            // ATTの状態をリセット（テスト用）
            if ProcessInfo.processInfo.environment["RESET_ATT_STATUS"] == "1" {
                print("🔄 ATT状態をリセット")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

---

## 🔧 トラブルシューティング

### 問題1: ビルドエラー「No such module 'XCTest'」

**解決策**:
1. Xcodeで **TARGETS** → **SoramoyouUITests** を選択
2. **Build Phases** → **Link Binary With Libraries** に `XCTest.framework` があることを確認

### 問題2: 要素が見つからない（Element not found）

**解決策**:
- `ACCESSIBILITY_IDENTIFIERS_GUIDE.md` を参照して、全ての識別子を追加
- Xcodeの **Debug** → **View Debugging** → **Capture View Hierarchy** で確認

### 問題3: ATTダイアログが表示されない

**解決策**:
- **実機でテストする**（シミュレータではATTが動作しない場合がある）
- または、シミュレータの設定をリセット: `Device → Erase All Content and Settings...`

### 問題4: テストがタイムアウトする

**解決策**:
- `waitForExistence(timeout:)` の timeout 値を増やす
- ネットワーク通信が遅い場合は、テスト環境でモックデータを使用

---

## 📝 今後の改善提案

### 1. モックデータの使用
- テスト環境ではFirebaseの代わりにモックデータを使用することで、テストの高速化と安定化を図る

### 2. スクリーンショットの自動撮影
- 各テストケースでスクリーンショットを自動撮影し、テストレポートに添付

### 3. CI/CD統合
- GitHub ActionsやXcode Cloudでテストを自動実行

### 4. カバレッジの測定
- コードカバレッジを測定し、テストの網羅性を確認

---

## ✅ 完了チェックリスト

### テストファイル作成
- [x] AppStoreReviewUITests.swift
- [x] ATTPermissionUITests.swift
- [x] UITestHelpers.swift
- [x] Info.plist
- [x] README_UITests.md

### ドキュメント作成
- [x] ACCESSIBILITY_IDENTIFIERS_GUIDE.md
- [x] run_ui_tests.sh
- [x] UI_TESTS_SUMMARY.md

### 次のステップ（ユーザーが実施）
- [ ] UIテストファイルをXcodeプロジェクトに追加
- [ ] アクセシビリティ識別子を全てのビューに追加
- [ ] テストを実行して全て成功することを確認
- [ ] App Store審査に提出

---

## 📞 サポート

質問や問題がある場合は、以下を確認してください：

1. **README_UITests.md** - UIテスト実行ガイド
2. **ACCESSIBILITY_IDENTIFIERS_GUIDE.md** - アクセシビリティ識別子の追加方法
3. **Xcodeのコンソールログ** - エラーメッセージを確認

---

**作成日**: 2026-02-15
**バージョン**: 1.0
**対象**: App Store審査対応修正のUIテスト自動化
