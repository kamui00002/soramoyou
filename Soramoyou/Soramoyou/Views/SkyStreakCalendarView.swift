//
//  SkyStreakCalendarView.swift
//  Soramoyou
//
//  ストリーク（連続投稿日数）の月カレンダー。投稿があった日に太陽マークを表示する。
//  図鑑（SkyZukanView）のストリークセクションから使う。ダーク背景前提の配色。
//
//  月グリッドのレイアウト・日付計算ロジックは MonthCalendarGridView に共通化されている
//  （空カレンダー日記 SkyCalendarDiaryView と共有・2箇所に重複実装しない）⭐️。
//  本ビューは「投稿日に太陽マークを付ける」日セルの中身だけを差し込む薄いラッパー。
//

import SwiftUI

/// 投稿日に印が付く月カレンダー（前後の月へ移動可能、未来の月へは進めない）。
struct SkyStreakCalendarView: View {
    /// ストリーク状態（postedDays をカレンダーの印に使う）
    let streak: SkyStreakState

    var body: some View {
        MonthCalendarGridView { day, monthStart, calendar in
            dayCell(day: day, monthStart: monthStart, calendar: calendar)
        }
    }

    @ViewBuilder
    private func dayCell(day: Int, monthStart: Date, calendar: Calendar) -> some View {
        let posted = isPosted(day: day, monthStart: monthStart, calendar: calendar)
        let today = isToday(day: day, monthStart: monthStart, calendar: calendar)

        ZStack {
            if posted {
                // 投稿があった日: 太陽の塗りつぶし
                Circle()
                    .fill(DesignTokens.Colors.sunsetOrange.opacity(0.85))
            }
            if today {
                // 今日: 輪郭リング（投稿の有無と独立して重なる）
                Circle()
                    .stroke(DesignTokens.Colors.textPrimary, lineWidth: 1.5)
            }
            Text("\(day)")
                .font(.caption2.weight(posted ? .bold : .regular))
                .foregroundColor(
                    posted ? .white : DesignTokens.Colors.textSecondary
                )
        }
        .frame(height: 30)
        // 「今日」は視覚的に輪郭リングで示すため、VoiceOver にも明示する（色/形だけに頼らない）
        .accessibilityLabel("\(day)日\(today ? "、今日" : "")\(posted ? "、投稿あり" : "")")
    }

    /// 表示中の月の day 日に投稿があるか
    private func isPosted(day: Int, monthStart: Date, calendar: Calendar) -> Bool {
        let comps = calendar.dateComponents([.year, .month], from: monthStart)
        guard let year = comps.year, let month = comps.month else { return false }
        return streak.postedDays.contains(SkyStreakDay(year: year, month: month, day: day))
    }

    /// 表示中の月の day 日が今日か
    private func isToday(day: Int, monthStart: Date, calendar: Calendar) -> Bool {
        let todayComps = calendar.dateComponents([.year, .month, .day], from: Date())
        let monthComps = calendar.dateComponents([.year, .month], from: monthStart)
        return todayComps.year == monthComps.year
            && todayComps.month == monthComps.month
            && todayComps.day == day
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        SkyStreakCalendarView(
            streak: SkyStreakState(
                currentStreak: 3,
                longestStreak: 5,
                didPostToday: true,
                postedDays: [
                    SkyStreakDay(year: 2026, month: 6, day: 1),
                    SkyStreakDay(year: 2026, month: 6, day: 2),
                    SkyStreakDay(year: 2026, month: 6, day: 5),
                    SkyStreakDay(year: 2026, month: 6, day: 6),
                    SkyStreakDay(year: 2026, month: 6, day: 7)
                ]
            )
        )
        .padding()
    }
}
