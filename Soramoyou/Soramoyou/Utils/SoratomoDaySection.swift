//
//  SoratomoDaySection.swift
//  Soramoyou
//
//  そらとものタイムラインの日付の見出し ⭐️
//  「今日」「昨日」「M月d日」「yyyy年M月d日」を端末のタイムゾーンで決める純関数（tasks 10.3・要件 8.4・8.5）。
//

import Foundation

/// タイムラインの日付の見出し
enum SoratomoDaySection {
    /// 見出しを決めるカレンダー（グレゴリオ暦・端末のタイムゾーン）
    ///
    /// `Calendar.current` をそのまま使わないのは、端末の設定で和暦などを選んでいると
    /// 年が「8」（令和8年）のように出て、要件 8.5 の例（2025年12月31日）の形にならないため。
    /// 日付の区切りは端末のタイムゾーンで決める（要件 8.4）ので、タイムゾーンだけ端末に合わせる。
    /// 呼ぶたびに作り直すのは、旅行などでタイムゾーンが変わったときに追従するため。
    static var deviceCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar
    }

    /// 投稿日時から日付の見出しを作る
    ///
    /// - 今日 → 「今日」、昨日 → 「昨日」
    /// - それ以外で今年 → 「M月d日」（例: 10月1日）
    /// - それ以外の年 → 「yyyy年M月d日」（例: 2025年12月31日）
    ///
    /// 「昨日」は年の判定より先に見る（1月1日に見た12月31日の投稿は「昨日」）。
    /// - Parameters:
    ///   - date: 投稿日時
    ///   - now: 現在時刻（テストで差し替える）
    ///   - calendar: 日付の区切りに使うカレンダー（テストでタイムゾーンを固定する）
    /// - Returns: 見出しの文字列
    static func title(for date: Date, now: Date = Date(), calendar: Calendar = deviceCalendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "今日"
        }
        // 「昨日」は now の 1 日前と同じ日か（夏時間のある地域でも日付で比べる）
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "昨日"
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        // 日付の書式は DateFormatter を使わずに組み立てる（端末の言語・地域の設定で形が変わらないように）
        if parts.year == calendar.component(.year, from: now) {
            return "\(month)月\(day)日"
        }
        return "\(parts.year ?? 0)年\(month)月\(day)日"
    }

    /// 投稿日時をその日の 0 時（端末のタイムゾーン）にそろえる
    ///
    /// タイムライン（tasks 13.5）で投稿を日付ごとに区切るときの鍵に使う。
    /// - Parameters:
    ///   - date: 投稿日時
    ///   - calendar: 日付の区切りに使うカレンダー
    /// - Returns: その日の 0 時
    static func startOfDay(for date: Date, calendar: Calendar = deviceCalendar) -> Date {
        calendar.startOfDay(for: date)
    }
}
