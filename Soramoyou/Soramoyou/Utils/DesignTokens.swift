//
//  DesignTokens.swift
//  Soramoyou
//
//  Created on 2025-01-31.
//
//  デザイントークンを集約したファイル ⭐️
//  色、スペーシング、コーナーラジアス、シャドウなどの定数を管理
//

import SwiftUI

// MARK: - Design Tokens

/// アプリ全体で使用するデザイントークン
/// マジックナンバーを排除し、一貫したデザインを実現
enum DesignTokens {

    // MARK: - Colors（カラーパレット）

    enum Colors {

        // MARK: Sky Gradient（空のグラデーション）

        /// 昼間の空グラデーション
        static let daySkyGradient: [Color] = [
            Color(red: 0.68, green: 0.85, blue: 0.90),  // 淡い空色
            Color(red: 0.53, green: 0.81, blue: 0.98),  // 空色
            Color(red: 0.39, green: 0.58, blue: 0.93)   // 深い空色
        ]

        /// 夕暮れの空グラデーション
        static let eveningSkyGradient: [Color] = [
            Color(red: 0.95, green: 0.65, blue: 0.55),  // 夕焼けオレンジ
            Color(red: 0.85, green: 0.50, blue: 0.60),  // ピンクがかった紫
            Color(red: 0.45, green: 0.35, blue: 0.65)   // 深い紫
        ]

        /// 夜空グラデーション
        static let nightSkyGradient: [Color] = [
            Color(red: 0.15, green: 0.20, blue: 0.35),  // 深い紺
            Color(red: 0.10, green: 0.15, blue: 0.30),  // 夜空
            Color(red: 0.05, green: 0.10, blue: 0.25)   // 濃い夜空
        ]

        // MARK: Accent Colors（アクセントカラー）

        /// 夕焼けオレンジ
        static let sunsetOrange = Color(red: 0.98, green: 0.60, blue: 0.40)

        /// スカイブルー
        static let skyBlue = Color(red: 0.40, green: 0.60, blue: 0.90)

        /// ソフトピンク
        static let softPink = Color(red: 0.95, green: 0.70, blue: 0.75)

        /// パステルパープル
        static let pastelPurple = Color(red: 0.70, green: 0.55, blue: 0.85)

        // MARK: Text Colors（テキストカラー）

        /// プライマリテキスト（白背景上）
        static let textPrimary = Color.white

        /// セカンダリテキスト（少し薄い白）- WCAG AA準拠
        static let textSecondary = Color.white.opacity(0.85)

        /// ターシャリテキスト（薄い白）- WCAG AA準拠
        static let textTertiary = Color.white.opacity(0.75)

        // MARK: Glass Colors（グラスモーフィズム用）

        /// グラスの背景色（プライマリ）
        static let glassPrimary = Color.white.opacity(0.25)

        /// グラスの背景色（セカンダリ）
        static let glassSecondary = Color.white.opacity(0.15)

        /// グラスのボーダー色（プライマリ）
        static let glassBorderPrimary = Color.white.opacity(0.5)

        /// グラスのボーダー色（セカンダリ）
        static let glassBorderSecondary = Color.white.opacity(0.3)

        // MARK: Gradient for Title（タイトル用グラデーション）

        /// タイトル用グラデーション
        static let titleGradient: [Color] = [
            Color(red: 0.4, green: 0.6, blue: 0.9),   // 明るい空色
            Color(red: 0.3, green: 0.5, blue: 0.85),  // 中間の青
            Color(red: 0.5, green: 0.3, blue: 0.8)    // 夕暮れのパープル
        ]
    }

    // MARK: - Spacing（スペーシング）

    enum Spacing {
        /// 極小: 4pt
        static let xs: CGFloat = 4

        /// 小: 8pt
        static let sm: CGFloat = 8

        /// 中: 16pt
        static let md: CGFloat = 16

        /// 大: 24pt
        static let lg: CGFloat = 24

        /// 特大: 32pt
        static let xl: CGFloat = 32

        /// 巨大: 48pt
        static let xxl: CGFloat = 48
    }

    // MARK: - Radius（コーナーラジアス）

    enum Radius {
        /// 小: 8pt
        static let sm: CGFloat = 8

        /// 中: 12pt
        static let md: CGFloat = 12

        /// 大: 16pt
        static let lg: CGFloat = 16

        /// 特大: 20pt
        static let xl: CGFloat = 20

        /// カード用: 16pt
        static let card: CGFloat = 16

        /// ボタン用: 14pt
        static let button: CGFloat = 14
    }

    // MARK: - Shadow（シャドウ）

    enum Shadow {
        /// ソフトシャドウ
        static let soft = ShadowStyle(
            color: Color.black.opacity(0.08),
            radius: 12,
            x: 0,
            y: 6
        )

        /// ミディアムシャドウ
        static let medium = ShadowStyle(
            color: Color.black.opacity(0.1),
            radius: 10,
            x: 0,
            y: 5
        )

        /// ストロングシャドウ
        static let strong = ShadowStyle(
            color: Color.black.opacity(0.15),
            radius: 15,
            x: 0,
            y: 8
        )

        /// ボタン用シャドウ
        static let button = ShadowStyle(
            color: Color.black.opacity(0.1),
            radius: 8,
            x: 0,
            y: 4
        )

        /// カード用シャドウ
        static let card = ShadowStyle(
            color: Color.black.opacity(0.08),
            radius: 12,
            x: 0,
            y: 6
        )

        /// テキスト用シャドウ（可読性向上）
        static let text = ShadowStyle(
            color: Color.black.opacity(0.3),
            radius: 2,
            x: 0,
            y: 1
        )
    }

    // MARK: - Animation（アニメーション）

    enum Animation {
        /// デフォルトスプリング
        static let defaultSpring = SwiftUI.Animation.spring(response: 0.5, dampingFraction: 0.7)

        /// クイックスプリング
        static let quickSpring = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.6)

        /// スローイーズ
        static let slowEase = SwiftUI.Animation.easeInOut(duration: 0.4)

        /// ボタンプレス
        static let buttonPress = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.6)

        /// フィード登場のディレイ倍率
        static let staggerDelay: Double = 0.05
    }

    // MARK: - Typography（タイポグラフィ）

    enum Typography {
        /// タイトル用フォントサイズ
        static let titleSize: CGFloat = 28

        /// サブタイトル用フォントサイズ
        static let subtitleSize: CGFloat = 20

        /// ボディ用フォントサイズ
        static let bodySize: CGFloat = 17

        /// キャプション用フォントサイズ
        static let captionSize: CGFloat = 14
    }
}

// MARK: - Shadow Style

/// シャドウスタイルを定義する構造体
struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

// MARK: - View Extension

extension View {
    /// ShadowStyleを適用するモディファイア
    func shadow(_ style: ShadowStyle) -> some View {
        self.shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}
