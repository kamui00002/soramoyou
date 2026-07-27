// ⭐️ SkyMotionAssetPreparer.swift
// 「空を動かす」（Kling版）フェーズ1b: fal.ai へ送るための3アセット（source/sky_mask/ground_mask）
// と trajectory・aspectRatio を準備する純粋な準備処理。
//
//  SkyMotionAssetPreparer.swift
//  Soramoyou
//
// 設計書: docs/sky-motion-design.md（唯一のデータ契約の土台）
//   §1  livingSkyJobs スキーマ（sourcePath/skyMaskPath/groundMaskPath/aspectRatio/trajectory）
//   §4  マスク・軌跡の極性（PoC実証済み・変更禁止）
//     - static_mask_url（固定領域） = ground_mask（白=地上）
//     - dynamic_masks[0].mask_url（動かす領域） = sky_mask（白=空） + trajectories
//       （sky_mask の重心 → 水平方向に +40px の2点・ピクセル座標）
//     - マスクは2値化（フェザーではない。既存 Metal版 Living Sky のフェザーマスクとは別物）
//
// ⚠️ 命名が近い（`LivingSkyEngine` 等）既存の Metal ローカル版 Living Sky とは別機能。
//    本ファイルは mp4 生成（`makeFrame` 相当）を持たない。mp4 は fal.ai 側が作る。
//    既存 Living Sky 系ファイルには一切手を入れない（温存・別名で新規実装）。
//
// 責務:
// - `LivingSkyEngine.prepareAsync` の①②（向き正規化・長辺1920縮小）を移植する
// - `HeuristicSkyMaskProvider.makeSkyMask()` で空マスクを取得し、2値化（閾値127相当）する
// - 2値化マスクを反転して ground_mask を作る
// - 2値化マスクの重心 + 水平 +40px の2点を trajectory として返す（ピクセル座標）
// - 画像の縦横比を "16:9"/"9:16"/"1:1" のいずれかへ近似する
// - source(JPEG)/sky_mask(PNG)/ground_mask(PNG) の Data を返す（Storage アップロードは
//   `SkyMotionJobService` の責務。本クラスはアップロードを行わない）

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import os
import UIKit

/// `SkyMotionAssetPreparer` の処理中に発生しうるエラー
enum SkyMotionAssetPreparerError: Error {
    /// UIImage → CIImage 変換に失敗した（cgImage が取得できない等）
    case invalidInput
    /// 長辺縮小のフィルタグラフ構築に失敗した
    case preparationFailed
    /// 空マスクのラスタライズ（CIImage → 生ピクセル配列）に失敗した
    case maskRasterizationFailed
    /// source.jpg / sky_mask.png / ground_mask.png の Data エンコードに失敗した
    case encodingFailed
}

/// `SkyMotionAssetPreparer.prepare` の出力。3ファイルの Data と trajectory・aspectRatio を持つ。
///
/// - Note: Storage アップロード・Firestore ジョブ作成は `SkyMotionJobService` の責務。
///   本 struct は「準備済みデータ」を受け渡すだけの値オブジェクト。
struct PreparedSkyMotionAssets {
    /// 元の空写真（編集確定後・向き正規化・長辺1920縮小済み）の JPEG Data
    let sourceData: Data
    /// 空マスク（白=空）の2値化 PNG Data。`HeuristicSkyMaskProvider` 出力を閾値127で2値化したもの
    let skyMaskData: Data
    /// 地上マスク（白=地上）の2値化 PNG Data。sky_mask の反転
    let groundMaskData: Data
    /// sky_mask 重心 → 水平方向 +40px の2点（ピクセル座標・原点は画像左上・y下向き）
    let trajectory: [CGPoint]
    /// 近似した縦横比。"16:9" | "9:16" | "1:1" のいずれか
    let aspectRatio: String
}

/// 「空を動かす」用アセット準備の実処理クラス。
///
/// `LivingSkyEngine` と同様、Metal カーネルは使わない（本クラスは CIImage フィルタと
/// CPU ラスタライズのみで完結する。動画生成そのものは fal.ai 側が行うため）。
final class SkyMotionAssetPreparer {
    // MARK: - 定数（マジックナンバー回避）

