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
final class HeuristicSkyMaskProvider: SkyMaskProviderProtocol {

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

    /// 地平線検出: 画素を「空色」とカウントする colorScore の下限
    private static let horizonScoreThreshold: Double = 0.5
    /// 地平線検出: 行を「まだ空」とみなすための空色画素率の下限
    private static let horizonRowSkyFractionThreshold: Double = 0.30
    /// 地平線より下へのフェード幅（yNorm 比）。境界を滑らかに落とすため
    private static let horizonFadeBand: Double = 0.08
    /// 1行も空色が無い場合の保険の地平線位置（旧 fadeStart と同じ 0.40）
    private static let fallbackHorizonNorm: Double = 0.40

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

    // MARK: - SkyMaskProviderProtocol

    func makeSkyMask(for image: CIImage, quality: SkyMaskQuality) async throws -> SkyMask {
        // 重い処理本体（縮小・画素読み出し・CPU ループ）は Task.detached にオフロードし、
        // 呼び出し元のアクター（多くは MainActor）をブロックしないようにする。
        // 純関数的な処理（外部状態を変更しない）なので detached 実行は安全。
        // コードベースの確立慣習（SkyStitchViewModel.runStitch / ImageService.applyEditRecipe）と同じパターン。
        let workTask = Task.detached(priority: .userInitiated) { () throws -> SkyMask in
            try self.makeSkyMaskSync(for: image, quality: quality)
        }
        return try await workTask.value
    }

    // MARK: - Private: 処理本体（手順a〜i・Task.detached からオフロードして呼ばれる）

