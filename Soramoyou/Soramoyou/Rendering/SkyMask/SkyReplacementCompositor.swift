// ⭐️ SkyReplacementCompositor.swift
// 空差し替え合成エンジン: SkyMask で検出した空領域を新しい空の画像に差し替える
//
//  SkyReplacementCompositor.swift
//  Soramoyou
//

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import ImageIO

/// 空差し替えのオプション
struct SkyReplacementOptions {
    /// マスクのフェザー（境界ぼかし）半径 = 画像長辺 × この係数。
    ///
    /// なぜ「係数 × 長辺」で決めるか: 固定 px 指定だと縮小画像では過剰ににじみ、
    /// 拡大画像では逆に境界が硬く残ってしまう。長辺に比例させることで
    /// 境界のなじみ方が解像度に依存しなくなる。
    var featherRadiusFraction: CGFloat = 0.01
    /// フェザリング前にマスクを膨張させる半径 = 画像長辺 × この係数。
    ///
    /// なぜ膨張させるか: フェザリング（ガウシアンブラー）は境界付近の画素を「元の空の色」と
    /// 「新しい空の色」でなじませるが、その混ざり具合が境界のすぐ外側に元の空の色を薄く
    /// 残してしまい、青い縁（ハロー）として見えてしまう。フェザリングの前にマスクを外側へ
    /// 少し広げておくことで、その境界付近を新しい空で塗り潰し、ハローの元になる元の空の色を
    /// 覆い隠す。0 で無効。
    var maskDilationFraction: CGFloat = 0.0075
    /// 新しい空の明るさを元写真の空に寄せる簡易トーンマッチを行うか。
    ///
    /// なぜ必要か: 例えば「昼の写真」に「真っ赤な夕焼け空」を単純に貼り合わせると、
    /// 空だけが浮いて見える。v1 は色相までは合わせず、明るさ（輝度）だけを
    /// 元写真の空領域に寄せる最小限のトーンマッチで「馴染み」を出す。
    var matchForegroundTone: Bool = true
}

/// 空差し替えの合成結果
///
/// 画像本体だけでなく SkyMask 由来の統計値も併せて返す。呼び出し側（UI）が
/// 「空が少ない写真に差し替えを試みた」等の警告表示を出す際の判断材料になる。
struct SkyReplacementResult {
    /// 合成後の画像。orientation 焼き込み済み（`.up`）・Display P3 で出力される。
    let image: UIImage
    /// 元写真の空被覆率 0...1（`SkyMask.skyCoverage` をそのまま転送）
    let skyCoverage: Double
    /// 元写真のマスク信頼度 0...1（`SkyMask.confidence` をそのまま転送）
    let confidence: Double
}

/// 空差し替え合成時に発生しうるエラー
enum SkyReplacementError: Error {
    /// CGImage を取得できない・extent が空など、入力画像そのものが不正
    case invalidInput
    /// マスクの空被覆率が閾値未満で、差し替えても効果が乏しい（誤爆防止のガード）
    case noSkyDetected
    /// フィルタグラフ構築・画素読み出し・最終レンダリングのいずれかが失敗
    case compositingFailed
}

/// 元写真の空領域を、新しい空の画像で差し替える合成エンジン。
///
/// 処理の流れ（`replaceSky` 内のコメントの手順番号と対応）:
/// 1. 向き正規化（EXIF orientation をピクセルへ焼き込む）
/// 2. `SkyMaskProviding` で空マスクを生成
/// 3. 空被覆率が低すぎる場合はガードして throw（誤爆防止）
/// 4. 新しい空を元写真の extent へ aspect-fill
/// 5.（任意）新しい空の明るさを元写真の空領域に寄せる簡易トーンマッチ
/// 6. マスクを膨張（6a. ハロー対策で境界を外側へ広げる）→ フェザリング（6b. 境界のなじみ）
/// 7. `CIBlendWithMask` でマスク合成
/// 8. レンダリングして `.up` 焼き込み済み UIImage を返す
///
/// なぜ `SkyMaskProviding` を注入式にするか: v1 はヒューリスティック実装（`HeuristicSkyMaskProvider`）だが、
/// 将来 CoreML ベースのセグメンテーションへ差し替える可能性があるため、この合成器はマスクの
/// 生成方法を意識しない。
final class SkyReplacementCompositor {

    // MARK: - Properties

    /// 画素読み出し・最終レンダリングに使う CIContext（テスト時は差し替え可能にするため注入式）
    private let ciContext: CIContext
    /// 空マスク生成の実装（差し替え可能）
    private let maskProvider: SkyMaskProviding

