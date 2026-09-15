// ⭐️ ImageService.swift
// 画像処理サービス
// FilterGraphBuilder を経由した編集レシピ適用 + 高速プレビュー生成
//
//  ImageService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//
// 🔧 2026-04-24 大規模リファクタ (コードレビュー H1 / M1 対応):
//   - applyEditTool / processEditTool および 27 個の applyXxx 独自実装を全削除。
//     FilterGraphBuilder と係数が乖離していて、テストは通るのにプレビューと結果が一致しない
//     構造的な不具合の温床になっていた。プレビューと最終書き出しが同じ経路を通るよう
//     FilterGraphBuilder 1 本に統一した。
//   - EditSettings ベースの applyEditSettings / generatePreview(_:edits:) / generatePreviewFast /
//     generatePreviewFromCIImage(_:edits:) も削除。EditRecipe 経路に一本化 (M1)。
//     toneCurvePoints / targetDynamicRange 脱落の再発を防ぐ。
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Metal
import UIKit
import Vision

protocol ImageServiceProtocol {
    // Filter
    func applyFilter(_ filter: FilterType, to image: UIImage) async throws -> UIImage

    /// EditRecipe 直接受け取り版（toneCurvePoints 等の EditSettings にない情報を脱落させない）
    /// - Parameter skyMask: ワンタップ空補正用の空マスク（`nil`＝空補正なし）
    func generatePreview(_ image: UIImage, recipe: EditRecipe, skyMask: CIImage?) async throws -> UIImage
    /// - Parameter skyMask: ワンタップ空補正用の空マスク（`nil`＝空補正なし）
    func generatePreviewFromCIImage(_ ciImage: CIImage, recipe: EditRecipe, skyMask: CIImage?) -> UIImage?
    /// EditRecipe を UIImage に適用（フル解像度・最終書き出し用）
    /// - Parameter skyMask: ワンタップ空補正用の空マスク（`nil`＝空補正なし）
    func applyEditRecipe(_ recipe: EditRecipe, to image: UIImage, skyMask: CIImage?) async throws -> UIImage

    /// CIImageをリサイズ（CIFilter.lanczosScaleTransformを使用）
    func resizeCIImage(_ ciImage: CIImage, maxSize: CGSize) -> CIImage

    // Compression & Resize
    func resizeImage(_ image: UIImage, maxSize: CGSize) async throws -> UIImage
    func compressImage(_ image: UIImage, quality: CGFloat) async throws -> Data

    // Analysis
    func extractColors(_ image: UIImage, maxCount: Int) async throws -> [String]
    func calculateColorTemperature(_ image: UIImage) async throws -> Int
    /// 主要色を解析用 CIImage から抽出する。`skyMask` があれば空の部分から、nil なら画像全体から（従来と同じ値）。
    /// - Parameters:
    ///   - ciImage: 向きを焼き込み済み・origin (0,0)・長辺 512 以下に縮小済みの解析用画像（この関数は縮小しない）
    ///   - skyMask: 空マスク（1=空）。extent は `ciImage` と一致させる
    func extractColors(from ciImage: CIImage, maxCount: Int, skyMask: CIImage?) async throws -> [String]
    /// 色温度を解析用 CIImage から計算する。`skyMask` があれば空の部分の加重平均から、nil なら画像全体から（従来と同じ値）。
    func calculateColorTemperature(from ciImage: CIImage, skyMask: CIImage?) async throws -> Int
    func detectSkyType(_ image: UIImage) async throws -> SkyType
    /// 元ファイルの URL から EXIF を読む（同期）。UIImage 版は再エンコードで EXIF が消えるため廃止。
    /// 同期なのは `NSItemProvider.loadFileRepresentation` の一時 URL が completion 内でしか有効でないため。
    func extractEXIFData(fileURL: URL) throws -> EXIFData
}

// MARK: - skyMask 省略用の互換オーバーロード

/// ワンタップ空補正機能導入前からの呼び出し元（Style2DPadView・各種テスト等）が
/// `skyMask` を意識せずに呼べるよう、省略版のオーバーロードをプロトコル拡張で提供する。
/// プロトコルの method requirement 自体にはデフォルト引数を書けない（Swift の制約）ため、
/// この形で後方互換を確保する。
extension ImageServiceProtocol {
    func generatePreview(_ image: UIImage, recipe: EditRecipe) async throws -> UIImage {
        try await generatePreview(image, recipe: recipe, skyMask: nil)
    }

    func generatePreviewFromCIImage(_ ciImage: CIImage, recipe: EditRecipe) -> UIImage? {
        generatePreviewFromCIImage(ciImage, recipe: recipe, skyMask: nil)
    }

    func applyEditRecipe(_ recipe: EditRecipe, to image: UIImage) async throws -> UIImage {
        try await applyEditRecipe(recipe, to: image, skyMask: nil)
    }
}

/// 🔧 2026-04-24 修正: final を付与して `@Sendable` クロージャ (Task.detached) での
/// self キャプチャを Swift 6 Strict Concurrency 下でも許容するようにする。
/// `context` は既に `let` 宣言なので、final + let で自動的に Sendable 候補になる。
final class ImageService: ImageServiceProtocol {
    /// 共有 CIContext（CIContextPool シングルトンから取得）
    /// 【修正】以前は各メソッドで毎回 CIContext を生成していたが、
    ///         CIContextPool.shared.ciContext を使用することで再利用するよう変更。
    ///         色空間も linear sRGB → Display P3 に改善。
    private let context: CIContext

