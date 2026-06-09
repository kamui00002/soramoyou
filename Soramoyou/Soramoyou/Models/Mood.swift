// ⭐️ Mood.swift
// 気分（mood）— 投稿にまとう「世界観」
//
//  Mood.swift
//  Soramoyou
//
//  Created on 2026-06-08.
//
//  機能1（気分フレーム＋気持ちコメント）の中核データ。
//  - `Mood` は Firestore に保存される純データ（String raw / Codable / SwiftUI 非依存で扱える）。
//  - `MoodStyle` は各 mood の配色・フォント・キャプション位置をまとめた表示用スタイル。
//    プレビュー（SwiftUI）にも書き出し（Core Image 焼き込み）にも導出できるよう、
//    具体的な Color / Font.Design / 位置を「データ」として保持する。
//
//  配色・フォント・キャプション位置は v1 のたたき台。感性側のチューニング対象なので、
//  値の調整だけで世界観を変えられるよう 1 か所（MoodStyle.style）に集約している。
//

import SwiftUI

// MARK: - Mood

/// 投稿にまとう気分（5 種）
///
/// 「気持ちを直接書かせる」のではなく「気分の世界観 ＋ 一言」で滲ませる設計。
/// raw value は Firestore 保存・後方互換のため固定文字列とする（表示名の変更で壊れない）。
enum Mood: String, Codable, CaseIterable, Identifiable {
    case calm       // 穏やか
    case uplifted   // 高揚
    case wistful    // 切ない
    case dignified  // 凛
    case dreamy     // 夢幻

    var id: String { rawValue }

    /// 表示名（日本語）
    var displayName: String {
        switch self {
        case .calm: return "穏やか"
        case .uplifted: return "高揚"
        case .wistful: return "切ない"
        case .dignified: return "凛"
        case .dreamy: return "夢幻"
        }
    }

    /// SF Symbols アイコン名 ☀️（mood 選択 UI 用）
    var iconName: String {
        switch self {
        case .calm: return "cloud"
        case .uplifted: return "sun.max"
        case .wistful: return "sunset"
        case .dignified: return "mountain.2"
        case .dreamy: return "sparkles"
        }
    }

    /// 一言の世界観（mood 選択 UI の補助テキスト）
    var tagline: String {
        switch self {
        case .calm: return "静かな空に、ひとことを"
        case .uplifted: return "晴れやかな気持ちのままに"
        case .wistful: return "暮れていく空へ、そっと"
        case .dignified: return "凛とした空気を一枚に"
        case .dreamy: return "うつろう色に、夢をのせて"
        }
    }

    /// この mood の世界観スタイル（配色・フォント・キャプション位置）
    var style: MoodStyle { MoodStyle.style(for: self) }
}

// MARK: - FrameStyle

/// 写真にまとう「枠の形」（mood の色で展開される）。
///
/// `Mood` が色・世界観を決め、`FrameStyle` が枠の形を決める **直交軸**。
/// これにより mood ごとに複数の見た目（候補）から選べる（spec「フレーム候補から選ぶ」）。
/// 保存は `frameId = "\(mood.rawValue)_\(frameStyle.rawValue)"`。raw value は保存値なので固定文字列。
enum FrameStyle: String, Codable, CaseIterable, Identifiable {
    case classic     // 色帯＋白い内枠線（額装）
    case matte       // 白いマット（ギャラリー風の余白）
    case bottomBand  // 下に色帯、写真は広く見せる（ミニマル・キャプション主役）

    var id: String { rawValue }

    /// 表示名（枠スタイル選択 UI 用）
    var displayName: String {
        switch self {
        case .classic: return "クラシック"
        case .matte: return "マット"
        case .bottomBand: return "バンド"
        }
    }

    /// SF Symbols アイコン名（選択チップ用）
    var iconName: String {
        switch self {
        case .classic: return "photo.artframe"
        case .matte: return "rectangle.inset.filled"
        case .bottomBand: return "text.below.photo"
        }
    }
}

// MARK: - FrameFontStyle