    /// 長辺の縮小上限px。`LivingSkyEngine.exportMaxLongSide` と同じ値を採用する
    /// （1本の動画生成という非リアルタイム用途のため、プレビュー用の1080ではなく
    /// 書き出し品質の1920を使う）。
    private static let maxLongSide: CGFloat = 1920

    /// 2値化の閾値（0...255）。設計書「閾値127相当」に対応。
    private static let binarizeThreshold: UInt8 = 127

    /// 既定（フォールバック）の水平ドリフト量＝**画像幅に対する比率**。
    /// 実際の生成時は `SkyMotionPreset.driftWidthRatio` の値を
    /// `prepare(image:driftWidthRatio:)` に渡す。internal なのはデフォルト引数と
    /// テスト（`SkyMotionAssetPreparerTests`）から参照するため。
    ///
    /// ⚠️ 絶対pxではなく比率で持つ理由: 写真は長辺1920に縮小されるため、同じ絶対pxでも
    ///    横写真(幅1920)は縦写真(幅1440)より相対移動量が1.33倍小さくなり、
    ///    「横写真だけ雲が動いて見えない」不具合になっていた（2026-07-28 実機FB）。
    static let driftWidthRatioDefault: CGFloat = SkyMotionPreset.standard.driftWidthRatio

    /// source.jpg の JPEG 品質
    private static let jpegQuality: CGFloat = 0.9

    /// aspect_ratio 近似の候補（表記, width/height の比率）
    private static let aspectRatioCandidates: [(label: String, ratio: Double)] = [
        ("16:9", 16.0 / 9.0),
        ("9:16", 9.0 / 16.0),
        ("1:1", 1.0),
    ]

    private static let logger = Logger(
        subsystem: "com.soramoyou.photo-editor",
        category: "SkyMotionAssetPreparer"
    )

    // MARK: - Properties

    /// 空マスク生成の実装（差し替え可能。テストでは軽量な実装を注入できる）
    private let maskProvider: SkyMaskProviderProtocol

    /// ラスタライズ・PNG/JPEGエンコードに使う CIContext
    private let ciContext: CIContext

    // MARK: - Init

    /// - Parameters:
    ///   - maskProvider: 空マスク生成の実装。差し替え可能（テスト用に軽量実装を注入できる）。
    ///   - ciContext: レンダリングに使う CIContext。既定は共有プール。
    init(
        maskProvider: SkyMaskProviderProtocol = HeuristicSkyMaskProvider(),
        ciContext: CIContext = CIContextPool.shared.ciContext
    ) {
        self.maskProvider = maskProvider
        self.ciContext = ciContext
    }

    // MARK: - Public

    /// 編集確定後の写真から `PreparedSkyMotionAssets` を生成する。
    ///
    /// - Note: 重い処理本体は `Task.detached` にオフロードし、呼び出し元のアクター
    ///   （多くは MainActor）をブロックしないようにする（`LivingSkyEngine.prepare` と同じ流儀）。
    /// - Parameter driftWidthRatio: trajectory の水平ドリフト量＝雲の移動量を
    ///   **縮小後の画像幅に対する比率**で指定する。`SkyMotionPreset.driftWidthRatio` の値を渡す。
    func prepare(
        image: UIImage,
        driftWidthRatio: CGFloat = SkyMotionAssetPreparer.driftWidthRatioDefault
    ) async throws -> PreparedSkyMotionAssets {
        let workTask = Task.detached(priority: .userInitiated) { () async throws -> PreparedSkyMotionAssets in
            try await self.prepareAsync(image: image, driftWidthRatio: driftWidthRatio)
        }
        return try await workTask.value
    }

    // MARK: - Private: 処理本体（Task.detached からオフロードして呼ばれる）

