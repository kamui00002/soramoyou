//
//  DailyPickKey.swift
//  Soramoyou
//
//  「今日のおすすめのそらもよう」の日付の鍵（dailyPicks/{yyyy-MM-dd} の文書 ID）を作る ⭐️
//
//  ⚠️ サーバー（functions/dailyPickCore.js の dateKeyForInstant）と同じ決め方にすること。
//     日本時間で「今 − 7 時間」の日付＝6:59:59 までは前日、7:00 から当日。
//     端末のタイムゾーン・暦・言語の設定に左右されないよう、Asia/Tokyo・グレゴリオ暦・en_US_POSIX に固定する。
//  ⚠️ 「私のおすすめの空」（publicProfiles.recommendedPostIds）とは別物。名前は dailyPick 系で統一する。
//

import Foundation

enum DailyPickKey {
    /// 日本時間で日付が切り替わる時刻（7 時。サーバーの DAY_SWITCH_HOUR_JST と同じ値）
    static let switchHourJST = 7

    /// 今日の鍵と前日の鍵を返す
    /// - Parameter now: 基準の瞬間（テストでは固定の時刻を渡す）
    /// - Returns: today＝今日のおすすめの鍵、fallback＝その前日の鍵（どちらも yyyy-MM-dd）
    static func keys(now: Date) -> (today: String, fallback: String) {
        // 「今 − 7 時間」の瞬間を作り、その瞬間の日本時間の日付を鍵にする
        // （サーバーの「UTC に (9 − 7) 時間足して日付部分を取る」と同じ結果）
        let shifted = now.addingTimeInterval(-TimeInterval(switchHourJST) * 3600)
        let today = formatKey(shifted)
        // fallback は鍵の日付の前日（日本は夏時間が無いので 24 時間引きと同じ）
        let previous = shifted.addingTimeInterval(-24 * 3600)
        return (today: today, fallback: formatKey(previous))
    }

    /// 日本時間のカレンダー（グレゴリオ暦・Asia/Tokyo 固定）
    /// - Note: Calendar は値型で、ここでは読み取りだけなのでどのスレッドから呼んでも安全。
    ///   DateFormatter は共有せず、年月日の数値から自前で yyyy-MM-dd を組み立てる
    ///   （端末のロケール・暦の設定の影響を受けず、スレッドの心配も要らない）。
    private static let tokyoCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? TimeZone(secondsFromGMT: 9 * 3600)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// 瞬間の「日本時間での日付」を yyyy-MM-dd にする
    private static func formatKey(_ date: Date) -> String {
        let parts = tokyoCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
