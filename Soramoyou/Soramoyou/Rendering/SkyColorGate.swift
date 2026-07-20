// ⭐️ SkyColorGate.swift
// ワンタップ空補正の色ゲート（青染み軽減）
//
//  SkyColorGate.swift
//  Soramoyou
//

import CoreImage
import CoreImage.CIFilterBuiltins

/// ワンタップ空補正が「壁など非空の誤検出領域」に色を乗せてしまうのを軽減する適応ゲート。
///
/// 背景（2026-07-20 実写検証）:
/// `HeuristicSkyMaskProvider` は色相・彩度・明度＋縦位置の事前確率だけのヒューリスティックのため、
/// 明るいグレーの壁（低彩度・高明度＝雲の判定条件に酷似）を空として誤検出することがある
/// （見上げ構図の建物写真=IMG_8225系で実機確認）。固定の色相ルール（青だけ許可、等）は
/// 夕焼け・朝焼けの暖色の空で補正が完全に死んでしまうため採用できない。
///
/// 代わりに「この写真ごとの空パレット」（マスクの高信頼度領域から抽出した代表色2〜3個）を都度
/// 抽出し、パレットに近い色の画素だけ補正の効きを残す・遠い画素は効きを弱める適応ゲートを実装する。
///
/// 設計方針:
/// - `HeuristicSkyMaskProvider` / `SkyMaskProviderProtocol` 自体は変更しない。Sky Replacement など
///   他機能が同じ provider を共有しているため、ヒューリスティックの挙動を変えると影響範囲が
///   マスク生成の全消費者に広がってしまう。ゲートは「ワンタップ空補正」機能専用のポスト処理として
///   このファイルに閉じ、`EditViewModel` がマスク生成時（`ensureSkyMaskCached` /
///   `makeExportSkyMask`）に一度だけ適用してキャッシュする。`FilterGraphBuilder` 側のグラフ構造・
///   feather 順序（clamp→blur→crop）・マスクキャッシュの型（`CIImage?`）は一切変更しない。
/// - パレット抽出（CPU 画素読み出し）とLUT構築はマスク生成と同じタイミングで一度だけ行い、
///   ドラッグ中の毎フレーム再計算はしない（`CIColorCubeWithColorSpace` の入力データとして
///   キャッシュ済みマスクに合成してしまうため、以降の消費側は無変更で恩恵を受ける）。
enum SkyColorGate {

    // MARK: - 定数（マジックナンバー回避）

    /// CIColorCube の LUT 次元（64^3）
    static let lutDimension = 64

    /// パレット抽出時にサンプリング対象とするマスク値のしきい値（これ以上を「高信頼度」とみなす）
    private static let maskConfidenceThreshold: Double = 0.7
    /// 連続下降走査で「まだ空」とみなす行の高信頼度画素率の下限。
    ///
    /// ⚠️ 実写検証（IMG_8225）で 0.5 は不十分と判明: 見上げ構図で「壁」と「奥に見える本物の空」が
    /// 同じ行に混在すると、行全体で見た高信頼度画素率は壁を含んでいても 0.5 を超え続けてしまい、
    /// 壁のある行までサンプリング対象に含んでしまう。実際の行ごとの高信頼度画素率を測定したところ
    /// 「明確に空だけの行」は 0.85 以上、屋根の縁〜壁の遷移帯は 0.73 以下だったため、
    /// 0.80 に引き上げて遷移帯の手前で確実に打ち切るようにした。
    private static let rowContiguityThreshold: Double = 0.80
    /// 連続下降走査が1行も条件を満たさない場合のフォールバック上限（画像上端から何割まで）
    private static let fallbackTopFraction: Double = 0.25
    /// パレット抽出用ダウンサンプルの長辺（HeuristicSkyMaskProvider の preview グリッドと同程度）
    private static let sampleGridLongSide: CGFloat = 64
    /// 抽出する代表色の最大数
    private static let maxPaletteColors = 3
    /// 信頼できるパレットを作るために必要な最低サンプル数（未満ならゲート無効＝旧挙動）
    private static let minSampleCount = 8
    /// ゲートのなめらかな falloff 幅（0...1 の正規化 RGB 空間でのユークリッド距離）
    private static let falloffWidth: Double = 0.22
    /// falloff の中心距離（これ未満は重み1.0＝補正そのまま）
    private static let coreDistance: Double = 0.10
    /// farthest-point クラスタリングで「新しい中心」として採用する最低距離^2
    /// （これ未満なら色が単一クラスタに収束しているとみなし打ち切る）
    private static let clusterMinDistance2: Double = 0.01
    /// 縦位置の裏付けゲート: パレット抽出の連続下降走査の下限（`verticalCutoffNorm`）から
    /// さらに何割（画像高さ比）まで「色ゲートを全面的に信頼する」かのフェード幅。
    ///
    /// ⚠️ 実写検証（IMG_8225）で判明: 見上げ構図の背景に写る建物の壁は、逆光の曇り空と
    /// 実測 RGB 距離が近く（濃い影がかった雲＝濃い影がかった壁）、色距離だけのゲートでは
    /// 弁別できないケースがあった。パレット抽出済みの「地続きに確認できた空領域」から離れる
    /// ほど色ゲートの信頼度も下げる縦方向のフェードを併用し、色が一致していても抽出元から
    /// 大きく離れた領域では効きを弱める（固定の色相ルールではなく、パレット抽出そのものが
    /// 使った「地続き」の判定結果を再利用するだけなので、夕焼け等の暖色空にも同様に効く）。
    private static let verticalTrustFadeFraction: Double = 0.10

