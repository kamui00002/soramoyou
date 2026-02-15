//
//  SkyTypeClassifier.swift
//  Soramoyou
//
//  AI空タイプ自動判定サービス ☁️
//  色分析ベースの空の種類自動判定を実装
//  Created on 2025-12-06.
//

import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - SkyTypeClassificationResult

/// 空タイプ判定結果
struct SkyTypeClassificationResult {
    /// 判定された空の種類
    let skyType: SkyType
    /// 信頼度（0.0 ~ 1.0）
    let confidence: Double
    /// 判定に使用した主要色
    let dominantColors: [DominantColor]
    /// 時間帯情報を使用したかどうか
    let usedTimeOfDay: Bool
    /// 補足情報
    let details: String

    /// 信頼度をパーセント表示
    var confidencePercentage: Int {
        return Int(confidence * 100)
    }
}

/// 主要色情報
struct DominantColor {
    let hex: String
    let percentage: Double
    let category: ColorCategory
}

/// 色カテゴリ
enum ColorCategory: String {
    case blue = "青"
    case orange = "オレンジ"
    case red = "赤"
    case yellow = "黄"
    case pink = "ピンク"
    case purple = "紫"
    case gray = "グレー"
    case white = "白"
    case black = "黒"
    case cyan = "シアン"

    /// SF Symbolsアイコン
    var iconName: String {
        switch self {
        case .blue: return "drop.fill"
        case .orange: return "sun.max.fill"
        case .red: return "flame.fill"
        case .yellow: return "sun.min.fill"
        case .pink: return "heart.fill"
        case .purple: return "moon.stars.fill"
        case .gray: return "cloud.fill"
        case .white: return "cloud"
        case .black: return "moon.fill"
        case .cyan: return "wind"
        }
    }
}

// MARK: - SkyTypeClassifierProtocol

protocol SkyTypeClassifierProtocol {
    /// 画像から空の種類を自動判定
    /// - Parameters:
    ///   - image: 判定対象の画像
    ///   - timeOfDay: 時間帯情報（精度向上に使用）
    /// - Returns: 判定結果
    func classify(_ image: UIImage, timeOfDay: TimeOfDay?) async throws -> SkyTypeClassificationResult
}

// MARK: - SkyTypeClassifier

/// 色分析ベースの空タイプ分類器 ☁️
class SkyTypeClassifier: SkyTypeClassifierProtocol {

    private let context: CIContext

