// ⭐️ LivingSkyParameters.swift
// Living Sky（空のループアニメーション）のユーザー可変パラメータ
//
//  LivingSkyParameters.swift
//  Soramoyou
//
// 設計書: docs/living-sky-design.md §6（パラメータ）

import CoreGraphics

/// Living Sky v1 のユーザー可変パラメータ（設計書§6のテーブルに対応）。
///
/// すべて `var` で保持し、プレビュー中のスライダー操作でそのまま更新できるようにする。
/// `Equatable` は SwiftUI 側での変更検知（`onChange` 等）に使うため付与している。
struct LivingSkyParameters: Equatable {
    /// 風向き（度数）。0=右向き、反時計回りに増加する。
    var windAngleDegrees: Double = 0

    /// 速さ（≒変位振幅の強さ）。0.1〜1.0 の範囲を想定。
    /// 「自然さ最優先」の方針（設計書§6）から既定値はゆっくり寄りの 0.5。
    var speed: Double = 0.5

    /// 光のゆらぎの強さ 0...0.10。0 で無効。
    var shimmerAmount: Double = 0.05

    /// ループ長 T（秒）。6〜10 秒を想定。長いほど継ぎ目・クロスフェードの「呼吸」が目立たない
    /// （設計書§2.1「既知のトレードオフ」参照）。
    var loopDuration: Double = 8.0

    /// 空の変位量の上限（px）を画像幅から導出する。
    ///
    /// 設計書§6: 変位振幅Aの上限は「画像幅の 0.5〜1.5%」としていたが、段階3 vision レビューで
    /// 「フローが壊れているように見える」不具合が報告された。数式検証の結果、二相クロスフェードは
    /// 加重平均位相 `phi1・(1-w) + phi2・w` が全時刻で 0.5 に恒等的に固定される構造であるため、
    /// ソフトエッジの領域では出力がほぼ時不変になり、知覚できる動きは「各位相コピーがこの係数(px/秒)
    /// で滑る」分だけになることが判明した。旧係数 0.015 では 1080px・speed=0.5 のとき僅か 1px/秒 相当
    /// で、実装は正常でも知覚不能だった（=「壊れている」のではなく「見えないほど小さい」が真因）。
    /// 0.08 へ改定し、1080px・speed=0.5（既定値）で約4%幅/ループ・約5.4px/秒相当のドリフトにする。
    /// 知覚可能な最低ラインは概ね3px/秒、上限はクロスフェードの「呼吸」（w=0.5付近のソフト化）と
    /// ゴースト（二重像）で頭打ちになる想定。段階3以降の vision レビューで実際の見え方を再確認する。
    /// - Parameter imageWidth: ワーキング座標系での画像幅（px）
    /// - Returns: 最大変位量（px）
    func maxDisplacementPx(imageWidth: CGFloat) -> CGFloat {
        imageWidth * 0.08 * CGFloat(speed)
    }
}
