//
//  SkyCameraZoomTests.swift ⭐️
//  SoramoyouTests
//
//  レンズ切替の倍率換算を、端末構成4通りぶん検証する。
//  内部値（videoZoomFactor）と表示倍率（0.5x / 1x / 3x）の取り違えは
//  ボタン・スライダー・実際の画角を全部ずらすので、ここを純関数で固めておく。
//

import XCTest
import CoreGraphics
@testable import SkyCamera

final class SkyCameraZoomTests: XCTestCase {

    /// 3眼（超広角＋標準＋望遠）。内部 1.0 が超広角、2.0 で標準、6.0 で望遠。
    private let triple = LensConfiguration(
        hasUltraWide: true, switchOverFactors: [2, 6], minFactor: 1, deviceMaxFactor: 100)

    /// 広角2眼（超広角＋標準）。望遠なし。
    private let dualWide = LensConfiguration(
        hasUltraWide: true, switchOverFactors: [2], minFactor: 1, deviceMaxFactor: 100)

    /// 2眼（標準＋望遠）。超広角なし＝いちばん広いレンズがそのまま 1x。
    private let dualTele = LensConfiguration(
        hasUltraWide: false, switchOverFactors: [2], minFactor: 1, deviceMaxFactor: 100)

    /// 単眼（標準のみ）。iPhone SE など。
    private let single = LensConfiguration(
        hasUltraWide: false, switchOverFactors: [], minFactor: 1, deviceMaxFactor: 100)

    // MARK: - 1x の基準

    func testBaseFactorIsFirstSwitchOverWhenUltraWideExists() {
        // 3眼では内部 2.0 が「標準レンズの始まり」＝表示 1x。
        XCTAssertEqual(triple.baseFactor, 2, accuracy: 0.0001)
    }

    func testBaseFactorIsOneWhenNoUltraWide() {
        // 超広角が無ければ、いちばん広いレンズがそのまま 1x。
        XCTAssertEqual(dualTele.baseFactor, 1, accuracy: 0.0001)
        XCTAssertEqual(single.baseFactor, 1, accuracy: 0.0001)
    }

    // MARK: - 換算

    func testUltraWideShowsAsHalf() {
        // ⭐️ 本命。3眼の内部 1.0（超広角）は 0.5x と表示されなければならない。
        XCTAssertEqual(triple.displayedZoom(forVideoZoomFactor: 1), 0.5, accuracy: 0.0001)
    }

    func testStandardLensShowsAsOne() {
        XCTAssertEqual(triple.displayedZoom(forVideoZoomFactor: 2), 1, accuracy: 0.0001)
    }

    func testTelephotoShowsAsThree() {
        XCTAssertEqual(triple.displayedZoom(forVideoZoomFactor: 6), 3, accuracy: 0.0001)
    }

    func testConversionRoundTrips() {
        for displayed in [0.5, 1.0, 1.7, 3.0, 5.0] as [CGFloat] {
            let factor = triple.videoZoomFactor(forDisplayedZoom: displayed)
            XCTAssertEqual(triple.displayedZoom(forVideoZoomFactor: factor), displayed,
                           accuracy: 0.0001, "表示 \(displayed)x で往復しない")
        }
    }

    // MARK: - プリセット

    func testTriplePresets() {
        // 光学の切替点（0.5 / 1 / 3）に倍々の停留点（2 / 4）が混ざり、昇順で並ぶ。
        XCTAssertEqual(triple.presetDisplayedZooms.map { round($0 * 10) / 10 },
                       [0.5, 1, 2, 3, 4])
    }

    func testDualWidePresetsHaveNoTelephoto() {
        // 望遠が無いので光学の切替点は 1 まで。以降は倍々の停留点で埋まる。
        XCTAssertEqual(dualWide.presetDisplayedZooms.map { round($0 * 10) / 10 },
                       [0.5, 1, 2, 4, 8])
    }

    func testDualTelePresetsHaveNoUltraWide() {
        // ⭐️ 超広角の無い端末に 0.5x ボタンを出してはいけない（押しても何も起きない）。
        let presets = dualTele.presetDisplayedZooms
        XCTAssertFalse(presets.contains { $0 < 0.9999 }, "超広角の無い端末に 1x 未満を出している")
        XCTAssertEqual(presets.map { round($0 * 10) / 10 }, [1, 2, 4, 8])
    }