/// フレーム文字に使うフォントの種類（ユーザー選択）。
///
/// `nil`（未選択）のときは mood ごとの既定フォント（`MoodStyle.fontDesign`）を使う。
/// 各ケースは SwiftUI の `Font.Design` に 1:1 対応。raw value は Firestore 保存値なので固定文字列。
enum FrameFontStyle: String, Codable, CaseIterable, Identifiable {
    case standard    // 端正（.default）
    case rounded     // 丸ゴシック（.rounded）
    case serif       // 明朝（.serif）
    case mono        // 等幅（.monospaced）

    var id: String { rawValue }

    /// 対応する SwiftUI フォントデザイン
    var fontDesign: Font.Design {
        switch self {
        case .standard: return .default
        case .rounded:  return .rounded
        case .serif:    return .serif
        case .mono:     return .monospaced
        }
    }

    /// 表示名（フォント選択 UI 用）
    var displayName: String {
        switch self {
        case .standard: return "標準"
        case .rounded:  return "丸ゴ"
        case .serif:    return "明朝"
        case .mono:     return "等幅"
        }
    }

    /// SF Symbols アイコン名（選択チップ用）
    var iconName: String {
        switch self {
        case .standard: return "textformat"
        case .rounded:  return "textformat.alt"
        case .serif:    return "textformat.size"
        case .mono:     return "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - TextPlacement

/// キャプションの配置位置（フレーム内の縦方向）
///
/// Codable にしておき、将来ユーザーが位置を動かせる版でも保存に再利用できるようにする。
enum TextPlacement: String, Codable, CaseIterable {
    case top
    case center
    case bottom
}

// MARK: - MoodStyle

/// mood ごとの世界観スタイル
///
/// SwiftUI 依存（`Color` / `Font.Design`）。プレビュー表示・書き出し焼き込みの双方から
/// 同じ定義を参照することで、見た目とエクスポートのズレを防ぐ。
struct MoodStyle {
    /// フレーム/装飾に使う配色（グラデーション等。先頭=主色）
    let palette: [Color]
    /// キャプション文字色
    let captionColor: Color
    /// キャプションのフォントデザイン（serif=叙情的 / rounded=やわらか / default=端正）
    let fontDesign: Font.Design
    /// キャプションの配置位置
    let captionPlacement: TextPlacement

    /// mood に対応するスタイルを返す（v1 たたき台）
    static func style(for mood: Mood) -> MoodStyle {
        switch mood {
        case .calm:
            // 穏やか：淡い空色、端正なフォント、下寄せ
            return MoodStyle(
                palette: DesignTokens.Colors.daySkyGradient,
                captionColor: DesignTokens.Colors.textPrimary,
                fontDesign: .default,
                captionPlacement: .bottom
            )
        case .uplifted:
            // 高揚：ゴールデンアワーの暖色、やわらかフォント、中央
            return MoodStyle(
                palette: [DesignTokens.Colors.goldenHour, DesignTokens.Colors.sunsetOrange],
                captionColor: DesignTokens.Colors.textPrimary,
                fontDesign: .rounded,
                captionPlacement: .center
            )
        case .wistful:
            // 切ない：夕暮れのグラデーション、叙情的な serif、下寄せ
            return MoodStyle(
                palette: DesignTokens.Colors.eveningSkyGradient,
                captionColor: DesignTokens.Colors.textPrimary,
                fontDesign: .serif,
                captionPlacement: .bottom
            )
        case .dignified:
            // 凛：深い夜空、端正なフォント、上寄せ
            return MoodStyle(
                palette: DesignTokens.Colors.nightSkyGradient,
                captionColor: DesignTokens.Colors.textPrimary,
                fontDesign: .default,
                captionPlacement: .top
            )
        case .dreamy:
            // 夢幻：パステルパープル、叙情的な serif、中央
            return MoodStyle(
                palette: [DesignTokens.Colors.pastelPurple, DesignTokens.Colors.softPink],
                captionColor: DesignTokens.Colors.textPrimary,
                fontDesign: .serif,
                captionPlacement: .center
            )
        }
    }
}
