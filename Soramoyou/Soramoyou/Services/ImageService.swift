// ⭐️ ImageService.swift
// 画像処理サービス
// 全27種類の編集ツール実装 + 高速プレビュー生成
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
import Metal

protocol ImageServiceProtocol {
    // Filter
    func applyFilter(_ filter: FilterType, to image: UIImage) async throws -> UIImage

    // Edit Tools
    func applyEditTool(_ tool: EditTool, value: Float, to image: UIImage) async throws -> UIImage
    func applyEditSettings(_ settings: EditSettings, to image: UIImage) async throws -> UIImage

    // Preview
    func generatePreview(_ image: UIImage, edits: EditSettings) async throws -> UIImage
    /// 高速プレビュー生成（256x256の低解像度）
    /// スライダー操作中のリアルタイム表示用
    func generatePreviewFast(_ image: UIImage, edits: EditSettings) async throws -> UIImage

    /// CIImageベースの高速プレビュー生成（同期処理）
    /// 既にリサイズ済みのCIImageを受け取り、フィルターチェーンを適用して一度だけレンダリング
    func generatePreviewFromCIImage(_ ciImage: CIImage, edits: EditSettings) -> UIImage?

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

class ImageService: ImageServiceProtocol {
    private let context: CIContext

    init(context: CIContext? = nil) {
        if let context = context {
            self.context = context
        } else if let device = MTLCreateSystemDefaultDevice() {
            // Metal GPU アクセラレーションを使用（大幅に高速化）
            self.context = CIContext(mtlDevice: device)
        } else {
            // Metal が利用できない場合はCPUフォールバック
            self.context = CIContext()
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

    // MARK: - Edit Tools

    func applyEditTool(_ tool: EditTool, value: Float, to image: UIImage) async throws -> UIImage {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    guard let ciImage = CIImage(image: image) else {
                        throw ImageServiceError.invalidImage
                    }

                    let editedImage = self.processEditTool(tool, value: value, on: ciImage)

                    guard let cgImage = self.context.createCGImage(editedImage, from: editedImage.extent) else {
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

    /// 全27種類の編集ツールを処理
    private func processEditTool(_ tool: EditTool, value: Float, on ciImage: CIImage) -> CIImage {
        let v = max(-1.0, min(1.0, value))

        switch tool {
        case .exposure:          return applyExposure(v, to: ciImage)
        case .brightness:        return applyBrightness(v, to: ciImage)
        case .contrast:          return applyContrast(v, to: ciImage)
        case .tone:              return applyTone(v, to: ciImage)
        case .brilliance:        return applyBrilliance(v, to: ciImage)
        case .highlight:         return applyHighlight(v, to: ciImage)
        case .shadow:            return applyShadow(v, to: ciImage)
        case .blackPoint:        return applyBlackPoint(v, to: ciImage)
        case .saturation:        return applySaturation(v, to: ciImage)
        case .naturalSaturation: return applyNaturalSaturation(v, to: ciImage)
        case .warmth:            return applyWarmth(v, to: ciImage)
        case .tint:              return applyTint(v, to: ciImage)
        case .sharpness:         return applySharpness(v, to: ciImage)
        case .vignette:          return applyVignette(v, to: ciImage)
        case .colorTemperature:  return applyColorTemperature(v, to: ciImage)
        case .whiteBalance:      return applyWhiteBalance(v, to: ciImage)
        case .texture:           return applyTexture(v, to: ciImage)
        case .clarity:           return applyClarity(v, to: ciImage)
        case .dehaze:            return applyDehaze(v, to: ciImage)
        case .grain:             return applyGrain(v, to: ciImage)
        case .fade:              return applyFade(v, to: ciImage)
        case .noiseReduction:    return applyNoiseReduction(v, to: ciImage)
        case .curves:            return applyCurves(v, to: ciImage)
        case .hsl:               return applyHSL(v, to: ciImage)
        case .lensCorrection:    return applyLensCorrection(v, to: ciImage)
        case .doubleExposure:    return applyDoubleExposure(v, to: ciImage)
        case .cropAndRotate:     return ciImage
        }
    }

    // MARK: - 編集ツール実装（全27種類）

    // ── 1. 露出（Exposure）──
    /// EV値を調整（-2.0〜+2.0）
    private func applyExposure(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = image
        filter.ev = value * 2.0
        return filter.outputImage ?? image
    }

    // ── 2. 明るさ（Brightness）──
    /// 画像全体の明度を調整（-1.0〜+1.0）
    private func applyBrightness(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.brightness = value * 0.5
        return filter.outputImage ?? image
    }

    // ── 3. コントラスト（Contrast）──
    /// 明暗差を調整（0.5〜1.5）
    private func applyContrast(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.contrast = 1.0 + value * 0.5
        return filter.outputImage ?? image
    }

    // ── 4. トーン（Tone）──
    /// ガンマカーブで中間調を調整
    /// 正値：中間調を明るく、負値：中間調を暗く
    private func applyTone(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.gammaAdjust()
        filter.inputImage = image
        // gamma < 1.0 で明るく、> 1.0 で暗く
        // value = -1.0 → gamma = 1.5（暗い）, value = 1.0 → gamma = 0.5（明るい）
        filter.power = 1.0 - value * 0.5
        return filter.outputImage ?? image
    }

    // ── 5. ブリリアンス（Brilliance）──
    /// 暗部を持ち上げつつハイライトを維持（スマート露出補正）
    /// シャドウを明るく + わずかにコントラスト追加
    private func applyBrilliance(_ value: Float, to image: CIImage) -> CIImage {
        // ハイライト・シャドウ調整で暗部を持ち上げ
        let hsFilter = CIFilter.highlightShadowAdjust()
        hsFilter.inputImage = image
        hsFilter.shadowAmount = 1.0 + value * 0.5
        hsFilter.highlightAmount = 1.0 - value * 0.3
        guard let step1 = hsFilter.outputImage else { return image }

        // わずかにコントラストを追加
        let ccFilter = CIFilter.colorControls()
        ccFilter.inputImage = step1
        ccFilter.contrast = 1.0 + value * 0.15
        return ccFilter.outputImage ?? step1
    }

    // ── 6. ハイライト（Highlight）──
    /// 明るい部分の明度を調整
    private func applyHighlight(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.highlightShadowAdjust()
        filter.inputImage = image
        // highlightAmount: 0.0（完全抑制）〜 1.0（通常）
        // value=-1 → 0.0, value=0 → 1.0, value=1 → 2.0
        filter.highlightAmount = 1.0 + value
        return filter.outputImage ?? image
    }

    // ── 7. シャドウ（Shadow）──
    /// 暗い部分の明度を調整
    private func applyShadow(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.highlightShadowAdjust()
        filter.inputImage = image
        // shadowAmount: -1.0〜1.0 → 0.0〜2.0
        filter.shadowAmount = 1.0 + value
        return filter.outputImage ?? image
    }

    // ── 8. ブラックポイント（Black Point）──
    /// 最も暗い点のレベルを調整
    /// 正値：黒を持ち上げて軽やかに、負値：黒をより深く
    private func applyBlackPoint(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        // ブラックポイントを持ち上げる（正値）または下げる（負値）
        let offset = value * 0.15
        filter.biasVector = CIVector(x: CGFloat(offset), y: CGFloat(offset), z: CGFloat(offset), w: 0)
        filter.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return filter.outputImage ?? image
    }

    // ── 9. 彩度（Saturation）──
    /// 全体的な色の鮮やかさを調整
    private func applySaturation(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        // value=-1 → 0.0（モノクロ）, value=0 → 1.0, value=1 → 2.0
        filter.saturation = 1.0 + value
        return filter.outputImage ?? image
    }

    // ── 10. 自然な彩度（Natural Saturation / Vibrance）──
    /// 彩度が低い色を優先的に鮮やかにする（肌色を保護）
    private func applyNaturalSaturation(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.vibrance()
        filter.inputImage = image
        // CIVibrance の amount: -1.0〜1.0
        filter.amount = value
        return filter.outputImage ?? image
    }

    // ── 11. 暖かみ（Warmth）──
    /// 暖色（オレンジ）⇔ 寒色（ブルー）のシフト
    private func applyWarmth(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: 0)
        // 正値で暖色（低いK値方向）、負値で寒色（高いK値方向）
        filter.targetNeutral = CIVector(x: 6500 - Double(value * 1500), y: 0)
        return filter.outputImage ?? image
    }

    // ── 12. 色合い（Tint）──
    /// グリーン ⇔ マゼンタのシフト
    private func applyTint(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: 0)
        // Y成分がティント（グリーン−マゼンタ軸）
        filter.targetNeutral = CIVector(x: 6500, y: Double(value * 100))
        return filter.outputImage ?? image
    }

    // ── 13. シャープネス（Sharpness）──
    /// エッジの鮮明さを調整
    private func applySharpness(_ value: Float, to image: CIImage) -> CIImage {
        if value >= 0 {
            // 正値：シャープ強化
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = value * 2.0
            filter.radius = 1.5
            return filter.outputImage ?? image
        } else {
            // 負値：ソフト化（ガウスぼかし）
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = image
            filter.radius = Float(abs(value) * 3.0)
            return filter.outputImage ?? image
        }
    }

    // ── 14. ビネット（Vignette）──
    /// 画像の四隅を暗く/明るく
    private func applyVignette(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.vignette()
        filter.inputImage = image
        // 正値で四隅を暗く、負値で四隅を明るく
        filter.intensity = value * 2.0
        filter.radius = 1.0 + abs(value)
        return filter.outputImage ?? image
    }

    // ── 15. 色温度（Color Temperature）──
    /// ケルビン単位の色温度調整（暖かみより広い範囲）
    private func applyColorTemperature(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: 0)
        // 広い範囲で調整：3500K〜9500K
        filter.targetNeutral = CIVector(x: 6500 - Double(value * 3000), y: 0)
        return filter.outputImage ?? image
    }

    // ── 16. ホワイトバランス（White Balance）──
    /// 温度+ティントの複合調整
    private func applyWhiteBalance(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        // ニュートラルポイントをシフト
        filter.neutral = CIVector(x: 6500 + Double(value * 2000), y: Double(value * 30))
        filter.targetNeutral = CIVector(x: 6500, y: 0)
        return filter.outputImage ?? image
    }

    // ── 17. テクスチャ（Texture）──
    /// 細部のディテールを強調/抑制（中程度の半径でアンシャープマスク）
    private func applyTexture(_ value: Float, to image: CIImage) -> CIImage {
        if value >= 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = 2.0
            filter.intensity = value * 1.5
            return filter.outputImage ?? image
        } else {
            // 負値：テクスチャを滑らかに
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = image
            filter.radius = Float(abs(value) * 2.0)
            return filter.outputImage ?? image
        }
    }