    // MARK: - 定数（マジックナンバー回避）

    /// この値未満の skyCoverage は「空がほぼ写っていない」とみなし、差し替えを拒否する。
    ///
    /// なぜ拒否するか: 空がほとんど無い写真に無理やり新しい空を貼ると、地面や被写体の一部が
    /// 誤って空色に置き換わり不自然な結果になる（マスクの信頼性が低い領域が支配的なため）。
    private static let minimumSkyCoverage: Double = 0.05

    /// トーンマッチの EV 補正量をこの範囲にクランプする。
    ///
    /// なぜクランプするか: 元の空と新しい空の明るさ差が極端な場合（例: 快晴の昼と夜空）、
    /// 無制限に補正すると新しい空の色味自体が失われてしまう（白飛び・黒つぶれ）。
    /// 「馴染ませる」程度の補正に留めるための上限。
    private static let toneMatchEVClampRange: ClosedRange<Double> = -1.0...1.0

    /// マスク加重平均を求める際の分母（マスク平均値）がゼロに近いときのゼロ除算防止用の下限値
    private static let minimumMaskAverageDenominator: Double = 0.001

    /// log2 計算時のゼロ除算・log(0) 発散防止用の微小値
    private static let luminanceEpsilon: Double = 0.001

    /// BT.709 相対輝度の重み（`ImageCompositor.readableTextColor` / `ExposureContrast.metal` と同一係数。
    /// 既存の輝度計算と一貫性を持たせるため同じ値を使う）
    private static let luminanceRedWeight: Double = 0.2126
    private static let luminanceGreenWeight: Double = 0.7152
    private static let luminanceBlueWeight: Double = 0.0722

    // MARK: - Init

    /// - Parameters:
    ///   - ciContext: レンダリング・画素読み出しに使う CIContext。
    ///     テストでは軽量な `CIContext()` を注入できるようにするため引数化している。
    ///   - maskProvider: 空マスク生成の実装。
    init(
        ciContext: CIContext = CIContextPool.shared.ciContext,
        maskProvider: SkyMaskProviding = HeuristicSkyMaskProvider()
    ) {
        self.ciContext = ciContext
        self.maskProvider = maskProvider
    }

    // MARK: - Public

    /// 元写真の空領域を newSky の画像で差し替える。
    /// - Parameters:
    ///   - photo: 元写真（差し替え対象）
    ///   - newSky: 新しい空の画像（元写真の extent へ aspect-fill される）
    ///   - options: 差し替えオプション
    /// - Returns: 合成結果（画像＋マスク統計）
    func replaceSky(
        in photo: UIImage,
        with newSky: UIImage,
        options: SkyReplacementOptions = SkyReplacementOptions()
    ) async throws -> SkyReplacementResult {

        // 手順1: 向き正規化
        // ImageCompositor.composeToUIImage と同一パターン: cgImage → `.oriented` で
        // EXIF orientation をピクセル空間へ適用する（provider は orientation を扱わない前提のため）。
        guard let photoCGImage = photo.cgImage, let skyCGImage = newSky.cgImage else {
            throw SkyReplacementError.invalidInput
        }
        let photoCI = CIImage(cgImage: photoCGImage)
            .oriented(CGImagePropertyOrientation(photo.imageOrientation))
        let skyCI = CIImage(cgImage: skyCGImage)
            .oriented(CGImagePropertyOrientation(newSky.imageOrientation))

        guard !photoCI.extent.isEmpty else {
            throw SkyReplacementError.invalidInput
        }

        // 手順2: マスク生成（書き出し用途＝高精度な .export 品質）
        let skyMask = try await maskProvider.makeSkyMask(for: photoCI, quality: .export)

        // 手順3: 空なしガード（誤爆防止）
        guard skyMask.skyCoverage >= Self.minimumSkyCoverage else {
            throw SkyReplacementError.noSkyDetected
        }

        // 手順4: 新しい空を元写真の extent へ aspect-fill（短辺基準で拡縮 → 中央クロップ）
        guard var fittedSky = aspectFill(skyCI, to: photoCI.extent) else {
            throw SkyReplacementError.compositingFailed
        }

        // 手順5: 簡易トーンマッチ（任意）
        if options.matchForegroundTone {
            fittedSky = try toneMatched(fittedSky, toForegroundOf: photoCI, mask: skyMask.mask)
        }

        // 手順6a: マスクの膨張（ハロー対策。境界付近に残る元の空の色を新しい空で覆い隠す）
        let longSide = max(photoCI.extent.width, photoCI.extent.height)
        let dilationRadius = longSide * options.maskDilationFraction
        let dilatedMask = dilate(skyMask.mask, radius: dilationRadius, extent: photoCI.extent)

        // 手順6b: マスクのフェザリング（境界のなじみ）
        let featherRadius = max(1.0, longSide * options.featherRadiusFraction)
        let featheredMask = feather(dilatedMask, radius: featherRadius, extent: photoCI.extent)

        // 手順7: マスク合成
        // CIBlendWithMask は「マスクが白(1.0)の画素は inputImage、黒(0.0)の画素は backgroundImage が出る」
        // という対応関係を持つ。SkyMask は 1.0=空 なので、inputImage=新しい空 / backgroundImage=元写真 が正しい。
        let blend = CIFilter.blendWithMask()
        blend.inputImage = fittedSky
        blend.backgroundImage = photoCI
        blend.maskImage = featheredMask
        guard let blended = blend.outputImage?.cropped(to: photoCI.extent) else {
            throw SkyReplacementError.compositingFailed
        }

        // 手順8: レンダリング
        // ImageCompositor.composeToUIImage と同一パターン: RGBAh + Display P3 で書き出し、
        // orientation 適用済みのため `.up`（既存の焼き込み契約と整合）で UIImage 化する。
        guard let outputCGImage = ciContext.createCGImage(
            blended,
            from: photoCI.extent,
            format: .RGBAh,
            colorSpace: CIContextPool.shared.outputColorSpace
        ) else {
            throw SkyReplacementError.compositingFailed
        }

        // 手順9
        return SkyReplacementResult(
            image: UIImage(cgImage: outputCGImage),
            skyCoverage: skyMask.skyCoverage,
            confidence: skyMask.confidence
        )
    }

