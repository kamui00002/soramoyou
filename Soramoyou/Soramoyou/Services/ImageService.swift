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

import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision
import Metal

protocol ImageServiceProtocol {
    // Filter
    func applyFilter(_ filter: FilterType, to image: UIImage) async throws -> UIImage

    /// EditRecipe 直接受け取り版（toneCurvePoints 等の EditSettings にない情報を脱落させない）
    func generatePreview(_ image: UIImage, recipe: EditRecipe) async throws -> UIImage
    func generatePreviewFromCIImage(_ ciImage: CIImage, recipe: EditRecipe) -> UIImage?
    /// EditRecipe を UIImage に適用（フル解像度・最終書き出し用）
    func applyEditRecipe(_ recipe: EditRecipe, to image: UIImage) async throws -> UIImage

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
        if let context = context {
            // テスト時など外部からの注入を許容
            self.context = context
        } else {
            // CIContextPool のシングルトンを使用（Metal + 適切な色空間設定済み）
            self.context = CIContextPool.shared.ciContext
        }
    }

    // MARK: - Filter

    func applyFilter(_ filter: FilterType, to image: UIImage) async throws -> UIImage {
        return try await withCheckedThrowingContinuation { continuation in
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
            return ciImage
        case .clear:
            return applyClearFilter(to: ciImage)
        case .drama:
            return applyDramaFilter(to: ciImage)
        case .soft:
            return applySoftFilter(to: ciImage)
        case .warm:
            return applyWarmFilter(to: ciImage)
        case .cool:
            return applyCoolFilter(to: ciImage)
        case .vintage:
            return applyVintageFilter(to: ciImage)
        case .monochrome:
            return applyMonochromeFilter(to: ciImage)
        case .pastel:
            return applyPastelFilter(to: ciImage)
        case .vivid:
            return applyVividFilter(to: ciImage)
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
    func generatePreview(_ image: UIImage, recipe: EditRecipe) async throws -> UIImage {
        // 🔧 2026-05-25 修正: 旧実装は 750×750 へ固定縮小していたため、編集画面に入った
        //   瞬間からプレビューがアップスケールでぼやけていた。高解像度パス（2400px）の
        //   PreviewRenderer.renderPreview が用意済みなのに未配線だったため、ここで配線する。
        //   applyEditRecipe と同じくキャンセル伝搬付きの detached 実行にして、ドラッグ中に
        //   古い計算が GPU/CPU を占有し続けないようにする。
        try Task.checkCancellation()

        let workTask = Task.detached(priority: .userInitiated) { () throws -> UIImage in
            try Task.checkCancellation()
            return try PreviewRenderer.renderPreview(from: image, recipe: recipe)
        }

        return try await withTaskCancellationHandler {
            try await workTask.value
        } onCancel: {
            workTask.cancel()
        }
    }

    /// 低解像度 CIImage + EditRecipe から同期的にプレビュー生成（リアルタイム用）
    func generatePreviewFromCIImage(_ ciImage: CIImage, recipe: EditRecipe) -> UIImage? {
        let result = FilterGraphBuilder.buildGraph(recipe: recipe, source: ciImage, quality: .interactive)
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
    func applyEditRecipe(_ recipe: EditRecipe, to image: UIImage) async throws -> UIImage {
        try Task.checkCancellation()

        let workTask = Task.detached(priority: .userInitiated) { () throws -> UIImage in
            guard let ciImage = CIImage(image: image) else {
                throw ImageServiceError.invalidImage
            }
            try Task.checkCancellation()
            let result = FilterGraphBuilder.buildGraph(recipe: recipe, source: ciImage)
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
            return ciImage
        case .clear:
            return applyClearFilter(to: ciImage)
        case .drama:
            return applyDramaFilter(to: ciImage)
        case .soft:
            return applySoftFilter(to: ciImage)
        case .warm:
            return applyWarmFilter(to: ciImage)
        case .cool:
            return applyCoolFilter(to: ciImage)
        case .vintage:
            return applyVintageFilter(to: ciImage)
        case .monochrome:
            return applyMonochromeFilter(to: ciImage)
        case .pastel:
            return applyPastelFilter(to: ciImage)
        case .vivid:
            return applyVividFilter(to: ciImage)
        }
    }

    // MARK: - Compression & Resize

    func resizeImage(_ image: UIImage, maxSize: CGSize) async throws -> UIImage {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let size = image.size
                let aspectRatio = size.width / size.height

                var newSize: CGSize
                if size.width > size.height {
                    if size.width > maxSize.width {
                        newSize = CGSize(width: maxSize.width, height: maxSize.width / aspectRatio)
                    } else {
                        newSize = size
                    }
                } else {
                    if size.height > maxSize.height {
                        newSize = CGSize(width: maxSize.height * aspectRatio, height: maxSize.height)
                    } else {
                        newSize = size
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
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                guard let imageData = image.jpegData(compressionQuality: quality) else {
                    continuation.resume(throwing: ImageServiceError.compressionFailed)
                    return
                }

                let maxSize: Int = 5 * 1024 * 1024
                if imageData.count > maxSize {
                    var currentQuality = quality
                    var compressedData = imageData

                    while compressedData.count > maxSize && currentQuality > 0.5 {
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
        return try await withCheckedThrowingContinuation { continuation in
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

        var colorMap: [String: Int] = [:]

        for i in 0..<gridSize {
            for j in 0..<gridSize {
                let cellRect = CGRect(
                    x: extent.origin.x + CGFloat(i) * cellWidth,
                    y: extent.origin.y + CGFloat(j) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )

                let filter = CIFilter.areaAverage()
                filter.inputImage = ciImage.cropped(to: cellRect)
                filter.extent = cellRect

                guard let outputImage = filter.outputImage,
                      let cgImage = context.createCGImage(outputImage, from: cellRect) else {
                    continue
                }

                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let bytesPerPixel = 4
                let bytesPerRow = bytesPerPixel
                var pixelData = [UInt8](repeating: 0, count: bytesPerPixel)

                guard let context = CGContext(
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

                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

                let r = Int(pixelData[0])
                let g = Int(pixelData[1])
                let b = Int(pixelData[2])
                let hexColor = String(format: "#%02X%02X%02X", r, g, b)

                colorMap[hexColor, default: 0] += 1
            }
        }

        let sortedColors = colorMap.sorted { $0.value > $1.value }
        return Array(sortedColors.prefix(maxCount).map { $0.key })
    }

    func calculateColorTemperature(_ image: UIImage) async throws -> Int {
        return try await withCheckedThrowingContinuation { continuation in
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

                    guard let outputImage = filter.outputImage,
                          let cgImage = self.context.createCGImage(outputImage, from: resizedCIImage.extent) else {
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

                    // ゼロ除算防止: 除数 (0.1858 - b) が0近傍の場合はデフォルト値（昼光 5500K）を返す
                    let divisor = 0.1858 - b
                    let epsilon = 1e-10
                    guard abs(divisor) > epsilon else {
                        continuation.resume(returning: 5500)
                        return
                    }

                    let n = (r - 0.3320) / divisor
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
        return try await withCheckedThrowingContinuation { continuation in
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
              let cgImage = context.createCGImage(outputImage, from: ciImage.extent) else {
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
        colors: [String],
        hsvAnalysis: (hue: Double, saturation: Double, brightness: Double)
    ) -> SkyType {
        let hue = hsvAnalysis.hue
        let saturation = hsvAnalysis.saturation
        let brightness = hsvAnalysis.brightness

        if colorTemperature < 4000 && (hue >= 0 && hue <= 60 || hue >= 300 && hue <= 360) {
            if colorTemperature < 3000 {
                return .sunset
            } else {
                return .sunrise
            }
        }

        if brightness < 0.3 && saturation > 0.5 {
            return .storm
        }

        if saturation < 0.3 {
            return .cloudy
        }

        if colorTemperature >= 5000 && (hue >= 180 && hue <= 240) {
            return .clear
        }

        return .clear
    }

    func extractEXIFData(_ image: UIImage) async throws -> EXIFData {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    guard let imageData = image.jpegData(compressionQuality: 1.0),
                          let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
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
            return "無効な画像です"
        case .processingFailed:
            return "画像処理に失敗しました"
        case .compressionFailed:
            return "画像の圧縮に失敗しました"
        case .resizeFailed:
            return "画像のリサイズに失敗しました"
        }
    }
}
