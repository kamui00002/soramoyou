//
//  SkyColorGateTests.swift
//  SoramoyouTests
//
//  ⭐️ 空色適応ゲート（SkyColorGate）の合成画像による回帰テスト。
//
//  背景（2026-07-20）: シミュレータ実写検証で「明るいグレーの壁が空マスクに誤包含され、
//  空補正で青く染まる」問題（IMG_8225系の見上げ構図）が見つかった。ここでは実写に頼らず、
//  同じ構図パターン（上部＝正しく空／下部中央＝壁のように地続きでない別ブロブが誤ってマスク白）
//  を合成画像で再現し、空色ゲート適用後に「壁領域の色変化が閾値以下」「空領域は補正が残る」
//  ことを検証する。SkyCorrectionVisualHarnessTests（実写9枚の目視ハーネス）と対になる単体テスト。
//

import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import Soramoyou

final class SkyColorGateTests: XCTestCase {

    // MARK: - Helpers

    private let context = CIContext()
    // ダウンサンプルグリッド（SkyColorGate.sampleGridLongSide=64）で「空」「壁」「その間の隙間」が
    // 十分な行数に分かれるよう、64x64単色テストより一回り大きいキャンバスを使う。
    private let imageSize = CGSize(width: 240, height: 320)

    /// 単色の CIImage を生成する（origin はゼロ基準）
    private func makeSolidImage(color: CIColor, size: CGSize) -> CIImage {
        CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// 指定領域（CI 座標系。y=0 が下端）の平均色 0...1 を取得する
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

    // MARK: - Tests

    /// 「上部＝青空（正しくマスク白）／下部中央＝明るいグレーの壁（地続きでないのに誤ってマスク白）」
    /// の合成画像を SkyColorGate に通し、壁領域の色変化が閾値以下・空領域は補正が残ることを検証する。
    ///
    /// 構図（IMG_8225 の再現。CI 座標系 y=0 が下端）:
    /// - 空: y = H*0.45...H（画像上部55%、全幅、マスク白＝正しい）
    /// - 地面: y = 0...H*0.45（画像下部45%、マスク黒＝正しい）
    /// - 壁: x = W*0.30...W*0.70, y = H*0.18...H*0.38（地面の中の一部だけ、マスクが誤って白）
    ///   → 空の下端(y=H*0.45)との間に隙間（屋根の縁に相当、正しくマスク黒）があるため、
    ///     `detectContiguousConfidentRowCutoff` が空だけで打ち切り、壁はパレット抽出対象外になる。
    func test_gate_suppressesMisclassifiedWallWhileKeepingSkyCorrection() {
        let width = imageSize.width
        let height = imageSize.height

        let skyColor = CIColor(red: 0.35, green: 0.55, blue: 0.90, alpha: 1)   // 青空
        let wallColor = CIColor(red: 0.72, green: 0.72, blue: 0.74, alpha: 1)  // 明るいグレーの壁
        let groundColor = CIColor(red: 0.15, green: 0.13, blue: 0.10, alpha: 1) // 非空の地面

        let skyRect = CGRect(x: 0, y: height * 0.45, width: width, height: height * 0.55)
        let groundRect = CGRect(x: 0, y: 0, width: width, height: height * 0.45)
        let wallRect = CGRect(x: width * 0.30, y: height * 0.18, width: width * 0.40, height: height * 0.20)

        // Given: 合成写真（空＋地面＋壁）
        let photo = makeSolidImage(color: wallColor, size: wallRect.size)
            .transformed(by: CGAffineTransform(translationX: wallRect.origin.x, y: wallRect.origin.y))
            .composited(over:
                makeSolidImage(color: skyColor, size: skyRect.size)
                    .transformed(by: CGAffineTransform(translationX: skyRect.origin.x, y: skyRect.origin.y))
                    .composited(over: makeSolidImage(color: groundColor, size: groundRect.size))
            )
            .cropped(to: CGRect(origin: .zero, size: imageSize))

        // Given: マスク（ヒューリスティックの誤判定を再現）。空は正しく白・地面は正しく黒・
        // 壁だけ誤って白（=「壁が空マスクに誤包含」バグの再現）
        let mask = makeSolidImage(color: .white, size: wallRect.size)
            .transformed(by: CGAffineTransform(translationX: wallRect.origin.x, y: wallRect.origin.y))
            .composited(over:
                makeSolidImage(color: .white, size: skyRect.size)
                    .transformed(by: CGAffineTransform(translationX: skyRect.origin.x, y: skyRect.origin.y))
                    .composited(over: makeSolidImage(color: .black, size: imageSize))
            )
            .cropped(to: CGRect(origin: .zero, size: imageSize))

        // When: 空色ゲートを構築して適用する
        guard let gateData = SkyColorGate.buildGateData(image: photo, mask: mask, ciContext: context) else {
            XCTFail("gateData の構築に失敗（パレット抽出できず）")
            return
        }
        let refinedMask = SkyColorGate.applyGate(to: mask, sampling: photo, gateData: gateData)

        // When: 実際の空補正グラフ（FilterGraphBuilder）に refinedMask を通す
        var recipe = EditRecipe()
        recipe.skyCorrectionIntensity = 1.0
        let output = FilterGraphBuilder.buildGraph(recipe: recipe, source: photo, skyMask: refinedMask)

        // Then: 壁領域（中心付近、フェザー滲みを避けるためマージンを取る）はほぼ不変
        let wallSampleRect = CGRect(x: wallRect.midX - 10, y: wallRect.midY - 10, width: 20, height: 20)
        let wallBefore = averageColor(of: photo, in: wallSampleRect)
        let wallAfter = averageColor(of: output, in: wallSampleRect)

        XCTAssertEqual(wallAfter.r, wallBefore.r, accuracy: 0.03, "誤検出された壁のRが変化してしまっている（青染み軽減が効いていない）")
        XCTAssertEqual(wallAfter.g, wallBefore.g, accuracy: 0.03, "誤検出された壁のGが変化してしまっている（青染み軽減が効いていない）")
        XCTAssertEqual(wallAfter.b, wallBefore.b, accuracy: 0.03, "誤検出された壁のBが変化してしまっている（青染み軽減が効いていない）")

        // Then: 空領域（中心付近）には補正の効果が残っている（ゲートで補正が死んでいない）
        let skySampleRect = CGRect(x: width * 0.35, y: height * 0.68, width: width * 0.30, height: height * 0.15)
        let skyBefore = averageColor(of: photo, in: skySampleRect)
        let skyAfter = averageColor(of: output, in: skySampleRect)

        let skyChanged = abs(skyAfter.r - skyBefore.r) > 0.02
            || abs(skyAfter.g - skyBefore.g) > 0.02
            || abs(skyAfter.b - skyBefore.b) > 0.02
        XCTAssertTrue(skyChanged, "空領域に空補正の効果が残っていない（ゲートが補正そのものを殺している）")
    }
}