    /// `makeSkyMask` の同期処理本体。
    private func makeSkyMaskSync(for image: CIImage, quality: SkyMaskQuality) throws -> SkyMask {
        let extent = image.extent

        // 手順a: 入力検証
        // extent が空・無限・幅か高さが 1px 未満の画像は解析グリッドを作れないため弾く
        guard !extent.isEmpty, !extent.isInfinite,
              extent.width >= 1, extent.height >= 1 else {
            throw SkyMaskError.invalidInput
        }

        // 手順a': origin 正規化
        // `CIImage.oriented()` は `.right` 系の向きで origin が非ゼロの extent を返しうる
        // （iPhone 縦撮りの標準的な EXIF orientation）。後段の CILanczosScaleTransform は
        // 画像自身のバウンディングボックス原点ではなく CI 座標系の (0,0) を基準にスケールするため、
        // origin が非ゼロのまま渡すと縮小後の内容が (0,0) 起点の解析グリッド抽出矩形からずれてしまう
        // （= 読み出す画素が画像本体からはみ出す）。`SkyReplacementCompositor.aspectFill` には
        // 同様の正規化が既にあったのに provider 側に無い非対称があったため、ここで揃える。
        // 最終的なマスクは手順h で `extent.origin` へ translate し戻し、入力 extent と厳密一致させる。
        let normalizedImage: CIImage = extent.origin == .zero
            ? image
            : image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))

        // 手順b: 解析グリッドサイズ決定
        let gridLongSide: CGFloat = quality == .preview ? Self.previewGridLongSide : Self.exportGridLongSide
        let longSide = max(extent.width, extent.height)
        // 入力が解析グリッドより小さい場合は拡大せずそのまま使う（scale=1.0）
        let scale: CGFloat = longSide > gridLongSide ? gridLongSide / longSide : 1.0
        let gridW = max(1, Int((extent.width * scale).rounded()))
        let gridH = max(1, Int((extent.height * scale).rounded()))

        // 手順c: 縮小して RGBA8 画素を読む（origin 正規化済みの画像を渡す）
        let pixels = try readRGBA8Pixels(image: normalizedImage, gridW: gridW, gridH: gridH)

        // 手順d（1パス目）: 画素ごとの色スコアのみを算出する（縦位置の事前確率はまだ掛けない）。
        // 地平線検出（次段）は写真ごとの実際の色分布に基づくため、先に色スコア全体が必要。
        var colorScoreGrid = [Double](repeating: 0, count: gridW * gridH)
        for row in 0..<gridH {
            for col in 0..<gridW {
                let pixelIndex = (row * gridW + col) * 4
                let r = Double(pixels[pixelIndex])     / 255.0
                let g = Double(pixels[pixelIndex + 1]) / 255.0
                let b = Double(pixels[pixelIndex + 2]) / 255.0

                let hsv = Self.rgbToHSV(r: r, g: g, b: b)
                colorScoreGrid[row * gridW + col] = self.colorScore(hue: hsv.h, saturation: hsv.s, value: hsv.v)
            }
        }

        // 手順d'（地平線検出）: 上から連続で「まだ空」とみなせる行を歩き、地平線位置を求める。
        let horizonNorm = detectHorizonNorm(colorScoreGrid: colorScoreGrid, gridW: gridW, gridH: gridH)

        // 手順e（2パス目）: 縦位置の事前確率（地平線基準）を掛けてスコア確定＋統計値集計
        var scoreGrid = [Double](repeating: 0, count: gridW * gridH)
        var scoreSum: Double = 0
        var confidentPixelCount = 0

        for row in 0..<gridH {
            // メモリ行0=画像の上端（手順c参照）。yNorm は上からの正規化位置。
            let yNorm = gridH > 1 ? Double(row) / Double(gridH - 1) : 0.0
            let positionPrior = self.positionPrior(yNorm: yNorm, horizonNorm: horizonNorm)

            for col in 0..<gridW {
                let index = row * gridW + col
                let score = colorScoreGrid[index] * positionPrior

                scoreGrid[index] = score
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

    /// 地平線検出: 各行の空色画素率を上から連続で歩き、地平線の位置（yNorm）を求める。
    ///
    /// なぜ写真ごとに検出するか: 「上から40%」固定の事前確率だと、山際まで空が写る実写
    /// （地平線が画像の下の方にある構図）では、本来空である下半分のスコアが固定 prior に
    /// 押し下げられて薄れてしまい、差し替え結果が中途半端な帯になる。写真ごとに地平線の
    /// 行を検出し、その位置を基準にフェードさせることでこれを避ける。
    ///
    /// なぜ「連続条件」で歩くか: 「下の方にある青い池」等を地平線越しに空と誤認しないため。
    /// 途中に雲や木の枝の行が混ざっても skyFraction が閾値を割らない限り歩行は続く（＝
    /// 一時的に空色画素が減っても地平線とはみなさない）。
    ///
    /// - Parameters:
    ///   - colorScoreGrid: 手順d（1パス目）で算出した画素ごとの色スコア（縦位置の事前確率は未適用）
    ///   - gridW: 解析グリッドの幅
    ///   - gridH: 解析グリッドの高さ
    /// - Returns: 地平線位置（yNorm 座標）。1行も空色が無ければ `fallbackHorizonNorm`。
    private func detectHorizonNorm(colorScoreGrid: [Double], gridW: Int, gridH: Int) -> Double {
        guard gridW > 0, gridH > 0 else { return Self.fallbackHorizonNorm }

        var horizonRow: Int?
        var row = 0
        while row < gridH {
            var skyPixelCount = 0
            let rowStart = row * gridW
            for col in 0..<gridW {
                if colorScoreGrid[rowStart + col] >= Self.horizonScoreThreshold {
                    skyPixelCount += 1
                }
            }
            let skyFraction = Double(skyPixelCount) / Double(gridW)
            guard skyFraction >= Self.horizonRowSkyFractionThreshold else { break }
            horizonRow = row
            row += 1
        }

        guard let lastSkyRow = horizonRow else { return Self.fallbackHorizonNorm }
        return Double(lastSkyRow) / Double(max(gridH - 1, 1))
    }

    /// 縦位置の事前確率（地平線より上は空、地平線から `horizonFadeBand` 分だけ下向きにフェード）
    /// - Parameters:
    ///   - yNorm: 上からの正規化位置 0...1（0=画像の上端、1=画像の下端）
    ///   - horizonNorm: `detectHorizonNorm` で求めた地平線位置（yNorm 座標）
    private func positionPrior(yNorm: Double, horizonNorm: Double) -> Double {
        if yNorm <= horizonNorm {
            return 1.0
        }
        let fadeEnd = horizonNorm + Self.horizonFadeBand
        if yNorm >= fadeEnd {
            return 0.0
        }
        // horizonNorm〜fadeEnd の間は 1.0 から 0.0 へ線形減衰
        let t = (yNorm - horizonNorm) / Self.horizonFadeBand
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
        //    blur は計算時に extent 外の透明をサンプルするため、事前に入力を clampedToExtent() で
        //    clamp してエッジ画素を複製しておくのが正しい順序（クランプ → blur → crop）。
        //    旧順序（blur 後に clamp）は縁のマスク値を下げ、目視検証（SkyReplacementVisualHarnessTests）で
        //    観測されていた「画像の縁の細い帯」の原因だった（SKY-002）。
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Self.edgeBlurRadius
        let blurred = blur.outputImage?.cropped(to: gridExtent) ?? image

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