    // ── 18. クラリティ（Clarity）──
    /// 中間調のコントラストを強調（大きな半径でアンシャープマスク）
    private func applyClarity(_ value: Float, to image: CIImage) -> CIImage {
        if value >= 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = 10.0
            filter.intensity = value * 1.0
            return filter.outputImage ?? image
        } else {
            // 負値：中間調コントラストを低下
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = 10.0
            filter.intensity = value * 0.5
            return filter.outputImage ?? image
        }
    }

    // ── 19. かすみの除去（Dehaze）──
    /// コントラスト + 彩度を上げてかすみを除去
    private func applyDehaze(_ value: Float, to image: CIImage) -> CIImage {
        // コントラスト調整
        let ccFilter = CIFilter.colorControls()
        ccFilter.inputImage = image
        ccFilter.contrast = 1.0 + value * 0.4
        ccFilter.saturation = 1.0 + value * 0.2
        guard let step1 = ccFilter.outputImage else { return image }

        // 露出を微調整（かすみ除去時にわずかに暗く）
        let expFilter = CIFilter.exposureAdjust()
        expFilter.inputImage = step1
        expFilter.ev = -value * 0.3
        return expFilter.outputImage ?? step1
    }

    // ── 20. グレイン（Grain / Film Grain）──
    /// フィルム風のノイズを追加
    private func applyGrain(_ value: Float, to image: CIImage) -> CIImage {
        guard abs(value) > 0.01 else { return image }

        let extent = image.extent

        // ランダムノイズを生成
        let noiseFilter = CIFilter.randomGenerator()
        guard let noise = noiseFilter.outputImage?.cropped(to: extent) else { return image }

        // ノイズをモノクロ化
        let monoFilter = CIFilter.colorMatrix()
        monoFilter.inputImage = noise
        let noiseLevel = CGFloat(abs(value) * 0.15)
        monoFilter.rVector = CIVector(x: noiseLevel, y: 0, z: 0, w: 0)
        monoFilter.gVector = CIVector(x: 0, y: noiseLevel, z: 0, w: 0)
        monoFilter.bVector = CIVector(x: 0, y: 0, z: noiseLevel, w: 0)
        monoFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        monoFilter.biasVector = CIVector(x: CGFloat(-abs(value) * 0.075), y: CGFloat(-abs(value) * 0.075), z: CGFloat(-abs(value) * 0.075), w: 0)
        guard let monoNoise = monoFilter.outputImage else { return image }

        // 元画像にノイズを加算合成
        let blendFilter = CIFilter.additionCompositing()
        blendFilter.inputImage = monoNoise
        blendFilter.backgroundImage = image
        return blendFilter.outputImage?.cropped(to: extent) ?? image
    }

