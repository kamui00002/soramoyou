//
//  SkyZukanView.swift
//  Soramoyou
//
//  空コレクション図鑑（柱2）。「空を集める」を可視化する。
//  - 使い方ガイド
//  - サマリー（集めた枚数・各軸の達成数）
//  - 空タイプ × 時間帯 のマトリクス（未取得セルはうすい枠）
//  - 達成バッジ
//
//  配色はアプリ本体（ProfileView）と同じ空グラデーション＋ガラスカードに揃える。
//

import SwiftUI

struct SkyZukanView: View {
    let userId: String

    @StateObject private var viewModel = SkyCollectionViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                // アプリ本体（ProfileView）と同じ空のグラデーション背景
                skyGradient.ignoresSafeArea()
                content
            }
            .navigationTitle("空図鑑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .alert("エラー", isPresented: Binding(errorMessage: $viewModel.errorMessage)) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .task { await viewModel.load(userId: userId) }
    }

    // MARK: - 背景

    private var skyGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.68, green: 0.85, blue: 0.90),
                Color(red: 0.53, green: 0.81, blue: 0.98),
                Color(red: 0.39, green: 0.58, blue: 0.93)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
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
                    introSection
                    if viewModel.state.totalPosts == 0 {
                        emptySection
                    } else {
                        summarySection
                        streakSection
                        matrixSection
                        badgesSection
                    }
                }
                .padding(DesignTokens.Spacing.screenMargin)
            }
        }
    }

    /// ガラスカードの共通スタイル（アプリ本体と同じ .ultraThinMaterial）
    @ViewBuilder
    private func glassCard<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(DesignTokens.Spacing.md)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .stroke(DesignTokens.Colors.glassBorderSecondary, lineWidth: 1)
            )
    }

    // MARK: - 使い方ガイド

    @ViewBuilder
    private var introSection: some View {
        glassCard {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundColor(DesignTokens.Colors.sunsetOrange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("空を集めよう")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(DesignTokens.Colors.textPrimary)
                    Text("投稿した空が、種類・時間帯・季節・地域ごとに自動で集まります。いろいろな空を撮って図鑑を完成させ、バッジを獲得しましょう。")
                        .font(.caption)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 空状態

    @ViewBuilder
    private var emptySection: some View {
        glassCard {
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "cloud.sun")
                    .font(.largeTitle)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                Text("まだ空を集めていません")
                    .font(.headline)
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                Text("空を投稿すると、種類・時間帯・季節・地域ごとにここへ集まります。")
                    .font(.caption)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - サマリー

    @ViewBuilder
    private var summarySection: some View {
        glassCard {
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
        }
    }

    private func summaryStat(title: String, current: Int, total: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(current)/\(total)")
                .font(.subheadline.weight(.bold))
                .foregroundColor(DesignTokens.Colors.textPrimary)
            Text(title)
                .font(.caption2)
                .foregroundColor(DesignTokens.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - ストリーク（連続投稿日数）

    @ViewBuilder
    private var streakSection: some View {
        glassCard {
            VStack(spacing: DesignTokens.Spacing.sm) {
                // 見出し: 🔥◯日連続（継続中の有無で文言を出し分け）
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "flame.fill")
                        .font(.title2)
                        .foregroundColor(DesignTokens.Colors.sunsetOrange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(streakTitle)
                            .font(.title3.weight(.bold))
                            .foregroundColor(DesignTokens.Colors.textPrimary)
                        Text(streakSubtitle)
                            .font(.caption)
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }

                    Spacer()

                    if viewModel.streak.longestStreak > 0 {
                        VStack(spacing: 2) {
                            Text("\(viewModel.streak.longestStreak)日")
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(DesignTokens.Colors.textPrimary)
                            Text("最長")
                                .font(.caption2)
                                .foregroundColor(DesignTokens.Colors.textSecondary)
                        }
                    }
                }

                Divider()
                    .overlay(DesignTokens.Colors.glassBorderSecondary)

                SkyStreakCalendarView(streak: viewModel.streak)
            }
        }
    }

    /// ストリーク見出しの文言
    private var streakTitle: String {
        if viewModel.streak.currentStreak > 0 {
            return "\(viewModel.streak.currentStreak)日連続"
        }
        return "空の記録をはじめよう"
    }

    /// ストリーク見出しの補助文言
    private var streakSubtitle: String {
        if viewModel.streak.currentStreak == 0 {
            return "投稿した日がカレンダーに刻まれます"
        }
        return viewModel.streak.didPostToday
            ? "今日も投稿済み。いい空を集めています"
            : "今日投稿するとストリークが伸びます"
    }

    // MARK: - Matrix（空タイプ × 時間帯）

    @ViewBuilder
    private var matrixSection: some View {
        glassCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("空 × 時間帯")
                    .font(.headline)
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                Text("色付き＝収集済み ／ うすい枠＝これから集める")
                    .font(.caption2)
                    .foregroundColor(DesignTokens.Colors.textSecondary)

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
                        .foregroundColor(DesignTokens.Colors.textPrimary)
                        .frame(width: 56, alignment: .leading)

                        ForEach(TimeOfDay.allCases, id: \.self) { time in
                            matrixCell(sky: sky, time: time)
                        }
                    }
                }
            }
        }
    }

    private func matrixCell(sky: SkyType, time: TimeOfDay) -> some View {
        let collected = viewModel.state.isCollected(skyType: sky, timeOfDay: time)
        return RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .fill(collected ? Color.white.opacity(0.92) : Color.white.opacity(0.12))
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .overlay(
                Image(systemName: sky.iconName)
                    .font(.caption)
                    .foregroundColor(collected ? DesignTokens.Colors.skyBlue : Color.white.opacity(0.45))
            )
            .accessibilityLabel("\(sky.displayName)・\(time.displayName) \(collected ? "収集済み" : "未収集")")
    }

    // MARK: - Badges

    @ViewBuilder
    private var badgesSection: some View {
        glassCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("バッジ")
                    .font(.headline)
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                Text("条件を満たすと解放されます")
                    .font(.caption2)
                    .foregroundColor(DesignTokens.Colors.textSecondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 88), spacing: DesignTokens.Spacing.sm)],
                    spacing: DesignTokens.Spacing.md
                ) {
                    ForEach(SkyBadge.all) { badge in
                        SkyBadgeView(badge: badge, state: viewModel.state)
                    }
                }
            }
        }
    }
}
