# そらもよう - UIテスト実行ガイド

## 📋 概要

App Store審査対応修正のUIテスト自動化ファイルです。

### テスト対象機能

1. **ホームスクロール機能** - HomeViewが正常にスクロールできること
2. **プロフィール読み込み** - ProfileViewが正常にロードされること
3. **アカウント削除機能** - 設定画面からアカウント削除フローが動作すること
4. **通報機能** - 投稿詳細から通報機能が動作すること
5. **ブロック機能** - ユーザーブロックが正常に動作すること
6. **ATT（App Tracking Transparency）** - ATTダイアログが適切なタイミングで表示されること

---

## 🚀 テスト実行手順

### 1. Xcodeでプロジェクトを開く

```bash
cd /Users/yoshidometoru/そらもよう/Soramoyou
open Soramoyou.xcodeproj
```

### 2. UIテストファイルをXcodeプロジェクトに追加

現在、UIテストファイルはフォルダ内に作成されていますが、Xcodeプロジェクトに追加されていません。

#### 手順：

1. Xcodeで **Project Navigator** を開く（左サイドバー）
2. **SoramoyouUITests** フォルダを右クリック → **Add Files to "Soramoyou"...**
3. 以下のファイルを選択して追加：
   - `AppStoreReviewUITests.swift`
   - `ATTPermissionUITests.swift`
   - `UITestHelpers.swift`
4. **Target Membership** で `SoramoyouUITests` にチェックが入っていることを確認

### 3. テストターゲットの設定を確認

1. Xcodeのメニューバーで **Product** → **Scheme** → **Soramoyou** を選択
2. **Product** → **Scheme** → **Edit Scheme...** を開く
3. 左メニューで **Test** を選択
4. **Info** タブで `SoramoyouUITests` が追加されていることを確認

### 4. シミュレータを選択

1. Xcodeのツールバーで **シミュレータを選択**（例: iPhone 15 Pro）
2. 推奨シミュレータ:
   - iPhone 15 Pro (iOS 17.0以降)
   - iPhone SE (3rd generation) - 小画面テスト用

### 5. テストを実行

#### 方法1: 全テストを実行

```
Xcodeメニュー: Product → Test
または
⌘ + U (Command + U)
```

#### 方法2: 特定のテストクラスを実行

1. **Test Navigator** を開く（左サイドバー、ダイヤモンドアイコン）
2. テストしたいクラスを選択（例: `AppStoreReviewUITests`）
3. クラス名の右側の **▶ボタン** をクリック

#### 方法3: 特定のテストメソッドのみ実行

1. **Test Navigator** でテストメソッドを展開
2. テストメソッド名の右側の **▶ボタン** をクリック

---

## 📝 アクセシビリティ識別子の追加が必要

UIテストが正常に動作するためには、各ビューに **アクセシビリティ識別子（Accessibility Identifier）** を追加する必要があります。

### 追加が必要なビュー一覧

#### 1. WelcomeView（ウェルカム画面）

**ファイル**: `Soramoyou/Views/WelcomeView.swift`

```swift
var body: some View {
    VStack {
        // ... (既存のコード)
    }
    .accessibilityIdentifier("WelcomeView") // 追加
}
```

#### 2. ContentView（メインタブビュー）

**ファイル**: `Soramoyou/Views/ContentView.swift`

```swift
var body: some View {
    TabView {
        // ... (既存のコード)
    }
    .accessibilityIdentifier("ContentView") // 追加
}
```

#### 3. HomeView（ホーム画面）

**ファイル**: `Soramoyou/Views/HomeView.swift`

```swift
// PostCard（投稿カード）に識別子を追加
var body: some View {
    VStack {
        // ... (投稿カードのUI)
    }
    .accessibilityIdentifier("PostCard") // 追加
}

// PostDetailView（投稿詳細）に識別子を追加
var body: some View {
    ScrollView {
        // ... (詳細画面のUI)
    }
    .accessibilityIdentifier("PostDetailView") // 追加
}

// メニューボタンに識別子を追加
Button(action: { /* ... */ }) {
    Image(systemName: "ellipsis")
}
.accessibilityIdentifier("PostMenuButton") // 追加
```

#### 4. ProfileView（プロフィール画面）

**ファイル**: `Soramoyou/Views/ProfileView.swift`

```swift
var body: some View {
    VStack {
        // ... (既存のコード)
    }
    .accessibilityIdentifier("ProfileView") // 追加
}

// プロフィール画像に識別子を追加
AsyncImage(url: URL(string: user.photoURL ?? "")) { image in
    image
        .resizable()
        .scaledToFill()
} placeholder: {
    Image(systemName: "person.circle.fill")
}
.frame(width: 80, height: 80)
.clipShape(Circle())
.accessibilityIdentifier("profileImage") // 追加

// ユーザー名に識別子を追加
Text(user.displayName)
    .font(.title2)
    .fontWeight(.bold)
    .accessibilityIdentifier("displayName") // 追加
```

#### 5. SettingsView（設定画面）

**ファイル**: `Soramoyou/Views/SettingsView.swift`

```swift
var body: some View {
    List {
        // ... (既存のコード)
    }
    .accessibilityIdentifier("SettingsView") // 追加
}

// アカウント削除ボタンに識別子を追加
Button("アカウントを削除") {
    // ... (削除処理)
}
.foregroundColor(.red)
.accessibilityIdentifier("アカウントを削除") // 追加（ボタンテキストと同じ）
```

#### 6. 通報機能のUI（GalleryDetailViewまたはHomeView）

**ファイル**: `Soramoyou/Views/HomeView.swift` 、 `Soramoyou/Views/GalleryDetailView.swift`