    // ── 21. フェード（Fade）──
    /// 黒を持ち上げてコントラストを下げ、フィルム風の退色効果
    private func applyFade(_ value: Float, to image: CIImage) -> CIImage {
        guard abs(value) > 0.01 else { return image }

        // 黒レベルを持ち上げ
        let matrixFilter = CIFilter.colorMatrix()
        matrixFilter.inputImage = image
        let lift = abs(value) * 0.2
        matrixFilter.biasVector = CIVector(x: CGFloat(lift), y: CGFloat(lift), z: CGFloat(lift), w: 0)
        // コントラストを下げる（RGB係数を1未満に）
        let scale = 1.0 - abs(value) * 0.15
        matrixFilter.rVector = CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0)
        matrixFilter.gVector = CIVector(x: 0, y: CGFloat(scale), z: 0, w: 0)
        matrixFilter.bVector = CIVector(x: 0, y: 0, z: CGFloat(scale), w: 0)
        matrixFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return matrixFilter.outputImage ?? image
    }

    // ── 22. ノイズリダクション（Noise Reduction）──
    /// ノイズを低減してスムーズな画像に
    private func applyNoiseReduction(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.noiseReduction()
        filter.inputImage = image
        // noiseLevel: 0.0〜0.1
        filter.noiseLevel = abs(value) * 0.05
        // sharpness: ノイズ除去後のシャープネス補正
        filter.sharpness = 0.5 + abs(value) * 0.3
        return filter.outputImage ?? image
    }

    // ── 23. カーブ調整（Curves）──
    /// S字カーブ（コントラスト強調）/ 逆S字カーブ（コントラスト低下）
    private func applyCurves(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        // S字カーブの強さを value で制御
        let shift = value * 0.15
        filter.point0 = CGPoint(x: 0.0, y: CGFloat(max(0, 0.0 - shift)))
        filter.point1 = CGPoint(x: 0.25, y: CGFloat(max(0, min(1, 0.25 - shift))))
        filter.point2 = CGPoint(x: 0.5, y: 0.5)
        filter.point3 = CGPoint(x: 0.75, y: CGFloat(max(0, min(1, 0.75 + shift))))
        filter.point4 = CGPoint(x: 1.0, y: CGFloat(min(1, 1.0 + shift)))
        return filter.outputImage ?? image
    }

    // ── 24. HSL調整（Hue Shift）──
    /// 色相をシフト（-180°〜+180°）
    private func applyHSL(_ value: Float, to image: CIImage) -> CIImage {
        let filter = CIFilter.hueAdjust()
        filter.inputImage = image
        // ラジアンで指定：value * π
        filter.angle = value * .pi
        return filter.outputImage ?? image
    }

    // ── 25. レンズ補正（Lens Correction）──
    /// 樽型/糸巻き型歪みを補正
    private func applyLensCorrection(_ value: Float, to image: CIImage) -> CIImage {
        guard abs(value) > 0.01 else { return image }

        let extent = image.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let radius = Float(min(extent.width, extent.height)) * 0.5

        let filter = CIFilter.bumpDistortion()
        filter.inputImage = image
        filter.center = center
        filter.radius = radius
        // 正値：樽型補正（膨らみ除去）、負値：糸巻き型補正
        filter.scale = -value * 0.3
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    // ── 26. 二重露光風合成（Double Exposure）──
    /// 元画像のぼかし版をスクリーンブレンドして幻想的な効果
    private func applyDoubleExposure(_ value: Float, to image: CIImage) -> CIImage {
        guard abs(value) > 0.01 else { return image }

        // ぼかし版を生成
        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = image
        blurFilter.radius = 15.0
        guard let blurred = blurFilter.outputImage?.cropped(to: image.extent) else { return image }

        // スクリーンブレンド
        let screenFilter = CIFilter.screenBlendMode()
        screenFilter.inputImage = blurred
        screenFilter.backgroundImage = image
        guard let blended = screenFilter.outputImage else { return image }

        // 元画像とブレンド結果をvalue量でミックス
        let amount = abs(value)
        let mixFilter = CIFilter(name: "CIDissolveTransition")
        mixFilter?.setValue(image, forKey: kCIInputImageKey)
        mixFilter?.setValue(blended, forKey: kCIInputTargetImageKey)
        mixFilter?.setValue(amount, forKey: kCIInputTimeKey)
        return mixFilter?.outputImage?.cropped(to: image.extent) ?? image
    }

    // MARK: - Edit Settings

    func applyEditSettings(_ settings: EditSettings, to image: UIImage) async throws -> UIImage {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    guard let ciImage = CIImage(image: image) else {
                        throw ImageServiceError.invalidImage
                    }

                    let result = self.applyAllEdits(settings, on: ciImage)

                    guard let cgImage = self.context.createCGImage(result, from: result.extent) else {
                        throw ImageServiceError.processingFailed
                    }

                    let finalImage = UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
                    continuation.resume(returning: finalImage)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 全編集設定を適用する共通メソッド
    private func applyAllEdits(_ settings: EditSettings, on ciImage: CIImage) -> CIImage {
        var result = ciImage

        // フィルターを適用
        if let filter = settings.appliedFilter {
            result = processFilterSync(filter, on: result)
        }

        // 全27種類の編集ツールを順次適用
        // 適用順序：露出系 → カラー系 → ディテール系 → エフェクト系
        if let v = settings.exposure { result = applyExposure(v, to: result) }
        if let v = settings.brightness { result = applyBrightness(v, to: result) }
        if let v = settings.contrast { result = applyContrast(v, to: result) }
        if let v = settings.tone { result = applyTone(v, to: result) }
        if let v = settings.brilliance { result = applyBrilliance(v, to: result) }
        if let v = settings.highlight { result = applyHighlight(v, to: result) }
        if let v = settings.shadow { result = applyShadow(v, to: result) }
        if let v = settings.blackPoint { result = applyBlackPoint(v, to: result) }
        if let v = settings.saturation { result = applySaturation(v, to: result) }
        if let v = settings.naturalSaturation { result = applyNaturalSaturation(v, to: result) }
        if let v = settings.warmth { result = applyWarmth(v, to: result) }
        if let v = settings.tint { result = applyTint(v, to: result) }
        if let v = settings.colorTemperature { result = applyColorTemperature(v, to: result) }
        if let v = settings.whiteBalance { result = applyWhiteBalance(v, to: result) }
        if let v = settings.sharpness { result = applySharpness(v, to: result) }
        if let v = settings.texture { result = applyTexture(v, to: result) }
        if let v = settings.clarity { result = applyClarity(v, to: result) }
        if let v = settings.dehaze { result = applyDehaze(v, to: result) }
        if let v = settings.grain { result = applyGrain(v, to: result) }
        if let v = settings.fade { result = applyFade(v, to: result) }
        if let v = settings.noiseReduction { result = applyNoiseReduction(v, to: result) }
        if let v = settings.curves { result = applyCurves(v, to: result) }
        if let v = settings.hsl { result = applyHSL(v, to: result) }
        if let v = settings.vignette { result = applyVignette(v, to: result) }
        if let v = settings.lensCorrection { result = applyLensCorrection(v, to: result) }
        if let v = settings.doubleExposure { result = applyDoubleExposure(v, to: result) }

        return result
    }

    // MARK: - Preview

    func generatePreview(_ image: UIImage, edits: EditSettings) async throws -> UIImage {
        let thumbnailSize = CGSize(width: 750, height: 750)
        let resizedImage = try await resizeImage(image, maxSize: thumbnailSize)
        return try await applyEditSettings(edits, to: resizedImage)
    }

    /// 高速プレビュー生成（256x256の低解像度）
    func generatePreviewFast(_ image: UIImage, edits: EditSettings) async throws -> UIImage {
        let fastThumbnailSize = CGSize(width: 750, height: 750)
        let resizedImage = try await resizeImage(image, maxSize: fastThumbnailSize)
        return try await applyEditSettings(edits, to: resizedImage)
    }

    // MARK: - CIImage ベースの高速プレビュー

    /// CIImageベースの高速プレビュー生成（同期処理）
    func generatePreviewFromCIImage(_ ciImage: CIImage, edits: EditSettings) -> UIImage? {
        let result = buildEditFilterChain(on: ciImage, edits: edits)
        guard let cgImage = context.createCGImage(result, from: result.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
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

    /// 編集設定のCIFilterチェーンを構築（リアルタイムプレビュー用）
    private func buildEditFilterChain(on ciImage: CIImage, edits: EditSettings) -> CIImage {
        return applyAllEdits(edits, on: ciImage)
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
                let context = CIContext(options: [.useSoftwareRenderer: false])
                guard let outputCGImage = context.createCGImage(scaled, from: scaled.extent) else {
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
