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

    // MARK: - Preview

    @ViewBuilder
    private func moodFramePreview(image: UIImage, mood: Mood) -> some View {
        let style = mood.style
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 240)
            .overlay(alignment: captionAlignment(style.captionPlacement)) {
                if !trimmedCaption.isEmpty {
                    Text(caption)
                        .font(.system(size: 15, design: style.fontDesign))
                        .fontWeight(.semibold)
                        .foregroundColor(style.captionColor)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .padding(20)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        LinearGradient(colors: style.palette, startPoint: .top, endPoint: .bottom),
                        lineWidth: 6
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
