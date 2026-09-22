//
//  SkyPriorityExposureTests.swift ⭐️
//  SoramoyouTests
//
//  空優先 AE（白飛び防止）の「純粋な判定」だけを検証する。
//  デバイスにもフレームバッファにも触らないので、机の上で挙動を確定できる。
//  SkyCameraHorizonMathTests と同じ理由で本体のテストターゲットに置いている。
//

import XCTest
import SkyCamera

final class SkyPriorityExposureTests: XCTestCase {

    /// 端末が返す典型的な補正範囲（iPhone は概ね ±8 EV）。
    private let limits: ClosedRange<Float> = -8.0...8.0
    private let tuning = SkyPriorityExposure.Tuning.default

    // MARK: - 測光

    func testClippedFractionCountsPixelsAtOrAboveThreshold() {
        // 10 個中 3 個が閾値以上 → 0.3
        let luma: [UInt8] = [0, 100, 200, 249, 250, 251, 255, 10, 20, 30]
        let fraction = SkyPriorityExposure.clippedFraction(luma: luma, threshold: 250)
        XCTAssertEqual(fraction, 0.3, accuracy: 0.0001)
    }

    func testClippedFractionOfEmptySamplesIsZero() {
        // サンプルが取れなかったときに 0 除算で NaN を返さないこと。
        XCTAssertEqual(SkyPriorityExposure.clippedFraction(luma: [], threshold: 250), 0)
    }

    // MARK: - 判定（下げる側）

    func testHeavyClippingLowersBias() {
        // 20% 飛んでいる（許容 2%）→ 必ず下がる
        let next = SkyPriorityExposure.decideBias(
            clippedFraction: 0.20, currentBias: 0, tuning: tuning, deviceLimits: limits)
        XCTAssertLessThan(next, 0, "白飛びしているのに露出が下がっていない")
    }

    func testLargerExcessLowersMore() {
        // 比例制御：超過が大きいほど 1 回の下げ幅も大きい
        let small = SkyPriorityExposure.decideBias(
            clippedFraction: 0.04, currentBias: 0, tuning: tuning, deviceLimits: limits)
        let large = SkyPriorityExposure.decideBias(
            clippedFraction: 0.12, currentBias: 0, tuning: tuning, deviceLimits: limits)
        XCTAssertLessThan(large, small, "超過が大きいのに下げ幅が増えていない")
    }

    func testAttackStepIsCapped() {
        // 全面白飛び（100%）でも 1 回で maxAttackStep を超えて下げない
        let next = SkyPriorityExposure.decideBias(
            clippedFraction: 1.0, currentBias: 0, tuning: tuning, deviceLimits: limits)
        XCTAssertEqual(next, -tuning.maxAttackStep, accuracy: 0.0001)
    }

    func testBiasNeverGoesBelowMinBias() {
        // 下限に張り付いている状態でさらに飛んでいても、それ以上は暗くしない
        let next = SkyPriorityExposure.decideBias(
            clippedFraction: 1.0, currentBias: tuning.minBiasEV, tuning: tuning, deviceLimits: limits)
        XCTAssertEqual(next, tuning.minBiasEV, accuracy: 0.0001)
    }

    // MARK: - 判定（戻す側）

    func testNoClippingRecoversTowardZero() {
        // 飛びが収まったら 0 EV へ戻っていく
        let next = SkyPriorityExposure.decideBias(
            clippedFraction: 0, currentBias: -1.0, tuning: tuning, deviceLimits: limits)
        XCTAssertGreaterThan(next, -1.0, "白飛びが無いのに露出が戻っていない")
    }

    func testRecoveryIsSlowerThanAttack() {
        // 「下げるのは速く・戻すのは遅く」（AE の定石）が保たれているか
        let attackDrop = 0 - SkyPriorityExposure.decideBias(
            clippedFraction: 0.20, currentBias: 0, tuning: tuning, deviceLimits: limits)
        let recoveryRise = SkyPriorityExposure.decideBias(
            clippedFraction: 0, currentBias: -1.0, tuning: tuning, deviceLimits: limits) - (-1.0)
        XCTAssertGreaterThan(attackDrop, recoveryRise, "戻しの方が速い＝明るさが揺れる")
    }

    func testNeverBrightensBeyondNeutral() {
        // ⭐️ 安全弁：この機能は「守る」だけ。標準より明るくは絶対にしない。
        let next = SkyPriorityExposure.decideBias(
            clippedFraction: 0, currentBias: 0, tuning: tuning, deviceLimits: limits)
        XCTAssertLessThanOrEqual(next, 0, "0 EV より明るくしてしまっている")
    }

