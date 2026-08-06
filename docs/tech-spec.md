# 技術仕様 ⭐️

## プロジェクト基本情報
```yaml
プロジェクト名: そらもよう - 空を撮る、空を集める
アプリ概要: 空の写真を投稿・編集・共有するSNSアプリ
開発フェーズ: Phase 1 (MVP)
```

## 非自明な依存（コードからは読み取れない事情）

- **opencv-spm 5.0.0**（広角合成 cv::Stitcher）: ObjC++ ブリッジ + Bridging Header 経由で利用し、`SORAMOYOU_OPENCV` フラグで条件コンパイルする。静的リンクのため実出荷サイズは IPA +約1.7MB。

## コーディング規約

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

        // ⚠️ compactMap { try? ... } は壊れたドキュメントを無言で落とすため禁止。
        //    ① 失敗したドキュメントのパスをログに残す、② 方針次第で throw するか
        //    スキップするかを明示する、の 2 点を徹底する。
        return snapshot.documents.compactMap { doc in
            do {
                return try doc.data(as: Post.self)
            } catch {
                // 個別ドキュメントのデコード失敗：運用フェーズで発覚した壊れたデータを
                // 検知できるよう必ずログに残し、クラッシュはさせず 1 件だけスキップする。
                print("❌ 投稿デコード失敗 path=\(doc.reference.path) error=\(error.localizedDescription)")
                return nil
            }
        }
    } catch {
        // クエリ全体の失敗（ネットワーク・権限など）は呼び出し側に伝播する。
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
