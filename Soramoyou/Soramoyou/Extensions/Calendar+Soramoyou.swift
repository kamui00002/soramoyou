// ⭐️ Calendar+Soramoyou.swift
// 空カレンダー日記・ストリークの「暦日キー」生成に使う共通カレンダー・判定処理。
//
//  背景（バグ修正 2026-07-20）: 端末のカレンダー設定が和暦（Calendar(identifier: .japanese)）の
//  ユーザーは、`Calendar.current` の年が西暦とズレる（例: 令和8年 → year=8）。
//  暦日キー（SkyStreakDay）の生成元（グルーピング・グリッド描画・空月判定・ストリーク集計）が
//  それぞれ別々に `.current` / `Calendar(identifier: .gregorian)` を使い分けていたため、
//  和暦ユーザーだけキーが一致せずカレンダーの全セルが空白になっていた。
//  → 暦日キーに関わる全経路が「同一のグレゴリオ暦インスタンス」を参照する単一ソースをここに置く。
//

import Foundation

extension Calendar {
    /// 暦日キー（年/月/日）生成専用のグレゴリオ暦。
    /// タイムゾーンは端末ローカルのまま（`Calendar(identifier:)` の既定値を使用）。
    /// 暦日キーに関わる箇所（CalendarDiaryService.groupByDay / MonthCalendarGridView の
    /// 日グリッド計算 / SkyCalendarDiaryView.isDisplayedMonthEmpty / SkyStreakCalculator.calculate）は
    /// すべてこのインスタンスを使うこと。
    static var soramoyouGregorian: Calendar {
        Calendar(identifier: .gregorian)
    }

    /// 表示中の月の `day` 日が「今日」かどうかを判定する。
    /// SkyCalendarDiaryView と SkyStreakCalendarView の日セルが共通で使う判定ロジック
    /// （もとは両ファイルに同一実装が重複していた）。
    /// - Parameters:
    ///   - day: 判定対象の日（1〜31）
    ///   - monthStart: 表示中の月の基準日（月の1日）
    ///   - now: 「今日」の基準日時（テスト用に注入可能。既定は現在時刻）
    func isSameDayAsToday(day: Int, monthStart: Date, now: Date = Date()) -> Bool {
        let todayComps = dateComponents([.year, .month, .day], from: now)
        let monthComps = dateComponents([.year, .month], from: monthStart)
        return todayComps.year == monthComps.year
            && todayComps.month == monthComps.month
            && todayComps.day == day
    }
}
