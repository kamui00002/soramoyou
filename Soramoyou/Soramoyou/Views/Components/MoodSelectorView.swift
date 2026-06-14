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
    /// フレーム文字色（"#RRGGBB"）。nil=おまかせ（自動色）。双方向バインド。
    @Binding var frameTextColorHex: String?
    /// フレーム文字フォント。nil=mood 既定フォント。双方向バインド。
    @Binding var frameFontStyle: FrameFontStyle?
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

                frameFontPicker

                frameColorPicker(mood: mood)

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
            // ⚠️ インライン Binding(get:set:) は実機の実キーボード入力で「打った文字が表示されない」
            //   不具合の原因になりうる。直接束縛にして、文字数制限は .onChange で後追いクランプする。
            TextField(
                "",
                text: $frameCaption,
                prompt: Text("空を見て感じたこと（任意）").foregroundColor(.white.opacity(0.45))
            )
            .foregroundColor(.white)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)))
            .onChange(of: frameCaption) { newValue in
                if newValue.count > frameCaptionLimit {
                    frameCaption = String(newValue.prefix(frameCaptionLimit))
                }
            }
            Text("\(frameCaption.count)/\(frameCaptionLimit)・通常のコメント（ハッシュタグ）とは別です")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.top, 4)
    }

    // MARK: - Frame font picker

    /// フレーム文字のフォント選択（おまかせ＝mood 既定 ＋ 4 種）。mood 選択後に表示。
    private var frameFontPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("文字のフォント")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // おまかせ（nil＝mood 既定フォント）
                    FrameFontChip(
                        title: "おまかせ",
                        iconName: "wand.and.stars",
                        isSelected: frameFontStyle == nil,
                        action: { selectFont(nil) }
                    )
                    ForEach(FrameFontStyle.allCases) { font in
                        FrameFontChip(
                            title: font.displayName,
                            iconName: font.iconName,
                            isSelected: frameFontStyle == font,
                            action: { selectFont(font) }
                        )
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    /// フォントを選択（変化時のみ計装）。
    private func selectFont(_ font: FrameFontStyle?) {
        guard frameFontStyle != font else { return }
        frameFontStyle = font
        LoggingService.shared.logEvent("frame_font_selected", parameters: ["font_style": font?.rawValue ?? "default"])
    }

    // MARK: - Frame color picker

    /// フレーム文字の色選択。おまかせ（自動色）トグル＋フルカラーピッカー。mood 選択後に表示。
    @ViewBuilder
    private func frameColorPicker(mood: Mood) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("文字の色")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))

            Toggle(isOn: autoColorBinding(mood: mood)) {
                Text("おまかせ（自動で読みやすい色）")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
            }
            .tint(Color(red: 0.39, green: 0.58, blue: 0.93))

            // おまかせ OFF のときのみピッカーを出す（おまかせ中は自動色に委ねる）。
            if frameTextColorHex != nil {
                ColorPicker(selection: colorBinding(mood: mood), supportsOpacity: false) {
                    Text("色を選ぶ")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                }
            }
        }
        .padding(.top, 4)
    }

    /// 「おまかせ」トグルのバインディング。ON→hex=nil、OFF→現在の自動色を初期値にセット。
    private func autoColorBinding(mood: Mood) -> Binding<Bool> {
        Binding(
            get: { frameTextColorHex == nil },
            set: { isAuto in
                if isAuto {
                    frameTextColorHex = nil
                } else {
                    // 自動 OFF：今の自動解決色を初期値に（プレビューと連続な見た目で開始）
                    let resolved = ImageCompositor.resolveCaptionColor(style: selectedFrameStyle, mood: mood, override: nil)
                    frameTextColorHex = resolved.toHexString()
                }
            }
        )
    }

    /// ColorPicker 用 Color バインディング（hex ⇄ Color）。設定すると hex が入る＝おまかせ自動解除。
    private func colorBinding(mood: Mood) -> Binding<Color> {
        Binding(
            get: {
                if let hex = frameTextColorHex, let c = Color(hex: hex) { return c }
                return Color(uiColor: ImageCompositor.resolveCaptionColor(style: selectedFrameStyle, mood: mood, override: nil))
            },
            set: { frameTextColorHex = $0.toHexString() }
        )
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
        // 文字色・フォントは焼き込みと同じ解決関数を使う（選んだ色／フォントとプレビューを一致させる）。
        let overrideColor = frameTextColorHex.flatMap { UIColor(hex: $0) }
        let captionColor = Color(uiColor: ImageCompositor.resolveCaptionColor(style: style, mood: mood, override: overrideColor))
        let fontDesign = ImageCompositor.resolveFontDesign(mood: mood, override: frameFontStyle)

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
                    .font(.system(size: 14, design: fontDesign))
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

// MARK: - Frame Font Chip

/// フレーム文字フォントの選択チップ（「おまかせ」＋ 4 種フォント列）
struct FrameFontChip: View {
    let title: String
    let iconName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 13))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
        .accessibilityLabel("\(title)のフォント")
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

// MARK: - Preview

/// mood 選択あり（枠・色・フォントの各ピッカーが見える状態）と未選択の2状態を確認する。
#Preview("mood 選択あり") {
    MoodSelectorViewPreviewHost(initialMood: .calm)
        .padding()
        .background(Color.black)
}

#Preview("mood 未選択") {
    MoodSelectorViewPreviewHost(initialMood: nil)
        .padding()
        .background(Color.black)
}

/// バインディングを保持してプレビューで実際に操作できるようにするホスト。
private struct MoodSelectorViewPreviewHost: View {
    @State private var mood: Mood?
    @State private var style: FrameStyle = .classic
    @State private var caption: String = "静かな空に、ひとことを"
    @State private var colorHex: String?
    @State private var fontStyle: FrameFontStyle?

    init(initialMood: Mood?) {
        _mood = State(initialValue: initialMood)
    }

    var body: some View {
        MoodSelectorView(
            selectedMood: $mood,
            selectedFrameStyle: $style,
            frameCaption: $caption,
            frameTextColorHex: $colorHex,
            frameFontStyle: $fontStyle,
            previewImage: nil
        )
    }
}
