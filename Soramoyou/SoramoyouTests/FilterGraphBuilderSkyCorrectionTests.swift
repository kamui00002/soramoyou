//
//  FilterGraphBuilderSkyCorrectionTests.swift
//  SoramoyouTests
//
//  ⭐️ ワンタップ空補正（FilterGraphBuilder.buildGraph の skyMask 引数）のマスク合成テスト。
//  上半分白（空）・下半分黒（非空）のマスクを与え、intensity=1.0 のとき
//  上半分だけが変化し下半分は不変であること、intensity=0（または skyMask なし）で
//  完全に no-op になることを検証する。
//

import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import Soramoyou

final class FilterGraphBuilderSkyCorrectionTests: XCTestCase {

    // MARK: - Helpers
    // FilterGraphBuilderTests / SkyReplacementCompositorTests のヘルパーと同型のパターンを
    // このファイル内に private で持つ（テストターゲットに共有ヘルパーが無いため重複を許容する）。

    private let context = CIContext()
    private let imageSize = CGSize(width: 64, height: 64)

    /// 単色の CIImage を生成する（origin はゼロ基準）
    private func makeSolidImage(color: CIColor, size: CGSize) -> CIImage {
        CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// 「視覚的な上半分＝白(1.0)・下半分＝黒(0.0)」のマスクを生成する。
    /// - Note: CIImage の座標系は y=0 が下端（UIKit と上下逆）のため、
    ///   視覚的な上半分は CI 座標系では y >= H/2 の領域になる。
    private func makeTopHalfWhiteMask(size: CGSize) -> CIImage {
        let white = CIImage(color: CIColor.white)
            .cropped(to: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        let black = CIImage(color: CIColor.black)
            .cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
        return white.composited(over: black).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// 指定領域（CI 座標系）の平均色 0...1 を取得する
    private func averageColor(of image: CIImage, in rect: CGRect) -> (r: Double, g: Double, b: Double) {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = rect

        guard let outputImage = filter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: CGRect(x: 0, y: 0, width: 1, height: 1)) else {
            XCTFail("areaAverage の CGImage 化に失敗")
            return (0, 0, 0)
        }

        var pixelData = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let pixelContext = CGContext(
            data: &pixelData,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            XCTFail("CGContext 生成に失敗")
            return (0, 0, 0)
        }
        pixelContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return (Double(pixelData[0]) / 255.0, Double(pixelData[1]) / 255.0, Double(pixelData[2]) / 255.0)
    }

    /// 「視覚的な上端バンド」「視覚的な下端バンド」（フェザー境界を避けて中央寄りに 20%幅で取る）
    private var topBand: CGRect {
        CGRect(x: 0, y: imageSize.height * 0.7, width: imageSize.width, height: imageSize.height * 0.2)
    }
    private var bottomBand: CGRect {
        CGRect(x: 0, y: imageSize.height * 0.1, width: imageSize.width, height: imageSize.height * 0.2)
    }

    // MARK: - Tests

    /// intensity=1.0・上半分白マスクのとき、上半分（空）だけが変化し下半分（非空）は不変であることを検証する。
    func testSkyCorrectionOnlyAffectsMaskedRegion() {
        // Given: 中間的な彩度のある単色ソース（露出/かすみの除去/コントラスト/彩度いずれの変化も検出できる色）
        let sourceColor = CIColor(red: 0.45, green: 0.5, blue: 0.65, alpha: 1)
        let source = makeSolidImage(color: sourceColor, size: imageSize)
        let mask = makeTopHalfWhiteMask(size: imageSize)

        var recipe = EditRecipe()
        recipe.skyCorrectionIntensity = 1.0

        let output = FilterGraphBuilder.buildGraph(recipe: recipe, source: source, skyMask: mask)

        let beforeTop = averageColor(of: source, in: topBand)
        let afterTop = averageColor(of: output, in: topBand)
        let beforeBottom = averageColor(of: source, in: bottomBand)
        let afterBottom = averageColor(of: output, in: bottomBand)

        // Then: 上半分（空）は変化する
        let topChanged = abs(afterTop.r - beforeTop.r) > 0.02
            || abs(afterTop.g - beforeTop.g) > 0.02
            || abs(afterTop.b - beforeTop.b) > 0.02
        XCTAssertTrue(topChanged, "空補正 intensity=1.0 で上半分（空）が変化していない")

        // Then: 下半分（非空）はほぼ不変（フェザーの滲みを考慮し小さな許容誤差を設ける）
        XCTAssertEqual(afterBottom.r, beforeBottom.r, accuracy: 0.02, "下半分（非空）の R が変化してしまっている")
        XCTAssertEqual(afterBottom.g, beforeBottom.g, accuracy: 0.02, "下半分（非空）の G が変化してしまっている")
        XCTAssertEqual(afterBottom.b, beforeBottom.b, accuracy: 0.02, "下半分（非空）の B が変化してしまっている")
    }

    /// intensity=0（未適用相当）のとき、skyMask を渡しても完全に no-op であることを検証する。
    func testSkyCorrectionIsNoOpWhenIntensityIsZero() {
        let sourceColor = CIColor(red: 0.45, green: 0.5, blue: 0.65, alpha: 1)
        let source = makeSolidImage(color: sourceColor, size: imageSize)
        let mask = makeTopHalfWhiteMask(size: imageSize)

        var recipe = EditRecipe()
        recipe.skyCorrectionIntensity = 0

        let output = FilterGraphBuilder.buildGraph(recipe: recipe, source: source, skyMask: mask)

        let beforeTop = averageColor(of: source, in: topBand)
        let afterTop = averageColor(of: output, in: topBand)

        XCTAssertEqual(afterTop.r, beforeTop.r, accuracy: 0.001, "intensity=0 なのに出力が変化している(R)")
        XCTAssertEqual(afterTop.g, beforeTop.g, accuracy: 0.001, "intensity=0 なのに出力が変化している(G)")
        XCTAssertEqual(afterTop.b, beforeTop.b, accuracy: 0.001, "intensity=0 なのに出力が変化している(B)")
    }

    /// intensity=0（未設定 nil 相当）のとき、skyMask を渡しても完全に no-op であることを検証する。
    /// `skyCorrectionIntensity` は後方互換のため Optional なので、nil 経路も別途確認する。
    func testSkyCorrectionIsNoOpWhenIntensityIsNil() {
        let sourceColor = CIColor(red: 0.45, green: 0.5, blue: 0.65, alpha: 1)
        let source = makeSolidImage(color: sourceColor, size: imageSize)
        let mask = makeTopHalfWhiteMask(size: imageSize)

        var recipe = EditRecipe()
        recipe.skyCorrectionIntensity = nil

        let output = FilterGraphBuilder.buildGraph(recipe: recipe, source: source, skyMask: mask)

        let beforeTop = averageColor(of: source, in: topBand)
        let afterTop = averageColor(of: output, in: topBand)

        XCTAssertEqual(afterTop.r, beforeTop.r, accuracy: 0.001, "intensity=nil なのに出力が変化している(R)")
        XCTAssertEqual(afterTop.g, beforeTop.g, accuracy: 0.001, "intensity=nil なのに出力が変化している(G)")
        XCTAssertEqual(afterTop.b, beforeTop.b, accuracy: 0.001, "intensity=nil なのに出力が変化している(B)")
    }

    /// intensity=1.0 でも skyMask を渡さない（nil）場合は no-op であることを検証する
    /// （マスク未生成時に誤って補正が掛かってしまわないことの防御的テスト）。
    func testSkyCorrectionIsNoOpWhenMaskIsNil() {
        let sourceColor = CIColor(red: 0.45, green: 0.5, blue: 0.65, alpha: 1)
        let source = makeSolidImage(color: sourceColor, size: imageSize)

        var recipe = EditRecipe()
        recipe.skyCorrectionIntensity = 1.0

        let output = FilterGraphBuilder.buildGraph(recipe: recipe, source: source, skyMask: nil)

        let beforeTop = averageColor(of: source, in: topBand)
        let afterTop = averageColor(of: output, in: topBand)

        XCTAssertEqual(afterTop.r, beforeTop.r, accuracy: 0.001, "skyMask=nil なのに出力が変化している(R)")
        XCTAssertEqual(afterTop.g, beforeTop.g, accuracy: 0.001, "skyMask=nil なのに出力が変化している(G)")
        XCTAssertEqual(afterTop.b, beforeTop.b, accuracy: 0.001, "skyMask=nil なのに出力が変化している(B)")
    }
}
