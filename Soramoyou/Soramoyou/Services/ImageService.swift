//
//  ImageService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision

protocol ImageServiceProtocol {
    // Filter
    func applyFilter(_ filter: FilterType, to image: UIImage) async throws -> UIImage
    
    // Edit Tools
    func applyEditTool(_ tool: EditTool, value: Float, to image: UIImage) async throws -> UIImage
    func applyEditSettings(_ settings: EditSettings, to image: UIImage) async throws -> UIImage
    
    // Preview
    func generatePreview(_ image: UIImage, edits: EditSettings) async throws -> UIImage
    
    // Compression & Resize
    func resizeImage(_ image: UIImage, maxSize: CGSize) async throws -> UIImage
    func compressImage(_ image: UIImage, quality: CGFloat) async throws -> Data
    
    // Analysis
    func extractColors(_ image: UIImage, maxCount: Int) async throws -> [String]
    func calculateColorTemperature(_ image: UIImage) async throws -> Int
    func detectSkyType(_ image: UIImage) async throws -> SkyType
    func extractEXIFData(_ image: UIImage) async throws -> EXIFData
}

class ImageService: ImageServiceProtocol {
    private let context: CIContext

    // MARK: - Constants

    private enum Constants {
        // サイズ制限
        static let analysisImageSize: CGFloat = 512          // 分析用画像サイズ（512x512）
        static let thumbnailSize: CGFloat = 512              // サムネイルサイズ
        static let maxFileSize: Int = 5 * 1024 * 1024       // 最大ファイルサイズ（5MB）

        // 圧縮品質
        static let minCompressionQuality: CGFloat = 0.5      // 最小圧縮品質
        static let compressionQualityStep: CGFloat = 0.1     // 品質調整ステップ

        // フィルター強度
        static let defaultFilterIntensity: Float = 0.5       // デフォルトフィルター強度

        // 色温度
        static let minColorTemperature: Int = 2000           // 最小色温度（K）
        static let maxColorTemperature: Int = 10000          // 最大色温度（K）
        static let baseColorTemperature: Double = 6500       // 基準色温度
        static let colorTemperatureRange: Double = 2000      // 色温度調整範囲

        // McCamy's formula定数
        static let mccamyConstantR: Double = 0.3320
        static let mccamyConstantB: Double = 0.1858

        // Sky detection閾値
        static let lowBrightnessThreshold: Double = 0.3
        static let highSaturationThreshold: Double = 0.5
    }

    init(context: CIContext = CIContext()) {
        self.context = context
    }

    // MARK: - Filter
    
    func applyFilter(_ filter: FilterType, to image: UIImage) async throws -> UIImage {
        return try await Task.detached(priority: .userInitiated) {
            guard let ciImage = CIImage(image: image) else {
                throw ImageServiceError.invalidImage
            }

            let filteredImage = try await self.processFilter(filter, on: ciImage)

            guard let cgImage = self.context.createCGImage(filteredImage, from: filteredImage.extent) else {
                throw ImageServiceError.processingFailed
            }

            return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
        }.value
    }
    