    // MARK: - 公開API

    /// `buildGateData` の結果。LUT データと、色ゲートを全面的に信頼してよい縦位置の下限
    /// （画像上端からの正規化位置）をまとめて保持する。
    struct GateData {
        /// `CIColorCubeWithColorSpace` 用の LUT データ（64^3 RGBA Float32）
        let colorCubeData: Data
        /// パレット抽出の連続下降走査が確認できた範囲（画像上端からの正規化位置 0...1）。
        /// `applyGate` はこの位置から `verticalTrustFadeFraction` 分だけ下までは色ゲートを
        /// そのまま信頼し、それ以降はなだらかに信頼度を下げる。
        let verticalCutoffNorm: Double
    }

    /// 画像とマスクから空色パレットを抽出し、色ゲート適用に必要なデータを構築する。
    /// サンプル不足（＝マスクの高信頼度領域がほぼ無い）の場合は nil を返し、
    /// 呼び出し側はゲート無効（旧挙動＝マスクそのまま）にフォールバックすること。
    ///
    /// - Parameters:
    ///   - image: マスク生成に使ったのと同じ基準（向き正規化＋回転反転適用後）の画像
    ///   - mask: `image` に対応する空マスク（グレースケール、1.0=空）
    ///   - ciContext: 画素読み出しに使う CIContext
    static func buildGateData(image: CIImage, mask: CIImage, ciContext: CIContext) -> GateData? {
        guard let extraction = extractPalette(image: image, mask: mask, ciContext: ciContext) else {
            return nil
        }
        let lutData = makeLUTData(palette: extraction.palette)
        return GateData(colorCubeData: lutData, verticalCutoffNorm: extraction.cutoffNorm)
    }

    /// 生成済みの `GateData` を使って `mask` に色ゲート＋縦位置の裏付けゲートを適用した
    /// 「精緻化マスク」を返す。CIImage は遅延評価グラフのため、この関数自体は重いラスタライズを
    /// 行わない（実際の GPU 計算は最終レンダリング時にのみ発生する＝毎フレーム再計算にはならない）。
    ///
    /// - Parameters:
    ///   - mask: 元の空マスク（フェザリング前。extent は `image` と一致している前提）
    ///   - image: ゲート判定に使う色のサンプル元画像（`mask` と同じ extent）
    ///   - gateData: `buildGateData` で構築したデータ
    static func applyGate(to mask: CIImage, sampling image: CIImage, gateData: GateData) -> CIImage {
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = image
        cube.cubeDimension = Float(lutDimension)
        cube.cubeData = gateData.colorCubeData
        cube.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let colorWeightImage = cube.outputImage else { return mask }

        let verticalGate = makeVerticalTrustGate(
            extent: image.extent,
            cutoffNormFromTop: gateData.verticalCutoffNorm,
            fadeBandFraction: verticalTrustFadeFraction
        )

        // gateWeightImage / verticalGate はどちらも R=G=B=重み・A=1 のグレースケール画像。
        // 全て opaque な画像同士の multiplyCompositing は per-channel の単純乗算に一致する。
        let multiplyColor = CIFilter.multiplyCompositing()
        multiplyColor.inputImage = mask
        multiplyColor.backgroundImage = colorWeightImage
        guard let colorGated = multiplyColor.outputImage else { return mask }

        let multiplyVertical = CIFilter.multiplyCompositing()
        multiplyVertical.inputImage = colorGated
        multiplyVertical.backgroundImage = verticalGate
        return multiplyVertical.outputImage?.cropped(to: mask.extent) ?? mask
    }

