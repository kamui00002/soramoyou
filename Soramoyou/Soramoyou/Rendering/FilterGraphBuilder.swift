// ⭐️ FilterGraphBuilder.swift
// EditRecipe から CIImage フィルターグラフを構築
// 【改善】フィルター + 全27ツールを 1 本のグラフとして処理（UIImage 変換ゼロ）
//
//  FilterGraphBuilder.swift
//  Soramoyou
//

import CoreImage
import CoreImage.CIFilterBuiltins

/// EditRecipe を受け取り、CIImage フィルターグラフを構築するクラス
///
/// 設計ポイント:
/// - CIImage は処理グラフであり、CIContext.createCGImage() まで実体化しない（遅延評価）
/// - フィルター → ツール全27種を 1 本のグラフとして構築することで UIImage 変換が不要
/// - 適用順序: フィルター → 露出系 → ハイライト/シャドウ → カラー系 → ディテール系 → エフェクト系
///
/// 使用例:
/// ```swift
/// let graph = FilterGraphBuilder.buildGraph(recipe: editRecipe, source: ciImage)
/// let cgImage = CIContextPool.shared.ciContext.createCGImage(graph, from: graph.extent)
/// ```
final class FilterGraphBuilder {

    // MARK: - グラフ構築（メインエントリーポイント）

    /// EditRecipe と入力 CIImage からフィルターグラフを構築する
    ///
    /// - Parameters:
    ///   - recipe: 編集レシピ（不変）
    ///   - source: 入力画像（CIImage）
    /// - Returns: フィルター適用済みの CIImage グラフ
    static func buildGraph(recipe: EditRecipe, source: CIImage) -> CIImage {
        var img = source

        // 1. フィルターを適用（プリセットエフェクト）
        if let filter = recipe.appliedFilter {
            img = applyFilter(filter, to: img)
        }

        // 2. 露出 + 明るさ + コントラスト + 彩度
        //    Metal CIKernel が使用可能なら 1 パスで処理、フォールバック時は CIFilter 2 パス
        let needsECS = recipe.exposureEV != 0
            || recipe.brightnessCI != 0
            || recipe.contrastCI   != 1.0
            || recipe.saturationCI != 1.0
        if needsECS {
            if let metalResult = MetalShaderPipeline.shared.applyExposureContrastSaturation(
                image:      img,
                exposureEV: Float(recipe.exposureEV),
                brightness: Float(recipe.brightnessCI),
                contrast:   Float(recipe.contrastCI),
                saturation: Float(recipe.saturationCI)
            ) {
                // Metal 1 パスで完了
                img = metalResult
            } else {
                // CIFilter フォールバック（Metal 未対応環境・シミュレーター等）
                if recipe.exposureEV != 0 {
                    img = applyExposure(ev: recipe.exposureEV, to: img)
                }
                img = applyColorControls(
                    brightness: recipe.brightnessCI,
                    contrast:   recipe.contrastCI,
                    saturation: recipe.saturationCI,
                    to: img
                )
            }
        }

        // 4. ガンマ/中間調
        if recipe.gamma != 1.0 {
            img = applyGamma(power: recipe.gamma, to: img)
        }

        // 5. ブリリアンス（複合処理）
        if let v = recipe.brillianceNorm, v != 0 {
            img = applyBrilliance(normalized: v, to: img)
        }

        // 6. ハイライト・シャドウ
        let hasHS = recipe.highlights != 1.0 || recipe.shadowAmount != 1.0
        if hasHS {
            img = applyHighlightShadow(
                highlights: recipe.highlights,
                shadows:    recipe.shadowAmount,
                to: img
            )
        }

        // 7. ブラックポイント
        if recipe.blackPointBias != 0 {
            img = applyBlackPoint(bias: recipe.blackPointBias, to: img)
        }

        // 8. 自然な彩度（ビブランス）
        if let v = recipe.naturalSaturationNorm, v != 0 {
            img = applyVibrance(amount: v, to: img)
        }

        // 9. 暖かみ・色合い（TemperatureAndTint）
        let hasWarmTint = recipe.warmthNorm != nil || recipe.tintNorm != nil
        if hasWarmTint {
            img = applyTemperatureAndTint(
                warmthNorm: recipe.warmthNorm ?? 0,
                tintNorm:   recipe.tintNorm   ?? 0,
                to: img
            )
        }

        // 10. 色温度（TemperatureAndTint: 独立）
        if let v = recipe.colorTemperatureNorm, v != 0 {
            img = applyColorTemperature(normalized: v, to: img)
        }

        // 11. ホワイトバランス
        if let v = recipe.whiteBalanceNorm, v != 0 {
            img = applyWhiteBalance(normalized: v, to: img)
        }

        // 12. シャープネス
        if let v = recipe.sharpnessNorm, v != 0 {
            img = applySharpness(normalized: v, to: img)
        }

        // 13. テクスチャ
        if let v = recipe.textureNorm, v != 0 {
            img = applyTexture(normalized: v, to: img)
        }

        // 14. クラリティ
        if let v = recipe.clarityNorm, v != 0 {
            img = applyClarity(normalized: v, to: img)
        }

        // 15. かすみの除去
        if let v = recipe.dehazeNorm, v != 0 {
            img = applyDehaze(normalized: v, to: img)
        }

        // 16. グレイン
        if let v = recipe.grainNorm, v != 0 {
            img = applyGrain(normalized: v, to: img)
        }

        // 17. フェード
        if let v = recipe.fadeNorm, v != 0 {
            img = applyFade(normalized: v, to: img)
        }

        // 18. ノイズリダクション
        if let v = recipe.noiseReductionNorm, v != 0 {
            img = applyNoiseReduction(normalized: v, to: img)
        }

        // 19. カーブ調整（toneCurvePoints が設定されていれば優先使用）
        if let points = recipe.toneCurvePoints, !points.isIdentity {
            img = applyToneCurvePoints(points, to: img)
        } else if let v = recipe.curvesNorm, v != 0 {
            img = applyCurves(normalized: v, to: img)
        }

        // 20. HSL 調整（色相シフト）
        if let v = recipe.hslNorm, v != 0 {
            img = applyHSL(normalized: v, to: img)
        }

        // 21. ビネット
        if let v = recipe.vignetteNorm, v != 0 {
            img = applyVignette(normalized: v, to: img)
        }

        // 22. レンズ補正
        if let v = recipe.lensCorrectionNorm, v != 0 {
            img = applyLensCorrection(normalized: v, to: img)
        }

        // 23. 二重露光風合成（最後に適用: 元画像参照が必要なため）
        if let v = recipe.doubleExposureNorm, v != 0 {
            img = applyDoubleExposure(normalized: v, original: source, blended: img)
        }

        // 24. iOS 18+ HDR トーンマッピング（Display P3 出力時に HDR 輝度を抑制）
        if #available(iOS 18.0, *) {
            img = applyHDRToneMapping(to: img)
        }