    init(context: CIContext? = nil) {
        if let context {
            // テスト時など外部からの注入を許容
            self.context = context
        } else {
            // CIContextPool のシングルトンを使用（Metal + 適切な色空間設定済み）
            self.context = CIContextPool.shared.ciContext
        }
    }

    // MARK: - Filter

    func applyFilter(_ filter: FilterType, to image: UIImage) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    guard let ciImage = CIImage(image: image) else {
                        throw ImageServiceError.invalidImage
                    }

                    let filteredImage = try await self.processFilter(filter, on: ciImage)

                    guard let cgImage = self.context.createCGImage(filteredImage, from: filteredImage.extent) else {
                        throw ImageServiceError.processingFailed
                    }

                    let result = UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func processFilter(_ filter: FilterType, on ciImage: CIImage) async throws -> CIImage {
        switch filter {
        case .natural:
            ciImage
        case .clear:
            applyClearFilter(to: ciImage)
        case .drama:
            applyDramaFilter(to: ciImage)
        case .soft:
            applySoftFilter(to: ciImage)
        case .warm:
            applyWarmFilter(to: ciImage)
        case .cool:
            applyCoolFilter(to: ciImage)
        case .vintage:
            applyVintageFilter(to: ciImage)
        case .monochrome:
            applyMonochromeFilter(to: ciImage)
        case .pastel:
            applyPastelFilter(to: ciImage)
        case .vivid:
            applyVividFilter(to: ciImage)
        }
    }

    // MARK: - Filter Implementations

    private func applyClearFilter(to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = 1.1
        filter.contrast = 1.05
        return filter.outputImage ?? image
    }

    private func applyDramaFilter(to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.contrast = 1.3
        filter.saturation = 1.2
        return filter.outputImage ?? image
    }

    private func applySoftFilter(to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = 0.8
        filter.contrast = 0.9
        return filter.outputImage ?? image
    }