    // MARK: - 不感帯（ハンチング防止）

    func testInsideDeadbandDoesNotMove() {
        // 許容(2%)と戻し閾値(1%)のあいだ＝不感帯。触らないことでチカチカを防ぐ。
        let inBetween = tuning.allowedClippedFraction * 0.75  // 1.5%
        let next = SkyPriorityExposure.decideBias(
            clippedFraction: inBetween, currentBias: -0.5, tuning: tuning, deviceLimits: limits)
        XCTAssertEqual(next, -0.5, accuracy: 0.0001, "不感帯なのに露出が動いた")
    }

    func testCloudySkyIsNotCrushed() {
        // ⭐️ 曇り空・太陽そのものは「本当に白い」。許容内の白飛びで露出を下げてはいけない。
        //    ここが壊れると、曇りの日の写真がドブ色になる。
        let next = SkyPriorityExposure.decideBias(
            clippedFraction: tuning.allowedClippedFraction, currentBias: 0,
            tuning: tuning, deviceLimits: limits)
        XCTAssertEqual(next, 0, accuracy: 0.0001, "許容内なのに露出を下げている")
    }

    // MARK: - 端末の制約

    func testRespectsNarrowDeviceLimits() {
        // 端末が ±0.5 EV しか受け付けない場合、そこを超えて設定しない
        let narrow: ClosedRange<Float> = -0.5...0.5
        let next = SkyPriorityExposure.decideBias(
            clippedFraction: 1.0, currentBias: 0, tuning: tuning, deviceLimits: narrow)
        XCTAssertEqual(next, -0.5, accuracy: 0.0001)
    }

    func testDegenerateDeviceLimitsAreSafe() {
        // 補正を一切受け付けない端末（範囲が 0 だけ）でも落ちず、値も動かさない
        let none: ClosedRange<Float> = 0...0
        let next = SkyPriorityExposure.decideBias(
            clippedFraction: 1.0, currentBias: 0, tuning: tuning, deviceLimits: none)
        XCTAssertEqual(next, 0, accuracy: 0.0001)
    }

    // MARK: - 輝度レンジの換算

    func testFullRangeThresholdIsUnchanged() {
        // Full Range のバッファはそのまま比較してよい。
        XCTAssertEqual(
            SkyPriorityExposure.effectiveThreshold(fullRangeThreshold: 250, isFullRange: true), 250)
    }

    func testVideoRangeThresholdIsScaledIntoReachableRange() {
        // ⭐️ ここが本命。Video Range では Y は 235 までしか来ない。
        //    250 のまま比較すると「白飛びゼロ」と判定し続け、機能が**黙って死ぬ**。
        let threshold = SkyPriorityExposure.effectiveThreshold(
            fullRangeThreshold: 250, isFullRange: false)
        XCTAssertLessThan(threshold, 235, "Video Range で到達しえない閾値になっている")
        XCTAssertGreaterThan(threshold, 200, "下げすぎ。ふつうの明るさまで白飛び扱いしてしまう")
    }

    func testVideoRangeConversionDetectsRealClipping() {
        // Video Range の「真っ白」= 235。換算後の閾値ならちゃんと検出できること。
        let threshold = SkyPriorityExposure.effectiveThreshold(
            fullRangeThreshold: 250, isFullRange: false)
        let luma: [UInt8] = [16, 100, 180, 235, 235]  // 5 個中 2 個が真っ白
        let fraction = SkyPriorityExposure.clippedFraction(luma: luma, threshold: threshold)
        XCTAssertEqual(fraction, 0.4, accuracy: 0.0001)
    }

    // MARK: - EXIF からの実測値

    func testExposureBiasIsReadFromExifDictionary() {
        // 計装は「アプリが要求した値」ではなく「撮れた 1 枚に記録された値」を正とする。
        let metadata: [String: Any] = ["{Exif}": ["ExposureBiasValue": NSNumber(value: -0.75)]]
        let bias = SkyPriorityExposure.exposureBias(fromMetadata: metadata)
        XCTAssertEqual(try XCTUnwrap(bias), -0.75, accuracy: 0.0001)
    }