    // MARK: - Private: aspect-fill（手順4）

    /// image を targetExtent へ短辺基準で拡縮（aspect-fill）し、中央クロップして
    /// extent を targetExtent に厳密一致させる。
    ///
    /// `SkyCollageCompositor.fittedPhoto` の Lanczos 流儀（高品質縮小＋中央合わせ）を踏襲する。
    private func aspectFill(_ image: CIImage, to targetExtent: CGRect) -> CIImage? {
        // 原点をゼロ基準に正規化（入力 extent の origin が (0,0) でないケースに対応）
        let normalized = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
        )
        let inputWidth = normalized.extent.width
        let inputHeight = normalized.extent.height
        guard inputWidth > 0, inputHeight > 0, targetExtent.width > 0, targetExtent.height > 0 else {
            return nil
        }

        // aspect-fill: ターゲットを完全に覆う（＝はみ出す側が出る）よう、大きい方の拡大率を採用する
        let scale = max(targetExtent.width / inputWidth, targetExtent.height / inputHeight)

        let scaler = CIFilter.lanczosScaleTransform()
        scaler.inputImage = normalized
        scaler.scale = Float(scale)
        scaler.aspectRatio = 1
        guard let scaledRaw = scaler.outputImage else { return nil }

        // 出力原点がずれるケースに備えて再正規化
        let scaled = scaledRaw.transformed(
            by: CGAffineTransform(translationX: -scaledRaw.extent.minX, y: -scaledRaw.extent.minY)
        )
        let scaledWidth = scaled.extent.width
        let scaledHeight = scaled.extent.height

