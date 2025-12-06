# Xcodeで手動で実行する手順

## 現在の状態

✅ **完了済み（自動実行済み）**
- テストファイルの復元完了
  - `Soramoyou/SoramoyouTests/` - 12個のテストファイル
  - `Soramoyou/SoramoyouUITests/` - 1個のUIテストファイル
- ファイルの存在確認完了

⚠️ **Xcodeで手動で実行が必要な作業**

## 手動で実行する手順

### ステップ1: Xcodeでプロジェクトを開く

```bash
open Soramoyou/Soramoyou.xcodeproj
```

### ステップ2: SoramoyouTestsターゲットを作成

1. **プロジェクトナビゲーターでプロジェクトを選択**
   - 一番上の青いアイコン（プロジェクト名）をクリック

2. **ターゲットを追加**
   - プロジェクト設定の下部にある"TARGETS"セクションで"+"ボタンをクリック

3. **Unit Testing Bundleを選択**
   - "iOS"タブを選択
   - "Unit Testing Bundle"を選択
   - "Next"をクリック

4. **ターゲット情報を入力**
   - **Product Name**: `SoramoyouTests`
   - **Team**: メインターゲットと同じチームを選択（`B7F79FDM78`）
   - **Target to be Tested**: `Soramoyou`を選択
   - **Language**: `Swift`
   - "Finish"をクリック

### ステップ3: SoramoyouUITestsターゲットを作成

1. **再度ターゲットを追加**
   - "TARGETS"セクションで"+"ボタンをクリック

2. **UI Testing Bundleを選択**
   - "iOS"タブを選択
   - "UI Testing Bundle"を選択
   - "Next"をクリック

3. **ターゲット情報を入力**
   - **Product Name**: `SoramoyouUITests`
   - **Team**: メインターゲットと同じチームを選択（`B7F79FDM78`）
   - **Target to be Tested**: `Soramoyou`を選択
   - **Language**: `Swift`
   - "Finish"をクリック

### ステップ4: テストファイルを追加

#### SoramoyouTestsターゲットにファイルを追加

1. **プロジェクトナビゲーターで`SoramoyouTests`グループを右クリック**
   - または、プロジェクトルートの`SoramoyouTests`フォルダを右クリック
   - "Add Files to Soramoyou..."を選択

2. **テストファイルを選択**
   - `Soramoyou/SoramoyouTests/`フォルダを選択
   - 以下のオプションを設定:
     - ❌ "Copy items if needed"のチェックを**外す**（既に同じディレクトリにあるため）
     - ✅ "Create groups"を選択
     - ✅ "Add to targets: SoramoyouTests"にチェックを入れる
   - "Finish"をクリック

3. **追加されたファイルを確認**
   - プロジェクトナビゲーターで`SoramoyouTests`グループを展開
   - 以下の12個のファイルが表示されることを確認:
     - AdServiceTests.swift
     - AuthServiceTests.swift
     - AuthViewModelTests.swift
     - EditViewModelTests.swift
     - FirestoreServiceTests.swift
     - HomeViewModelTests.swift
     - ImageServiceTests.swift
     - IntegrationTests.swift
     - ProfileViewModelTests.swift
     - SearchViewModelTests.swift
     - StorageServiceTests.swift
     - UserModelTests.swift

#### SoramoyouUITestsターゲットにファイルを追加

1. **プロジェクトナビゲーターで`SoramoyouUITests`グループを右クリック**
   - または、プロジェクトルートの`SoramoyouUITests`フォルダを右クリック
   - "Add Files to Soramoyou..."を選択

2. **UIテストファイルを選択**
   - `Soramoyou/SoramoyouUITests/SoramoyouUITests.swift`を選択
   - 以下のオプションを設定:
     - ❌ "Copy items if needed"のチェックを**外す**（既に同じディレクトリにあるため）
     - ✅ "Create groups"を選択
     - ✅ "Add to targets: SoramoyouUITests"にチェックを入れる
   - "Finish"をクリック

### ステップ5: テストターゲットに依存関係を追加

#### SoramoyouTestsターゲット

1. **SoramoyouTestsターゲットを選択**
   - プロジェクト設定で"SoramoyouTests"ターゲットを選択

2. **Generalタブ > Frameworks, Libraries, and Embedded Content**
   - "+"ボタンをクリック
   - メインターゲットと同じパッケージ依存関係を追加（既に追加されている場合はスキップ）:
     - FirebaseAuth
     - FirebaseFirestore
     - FirebaseStorage
     - FirebaseCrashlytics
     - FirebaseAnalytics
     - Kingfisher
     - GoogleMobileAds

3. **Build Phasesタブ > Dependencies**
   - "+"ボタンをクリック
   - `Soramoyou`ターゲットを追加（テスト対象のアプリ）

#### SoramoyouUITestsターゲット

1. **SoramoyouUITestsターゲットを選択**
   - プロジェクト設定で"SoramoyouUITests"ターゲットを選択

2. **Build Phasesタブ > Dependencies**
   - "+"ボタンをクリック
   - `Soramoyou`ターゲットを追加（テスト対象のアプリ）

### ステップ6: テストの実行（確認）

1. **テストスキームを選択**
   - Xcodeの上部でスキームを`Soramoyou`から`SoramoyouTests`に変更

2. **テストを実行**
   - `Cmd + U`でテストを実行
   - または、テストナビゲーター（`Cmd + 6`）から個別のテストを実行

## 完了チェックリスト

- [ ] SoramoyouTestsターゲットが作成されている
- [ ] SoramoyouUITestsターゲットが作成されている
- [ ] SoramoyouTestsに12個のテストファイルが追加されている
- [ ] SoramoyouUITestsに1個のUIテストファイルが追加されている
- [ ] テストターゲットに依存関係が追加されている
- [ ] テストが正常に実行できる

## トラブルシューティング

### テストファイルが見つからない場合

テストファイルは以下の場所に存在します：
- `Soramoyou/SoramoyouTests/` - 12個のファイル
- `Soramoyou/SoramoyouUITests/SoramoyouUITests.swift` - 1個のファイル

Xcodeでファイルを追加する際は、これらのパスを指定してください。

### ビルドエラーが発生する場合

1. **依存関係の確認**
   - テストターゲットに必要なパッケージが追加されているか確認
   - メインターゲットと同じパッケージ依存関係を追加

2. **ターゲットの依存関係を確認**
   - Build Phases > Dependenciesに`Soramoyou`ターゲットが追加されているか確認

### テストが実行されない場合

1. **テストスキームを確認**
   - Product > Scheme > Edit Scheme
   - Test > Info > テストターゲットが選択されているか確認

2. **テストナビゲーターを確認**
   - `Cmd + 6`でテストナビゲーターを開く
   - テストが表示されているか確認

