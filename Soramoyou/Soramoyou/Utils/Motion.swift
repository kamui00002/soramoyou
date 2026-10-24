//
//  Motion.swift ⭐️
//  Soramoyou
//
//  端末の「視差効果を減らす」に合わせて動きを選ぶ共通部品
//  1.18.0 の UI 刷新 PR-U「土台 2」（計画書 ~/.claude/plans/profile-visibility-toggles.md）
//

import SwiftUI

/// 「視差効果を減らす」に合わせて動きを選ぶ（ON のときは動かさず一瞬で変える）
///
/// 「視差効果を減らす」は、端末の「設定 > アクセシビリティ > 動作 > 視差効果を減らす」。
/// 画面の動きで気分が悪くなる人が ON にする設定なので、ON のときはアニメーションを付けずに
/// 一瞬で次の見た目へ切り替える。
///
/// ## ON / OFF の読み方（使い分け）
/// - **View の中**: `@Environment(\.accessibilityReduceMotion) private var reduceMotion` を読んで渡す。
///   SwiftUI が設定の変化を見張ってくれるので、途中で切り替えても次の描画から新しい値になる。
/// - **View の外**（ViewModel やボタンの処理など、環境値が届かない所）: `UIAccessibility.isReduceMotionEnabled` を読んで渡す。
///   こちらは呼んだ瞬間の値で、変化は自動では届かない。
///
/// ## 使い方
/// ```swift
/// @Environment(\.accessibilityReduceMotion) private var reduceMotion
///
/// withAnimation(Motion.animation(.easeOut(duration: 0.3), reduceMotion: reduceMotion)) {
///     isShown = true
/// }
/// ```
///
/// ## ずっと動くもの（`repeatForever`）の扱い
/// `nil` を返すので、`withAnimation(nil) { 値 = 終点 }` は「終点で止めた絵」になる。
/// 始点で止めたい（あるいは止めた絵を別の値にしたい）所では、この関数を通さずに
/// 「ON のときは動きを始めない」と分岐する（例: `SkyBackgroundView` の雲）。
enum Motion {
    /// 「視差効果を減らす」の ON / OFF に合わせて、付けるアニメーションを返す
    /// - Parameters:
    ///   - base: OFF のときに付けたい動き
    ///   - reduceMotion: 「視差効果を減らす」が ON か
    /// - Returns: ON なら `nil`（動かさず一瞬で変える）、OFF なら `base` をそのまま
    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }
}
