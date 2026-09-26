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

// MARK: - 物理レンズ単体を掴んだときの倍率換算

extension SkyCameraZoomTests {

    /// ⭐️ **最重要**: 素の画角ちょうどを指定したら、そのレンズの等倍（1.0）になること。
    /// ⚠️ ここが逆になっていると「ボタンは 1x なのに画角は 0.5x」というズレ方をする。
    ///    実機では気づきにくく、写真を見比べて初めて分かる類のバグ。
    func testPhysicalLensNativeZoomMapsToUnity() {
        // 超広角（素の画角 0.5x）: 表示 0.5x → そのレンズの等倍
        let ultra = LensConfiguration(nativeDisplayedZoom: 0.5, minFactor: 1, deviceMaxFactor: 100)
        XCTAssertEqual(ultra.baseFactor, 2, accuracy: 0.0001)
        XCTAssertEqual(ultra.videoZoomFactor(forDisplayedZoom: 0.5), 1, accuracy: 0.0001)

        // 標準（素の画角 1x）
        let wide = LensConfiguration(nativeDisplayedZoom: 1, minFactor: 1, deviceMaxFactor: 100)
        XCTAssertEqual(wide.videoZoomFactor(forDisplayedZoom: 1), 1, accuracy: 0.0001)

        // 望遠（素の画角 3x）: baseFactor は 1/3
        let tele = LensConfiguration(nativeDisplayedZoom: 3, minFactor: 1, deviceMaxFactor: 100)
        XCTAssertEqual(tele.baseFactor, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(tele.videoZoomFactor(forDisplayedZoom: 3), 1, accuracy: 0.0001)
    }

    /// 素の画角から離れた倍率でも、比が保たれること（＝デジタルズームの量が正しい）。
    func testPhysicalLensDigitalZoomScales() {
        let ultra = LensConfiguration(nativeDisplayedZoom: 0.5, minFactor: 1, deviceMaxFactor: 100)
        // 0.5x の 1.6 倍 = 0.8x
        XCTAssertEqual(ultra.videoZoomFactor(forDisplayedZoom: 0.8), 1.6, accuracy: 0.0001)

        let tele = LensConfiguration(nativeDisplayedZoom: 3, minFactor: 1, deviceMaxFactor: 100)
        // 3x の 4/3 倍 = 4x
        XCTAssertEqual(tele.videoZoomFactor(forDisplayedZoom: 4), 4.0 / 3.0, accuracy: 0.0001)
    }

    /// 物理レンズは素の画角より広くは写せない（下限が素の画角で止まる）。
    func testPhysicalLensCannotGoWiderThanItsNativeZoom() {
        let tele = LensConfiguration(nativeDisplayedZoom: 3, minFactor: 1, deviceMaxFactor: 100)
        // 望遠に 2x を頼んでも、いちばん広い 3x で止まる。
        let factor = tele.videoZoomFactor(forDisplayedZoom: 2)
        XCTAssertEqual(tele.displayedZoom(forVideoZoomFactor: factor), 3, accuracy: 0.0001)
    }

    /// 素の画角は仮想デバイスの切替点から導く（定数で持たない）。
    func testNativeDisplayedZoomIsDerivedFromVirtualConfiguration() {
        XCTAssertEqual(triple.nativeDisplayedZoom(for: .ultraWide) ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(triple.nativeDisplayedZoom(for: .wide) ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(triple.nativeDisplayedZoom(for: .telephoto) ?? -1, 3, accuracy: 0.0001)

        // 望遠を持たない端末では望遠が nil。
        XCTAssertNil(dualWide.nativeDisplayedZoom(for: .telephoto))
        // 超広角を持たない端末では超広角が nil。
        XCTAssertNil(dualTele.nativeDisplayedZoom(for: .ultraWide))
        XCTAssertEqual(dualTele.nativeDisplayedZoom(for: .telephoto) ?? -1, 2, accuracy: 0.0001)
        // 単眼は標準だけ。
        XCTAssertNil(single.nativeDisplayedZoom(for: .ultraWide))
        XCTAssertNil(single.nativeDisplayedZoom(for: .telephoto))
    }
}

// MARK: - どのレンズを掴むか（48MP とレンズの両立）

extension SkyCameraZoomTests {

    /// 3眼端末の素の画角で判断させるための補助。
    private func required(_ zoom: CGFloat,
                          needs48MP: Bool = true,
                          current: SkyCameraLensRequirement = .virtual,
                          ultra: CGFloat? = 0.5,
                          tele: CGFloat? = 3) -> SkyCameraLensRequirement {
        SkyCameraLensSwitching.requiredDevice(
            displayedZoom: zoom,
            preferredRequiresPhysicalLens: needs48MP,
            ultraWideNativeZoom: ultra,
            teleNativeZoom: tele,
            current: current)
    }

    /// 48MP を求めていなければ、倍率によらず切替がなめらかな仮想デバイス。
    func testVirtualDeviceWhenResolutionDoesNotNeedPhysicalLens() {
        for zoom in [CGFloat(0.5), 1, 2, 3, 10] {
            XCTAssertEqual(required(zoom, needs48MP: false), .virtual,
                           "12MP では \(zoom)x でも仮想デバイスのままであるべき")
        }
    }

    /// 倍率ごとに担当レンズが変わる。
    func testEachZoomRangePicksItsLens() {
        XCTAssertEqual(required(0.5), .physical(.ultraWide))
        XCTAssertEqual(required(0.7), .physical(.ultraWide))
        XCTAssertEqual(required(1), .physical(.wide))       // ちょうど 1x は標準
        XCTAssertEqual(required(2.9), .physical(.wide))
        XCTAssertEqual(required(3), .physical(.telephoto))  // ちょうど切替点は望遠
        XCTAssertEqual(required(6), .physical(.telephoto))
    }

    /// 1x のわずか下は誤差として吸収する（ボタンを押した直後の 0.9999 で付け替わらないため）。
    func testZoomJustUnderOneXIsAbsorbedAsOneX() {
        XCTAssertEqual(required(0.9995), .physical(.wide))
    }

    /// 超広角を持たない端末では超広角を選ばない。
    func testNeverPicksUltraWideWhenDeviceHasNone() {
        XCTAssertEqual(required(0.5, ultra: nil, tele: 2), .physical(.wide))
    }

    /// 望遠を持たない端末では望遠を選ばない。
    func testNeverPicksTelephotoWhenDeviceHasNone() {
        for zoom in [CGFloat(1), 3, 10] {
            XCTAssertEqual(required(zoom, tele: nil), .physical(.wide),
                           "望遠が無い端末では \(zoom)x でも標準のままであるべき")
        }
    }

    // MARK: - 不感帯（付け替えのばたつき防止）

    /// ⭐️ **符号の検出器**: 同じ倍率でも、いまいるレンズによって答えが変わること。
    /// ⚠️ 3 つのうち 2 つが同じ答えになったら、不感帯の符号がどこかで逆になっている。
    ///    0.97x は「1x のすぐ下」なので、標準にいるなら居座り、超広角にいるなら居座る。
    func testHysteresisDependsOnWhichLensWeAreOn() {
        // 超広角にいる → 境界が上へずれるので、まだ超広角の担当
        XCTAssertEqual(required(0.97, current: .physical(.ultraWide)), .physical(.ultraWide))
        // 標準にいる → 境界が下へずれるので、まだ標準の担当（＝付け替えない）
        XCTAssertEqual(required(0.97, current: .physical(.wide)), .physical(.wide))
        // 仮想デバイスからの初回判断は不感帯なし → 素直に超広角
        XCTAssertEqual(required(0.97, current: .virtual), .physical(.ultraWide))
    }

    /// 不感帯を超えて広げれば、ちゃんと超広角へ渡す。
    func testLeavesWideBeyondHysteresis() {
        XCTAssertEqual(required(0.9, current: .physical(.wide)), .physical(.ultraWide))
    }

    /// 望遠側の境界にも同じ向きの不感帯が付く。
    func testHysteresisOnTelephotoBoundary() {
        // 標準にいる → 切替点を少し越えても標準に居座る
        XCTAssertEqual(required(3.02, current: .physical(.wide)), .physical(.wide))
        // 離れれば望遠へ渡す
        XCTAssertEqual(required(3.2, current: .physical(.wide)), .physical(.telephoto))
        // 望遠にいる → 切替点を少し下回っても望遠に居座る
        XCTAssertEqual(required(2.98, current: .physical(.telephoto)), .physical(.telephoto))
        // 離れれば標準へ戻す
        XCTAssertEqual(required(2.8, current: .physical(.telephoto)), .physical(.wide))
    }

    /// 本当に単眼しか無い端末（iPhone SE など）では、従来どおりボタンを出さない。
    /// ⚠️ 48MP のためにボタンを出しっぱなしにする改修で、ここを壊しやすい。
    func testGenuinelySingleLensDeviceStillShowsNoPresets() {
        XCTAssertEqual(single.presetDisplayedZooms, [1])
    }
}
