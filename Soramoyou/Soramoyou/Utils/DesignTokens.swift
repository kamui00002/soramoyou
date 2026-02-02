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

        /// ゴールデンアワー
        static let goldenHour = Color(red: 1.0, green: 0.85, blue: 0.60)

        /// オーロラグリーン
        static let auroraGreen = Color(red: 0.40, green: 0.85, blue: 0.75)

        // MARK: Text Colors（テキストカラー）

        /// プライマリテキスト（白背景上）
        static let textPrimary = Color.white

        /// セカンダリテキスト（少し薄い白）- WCAG AA準拠
        static let textSecondary = Color.white.opacity(0.85)

        /// ターシャリテキスト（薄い白）- WCAG AA準拠
        static let textTertiary = Color.white.opacity(0.70)

        /// ダークテキスト（明るい背景用）
        static let textDark = Color(red: 0.15, green: 0.15, blue: 0.20)

        // MARK: Glass Colors（グラスモーフィズム用）

        /// グラスの背景色（プライマリ）
        static let glassPrimary = Color.white.opacity(0.25)

        /// グラスの背景色（セカンダリ）
        static let glassSecondary = Color.white.opacity(0.15)

        /// グラスの背景色（ターシャリ - より透明）
        static let glassTertiary = Color.white.opacity(0.08)

        /// グラスのボーダー色（プライマリ）
        static let glassBorderPrimary = Color.white.opacity(0.5)

        /// グラスのボーダー色（セカンダリ）
        static let glassBorderSecondary = Color.white.opacity(0.3)

        /// グラスのボーダー色（アクセント - グラデーション始点）
        static let glassBorderAccentStart = Color.white.opacity(0.6)

        /// グラスのボーダー色（アクセント - グラデーション終点）
        static let glassBorderAccentEnd = Color.white.opacity(0.1)

        // MARK: Interactive Colors（インタラクティブ）

        /// ホバー/アクティブ時のハイライト
        static let interactiveHighlight = Color.white.opacity(0.1)

        /// 選択状態のアクセント
        static let selectionAccent = Color(red: 0.45, green: 0.65, blue: 0.95)

        /// 成功状態
        static let success = Color(red: 0.40, green: 0.80, blue: 0.55)

        /// 警告状態
        static let warning = Color(red: 0.95, green: 0.75, blue: 0.35)

        // MARK: Gradient for Title（タイトル用グラデーション）

        /// タイトル用グラデーション
        static let titleGradient: [Color] = [
            Color(red: 0.4, green: 0.6, blue: 0.9),   // 明るい空色
            Color(red: 0.3, green: 0.5, blue: 0.85),  // 中間の青
            Color(red: 0.5, green: 0.3, blue: 0.8)    // 夕暮れのパープル
        ]

        /// アクセントグラデーション（ボタン・ハイライト用）
        static let accentGradient: [Color] = [
            Color(red: 0.50, green: 0.70, blue: 0.95),
            Color(red: 0.60, green: 0.45, blue: 0.90)
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

        /// 画面マージン: 20pt
        static let screenMargin: CGFloat = 20

        /// カード内パディング: 16pt
        static let cardPadding: CGFloat = 16
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

        /// 巨大: 28pt（フローティング要素用）
        static let xxl: CGFloat = 28

        /// カード用: 16pt
        static let card: CGFloat = 16

        /// ボタン用: 14pt
        static let button: CGFloat = 14

        /// フルラウンド（ピル型）
        static let full: CGFloat = 100

        /// チップ用: 20pt
        static let chip: CGFloat = 20
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
            color: Color.black.opacity(0.12),
            radius: 16,
            x: 0,
            y: 8
        )

        /// ストロングシャドウ
        static let strong = ShadowStyle(
            color: Color.black.opacity(0.18),
            radius: 24,
            x: 0,
            y: 12
        )

        /// ボタン用シャドウ
        static let button = ShadowStyle(
            color: Color.black.opacity(0.15),
            radius: 10,
            x: 0,
            y: 5
        )

        /// カード用シャドウ
        static let card = ShadowStyle(
            color: Color.black.opacity(0.10),
            radius: 20,
            x: 0,
            y: 10
        )

        /// フローティング要素用シャドウ
        static let floating = ShadowStyle(
            color: Color.black.opacity(0.20),
            radius: 30,
            x: 0,
            y: 15
        )

        /// グロー効果（青系）
        static let glow = ShadowStyle(
            color: Color(red: 0.4, green: 0.6, blue: 0.9).opacity(0.35),
            radius: 20,
            x: 0,
            y: 0
        )

        /// インナーシャドウ風（押下時）
        static let inner = ShadowStyle(
            color: Color.black.opacity(0.08),
            radius: 4,
            x: 0,
            y: 2
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
        static let quickSpring = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.65)

        /// スムーススプリング（なめらか）
        static let smoothSpring = SwiftUI.Animation.spring(response: 0.55, dampingFraction: 0.85)

        /// バウンシースプリング（弾む）
        static let bouncySpring = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.55)

        /// スローイーズ
        static let slowEase = SwiftUI.Animation.easeInOut(duration: 0.4)

        /// ファストイーズ
        static let fastEase = SwiftUI.Animation.easeOut(duration: 0.2)

        /// ボタンプレス
        static let buttonPress = SwiftUI.Animation.spring(response: 0.25, dampingFraction: 0.6)

        /// カードホバー
        static let cardHover = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.7)

        /// フェードイン
        static let fadeIn = SwiftUI.Animation.easeIn(duration: 0.25)

        /// フェードアウト
        static let fadeOut = SwiftUI.Animation.easeOut(duration: 0.2)

        /// 画面遷移用
        static let transition = SwiftUI.Animation.spring(response: 0.45, dampingFraction: 0.8)

        /// フィード登場のディレイ倍率
        static let staggerDelay: Double = 0.05

        /// 雲アニメーション時間
        static let cloudDuration: Double = 10.0

        /// パルスアニメーション時間
        static let pulseDuration: Double = 1.5
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

        /// 小キャプション用フォントサイズ
        static let smallCaptionSize: CGFloat = 12

        /// ヒーローテキスト用フォントサイズ
        static let heroSize: CGFloat = 42

        /// ボタンテキスト用フォントサイズ
        static let buttonSize: CGFloat = 17

        /// タブラベル用フォントサイズ
        static let tabLabelSize: CGFloat = 11
    }

    // MARK: - Blur（ブラー設定）

    enum Blur {
        /// 薄いブラー
        static let light: CGFloat = 10

        /// 中程度のブラー
        static let medium: CGFloat = 20

        /// 強いブラー
        static let heavy: CGFloat = 40

        /// 背景用ブラー
        static let background: CGFloat = 30
    }

    // MARK: - Duration（時間設定）

    enum Duration {
        /// 超短時間
        static let instant: Double = 0.1

        /// 短時間
        static let short: Double = 0.2

        /// 中程度
        static let medium: Double = 0.35

        /// 長時間
        static let long: Double = 0.5

        /// スロー
        static let slow: Double = 0.8
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
