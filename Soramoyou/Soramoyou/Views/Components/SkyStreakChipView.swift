//
//  SkyStreakChipView.swift
//  Soramoyou
//
//  ホーム上部に出す「🔥◯日連続」の小さなチップ。
//  ストリークが継続中（currentStreak > 0）の時だけ表示し、タップで図鑑（詳細）へ誘導する。
//  習慣化のために「毎日目に入る」ことが目的の軽量表示。
//

import SwiftUI

/// ストリークの連続日数チップ（継続中のみ表示）。
struct SkyStreakChipView: View {
    /// ストリーク状態（OnThisDayViewModel の取得結果を共有）
    let streak: SkyStreakState
    /// タップ時のアクション（図鑑を開く）
    let action: () -> Void

    var body: some View {
        if streak.currentStreak > 0 {
            HStack {
                Button(action: action) {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .font(.caption)
                            .foregroundColor(DesignTokens.Colors.sunsetOrange)

                        Text("\(streak.currentStreak)日連続")
                            .font(.caption.weight(.bold))
                            .foregroundColor(DesignTokens.Colors.textPrimary)

                        // 今日まだ投稿していなければ、ひと押しの文言を添える
                        if !streak.didPostToday {
                            Text("今日も撮ろう")
                                .font(.caption2)
                                .foregroundColor(DesignTokens.Colors.textSecondary)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(DesignTokens.Colors.glassBorderSecondary, lineWidth: 1)
                    )
                }
                .accessibilityLabel("\(streak.currentStreak)日連続で投稿中。タップで空図鑑を開く")

                Spacer(minLength: 0)
            }
        }
    }
}

#Preview {
    ZStack {
        Color.blue.ignoresSafeArea()
        VStack(spacing: 16) {
            // 今日投稿済み
            SkyStreakChipView(
                streak: SkyStreakState(
                    currentStreak: 7, longestStreak: 7, didPostToday: true, postedDays: []
                ),
                action: {}
            )
            // 今日まだ（継続中）
            SkyStreakChipView(
                streak: SkyStreakState(
                    currentStreak: 3, longestStreak: 5, didPostToday: false, postedDays: []
                ),
                action: {}
            )
        }
        .padding()
    }
}
