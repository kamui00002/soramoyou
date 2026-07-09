//
//  SkyMaskProviderTests.swift
//  SoramoyouTests
//
//  ⭐️ SkyMaskProvider v1（HeuristicSkyMaskProvider）のユニットテスト
//  上下2色に塗り分けた合成画像を入力し、マスクが空領域だけを正しく検出するかを検証する。
//

import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
@testable import Soramoyou

final class SkyMaskProviderTests: XCTestCase {

    /// テスト内で使い回す CIContext（1個生成して再利用）
    private let context = CIContext()

    // MARK: - Helpers

    /// 上下2色に塗り分けた CIImage を生成する
    /// - Parameters:
    ///   - top: 上部の色
    ///   - bottom: 下部の色
    ///   - size: 画像サイズ
    ///   - topFraction: 上部が占める割合（0...1）
    /// - Returns: 塗り分け済み CIImage
    private func makeTwoBandImage(
        top: UIColor,
        bottom: UIColor,
        size: CGSize = CGSize(width: 256, height: 256),
        topFraction: CGFloat = 0.5
    ) -> CIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { rendererContext in
            let topHeight = size.height * topFraction
            top.setFill()
            rendererContext.fill(CGRect(x: 0, y: 0, width: size.width, height: topHeight))
            bottom.setFill()
            rendererContext.fill(CGRect(x: 0, y: topHeight, width: size.width, height: size.height - topHeight))
        }
        return CIImage(image: uiImage)!
    }

    /// 指定領域のマスク平均値（0...1）を取得する
    /// - Note: CIImage の座標系は y=0 が下端（UIKit と上下逆）。
    ///   「画像の上端バンド」は `CGRect(x: 0, y: H*0.75, width: W, height: H*0.25)` のように指定する。
    private func averageMaskValue(_ mask: CIImage, in rect: CGRect) -> Double {
        let filter = CIFilter.areaAverage()
        filter.inputImage = mask
        filter.extent = rect

        guard let outputImage = filter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: CGRect(x: 0, y: 0, width: 1, height: 1)) else {
            XCTFail("areaAverage の CGImage 化に失敗")
            return 0
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
            return 0
        }
        pixelContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return Double(pixelData[0]) / 255.0
    }

    // MARK: - Tests

    /// 上=青空・下=地面の茶色 → 上端バンドのみが空として検出される
    func test_blueTopGroundBottom_masksSkyOnly() async throws {
        let topColor = UIColor(red: 0.35, green: 0.55, blue: 0.90, alpha: 1)
        let bottomColor = UIColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1)
        let input = makeTwoBandImage(top: topColor, bottom: bottomColor)
        let extent = input.extent
        let provider = HeuristicSkyMaskProvider()

        let result = try await provider.makeSkyMask(for: input, quality: .export)

        let topBand = CGRect(x: 0, y: extent.height * 0.75, width: extent.width, height: extent.height * 0.25)
        let bottomBand = CGRect(x: 0, y: 0, width: extent.width, height: extent.height * 0.25)

        let topAvg = averageMaskValue(result.mask, in: topBand)
        let bottomAvg = averageMaskValue(result.mask, in: bottomBand)

        XCTAssertGreaterThan(topAvg, 0.6, "青空バンドのマスク平均が低すぎる: \(topAvg)")
        XCTAssertLessThan(bottomAvg, 0.15, "地面バンドのマスク平均が高すぎる: \(bottomAvg)")
        XCTAssertTrue((0.25...0.75).contains(result.skyCoverage), "skyCoverage が想定範囲外: \(result.skyCoverage)")
    }

    /// 全面 地面の茶色 → skyCoverage が低い
    func test_allGround_lowCoverage() async throws {
        let groundColor = UIColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1)
        let input = makeTwoBandImage(top: groundColor, bottom: groundColor)
        let provider = HeuristicSkyMaskProvider()

        let result = try await provider.makeSkyMask(for: input, quality: .export)

        XCTAssertLessThan(result.skyCoverage, 0.15, "全面地面なのに skyCoverage が高すぎる: \(result.skyCoverage)")
    }

    /// 全面 青空色 → skyCoverage が高い（縦位置の事前確率が下部を削るため 1.0 にはならない。それで正常）
    func test_allSky_highCoverage() async throws {
        let skyColor = UIColor(red: 0.35, green: 0.55, blue: 0.90, alpha: 1)
        let input = makeTwoBandImage(top: skyColor, bottom: skyColor)
        let provider = HeuristicSkyMaskProvider()

        let result = try await provider.makeSkyMask(for: input, quality: .export)

        XCTAssertGreaterThan(result.skyCoverage, 0.45, "全面青空なのに skyCoverage が低すぎる: \(result.skyCoverage)")
    }

    /// 上=夕焼けオレンジ・下=夜の暗い色 → 上端バンドで朝夕の空が検出される
    func test_sunsetSky_detected() async throws {
        let sunsetColor = UIColor(red: 0.95, green: 0.55, blue: 0.30, alpha: 1)
        let nightColor = UIColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1)
        let input = makeTwoBandImage(top: sunsetColor, bottom: nightColor)
        let extent = input.extent
        let provider = HeuristicSkyMaskProvider()

        let result = try await provider.makeSkyMask(for: input, quality: .export)

        let topBand = CGRect(x: 0, y: extent.height * 0.75, width: extent.width, height: extent.height * 0.25)
        let topAvg = averageMaskValue(result.mask, in: topBand)

        XCTAssertGreaterThan(topAvg, 0.3, "夕焼け空バンドのマスク平均が低すぎる: \(topAvg)")
    }

    /// preview / export いずれの品質でも mask.extent が入力の extent と厳密に一致する
    func test_maskExtentMatchesInput() async throws {
        let topColor = UIColor(red: 0.35, green: 0.55, blue: 0.90, alpha: 1)
        let bottomColor = UIColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1)
        let input = makeTwoBandImage(top: topColor, bottom: bottomColor)
        let provider = HeuristicSkyMaskProvider()

        let previewResult = try await provider.makeSkyMask(for: input, quality: .preview)
        XCTAssertEqual(previewResult.mask.extent, input.extent, "preview: マスクの extent が入力と一致しない")

        let exportResult = try await provider.makeSkyMask(for: input, quality: .export)
        XCTAssertEqual(exportResult.mask.extent, input.extent, "export: マスクの extent が入力と一致しない")
    }

    /// 不正な入力（空の extent）で invalidInput が throw される
    func test_invalidInput_throws() async throws {
        let provider = HeuristicSkyMaskProvider()

        do {
            _ = try await provider.makeSkyMask(for: CIImage.empty(), quality: .preview)
            XCTFail("invalidInput が throw されなかった")
        } catch SkyMaskError.invalidInput {
            // 期待どおり
        } catch {
            XCTFail("想定外のエラー種別: \(error)")
        }
    }

    /// confidence は常に 0...1 の範囲に収まる
    func test_confidenceIsInUnitRange() async throws {
        let topColor = UIColor(red: 0.35, green: 0.55, blue: 0.90, alpha: 1)
        let bottomColor = UIColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1)
        let input = makeTwoBandImage(top: topColor, bottom: bottomColor)
        let provider = HeuristicSkyMaskProvider()

        let result = try await provider.makeSkyMask(for: input, quality: .export)

        XCTAssertGreaterThanOrEqual(result.confidence, 0.0)
        XCTAssertLessThanOrEqual(result.confidence, 1.0)
    }
}