```swift
// 通報ボタンに識別子を追加
Button("この投稿を通報する") {
    // ... (通報処理)
}
.accessibilityIdentifier("この投稿を通報する") // 追加

// ブロックボタンに識別子を追加
Button("このユーザーをブロック") {
    // ... (ブロック処理)
}
.accessibilityIdentifier("このユーザーをブロック") // 追加
```

#### 7. BannerAdView（広告バナー）

**ファイル**: `Soramoyou/Views/BannerAdView.swift`

```swift
var body: some View {
    // ... (広告バナーのUI)
        .accessibilityIdentifier("BannerAdView") // 追加
}
```

---

## 🧪 テストケース詳細

### AppStoreReviewUITests.swift

| テストメソッド | 内容 |
|---|---|
| `testHomeViewScrolling()` | ホーム画面が正常にスクロールできることを確認 |
| `testPostCardTappable()` | 投稿カードがタップ可能であることを確認 |
| `testProfileLoading()` | ログイン後にプロフィールが正常に読み込まれることを確認 |
| `testProfileReloadsOnAuthStateChange()` | Auth状態が復元されてプロフィールが再読み込みされることを確認 |
| `testAccountDeletion()` | アカウント削除フローが正常に動作することを確認 |
| `testAccountDeletionConfirmation()` | アカウント削除確認ボタンが表示されることを確認 |
| `testReportPost()` | 投稿詳細から通報機能が動作することを確認 |
| `testReportReasonSelection()` | 通報理由が正しく選択できることを確認 |
| `testBlockUser()` | ユーザーブロック機能が動作することを確認 |
| `testBlockedUserPostsHiddenInFeed()` | ブロック後にフィードから該当ユーザーの投稿が非表示になることを確認 |

### ATTPermissionUITests.swift

| テストメソッド | 内容 |
|---|---|
| `testATTDialogAppearsAfterLaunch()` | ATTダイアログがアプリ起動後に表示されることを確認 |
| `testATTDialogNotShownDuringInit()` | ATTダイアログが init() では表示されないことを確認 |
| `testAdInitializationAfterATTResponse()` | ATTの許可状態に応じて広告が適切に初期化されることを確認 |
| `testAdNotInitializedBeforeATTPermission()` | ATT許可前に広告が初期化されないことを確認 |

---

## ⚙️ テスト環境の設定

### UI Testing用の起動引数

テストでは起動引数 `["UI-TESTING"]` を使用しています。本番環境とテスト環境を分離するために、以下のコードをアプリに追加してください。

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
            // 例: UserDefaults.standard.set(true, forKey: "isUITesting")

            // ATTの状態をリセット（テスト用）
            if ProcessInfo.processInfo.environment["RESET_ATT_STATUS"] == "1" {
                // ATTリセット処理（実機ではリセットできない）
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

### 問題1: テストが見つからない

**原因**: UIテストファイルがXcodeプロジェクトに追加されていない

**解決策**:
1. Xcodeで **SoramoyouUITests** フォルダを右クリック
2. **Add Files to "Soramoyou"...** を選択
3. UIテストファイルを追加

### 問題2: ビルドエラー「No such module 'XCTest'」

**原因**: UITestsターゲットの設定が不正

**解決策**:
1. Xcodeで **PROJECT** → **Soramoyou** を選択
2. **TARGETS** → **SoramoyouUITests** を選択
3. **Build Phases** → **Link Binary With Libraries** に `XCTest.framework` が含まれていることを確認

### 問題3: 要素が見つからない（Element not found）

**原因**: アクセシビリティ識別子が追加されていない

**解決策**:
- 上記「アクセシビリティ識別子の追加が必要」セクションを参照
- 各ビューに `.accessibilityIdentifier()` を追加

### 問題4: ATTダイアログが表示されない

**原因**: シミュレータではATTダイアログが表示されない場合がある

**解決策**:
- **実機でテストする**（推奨）
- または、シミュレータの設定をリセット: `Device → Erase All Content and Settings...`

### 問題5: テストがタイムアウトする

**原因**: Firebaseの初期化やネットワーク通信に時間がかかっている

**解決策**:
- `waitForExistence(timeout:)` の timeout 値を増やす
- テスト環境ではモックデータを使用する

---

## 📊 テスト結果の確認

### テスト結果の表示

1. **Test Navigator** を開く（左サイドバー、ダイヤモンドアイコン）
2. テスト完了後、各テストメソッドの右側に結果が表示される:
   - ✅ 緑チェック: 成功
   - ❌ 赤バツ: 失敗

### テストレポートの出力

```bash
# コマンドラインからテストを実行してレポート生成
xcodebuild test \
  -project Soramoyou.xcodeproj \
  -scheme Soramoyou \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -resultBundlePath TestResults.xcresult
```

---

## 🎯 テスト実行チェックリスト

- [ ] UIテストファイルをXcodeプロジェクトに追加
- [ ] アクセシビリティ識別子を全てのビューに追加
- [ ] シミュレータまたは実機を選択
- [ ] `AppStoreReviewUITests` を実行
- [ ] `ATTPermissionUITests` を実行
- [ ] 全テストが成功することを確認
- [ ] 失敗したテストがあれば修正

---

## 📚 参考資料

- [Apple公式 - UI Testing](https://developer.apple.com/documentation/xctest/user_interface_tests)
- [Apple公式 - Accessibility Identifiers](https://developer.apple.com/documentation/uikit/uiaccessibilityidentification)
- [XCTest Framework Documentation](https://developer.apple.com/documentation/xctest)
