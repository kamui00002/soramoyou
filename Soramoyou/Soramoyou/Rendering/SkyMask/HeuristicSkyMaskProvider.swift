// ⭐️ HeuristicSkyMaskProvider.swift
// SkyMaskProvider v1: 色分析＋縦位置の事前確率によるヒューリスティック実装
//
//  HeuristicSkyMaskProvider.swift
//  Soramoyou
//

import CoreImage
import CoreImage.CIFilterBuiltins

/// 色分析（HSV）と縦位置の事前確率（上ほど空らしい）を組み合わせて空マスクを生成する v1 実装。
///
/// 設計方針:
/// - ステートレス（キャッシュを持たない）。呼び出しごとに独立して計算するため、
///   同一インスタンスを複数スレッド・複数画像で使い回しても問題ない。
/// - 解析は縮小したグリッド（最大 384px 長辺）上で行う CPU ループで完結させる。
///   Core Image のフィルタグラフだけで色相判定を表現するのは複雑になりすぎるため、
///   縮小後の少画素数（数万画素程度）に限定して Swift ループで判定する。
final class HeuristicSkyMaskProvider: SkyMaskProviding {

    // MARK: - Properties

    /// 画素読み出し・グラフレンダリングに使う CIContext（テスト時は差し替え可能にするため注入式）
    private let ciContext: CIContext

    // MARK: - 定数（マジックナンバー回避）

    /// 解析グリッドの長辺（プレビュー品質）
    private static let previewGridLongSide: CGFloat = 192
    /// 解析グリッドの長辺（書き出し品質）
    private static let exportGridLongSide: CGFloat = 384

    /// 青空判定: 色相レンジ（度数）
    private static let blueSkyHueRange: ClosedRange<Double> = 180...260
    /// 青空判定: 最低彩度
    private static let blueSkyMinSaturation: Double = 0.15
    /// 青空判定: 最低明度
    private static let blueSkyMinValue: Double = 0.25
    /// 青空判定のスコア
    private static let blueSkyScore: Double = 1.0

    /// 白い雲・曇天判定: 最大彩度（これ未満なら無彩色扱い）
    private static let cloudMaxSaturation: Double = 0.15
    /// 白い雲・曇天判定: 最低明度
    private static let cloudMinValue: Double = 0.65
    /// 白い雲・曇天判定のスコア
    private static let cloudScore: Double = 0.85

    /// 朝夕の空判定: 暖色側の色相上限（0 起点、この値以下なら赤〜オレンジ側）
    private static let sunsetHueLowMax: Double = 50
    /// 朝夕の空判定: 暖色側の色相下限（この値以上ならマゼンタ〜赤側）
    private static let sunsetHueHighMin: Double = 300
    /// 朝夕の空判定: 最低彩度
    private static let sunsetMinSaturation: Double = 0.15
    /// 朝夕の空判定: 最低明度
    ///
    /// 朝夕の空は太陽光で明るく輝く（明度0.6以上が典型）のに対し、土・木・建物などの
    /// 暖色系の地上物は中明度（0.3〜0.5）に集中する。0.55 はこの2群を分離する閾値。
    /// 0.35 だと中明度の茶色（例: 土 val=0.45）を朝夕の空と誤判定していた。
    private static let sunsetMinValue: Double = 0.55
    /// 朝夕の空判定のスコア
    private static let sunsetScore: Double = 0.6

    /// 非空判定のスコア
    private static let nonSkyScore: Double = 0.0

    /// 縦位置の事前確率: この yNorm 以下は「確実に空」として prior=1.0
    private static let positionPriorFadeStart: Double = 0.40
    /// 縦位置の事前確率: この yNorm 以上は「確実に非空」として prior=0.0
    private static let positionPriorFadeEnd: Double = 0.85

    /// エッジ整形: ガウシアンブラー半径
    private static let edgeBlurRadius: Float = 2.0
    /// エッジ整形: ソフト閾値のスケール（コントラスト強調）
    private static let thresholdScale: Float = 2.5
    /// エッジ整形: ソフト閾値のバイアス（コントラスト強調）
    private static let thresholdBias: Float = -0.75

    /// 信頼度判定: この値以下は「はっきり非空」
    private static let confidenceLowThreshold: Double = 0.2
    /// 信頼度判定: この値以上は「はっきり空」
    private static let confidenceHighThreshold: Double = 0.8

    // MARK: - Init

    /// - Parameter ciContext: 画素読み出し・レンダリングに使う CIContext。
    ///   テストでは軽量な `CIContext()` を注入できるようにするため引数化している。
    init(ciContext: CIContext = CIContextPool.shared.ciContext) {
        self.ciContext = ciContext
    }

    // MARK: - SkyMaskProviding

