// ⭐️ 水平線ガイドの純粋計算（UI・CoreMotion に依存しないのでテストしやすい）
import Foundation

/// 端末の傾き（重力ベクトル）から水平線ガイドの表示情報を計算する純関数群。
///
/// 端末座標系の重力ベクトルは、正立（ポートレート）で `(0, -1, 0)` になる。
/// x は画面の右方向、y は画面の上方向。よって
/// ポートレート `y ≈ -1` / 上下逆 `y ≈ +1` / ランドスケープ左 `x ≈ -1` / 右 `x ≈ +1`。
public enum HorizonMath {

    /// 「水平」とみなす許容角度（度）。標準カメラの水平インジケータに合わせて ±1°。
    public static let levelToleranceDegrees: Double = 1.0

    /// 重力ベクトルの画面平面成分（x, y）の大きさがこの値未満なら、
    /// 端末がほぼ真上（＝空）を向いていて回転角が求まらないと判断する。
    public static let reliabilityThreshold: Double = 0.25

    /// 端末の向き（`UIDeviceOrientation` と同じ意味づけ）。
    public enum DeviceOrientation: Equatable {
        case portrait
        case portraitUpsideDown
        case landscapeLeft
        case landscapeRight
    }

    /// 水平線ガイド 1 回分の読み取り結果。
    public struct Reading: Equatable {
        /// 最寄りの基準角（0 / 90 / 180 / 270°）からのズレ（度・符号付き・-45...45）。
        /// SwiftUI の `rotationEffect(.degrees(rollDegrees))` にそのまま渡すと、
        /// 画面上で「本当の水平」を指す線になる。
        public let rollDegrees: Double
        /// 水平とみなせるか（`|rollDegrees| <= levelToleranceDegrees`）。
        public let isLevel: Bool
        /// 傾きの計算が信頼できるか（真上を向いていると false）。
        public let isReliable: Bool
        /// 最寄りの基準角から決めた端末の向き（撮影向きのフォールバックに使う）。
        public let orientation: DeviceOrientation

        public init(
            rollDegrees: Double,
            isLevel: Bool,
            isReliable: Bool,
            orientation: DeviceOrientation = .portrait
        ) {
            self.rollDegrees = rollDegrees
            self.isLevel = isLevel
            self.isReliable = isReliable
            self.orientation = orientation
        }
    }

    /// 重力ベクトルの x / y 成分から傾きを求める。
    /// - Parameters:
    ///   - gravityX: `CMDeviceMotion.gravity.x`（端末座標系）
    ///   - gravityY: `CMDeviceMotion.gravity.y`（端末座標系）
    /// - Returns: 最寄りの 0 / 90 / 180 / 270° を基準にしたズレ・水平判定・信頼度・端末の向き
    public static func reading(gravityX: Double, gravityY: Double) -> Reading {
        // 画面平面に投影した重力の大きさ。真上（空）を向けるとゼロに近づき、回転角が決まらなくなる。
        let magnitude = (gravityX * gravityX + gravityY * gravityY).squareRoot()
        let isReliable = magnitude >= reliabilityThreshold

        // 端末の回転角。正立（重力 = (0, -1)）で 0°、反時計回りが正。
        let degrees = atan2(-gravityX, -gravityY) * 180.0 / .pi

        // 最寄りの基準角（0 / ±90 / 180）を求め、そこからのズレを roll とする。
        // これにより「横持ちでも水平が取れる」（縦持ちだけの水平器にしない）。
        let quadrant = (degrees / 90.0).rounded()
        let roll = degrees - quadrant * 90.0

        // 基準角から端末の向きを決める。-2 と 2 はどちらも上下逆さま。
        let normalized = ((Int(quadrant) % 4) + 4) % 4
        let orientation: DeviceOrientation
        switch normalized {
        case 1:  orientation = .landscapeLeft
        case 2:  orientation = .portraitUpsideDown
        case 3:  orientation = .landscapeRight
        default: orientation = .portrait
        }

        return Reading(
            rollDegrees: roll,
            // 傾きが信頼できないときに「水平」と言い切らない（嘘のガイドを出さない）。
            isLevel: isReliable && abs(roll) <= levelToleranceDegrees,
            isReliable: isReliable,
            orientation: orientation
        )
    }
}
