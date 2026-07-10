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
}