    private func prepareAsync(image: UIImage, driftWidthRatio: CGFloat) async throws -> PreparedSkyMotionAssets {
        // 手順①②: 向き正規化 + 長辺1920縮小（LivingSkyEngine.prepareAsync の①②を移植）
        let photo = try Self.normalizeAndScale(image: image, maxLongSide: Self.maxLongSide)

        // 手順③: 空マスク生成。.export品質（384pxグリッド）を使う。
        // 動画1本の生成という非リアルタイム用途のため、プレビュー用の高速・低精度(.preview)ではなく
        // 境界精度を優先する書き出し用品質を選ぶ。
        let skyMask = try await maskProvider.makeSkyMask(for: photo, quality: .export)

        // 手順④: マスクをラスタライズ（row0=画像上端のグレースケールバイト列）。
        // `HeuristicSkyMaskProvider.readRGBA8Pixels` と同じ idiom（format: .RGBA8 + sRGB明示）。
        // ⚠️ ここで得るバイト列は「行0=画像の上端」（CGContext に draw した場合の標準的な走査順）。
        //    これは動画/画像APIが期待する「左上原点・y下向き」のピクセル座標系とそのまま一致するため、
        //    以降の重心計算（centroidPixel）は追加のY反転を一切行わない。CIImage自体は左下原点だが、
        //    このラスタライズ処理が座標系の変換点であり、ここより後段は「素直な画像ピクセル座標」に統一される。
        let (grayBytes, width, height) = try Self.rasterizeGrayscaleBytes(
            skyMask.mask,
            extent: photo.extent,
            ciContext: ciContext
        )

        // 手順⑤: 2値化・反転・重心（純関数・テスト対象）
        let skyBytes = Self.binarizeMaskBytes(grayBytes, threshold: Self.binarizeThreshold)
        let groundBytes = Self.invertMaskBytes(skyBytes)

        // 空が1画素も検出できない場合（例: 完全な地上写真）は画像中心へフォールバックする。
        // trajectory を欠落させて Functions 側の処理を止めるより、中心を使って
        // 「ほぼ動かない」動画になる方が DEBUG 検証としては実用的なため。
        // ⚠️ O(width*height) の走査なので、フォールバック判定用に2回呼ばず1回の結果を使い回す。
        let detectedCentroid = Self.centroidPixel(binaryBytes: skyBytes, width: width, height: height)
        let centroid = detectedCentroid ?? CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        if detectedCentroid == nil {
            Self.logger.warning("空マスクが空（0画素）のため画像中心へフォールバックした")
        }
        let driftPixels = Self.driftPixels(imageWidth: CGFloat(width), ratio: driftWidthRatio)
        let trajectory = [centroid, CGPoint(x: centroid.x + driftPixels, y: centroid.y)]

        // 手順⑥: aspect比の近似（純関数）
        let aspectRatio = Self.nearestAspectRatio(width: photo.extent.width, height: photo.extent.height)

        // 手順⑦: Data化
        let sourceData = try Self.encodeJPEG(photo, ciContext: ciContext, quality: Self.jpegQuality)
        let skyMaskData = try Self.encodeGrayscalePNG(bytes: skyBytes, width: width, height: height)
        let groundMaskData = try Self.encodeGrayscalePNG(bytes: groundBytes, width: width, height: height)

        return PreparedSkyMotionAssets(
            sourceData: sourceData,
            skyMaskData: skyMaskData,
            groundMaskData: groundMaskData,
            trajectory: trajectory,
            aspectRatio: aspectRatio
        )
    }

    // MARK: - Pure Functions（テスト対象: SkyMotionAssetPreparerTests）

    /// マスクのグレースケールバイト列（0...255）を閾値で2値化する（0 または 255 のみ）。
    /// 設計書「2値化（フェザーではない）」に対応。`threshold` 以上を空（255）とみなす。
    static func binarizeMaskBytes(_ bytes: [UInt8], threshold: UInt8 = SkyMotionAssetPreparer.binarizeThreshold) -> [UInt8] {
        bytes.map { $0 >= threshold ? 255 : 0 }
    }

