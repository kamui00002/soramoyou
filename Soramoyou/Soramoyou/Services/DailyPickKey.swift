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
    static func keys(now _: Date) -> (today: String, fallback: String) {
        // 契約の仮の実装（A1 が置き換える）
        (today: "", fallback: "")
    }
}
