//
//  CIImageTestHelpers.swift
//  SoramoyouTests
//
//  ⭐️ EditToolsPhotosParityTests / FilterGraphBuilderTests で共有するテストヘルパー。
//  PR レビュー指摘 (SP1) 対応: 各テストファイルにほぼ同型のヘルパーが重複していたため
//  1 本化する。
//

import XCTest
import CoreImage

/// テスト専用の CIImage 生成・サンプリングヘルパー
enum CIImageTestHelpers {

    /// 上半分=暗いグレー・下半分=明るいグレー の2バンド画像を生成する。
    ///
    /// ハイライト/シャドウ・ブリリアンスの局所適応版 (.final) は暗部・明部で別方向の
    /// 処理を行うため、単色画像ではなく明暗差のある画像でないと方向性を検証できない
    /// （`CIHighlightShadowAdjust` は局所解析を行う適応フィルタのため）。
    static func makeTwoBandCIImage(darkGray: UInt8 = 38, brightGray: UInt8 = 217, size: Int = 64) -> CIImage {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let c: UInt8 = y < size / 2 ? darkGray : brightGray
                bytes[i]     = c
                bytes[i + 1] = c
                bytes[i + 2] = c
                bytes[i + 3] = 255
            }
        }
        let data = Data(bytes)
        return CIImage(bitmapData: data,
                       bytesPerRow: size * 4,
                       size: CGSize(width: size, height: size),
                       format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// 指定 x, y 起点の 4x4 領域の RGBA 平均を取得
    static func sampleRegionRGB(_ image: CIImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        let context = CIContext()
        let region = CGRect(x: x, y: y, width: 4, height: 4)
        guard let cg = context.createCGImage(image.cropped(to: region), from: region) else {
            XCTFail("CGImage 生成失敗")
            return (0, 0, 0)
        }
        var bytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &bytes,
                            width: 4,
                            height: 4,
                            bitsPerComponent: 8,
                            bytesPerRow: 4 * 4,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: 4, height: 4))

        var r: Double = 0, g: Double = 0, b: Double = 0
        let pixelCount = 4 * 4
        for i in stride(from: 0, to: bytes.count, by: 4) {
            r += Double(bytes[i])
            g += Double(bytes[i + 1])
            b += Double(bytes[i + 2])
        }
        return (r / Double(pixelCount), g / Double(pixelCount), b / Double(pixelCount))
    }

    /// 鋭い垂直エッジを持つ CIImage を生成する（左半分=黒0、右半分=白255）。
    ///
    /// PR レビュー指摘 (Fix4) 対応: `LivingSkyEngineTests` の private ヘルパーをここへ昇格し、
    /// `LivingSkyVideoExporterTests` 等の他テストからも共有できるようにする。
    /// 局所的に線形なコンテンツ（グラデーション等）では二相クロスフェードの加重平均位相が
    /// 定数であるため差分が打ち消し合ってしまうため、鋭いエッジで局所的な変化を作る必要がある
    /// （詳細背景は `LivingSkyEngineTests.test_motion_frame0DiffersFromQuarterLoop` のコメント参照）。
    static func makeVerticalEdgeCIImage(size: Int) -> CIImage {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let c: UInt8 = x < size / 2 ? 0 : 255
                bytes[i]     = c
                bytes[i + 1] = c
                bytes[i + 2] = c
                bytes[i + 3] = 255
            }
        }
        let data = Data(bytes)
        return CIImage(bitmapData: data,
                       bytesPerRow: size * 4,
                       size: CGSize(width: size, height: size),
                       format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// CIImage を RGBA8 の生バイト列としてレンダリングする（厳密なピクセル一致比較用）。
    ///
    /// PR レビュー指摘 (Fix4) 対応: `LivingSkyEngineTests` の private ヘルパーをここへ昇格。
    /// `sampleRegionRGB` は 4x4 領域の平均値のため、「全画素が完全一致するか」の検証には使えず、
    /// 専用のピクセル単位レンダリングが必要な場合はこちらを使う。
    static func renderRGBA8Pixels(_ image: CIImage, extent: CGRect) throws -> [UInt8] {
        let context = CIContext()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace) else {
            XCTFail("CGImage 生成に失敗した")
            return []
        }

        let width = Int(extent.width)
        let height = Int(extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let bitmapContext = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("CGContext 生成に失敗した")
            return []
        }
        bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}
