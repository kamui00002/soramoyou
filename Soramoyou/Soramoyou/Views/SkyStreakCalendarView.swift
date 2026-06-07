//
//  SkyStreakCalendarView.swift
//  Soramoyou
//
//  ストリーク（連続投稿日数）の月カレンダー。投稿があった日に太陽マークを表示する。
//  図鑑（SkyZukanView）のストリークセクションから使う。ダーク背景前提の配色。
//

import SwiftUI

/// 投稿日に印が付く月カレンダー（前後の月へ移動可能、未来の月へは進めない）。
struct SkyStreakCalendarView: View {
    /// ストリーク状態（postedDays をカレンダーの印に使う）
    let streak: SkyStreakState

    /// 表示中の月（その月に含まれる任意の日付）
    @State private var displayedMonth = Date()

    /// カレンダー計算用。曜日ヘッダーを「日〜土」固定で描くため、firstWeekday も
    /// 日曜（=1）に固定する。端末ロケールが月曜始まり等の場合に Calendar.current の
    /// firstWeekday をそのまま使うと、ヘッダー（日曜始まり固定）と先頭空白セルの
    /// 計算（firstWeekday 依存）がずれて日付が誤った曜日列に並ぶため。
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1 // 日曜始まり（weekdaySymbols と一致させる）
        return calendar
    }()
    /// 曜日ヘッダー（日曜始まり固定。上の calendar.firstWeekday=1 と対応）
    private let weekdaySymbols = ["日", "月", "火", "水", "木", "金", "土"]

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            monthHeader
            weekdayHeader
            dayGrid
        }
    }

    // MARK: - 月ヘッダー（前後ナビ付き）

    private var monthHeader: some View {
        HStack {
            Button {
                moveMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("前の月")

            Spacer()

            Text(monthTitle)
                .font(.subheadline.weight(.bold))
                .foregroundColor(DesignTokens.Colors.textPrimary)

            Spacer()

            Button {
                moveMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(
                        canMoveToNextMonth
                            ? DesignTokens.Colors.textPrimary
                            : DesignTokens.Colors.textTertiary
                    )
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!canMoveToNextMonth)
            .accessibilityLabel("次の月")
        }
    }

    // MARK: - 曜日ヘッダー

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 日グリッド

    private var dayGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: 6) {
            // 月初までの空白セル
            ForEach(0..<leadingBlankCount, id: \.self) { _ in
                Color.clear.frame(height: 30)
            }
            // 各日のセル
            ForEach(1...daysInMonth, id: \.self) { day in
                dayCell(day)
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Int) -> some View {
        let posted = isPosted(day: day)
        let today = isToday(day: day)

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

    // MARK: - カレンダー計算

    /// 表示中の月の1日（month の基準点）
    private var monthStart: Date {
        let comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        return calendar.date(from: comps) ?? displayedMonth
    }

    /// 表示中の月の日数
    private var daysInMonth: Int {
        calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
    }

    /// 月初の曜日に合わせた先頭の空白セル数
    private var leadingBlankCount: Int {
        let weekday = calendar.component(.weekday, from: monthStart)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    /// 「2026年6月」形式のタイトル
    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: monthStart)
    }

    /// 現在の月より先へは進めない（未来のカレンダーに意味がないため）
    private var canMoveToNextMonth: Bool {
        guard let next = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return false }
        return next <= Date()
    }

    private func moveMonth(by value: Int) {
        guard let moved = calendar.date(byAdding: .month, value: value, to: monthStart) else { return }
        displayedMonth = moved
    }

    /// 表示中の月の day 日に投稿があるか
    private func isPosted(day: Int) -> Bool {
        let comps = calendar.dateComponents([.year, .month], from: monthStart)
        guard let year = comps.year, let month = comps.month else { return false }
        return streak.postedDays.contains(SkyStreakDay(year: year, month: month, day: day))
    }

    /// 表示中の月の day 日が今日か
    private func isToday(day: Int) -> Bool {
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