    func makeSkyMask(for image: CIImage, quality: SkyMaskQuality) async throws -> SkyMask {
        let extent = image.extent

        // 手順a: 入力検証
        // extent が空・無限・幅か高さが 1px 未満の画像は解析グリッドを作れないため弾く
        guard !extent.isEmpty, !extent.isInfinite,
              extent.width >= 1, extent.height >= 1 else {
            throw SkyMaskError.invalidInput
        }

        // 手順b: 解析グリッドサイズ決定
        let gridLongSide: CGFloat = quality == .preview ? Self.previewGridLongSide : Self.exportGridLongSide
        let longSide = max(extent.width, extent.height)
        // 入力が解析グリッドより小さい場合は拡大せずそのまま使う（scale=1.0）
        let scale: CGFloat = longSide > gridLongSide ? gridLongSide / longSide : 1.0
        let gridW = max(1, Int((extent.width * scale).rounded()))
        let gridH = max(1, Int((extent.height * scale).rounded()))

        // 手順c: 縮小して RGBA8 画素を読む
        let pixels = try readRGBA8Pixels(image: image, gridW: gridW, gridH: gridH)

        // 手順d, e: 画素ごとの空らしさスコア算出＋統計値集計
        var scoreGrid = [Double](repeating: 0, count: gridW * gridH)
        var scoreSum: Double = 0
        var confidentPixelCount = 0

        for row in 0..<gridH {
            // メモリ行0=画像の上端（手順c参照）。yNorm は上からの正規化位置。
            let yNorm = gridH > 1 ? Double(row) / Double(gridH - 1) : 0.0
            let positionPrior = self.positionPrior(yNorm: yNorm)

            for col in 0..<gridW {
                let pixelIndex = (row * gridW + col) * 4
                let r = Double(pixels[pixelIndex])     / 255.0
                let g = Double(pixels[pixelIndex + 1]) / 255.0
                let b = Double(pixels[pixelIndex + 2]) / 255.0

                let hsv = Self.rgbToHSV(r: r, g: g, b: b)
                let colorScoreValue = self.colorScore(hue: hsv.h, saturation: hsv.s, value: hsv.v)
                let score = colorScoreValue * positionPrior

                scoreGrid[row * gridW + col] = score
                scoreSum += score

                if score <= Self.confidenceLowThreshold || score >= Self.confidenceHighThreshold {
                    confidentPixelCount += 1
                }
            }
        }

        let totalPixels = gridW * gridH
        let skyCoverage = totalPixels > 0 ? scoreSum / Double(totalPixels) : 0
        let confidence = totalPixels > 0 ? Double(confidentPixelCount) / Double(totalPixels) : 0

        // 手順f: スコアグリッド → グレースケール CIImage
        let grayImage = try makeGrayscaleImage(scoreGrid: scoreGrid, width: gridW, height: gridH)

        // 手順g: 平滑化とエッジ整形
        let gridExtent = CGRect(x: 0, y: 0, width: gridW, height: gridH)
        let smoothed = smoothAndSharpenEdges(grayImage, gridExtent: gridExtent)

        // 手順h: 入力サイズへ拡大し、入力 extent に厳密一致させる
        let scaleX = extent.width  / CGFloat(gridW)
        let scaleY = extent.height / CGFloat(gridH)
        let upscaled = smoothed
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
            .cropped(to: extent)

        // 手順i
        return SkyMask(mask: upscaled, skyCoverage: skyCoverage, confidence: confidence)
    }

    // MARK: - Private: 画素読み出し（手順c）