    /// 2値化バイト列を反転する（sky_mask → ground_mask）。0/255 の単純反転のため
    /// 入力が非2値でも安全（255 - v）。
    static func invertMaskBytes(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { 255 - $0 }
    }

    /// 2値化マスクの重心をピクセル座標（左上原点・y下向き）で返す。
    ///
    /// - Important: `binaryBytes` は「行0=画像の上端」の走査順であること（`rasterizeGrayscaleBytes`
    ///   の出力契約）。この関数自体はY反転を一切行わず、バッファの行インデックスをそのまま
    ///   ピクセルYとして扱う。呼び出し側がこの前提を満たさないバッファを渡すと上下逆の
    ///   trajectory になるため、必ず `rasterizeGrayscaleBytes` の出力（または同じ走査順の
    ///   テスト用バッファ）を渡すこと。
    /// - Returns: 白画素（値 >= 128）が1つも無い場合は nil。
    static func centroidPixel(binaryBytes: [UInt8], width: Int, height: Int) -> CGPoint? {
        guard width > 0, height > 0, binaryBytes.count == width * height else { return nil }

        var sumX: Double = 0
        var sumY: Double = 0
        var count: Double = 0

        for row in 0 ..< height {
            let rowStart = row * width
            for col in 0 ..< width {
                if binaryBytes[rowStart + col] >= 128 {
                    sumX += Double(col)
                    sumY += Double(row)
                    count += 1
                }
            }
        }

        guard count > 0 else { return nil }
        return CGPoint(x: sumX / count, y: sumY / count)
    }

    /// 雲の水平移動量を「画像幅に対する比率」から実px量へ変換する（純関数・テスト対象）。
    ///
    /// ⚠️ ここを絶対pxで固定してはいけない。写真は長辺1920に縮小されるため、
    ///    横写真は幅1920・縦写真は幅1440となり、同じ絶対pxでは横写真の相対移動量が
    ///    1.33倍小さくなる。実機では「横写真だけ雲が止まって見える」として現れた（2026-07-28 FB）。
    ///    比率で持てば、どの向きの写真でも画面に対して同じ割合だけ流れる。
    /// - Parameters:
    ///   - imageWidth: 縮小後の画像幅(px)。
    ///   - ratio: `SkyMotionPreset.driftWidthRatio`（幅に対する比率）。
    static func driftPixels(imageWidth: CGFloat, ratio: CGFloat) -> CGFloat {
        imageWidth * ratio
    }

    /// 画像の縦横比を "16:9" / "9:16" / "1:1" のいずれか最も近いものへ近似する。
    ///
    /// 対数比較を使う理由: 16:9(≈1.78) と 9:16(≈0.56) のように候補が桁違いに離れている場合、
    /// 単純な差分（線形距離）だと極端な縦長/横長比率で不自然な誤判定をしうる。
    /// log(ratio) 空間での距離にすることで「何倍伸びているか」を対称に評価できる。
    static func nearestAspectRatio(width: CGFloat, height: CGFloat) -> String {
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return "1:1" }

        let ratio = Double(width / height)
        let logRatio = log(ratio)

