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
    /// プレビューに重ねるキャプション（表示のみ）
    let caption: String
    /// プレビュー用の編集後画像（先頭1枚）。無ければプレビューは出さない。
    let previewImage: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("気分")
                .font(.headline)
                .foregroundColor(.white)

            Text("選ぶと、その気分のフレームと一言が写真に重なります（任意）")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))

            moodGrid

            if let mood = selectedMood {
                Text(mood.tagline)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.top, 2)

                frameStylePicker

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

    // MARK: - Preview

    @ViewBuilder
    private func moodFramePreview(image: UIImage, mood: Mood) -> some View {
        let moodStyle = mood.style
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBand = (selectedFrameStyle == .bottomBand)
        // バンドは下帯に白文字、それ以外は mood の文字色・配置（実焼き込みと整合）。
        let captionColor: Color = isBand ? .white : moodStyle.captionColor
        let alignment: Alignment = isBand ? .bottom : captionAlignment(moodStyle.captionPlacement)

        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 240)
            // 実際の焼き込み(ImageCompositor)の見え方に近づけた近似。正は書き出し側。
            // レイヤ順は実焼き込み（写真→枠→キャプション）に合わせ、枠を下・キャプションを上に重ねる
            //（bottomBand で暗帯が白文字を被さないように）。
            .overlay { framePreviewOverlay(mood: mood) }
            .overlay(alignment: alignment) {
                if !trimmedCaption.isEmpty {
                    Text(caption)
                        .font(.system(size: 15, design: moodStyle.fontDesign))
                        .fontWeight(.semibold)
                        .foregroundColor(captionColor)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        .padding(isBand ? 14 : 20)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 枠スタイルごとのプレビュー近似（クラシック=色枠 / マット=白枠 / バンド=下帯）。
    @ViewBuilder
    private func framePreviewOverlay(mood: Mood) -> some View {
        let palette = mood.style.palette
        switch selectedFrameStyle {
        case .classic:
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        LinearGradient(colors: palette, startPoint: .top, endPoint: .bottom),
                        lineWidth: 16
                    )
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                    .padding(15)
            }
        case .matte:
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(white: 0.98), lineWidth: 18)
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder((palette.first ?? .white).opacity(0.95), lineWidth: 2)
                    .padding(17)
            }
        case .bottomBand:
            VStack(spacing: 0) {
                Rectangle()
                    .fill(palette.first ?? .white)
                    .frame(height: 4)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 70)
            }
            .allowsHitTesting(false)
        }
    }

    /// TextPlacement を SwiftUI の Alignment へ変換
    private func captionAlignment(_ placement: TextPlacement) -> Alignment {
        switch placement {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
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
