# Claude への指示書

## 🎯 基本指示（最優先）

**あなた（Claude）は以下を必ず守ってください：**

- ✅ **全ての回答を日本語で行う**
- ✅ **mainブランチに直接コミット・変更は絶対禁止**
- ✅ **作業前に必ずブランチを作成する**
- ✅ **コミット前に必ず動作確認・テストを行う**
- ✅ **エラーがある状態ではコミットしない**

---

## 📱 現在のプロジェクト情報

### プロジェクト基本情報
```yaml
プロジェクト名: そらもよう - 空を撮る、空を集める
アプリ概要: 空の写真を投稿・編集・共有するSNSアプリ
リポジトリ名: [GitHubリポジトリ名を記入]
GitHubユーザー名: [ユーザー名を記入]
開発フェーズ: Phase 1 (MVP)
```

### 技術スタック
```yaml
プラットフォーム: iOS
メイン言語: Swift
UIフレームワーク: SwiftUI
バックエンド: Firebase (Authentication, Firestore, Storage)
開発ツール: Xcode, Cursor, CC-SSD
収益モデル: AdMob広告（バナー広告）
```

### 使用ライブラリ・SDK
```yaml
Firebase:
  - Firebase Authentication
  - Cloud Firestore
  - Firebase Storage
  - Google Mobile Ads SDK (AdMob)

iOSフレームワーク:
  - SwiftUI
  - Core Image / CIFilter (画像編集)
  - Photos (カメラロール保存)
  - CoreLocation (位置情報)
  - MapKit (地図表示)

その他:
  - Kingfisher or SDWebImageSwiftUI (画像キャッシュ)
```

### MCP GitHub API 設定
```yaml
対象リポジトリ: [上記のリポジトリ名]
デフォルトブランチ: main
```

---

## 🚀 作業フロー（必ず順守）

### 1️⃣ 作業開始時
```bash
# 必ずブランチを作成
git checkout -b [ブランチ名]
```

**ブランチ命名規則:**
- `機能-[機能名]` 例: 機能-カメラフィルター追加
- `修正-[修正内容]` 例: 修正-起動時クラッシュ
- `改善-[改善内容]` 例: 改善-UI表示速度向上
- `ドキュメント-[内容]` 例: ドキュメント-README更新

### 2️⃣ 実装中
1. コードを実装
2. **必ず動作確認・テストを実施**
3. 他の機能への影響を確認
4. エラーがないことを確認

### 3️⃣ 作業完了時
```bash
# 1. コミット（日本語メッセージ）
git add .
git commit -m "機能: [詳細な説明]"

# 2. リモートにプッシュ
git push -u origin [ブランチ名]

# 3. PR作成（MCP GitHub APIを使用）
```

**コミットメッセージの例:**
```
機能: 空の写真にフィルター機能を追加
修正: アルバム画面でのクラッシュを解消
改善: Firebase読み込み速度を最適化
ドキュメント: セットアップ手順を追加
```

---

## 💻 コーディング規約

### Swift/SwiftUI 命名規則
- **変数・関数**: `camelCase` (例: `skyPhotoList`, `getUserProfile`, `saveSkyPhoto`)
- **クラス・構造体**: `PascalCase` (例: `SkyPhotoView`, `AlbumScreen`, `EditToolModel`)
- **列挙型**: `PascalCase` (例: `SkyType`, `TimeOfDay`, `Visibility`)
- **定数**: `UPPER_SNAKE_CASE` (例: `MAX_PHOTO_SIZE`, `MAX_IMAGES_COUNT`)
- **プロトコル**: `PascalCase` + 形容詞または名詞 (例: `Editable`, `PhotoStorageProtocol`)

### SwiftUIビュー構造
```swift
// ✅ Good: 明確な構造と日本語コメント
struct SkyPhotoListView: View {
    // MARK: - Properties
    @StateObject private var viewModel: SkyPhotoViewModel
    
    // MARK: - Body
    var body: some View {
        // UI実装
    }
    
    // MARK: - Private Methods
    /// 写真を読み込む
    private func loadPhotos() {
        // 実装
    }
}
```

