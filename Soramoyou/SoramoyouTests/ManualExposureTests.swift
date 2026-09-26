//
//  ManualExposureTests.swift ⭐️
//  SoramoyouTests
//
//  長押しロック中の「明るさ調整（☀︎ドラッグ）」の純粋な計算だけを検証する。
//  デバイスにもジェスチャにも触らないので、机の上で挙動を確定できる。
//  SkyPriorityExposureTests と同じ理由で本体のテストターゲットに置いている
//  （SkyCamera パッケージにはテストターゲットが無い）。
//

import SkyCamera
import XCTest

final class ManualExposureTests: XCTestCase {
    /// iPhone の典型的な端末範囲（概ね ±8 EV）から求めた範囲 = ±2 EV。
    private var standardRange: ClosedRange<Float> {
        guard let range = ManualExposure.range(deviceMin: -8, deviceMax: 8) else {
            XCTFail("典型的な端末範囲で nil になった")
            return -2 ... 2
        }
        return range
    }

    // MARK: - 範囲

    /// 端末が ±8 EV まで受け付けても、±2 EV に絞る。
    func testRangeClampsWideDeviceRangeToTwoEV() {
        let range = ManualExposure.range(deviceMin: -8, deviceMax: 8)
        XCTAssertEqual(range?.lowerBound ?? .nan, -2, accuracy: 0.0001)
        XCTAssertEqual(range?.upperBound ?? .nan, 2, accuracy: 0.0001)
    }

    /// 端末の範囲が ±2 より狭いなら、端末の範囲をそのまま使う（書けない値を要求しない）。
    func testRangeKeepsNarrowerDeviceRange() {
        let range = ManualExposure.range(deviceMin: -1.5, deviceMax: 1.0)
        XCTAssertEqual(range?.lowerBound ?? .nan, -1.5, accuracy: 0.0001)
        XCTAssertEqual(range?.upperBound ?? .nan, 1.0, accuracy: 0.0001)
    }

    /// 片側だけ狭い端末でも、狭い側だけが端末の値になる。
    func testRangeMixesDeviceAndTwoEVLimitsPerSide() {
        let range = ManualExposure.range(deviceMin: -8, deviceMax: 1.3)
        XCTAssertEqual(range?.lowerBound ?? .nan, -2, accuracy: 0.0001)
        XCTAssertEqual(range?.upperBound ?? .nan, 1.3, accuracy: 0.0001)
    }

    /// 壊れた値（min > max）や 0 を含まない範囲は扱わない（`lower...upper` のトラップも防ぐ）。
    func testRangeRejectsBrokenDeviceValues() {
        XCTAssertNil(ManualExposure.range(deviceMin: 1, deviceMax: -1))
        XCTAssertNil(ManualExposure.range(deviceMin: 0.5, deviceMax: 3))
        XCTAssertNil(ManualExposure.range(deviceMin: -3, deviceMax: -0.5))
    }

    // MARK: - ドラッグ量 → 補正値

    /// 上へ動かす（translationY が負）と明るくなる。
    func testDragUpMakesBrighter() {
        let bias = ManualExposure.bias(startBias: 0, translationY: -70, range: standardRange)
        XCTAssertEqual(bias, 0.7, accuracy: 0.0001)
    }

    /// 下へ動かすと暗くなる。
    func testDragDownMakesDarker() {
        let bias = ManualExposure.bias(startBias: 0, translationY: 130, range: standardRange)
        XCTAssertEqual(bias, -1.3, accuracy: 0.0001)
    }

    /// 感度: 約 200pt で ±2 EV の端に届く。
    func testTwoHundredPointsReachesTwoEV() {
        XCTAssertEqual(ManualExposure.bias(startBias: 0, translationY: -200, range: standardRange),
                       2, accuracy: 0.0001)
        XCTAssertEqual(ManualExposure.bias(startBias: 0, translationY: 200, range: standardRange),
                       -2, accuracy: 0.0001)
    }

    /// 範囲の外へは出ない（上端・下端でクランプされる）。
    func testDragBeyondRangeIsClamped() {
        XCTAssertEqual(ManualExposure.bias(startBias: 0, translationY: -1000, range: standardRange),
                       2, accuracy: 0.0001)
        XCTAssertEqual(ManualExposure.bias(startBias: 0, translationY: 1000, range: standardRange),
                       -2, accuracy: 0.0001)
    }

    /// 端末の範囲が狭いときは、その端でクランプされる（±2 まで行かない）。
    func testDragIsClampedToNarrowDeviceRange() {
        guard let narrow = ManualExposure.range(deviceMin: -1.5, deviceMax: 1.0) else {
            return XCTFail("狭い範囲で nil になった")
        }
        XCTAssertEqual(ManualExposure.bias(startBias: 0, translationY: -500, range: narrow),
                       1.0, accuracy: 0.0001)
        XCTAssertEqual(ManualExposure.bias(startBias: 0, translationY: 500, range: narrow),
                       -1.5, accuracy: 0.0001)
    }

