//
//  SkyReplacementCompositorTests.swift
//  SoramoyouTests
//
//  ⭐️ SkyReplacementCompositor（空差し替え合成エンジン）のユニットテスト
//  上下2色に塗り分けた合成画像を入力し、空領域だけが新しい空の画像に差し替わるかを検証する。
//

import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
@testable import Soramoyou

final class SkyReplacementCompositorTests: XCTestCase {

    // MARK: - Helpers
    // SkyMaskProviderTests のヘルパーと同型のパターンをこのファイル内に private で持つ
    // （テストターゲットに共有ヘルパーが無いため、ファイル内での重複を許容する）。

    /// テスト内で使い回す CIContext（1個生成して再利用）
    private let context = CIContext()

    /// 上下2色に塗り分けた UIImage を生成する
    /// - Parameters:
    ///   - top: 上部の色
    ///   - bottom: 下部の色
    ///   - size: 画像サイズ
    ///   - topFraction: 上部が占める割合（0...1）
    /// - Returns: 塗り分け済み UIImage
    private func makeTwoBandImage(
        top: UIColor,
        bottom: UIColor,
        size: CGSize = CGSize(width: 256, height: 256),
        topFraction: CGFloat = 0.5
    ) -> UIImage {
        // UIGraphicsImageRenderer は既定で端末倍率（2x/3x）で描画するため、
        // scale=1 に固定しないと「指定サイズ」と「実ピクセルサイズ」がズレる
        // （例: 256×192 指定でも実機 3x なら 768×576 になる）。
        // テストの決定性（指定サイズ＝実ピクセルサイズ）を確保するため 1x に固定する。
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            let topHeight = size.height * topFraction
            top.setFill()
            rendererContext.fill(CGRect(x: 0, y: 0, width: size.width, height: topHeight))
            bottom.setFill()
            rendererContext.fill(CGRect(x: 0, y: topHeight, width: size.width, height: size.height - topHeight))
        }
    }

    /// 単色で塗りつぶした UIImage を生成する
    private func makeSolidImage(color: UIColor, size: CGSize = CGSize(width: 256, height: 256)) -> UIImage {
        // makeTwoBandImage と同様、端末倍率に依存させず「指定サイズ＝実ピクセル」にするため 1x に固定する。
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            color.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
    }

    /// 指定領域（CI 座標系）の平均色 0...1 を取得する
    /// - Note: CIImage の座標系は y=0 が下端（UIKit と上下逆）。
    ///   「画像の上端バンド」は `CGRect(x: 0, y: H*0.80, width: W, height: H*0.20)` のように指定する。
    private func averageColor(of image: UIImage, in rect: CGRect) -> (r: Double, g: Double, b: Double) {
        guard let cgImage = image.cgImage else {
            XCTFail("cgImage 取得に失敗")
            return (0, 0, 0)
        }
        let ciImage = CIImage(cgImage: cgImage)

        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage
        filter.extent = rect

        guard let outputImage = filter.outputImage,
              let outputCGImage = context.createCGImage(outputImage, from: CGRect(x: 0, y: 0, width: 1, height: 1)) else {
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
        pixelContext.draw(outputCGImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return (Double(pixelData[0]) / 255.0, Double(pixelData[1]) / 255.0, Double(pixelData[2]) / 255.0)
    }

    /// 出力 UIImage の pixel サイズ（size × scale）を返す
    private func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    // MARK: - 共通で使う色

    private let skyBlue = UIColor(red: 0.35, green: 0.55, blue: 0.90, alpha: 1)
    private let groundBrown = UIColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1)
    private let newSkyRed = UIColor(red: 0.90, green: 0.10, blue: 0.10, alpha: 1)

    // MARK: - Tests

    /// 上=青空・下=茶色の写真に赤い新しい空を差し替える → 上端バンドのみ赤に置き換わり、下端バンドは元のまま
    func test_replaceSky_replacesTopBandOnly() async throws {
        let photo = makeTwoBandImage(top: skyBlue, bottom: groundBrown)
        let newSky = makeSolidImage(color: newSkyRed)
        let compositor = SkyReplacementCompositor()
        // トーンマッチを切って決定性を確保する（明るさ補正が入ると期待色から僅かにずれるため）
        let options = SkyReplacementOptions(matchForegroundTone: false)

        let result = try await compositor.replaceSky(in: photo, with: newSky, options: options)

        let size = pixelSize(of: result.image)
        let topBand = CGRect(x: 0, y: size.height * 0.80, width: size.width, height: size.height * 0.20)
        let bottomBand = CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.20)

        let topAvg = averageColor(of: result.image, in: topBand)
        let bottomAvg = averageColor(of: result.image, in: bottomBand)

        XCTAssertGreaterThan(topAvg.r, 0.6, "上端バンドの赤成分が低すぎる（赤い空に置き換わっていない）: \(topAvg)")
        XCTAssertLessThan(topAvg.b, 0.35, "上端バンドの青成分が高すぎる（赤い空に置き換わっていない）: \(topAvg)")

        XCTAssertLessThan(bottomAvg.b, 0.35, "下端バンドの青成分が高すぎる（元の茶色から変化した）: \(bottomAvg)")
        XCTAssertTrue((0.30...0.60).contains(bottomAvg.r), "下端バンドの赤成分が想定範囲外（元の茶色から変化した）: \(bottomAvg)")
    }

    /// 全面 地面の茶色 → 空がほぼ写っていないため noSkyDetected が throw される
    func test_allGroundPhoto_throwsNoSkyDetected() async throws {
        let photo = makeSolidImage(color: groundBrown)
        let newSky = makeSolidImage(color: newSkyRed)
        let compositor = SkyReplacementCompositor()

        do {
            _ = try await compositor.replaceSky(in: photo, with: newSky)
            XCTFail("noSkyDetected が throw されなかった")
        } catch SkyReplacementError.noSkyDetected {
            // 期待どおり
        } catch {
            XCTFail("想定外のエラー種別: \(error)")
        }
    }

    /// 出力 UIImage の pixel サイズが入力と一致し、orientation は .up に正規化されている
    func test_outputSizeAndOrientation() async throws {
        let photo = makeTwoBandImage(top: skyBlue, bottom: groundBrown)
        let newSky = makeSolidImage(color: newSkyRed)
        let compositor = SkyReplacementCompositor()

        let result = try await compositor.replaceSky(in: photo, with: newSky)

        XCTAssertEqual(pixelSize(of: result.image), pixelSize(of: photo))
        XCTAssertEqual(result.image.imageOrientation, .up)
    }

    /// matchForegroundTone = true でもクラッシュせず正常な出力が得られる（スモークテスト）
    func test_toneMatchOn_producesValidOutput() async throws {
        let photo = makeTwoBandImage(top: skyBlue, bottom: groundBrown)
        let newSky = makeSolidImage(color: newSkyRed)
        let compositor = SkyReplacementCompositor()
        let options = SkyReplacementOptions(matchForegroundTone: true)

        let result = try await compositor.replaceSky(in: photo, with: newSky, options: options)

        XCTAssertNotNil(result.image.cgImage, "トーンマッチ有効時に出力画像が生成されなかった")
        XCTAssertEqual(pixelSize(of: result.image), pixelSize(of: photo))
    }

    /// 回転済み（.right）入力でも出力は .up に正規化され、pixel サイズは .right の視覚サイズと一致する
    /// - Note: basePhoto をあえて非正方形（256×192）にすることで、
    ///   「出力が 192×256（縦横入れ替え後）になっているか」を数値で検証できるようにしている。
    ///   正方形だと縦横が入れ替わっても pixelSize の比較値が変わらず、
    ///   向き正規化が効いていないバグを検出できない（テストが素通りしてしまう）ため。
    func test_rotatedInput_producesUprightOutput() async throws {
        let basePhoto = makeTwoBandImage(
            top: skyBlue,
            bottom: groundBrown,
            size: CGSize(width: 256, height: 192)
        )
        guard let baseCGImage = basePhoto.cgImage else {
            XCTFail("cgImage 取得に失敗")
            return
        }
        let rotatedPhoto = UIImage(cgImage: baseCGImage, scale: 1.0, orientation: .right)
        let newSky = makeSolidImage(color: newSkyRed)
        let compositor = SkyReplacementCompositor()

        let result = try await compositor.replaceSky(in: rotatedPhoto, with: newSky)

        XCTAssertEqual(result.image.imageOrientation, .up)
        // UIImage.size は imageOrientation に応じて縦横を入れ替えた「視覚上のサイズ」を返すため、
        // rotatedPhoto の pixelSize（= .right の視覚サイズ）と出力の pixelSize が一致するはず。
        // basePhoto は 256×192 なので、.right 回転後の視覚サイズは 192×256 になる。
        // ここが 256×192 のままなら向き正規化が効いていないことを検出できる。
        XCTAssertEqual(pixelSize(of: result.image), CGSize(width: 192, height: 256))
        XCTAssertEqual(pixelSize(of: result.image), pixelSize(of: rotatedPhoto))
    }

    /// 合成結果に SkyMask 由来の skyCoverage / confidence が正しい範囲で載っている
    func test_result_carriesMaskStats() async throws {
        let photo = makeTwoBandImage(top: skyBlue, bottom: groundBrown)
        let newSky = makeSolidImage(color: newSkyRed)
        let compositor = SkyReplacementCompositor()
        let options = SkyReplacementOptions(matchForegroundTone: false)

        let result = try await compositor.replaceSky(in: photo, with: newSky, options: options)

        XCTAssertTrue((0.05...1.0).contains(result.skyCoverage), "skyCoverage が想定範囲外: \(result.skyCoverage)")
        XCTAssertTrue((0.0...1.0).contains(result.confidence), "confidence が想定範囲外: \(result.confidence)")
    }
}