### Firebase実装規約
```swift
// ✅ Good: エラーハンドリングと日本語コメント
/// Firestoreから投稿を取得する
/// - Parameter userId: ユーザーID
/// - Returns: 投稿の配列
func fetchPosts(for userId: String) async throws -> [Post] {
    do {
        let snapshot = try await db.collection("posts")
            .whereField("userId", isEqualTo: userId)
            .order(by: "createdAt", descending: true)
            .getDocuments()
        
        return snapshot.documents.compactMap { doc in
            try? doc.data(as: Post.self)
        }
    } catch {
        // エラーログ出力
        print("❌ 投稿取得エラー: \(error.localizedDescription)")
        throw error
    }
}
```

### 画像処理実装規約
```swift
// ✅ Good: Core Imageを使った画像編集
/// 画像にフィルターを適用する
/// - Parameters:
///   - image: 元画像
///   - filterName: フィルター名
/// - Returns: 編集後の画像
func applyFilter(to image: UIImage, filterName: String) -> UIImage? {
    guard let ciImage = CIImage(image: image) else { return nil }
    
    // フィルター適用処理
    let filter = CIFilter(name: filterName)
    filter?.setValue(ciImage, forKey: kCIInputImageKey)
    
    // 結果を取得
    guard let outputImage = filter?.outputImage else { return nil }
    
    let context = CIContext()
    guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
        return nil
    }
    
    return UIImage(cgImage: cgImage)
}
```

### コメント規則
**必ず詳細な日本語コメントを記述する**

#### Swift の場合
```swift
/// ユーザーが撮影した空の写真を保存する
/// - Parameter image: 保存する画像データ
/// - Returns: 保存成功時はtrue
func saveSkyPhoto(image: UIImage) -> Bool {
    // Firebaseに画像をアップロード
    // エラーハンドリングを実装
}
```

#### JavaScript/TypeScript の場合
```javascript
/**
 * 空の写真一覧を取得する
 * @returns {Promise<Array>} 写真データの配列
 */
const fetchSkyPhotos = async () => {
  // Firestoreから取得
  // キャッシュ処理を含む
}
```

---

## 🧪 テスト・動作確認（コミット前必須）

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

## 🌐 ポート設定（Web開発時）

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

## 📝 PR作成時のガイドライン

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

## 🔥 Firebase使用時の重要事項

### セキュリティ
- ✅ APIキーは**必ず環境変数**で管理（`.env`ファイル）
- ✅ `.env`ファイルは`.gitignore`に追加
- ✅ Firestoreのセキュリティルールを適切に設定
- ✅ 認証状態を常に確認してからデータアクセス

### パフォーマンス
- ✅ 不要なリアルタイムリスナーは必ず削除
- ✅ クエリは必要最小限に（limitを活用）
- ✅ 画像は適切なサイズに圧縮してからアップロード

---

## 📂 .gitignore 管理

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


**新規ファイル作成時**: GitHubに上げるべきでないファイルは必ず`.gitignore`に追加

---

## ⚠️ 修正時の注意事項

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

## 🎨 UI/UX開発時の考慮事項

### iOS (Swift/SwiftUI)
- ✅ システムカラーを優先的に使用
- ✅ ダークモード対応
- ✅ アクセシビリティ対応
- ✅ Apple Human Interface Guidelines に準拠

### React Native
- ✅ レスポンシブデザイン
- ✅ プラットフォーム固有UIパターンの尊重
- ✅ パフォーマンス最適化
- ✅ iOS/Android両方での動作確認

---

## 🗄️ データベース設計（Firestore）

### users コレクション
```json
{
  "userId": "string (ドキュメントID)",
  "email": "string",
  "displayName": "string",
  "photoURL": "string",
  "bio": "string",
  "createdAt": "timestamp",
  "updatedAt": "timestamp",
  "followersCount": "number",
  "followingCount": "number",
  "postsCount": "number",
  "customEditTools": ["string"],      // 選択した編集ツール名
  "customEditToolsOrder": ["string"]  // 表示順
}
```

