//
//  SkyCameraHorizonMathTests.swift ⭐️
//  SoramoyouTests
//
//  空カメラの水平線ガイド・グリッドの「純粋計算」だけを検証する。
//  ローカルパッケージ SkyCamera のテストだが、パッケージ単体の scheme はヘッドレスの
//  xcodebuild から扱いづらいため、本体のテストターゲットに置いて test_sim で回す。
//

import XCTest
import SkyCamera

final class SkyCameraHorizonMathTests: XCTestCase {

    /// 端末座標系の重力: 正立（ポートレート）は (0, -1, 0)。
    /// 正立ならズレ 0° で「水平」、向きはポートレート。
    func testUprightPortraitIsLevel() {
        let reading = HorizonMath.reading(gravityX: 0, gravityY: -1)

        XCTAssertEqual(reading.rollDegrees, 0, accuracy: 0.001)
        XCTAssertTrue(reading.isLevel, "正立は水平と判定されるべき")
        XCTAssertTrue(reading.isReliable, "正立なら傾きは信頼できる")
        XCTAssertEqual(reading.orientation, .portrait)
    }

    /// 5°傾けたら「水平ではない」。ズレの大きさは約5°。
    ///
    /// ⚠️ **符号まで固定する**。`rollDegrees` は `rotationEffect(.degrees(_:))` へそのまま渡す
    ///    契約（`HorizonMath.Reading` のドキュコメント）なので、符号が反転するとガイド線が
    ///    逆向きに回る。`abs()` で比較すると反転しても緑のまま通ってしまい、計測が効かない。
    func testFiveDegreeTiltClockwiseGivesNegativeRoll() {
        // 端末を時計回りに 5° 傾けると、端末座標系の重力は反時計回りに 5° 回る。
        let radians = 5.0 * .pi / 180.0
        let reading = HorizonMath.reading(gravityX: sin(radians), gravityY: -cos(radians))

        // 端末が時計回り → 画面上の水平線は反時計回りに見える →
        // SwiftUI の rotationEffect（正が時計回り）へ渡す値は負。
        XCTAssertEqual(reading.rollDegrees, -5, accuracy: 0.01)
        XCTAssertFalse(reading.isLevel, "5°は許容(±1°)の外なので水平ではない")
        XCTAssertTrue(reading.isReliable)
        XCTAssertEqual(reading.orientation, .portrait, "5°程度なら最寄りの基準はポートレートのまま")
    }

    // MARK: - ガイドの回転角（UI フレームとのズレ補正）

    /// UI が端末と一緒に回っているときは、従来どおり基準線 0°・追従線 = 残差。
    func testGuideAnglesWhenInterfaceFollowsDevice() {
        // 端末を横（landscapeLeft = 反時計回り 90°）に構え、さらに 5° 傾けた状態。
        let radians = 95.0 * .pi / 180.0
        let reading = HorizonMath.reading(gravityX: -sin(radians), gravityY: -cos(radians))
        XCTAssertEqual(reading.orientation, .landscapeLeft)

        // UI も一緒に回っている（interfaceDegrees = 90）。
        let angles = HorizonMath.guideAngles(reading: reading, interfaceDegrees: 90)

        XCTAssertEqual(angles.reference, 0, accuracy: 0.01, "UI が追従していれば基準線は画面の水平のまま")
        XCTAssertEqual(angles.moving, 5, accuracy: 0.01, "追従線は残差ぶんだけ傾く")
    }

    /// ⭐️ 回転ロックで UI が縦のまま固定されている横持ち。
    /// ここで基準線を 0° のままにすると、ガイドだけ世界の垂直方向を指してしまう（実機で発生）。
    func testGuideAnglesWhenInterfaceIsLockedToPortrait() {
        let radians = 95.0 * .pi / 180.0
        let reading = HorizonMath.reading(gravityX: -sin(radians), gravityY: -cos(radians))

        // UI は縦のまま（interfaceDegrees = 0）。
        let angles = HorizonMath.guideAngles(reading: reading, interfaceDegrees: 0)

        XCTAssertEqual(angles.reference, 90, accuracy: 0.01, "端末の姿勢ぶん（90°）だけガイドを回す必要がある")
        XCTAssertEqual(angles.moving, 95, accuracy: 0.01, "追従線は基準線からさらに残差ぶん")
    }

    /// 反対向きの横持ち（landscapeRight）は -90° 側へ畳まれる（遠回りの回転アニメを防ぐ）。
    func testGuideAnglesLockedPortraitOtherLandscapeFoldsToNegative() {
        let radians = 270.0 * .pi / 180.0
        let reading = HorizonMath.reading(gravityX: -sin(radians), gravityY: -cos(radians))
        XCTAssertEqual(reading.orientation, .landscapeRight)

        let angles = HorizonMath.guideAngles(reading: reading, interfaceDegrees: 0)

        XCTAssertEqual(angles.reference, -90, accuracy: 0.01, "270° ではなく -90° として扱う")
    }