    init() {
        // Metal GPU アクセラレーションを使用
        if let device = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: device)
        } else {
            self.context = CIContext()
        }
    }

    // MARK: - Public Methods

    func classify(_ image: UIImage, timeOfDay: TimeOfDay?) async throws -> SkyTypeClassificationResult {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    // 1. 画像をリサイズして処理を高速化
                    let resizedImage = try await self.resizeImage(image, maxSize: CGSize(width: 256, height: 256))

                    guard let ciImage = CIImage(image: resizedImage) else {
                        throw SkyTypeClassifierError.invalidImage
                    }

                    // 2. 画像上部（空部分）を分析
                    let skyRegion = self.extractSkyRegion(from: ciImage)

                    // 3. 主要色を抽出
                    let dominantColors = try await self.extractDominantColors(from: skyRegion)

                    // 4. 色分布を分析
                    let colorDistribution = self.analyzeColorDistribution(dominantColors)

                    // 5. HSV分析
                    let hsvAnalysis = try await self.analyzeAverageHSV(from: skyRegion)

                    // 6. 空タイプを判定
                    let result = self.determineSkyType(
                        colorDistribution: colorDistribution,
                        hsvAnalysis: hsvAnalysis,
                        dominantColors: dominantColors,
                        timeOfDay: timeOfDay
                    )

                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Methods

    /// 画像をリサイズ
    private func resizeImage(_ image: UIImage, maxSize: CGSize) async throws -> UIImage {
        let size = image.size
        let aspectRatio = size.width / size.height

        var newSize: CGSize
        if size.width > size.height {
            newSize = CGSize(width: min(size.width, maxSize.width), height: min(size.width, maxSize.width) / aspectRatio)
        } else {
            newSize = CGSize(width: min(size.height, maxSize.height) * aspectRatio, height: min(size.height, maxSize.height))
        }

        // CIContextベースのリサイズ（バックグラウンドスレッドセーフ）
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        let scaleX = newSize.width / ciImage.extent.width
        let scaleY = newSize.height / ciImage.extent.height
        let scale = min(scaleX, scaleY)

        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let outputCGImage = context.createCGImage(scaled, from: scaled.extent) else { return image }

        return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
    }

    /// 画像上部（空部分）を抽出
    private func extractSkyRegion(from ciImage: CIImage) -> CIImage {
        let extent = ciImage.extent
        // 上部60%を空として抽出
        let skyHeight = extent.height * 0.6
        let skyRect = CGRect(
            x: extent.origin.x,
            y: extent.origin.y + extent.height * 0.4,
            width: extent.width,
            height: skyHeight
        )
        return ciImage.cropped(to: skyRect)
    }

    /// 主要色を抽出
    private func extractDominantColors(from ciImage: CIImage) async throws -> [DominantColor] {
        let extent = ciImage.extent
        let gridSize = 4 // 4x4グリッドで分析
        let cellWidth = extent.width / CGFloat(gridSize)
        let cellHeight = extent.height / CGFloat(gridSize)

        var colorCounts: [String: Int] = [:]
        var totalCells = 0

        for i in 0..<gridSize {
            for j in 0..<gridSize {
                let cellRect = CGRect(
                    x: extent.origin.x + CGFloat(i) * cellWidth,
                    y: extent.origin.y + CGFloat(j) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )

                if let color = getAverageColor(from: ciImage, rect: cellRect) {
                    let quantizedHex = quantizeColor(color)
                    colorCounts[quantizedHex, default: 0] += 1
                    totalCells += 1
                }
            }
        }

        // 出現頻度でソートし、上位5色を返す
        let sortedColors = colorCounts.sorted { $0.value > $1.value }

        return sortedColors.prefix(5).map { hex, count in
            let percentage = Double(count) / Double(max(totalCells, 1))
            let category = categorizeColor(hex: hex)
            return DominantColor(hex: hex, percentage: percentage, category: category)
        }
    }

    /// セルの平均色を取得
    private func getAverageColor(from ciImage: CIImage, rect: CGRect) -> (r: Int, g: Int, b: Int)? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage.cropped(to: rect)
        filter.extent = rect

        guard let outputImage = filter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: CGRect(x: 0, y: 0, width: 1, height: 1)) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: 4)

        guard let pixelContext = CGContext(
            data: &pixelData,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }

        pixelContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return (r: Int(pixelData[0]), g: Int(pixelData[1]), b: Int(pixelData[2]))
    }

    /// 色を量子化（類似色をまとめる）
    private func quantizeColor(_ color: (r: Int, g: Int, b: Int)) -> String {
        // 32段階に量子化
        let step = 8
        let r = (color.r / step) * step
        let g = (color.g / step) * step
        let b = (color.b / step) * step
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// 色をカテゴリに分類
    private func categorizeColor(hex: String) -> ColorCategory {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        // HSVに変換
        let maxVal = max(r, g, b)
        let minVal = min(r, g, b)
        let delta = maxVal - minVal

        var h: Double = 0
        if delta != 0 {
            if maxVal == r {
                h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxVal == g {
                h = 60 * (((b - r) / delta) + 2)
            } else {
                h = 60 * (((r - g) / delta) + 4)
            }
        }
        if h < 0 { h += 360 }

        let s = maxVal == 0 ? 0 : delta / maxVal
        let v = maxVal

        // 明度と彩度でグレー/白/黒を判定
        if s < 0.1 {
            if v > 0.9 { return .white }
            if v < 0.2 { return .black }
            return .gray
        }

        // 色相で分類
        switch h {
        case 0..<15, 345..<360:
            return .red
        case 15..<45:
            return .orange
        case 45..<70:
            return .yellow
        case 70..<165:
            return v > 0.7 && s < 0.5 ? .cyan : .cyan
        case 165..<200:
            return .cyan
        case 200..<260:
            return .blue
        case 260..<290:
            return .purple
        case 290..<345:
            return s < 0.5 ? .pink : .pink
        default:
            return .gray
        }
    }

    /// 色分布を分析
    private func analyzeColorDistribution(_ colors: [DominantColor]) -> ColorDistribution {
        var distribution = ColorDistribution()

        for color in colors {
            switch color.category {
            case .blue, .cyan:
                distribution.blueScore += color.percentage
            case .orange, .yellow, .red:
                distribution.warmScore += color.percentage
            case .pink, .purple:
                distribution.pinkPurpleScore += color.percentage
            case .gray:
                distribution.grayScore += color.percentage
            case .white:
                distribution.whiteScore += color.percentage
            case .black:
                distribution.darkScore += color.percentage
            }
        }

        return distribution
    }

    /// 平均HSVを分析
    private func analyzeAverageHSV(from ciImage: CIImage) async throws -> HSVAnalysis {
        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage
        filter.extent = ciImage.extent

        guard let outputImage = filter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: ciImage.extent) else {
            throw SkyTypeClassifierError.processingFailed
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: 4)

        guard let pixelContext = CGContext(
            data: &pixelData,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw SkyTypeClassifierError.processingFailed
        }

        pixelContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let r = Double(pixelData[0]) / 255.0
        let g = Double(pixelData[1]) / 255.0
        let b = Double(pixelData[2]) / 255.0

        // RGBからHSVに変換
        let maxVal = max(r, g, b)
        let minVal = min(r, g, b)
        let delta = maxVal - minVal

        var h: Double = 0
        if delta != 0 {
            if maxVal == r {
                h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxVal == g {
                h = 60 * (((b - r) / delta) + 2)
            } else {
                h = 60 * (((r - g) / delta) + 4)
            }
        }
        if h < 0 { h += 360 }

        let s = maxVal == 0 ? 0 : delta / maxVal
        let v = maxVal

        return HSVAnalysis(hue: h, saturation: s, brightness: v)
    }

    /// 空タイプを判定
    private func determineSkyType(
        colorDistribution: ColorDistribution,
        hsvAnalysis: HSVAnalysis,
        dominantColors: [DominantColor],
        timeOfDay: TimeOfDay?
    ) -> SkyTypeClassificationResult {

        var scores: [(SkyType, Double, String)] = []

        // 晴れ（clear）の判定
        let clearScore = calculateClearScore(colorDistribution: colorDistribution, hsvAnalysis: hsvAnalysis)
        scores.append((.clear, clearScore, "青系の色が支配的"))

        // 曇り（cloudy）の判定
        let cloudyScore = calculateCloudyScore(colorDistribution: colorDistribution, hsvAnalysis: hsvAnalysis)
        scores.append((.cloudy, cloudyScore, "グレー/白が支配的、低彩度"))

        // 夕焼け（sunset）の判定
        let sunsetScore = calculateSunsetScore(colorDistribution: colorDistribution, hsvAnalysis: hsvAnalysis, timeOfDay: timeOfDay)
        scores.append((.sunset, sunsetScore, "暖色系が支配的"))

        // 朝焼け（sunrise）の判定
        let sunriseScore = calculateSunriseScore(colorDistribution: colorDistribution, hsvAnalysis: hsvAnalysis, timeOfDay: timeOfDay)
        scores.append((.sunrise, sunriseScore, "暖色とピンク系が混在"))

        // 嵐（storm）の判定
        let stormScore = calculateStormScore(colorDistribution: colorDistribution, hsvAnalysis: hsvAnalysis)
        scores.append((.storm, stormScore, "暗い色が支配的"))

        // 最高スコアを選択
        scores.sort { $0.1 > $1.1 }
        let bestMatch = scores[0]

        // 信頼度を計算（最高スコアと2番目のスコアの差を考慮）
        let confidence: Double
        if scores.count > 1 {
            let topScore = bestMatch.1
            let secondScore = scores[1].1
            let diff = topScore - secondScore
            // 差が大きいほど信頼度が高い
            confidence = min(1.0, topScore * (1 + diff))
        } else {
            confidence = bestMatch.1
        }

        return SkyTypeClassificationResult(
            skyType: bestMatch.0,
            confidence: confidence,
            dominantColors: dominantColors,
            usedTimeOfDay: timeOfDay != nil,
            details: bestMatch.2
        )
    }

    // MARK: - Score Calculations

    /// 晴れスコアを計算
    private func calculateClearScore(colorDistribution: ColorDistribution, hsvAnalysis: HSVAnalysis) -> Double {
        var score = 0.0

        // 青系の色が多いほどスコアが高い
        score += colorDistribution.blueScore * 0.6

        // 彩度が高いとボーナス
        if hsvAnalysis.saturation > 0.3 {
            score += 0.2
        }

        // 明度が中程度以上
        if hsvAnalysis.brightness > 0.4 && hsvAnalysis.brightness < 0.95 {
            score += 0.2
        }

        // 色相が青系（200-260度）
        if hsvAnalysis.hue >= 180 && hsvAnalysis.hue <= 260 {
            score += 0.2
        }

        return min(1.0, score)
    }

    /// 曇りスコアを計算
    private func calculateCloudyScore(colorDistribution: ColorDistribution, hsvAnalysis: HSVAnalysis) -> Double {
        var score = 0.0

        // グレー/白が多いほどスコアが高い
        score += (colorDistribution.grayScore + colorDistribution.whiteScore) * 0.5

        // 彩度が低いほどスコアが高い
        if hsvAnalysis.saturation < 0.2 {
            score += 0.3
        } else if hsvAnalysis.saturation < 0.35 {
            score += 0.15
        }

        // 明度が中程度（暗すぎず明るすぎず）
        if hsvAnalysis.brightness > 0.3 && hsvAnalysis.brightness < 0.85 {
            score += 0.2
        }

        return min(1.0, score)
    }

    /// 夕焼けスコアを計算
    private func calculateSunsetScore(colorDistribution: ColorDistribution, hsvAnalysis: HSVAnalysis, timeOfDay: TimeOfDay?) -> Double {
        var score = 0.0

        // 暖色が多いほどスコアが高い
        score += colorDistribution.warmScore * 0.5

        // 色相がオレンジ〜赤系（0-60度 or 330-360度）
        if (hsvAnalysis.hue >= 0 && hsvAnalysis.hue <= 60) || (hsvAnalysis.hue >= 300) {
            score += 0.25
        }

        // 彩度が中程度以上
        if hsvAnalysis.saturation > 0.3 {
            score += 0.15
        }

        // 時間帯が夕方ならボーナス
        if timeOfDay == .evening {
            score += 0.2
        }

        // ピンク/紫も夕焼けの特徴
        score += colorDistribution.pinkPurpleScore * 0.2

        return min(1.0, score)
    }

    /// 朝焼けスコアを計算
    private func calculateSunriseScore(colorDistribution: ColorDistribution, hsvAnalysis: HSVAnalysis, timeOfDay: TimeOfDay?) -> Double {
        var score = 0.0

        // 暖色とピンク系が混在
        score += colorDistribution.warmScore * 0.3
        score += colorDistribution.pinkPurpleScore * 0.3

        // 色相がピンク〜オレンジ系（0-45度 or 300-360度）
        if (hsvAnalysis.hue >= 0 && hsvAnalysis.hue <= 45) || (hsvAnalysis.hue >= 280) {
            score += 0.2
        }

        // 時間帯が朝ならボーナス
        if timeOfDay == .morning {
            score += 0.25
        }

        // 明度が比較的高い（朝は夕方より明るい傾向）
        if hsvAnalysis.brightness > 0.5 {
            score += 0.1
        }

        return min(1.0, score)
    }

    /// 嵐スコアを計算
    private func calculateStormScore(colorDistribution: ColorDistribution, hsvAnalysis: HSVAnalysis) -> Double {
        var score = 0.0

        // 暗い色が多いほどスコアが高い
        score += colorDistribution.darkScore * 0.4
        score += colorDistribution.grayScore * 0.3

        // 明度が低い
        if hsvAnalysis.brightness < 0.35 {
            score += 0.3
        } else if hsvAnalysis.brightness < 0.5 {
            score += 0.15
        }

        // 彩度が低い（嵐は彩度が低い傾向）
        if hsvAnalysis.saturation < 0.3 {
            score += 0.15
        }

        return min(1.0, score)
    }
}

// MARK: - Helper Structures

/// 色分布
private struct ColorDistribution {
    var blueScore: Double = 0
    var warmScore: Double = 0
    var pinkPurpleScore: Double = 0
    var grayScore: Double = 0
    var whiteScore: Double = 0
    var darkScore: Double = 0
}

/// HSV分析結果
private struct HSVAnalysis {
    let hue: Double        // 0-360
    let saturation: Double // 0-1
    let brightness: Double // 0-1
}

// MARK: - SkyTypeClassifierError

enum SkyTypeClassifierError: LocalizedError {
    case invalidImage
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "無効な画像です"
        case .processingFailed:
            return "画像処理に失敗しました"
        }
    }
}