    /// 0.1 EV 刻みへ丸める（1pt 単位の端数を持たない）。
    func testDragIsRoundedToTenthEV() {
        // 0.33 EV 相当 → 0.3
        XCTAssertEqual(ManualExposure.bias(startBias: 0, translationY: -33, range: standardRange),
                       0.3, accuracy: 0.0001)
        // 0.37 EV 相当 → 0.4
        XCTAssertEqual(ManualExposure.bias(startBias: 0, translationY: -37, range: standardRange),
                       0.4, accuracy: 0.0001)
    }

    /// ⭐️ 開始値からの連続性: 空優先 AE がロック前に -1.0 を掛けていれば、-1.0 から動き始める
    ///    （0 から始めると触った瞬間に明るさが跳ぶ）。
    func testDragContinuesFromStartBias() {
        XCTAssertEqual(ManualExposure.bias(startBias: -1.0, translationY: 0, range: standardRange),
                       -1.0, accuracy: 0.0001)
        XCTAssertEqual(ManualExposure.bias(startBias: -1.0, translationY: -30, range: standardRange),
                       -0.7, accuracy: 0.0001)
        XCTAssertEqual(ManualExposure.bias(startBias: -1.0, translationY: 20, range: standardRange),
                       -1.2, accuracy: 0.0001)
    }

    /// 刻みに乗っていない開始値（空優先 AE の -0.75 など）でも、触れた瞬間には跳ばない。
    func testTinyDragKeepsOffStepStartBias() {
        XCTAssertEqual(ManualExposure.bias(startBias: -0.75, translationY: 2, range: standardRange),
                       -0.75, accuracy: 0.0001)
    }

    /// 範囲外の開始値（空優先 AE が -2 より下げていた等）でも、結果は範囲内に収まる。
    func testStartBiasOutsideRangeIsClamped() {
        XCTAssertEqual(ManualExposure.bias(startBias: -3, translationY: 0, range: standardRange),
                       -2, accuracy: 0.0001)
    }

    // MARK: - VoiceOver の 1 段

    /// 1/3 EV ずつ増減し、範囲の端で止まる。
    func testSteppedBiasMovesByOneThirdAndClamps() {
        XCTAssertEqual(ManualExposure.steppedBias(currentBias: 0, direction: 1, range: standardRange),
                       1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(ManualExposure.steppedBias(currentBias: 0, direction: -1, range: standardRange),
                       -1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(ManualExposure.steppedBias(currentBias: 2, direction: 1, range: standardRange),
                       2, accuracy: 0.0001)
    }

    // MARK: - 表示

    /// 表示文字列は「+0.7」「0.0」「-1.3」。素の状態は符号なしの "0.0"（"-0.0" にしない）。
    func testDisplayText() {
        XCTAssertEqual(ManualExposure.displayText(0.7), "+0.7")
        XCTAssertEqual(ManualExposure.displayText(-1.3), "-1.3")
        XCTAssertEqual(ManualExposure.displayText(0), "0.0")
        XCTAssertEqual(ManualExposure.displayText(-0.0001), "0.0")
        XCTAssertEqual(ManualExposure.displayText(2), "+2.0")
    }

    /// VoiceOver の読み上げは記号でなく言葉にする。
    func testAccessibilityValue() {
        XCTAssertEqual(ManualExposure.accessibilityValue(0.7), "プラス0.7")
        XCTAssertEqual(ManualExposure.accessibilityValue(-1.3), "マイナス1.3")
        XCTAssertEqual(ManualExposure.accessibilityValue(0), "0")
    }

    /// 太陽マークは上が明るい側（オフセットは負）。±2 EV でトラックの端。
    func testIndicatorOffsetDirection() {
        XCTAssertEqual(ManualExposure.indicatorOffset(bias: 2, trackHalfLength: 50), -50, accuracy: 0.0001)
        XCTAssertEqual(ManualExposure.indicatorOffset(bias: -1, trackHalfLength: 50), 25, accuracy: 0.0001)
        XCTAssertEqual(ManualExposure.indicatorOffset(bias: 0, trackHalfLength: 50), 0, accuracy: 0.0001)
    }

    // MARK: - 解除時のリセット

    /// ⭐️ そのロック中に手動で動かしたときだけ、解除時に 0 へ戻す。
    ///    動かしていないのに戻すと、既存の空優先 AE の挙動を変えてしまう。
    func testShouldResetOnUnlockOnlyWhenManuallyAdjusted() {
        XCTAssertTrue(ManualExposure.shouldResetOnUnlock(hasManualAdjustment: true))
        XCTAssertFalse(ManualExposure.shouldResetOnUnlock(hasManualAdjustment: false))
    }
}
