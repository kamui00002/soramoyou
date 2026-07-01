//
//  GalleryExploreHeader.swift ⭐️
//  Soramoyou
//
//  ギャラリータブ上部の「探索ヘッダー」。
//  - 絞り込み（時間帯 / 空の種類）
//  - 並び替え（新着 / 人気）
//  - 色で探す（横スワイプのカラースウォッチ）
//  - シャッフル / レイアウト切替（グリッド⇔モザイク）
//
//  チップ・カラースウォッチは SearchView の FilterChip / ColorSelectionButton を再利用する。
//

import SwiftUI

struct GalleryExploreHeader: View {
    @ObservedObject var viewModel: GalleryViewModel

    /// 色で探すプリセット（SearchView と同じ主要色）
    private let colorPresets: [(name: String, hex: String)] = [
        ("青", "#0000FF"),
        ("赤", "#FF0000"),
        ("緑", "#00FF00"),
        ("黄", "#FFFF00"),
        ("紫", "#800080"),
        ("オレンジ", "#FFA500"),
        ("ピンク", "#FFC0CB"),
        ("シアン", "#00FFFF")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            // 並び替え・シャッフル・レイアウト切替
            controlsRow

            // 絞り込みチップ（時間帯 + 空の種類）
            filterChipsRow

            // 色で探す
            colorRow
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    // MARK: - 並び替え・操作ボタン行

    private var controlsRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // 新着 / 人気（絞り込み中は人気を無効化＝新着固定）
            sortChip(title: "新着", order: .newest)
            sortChip(title: "人気", order: .popular)

            Spacer()

            // シャッフル
            iconToggleButton(
                systemName: "shuffle",
                isOn: viewModel.isShuffled,
                accessibilityLabel: "シャッフル"
            ) {
                Task { await viewModel.toggleShuffle() }
            }

            // レイアウト切替（グリッド⇔モザイク）
            iconToggleButton(
                systemName: viewModel.layoutMode == .mosaic ? "rectangle.grid.1x2" : "square.grid.2x2",
                isOn: viewModel.layoutMode == .mosaic,
                accessibilityLabel: "表示レイアウト切替"
            ) {
                viewModel.toggleLayoutMode()
            }
        }
    }

    /// 新着/人気の並び替えチップ
    private func sortChip(title: String, order: GallerySortOrder) -> some View {
        // 「人気」は絞り込み中は選択不可（新着固定）
        let isDisabled = (order == .popular) && viewModel.hasActiveFilter
        let isSelected = !viewModel.isColorMode
            && viewModel.effectiveSortOrder.sortField == order.sortField
            && !isDisabled

        return FilterChip(
            title: title,
            isSelected: isSelected,
            action: {
                Task { await viewModel.setSortOrder(order) }
            }
        )
        .opacity(isDisabled ? 0.35 : 1.0)
        .disabled(isDisabled)
    }

    /// アイコンのトグルボタン（シャッフル・レイアウト）
    private func iconToggleButton(
        systemName: String,
        isOn: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        }) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isOn ? .white : DesignTokens.Colors.textSecondary)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(isOn ? DesignTokens.Colors.selectionAccent : DesignTokens.Colors.glassTertiary)
                        .overlay(
                            Circle().stroke(
                                isOn ? Color.white.opacity(0.3) : DesignTokens.Colors.glassBorderSecondary,
                                lineWidth: 1
                            )
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - 絞り込みチップ行

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(TimeOfDay.allCases, id: \.self) { timeOfDay in
                    FilterChip(
                        title: timeOfDay.displayName,
                        isSelected: viewModel.selectedTimeOfDay == timeOfDay,
                        action: {
                            Task { await viewModel.selectTimeOfDay(timeOfDay) }
                        }
                    )
                }

                // 時間帯と空の種類の区切り
                Divider()
                    .frame(height: 20)
                    .background(.white.opacity(0.3))

                ForEach(SkyType.allCases, id: \.self) { skyType in
                    FilterChip(
                        title: skyType.displayName,
                        isSelected: viewModel.selectedSkyType == skyType,
                        action: {
                            Task { await viewModel.selectSkyType(skyType) }
                        }
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 色で探す行

    private var colorRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.md) {
                ForEach(colorPresets, id: \.hex) { color in
                    ColorSelectionButton(
                        name: color.name,
                        hex: color.hex,
                        isSelected: viewModel.selectedColor == color.hex,
                        action: {
                            Task { await viewModel.selectColor(color.hex) }
                        }
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }
}
