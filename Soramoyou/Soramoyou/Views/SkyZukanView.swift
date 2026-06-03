//
//  SkyZukanView.swift
//  Soramoyou
//
//  空コレクション図鑑（柱2）。「空を集める」を可視化する。
//  - サマリー（集めた枚数・各軸の達成数）
//  - 空タイプ × 時間帯 のマトリクス（未取得セルはシルエット）
//  - 達成バッジ
//

import SwiftUI

struct SkyZukanView: View {
    let userId: String

    @StateObject private var viewModel = SkyCollectionViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                backgroundGradient.ignoresSafeArea()
                content
            }
            .navigationTitle("空図鑑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") { dismiss() }
                        .foregroundColor(DesignTokens.Colors.textPrimary)
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .task { await viewModel.load(userId: userId) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView()
                .tint(.white)
        } else {
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.lg) {
                    summarySection
                    matrixSection
                    badgesSection
                }
                .padding(DesignTokens.Spacing.screenMargin)
            }
        }
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.16, blue: 0.30),
                Color(red: 0.05, green: 0.07, blue: 0.14)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
            .fill(Color.white.opacity(0.06))
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text("集めた空 \(viewModel.state.totalPosts) 枚")
                .font(.title3.weight(.bold))
                .foregroundColor(DesignTokens.Colors.textPrimary)

            HStack(spacing: DesignTokens.Spacing.sm) {
                summaryStat(title: "空タイプ", current: viewModel.state.skyTypes.count, total: SkyType.allCases.count)
                summaryStat(title: "時間帯", current: viewModel.state.timeOfDays.count, total: TimeOfDay.allCases.count)
                summaryStat(title: "季節", current: viewModel.state.seasons.count, total: Season.allCases.count)
                summaryStat(title: "都道府県", current: viewModel.state.prefectures.count, total: JapanPrefecture.allNames.count)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.md)
        .background(cardBackground)
    }

    private func summaryStat(title: String, current: Int, total: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(current)/\(total)")
                .font(.subheadline.weight(.bold))
                .foregroundColor(DesignTokens.Colors.textPrimary)
            Text(title)
                .font(.caption2)
                .foregroundColor(DesignTokens.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Matrix（空タイプ × 時間帯）

    @ViewBuilder
    private var matrixSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("空 × 時間帯")
                .font(.headline)
                .foregroundColor(DesignTokens.Colors.textPrimary)

            // ヘッダー行（時間帯）
            HStack(spacing: 6) {
                Color.clear.frame(width: 56, height: 1)
                ForEach(TimeOfDay.allCases, id: \.self) { time in
                    VStack(spacing: 2) {
                        Image(systemName: time.iconName).font(.caption)
                        Text(time.displayName).font(.caption2)
                    }
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                }
            }

            // 各空タイプの行
            ForEach(SkyType.allCases, id: \.self) { sky in
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: sky.iconName).font(.caption)
                        Text(sky.displayName).font(.caption2)
                    }
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .frame(width: 56, alignment: .leading)

                    ForEach(TimeOfDay.allCases, id: \.self) { time in
                        matrixCell(sky: sky, time: time)
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(cardBackground)
    }

    private func matrixCell(sky: SkyType, time: TimeOfDay) -> some View {
        let collected = viewModel.state.isCollected(skyType: sky, timeOfDay: time)
        return RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .fill(collected ? DesignTokens.Colors.skyBlue : Color.white.opacity(0.06))
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .overlay(
                Image(systemName: sky.iconName)
                    .font(.caption)
                    .foregroundColor(collected ? .white : Color.white.opacity(0.18))
            )
            .accessibilityLabel("\(sky.displayName)・\(time.displayName) \(collected ? "収集済み" : "未収集")")
    }

    // MARK: - Badges

    @ViewBuilder
    private var badgesSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("バッジ")
                .font(.headline)
                .foregroundColor(DesignTokens.Colors.textPrimary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 88), spacing: DesignTokens.Spacing.sm)],
                spacing: DesignTokens.Spacing.md
            ) {
                ForEach(SkyBadge.all) { badge in
                    SkyBadgeView(badge: badge, state: viewModel.state)
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(cardBackground)
    }
}
