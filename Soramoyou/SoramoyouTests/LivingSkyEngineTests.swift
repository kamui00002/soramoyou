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

    /// フロー変位が実際に画素を動かしていることを検出する「動くことのテスト」。
    ///
    /// 背景（段階3 vision レビュー指摘#1・#2）: 既存のループ保証テスト（frame(0) ≡ frame(T)）は
    /// 数式の周期性だけを検証しており、「フロー変位が常にゼロ」でも機械的に合格してしまうという
    /// 死角があった。当初は `float2 flowDirPx` の CIVector 引数マーシャリング不具合が疑われ
    /// 2スカラー化（flowDirPxX/Y）で対処したが、その後の設計者による再解析で**真因は別**と判明した:
    ///
    /// 1. 二相クロスフェードは加重平均位相 `phi1・(1-w) + phi2・w` が全時刻で 0.5 に恒等的に固定される
    ///    構造を持つため、ソフトエッジ領域ではほぼ時不変に見える。知覚できる動きは
    ///    「各位相コピーが `maxDisplacementPx` px/秒で滑る」分だけに限られる。
    /// 2. 旧係数（画像幅の1.5%上限）は 1080px・speed=0.5 で約1px/秒相当しかなく、
    ///    実装は正常でも知覚不能だった（＝「壊れている」のではなく「見えないほど小さい」）。
    ///    `LivingSkyParameters.maxDisplacementPx` を 0.08 係数に改定済み。
    /// 3. 当初のテスト（線形グラデーション画像・平均絶対差判定）にも盲点があった: 加重平均位相が
    ///    定数のため、**局所的に線形なコンテンツでは1/4ループ比較でも差がほぼゼロになる**
    ///    （2サンプルの平均＝平均位相でのサンプルに近似し、線形性のため位相差が打ち消し合う）。
    ///    このためテスト画像を「鋭い垂直エッジ」（左黒・右白）に変更し、判定を面平均（平均絶対差）
    ///    ではなく「閾値を超える画素の実数」に変更した（局所的な変化を面平均で薄めないため）。
    ///
    /// - `windAngleDegrees: 0` でフローをエッジと直交する水平方向にする。
    /// - `shimmerAmount: 0` でシマー項を無効化し、差分の原因をフロー項だけに切り分ける。
    /// - 期待値: 512px幅 × 0.08 × speed1.0 = 41px の最大変位。1/4ループでのゴースト帯
    ///   （二相のサンプル位置がエッジをまたいで分かれる境界帯）は少なくとも数百画素の幅を持つため、
    ///   「差>20/255 の画素数 ≥ 200」は十分な余裕を持って検出できる。
    func test_motion_frame0DiffersFromQuarterLoop() throws {
        let engine = LivingSkyEngine()
        guard engine.isAvailable else {
            throw XCTSkip("この実行環境では Living Sky の Metal カーネルをロードできない")
        }

        let size = 512
        let photo = makeVerticalEdgeCIImage(size: size)
        let mask = CIImage(color: CIColor.white).cropped(to: photo.extent)
        engine.setPreparedStateForTesting(photo: photo, mask: mask)

        engine.parameters = LivingSkyParameters(
            windAngleDegrees: 0,
            speed: 1.0,
            shimmerAmount: 0,
            loopDuration: 4.0
        )

        let quarterLoopElapsed = engine.parameters.loopDuration / 4
        guard let frame0 = engine.makeFrame(elapsed: 0),
              let frameQuarter = engine.makeFrame(elapsed: quarterLoopElapsed) else {
            XCTFail("makeFrame がフレームを生成できなかった（kernel.apply が nil を返した）")
            return
        }

        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        let pixels0 = try renderRGBA8Pixels(frame0, extent: extent)
        let pixelsQuarter = try renderRGBA8Pixels(frameQuarter, extent: extent)

        let movedPixelCount = countPixelsExceedingThreshold(pixels0, pixelsQuarter, threshold: 20)
        XCTAssertGreaterThanOrEqual(
            movedPixelCount, 200,
            "elapsed=0 と elapsed=T/4 で差>20/255 の画素数が少なすぎる（\(movedPixelCount)画素）。" +
            "フロー変位が効いていない疑いがある（段階3 vision レビュー指摘#1/#2の再発）"
        )
    }

    // MARK: - Private Helpers

    /// 鋭い垂直エッジを持つ CIImage を生成する（左半分=黒0、右半分=白255）。
    /// 局所的に線形なコンテンツ（グラデーション等）では二相クロスフェードの加重平均位相が
    /// 定数であるため差分が打ち消し合ってしまうため、鋭いエッジで局所的な変化を作る必要がある。
    private func makeVerticalEdgeCIImage(size: Int) -> CIImage {
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

    /// 2つの RGBA8 バイト列を比較し、RGB のいずれかのチャンネルの絶対差が `threshold` を超える
    /// 画素数を数える（alpha は常に 255 で不動のため除外）。面平均ではなく画素数基準にすることで、
    /// 局所的な変化（エッジ付近の帯）が全体平均で薄まって見えなくなることを避ける。
    private func countPixelsExceedingThreshold(_ a: [UInt8], _ b: [UInt8], threshold: Int) -> Int {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var count = 0
        var i = 0
        while i + 2 < a.count {
            let diffR = abs(Int(a[i]) - Int(b[i]))
            let diffG = abs(Int(a[i + 1]) - Int(b[i + 1]))
            let diffB = abs(Int(a[i + 2]) - Int(b[i + 2]))
            if max(diffR, diffG, diffB) > threshold {
                count += 1
            }
            i += 4
        }
        return count
    }

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
