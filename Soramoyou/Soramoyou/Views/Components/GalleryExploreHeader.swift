//
//  GalleryExploreHeader.swift ⭐️
//  Soramoyou
//
//  ギャラリータブ上部の「探索ヘッダー」。
//  - 絞り込み（時間帯 / 空の種類）
//  - 並び替え（新着 / 人気 / 週間 / 月間）※週間・月間は「期間中に押されたいいね」のランキング ⭐️
//  - 色で探す（横スワイプのカラースウォッチ）
//  - シャッフル / レイアウト切替（グリッド⇔モザイク）
//
//  チップ・カラースウォッチは SearchView の FilterChip / ColorSelectionButton を再利用する。
//

import SwiftUI

struct GalleryExploreHeader: View {
    @ObservedObject var viewModel: GalleryViewModel

    /// 色で探すプリセット（検索タブと共有の定数を参照＝提示色のズレを防ぐ）
    private var colorPresets: [(name: String, hex: String)] { ColorSelectionButton.presets }

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
            // 新着 / 人気 / 週間 / 月間（絞り込み中は新着以外を無効化＝新着固定）
            // ⚠️ チップが 4 つになり、幅 375pt の端末（iPhone SE / mini）では右のボタンと合わせて
            //    はみ出すため、チップだけ横スクロールにして「続きがある」手がかりを重ねる。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    sortChip(title: "新着", order: .newest)
                    sortChip(title: "人気", order: .popular)
                    sortChip(title: RankingPeriod.weekly.displayName, order: .weeklyRanking)
                    sortChip(title: RankingPeriod.monthly.displayName, order: .monthlyRanking)

                    // 内容の右端を計測して「まだ続きがあるか」を判定するための幅0マーカー
                    HorizontalScrollEndMarker()
                }
                .padding(.vertical, 2)
            }
            // 空色背景に黒フェードは浮くので、選択色（青）の下地＋白矢印にする
            .horizontalScrollEdgeFade(
                fadeColor: DesignTokens.Colors.selectionAccent,
                chevronColor: .white
            )

            // シャッフル（ランキングは順位そのものが内容なので無効化）
            iconToggleButton(
                systemName: "shuffle",
                isOn: viewModel.isShuffled && !viewModel.isRankingMode,
                accessibilityLabel: "シャッフル"
            ) {
                Task { await viewModel.toggleShuffle() }
            }
            .opacity(viewModel.isRankingMode ? 0.35 : 1.0)
            .disabled(viewModel.isRankingMode)

            // レイアウト切替（グリッド⇔モザイク）
            // ランキングは専用レイアウト（表彰台＋縦リスト）で表示し切替が効かないため、シャッフルと同じく無効化する
            iconToggleButton(
                systemName: viewModel.layoutMode == .mosaic ? "rectangle.grid.1x2" : "square.grid.2x2",
                isOn: viewModel.layoutMode == .mosaic && !viewModel.isRankingMode,
                accessibilityLabel: "表示レイアウト切替"
            ) {
                viewModel.toggleLayoutMode()
            }
            .opacity(viewModel.isRankingMode ? 0.35 : 1.0)
            .disabled(viewModel.isRankingMode)
        }
    }

    /// 並び替えチップ（新着 / 人気 / 週間 / 月間）
    private func sortChip(title: String, order: GallerySortOrder) -> some View {
        // 新着以外は絞り込み中は選択不可（新着固定）
        let isDisabled = (order != .newest) && viewModel.hasActiveFilter
        let isSelected = !viewModel.isColorMode
            && viewModel.effectiveSortOrder == order
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
