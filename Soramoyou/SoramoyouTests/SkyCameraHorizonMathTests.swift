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
    func testFiveDegreeTiltIsNotLevel() {
        // 端末を時計回りに 5° 傾けると、端末座標系の重力は反時計回りに 5° 回る。
        let radians = 5.0 * .pi / 180.0
        let reading = HorizonMath.reading(gravityX: sin(radians), gravityY: -cos(radians))

        XCTAssertEqual(abs(reading.rollDegrees), 5, accuracy: 0.01)
        XCTAssertFalse(reading.isLevel, "5°は許容(±1°)の外なので水平ではない")
        XCTAssertTrue(reading.isReliable)
        XCTAssertEqual(reading.orientation, .portrait, "5°程度なら最寄りの基準はポートレートのまま")
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