    /// 縦方向の「色ゲート信頼度」勾配画像を生成する。`cutoffNormFromTop`（連続下降走査が
    /// 地続きの空と確認できた最終行）を境界としてフェード帯を**前後に半分ずつ**配置する:
    /// `cutoffNormFromTop - fadeBandFraction/2` までは白(1.0)＝色ゲートをそのまま信頼、
    /// そこから `cutoffNormFromTop + fadeBandFraction/2` までなだらかに黒(0.0)へフェードし、
    /// それより下は常に 0.0（色が一致していても信頼しない）にする。
    ///
    /// ⚠️ 実写検証（IMG_8225）で判明: 当初は「カットオフ行=満信頼度(1.0)の開始点、そこから
    /// 下方向にのみフェード」という設計だったが、これだとカットオフ行の直後（＝屋根の縁の真下、
    /// 壁の最上段）がまだ高い信頼度を残したままになり、そこの色がパレット中の暗い雲影色と近い
    /// 場合に青染みが残ってしまった。カットオフ行そのものを「フェードの中間点」として扱うことで、
    /// カットオフ行に到達する頃には信頼度をすでに半分まで下げておき、壁の最上段（カットオフの
    /// 直後）では信頼度がほぼ0まで下がるようにする。
    private static func makeVerticalTrustGate(
        extent: CGRect,
        cutoffNormFromTop: Double,
        fadeBandFraction: Double
    ) -> CIImage {
        guard extent.width > 0, extent.height > 0 else {
            return CIImage(color: .white).cropped(to: extent)
        }
        // CI 座標系は y=0 が下端のため、画像上端からの正規化位置を「下端からの絶対座標」に変換する。
        let halfBand = fadeBandFraction / 2.0
        let fullTrustNormFromTop = cutoffNormFromTop - halfBand
        let zeroTrustNormFromTop = cutoffNormFromTop + halfBand
        let fullTrustYFromBottom = extent.origin.y + extent.height * (1.0 - fullTrustNormFromTop)
        let zeroTrustYFromBottom = extent.origin.y + extent.height * (1.0 - zeroTrustNormFromTop)

        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: extent.midX, y: fullTrustYFromBottom)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
        gradient.point1 = CGPoint(x: extent.midX, y: zeroTrustYFromBottom)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0)

        guard let output = gradient.outputImage else {
            return CIImage(color: .white).cropped(to: extent)
        }
        return output.cropped(to: extent)
    }

    // MARK: - パレット抽出（CPU、ダウンサンプル画像から）

    private static func extractPalette(
        image: CIImage,
        mask: CIImage,
        ciContext: CIContext
    ) -> (palette: [(r: Double, g: Double, b: Double)], cutoffNorm: Double)? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }

        let longSide = max(extent.width, extent.height)
        let scale = longSide > sampleGridLongSide ? sampleGridLongSide / longSide : 1.0
        let gridW = max(1, Int((extent.width * scale).rounded()))
        let gridH = max(1, Int((extent.height * scale).rounded()))

        guard let imagePixels = readRGBA8(image, gridW: gridW, gridH: gridH, ciContext: ciContext),
              let maskPixels  = readRGBA8(mask,  gridW: gridW, gridH: gridH, ciContext: ciContext) else {
            return nil
        }

        // 「マスク値が高くかつ画像上部寄り」の単純な固定割合（旧: topBiasFraction）は、
        // 誤検出領域（壁など）が実際の空と地続きに「白」判定され、かつ画像上部6割以内に
        // 収まっている構図（見上げ構図の建物写真=IMG_8225系）で誤検出領域までサンプリング
        // してしまい、パレット自体が汚染される実害が実写検証で確認された。
        // 代わりに `HeuristicSkyMaskProvider.detectHorizonNorm` と同型の「上端から連続で
        // 高信頼度とみなせる行を歩く」走査を使い、屋根の縁など低信頼度の行で歩行が止まった
        // 時点（＝地続きでない別ブロブに踏み込む前）までを抽出対象にする。
        let cutoffRow = detectContiguousConfidentRowCutoff(maskPixels: maskPixels, gridW: gridW, gridH: gridH)

        var samples: [(r: Double, g: Double, b: Double)] = []
        samples.reserveCapacity(gridW * gridH / 4)

        for row in 0..<cutoffRow {
            for col in 0..<gridW {
                let idx = (row * gridW + col) * 4
                let maskValue = Double(maskPixels[idx]) / 255.0
                guard maskValue >= maskConfidenceThreshold else { continue }

                let r = Double(imagePixels[idx])     / 255.0
                let g = Double(imagePixels[idx + 1]) / 255.0
                let b = Double(imagePixels[idx + 2]) / 255.0
                samples.append((r, g, b))
            }
        }

        guard samples.count >= minSampleCount else { return nil }

        let palette = clusterPalette(samples: samples, maxColors: maxPaletteColors)
        let cutoffNorm = gridH > 0 ? Double(cutoffRow) / Double(gridH) : 0
        return (palette: palette, cutoffNorm: cutoffNorm)
    }

    /// 画像上端から連続で「行の大半が高信頼度画素」とみなせる行数を数える
    /// （`HeuristicSkyMaskProvider.detectHorizonNorm` と同型のロジック）。
    ///
    /// なぜ「行の集計」で止めるか: 屋根の縁のように低信頼度の画素が並ぶ行を挟むと、
    /// その行で `rowContiguityThreshold` を下回り歩行が止まる。この境界より下（壁など
    /// 地続きでない別の高信頼度ブロブ）はパレット抽出の対象に含めない。
    private static func detectContiguousConfidentRowCutoff(maskPixels: [UInt8], gridW: Int, gridH: Int) -> Int {
        guard gridW > 0, gridH > 0 else { return 0 }

        var lastGoodRow = -1
        var row = 0
        while row < gridH {
            var confidentCount = 0
            let rowStart = row * gridW
            for col in 0..<gridW {
                let idx = (rowStart + col) * 4
                let v = Double(maskPixels[idx]) / 255.0
                if v >= maskConfidenceThreshold { confidentCount += 1 }
            }
            let fraction = Double(confidentCount) / Double(gridW)
            guard fraction >= rowContiguityThreshold else { break }
            lastGoodRow = row
            row += 1
        }

        guard lastGoodRow >= 0 else {
            // 1行も条件を満たさない（＝上端がそもそも高信頼度でない）場合のフォールバック。
            return max(1, Int(Double(gridH) * fallbackTopFraction))
        }
        return lastGoodRow + 1
    }

    /// 簡易な最遠点法（farthest-point sampling）+ 最近傍平均（Lloyd 法1回）によるクラスタリング。
    /// フル k-means を回すほどのサンプル数・精度要求ではないため、軽量な代表点抽出で十分。
    private static func clusterPalette(
        samples: [(r: Double, g: Double, b: Double)],
        maxColors: Int
    ) -> [(r: Double, g: Double, b: Double)] {
        guard !samples.isEmpty else { return [] }

        func dist2(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
            let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
            return dr * dr + dg * dg + db * db
        }

        // 平均色を起点に、既存中心から最も離れた点を順に新しい中心として選ぶ（最大 maxColors 個）
        var centers: [(r: Double, g: Double, b: Double)] = []
        let mean = (
            r: samples.reduce(0) { $0 + $1.r } / Double(samples.count),
            g: samples.reduce(0) { $0 + $1.g } / Double(samples.count),
            b: samples.reduce(0) { $0 + $1.b } / Double(samples.count)
        )
        centers.append(mean)

        while centers.count < maxColors {
            var farthest = samples[0]
            var farthestDist = -1.0
            for s in samples {
                let minDistToCenters = centers.map { dist2(s, $0) }.min() ?? 0
                if minDistToCenters > farthestDist {
                    farthestDist = minDistToCenters
                    farthest = s
                }
            }
            // 十分に離れた新しい中心が見つからない（＝色がほぼ単一クラスタに収束している）なら打ち切る
            guard farthestDist > clusterMinDistance2 else { break }
            centers.append(farthest)
        }

        // 各サンプルを最近傍の中心に割り当て、中心をクラスタ平均で更新（Lloyd 法1回のみ）
        var sums = centers.map { _ in (r: 0.0, g: 0.0, b: 0.0, count: 0) }
        for s in samples {
            var bestIndex = 0
            var bestDist = Double.greatestFiniteMagnitude
            for (i, c) in centers.enumerated() {
                let d = dist2(s, c)
                if d < bestDist {
                    bestDist = d
                    bestIndex = i
                }
            }
            sums[bestIndex].r += s.r
            sums[bestIndex].g += s.g
            sums[bestIndex].b += s.b
            sums[bestIndex].count += 1
        }

        return sums.compactMap { sum in
            guard sum.count > 0 else { return nil }
            return (r: sum.r / Double(sum.count), g: sum.g / Double(sum.count), b: sum.b / Double(sum.count))
        }
    }

    // MARK: - CIColorCube LUT 構築

    /// パレット色からの距離に基づくなめらかな重み（0...1）を各 RGB グリッド点について書き込んだ
    /// 64^3 の RGBA Float32 LUT を構築する。この計算は1回だけ（マスク生成のたび）行われ、
    /// 描画のホットパス（毎フレームの buildGraph 呼び出し）では再実行されない。
    private static func makeLUTData(palette: [(r: Double, g: Double, b: Double)]) -> Data {
        let n = lutDimension
        var cube = [Float](repeating: 0, count: n * n * n * 4)

        for bIndex in 0..<n {
            let bVal = Double(bIndex) / Double(n - 1)
            for gIndex in 0..<n {
                let gVal = Double(gIndex) / Double(n - 1)
                for rIndex in 0..<n {
                    let rVal = Double(rIndex) / Double(n - 1)

                    var minDist = Double.greatestFiniteMagnitude
                    for color in palette {
                        let dr = rVal - color.r, dg = gVal - color.g, db = bVal - color.b
                        let d = (dr * dr + dg * dg + db * db).squareRoot()
                        if d < minDist { minDist = d }
                    }

                    let weight = smoothFalloff(distance: minDist)
                    // CIColorCubeWithColorSpace の格子順序（Apple ドキュメント準拠）:
                    // オフセット = (r + g * n + b * n * n) * 4
                    let offset = (rIndex + gIndex * n + bIndex * n * n) * 4
                    cube[offset]     = Float(weight)
                    cube[offset + 1] = Float(weight)
                    cube[offset + 2] = Float(weight)
                    cube[offset + 3] = 1.0
                }
            }
        }

        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// distance <= coreDistance で 1.0（補正そのまま）、coreDistance...coreDistance+falloffWidth で
    /// smoothstep 状になめらかに 0 へ、それ以上で 0.0（補正を打ち消す）になる falloff。
    private static func smoothFalloff(distance: Double) -> Double {
        if distance <= coreDistance { return 1.0 }
        let t = min(1.0, max(0.0, (distance - coreDistance) / falloffWidth))
        // smoothstep(t) = 3t^2 - 2t^3 は 0→1 の滑らかな遷移。1 - smoothstep(t) で 1→0 に反転させる。
        let s = t * t * (3 - 2 * t)
        return 1.0 - s
    }

    // MARK: - 画素読み出し（HeuristicSkyMaskProvider.readRGBA8Pixels と同型のパターン）

    private static func readRGBA8(_ image: CIImage, gridW: Int, gridH: Int, ciContext: CIContext) -> [UInt8]? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        // CILanczosScaleTransform は「scale で縦横一律に拡縮 → aspectRatio で幅だけ追加調整」という
        // 2 段階の縮小モデルを取るため、まず高さを gridH に合わせる scale を求め、
        // 続けて幅を gridW に微調整する aspectRatio を求める（HeuristicSkyMaskProvider と同じ手法）。
        let heightScale = CGFloat(gridH) / extent.height
        let intermediateWidth = extent.width * heightScale
        let aspectRatio: CGFloat = intermediateWidth > 0 ? CGFloat(gridW) / intermediateWidth : 1.0

        let scaleFilter = CIFilter.lanczosScaleTransform()
        scaleFilter.inputImage = image
        scaleFilter.scale = Float(heightScale)
        scaleFilter.aspectRatio = Float(aspectRatio)

        guard let scaledImage = scaleFilter.outputImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let gridRect = CGRect(x: 0, y: 0, width: gridW, height: gridH)
        guard let cgImage = ciContext.createCGImage(
            scaledImage, from: gridRect, format: .RGBA8, colorSpace: colorSpace
        ) else {
            return nil
        }

        var pixels = [UInt8](repeating: 0, count: gridW * gridH * 4)
        guard let bitmapContext = CGContext(
            data: &pixels, width: gridW, height: gridH, bitsPerComponent: 8,
            bytesPerRow: gridW * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: gridW, height: gridH))
        return pixels
    }
}