### posts コレクション
```json
{
  "postId": "string (ドキュメントID)",
  "userId": "string",
  "images": [
    {
      "url": "string",
      "thumbnail": "string",
      "width": "number",
      "height": "number",
      "order": "number"
    }
  ],
  "caption": "string",
  "hashtags": ["string"],
  "location": {
    "latitude": "number",
    "longitude": "number",
    "city": "string",
    "prefecture": "string",
    "landmark": "string"
  },
  "skyColors": ["string"],           // 16進数カラーコード（最大5色）
  "capturedAt": "timestamp",
  "timeOfDay": "string",             // morning, afternoon, evening, night
  "skyType": "string",               // clear, cloudy, sunset, sunrise, storm
  "colorTemperature": "number",      // K表示
  "visibility": "string",            // public, followers, private
  "likesCount": "number",
  "commentsCount": "number",
  "createdAt": "timestamp",
  "updatedAt": "timestamp"
}
```

### drafts コレクション
```json
{
  "draftId": "string (ドキュメントID)",
  "userId": "string",
  "images": [/* posts と同じ構造 */],
  "editedImages": ["string"],
  "editSettings": {
    "brightness": "number",
    "contrast": "number",
    "saturation": "number"
    // その他の編集パラメータ
  },
  "caption": "string",
  "hashtags": ["string"],
  "location": {/* posts と同じ構造 */},
  "visibility": "string",
  "createdAt": "timestamp",
  "updatedAt": "timestamp"
}
```

### follows コレクション（Phase 2）
```json
{
  "followId": "string (ドキュメントID)",
  "followerId": "string",
  "followingId": "string",
  "createdAt": "timestamp"
}
```

---

## 🎨 「そらもよう」特有の機能仕様

### 📸 投稿枚数制限
- **未ログインユーザー**: 1投稿あたり最大3枚
- **ログイン済みユーザー**: 1投稿あたり最大10枚

### 🖼️ 画像仕様
```yaml
最大解像度: 2048×2048ピクセル
ファイルサイズ: 5MB以下
フォーマット: JPEG（圧縮率80-90%）
サムネイル: 自動生成（表示高速化）
```

### 🎨 フィルター（10種類）
1. ナチュラル (Natural)
2. クリア (Clear)
3. ドラマ (Drama)
4. ソフト (Soft)
5. ウォーム (Warm)
6. クール (Cool)
7. ビンテージ (Vintage)
8. モノクロ (Monochrome)
9. パステル (Pastel)
10. ヴィヴィッド (Vivid)

### 🛠️ 基本編集ツール（27種類）
```
1. 露出             10. 自然な彩度      19. かすみの除去
2. 明るさ           11. 暖かみ          20. グレイン
3. コントラスト     12. 色合い          21. フェード
4. トーン           13. シャープネス    22. ノイズリダクション
5. ブリリアンス     14. ビネット        23. カーブ調整
6. ハイライト       15. 色温度          24. HSL調整
7. シャドウ         16. ホワイトバランス 25. レンズ補正
8. ブラックポイント 17. テクスチャ      26. 二重露光風合成
9. 彩度             18. クラリティ      27. トリミング・回転
```

### 🎒 装備システム
- ユーザーは27種類から **5〜8個** を選択
- 選択したツールのみが編集画面に表示
- 表示順を自由にカスタマイズ可能（ドラッグ&ドロップ）
- 装備情報は `users` コレクションの `customEditTools` に保存

### 🔍 検索機能
```yaml
検索方法:
  - ハッシュタグ検索
  - 色で検索（抽出された色から）
  - 時間帯で検索（morning / afternoon / evening / night）
  - 空の種類で検索（clear / cloudy / sunset / sunrise / storm）
```

### 📍 位置情報
- 市区町村レベルで表示
- 地図から目標物（ランドマーク）を選択可能
- CoreLocation + MapKit 使用