    func testNormalizedAngleFolding() {
        XCTAssertEqual(HorizonMath.normalizedAngle(270), -90, accuracy: 0.001)
        XCTAssertEqual(HorizonMath.normalizedAngle(180), 180, accuracy: 0.001)
        XCTAssertEqual(HorizonMath.normalizedAngle(-270), 90, accuracy: 0.001)
        XCTAssertEqual(HorizonMath.normalizedAngle(0), 0, accuracy: 0.001)
    }

    /// 反対向きに傾けたら符号も反対になる（上のテストと対で符号反転を検出する）。
    func testFiveDegreeTiltCounterClockwiseGivesPositiveRoll() {
        let radians = 5.0 * .pi / 180.0
        let reading = HorizonMath.reading(gravityX: -sin(radians), gravityY: -cos(radians))

        XCTAssertEqual(reading.rollDegrees, 5, accuracy: 0.01)
        XCTAssertEqual(reading.orientation, .portrait)
    }

    /// 0.5° のズレは許容範囲（±1°）内なので「水平」。
    func testHalfDegreeTiltIsLevel() {
        let radians = 0.5 * .pi / 180.0
        let reading = HorizonMath.reading(gravityX: sin(radians), gravityY: -cos(radians))

        XCTAssertEqual(abs(reading.rollDegrees), 0.5, accuracy: 0.01)
        XCTAssertTrue(reading.isLevel, "0.5°は許容(±1°)の内側なので水平")
    }

    /// 横持ち（landscapeLeft = 重力が x の負方向）は 90° 基準からのズレで測る。
    func testLandscapeLeftIsLevelAgainstNinetyDegrees() {
        let reading = HorizonMath.reading(gravityX: -1, gravityY: 0)

        XCTAssertEqual(reading.rollDegrees, 0, accuracy: 0.001, "90°基準からのズレは0°")
        XCTAssertTrue(reading.isLevel)
        XCTAssertEqual(reading.orientation, .landscapeLeft)
    }

    /// 横持ち（landscapeRight = 重力が x の正方向）も同様に 270° 基準で測る。
    func testLandscapeRightIsLevelAgainstTwoSeventyDegrees() {
        let reading = HorizonMath.reading(gravityX: 1, gravityY: 0)

        XCTAssertEqual(reading.rollDegrees, 0, accuracy: 0.001)
        XCTAssertTrue(reading.isLevel)
        XCTAssertEqual(reading.orientation, .landscapeRight)
    }

    /// 上下逆さまも基準角（180°）が変わるだけで水平。
    func testUpsideDownIsLevelAgainstOneEightyDegrees() {
        let reading = HorizonMath.reading(gravityX: 0, gravityY: 1)

        XCTAssertEqual(reading.rollDegrees, 0, accuracy: 0.001)
        XCTAssertTrue(reading.isLevel)
        XCTAssertEqual(reading.orientation, .portraitUpsideDown)
    }

    /// ⭐️ 空へ真上に向けた状態（x/y 成分がほぼゼロ）では回転角が求まらない。
    ///    嘘のガイドを出さないよう isReliable = false にする。
    func testPointingAtSkyIsNotReliable() {
        // x/y の大きさが閾値 0.25 未満（ほぼ真上）
        let reading = HorizonMath.reading(gravityX: 0.1, gravityY: -0.1)

        XCTAssertFalse(reading.isReliable, "真上を向いていたら傾きは信頼できない")
    }

    /// 閾値ちょうど（0.25）は「信頼できる」側に含める（境界の取りこぼし防止）。
    func testReliabilityThresholdBoundary() {
        let reading = HorizonMath.reading(gravityX: 0, gravityY: -HorizonMath.reliabilityThreshold)

        XCTAssertTrue(reading.isReliable, "閾値ちょうどは信頼できる側")
    }
}

// MARK: - グリッド

final class SkyCameraGridGeometryTests: XCTestCase {

    /// 三分割の縦線は幅の 1/3 と 2/3。
    func testVerticalThirds() {
        let xs = GridGeometry.verticalLineXs(width: 300)

        XCTAssertEqual(xs.count, 2)
        XCTAssertEqual(xs.first ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(xs.last ?? -1, 200, accuracy: 0.001)
    }

    /// 三分割の横線は高さの 1/3 と 2/3。
    func testHorizontalThirds() {
        let ys = GridGeometry.horizontalLineYs(height: 600)

        XCTAssertEqual(ys.count, 2)
        XCTAssertEqual(ys.first ?? -1, 200, accuracy: 0.001)
        XCTAssertEqual(ys.last ?? -1, 400, accuracy: 0.001)
    }

    /// 幅ゼロ（レイアウト確定前）でも落ちないこと。
    func testZeroSizeDoesNotCrash() {
        XCTAssertEqual(GridGeometry.verticalLineXs(width: 0), [0, 0])
        XCTAssertEqual(GridGeometry.horizontalLineYs(height: 0), [0, 0])
    }
}