        return img
    }

    // MARK: - フィルタープリセット

    private static func applyFilter(_ filter: FilterType, to image: CIImage) -> CIImage {
        switch filter {
        case .natural:
            return image

        case .clear:
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.saturation = 1.1
            f.contrast   = 1.05
            return f.outputImage ?? image

        case .drama:
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.contrast   = 1.3
            f.saturation = 1.2
            return f.outputImage ?? image

        case .soft:
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.saturation = 0.8
            f.contrast   = 0.9
            return f.outputImage ?? image

        case .warm:
            let f = CIFilter.temperatureAndTint()
            f.inputImage    = image
            f.neutral       = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 5500, y: 0)
            return f.outputImage ?? image

        case .cool:
            let f = CIFilter.temperatureAndTint()
            f.inputImage    = image
            f.neutral       = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 7500, y: 0)
            return f.outputImage ?? image

        case .vintage:
            var result = image
            let sepia = CIFilter.sepiaTone()
            sepia.inputImage = result
            sepia.intensity  = 0.5
            result = sepia.outputImage ?? result
            let vignette = CIFilter.vignette()
            vignette.inputImage = result
            vignette.intensity  = 0.5
            vignette.radius     = 1.0
            return vignette.outputImage ?? result

        case .monochrome:
            let f = CIFilter.colorMonochrome()
            f.inputImage = image
            f.color      = CIColor.white
            f.intensity  = 1.0
            return f.outputImage ?? image

        case .pastel:
            let f = CIFilter.colorControls()
            f.inputImage  = image
            f.saturation  = 0.6
            f.brightness  = 0.1
            f.contrast    = 0.9
            return f.outputImage ?? image

        case .vivid:
            let f = CIFilter.colorControls()
            f.inputImage  = image
            f.saturation  = 1.5
            f.contrast    = 1.2
            return f.outputImage ?? image
        }
    }

    // MARK: - 個別フィルター実装

    // ── 露出（EV 値）──
    private static func applyExposure(ev: Double, to image: CIImage) -> CIImage {
        let f = CIFilter.exposureAdjust()
        f.inputImage = image
        f.ev = Float(ev)
        return f.outputImage ?? image
    }

    // ── 明るさ・コントラスト・彩度（CIColorControls）──
    private static func applyColorControls(
        brightness: Double,
        contrast: Double,
        saturation: Double,
        to image: CIImage
    ) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage  = image
        f.brightness  = Float(brightness)
        f.contrast    = Float(contrast)
        f.saturation  = Float(saturation)
        return f.outputImage ?? image
    }

    // ── ガンマ/中間調 ──
    private static func applyGamma(power: Double, to image: CIImage) -> CIImage {
        let f = CIFilter.gammaAdjust()
        f.inputImage = image
        f.power = Float(power)
        return f.outputImage ?? image
    }

    // ── ブリリアンス（複合処理）──
    private static func applyBrilliance(normalized v: Double, to image: CIImage) -> CIImage {
        let hs = CIFilter.highlightShadowAdjust()
        hs.inputImage      = image
        hs.shadowAmount    = Float(1.0 + v * 0.5)
        hs.highlightAmount = Float(1.0 - v * 0.3)
        guard let step1 = hs.outputImage else { return image }

        let cc = CIFilter.colorControls()
        cc.inputImage = step1
        cc.contrast   = Float(1.0 + v * 0.15)
        return cc.outputImage ?? step1
    }

    // ── ハイライト・シャドウ ──
    private static func applyHighlightShadow(
        highlights: Double,
        shadows: Double,
        to image: CIImage
    ) -> CIImage {
        let f = CIFilter.highlightShadowAdjust()
        f.inputImage      = image
        f.highlightAmount = Float(highlights)
        f.shadowAmount    = Float(shadows)
        return f.outputImage ?? image
    }

    // ── ブラックポイント ──
    private static func applyBlackPoint(bias: Double, to image: CIImage) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage  = image
        let offset    = Float(bias)
        f.biasVector  = CIVector(x: CGFloat(offset), y: CGFloat(offset), z: CGFloat(offset), w: 0)
        f.rVector     = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.gVector     = CIVector(x: 0, y: 1, z: 0, w: 0)
        f.bVector     = CIVector(x: 0, y: 0, z: 1, w: 0)
        f.aVector     = CIVector(x: 0, y: 0, z: 0, w: 1)
        return f.outputImage ?? image
    }

    // ── 自然な彩度（ビブランス）──
    private static func applyVibrance(amount: Double, to image: CIImage) -> CIImage {
        let f = CIFilter.vibrance()
        f.inputImage = image
        f.amount     = Float(amount)
        return f.outputImage ?? image
    }

    // ── 暖かみ・色合い（同一フィルターで処理）──
    private static func applyTemperatureAndTint(
        warmthNorm: Double,
        tintNorm: Double,
        to image: CIImage
    ) -> CIImage {
        let f = CIFilter.temperatureAndTint()
        f.inputImage    = image
        f.neutral       = CIVector(x: 6500, y: 0)
        f.targetNeutral = CIVector(
            x: 6500 - warmthNorm * 1500,
            y: tintNorm * 100
        )
        return f.outputImage ?? image
    }

    // ── 色温度シフト共通ヘルパー ──
    /// 中性色温度 6500K を基準に、normalized 値とスケール係数で色温度をシフト
    private static func applyTemperatureShift(
        normalized v: Double, scale: Double, to image: CIImage
    ) -> CIImage {
        let f = CIFilter.temperatureAndTint()
        f.inputImage    = image
        f.neutral       = CIVector(x: 6500, y: 0)
        f.targetNeutral = CIVector(x: 6500 + v * scale, y: 0)
        return f.outputImage ?? image
    }

    // ── 色温度（独立）──
    private static func applyColorTemperature(normalized v: Double, to image: CIImage) -> CIImage {
        applyTemperatureShift(normalized: v, scale: 1500, to: image)
    }

    // ── ホワイトバランス ──
    private static func applyWhiteBalance(normalized v: Double, to image: CIImage) -> CIImage {
        applyTemperatureShift(normalized: v, scale: 1000, to: image)
    }

    // ── シャープネス ──
    private static func applySharpness(normalized v: Double, to image: CIImage) -> CIImage {
        let f = CIFilter.sharpenLuminance()
        f.inputImage  = image
        f.sharpness   = Float(v * 2.0)
        return f.outputImage ?? image
    }

    // ── テクスチャ ──
    private static func applyTexture(normalized v: Double, to image: CIImage) -> CIImage {
        guard abs(v) > 0.01 else { return image }
        let f = CIFilter.unsharpMask()
        f.inputImage  = image
        f.radius      = Float(abs(v) * 3.0)
        f.intensity   = Float(abs(v))
        return f.outputImage ?? image
    }

    // ── クラリティ ──
    private static func applyClarity(normalized v: Double, to image: CIImage) -> CIImage {
        guard abs(v) > 0.01 else { return image }
        let f = CIFilter.unsharpMask()
        f.inputImage  = image
        f.radius      = Float(abs(v) * 0.8 + 0.01)
        f.intensity   = Float(abs(v) * 0.5)
        return f.outputImage ?? image
    }

    // ── かすみの除去 ──
    // Phase 1 #J: CIFogEffect は CIFilterBuiltins に型安全 API が存在しないため
    // 文字列キーのまま維持（変更するとランタイムで入力キー mismatch を起こすリスク）。
    // Grain / DoubleExposure 側は型安全 API に移行済み。
    private static func applyDehaze(normalized v: Double, to image: CIImage) -> CIImage {
        guard abs(v) > 0.01 else { return image }
        if #available(iOS 15.0, *) {
            let f = CIFilter(name: "CIFogEffect")
            f?.setValue(image, forKey: kCIInputImageKey)
            f?.setValue(-Float(v * 0.8), forKey: "inputAmount")
            return f?.outputImage ?? image
        } else {
            let f = CIFilter.colorControls()
            f.inputImage  = image
            f.contrast    = Float(1.0 + v * 0.3)
            f.saturation  = Float(1.0 + v * 0.2)
            return f.outputImage ?? image
        }
    }

    // ── グレイン ──
    // Phase 1 #J: 文字列キー API → CIFilterBuiltins に移行（型安全化）
    private static func applyGrain(normalized v: Double, to image: CIImage) -> CIImage {
        guard abs(v) > 0.01 else { return image }

        let random = CIFilter.randomGenerator()
        guard let noiseImage = random.outputImage else { return image }

        let cropped = noiseImage.cropped(to: image.extent)

        // モノクロ化 + アルファ減衰を CIColorMatrix（型安全 API）で実装
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = cropped
        matrix.rVector    = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.gVector    = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.bVector    = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.aVector    = CIVector(x: 0, y: 0, z: 0, w: CGFloat(abs(v) * 0.15))
        matrix.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        let monochromeNoise = matrix.outputImage ?? cropped

        let blendFilter = CIFilter.multiplyBlendMode()
        blendFilter.inputImage      = image
        blendFilter.backgroundImage = monochromeNoise
        return blendFilter.outputImage ?? image
    }

    // ── フェード ──
    private static func applyFade(normalized v: Double, to image: CIImage) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        let bias = Float(v * 0.1)
        f.biasVector = CIVector(x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 0)
        f.rVector    = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.gVector    = CIVector(x: 0, y: 1, z: 0, w: 0)
        f.bVector    = CIVector(x: 0, y: 0, z: 1, w: 0)
        f.aVector    = CIVector(x: 0, y: 0, z: 0, w: 1)
        return f.outputImage ?? image
    }

    // ── ノイズリダクション ──
    private static func applyNoiseReduction(normalized v: Double, to image: CIImage) -> CIImage {
        let f = CIFilter.noiseReduction()
        f.inputImage  = image
        f.noiseLevel  = Float(abs(v) * 0.05)
        f.sharpness   = Float(0.5 + abs(v) * 0.3)
        return f.outputImage ?? image
    }

    // ── トーンカーブ（ToneCurvePoints による 5点制御）──
    private static func applyToneCurvePoints(_ points: ToneCurvePoints, to image: CIImage) -> CIImage {
        let f = CIFilter.toneCurve()
        f.inputImage = image
        f.point0 = points.point0.cgPoint
        f.point1 = points.point1.cgPoint
        f.point2 = points.point2.cgPoint
        f.point3 = points.point3.cgPoint
        f.point4 = points.point4.cgPoint
        return f.outputImage ?? image
    }

    // ── カーブ調整（S字/逆S字）──
    private static func applyCurves(normalized v: Double, to image: CIImage) -> CIImage {
        let f = CIFilter.toneCurve()
        f.inputImage = image
        let shift    = Float(v * 0.15)
        f.point0 = CGPoint(x: 0.0,  y: CGFloat(max(0, 0.0  - shift)))
        f.point1 = CGPoint(x: 0.25, y: CGFloat(max(0, min(1, 0.25 - shift))))
        f.point2 = CGPoint(x: 0.5,  y: 0.5)
        f.point3 = CGPoint(x: 0.75, y: CGFloat(max(0, min(1, 0.75 + shift))))
        f.point4 = CGPoint(x: 1.0,  y: CGFloat(min(1, 1.0  + shift)))
        return f.outputImage ?? image
    }

    // ── HSL 調整（色相シフト）──
    private static func applyHSL(normalized v: Double, to image: CIImage) -> CIImage {
        let f = CIFilter.hueAdjust()
        f.inputImage = image
        f.angle      = Float(v * .pi)
        return f.outputImage ?? image
    }

    // ── ビネット ──
    private static func applyVignette(normalized v: Double, to image: CIImage) -> CIImage {
        let f = CIFilter.vignette()
        f.inputImage = image
        f.intensity  = Float(v * 2.0)
        f.radius     = 1.0
        return f.outputImage ?? image
    }

    // ── レンズ補正 ──
    // Phase 1 #M: `cropped(to:)` 前に `clampedToExtent()` を挟み、
    // 歪みで押し出されたエッジ近傍の黒帯・コピー縞アーティファクトを抑制する。
    // radius を画像対角線長まで広げ、歪みの連続性を確保。
    private static func applyLensCorrection(normalized v: Double, to image: CIImage) -> CIImage {
        guard abs(v) > 0.01 else { return image }
        let extent = image.extent
        let f = CIFilter.bumpDistortion()
        f.inputImage = image
        f.center     = CGPoint(x: extent.midX, y: extent.midY)
        f.radius     = Float(hypot(extent.width, extent.height))
        f.scale      = Float(-v * 0.3)
        let distorted = f.outputImage ?? image
        return distorted
            .clampedToExtent()
            .cropped(to: extent)
    }

    // ── 二重露光風合成 ──
    private static func applyDoubleExposure(
        normalized v: Double,
        original: CIImage,
        blended: CIImage
    ) -> CIImage {
        guard abs(v) > 0.01 else { return blended }

        // ぼかし版を生成
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = original
        blur.radius     = 15.0
        guard let blurredImage = blur.outputImage?.cropped(to: original.extent) else {
            return blended
        }

        // スクリーンブレンド
        let screen = CIFilter.screenBlendMode()
        screen.inputImage       = blurredImage
        screen.backgroundImage  = blended
        guard let screenResult = screen.outputImage else { return blended }

        // ディゾルブで強度をコントロール
        // Phase 1 #J: 文字列キー API → CIFilterBuiltins に移行（型安全化）
        let mix = CIFilter.dissolveTransition()
        mix.inputImage  = blended
        mix.targetImage = screenResult
        mix.time        = Float(abs(v))
        return mix.outputImage?.cropped(to: original.extent) ?? blended
    }

    // ── iOS 18+ HDR トーンマッピング ──
    ///
    /// Phase 1 #K: Reinhard 近似 → ACES Filmic 近似に差し替え。
    /// ACES Filmic は映画業界標準の S 字カーブで、
    /// - ハイライトのロールオフが滑らか（Reinhard の急峻なクリップ感を解消）
    /// - シャドウが深く保たれる（コントラスト確保）
    /// - 中間域のサチュレーションが自然
    ///
    /// `CIColorCurves` を 16 点 LUT として定義し、GPU で 1 パス評価する。
    @available(iOS 18.0, *)
    private static func applyHDRToneMapping(to image: CIImage) -> CIImage {
        applyACESFilmicToneMap(to: image)
    }

    /// ACES Filmic トーンマップ近似（Krzysztof Narkowicz の簡易版）
    ///
    /// f(x) = (x * (a*x + b)) / (x * (c*x + d) + e)
    /// a=2.51, b=0.03, c=2.43, d=0.59, e=0.14
    ///
    /// 16 点の LUT（0.0〜1.0 範囲、HDR 入力は事前に線形に正規化されている前提）を
    /// `CIColorCurves` に流し、各色チャネル独立にトーンカーブを適用する。
    private static func applyACESFilmicToneMap(to image: CIImage) -> CIImage {
        let lutSize = 16
        var lut: [Float] = []
        lut.reserveCapacity(lutSize * 4)

        for i in 0..<lutSize {
            let x = Float(i) / Float(lutSize - 1)
            let a: Float = 2.51
            let b: Float = 0.03
            let c: Float = 2.43
            let d: Float = 0.59
            let e: Float = 0.14
            let y = max(0.0, min(1.0, (x * (a * x + b)) / (x * (c * x + d) + e)))
            lut.append(y)
            lut.append(y)
            lut.append(y)
            lut.append(1.0)
        }

        let data = lut.withUnsafeBufferPointer { buffer -> Data in
            Data(buffer: buffer)
        }

        let curves = CIFilter.colorCurves()
        curves.inputImage      = image
        curves.curvesData      = data
        curves.curvesDomain    = CIVector(x: 0.0, y: 1.0)
        curves.colorSpace      = CIContextPool.shared.workingColorSpace
        return curves.outputImage ?? image
    }
}