        // ターゲット中央に合わせて平行移動 → ターゲット矩形でクロップし extent を厳密一致させる
        let translateX = targetExtent.minX - (scaledWidth - targetExtent.width) / 2
        let translateY = targetExtent.minY - (scaledHeight - targetExtent.height) / 2
        let placed = scaled.transformed(by: CGAffineTransform(translationX: translateX, y: translateY))
        return placed.cropped(to: targetExtent)
    }

    // MARK: - Private: 簡易トーンマッチ（手順5）

    /// 新しい空 fittedSky の明るさを、元写真の空領域（mask で加重した部分）の明るさへ寄せる。
    ///
    /// 手順:
    /// 1. `CIMultiplyCompositing` で photoCI × mask を作り、`CIAreaAverage` で全体平均を取る
    ///    （= Σ(photo×mask)/N）。同様に mask 単体の平均（= Σ(mask)/N）も取る。
    /// 2. 加重平均 rgbSky = Σ(photo×mask) / Σ(mask) を成分ごとに計算する。
    /// 3. 新しい空 fittedSky の平均色 rgbNew を求める。
    /// 4. BT.709 輝度 L を比較し、EV 補正量 `log2((Lsky+ε)/(Lnew+ε))` を -1...1 にクランプして適用する。
    private func toneMatched(_ fittedSky: CIImage, toForegroundOf photoCI: CIImage, mask: CIImage) throws -> CIImage {
        let extent = photoCI.extent

        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = photoCI
        multiply.backgroundImage = mask
        guard let maskedPhoto = multiply.outputImage else {
            throw SkyReplacementError.compositingFailed
        }

        let maskedAverage = try areaAverageColor(of: maskedPhoto, extent: extent)
        let maskAverage = try areaAverageColor(of: mask, extent: extent).r
        let denominator = max(maskAverage, Self.minimumMaskAverageDenominator)
        let rgbSky = (
            r: maskedAverage.r / denominator,
            g: maskedAverage.g / denominator,
            b: maskedAverage.b / denominator
        )

        let rgbNew = try areaAverageColor(of: fittedSky, extent: extent)

        let lSky = luminance(rgbSky)
        let lNew = luminance(rgbNew)
        let rawEV = log2((lSky + Self.luminanceEpsilon) / (lNew + Self.luminanceEpsilon))
        let clampedEV = min(Self.toneMatchEVClampRange.upperBound, max(Self.toneMatchEVClampRange.lowerBound, rawEV))

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = fittedSky
        exposure.ev = Float(clampedEV)
        return exposure.outputImage ?? fittedSky
    }

    /// BT.709 相対輝度（`ImageCompositor.readableTextColor` / `ExposureContrast.metal` と同一係数）
    private func luminance(_ rgb: (r: Double, g: Double, b: Double)) -> Double {
        Self.luminanceRedWeight * rgb.r + Self.luminanceGreenWeight * rgb.g + Self.luminanceBlueWeight * rgb.b
    }

    /// `CIAreaAverage` で指定領域の平均色を読み取る。
    /// - Note: `CIAreaAverage` の出力は常に 1x1 の画像になるため、そこから 1 ピクセルだけ読み出す
    ///   （`SkyMaskProviderTests.averageMaskValue` と同型のパターン）。
    private func areaAverageColor(of image: CIImage, extent: CGRect) throws -> (r: Double, g: Double, b: Double) {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = extent

        guard let output = filter.outputImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SkyReplacementError.compositingFailed
        }
        guard let cgImage = ciContext.createCGImage(
            output,
            from: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            throw SkyReplacementError.compositingFailed
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let bitmapContext = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw SkyReplacementError.compositingFailed
        }
        bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return (Double(pixel[0]) / 255.0, Double(pixel[1]) / 255.0, Double(pixel[2]) / 255.0)
    }

    // MARK: - Private: マスクの膨張（手順6a）

    /// マスクを `CIMorphologyMaximum`（円形膨張）で外側へ広げる。
    ///
    /// なぜ膨張させるか: `SkyReplacementOptions.maskDilationFraction` のコメント参照。
    /// フェザリングだけでは境界のすぐ外側に元の空の色が薄く残り、青い縁（ハロー）として
    /// 見えてしまう。フェザリングの前にマスクの白領域（空）を radius 分だけ外側へ広げ、
    /// その分だけ新しい空で塗り潰すことでハローの元を覆い隠す。
    ///
    /// - Parameters:
    ///   - mask: 膨張対象のマスク（1.0=空、0.0=非空）
    ///   - radius: 膨張半径（px）。0.5 未満なら膨張をスキップし mask をそのまま返す。
    ///   - extent: クロップ先の矩形（入力画像の extent）
    private func dilate(_ mask: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        guard radius >= 0.5 else { return mask }

        let morphology = CIFilter.morphologyMaximum()
        morphology.inputImage = mask
        morphology.radius = Float(radius)
        return morphology.outputImage?.clampedToExtent().cropped(to: extent) ?? mask
    }

    // MARK: - Private: フェザリング（手順6b）

    /// マスクをガウシアンブラーで境界ぼかしする。
    ///
    /// blur → `clampedToExtent()` → crop の順は、`HeuristicSkyMaskProvider.smoothAndSharpenEdges` /
    /// `FilterGraphBuilder` のガウシアンブラー箇所と同一の既存流儀（ブラー結果の端を
    /// `clampedToExtent()` で外側へ引き伸ばしてからクロップすることで、クロップ後に
    /// 意図しない透明フチが残らないようにする）を踏襲する。
    private func feather(_ mask: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = mask
        blur.radius = Float(radius)
        return blur.outputImage?.clampedToExtent().cropped(to: extent) ?? mask
    }
}