        let nearest = aspectRatioCandidates.min { lhs, rhs in
            abs(log(lhs.ratio) - logRatio) < abs(log(rhs.ratio) - logRatio)
        }
        return nearest?.label ?? "1:1"
    }

    // MARK: - Private Helpers（非純粋: CIContext / IO 依存）

    /// `LivingSkyEngine.prepareAsync` の①②（向き正規化・長辺縮小）と同一パターン。
    /// スケール後は origin をゼロ基準に正規化する（後続のラスタライズ・マスク生成のズレ防止）。
    private static func normalizeAndScale(image: UIImage, maxLongSide: CGFloat) throws -> CIImage {
        let normalized = image.withNormalizedOrientation()
        guard let cgImage = normalized.cgImage else {
            throw SkyMotionAssetPreparerError.invalidInput
        }
        let rawCIImage = CIImage(cgImage: cgImage)
        guard !rawCIImage.extent.isEmpty, !rawCIImage.extent.isInfinite else {
            throw SkyMotionAssetPreparerError.invalidInput
        }

        let longSide = max(rawCIImage.extent.width, rawCIImage.extent.height)
        guard longSide > maxLongSide else {
            return rawCIImage
        }

        let scale = maxLongSide / longSide
        let scaleFilter = CIFilter.lanczosScaleTransform()
        scaleFilter.inputImage = rawCIImage
        scaleFilter.scale = Float(scale)
        scaleFilter.aspectRatio = 1
        guard let scaledRaw = scaleFilter.outputImage else {
            throw SkyMotionAssetPreparerError.preparationFailed
        }
        return scaledRaw.transformed(
            by: CGAffineTransform(translationX: -scaledRaw.extent.minX, y: -scaledRaw.extent.minY)
        )
    }

    /// マスク CIImage を「行0=画像の上端」のグレースケールバイト列にラスタライズする。
    ///
    /// `HeuristicSkyMaskProvider.readRGBA8Pixels` と同じ idiom（CIContext.createCGImage に
    /// format/colorSpace を明示 → CGContext に draw → 生バイトを読む）。マスクは R=G=B の
    /// グレースケールであることが `HeuristicSkyMaskProvider` の実装（`makeGrayscaleImage` が
    /// 単一チャンネル値を全チャンネルへ複製して生成し、以降のフィルタも scale/bias を
    /// 全チャンネル同一に適用する）から保証されるため、Rチャンネルだけを読めばよい。
    private static func rasterizeGrayscaleBytes(
        _ mask: CIImage,
        extent: CGRect,
        ciContext: CIContext
    ) throws -> (bytes: [UInt8], width: Int, height: Int) {
        guard !extent.isEmpty, !extent.isInfinite,
              extent.width >= 1, extent.height >= 1
        else {
            throw SkyMotionAssetPreparerError.maskRasterizationFailed
        }

        let width = max(1, Int(extent.width.rounded()))
        let height = max(1, Int(extent.height.rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SkyMotionAssetPreparerError.maskRasterizationFailed
        }

        let pixelRect = CGRect(x: extent.origin.x, y: extent.origin.y, width: CGFloat(width), height: CGFloat(height))
        guard let cgImage = ciContext.createCGImage(
            mask,
            from: pixelRect,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            throw SkyMotionAssetPreparerError.maskRasterizationFailed
        }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let bitmapContext = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SkyMotionAssetPreparerError.maskRasterizationFailed
        }
        bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var gray = [UInt8](repeating: 0, count: width * height)
        for i in 0 ..< (width * height) {
            gray[i] = rgba[i * 4]
        }
        return (gray, width, height)
    }

    /// 元写真（縮小済み CIImage）を JPEG Data にエンコードする。
    /// `StorageService.encodeJPEG` と同様 CIContext.jpegRepresentation を使うが、
    /// 外部API（fal.ai）連携用のため色空間は素直な sRGB を採用する
    /// （投稿表示用途の Display P3 ワイドガンマットは不要）。
    private static func encodeJPEG(_ image: CIImage, ciContext: CIContext, quality: CGFloat) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SkyMotionAssetPreparerError.encodingFailed
        }
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        guard let data = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
            throw SkyMotionAssetPreparerError.encodingFailed
        }
        return data
    }

    /// グレースケールバイト列（0...255・行0=画像の上端）を PNG Data にエンコードする。
    /// `HeuristicSkyMaskProvider.makeGrayscaleImage` と同じ CGContext(DeviceGray) の idiom。
    private static func encodeGrayscalePNG(bytes: [UInt8], width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, bytes.count == width * height else {
            throw SkyMotionAssetPreparerError.encodingFailed
        }
        var mutableBytes = bytes
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let bitmapContext = CGContext(
            data: &mutableBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let cgImage = bitmapContext.makeImage() else {
            throw SkyMotionAssetPreparerError.encodingFailed
        }
        guard let data = UIImage(cgImage: cgImage).pngData() else {
            throw SkyMotionAssetPreparerError.encodingFailed
        }
        return data
    }
}
