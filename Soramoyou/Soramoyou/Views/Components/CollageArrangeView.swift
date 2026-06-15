// ⭐️ CollageArrangeView.swift
// 配置写真（v1）— レイアウト選択＋各パネルの一言ラベル入力＋近似プレビュー
//
//  Created on 2026-06-10.
//
//  PostInfoView の肥大化（body 型チェックタイムアウト）を避け、MoodSelectorView と同じ作法で
//  独立コンポーネント化。プレビューは SwiftUI による軽量な近似で、正は書き出し側
//  （SkyCollageCompositor）。気分フレームとは排他（配置写真モードのときだけ表示）。
//

import SwiftUI

struct CollageArrangeView: View {
    /// 並べ方（親 ViewModel と双方向バインド）
    @Binding var layout: CollageLayout
    /// 各パネルの一言ラベル（index は写真と対応・任意）
    @Binding var labels: [String]
    /// プレビュー用の編集後画像（最大4枚）
    let previewImages: [UIImage]

    /// ラベルの最大文字数（朝/昼/夕/夜 のような短文想定）
    private let labelLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("配置写真")
                .font(.headline)
                .foregroundColor(.white)

            Text("好きな空を4枚、自由に並べて1枚に。同じ空の朝・昼・夕・夜で「空の一日」も")
                .font(.caption)
                .foregroundColor(.white.opacity(0.85))

            layoutPicker

            labelFields

            if !previewImages.isEmpty {
                collagePreview
                    .padding(.top, 8)
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

    // MARK: - Layout picker

    private var layoutPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("並べ方")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
            HStack(spacing: 8) {
                ForEach(CollageLayout.allCases) { l in
                    CollageLayoutChip(layout: l, isSelected: layout == l, action: { selectLayout(l) })
                }
            }
        }
        .padding(.top, 4)
    }

    private func selectLayout(_ l: CollageLayout) {
        guard layout != l else { return }
        layout = l
        LoggingService.shared.logEvent("collage_layout_selected", parameters: ["layout": l.rawValue])
    }

    // MARK: - Label fields

    /// 各パネルの一言ラベル入力（4枠・任意・最大文字数で制限）。
    private var labelFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("各写真の一言（任意）")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
            ForEach(0..<4, id: \.self) { i in
                HStack(spacing: 8) {
                    Text("\(i + 1)")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 18)
                    // ⚠️ インライン Binding(get:set:) は実機の実キーボード入力で「打った文字が表示されない」
                    //   不具合の原因になりうる。直接の subscript 束縛にし、文字数制限は .onChange でクランプする。
                    //   labels は常に4要素だが、念のため範囲外は .constant("") にフォールバックして crash を防ぐ。
                    TextField(
                        "",
                        text: i < labels.count ? $labels[i] : .constant(""),
                        prompt: Text(placeholder(for: i)).foregroundColor(.white.opacity(0.45))
                    )
                    .foregroundColor(.white)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)))
                }
            }
            Text("空欄でもOK。文字は写真の下の帯に入ります")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.top, 4)
        .onChange(of: labels) { newLabels in
            for idx in newLabels.indices where newLabels[idx].count > labelLimit {
                labels[idx] = String(newLabels[idx].prefix(labelLimit))
            }
        }
    }

    private func placeholder(for i: Int) -> String {
        let examples = ["朝", "昼", "夕", "夜"]
        return i < examples.count ? "例: \(examples[i])" : ""
    }

    // MARK: - Preview（近似。正は SkyCollageCompositor）

    @ViewBuilder
    private var collagePreview: some View {
        let imgs = Array(previewImages.prefix(4))
        let cell: (Int) -> AnyView = { idx in
            AnyView(
                VStack(spacing: 0) {
                    if idx < imgs.count {
                        Image(uiImage: imgs[idx])
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: layout == .vertical4 ? 56 : 80)
                            .clipped()
                    } else {
                        Color(white: 0.9).frame(height: layout == .vertical4 ? 56 : 80)
                    }
                    if idx < labels.count, !labels[idx].trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(labels[idx])
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(Color(white: 0.18))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(Color(white: 0.98))
                    }
                }
                .background(Color(white: 0.98))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            )
        }

        Group {
            if layout == .grid2x2 {
                VStack(spacing: 6) {
                    HStack(spacing: 6) { cell(0); cell(1) }
                    HStack(spacing: 6) { cell(2); cell(3) }
                }
            } else {
                VStack(spacing: 6) { cell(0); cell(1); cell(2); cell(3) }
                    .frame(maxWidth: 180)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(6)
        .background(Color(white: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Collage Layout Chip

struct CollageLayoutChip: View {
    let layout: CollageLayout
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            HStack(spacing: 5) {
                Image(systemName: layout.iconName)
                    .font(.system(size: 13))
                Text(layout.displayName)
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
        .accessibilityLabel("\(layout.displayName)レイアウト")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    CollageArrangePreviewHost()
        .padding()
        .background(Color.black)
}

private struct CollageArrangePreviewHost: View {
    @State private var layout: CollageLayout = .grid2x2
    @State private var labels: [String] = ["朝", "昼", "夕", "夜"]
    var body: some View {
        CollageArrangeView(layout: $layout, labels: $labels, previewImages: [])
    }
}