    func testSingleLensHasOnlyOnePreset() {
        // ⭐️ 単眼端末に倍々のボタンを並べない。全部デジタルズーム＝画質が落ちるだけで、
        //    iPhone 標準カメラも単眼機では 1x しか出さない。
        XCTAssertEqual(single.presetDisplayedZooms.count, 1)
        XCTAssertEqual(single.presetDisplayedZooms[0], 1, accuracy: 0.0001)
    }

    func testPresetCountIsCapped() {
        // 押し間違えるので 5 個より増やさない。
        XCTAssertLessThanOrEqual(triple.presetDisplayedZooms.count, 5)
        XCTAssertLessThanOrEqual(dualWide.presetDisplayedZooms.count, 5)
    }

    func testPresetsNeverExceedDeviceMaximum() {
        // 端末が 3x までしか許さない場合、6x のプリセットを出さない。
        let capped = LensConfiguration(
            hasUltraWide: true, switchOverFactors: [2, 6], minFactor: 1, deviceMaxFactor: 4)
        XCTAssertFalse(capped.presetDisplayedZooms.contains { $0 > 2.0001 },
                       "端末が届かない倍率のボタンを出している")
    }

    // MARK: - 範囲の制限

    func testDigitalZoomIsCappedAtTenTimes() {
        // 端末は 100 倍まで許すが、スライダーの大半がデジタルズームになると操作しづらい。
        XCTAssertEqual(triple.displayedZoom(forVideoZoomFactor: triple.maxFactor), 10,
                       accuracy: 0.0001)
    }

    func testFactorIsClampedIntoDeviceRange() {
        XCTAssertEqual(triple.videoZoomFactor(forDisplayedZoom: 0.01), triple.minFactor,
                       accuracy: 0.0001, "下限を下回る値を返している")
        XCTAssertEqual(triple.videoZoomFactor(forDisplayedZoom: 999), triple.maxFactor,
                       accuracy: 0.0001, "上限を超える値を返している")
    }

    func testDegenerateDeviceValuesDoNotDivideByZero() {
        // 端末が 0 を返す事故でも NaN / inf を作らない。
        let broken = LensConfiguration(
            hasUltraWide: true, switchOverFactors: [0], minFactor: 0, deviceMaxFactor: 0)
        let displayed = broken.displayedZoom(forVideoZoomFactor: 1)
        XCTAssertTrue(displayed.isFinite, "表示倍率が有限でない（0 除算）")
        XCTAssertTrue(broken.videoZoomFactor(forDisplayedZoom: 1).isFinite)
    }

    // MARK: - 表示

    func testLabels() {
        XCTAssertEqual(LensConfiguration.label(forDisplayedZoom: 0.5), "0.5x")
        XCTAssertEqual(LensConfiguration.label(forDisplayedZoom: 1), "1x")
        XCTAssertEqual(LensConfiguration.label(forDisplayedZoom: 3), "3x")
        XCTAssertEqual(LensConfiguration.label(forDisplayedZoom: 1.5), "1.5x")
        // 端数は丸めて整数に寄せる（2.02x のような表示を出さない）。
        XCTAssertEqual(LensConfiguration.label(forDisplayedZoom: 2.02), "2x")
    }

    // MARK: - 巡回

    func testNextPresetCyclesForward() {
        XCTAssertEqual(triple.nextPreset(after: 0.5), 1, accuracy: 0.0001)
        XCTAssertEqual(triple.nextPreset(after: 1), 2, accuracy: 0.0001)
        // いちばん望遠まで行ったら先頭（超広角）へ戻る。
        XCTAssertEqual(triple.nextPreset(after: 4), 0.5, accuracy: 0.0001)
    }

    func testNextPresetFromMidZoomGoesToNextStop() {
        // スライダーで 1.7x にしてからボタンを押したら、次の停留点（2x）へ。
        XCTAssertEqual(triple.nextPreset(after: 1.7), 2, accuracy: 0.0001)
    }
}