    private func processFilter(_ filter: FilterType, on ciImage: CIImage) async throws -> CIImage {
        switch filter {
        case .natural:
            return ciImage // フィルターなし
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
        filter.targetNeutral = CIVector(x: 5500, y: 0) // 暖色にシフト
        return filter.outputImage ?? image
    }
    
    private func applyCoolFilter(to image: CIImage) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: 7500, y: 0) // 寒色にシフト
        return filter.outputImage ?? image
    }
    
    private func applyVintageFilter(to image: CIImage) -> CIImage {
        var result = image
        
        // セピア調
        let sepiaFilter = CIFilter.sepiaTone()
        sepiaFilter.inputImage = result
        sepiaFilter.intensity = Constants.defaultFilterIntensity
        result = sepiaFilter.outputImage ?? result
        
        // ビネット効果
        let vignetteFilter = CIFilter.vignette()
        vignetteFilter.inputImage = result
        vignetteFilter.intensity = Constants.defaultFilterIntensity
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
    
    // MARK: - Edit Tools
    
    func applyEditTool(_ tool: EditTool, value: Float, to image: UIImage) async throws -> UIImage {
        return try await Task.detached(priority: .userInitiated) {
            guard let ciImage = CIImage(image: image) else {
                throw ImageServiceError.invalidImage
            }

            let editedImage = try await self.processEditTool(tool, value: value, on: ciImage)

            guard let cgImage = self.context.createCGImage(editedImage, from: editedImage.extent) else {
                throw ImageServiceError.processingFailed
            }

            return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
        }.value
    }
    
    private func processEditTool(_ tool: EditTool, value: Float, on ciImage: CIImage) async throws -> CIImage {
        // 値の範囲を-1.0から1.0に正規化（一部のツールは0.0から1.0）
        let normalizedValue = max(-1.0, min(1.0, value))
        
        switch tool {
        case .exposure:
            return applyExposure(normalizedValue, to: ciImage)
        case .brightness:
            return applyBrightness(normalizedValue, to: ciImage)
        case .contrast:
            return applyContrast(normalizedValue, to: ciImage)
        case .saturation:
            return applySaturation(normalizedValue, to: ciImage)
        case .highlight:
            return applyHighlight(normalizedValue, to: ciImage)
        case .shadow:
            return applyShadow(normalizedValue, to: ciImage)
        case .warmth:
            return applyWarmth(normalizedValue, to: ciImage)
        case .sharpness:
            return applySharpness(normalizedValue, to: ciImage)
        case .vignette:
            return applyVignette(normalizedValue, to: ciImage)
        default:
            // その他のツールは基本的な処理を実装
            return ciImage
        }
    }
    
    // MARK: - Edit Tool Implementations
    
    private func applyExposure(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = image
        filter.ev = value * 2.0 // -2.0から+2.0の範囲
        return filter.outputImage ?? image
    }
    
    private func applyBrightness(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.brightness = value
        return filter.outputImage ?? image
    }
    
    private func applyContrast(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.contrast = 1.0 + value
        return filter.outputImage ?? image
    }
    
    private func applySaturation(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = 1.0 + value
        return filter.outputImage ?? image
    }
    
    private func applyHighlight(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.highlightShadowAdjust()
        filter.inputImage = image
        filter.highlightAmount = value
        return filter.outputImage ?? image
    }
    
    private func applyShadow(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.highlightShadowAdjust()
        filter.inputImage = image
        filter.shadowAmount = value
        return filter.outputImage ?? image
    }
    
    private func applyWarmth(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: Constants.baseColorTemperature + Double(value) * Constants.colorTemperatureRange, y: 0)
        return filter.outputImage ?? image
    }
    
    private func applySharpness(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image
        filter.sharpness = value
        filter.radius = 1.5
        return filter.outputImage ?? image
    }
    
    private func applyVignette(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.vignette()
        filter.inputImage = image
        filter.intensity = abs(value)
        filter.radius = 1.0 + abs(value)
        return filter.outputImage ?? image
    }
    
    // MARK: - Edit Settings
    
    func applyEditSettings(_ settings: EditSettings, to image: UIImage) async throws -> UIImage {
        return try await Task.detached(priority: .userInitiated) {
            // autoreleasepoolで中間オブジェクトを適切に解放
            return try autoreleasepool {
                guard let ciImage = CIImage(image: image) else {
                    throw ImageServiceError.invalidImage
                }

                var result = ciImage

                // フィルターを適用（autoreleasepoolで囲む）
                if let filter = settings.appliedFilter {
                    result = try autoreleasepool {
                        try await self.processFilter(filter, on: result)
                    }
                }

                // 編集ツールを順次適用（各ツールごとにautoreleasepoolで囲む）
                if let brightness = settings.brightness {
                    result = autoreleasepool {
                        self.applyBrightness(brightness, to: result)
                    }
                }
                if let contrast = settings.contrast {
                    result = autoreleasepool {
                        self.applyContrast(contrast, to: result)
                    }
                }
                if let saturation = settings.saturation {
                    result = autoreleasepool {
                        self.applySaturation(saturation, to: result)
                    }
                }
                if let exposure = settings.exposure {
                    result = autoreleasepool {
                        self.applyExposure(exposure, to: result)
                    }
                }
                if let highlight = settings.highlight {
                    result = autoreleasepool {
                        self.applyHighlight(highlight, to: result)
                    }
                }
                if let shadow = settings.shadow {
                    result = autoreleasepool {
                        self.applyShadow(shadow, to: result)
                    }
                }
                if let warmth = settings.warmth {
                    result = autoreleasepool {
                        self.applyWarmth(warmth, to: result)
                    }
                }
                if let sharpness = settings.sharpness {
                    result = autoreleasepool {
                        self.applySharpness(sharpness, to: result)
                    }
                }
                if let vignette = settings.vignette {
                    result = autoreleasepool {
                        self.applyVignette(vignette, to: result)
                    }
                }

                guard let cgImage = self.context.createCGImage(result, from: result.extent) else {
                    throw ImageServiceError.processingFailed
                }

                return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
            }
        }.value
    }
    
    // MARK: - Preview
    
    func generatePreview(_ image: UIImage, edits: EditSettings) async throws -> UIImage {
        // まずサムネイルサイズにリサイズ
        let thumbnailSize = CGSize(width: Constants.thumbnailSize, height: Constants.thumbnailSize)
        let resizedImage = try await resizeImage(image, maxSize: thumbnailSize)
        
        // 編集設定を適用
        return try await applyEditSettings(edits, to: resizedImage)
    }
    
    // MARK: - Compression & Resize
    
    func resizeImage(_ image: UIImage, maxSize: CGSize) async throws -> UIImage {
        return try await Task.detached(priority: .userInitiated) {
            let size = image.size
            let aspectRatio = size.width / size.height

            var newSize: CGSize
            if size.width > size.height {
                // 横長
                if size.width > maxSize.width {
                    newSize = CGSize(width: maxSize.width, height: maxSize.width / aspectRatio)
                } else {
                    newSize = size
                }
            } else {
                // 縦長または正方形
                if size.height > maxSize.height {
                    newSize = CGSize(width: maxSize.height * aspectRatio, height: maxSize.height)
                } else {
                    newSize = size
                }
            }

            let renderer = UIGraphicsImageRenderer(size: newSize)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }.value
    }
    
    func compressImage(_ image: UIImage, quality: CGFloat) async throws -> Data {
        return try await Task.detached(priority: .userInitiated) {
            guard let imageData = image.jpegData(compressionQuality: quality) else {
                throw ImageServiceError.compressionFailed
            }

            // ファイルサイズが5MBを超える場合は品質を下げて再圧縮
            if imageData.count > Constants.maxFileSize {
                var currentQuality = quality
                var compressedData = imageData

                while compressedData.count > Constants.maxFileSize && currentQuality > Constants.minCompressionQuality {
                    currentQuality -= Constants.compressionQualityStep
                    if let newData = image.jpegData(compressionQuality: currentQuality) {
                        compressedData = newData
                    } else {
                        break
                    }
                }

                return compressedData
            } else {
                return imageData
            }
        }.value
    }
    
    // MARK: - Analysis
    
    func extractColors(_ image: UIImage, maxCount: Int) async throws -> [String] {
        return try await Task.detached(priority: .userInitiated) {
            guard let ciImage = CIImage(image: image) else {
                throw ImageServiceError.invalidImage
            }

            // 画像をリサイズして処理を高速化
            let resizedImage = try await self.resizeImage(image, maxSize: CGSize(width: Constants.analysisImageSize, height: Constants.analysisImageSize))
            guard let resizedCIImage = CIImage(image: resizedImage) else {
                throw ImageServiceError.invalidImage
            }

            // 色抽出用のフィルター
            let filter = CIFilter.areaAverage()
            filter.inputImage = resizedCIImage
            filter.extent = resizedCIImage.extent

            // K-means風の色抽出（簡易版）
            return try await self.extractDominantColors(from: resizedCIImage, maxCount: maxCount)
        }.value
    }
    
    private func extractDominantColors(from ciImage: CIImage, maxCount: Int) async throws -> [String] {
        // Core Imageを使用して色を抽出
        // 画像をグリッドに分割して各セルの平均色を取得
        let extent = ciImage.extent
        let gridSize = min(maxCount, 5) // 最大5色
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
                
                // CGImageから色を取得
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
        
        // 出現頻度の高い色をソートして返す
        let sortedColors = colorMap.sorted { $0.value > $1.value }
        return Array(sortedColors.prefix(maxCount).map { $0.key })
    }
    
    func calculateColorTemperature(_ image: UIImage) async throws -> Int {
        return try await Task.detached(priority: .userInitiated) {
            guard let ciImage = CIImage(image: image) else {
                throw ImageServiceError.invalidImage
            }

            // 画像をリサイズして処理を高速化
            let resizedImage = try await self.resizeImage(image, maxSize: CGSize(width: Constants.analysisImageSize, height: Constants.analysisImageSize))
            guard let resizedCIImage = CIImage(image: resizedImage) else {
                throw ImageServiceError.invalidImage
            }

            // 平均色を取得
            let filter = CIFilter.areaAverage()
            filter.inputImage = resizedCIImage
            filter.extent = resizedCIImage.extent

            guard let outputImage = filter.outputImage,
                  let cgImage = self.context.createCGImage(outputImage, from: resizedCIImage.extent) else {
                throw ImageServiceError.processingFailed
            }

            // CGImageからRGB値を取得
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

            // RGBから色温度を計算（簡易版）
            // McCamy's formulaを使用
            let n = (r - Constants.mccamyConstantR) / (Constants.mccamyConstantB - b)
            let colorTemperature = 449.0 * pow(n, 3.0) + 3525.0 * pow(n, 2.0) + 6823.3 * n + 5520.33

            // 範囲を制限
            return max(Constants.minColorTemperature, min(Constants.maxColorTemperature, Int(colorTemperature)))
        }.value
    }
    
    func detectSkyType(_ image: UIImage) async throws -> SkyType {
        return try await Task.detached(priority: .userInitiated) {
            guard let ciImage = CIImage(image: image) else {
                throw ImageServiceError.invalidImage
            }

            // 画像をリサイズして処理を高速化
            let resizedImage = try await self.resizeImage(image, maxSize: CGSize(width: Constants.analysisImageSize, height: Constants.analysisImageSize))
            guard let resizedCIImage = CIImage(image: resizedImage) else {
                throw ImageServiceError.invalidImage
            }

            // 色温度を取得
            let colorTemperature = try await self.calculateColorTemperature(resizedImage)

            // 色分布を分析
            let colors = try await self.extractColors(resizedImage, maxCount: 5)

            // HSV色空間での分析
            let hsvAnalysis = try await self.analyzeHSV(resizedCIImage)

            // 判定ロジック
            return self.determineSkyType(
                colorTemperature: colorTemperature,
                colors: colors,
                hsvAnalysis: hsvAnalysis
            )
        }.value
    }
    
    private func analyzeHSV(_ ciImage: CIImage) async throws -> (hue: Double, saturation: Double, brightness: Double) {
        // 平均色を取得
        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage
        filter.extent = ciImage.extent
        
        guard let outputImage = filter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: ciImage.extent) else {
            throw ImageServiceError.processingFailed
        }
        
        // CGImageからRGB値を取得
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
        
        // RGBからHSVに変換
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
        
        // 夕焼け/朝焼け判定（オレンジ・赤系、低色温度）
        if colorTemperature < 4000 && (hue >= 0 && hue <= 60 || hue >= 300 && hue <= 360) {
            // 時間帯で判定できないため、色温度と色相で判定
            // より暖色寄りなら夕焼け、やや暖色なら朝焼け
            if colorTemperature < 3000 {
                return .sunset
            } else {
                return .sunrise
            }
        }
        
        // 嵐判定（暗い、コントラストが高い）
        if brightness < Constants.lowBrightnessThreshold && saturation > Constants.highSaturationThreshold {
            return .storm
        }
        
        // 曇り判定（グレー系、低彩度）
        if saturation < 0.3 {
            return .cloudy
        }
        
        // 晴れ判定（青系、高色温度）
        if colorTemperature >= 5000 && (hue >= 180 && hue <= 240) {
            return .clear
        }
        
        // デフォルトは晴れ
        return .clear
    }
    
    func extractEXIFData(_ image: UIImage) async throws -> EXIFData {
        return try await Task.detached(priority: .userInitiated) {
            guard let imageData = image.jpegData(compressionQuality: 1.0),
                  let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
                throw ImageServiceError.invalidImage
            }

            guard let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
                // EXIF情報がない場合は空のデータを返す
                return EXIFData()
            }

            // EXIF情報を取得
            let exifDict = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let tiffDict = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]

            // 撮影時刻
            var capturedAt: Date?
            if let dateTimeOriginal = exifDict?[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                capturedAt = formatter.date(from: dateTimeOriginal)
            }

            // カメラモデル
            let cameraModel = tiffDict?[kCGImagePropertyTIFFModel as String] as? String

            // ISO感度
            let iso = exifDict?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int]
            let isoValue = iso?.first

            // シャッタースピード
            var shutterSpeed: String?
            if let exposureTime = exifDict?[kCGImagePropertyExifExposureTime as String] as? Double {
                shutterSpeed = String(format: "1/%.0f", 1.0 / exposureTime)
            }

            // 絞り値
            var aperture: String?
            if let fNumber = exifDict?[kCGImagePropertyExifFNumber as String] as? Double {
                aperture = String(format: "f/%.1f", fNumber)
            }

            // 焦点距離
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
        }.value
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

