//
//  MonthCalendarGridView.swift
//  Soramoyou
//
//  月表示カレンダーの共通シェル（月ヘッダー・曜日ヘッダー・日グリッド・月ナビ・日付計算）。
//  SkyStreakCalendarView（投稿マーク表示・PR #37）と SkyCalendarDiaryView（サムネイル表示）の
//  両方から使う。日セルの中身だけが異なるため、グリッドレイアウト・日付計算ロジックを
//  1箇所に保つ目的でここに切り出した ⭐️（もとは SkyStreakCalendarView 内に直書きされていた）。
//

import SwiftUI

/// 月表示カレンダーの共通基盤。日セルの中身は呼び出し側が `dayCell` で差し込む。
/// 前後の月へ移動可能（未来の月へは進めない）。
struct MonthCalendarGridView<DayCell: View>: View {
    /// 表示中の月（その月に含まれる任意の日付）
    @State private var displayedMonth: Date

    /// 表示中の月が変わるたびに呼ばれる（初回表示時にも1回呼ばれる）。
    /// 呼び出し側が「いま表示中の月」を把握するためのフック（例: 月が空かどうかの判定）。
    private let onMonthChange: ((Date) -> Void)?

    /// 各日セルの高さ（先頭の空白セルも同じ高さに揃える）
    private let cellHeight: CGFloat

    /// 日セルの中身。(day, monthStart, calendar) を渡すので、呼び出し側は
    /// 同じ calendar インスタンスで年/月を再計算でき、タイムゾーン差の off-by-one を防げる。
    private let dayCell: (_ day: Int, _ monthStart: Date, _ calendar: Calendar) -> DayCell

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

    init(
        initialMonth: Date = Date(),
        cellHeight: CGFloat = 30,
        onMonthChange: ((Date) -> Void)? = nil,
        @ViewBuilder dayCell: @escaping (_ day: Int, _ monthStart: Date, _ calendar: Calendar) -> DayCell
    ) {
        _displayedMonth = State(initialValue: initialMonth)
        self.cellHeight = cellHeight
        self.onMonthChange = onMonthChange
        self.dayCell = dayCell
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            monthHeader
            weekdayHeader
            dayGrid
        }
        .onAppear { onMonthChange?(monthStart) }
        .onChange(of: displayedMonth) { newValue in
            let comps = calendar.dateComponents([.year, .month], from: newValue)
            onMonthChange?(calendar.date(from: comps) ?? newValue)
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
                Color.clear.frame(height: cellHeight)
            }
            // 各日のセル
            ForEach(1...daysInMonth, id: \.self) { day in
                dayCell(day, monthStart, calendar)
            }
        }
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
}