    private func applyWarmFilter(to image: CIImage) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: 5500, y: 0)
        return filter.outputImage ?? image
    }

    private func applyCoolFilter(to image: CIImage) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: 7500, y: 0)
        return filter.outputImage ?? image
    }

    private func applyVintageFilter(to image: CIImage) -> CIImage {
        var result = image

        let sepiaFilter = CIFilter.sepiaTone()
        sepiaFilter.inputImage = result
        sepiaFilter.intensity = 0.5
        result = sepiaFilter.outputImage ?? result

        let vignetteFilter = CIFilter.vignette()
        vignetteFilter.inputImage = result
        vignetteFilter.intensity = 0.5
        vignetteFilter.radius = 1.0
        result = vignetteFilter.outputImage ?? result

        return result
    }

    private func applyMonochromeFilter(to image: CIImage) -> CIImage {
        let filter = CIFilter.colorMonochrome()
        filter.inputImage = image
        filter.color = CIColor.white
        filter.intensity = 1.0
        return filter.outputImage ?? image
    }

    private func applyPastelFilter(to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = 0.6
        filter.brightness = 0.1
        filter.contrast = 0.9
        return filter.outputImage ?? image
    }

    private func applyVividFilter(to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = 1.5
        filter.contrast = 1.2
        return filter.outputImage ?? image
    }

    // MARK: - EditRecipe 直接パス（toneCurvePoints 等を保全）

    //
    // 🔧 2026-04-24 H1 削除:
    // 旧 applyEditTool / processEditTool / 27 個の applyXxx 独自実装は FilterGraphBuilder と
    // 係数が乖離しておりプレビュー挙動とテストが一致しない温床だったため削除。
    // 全ツールの正規実装は `FilterGraphBuilder.buildGraph` に集約済み。
    //
    // 🔧 2026-04-24 M1 削除:
    // applyEditSettings / generatePreview(_:edits:) / generatePreviewFast / generatePreviewFromCIImage(_:edits:)
    // も削除。EditRecipe 経路に一本化することで toneCurvePoints / targetDynamicRange 脱落の
    // 再発を防ぐ。

    /// EditRecipe を直接受け取ってプレビューを生成。
    /// `EditSettings` への往復では `toneCurvePoints` / `targetDynamicRange` が脱落するため、
    /// トーンカーブ編集時は必ずこちらを呼ぶ。
    /// - Parameter skyMask: ワンタップ空補正用の空マスク（`nil`＝空補正なし）
    func generatePreview(_ image: UIImage, recipe: EditRecipe, skyMask: CIImage?) async throws -> UIImage {
        // 🔧 2026-05-25 修正: 旧実装は 750×750 へ固定縮小していたため、編集画面に入った
        //   瞬間からプレビューがアップスケールでぼやけていた。高解像度パス（2400px）の
        //   PreviewRenderer.renderPreview が用意済みなのに未配線だったため、ここで配線する。
        //   applyEditRecipe と同じくキャンセル伝搬付きの detached 実行にして、ドラッグ中に
        //   古い計算が GPU/CPU を占有し続けないようにする。
        try Task.checkCancellation()

        let workTask = Task.detached(priority: .userInitiated) { () throws -> UIImage in
            try Task.checkCancellation()
            return try PreviewRenderer.renderPreview(from: image, recipe: recipe, skyMask: skyMask)
        }

        return try await withTaskCancellationHandler {
            try await workTask.value
        } onCancel: {
            workTask.cancel()
        }
    }

    /// 低解像度 CIImage + EditRecipe から同期的にプレビュー生成（リアルタイム用）
    /// - Parameter skyMask: ワンタップ空補正用の空マスク（`nil`＝空補正なし）
    func generatePreviewFromCIImage(_ ciImage: CIImage, recipe: EditRecipe, skyMask: CIImage?) -> UIImage? {
        let result = FilterGraphBuilder.buildGraph(recipe: recipe, source: ciImage, quality: .interactive, skyMask: skyMask)
        // colorSpace を明示して Display P3 タグを確実に付与する（省略すると iOS 差異で色がくすむ恐れ）
        guard let cgImage = context.createCGImage(
            result,
            from: result.extent,
            format: CIFormat.BGRA8,
            colorSpace: CIContextPool.shared.outputColorSpace
        ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// EditRecipe を UIImage に直接適用（フル解像度）
    ///
    /// 🔧 2026-04-24 修正 (コードレビュー M7):
    /// 旧実装は Task.detached 内で実行していたためキャンセルが伝搬せず、ユーザーが指を
    /// 高速に動かしている間に古い計算が GPU / CPU を占有していた。
    /// withTaskCancellationHandler + Task.checkCancellation で
    /// 親 Task のキャンセルを detached task にも伝搬させる。
    /// - Parameter skyMask: ワンタップ空補正用の空マスク（`nil`＝空補正なし）
    func applyEditRecipe(_ recipe: EditRecipe, to image: UIImage, skyMask: CIImage?) async throws -> UIImage {
        try Task.checkCancellation()

        let workTask = Task.detached(priority: .userInitiated) { () throws -> UIImage in
            guard let ciImage = CIImage(image: image) else {
                throw ImageServiceError.invalidImage
            }
            try Task.checkCancellation()
            let result = FilterGraphBuilder.buildGraph(recipe: recipe, source: ciImage, skyMask: skyMask)
            try Task.checkCancellation()
            // colorSpace を明示して Display P3 タグを確実に付与する（省略すると iOS 差異で色がくすむ恐れ）
            guard let cgImage = self.context.createCGImage(
                result,
                from: result.extent,
                format: CIFormat.BGRA8,
                colorSpace: CIContextPool.shared.outputColorSpace
            ) else {
                throw ImageServiceError.processingFailed
            }
            return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
        }

        return try await withTaskCancellationHandler {
            try await workTask.value
        } onCancel: {
            workTask.cancel()
        }
    }

    /// CIImageをリサイズ
    func resizeCIImage(_ ciImage: CIImage, maxSize: CGSize) -> CIImage {
        let extent = ciImage.extent
        let width = extent.width
        let height = extent.height

        guard width > maxSize.width || height > maxSize.height else {
            return ciImage
        }

        let scaleX = maxSize.width / width
        let scaleY = maxSize.height / height
        let scale = min(scaleX, scaleY)

        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = ciImage
        filter.scale = Float(scale)
        filter.aspectRatio = 1.0
        return filter.outputImage ?? ciImage
    }

    /// フィルター適用（同期版）
    private func processFilterSync(_ filter: FilterType, on ciImage: CIImage) -> CIImage {
        switch filter {
        case .natural:
            ciImage
        case .clear:
            applyClearFilter(to: ciImage)
        case .drama:
            applyDramaFilter(to: ciImage)
        case .soft:
            applySoftFilter(to: ciImage)
        case .warm:
            applyWarmFilter(to: ciImage)
        case .cool:
            applyCoolFilter(to: ciImage)
        case .vintage:
            applyVintageFilter(to: ciImage)
        case .monochrome:
            applyMonochromeFilter(to: ciImage)
        case .pastel:
            applyPastelFilter(to: ciImage)
        case .vivid:
            applyVividFilter(to: ciImage)
        }
    }

    // MARK: - Compression & Resize

    func resizeImage(_ image: UIImage, maxSize: CGSize) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let size = image.size
                let aspectRatio = size.width / size.height

                var newSize: CGSize = if size.width > size.height {
                    if size.width > maxSize.width {
                        CGSize(width: maxSize.width, height: maxSize.width / aspectRatio)
                    } else {
                        size
                    }
                } else {
                    if size.height > maxSize.height {
                        CGSize(width: maxSize.height * aspectRatio, height: maxSize.height)
                    } else {
                        size
                    }
                }

                // CIContextベースのリサイズ（バックグラウンドスレッドセーフ）
                guard let cgImage = image.cgImage else {
                    continuation.resume(returning: image)
                    return
                }
                let ciImage = CIImage(cgImage: cgImage)
                let scaleX = newSize.width / ciImage.extent.width
                let scaleY = newSize.height / ciImage.extent.height
                let scale = min(scaleX, scaleY)

                let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                // 【修正】CIContext を毎回生成せず CIContextPool.shared.ciContext を再利用
                guard let outputCGImage = CIContextPool.shared.ciContext.createCGImage(scaled, from: scaled.extent) else {
                    continuation.resume(returning: image)
                    return
                }

                let resizedImage = UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
                continuation.resume(returning: resizedImage)
            }
        }
    }

    func compressImage(_ image: UIImage, quality: CGFloat) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                guard let imageData = image.jpegData(compressionQuality: quality) else {
                    continuation.resume(throwing: ImageServiceError.compressionFailed)
                    return
                }

                let maxSize = 5 * 1024 * 1024
                if imageData.count > maxSize {
                    var currentQuality = quality
                    var compressedData = imageData

                    while compressedData.count > maxSize, currentQuality > 0.5 {
                        currentQuality -= 0.1
                        if let newData = image.jpegData(compressionQuality: currentQuality) {
                            compressedData = newData
                        } else {
                            break
                        }
                    }

                    continuation.resume(returning: compressedData)
                } else {
                    continuation.resume(returning: imageData)
                }
            }
        }
    }

    // MARK: - Analysis

    func extractColors(_ image: UIImage, maxCount: Int) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let resizedImage = try await self.resizeImage(image, maxSize: CGSize(width: 512, height: 512))
                    guard let resizedCIImage = CIImage(image: resizedImage) else {
                        throw ImageServiceError.invalidImage
                    }

                    // 空マスク無し（画像全体）で CIImage 版へ委譲する。出力は従来と同一。
                    let colors = try await self.extractColors(from: resizedCIImage, maxCount: maxCount, skyMask: nil)
                    continuation.resume(returning: colors)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func extractColors(from ciImage: CIImage, maxCount: Int, skyMask: CIImage?) async throws -> [String] {
        // 空のセルが 1 つも残らない（マスクがほぼ空を含まない等）ときは画像全体へフォールバックする。
        if let skyMask, let skyColors = maskedDominantColors(image: ciImage, mask: skyMask, maxCount: maxCount) {
            return skyColors
        }
        return try await extractDominantColors(from: ciImage, maxCount: maxCount)
    }

    private func extractDominantColors(from ciImage: CIImage, maxCount: Int) async throws -> [String] {
        let extent = ciImage.extent
        let gridSize = min(maxCount, 5)
        let cellWidth = extent.width / CGFloat(gridSize)
        let cellHeight = extent.height / CGFloat(gridSize)

        // セルの平均色を観測順（i=列 → j=行）に集める。順位付けは rankDominantColors に任せる。
        var samples: [(r: Int, g: Int, b: Int)] = []

        for i in 0 ..< gridSize {
            for j in 0 ..< gridSize {
                let cellRect = CGRect(
                    x: extent.origin.x + CGFloat(i) * cellWidth,
                    y: extent.origin.y + CGFloat(j) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )

                let filter = CIFilter.areaAverage()
                filter.inputImage = ciImage.cropped(to: cellRect)
                filter.extent = cellRect

                // ⚠️ 切り出し矩形に cellRect を使ってはならない。
                //    `areaAverage` の出力は入力範囲によらず**常に原点 (0,0) の 1×1 画像**である。
                //    一方 cellRect は i>0 / j>0 のセルでは原点が非ゼロなので両者が交差せず、
                //    取り出せるのは範囲外＝透明黒だけになる。これが「skyColors が全件 #000000、
                //    色温度が常に 2021K」の真因（2026-08-14 に実データで確認）。
                //    同じ間違いを SkyTypeClassifier で直したのが PR #79。そちらの
                //    `getAverageColor` と同じく 1×1 を指定するのが正しい。
                guard let outputImage = filter.outputImage,
                      let cgImage = context.createCGImage(outputImage, from: CGRect(x: 0, y: 0, width: 1, height: 1))
                else {
                    continue
                }

                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let bytesPerPixel = 4
                let bytesPerRow = bytesPerPixel
                var pixelData = [UInt8](repeating: 0, count: bytesPerPixel)

                // 変数名を pixelContext にしているのは、上で使っている `context`（CIContext）と
                // 取り違えないため。calculateColorTemperature 側と命名を揃えてある。
                guard let pixelContext = CGContext(
                    data: &pixelData,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else {
                    continue
                }

                pixelContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

                samples.append((r: Int(pixelData[0]), g: Int(pixelData[1]), b: Int(pixelData[2])))
            }
        }

        return Self.rankDominantColors(samples, maxCount: maxCount)
    }

    /// セルの平均色（観測順）から「よく出ている色」を上位 `maxCount` 件選ぶ。
    ///
    /// 画像全体の経路（`extractDominantColors`）と空マスクの経路（`maskedDominantColors`）で共用する。
    /// - Parameters:
    ///   - samples: セルの平均色（0...255）。観測順に並べる（同じグループの代表色は最初に観測した色になる）
    ///   - maxCount: 返す色の最大数
    /// - Returns: `#RRGGBB` の配列（出現数の降順 → キーの昇順）
    private static func rankDominantColors(_ samples: [(r: Int, g: Int, b: Int)], maxCount: Int) -> [String] {
        // 量子化キー -> (出現数, 代表色)。
        // ⚠️ セルの平均色そのものをキーにしてはならない。25セルの平均が完全一致することは
        //    まず無いため、全エントリが count=1 になり、下の prefix(maxCount) が
        //    「上位5色」ではなく「順序の定まらない任意の5セル」を返してしまう
        //    （Dictionary.sorted は値が同じときの順序を保証しない＝同じ写真から毎回違う
        //     skyColors が出る）。各チャンネルを32段階に丸めたキーでまとめることで、
        //    初めて「よく出ている色」という集計の意味が成立する。
        //    返す値は量子化後の色ではなく、そのグループで最初に観測した実際の色にする
        //    （丸めた色をそのまま保存すると、実際の空の色から目に見えてズレるため）。
        var buckets: [String: (count: Int, representative: String)] = [:]

        for sample in samples {
            let hexColor = String(format: "#%02X%02X%02X", sample.r, sample.g, sample.b)

            // 各チャンネルを 8 刻み（0-31 の32段階）に丸めたキー。近い色を1グループにまとめる。
            let bucketKey = String(format: "%02X%02X%02X", sample.r / 8, sample.g / 8, sample.b / 8)
            if let existing = buckets[bucketKey] {
                buckets[bucketKey] = (existing.count + 1, existing.representative)
            } else {
                buckets[bucketKey] = (1, hexColor)
            }
        }

        // 出現数の降順。同数のときはキーの昇順で並びを確定させる
        // （Dictionary.sorted は同値の順序が不定なため、ここを決めないと結果が毎回変わる）。
        let sortedBuckets = buckets.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count {
                return lhs.value.count > rhs.value.count
            }
            return lhs.key < rhs.key
        }
        return Array(sortedBuckets.prefix(maxCount).map(\.value.representative))
    }

    // MARK: - 空マスク加重の色（PR-B）

    /// 空マスク加重で色を読むグリッドの長辺（px）。512 の解析画像を 1/4 に縮めて CPU で回す。
    private static let skySamplingGridLongSide: CGFloat = 128
    /// 空のセルとして採用するマスク平均の下限。上端の薄い空（ソフトエッジ）でも 1 行目が残る値。
    private static let skyCellMinMaskMean: Double = 0.2
    /// 画像全体のマスク平均がこれ未満なら「空が無い」とみなして加重平均を返さない。
    private static let skyMinMaskMean: Double = 0.01

    /// 解析画像とマスクを同じグリッドで読み出した結果
    private struct MaskedSamplingGrid {
        /// 解析画像の RGBA8（premultiplied・行 0 が画像の上端）
        let pixels: [UInt8]
        /// マスクの RGBA8（同上）
        let mask: [UInt8]
        let width: Int
        let height: Int

        /// (x, y) の画素を「非乗算の色 0...255」「マスク値 0...1」「画素の不透明度 0...1」で返す。
        ///
        /// ⚠️ 読み出しは premultiplied なので、縮小で縁の画素が半透明になると色もマスクも暗く見える。
        ///    アルファで割り戻してから、アルファ（=その画素がどれだけ画像の中にあるか）を重みに掛ける。
        ///    割り戻さないと、単色画像でも縁のセルだけ色が暗くなり「画像全体の値」とずれる。
        func sample(x: Int, y: Int) -> (r: Double, g: Double, b: Double, m: Double, a: Double) {
            let i = (y * width + x) * 4
            let alpha = Double(pixels[i + 3])
            guard alpha > 0 else { return (0, 0, 0, 0, 0) }
            let r = Double(pixels[i]) * 255.0 / alpha
            let g = Double(pixels[i + 1]) * 255.0 / alpha
            let b = Double(pixels[i + 2]) * 255.0 / alpha
            let maskAlpha = Double(mask[i + 3])
            // マスクはグレースケール（R=G=B=値・アルファ素通し）。R をアルファで割り戻して値にする。
            // ⚠️ マスクは色管理なし（`HeuristicSkyMaskProvider` が `.colorSpace: NSNull()` で作る）＝線形の値だが、
            //    `readRGBA8` は sRGB で書き出すため、読んだ値には sRGB のガンマがかかっている（0.15 → 約 0.42）。
            //    0/1 は変わらないが、境界のにじみ（中間値）の重みとセルの採用判定が膨らむので線形に戻す。
            //    画像側は本物の sRGB 色空間を持つので、書き出しで元の値に戻っており変換しない。
            let encoded = maskAlpha > 0 ? min(1.0, Double(mask[i]) / maskAlpha) : 0
            let m = Self.srgbToLinear(encoded)
            return (min(255, r), min(255, g), min(255, b), m, alpha / 255.0)
        }

        /// sRGB のガンマを外す（`ImageService.correlatedColorTemperature` の linearize と同じ式）
        private static func srgbToLinear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
    }

    /// 解析画像とマスクを同じ長辺 128px のグリッドへ縮小して読み出す（`SkyColorGate.readRGBA8` を共用）。
    private func readMaskedSamplingGrid(image: CIImage, mask: CIImage) -> MaskedSamplingGrid? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }

        // origin を (0,0) に揃える。readRGBA8 は CI 座標系の原点を基準に縮小して (0,0) 起点で読むため、
        // origin が非ゼロのままだと画像本体からはみ出した範囲を読んでしまう。マスクも同じ量だけずらす。
        let shift = CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        let bounds = CGRect(origin: .zero, size: extent.size)
        let normalizedImage = image.transformed(by: shift)
        let normalizedMask = mask.transformed(by: shift).cropped(to: bounds)

        let scale = min(1, Self.skySamplingGridLongSide / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))

        guard let pixels = SkyColorGate.readRGBA8(normalizedImage, gridW: width, gridH: height, ciContext: context),
              let maskPixels = SkyColorGate.readRGBA8(normalizedMask, gridW: width, gridH: height, ciContext: context)
        else {
            return nil
        }
        return MaskedSamplingGrid(pixels: pixels, mask: maskPixels, width: width, height: height)
    }

    /// 空マスク加重で主要色を選ぶ。セル平均は Σ(m·c)/Σm、マスク平均が `skyCellMinMaskMean` 未満のセルは捨てる。
    ///
    /// CI の `areaAverage(image×mask) / areaAverage(mask)` を使わないのは、線形空間での平均になることと、
    /// 8bit 量子化で被覆率 5% のとき 1/255 が約 8% の相対誤差になるため。CPU で加重和を取る。
    /// - Returns: 空のセルが 1 つも無い・読み出しに失敗したときは nil（呼び出し側が画像全体へフォールバック）
    /// グリッドの矩形範囲（[x0, x1) × [y0, y1)）で Σ(m·a·c) と Σm・Σ(m・a) を積算する。
    /// `maskedDominantColors`（セル単位）・`maskedMeanColor`（全域）の共通ロジック（review-full simplifier keep）。
    private func accumulateWeightedSum(
        grid: MaskedSamplingGrid,
        x0: Int, x1: Int, y0: Int, y1: Int
    ) -> (weightSum: Double, alphaSum: Double, rSum: Double, gSum: Double, bSum: Double) {
        var weightSum = 0.0
        var alphaSum = 0.0
        var rSum = 0.0, gSum = 0.0, bSum = 0.0
        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                let p = grid.sample(x: x, y: y)
                let weight = p.m * p.a
                weightSum += weight
                alphaSum += p.a
                rSum += weight * p.r
                gSum += weight * p.g
                bSum += weight * p.b
            }
        }
        return (weightSum, alphaSum, rSum, gSum, bSum)
    }

    private func maskedDominantColors(image: CIImage, mask: CIImage, maxCount: Int) -> [String]? {
        guard let grid = readMaskedSamplingGrid(image: image, mask: mask) else { return nil }

        // セルの分け方・観測順は画像全体の経路（extractDominantColors）と揃える。
        // i=列（左→右）、j=行（CI 座標と同じく下→上）。ビットマップは行 0 が上端なので行番号を反転する。
        let gridSize = min(maxCount, 5)
        guard gridSize > 0 else { return nil }
        var samples: [(r: Int, g: Int, b: Int)] = []

        for i in 0 ..< gridSize {
            let x0 = i * grid.width / gridSize
            let x1 = (i + 1) * grid.width / gridSize
            for j in 0 ..< gridSize {
                let rowFromTop = gridSize - 1 - j
                let y0 = rowFromTop * grid.height / gridSize
                let y1 = (rowFromTop + 1) * grid.height / gridSize

                let sums = accumulateWeightedSum(grid: grid, x0: x0, x1: x1, y0: y0, y1: y1)
                // マスク平均が低いセル（地上・境界のにじみ）は色の集計に入れない
                guard sums.alphaSum > 0, sums.weightSum / sums.alphaSum >= Self.skyCellMinMaskMean else { continue }

                func toByte(_ value: Double) -> Int {
                    max(0, min(255, Int((value / sums.weightSum).rounded())))
                }
                samples.append((r: toByte(sums.rSum), g: toByte(sums.gSum), b: toByte(sums.bSum)))
            }
        }

        guard !samples.isEmpty else { return nil }
        return Self.rankDominantColors(samples, maxCount: maxCount)
    }

    /// 空マスク加重の平均色（0...1）。Σ(m·c)/Σm。
    /// - Returns: マスク平均が `skyMinMaskMean` 未満（空がほぼ無い）・読み出し失敗なら nil
    private func maskedMeanColor(image: CIImage, mask: CIImage) -> (r: Double, g: Double, b: Double)? {
        guard let grid = readMaskedSamplingGrid(image: image, mask: mask) else { return nil }

        let sums = accumulateWeightedSum(grid: grid, x0: 0, x1: grid.width, y0: 0, y1: grid.height)
        guard sums.alphaSum > 0, sums.weightSum > 0, sums.weightSum / sums.alphaSum >= Self.skyMinMaskMean else { return nil }
        return (r: sums.rSum / sums.weightSum / 255.0, g: sums.gSum / sums.weightSum / 255.0, b: sums.bSum / sums.weightSum / 255.0)
    }

    func calculateColorTemperature(_ image: UIImage) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    guard CIImage(image: image) != nil else {
                        throw ImageServiceError.invalidImage
                    }

                    let resizedImage = try await self.resizeImage(image, maxSize: CGSize(width: 512, height: 512))
                    guard let resizedCIImage = CIImage(image: resizedImage) else {
                        throw ImageServiceError.invalidImage
                    }

                    // 空マスク無し（画像全体）で CIImage 版へ委譲する。出力は従来と同一。
                    let colorTemperature = try await self.calculateColorTemperature(from: resizedCIImage, skyMask: nil)
                    continuation.resume(returning: colorTemperature)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func calculateColorTemperature(from ciImage: CIImage, skyMask: CIImage?) async throws -> Int {
        // 空がほぼ写っていない（マスク平均が小さい）ときは画像全体へフォールバックする。
        if let skyMask, let skyMean = maskedMeanColor(image: ciImage, mask: skyMask) {
            return Self.correlatedColorTemperature(r: skyMean.r, g: skyMean.g, b: skyMean.b)
        }
        let mean = try wholeImageMeanColor(of: ciImage)
        return Self.correlatedColorTemperature(r: mean.r, g: mean.g, b: mean.b)
    }

    /// 画像全体の平均色（0...1・8bit 量子化後）を `areaAverage` で読む。
    private func wholeImageMeanColor(of ciImage: CIImage) throws -> (r: Double, g: Double, b: Double) {
        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage
        filter.extent = ciImage.extent

        // ⚠️ 切り出し矩形に resizedCIImage.extent（512×512）を使ってはならない。
        //    `areaAverage` の出力は常に原点 (0,0) の 1×1 画像なので、512×512 を要求すると
        //    平均色は左下1ピクセルだけ、残りは範囲外＝透明黒で埋まった画像が返る。
        //    それを 1×1 に縮小描画するとほぼ真っ黒になり、下の式が必ず約2020Kを返していた
        //    （実データでも全投稿が colorTemperature: 2021 で固定。2026-08-14 確認）。
        //    extractDominantColors / SkyTypeClassifier.getAverageColor と同じく 1×1 が正しい。
        guard let outputImage = filter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: CGRect(x: 0, y: 0, width: 1, height: 1))
        else {
            throw ImageServiceError.processingFailed
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: bytesPerPixel)

        guard let pixelContext = CGContext(
            data: &pixelData,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ImageServiceError.processingFailed
        }

        pixelContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return (
            r: Double(pixelData[0]) / 255.0,
            g: Double(pixelData[1]) / 255.0,
            b: Double(pixelData[2]) / 255.0
        )
    }

    /// sRGB の平均色（0...1）から相関色温度（K・2000...10000 にクランプ）を求める。
    /// 画像全体の経路と空マスクの経路で共用する。
    private static func correlatedColorTemperature(r: Double, g: Double, b: Double) -> Int {
        // McCamy の近似式は「CIE xy 色度座標」を入力に取る式であり、RGB をそのまま
        // x, y として渡してはならない（旧実装は x に r、y に b を入れていた＝単位の取り違え）。
        // 誤用したままだと暖色で除数が負に振れて式が破綻し、夕焼けが常に下限 2000K に
        // 張り付いていた。sRGB → 線形RGB → CIE XYZ(D65) → xy と正しく変換してから渡す。
        // 検証: D65 の無彩色 #808080 を通すと 6504K（D65 の定義値）が返ることを確認済み。

        // sRGB のガンマを外して線形 RGB にする
        func linearize(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let rLinear = linearize(r)
        let gLinear = linearize(g)
        let bLinear = linearize(b)

        // 線形 sRGB → CIE XYZ（D65 基準の標準変換行列）
        let xyzX = 0.4124 * rLinear + 0.3576 * gLinear + 0.1805 * bLinear
        let xyzY = 0.2126 * rLinear + 0.7152 * gLinear + 0.0722 * bLinear
        let xyzZ = 0.0193 * rLinear + 0.1192 * gLinear + 0.9505 * bLinear

        let epsilon = 1e-10
        // 真っ黒（XYZ 合計が 0）では色度が定義できないため、既定値（昼光 5500K）を返す
        let xyzSum = xyzX + xyzY + xyzZ
        guard xyzSum > epsilon else {
            return 5500
        }
        let chromaticityX = xyzX / xyzSum
        let chromaticityY = xyzY / xyzSum

        // ゼロ除算防止: 除数 (0.1858 - y) が0近傍の場合はデフォルト値（昼光 5500K）を返す
        let divisor = 0.1858 - chromaticityY
        guard abs(divisor) > epsilon else {
            return 5500
        }

        let n = (chromaticityX - 0.3320) / divisor
        let nSquared = n * n
        let nCubed = nSquared * n
        let colorTemperature = (449.0 * nCubed) + (3525.0 * nSquared) + (6823.3 * n) + 5520.33

        // NaN/Infinity チェック: 異常値の場合はデフォルト値（昼光 5500K）を返す
        guard colorTemperature.isFinite else {
            return 5500
        }

        return max(2000, min(10000, Int(colorTemperature)))
    }

    func detectSkyType(_ image: UIImage) async throws -> SkyType {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    guard let ciImage = CIImage(image: image) else {
                        throw ImageServiceError.invalidImage
                    }

                    let resizedImage = try await self.resizeImage(image, maxSize: CGSize(width: 512, height: 512))
                    guard let resizedCIImage = CIImage(image: resizedImage) else {
                        throw ImageServiceError.invalidImage
                    }

                    let colorTemperature = try await self.calculateColorTemperature(resizedImage)
                    let colors = try await self.extractColors(resizedImage, maxCount: 5)
                    let hsvAnalysis = try await self.analyzeHSV(resizedCIImage)

                    let skyType = self.determineSkyType(
                        colorTemperature: colorTemperature,
                        colors: colors,
                        hsvAnalysis: hsvAnalysis
                    )

                    continuation.resume(returning: skyType)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func analyzeHSV(_ ciImage: CIImage) async throws -> (hue: Double, saturation: Double, brightness: Double) {
        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage
        filter.extent = ciImage.extent

        guard let outputImage = filter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: ciImage.extent)
        else {
            throw ImageServiceError.processingFailed
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: bytesPerPixel)

        guard let pixelContext = CGContext(
            data: &pixelData,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ImageServiceError.processingFailed
        }

        pixelContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let r = Double(pixelData[0]) / 255.0
        let g = Double(pixelData[1]) / 255.0
        let b = Double(pixelData[2]) / 255.0

        let max = Swift.max(r, g, b)
        let min = Swift.min(r, g, b)
        let delta = max - min

        var h: Double = 0
        if delta != 0 {
            if max == r {
                h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if max == g {
                h = 60 * (((b - r) / delta) + 2)
            } else {
                h = 60 * (((r - g) / delta) + 4)
            }
        }
        if h < 0 { h += 360 }

        let s = max == 0 ? 0 : delta / max
        let v = max

        return (hue: h, saturation: s, brightness: v)
    }

    private func determineSkyType(
        colorTemperature: Int,
        colors _: [String],
        hsvAnalysis: (hue: Double, saturation: Double, brightness: Double)
    ) -> SkyType {
        let hue = hsvAnalysis.hue
        let saturation = hsvAnalysis.saturation
        let brightness = hsvAnalysis.brightness

        if colorTemperature < 4000, hue >= 0 && hue <= 60 || hue >= 300 && hue <= 360 {
            if colorTemperature < 3000 {
                return .sunset
            } else {
                return .sunrise
            }
        }

        if brightness < 0.3, saturation > 0.5 {
            return .storm
        }

        if saturation < 0.3 {
            return .cloudy
        }

        if colorTemperature >= 5000, hue >= 180, hue <= 240 {
            return .clear
        }

        return .clear
    }

    // MARK: - EXIF

    /// 元ファイル（写真ライブラリから `loadFileRepresentation` で得た一時ファイル等）の EXIF を読む。
    ///
    /// ⚠️ 旧実装は `UIImage.jpegData` で**再エンコードしてから** EXIF を読んでいたため、
    ///    メタデータが構造的に常に空だった（本番の公開投稿 12/12 件で撮影日時が欠落）。
    ///    UIImage は EXIF を保持しないので、元ファイルの URL から直接読むしかない。
    /// - 同期 API にしているのは、`NSItemProvider.loadFileRepresentation` の一時 URL が
    ///   completion を抜けた時点で無効になるため。呼び出し側は completion の中で読み切る。
    /// - `kCGImageSourceShouldCache: false` でピクセルのデコードを避け、ヘッダだけ読む
    ///   （10 枚選択で 10 回呼ばれても軽い）。HEIC も `.current` 表現のまま読める。
    /// - Throws: 画像として開けないファイルは `ImageServiceError.invalidImage`。
    ///   EXIF が無いだけなら throw せず、各フィールド nil の `EXIFData` を返す。
    func extractEXIFData(fileURL: URL) throws -> EXIFData {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else {
            throw ImageServiceError.invalidImage
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary) as? [String: Any] else {
            return EXIFData()
        }
        return Self.parseEXIFData(from: properties)
    }

    /// ImageIO のプロパティ辞書から `EXIFData` を組み立てる（純関数・I/O なし）。
    /// 旧 UIImage 版から組み立て部分をそのまま移した。`static` なのは辞書だけで
    /// テストできるようにするため。
    static func parseEXIFData(from properties: [String: Any]) -> EXIFData {
        let exifDict = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiffDict = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]

        var capturedAt: Date?
        if let dateTimeOriginal = exifDict?[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            // OffsetTimeOriginal（EXIF 2.31・"+09:00" 形式）があれば撮影地のオフセットで解釈する
            let offset = exifDict?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
            capturedAt = parseEXIFDateTime(dateTimeOriginal, offset: offset)
        }

        let cameraModel = tiffDict?[kCGImagePropertyTIFFModel as String] as? String
        let iso = exifDict?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int]
        let isoValue = iso?.first

        var shutterSpeed: String?
        if let exposureTime = exifDict?[kCGImagePropertyExifExposureTime as String] as? Double {
            shutterSpeed = String(format: "1/%.0f", 1.0 / exposureTime)
        }

        var aperture: String?
        if let fNumber = exifDict?[kCGImagePropertyExifFNumber as String] as? Double {
            aperture = String(format: "f/%.1f", fNumber)
        }

        var focalLength: String?
        if let focalLengthValue = exifDict?[kCGImagePropertyExifFocalLength as String] as? Double {
            focalLength = String(format: "%.0fmm", focalLengthValue)
        }

        return EXIFData(
            capturedAt: capturedAt,
            cameraModel: cameraModel,
            iso: isoValue,
            shutterSpeed: shutterSpeed,
            aperture: aperture,
            focalLength: focalLength
        )
    }

    /// EXIF の日時文字列（`"yyyy:MM:dd HH:mm:ss"`）を `Date` に変換する。書式外は nil。
    ///
    /// - `Locale(identifier: "en_US_POSIX")` と `Calendar(identifier: .gregorian)` を固定するのは、
    ///   端末の設定が和暦・タイ仏暦・12 時間制などでも解釈がぶれないようにするため
    ///   （`DateFormatter` は既定で端末ロケールに従い、和暦端末では "2026" を和暦年として読む）。
    /// - EXIF の日時はタイムゾーンを持たない「壁時計」の値。`offset`（`OffsetTimeOriginal`・
    ///   `"+09:00"` 形式）があればそのオフセットで、無ければ `TimeZone.current` で解釈する
    ///   （撮影地＝端末の所在地という前提）。`"JST"` のような ISO 形式でない値は無視して current に倒す。
    static func parseEXIFDateTime(_ value: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = offset.flatMap(timeZone(fromEXIFOffset:)) ?? .current
        return formatter.date(from: value)
    }

    /// `"+09:00"` / `"-05:30"` 形式の EXIF オフセット文字列を `TimeZone` に変換する。
    /// 6 文字（符号 + HH + ":" + MM）以外・範囲外は nil（呼び出し側が `.current` に倒す）。
    private static func timeZone(fromEXIFOffset offset: String) -> TimeZone? {
        let chars = Array(offset)
        guard chars.count == 6,
              chars[0] == "+" || chars[0] == "-",
              chars[3] == ":",
              let hours = Int(String(chars[1...2])),
              let minutes = Int(String(chars[4...5])),
              (0...23).contains(hours),
              (0...59).contains(minutes)
        else {
            return nil
        }
        let sign = chars[0] == "-" ? -1 : 1
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }
}

// MARK: - ImageServiceError

enum ImageServiceError: LocalizedError {
    case invalidImage
    case processingFailed
    case compressionFailed
    case resizeFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "無効な画像です"
        case .processingFailed:
            "画像処理に失敗しました"
        case .compressionFailed:
            "画像の圧縮に失敗しました"
        case .resizeFailed:
            "画像のリサイズに失敗しました"
        }
    }
}
