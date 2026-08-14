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
    func detectSkyType(_ image: UIImage) async throws -> SkyType
    func extractEXIFData(_ image: UIImage) async throws -> EXIFData
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

                    let colors = try await self.extractDominantColors(from: resizedCIImage, maxCount: maxCount)
                    continuation.resume(returning: colors)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func extractDominantColors(from ciImage: CIImage, maxCount: Int) async throws -> [String] {
        let extent = ciImage.extent
        let gridSize = min(maxCount, 5)
        let cellWidth = extent.width / CGFloat(gridSize)
        let cellHeight = extent.height / CGFloat(gridSize)

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

                let r = Int(pixelData[0])
                let g = Int(pixelData[1])
                let b = Int(pixelData[2])
                let hexColor = String(format: "#%02X%02X%02X", r, g, b)

                // 各チャンネルを 8 刻み（0-31 の32段階）に丸めたキー。近い色を1グループにまとめる。
                let bucketKey = String(format: "%02X%02X%02X", r / 8, g / 8, b / 8)
                if let existing = buckets[bucketKey] {
                    buckets[bucketKey] = (existing.count + 1, existing.representative)
                } else {
                    buckets[bucketKey] = (1, hexColor)
                }
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

    func calculateColorTemperature(_ image: UIImage) async throws -> Int {
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

                    let filter = CIFilter.areaAverage()
                    filter.inputImage = resizedCIImage
                    filter.extent = resizedCIImage.extent

                    // ⚠️ 切り出し矩形に resizedCIImage.extent（512×512）を使ってはならない。
                    //    `areaAverage` の出力は常に原点 (0,0) の 1×1 画像なので、512×512 を要求すると
                    //    平均色は左下1ピクセルだけ、残りは範囲外＝透明黒で埋まった画像が返る。
                    //    それを 1×1 に縮小描画するとほぼ真っ黒になり、下の式が必ず約2020Kを返していた
                    //    （実データでも全投稿が colorTemperature: 2021 で固定。2026-08-14 確認）。
                    //    extractDominantColors / SkyTypeClassifier.getAverageColor と同じく 1×1 が正しい。
                    guard let outputImage = filter.outputImage,
                          let cgImage = self.context.createCGImage(outputImage, from: CGRect(x: 0, y: 0, width: 1, height: 1))
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
                        continuation.resume(returning: 5500)
                        return
                    }
                    let chromaticityX = xyzX / xyzSum
                    let chromaticityY = xyzY / xyzSum

                    // ゼロ除算防止: 除数 (0.1858 - y) が0近傍の場合はデフォルト値（昼光 5500K）を返す
                    let divisor = 0.1858 - chromaticityY
                    guard abs(divisor) > epsilon else {
                        continuation.resume(returning: 5500)
                        return
                    }

                    let n = (chromaticityX - 0.3320) / divisor
                    let nSquared = n * n
                    let nCubed = nSquared * n
                    let colorTemperature = (449.0 * nCubed) + (3525.0 * nSquared) + (6823.3 * n) + 5520.33

                    // NaN/Infinity チェック: 異常値の場合はデフォルト値（昼光 5500K）を返す
                    guard colorTemperature.isFinite else {
                        continuation.resume(returning: 5500)
                        return
                    }

                    let clampedTemperature = max(2000, min(10000, Int(colorTemperature)))
                    continuation.resume(returning: clampedTemperature)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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

    func extractEXIFData(_ image: UIImage) async throws -> EXIFData {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    guard let imageData = image.jpegData(compressionQuality: 1.0),
                          let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil)
                    else {
                        throw ImageServiceError.invalidImage
                    }

                    guard let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
                        continuation.resume(returning: EXIFData())
                        return
                    }

                    let exifDict = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
                    let tiffDict = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]

                    var capturedAt: Date?
                    if let dateTimeOriginal = exifDict?[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                        capturedAt = formatter.date(from: dateTimeOriginal)
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

                    let exifData = EXIFData(
                        capturedAt: capturedAt,
                        cameraModel: cameraModel,
                        iso: isoValue,
                        shutterSpeed: shutterSpeed,
                        aperture: aperture,
                        focalLength: focalLength
                    )

                    continuation.resume(returning: exifData)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
