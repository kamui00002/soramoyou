//
//  LivingSkyEngineTests.swift
//  SoramoyouTests
//
//  ⭐️ LivingSkyEngine（Living Sky の1フレーム生成エンジン）のループ保証ユニットテスト。
//  設計書 docs/living-sky-design.md §2.1「継ぎ目なしの証明」:
//  全項が frac(t/T) の関数のため frame(0) ≡ frame(T) が数式レベルで保証される。
//  このテストはその保証がコード上でも崩れていないか（modulo 計算・kernel 引数の組み立て）を検証する。
//

import XCTest
import CoreImage
@testable import Soramoyou

final class LivingSkyEngineTests: XCTestCase {

    /// `makeFrame(elapsed: 0)` と `makeFrame(elapsed: T)` のレンダリング結果ピクセルが一致することを確認する。
    ///
    /// - `setPreparedStateForTesting` で `prepare()`（実写真の向き正規化・ヒューリスティックマスク生成）を
    ///   経由せず、決定的なテスト用 photo/mask（2色バンド写真 × 全面「空」扱いの白マスク）を直接注入する。
    /// - マスクを全面白にする理由: 風向き変位・光のゆらぎの効果が画面全体に及ぶようにし、
    ///   「たまたま静止部分だけ比較して一致した」という偽陽性を避けるため。
    /// - シミュレータの Metal 環境で CIKernel をロードできない場合は XCTSkip で逃がす。
    func test_loopBoundary_frame0EqualsFrameT() throws {
        let engine = LivingSkyEngine()
        guard engine.isAvailable else {
            throw XCTSkip("この実行環境では Living Sky の Metal カーネルをロードできない")
        }

        let size = 64
        let photo = CIImageTestHelpers.makeTwoBandCIImage(size: size)
        let mask = CIImage(color: CIColor.white).cropped(to: photo.extent)
        engine.setPreparedStateForTesting(photo: photo, mask: mask)

        // 変位・シマーの効果を十分に出すパラメータ（既定値のままだと差が小さく偽陽性になりうるため）
        engine.parameters = LivingSkyParameters(
            windAngleDegrees: 30,
            speed: 1.0,
            shimmerAmount: 0.08,
            loopDuration: 4.0
        )

        guard let frame0 = engine.makeFrame(elapsed: 0),
              let frameT = engine.makeFrame(elapsed: engine.parameters.loopDuration) else {
            XCTFail("makeFrame がフレームを生成できなかった（kernel.apply が nil を返した）")
            return
        }

        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        let pixels0 = try renderRGBA8Pixels(frame0, extent: extent)
        let pixelsT = try renderRGBA8Pixels(frameT, extent: extent)

        XCTAssertEqual(
            pixels0, pixelsT,
            "elapsed=0 と elapsed=T のフレームが一致しない（ループが継ぎ目なしであることの保証が壊れている）"
        )
    }

    // MARK: - Private Helpers

    /// CIImage を RGBA8 の生バイト列としてレンダリングする（厳密なピクセル一致比較用）。
    /// `CIImageTestHelpers.sampleRegionRGB` は 4x4 領域の平均値のため、今回のような
    /// 「全画素が完全一致するか」の検証には使えず、専用ヘルパーをこのファイル内に持つ。
    private func renderRGBA8Pixels(_ image: CIImage, extent: CGRect) throws -> [UInt8] {
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
