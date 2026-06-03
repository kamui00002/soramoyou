//
//  SkyBadgeView.swift
//  Soramoyou
//
//  空コレクション図鑑（柱2）のバッジ 1 個の表示。
//  解放済み=点灯（アクセント）/ 未解放=シルエット＋進捗。
//

import SwiftUI

struct SkyBadgeView: View {
    let badge: SkyBadge
    let state: CollectionState

    private var unlocked: Bool { badge.isUnlocked(state) }
    private var progress: BadgeProgress { badge.progress(state) }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            ZStack {
                Circle()
                    .fill(unlocked
                          ? DesignTokens.Colors.sunsetOrange
                          : Color.white.opacity(0.10))
                    .frame(width: 60, height: 60)

                Image(systemName: badge.iconName)
                    .font(.title2)
                    .foregroundColor(unlocked ? .white : Color.white.opacity(0.30))
            }

            Text(badge.title)
                .font(.caption2.weight(.semibold))
                .foregroundColor(unlocked ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 28, alignment: .top)

            // 未解放かつ複数段階のものは進捗を表示
            if !unlocked && progress.total > 1 {
                Text("\(progress.current)/\(progress.total)")
                    .font(.caption2)
                    .foregroundColor(DesignTokens.Colors.textTertiary)
            }
        }
        .frame(width: 88)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(badge.title)。\(unlocked ? "達成済み" : "未達成 \(progress.current)/\(progress.total)")")
    }
}
