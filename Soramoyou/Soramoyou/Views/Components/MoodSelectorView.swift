// ⭐️ MoodSelectorView.swift
// 気分(mood)選択 + 世界観プレビュー（機能1）
//
//  MoodSelectorView.swift
//  Soramoyou
//
//  Created on 2026-06-09.
//
//  PostInfoView の肥大化（SwiftUI body の型チェックタイムアウト）を避けるため、
//  mood 選択 UI を独立コンポーネントへ分離する。選んだ mood のフレーム＋キャプションの
//  プレビューは SwiftUI による軽量な近似で、実際の書き出し（ImageCompositor 焼き込み）
//  とは別レイヤ。
//

import SwiftUI

struct MoodSelectorView: View {
    /// 選択中の気分（親 ViewModel と双方向バインド）
    @Binding var selectedMood: Mood?
    /// 選択中の枠スタイル（親 ViewModel と双方向バインド）
    @Binding var selectedFrameStyle: FrameStyle
    /// フレーム（額縁）に焼く一言。通常の投稿キャプション（ハッシュタグ用）とは別欄（双方向バインド）。
    @Binding var frameCaption: String
    /// プレビュー用の編集後画像（先頭1枚）。無ければプレビューは出さない。
    let previewImage: UIImage?

    /// フレーム用コメントの最大文字数（プレートに収まる短文に制限）
    private let frameCaptionLimit = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("気分")
                .font(.headline)
                .foregroundColor(.white)

            Text("選ぶと、その気分の額縁が写真の外側に付きます（任意）")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))

            moodGrid

            if let mood = selectedMood {
                Text(mood.tagline)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.top, 2)

                frameStylePicker

                frameCaptionField

                if let image = previewImage {
                    moodFramePreview(image: image, mood: mood)
                        .padding(.top, 8)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.15))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Grid

    private var moodGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(Mood.allCases) { mood in
                MoodButton(
                    mood: mood,
                    isSelected: selectedMood == mood,
                    action: { select(mood) }
                )
            }
        }
    }

    /// mood をトグル選択（同じ mood の再タップで解除）。選択時のみ計装する。
    private func select(_ mood: Mood) {
        let wasSelected = (selectedMood == mood)
        selectedMood = wasSelected ? nil : mood
        if !wasSelected {
            LoggingService.shared.logEvent("mood_selected", parameters: ["mood": mood.rawValue])
        }
    }

    // MARK: - Frame style picker

    /// 枠スタイル（クラシック / マット / バンド）の選択チップ列。mood 選択後に表示。
    private var frameStylePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("枠のスタイル")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
            HStack(spacing: 8) {
                ForEach(FrameStyle.allCases) { style in
                    FrameStyleChip(
                        style: style,
                        isSelected: selectedFrameStyle == style,
                        action: { selectFrameStyle(style) }
                    )
                }
            }
        }
        .padding(.top, 4)
    }

    /// 枠スタイルを選択（変化時のみ計装）。
    private func selectFrameStyle(_ style: FrameStyle) {
        guard selectedFrameStyle != style else { return }
        selectedFrameStyle = style
        LoggingService.shared.logEvent("frame_style_selected", parameters: ["frame_style": style.rawValue])
    }

    // MARK: - Frame caption input

    /// フレームに焼く一言の入力欄（通常コメントとは別。mood 選択時のみ表示・最大文字数で制限）。
    private var frameCaptionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("フレームに入れる一言")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
            TextField(
                "",
                text: Binding(
                    get: { frameCaption },
                    set: { frameCaption = String($0.prefix(frameCaptionLimit)) }
                ),
                prompt: Text("空を見て感じたこと（任意）").foregroundColor(.white.opacity(0.45))
            )
            .foregroundColor(.white)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)))
            Text("\(frameCaption.count)/\(frameCaptionLimit)・通常のコメント（ハッシュタグ）とは別です")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.top, 4)
    }

    // MARK: - Preview

    /// 実焼き込み（写真の外側に余白＋下プレート、コメントはプレートに描く）を近似するプレビュー。
    /// 正は書き出し側（ImageCompositor）。ここでは「コメントが写真に被らず下プレートに乗る」ことを伝える。
    @ViewBuilder
    private func moodFramePreview(image: UIImage, mood: Mood) -> some View {
        let trimmed = frameCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        let palette = mood.style.palette
        let style = selectedFrameStyle
        let sideInset: CGFloat = (style == .bottomBand) ? 0 : (style == .matte ? 14 : 12)
        let captionColor: Color = (style == .matte) ? Color(white: 0.12) : .white

        VStack(spacing: 0) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 200)
                .padding(.horizontal, sideInset)
                .padding(.top, sideInset)
                .padding(.bottom, trimmed.isEmpty ? sideInset : 6)

            if !trimmed.isEmpty {
                Text(trimmed)
                    .font(.system(size: 14, design: mood.style.fontDesign))
                    .fontWeight(.semibold)
                    .foregroundColor(captionColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(plateBackground(style: style, palette: palette))
            }
        }
        .background(frameBackground(style: style, palette: palette))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 枠全体の背景（classic=mood グラデ / matte=白マット / band=ほぼ透明＝写真が主役）。
    @ViewBuilder
    private func frameBackground(style: FrameStyle, palette: [Color]) -> some View {
        switch style {
        case .classic:    LinearGradient(colors: palette, startPoint: .top, endPoint: .bottom)
        case .matte:      Color(white: 0.98)
        case .bottomBand: Color.black.opacity(0.001)
        }
    }

    /// プレート（コメント帯）の背景（classic=mood グラデ / matte=白 / band=濃色グラデ）。
    @ViewBuilder
    private func plateBackground(style: FrameStyle, palette: [Color]) -> some View {
        switch style {
        case .classic:    LinearGradient(colors: palette, startPoint: .top, endPoint: .bottom)
        case .matte:      Color(white: 0.98)
        case .bottomBand: LinearGradient(colors: [(palette.first ?? .white).opacity(0.85), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
    }
}

// MARK: - Mood Button

struct MoodButton: View {
    let mood: Mood
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        }) {
            VStack(spacing: 6) {
                Image(systemName: mood.iconName)
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.7))

                Text(mood.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color(red: 0.39, green: 0.58, blue: 0.93) : .white.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isSelected ? Color.white.opacity(0.4) : Color.white.opacity(0.2),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .accessibilityLabel("\(mood.displayName)の気分")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Frame Style Chip

/// 枠スタイルの選択チップ（mood 選択後の「枠のスタイル」列）
struct FrameStyleChip: View {
    let style: FrameStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            HStack(spacing: 5) {
                Image(systemName: style.iconName)
                    .font(.system(size: 13))
                Text(style.displayName)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color(red: 0.39, green: 0.58, blue: 0.93) : .white.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(isSelected ? Color.white.opacity(0.4) : Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .accessibilityLabel("\(style.displayName)の枠")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