### 🎨 自動抽出情報
- **撮影時刻**: EXIF情報から取得
- **時間帯判定**: morning / afternoon / evening / night
- **空の色分析**: 主要な色を最大5色抽出（16進数カラーコード）
- **色温度**: K（ケルビン）表示

### 📱 AdMob広告
- バナー広告を画面下部に固定表示
- Google Mobile Ads SDK 使用

---

## 📱 画面構成

### タブバー（下部固定）
1. **ホーム**（フィード）
2. **検索**
3. **投稿**（中央、目立つデザイン）
4. **通知**（Phase 2実装予定）
5. **プロフィール**

### Phase 1 実装画面一覧
#### 認証関連
- スプラッシュ画面
- ウェルカム画面
- ログイン画面
- 新規登録画面

#### メイン機能
- ホーム画面（フィード）
- 投稿詳細画面
- 写真選択画面
- 編集画面
- 投稿情報入力画面
- 検索画面
- 検索結果一覧画面
- プロフィール画面（自分）
- プロフィール編集画面
- 他ユーザーのプロフィール画面
- 設定画面
- 編集装備設定画面
- 下書き一覧画面

### 主要な画面遷移
```
【初回起動】
スプラッシュ → ウェルカム → ログイン/新規登録 → ホーム

【投稿の流れ】
タブ「投稿」→ 写真選択 → 編集 → 投稿情報入力 → 完了 → ホーム

【閲覧の流れ】
ホーム → 投稿詳細 → ユーザープロフィール

【設定の流れ】
タブ「プロフィール」→ 設定 → 各種設定画面
```

---

## 🎨 デザインガイドライン

### カラーパレット
```yaml
プライマリカラー: 空をイメージした青系
セカンダリカラー: 夕焼けをイメージしたオレンジ系
アクセントカラー: 柔らかいピンク系
背景色: 白 or 淡いグレー
テキスト: ダークグレー
```

### フォント
```yaml
見出し: SF Pro Display (Bold)
本文: SF Pro Text (Regular)
日本語: ヒラギノ角ゴシック or 游ゴシック
```

### デザイン方針
- ✅ シンプル＆おしゃれ
- ✅ 写真が主役
- ✅ 余白を活かしたデザイン
- ✅ 直感的な操作性

---

## 📋 Info.plist 必要な権限

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

## 🚀 開発ロードマップ（Phase 1）

### Step 1: 環境構築
- [ ] Firebaseプロジェクト作成
- [ ] Xcodeプロジェクト作成
- [ ] Firebase SDK導入（CocoaPods or SPM）
- [ ] AdMob SDK導入

### Step 2: 認証機能実装
- [ ] Firebase Authentication設定
- [ ] ログイン/新規登録画面作成
- [ ] 認証状態管理

### Step 3: プロフィール機能実装
- [ ] Firestoreユーザー情報保存
- [ ] プロフィール画面作成
- [ ] プロフィール編集機能

### Step 4: 投稿機能実装（最重要）
- [ ] 写真選択機能
- [ ] 編集機能（フィルター＋基本ツール）
- [ ] 装備システム
- [ ] 投稿情報入力
- [ ] Firestore/Storage保存
- [ ] 色分析・EXIF読み取り

### Step 5: フィード機能実装
- [ ] 投稿一覧表示
- [ ] 投稿詳細表示
- [ ] ページネーション

### Step 6: 検索機能実装
- [ ] 検索UI作成
- [ ] Firestoreクエリ実装

### Step 7: 広告実装
- [ ] AdMobバナー広告表示

### Step 8: テスト＆デバッグ
- [ ] 各機能の動作確認
- [ ] バグ修正
- [ ] パフォーマンス最適化

### Step 9: App Store申請準備
- [ ] アプリアイコン作成
- [ ] スクリーンショット作成
- [ ] App Store説明文作成
- [ ] プライバシーポリシー作成

---