    func testExposureBiasIsNilWhenExifIsMissing() {
        // EXIF が無い端末では nil を返し、呼び出し側が現在値へフォールバックできること。
        XCTAssertNil(SkyPriorityExposure.exposureBias(fromMetadata: [:]))
        XCTAssertNil(SkyPriorityExposure.exposureBias(fromMetadata: ["{Exif}": [String: Any]()]))
    }

    // MARK: - 収束

    func testConvergesAndStopsUnderSustainedClipping() {
        // 同じ白飛び率が続いたとき、下がり続けて最後は止まる（発散しない）こと。
        var bias: Float = 0
        for _ in 0..<50 {
            bias = SkyPriorityExposure.decideBias(
                clippedFraction: 0.30, currentBias: bias, tuning: tuning, deviceLimits: limits)
        }
        XCTAssertEqual(bias, tuning.minBiasEV, accuracy: 0.0001, "下限で止まっていない")
    }


    // MARK: - 測光領域（空の側だけを測る）

    /// 0°（回転なし）: バッファの上辺がそのまま空。
    func testUpperRegionWithoutRotationIsTopRows() {
        let region = SkyPriorityExposure.upperRegion(rotationDegrees: 0, fraction: 0.5)
        XCTAssertEqual(region, SkyPriorityExposure.SampleRegion(x: 0...1, y: 0...0.5))
    }

    /// 90°（縦持ちの典型）: 時計回りに 90° 回すと**左辺**が上に来るので、左側が空。
    /// ⭐️ ここを取り違えると、縦持ちで地面を測って空を守れない（段階A の向きバグと同じ種類）。
    func testUpperRegionAt90DegreesIsLeftColumns() {
        let region = SkyPriorityExposure.upperRegion(rotationDegrees: 90, fraction: 0.5)
        XCTAssertEqual(region, SkyPriorityExposure.SampleRegion(x: 0...0.5, y: 0...1))
    }

    /// 180°: 下辺が上に来るので、下側が空。
    func testUpperRegionAt180DegreesIsBottomRows() {
        let region = SkyPriorityExposure.upperRegion(rotationDegrees: 180, fraction: 0.5)
        XCTAssertEqual(region, SkyPriorityExposure.SampleRegion(x: 0...1, y: 0.5...1))
    }

    /// 270°: **右辺**が上に来るので、右側が空。
    func testUpperRegionAt270DegreesIsRightColumns() {
        let region = SkyPriorityExposure.upperRegion(rotationDegrees: 270, fraction: 0.5)
        XCTAssertEqual(region, SkyPriorityExposure.SampleRegion(x: 0.5...1, y: 0...1))
    }

    /// 範囲外の角度は 0〜359 に正規化してから 90° 刻みへ丸める。
    func testUpperRegionNormalizesAngles() {
        XCTAssertEqual(SkyPriorityExposure.upperRegion(rotationDegrees: -90, fraction: 0.5),
                       SkyPriorityExposure.upperRegion(rotationDegrees: 270, fraction: 0.5))
        XCTAssertEqual(SkyPriorityExposure.upperRegion(rotationDegrees: 450, fraction: 0.5),
                       SkyPriorityExposure.upperRegion(rotationDegrees: 90, fraction: 0.5))
        XCTAssertEqual(SkyPriorityExposure.upperRegion(rotationDegrees: 88, fraction: 0.5),
                       SkyPriorityExposure.upperRegion(rotationDegrees: 90, fraction: 0.5),
                       "端数は最寄りの 90° 刻みへ丸める")
    }

    /// 割合は 0〜1 に丸める（設定ミスで範囲外になっても落ちない）。
    func testUpperRegionClampsFraction() {
        XCTAssertEqual(SkyPriorityExposure.upperRegion(rotationDegrees: 0, fraction: 1.5),
                       SkyPriorityExposure.SampleRegion.wholeFrame)
    }

    /// 割合から画素範囲へ直すとき、端を取りこぼさず、最低 1 画素は残す。
    func testPixelRangesCoverEdgesAndNeverEmpty() {
        let upper = SkyPriorityExposure.SampleRegion(x: 0...1, y: 0...0.5)
        let ranges = upper.pixelRanges(width: 101, height: 101)
        XCTAssertEqual(ranges.x, 0..<101)
        XCTAssertEqual(ranges.y, 0..<51, "上半分の境目の行は含める（外側へ丸める）")

        let empty = SkyPriorityExposure.SampleRegion(x: 0...1, y: 0...0)
        XCTAssertEqual(empty.pixelRanges(width: 10, height: 10).y.count, 1, "0 割でも 1 行は測る")
    }
}