    /// 入力 CIImage を解析グリッドサイズへ縮小し、RGBA8（sRGB）の生バイト列を返す
    ///
    /// - Note: CGBitmapContext に CGImage を draw した場合、メモリ行0=画像の上端になる。
    ///   このバイト列を走査する側（makeSkyMask 内のループ）はこの前提で yNorm を計算する。
    private func readRGBA8Pixels(image: CIImage, gridW: Int, gridH: Int) throws -> [UInt8] {
        let extent = image.extent

        // CILanczosScaleTransform は「scale で縦横一律に拡縮 → aspectRatio で幅だけ追加調整」という
        // 2 段階の縮小モデルを取るため、まず高さを gridH に合わせる scale を求め、
        // 続けて幅を gridW に微調整する aspectRatio を求める。
        let heightScale = CGFloat(gridH) / extent.height
        let intermediateWidth = extent.width * heightScale
        let aspectRatio: CGFloat = intermediateWidth > 0 ? CGFloat(gridW) / intermediateWidth : 1.0

        let scaleFilter = CIFilter.lanczosScaleTransform()
        scaleFilter.inputImage = image
        scaleFilter.scale = Float(heightScale)
        scaleFilter.aspectRatio = Float(aspectRatio)

        guard let scaledImage = scaleFilter.outputImage else {
            throw SkyMaskError.generationFailed
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SkyMaskError.generationFailed
        }

        let gridRect = CGRect(x: 0, y: 0, width: gridW, height: gridH)
        guard let cgImage = ciContext.createCGImage(
            scaledImage,
            from: gridRect,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            throw SkyMaskError.generationFailed
        }

        var pixels = [UInt8](repeating: 0, count: gridW * gridH * 4)
        guard let bitmapContext = CGContext(
            data: &pixels,
            width: gridW,
            height: gridH,
            bitsPerComponent: 8,
            bytesPerRow: gridW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SkyMaskError.generationFailed
        }
        bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: gridW, height: gridH))

        return pixels
    }

    // MARK: - Private: HSV 変換（手順d）

    /// RGB(0...1) を HSV に変換する（hue は度数 0...360）
    private static func rgbToHSV(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxVal = max(r, g, b)
        let minVal = min(r, g, b)
        let delta = maxVal - minVal

        var h: Double = 0
        if delta > 0 {
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

        return (h, s, v)
    }

    // MARK: - Private: 空らしさスコア判定（手順d）

    /// HSV から色カテゴリスコアを判定する（上から順に最初にマッチしたものを採用）
    private func colorScore(hue: Double, saturation: Double, value: Double) -> Double {
        // 1. 青空
        if Self.blueSkyHueRange.contains(hue)
            && saturation >= Self.blueSkyMinSaturation
            && value >= Self.blueSkyMinValue {
            return Self.blueSkyScore
        }

        // 2. 白い雲・曇天
        if saturation < Self.cloudMaxSaturation
            && value >= Self.cloudMinValue {
            return Self.cloudScore
        }

        // 3. 朝夕の空
        if (hue <= Self.sunsetHueLowMax || hue >= Self.sunsetHueHighMin)
            && saturation >= Self.sunsetMinSaturation
            && value >= Self.sunsetMinValue {
            return Self.sunsetScore
        }

        // 4. それ以外
        return Self.nonSkyScore
    }

    /// 縦位置の事前確率（上ほど空らしい）
    /// - Parameter yNorm: 上からの正規化位置 0...1（0=画像の上端、1=画像の下端）
    private func positionPrior(yNorm: Double) -> Double {
        if yNorm <= Self.positionPriorFadeStart {
            return 1.0
        }
        if yNorm >= Self.positionPriorFadeEnd {
            return 0.0
        }
        // fadeStart〜fadeEnd の間は 1.0 から 0.0 へ線形減衰
        let t = (yNorm - Self.positionPriorFadeStart) / (Self.positionPriorFadeEnd - Self.positionPriorFadeStart)
        return 1.0 - t
    }

    // MARK: - Private: グレースケール CIImage 化（手順f）

    /// スコアグリッド（0...1）を 8bit 1ch（DeviceGray）の CGImage 経由で CIImage 化する
    ///
    /// - Note: この CGImage を素直に `CIImage(cgImage:)` にすると、Core Image が
    ///   DeviceGray の暗黙のガンマカーブでバイト値をデコードしてしまい、0.0/1.0 の両端以外の
    ///   中間スコア（例: 0.6）が大きく歪む（レンダリングに使う CIContext の作業色空間次第で
    ///   0.6 が 0.3 前後まで暗転するなど）。スコアは「色」ではなく生の数値なので、
    ///   `.colorSpace: NSNull()` でカラーマネジメントを無効化し、バイト値をそのまま
    ///   後段のフィルタグラフへ通す（マスク/非色データを Core Image で扱う定石）。
    private func makeGrayscaleImage(scoreGrid: [Double], width: Int, height: Int) throws -> CIImage {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for i in 0..<scoreGrid.count {
            let clamped = min(1.0, max(0.0, scoreGrid[i]))
            bytes[i] = UInt8((clamped * 255).rounded())
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let bitmapContext = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let cgImage = bitmapContext.makeImage() else {
            throw SkyMaskError.generationFailed
        }

        return CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
    }

    // MARK: - Private: 平滑化とエッジ整形（手順g）

    /// ガウシアンブラーによる平滑化 → ソフト閾値によるコントラスト強調 → 0...1 クランプ
    private func smoothAndSharpenEdges(_ image: CIImage, gridExtent: CGRect) -> CIImage {
        // 1. ガウシアンブラーで境界のギザギザを軽減
        //    gaussianBlur は境界を超えて広がるため clampedToExtent() で端を埋めてから crop する
        //    （FilterGraphBuilder の applySharpness 負値側と同じパターン）
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image
        blur.radius = Self.edgeBlurRadius
        let blurred = blur.outputImage?.clampedToExtent().cropped(to: gridExtent) ?? image

        // 2. ソフト閾値（コントラスト強調）: out = scale × v + bias
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = blurred
        let scale = CGFloat(Self.thresholdScale)
        let bias  = CGFloat(Self.thresholdBias)
        matrix.rVector    = CIVector(x: scale, y: 0,     z: 0,     w: 0)
        matrix.gVector    = CIVector(x: 0,     y: scale, z: 0,     w: 0)
        matrix.bVector    = CIVector(x: 0,     y: 0,     z: scale, w: 0)
        matrix.aVector    = CIVector(x: 0,     y: 0,     z: 0,     w: 1) // alpha は素通し
        matrix.biasVector = CIVector(x: bias,  y: bias,  z: bias,  w: 0)
        let contrasted = matrix.outputImage ?? blurred

        // 3. 0...1 にクランプ
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = contrasted
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage ?? contrasted
    }
}