## ⚠️ 「そらもよう」特有の注意事項

### セキュリティ
- ✅ Firebase Security Rulesの設定（ユーザーは自分のデータのみ編集可能）
- ✅ 画像のアクセス制御（公開設定に応じた表示制限）
- ✅ 投稿の公開設定（public / followers / private）

### パフォーマンス
- ✅ 画像の遅延読み込み（LazyLoad）
- ✅ サムネイル生成で通信量削減
- ✅ Firestoreクエリの最適化
- ✅ 画像圧縮（JPEG 80-90%、最大5MB）
- ✅ ページネーション実装（無限スクロール）

### 画像処理
- ✅ Core ImageフレームワークまたはCIFilterを使用
- ✅ リアルタイムプレビュー
- ✅ 編集パラメータの保存（下書き機能用）
- ✅ EXIF情報の読み取り
- ✅ 色分析アルゴリズムの実装

### ユーザビリティ
- ✅ ローディング表示
- ✅ エラーハンドリング
- ✅ オフライン対応（可能な範囲で）
- ✅ 未ログインユーザーの閲覧制限（写真3枚まで）

---

## 🔮 Phase 2以降の実装予定

### Phase 2（拡張機能）
- フォロー/フォロワー機能
- フォロワー限定投稿の閲覧
- いいね機能
- コメント機能
- 通知機能
- マップビュー（地図上に投稿をピン表示）

### Phase 3（カメラ機能）
- アプリ内カメラ
- 撮影補助機能
  - グリッド表示
  - 水平線ガイド
  - 露出ロック
  - フォーカスロック

---

### 開発スタイル
- ✅ AI支援ツールを積極的に活用
- ✅ ビジュアル開発ツールを好む
- ✅ **ステップバイステップで進めることを好む**
- ✅ **詳細な説明と具体例を求める**
- ✅ コメントで理解を深めることを重視

### 過去のプロジェクト
1. **AI-compass**: AIツール発見アプリ
2. **ことばのたまご**: 英語学習 × MBTI × キャラクター育成
3. **ParkPedia**: React Native + Firebase + Expo

### コミュニケーション
- ✅ 不明点は遠慮なく質問してくる
- ✅ 複数の選択肢を提示すると判断しやすい
- ✅ メリット・デメリットの説明を求める
- ✅ 実装前の詳細な相談を好む

---

## 🤝 Claude（あなた）の対応方針

### 回答スタイル
1. **段階的に説明**
   - 一度に全てを説明しない
   - ステップごとに確認

2. **具体例を豊富に**
   - コード例を必ず提示
   - 実際の使用例を示す

3. **選択肢の提示**
   - 複数のアプローチを提案
   - それぞれのメリット・デメリットを説明

4. **確認を怠らない**
   - 不明点があれば質問
   - 前提を確認してから実装

### 実装時の姿勢
- ✅ 慎重に影響範囲を確認
- ✅ 既存の動作を壊さない
- ✅ わからないことは質問
- ✅ テストを必ず実施

---

## 🎯 Issue作成時のガイドライン

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

## 🔍 デバッグ・トラブルシューティング

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

## 📋 チェックリスト（作業完了前）

### 最終確認
- [ ] 全ての機能が正常に動作する
- [ ] 既存機能に影響がない
- [ ] エラー・警告が表示されない
- [ ] コードに適切なコメントがある
- [ ] 不要なコンソールログを削除した
- [ ] `.gitignore`に必要なファイルを追加した
- [ ] コミットメッセージが適切
- [ ] PRの説明が十分

---

## 🎓 追加の参考情報

### 開発時の心構え
- 小さく分けて進める
- こまめにコミット
- 動作確認を怠らない
- わからないことは質問する

### Claude（あなた）へのお願い
- 丁寧な説明を心がける
- 専門用語は噛み砕いて説明
- 複数の選択肢を提示
- ユーザーの判断を尊重

---

**この指示書は、各プロジェクトの開始時に「現在のプロジェクト情報」セクションを更新して使用してください。**
