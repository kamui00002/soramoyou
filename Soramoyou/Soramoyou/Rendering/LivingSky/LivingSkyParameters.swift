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
    /// 設計書§6: 変位振幅Aの上限は「画像幅の 0.5〜1.5%」（これ以上はゴム状に伸びて破綻する）。
    /// v1 では「雲量（振幅A）」を独立パラメータとして UI 公開せず、`speed` に連動させて
    /// 0.5〜1.5%幅の範囲へ写像する（speed=1.0 で上限 1.5%幅、speed→0 に近づくほど振幅も小さくなる）。
    /// - Parameter imageWidth: ワーキング座標系での画像幅（px）
    /// - Returns: 最大変位量（px）
    func maxDisplacementPx(imageWidth: CGFloat) -> CGFloat {
        imageWidth * 0.015 * CGFloat(speed)
    }
}
