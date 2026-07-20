//
//  SkyStreakCalculator.swift
//  Soramoyou
//
//  ストリーク（連続投稿日数）の計算ロジック（純関数・Firestore/UI 非依存）。
//
//  「1日」は**投稿日（createdAt）**のローカル暦日で数える。撮影日（capturedAt）ではない。
//  - ストリークは「毎日アプリで投稿する習慣」の記録なので、ユーザーの行動日が基準（製品判断・確定済み）。
//  - 撮影日基準だと過去写真の一括アップロードで遡ってストリークが成立してしまう。
//  - 図鑑/季節が撮影日優先なのは「空そのもの」の記録だから（軸が違う）。
//

import Foundation

/// 暦日キー（年/月/日）。カレンダー描画の「投稿があった日」照合に使う値型。
struct SkyStreakDay: Hashable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Date から生成（calendar のタイムゾーンで暦日に丸める）
    init?(date: Date, calendar: Calendar) {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return nil }
        self.init(year: year, month: month, day: day)
    }
}

/// ストリークの計算結果。
struct SkyStreakState: Equatable {
    /// 継続中の連続日数。
    /// 今日まだ投稿していなくても、昨日まで連続していれば「継続中」として数える
    /// （今日が終わるまではストリークは切れない、一般的なストリーク UX に準拠）。
    let currentStreak: Int
    /// 過去最長の連続日数（バッジ判定にはこちらを使う = 一度の達成は失われない）
    let longestStreak: Int
    /// 今日すでに投稿したか（「今日も撮ろう」等の文言出し分け用）
    let didPostToday: Bool
    /// 投稿があった暦日の集合（カレンダー描画用）
    let postedDays: Set<SkyStreakDay>

    static let empty = SkyStreakState(
        currentStreak: 0, longestStreak: 0, didPostToday: false, postedDays: []
    )
}

/// ストリーク計算の純関数。`today` / `calendar` を注入してテスト可能にする。
enum SkyStreakCalculator {

    /// 投稿配列からストリークを計算する。
    /// - Parameters:
    ///   - posts: ユーザー自身の投稿（順不同でよい）
    ///   - today: 基準日（テストで固定可能）
    ///   - calendar: 暦日の丸めに使うカレンダー。`today` の判定と投稿日の丸めに
    ///     **同じインスタンス**を使うこと（タイムゾーン差の off-by-one 防止）。
    ///     既定はグレゴリオ暦（和暦等の端末設定で `postedDays` の年がズレ、カレンダー描画と
    ///     一致しなくなるのを防ぐ。Calendar+Soramoyou.swift 参照）。
    static func calculate(
        posts: [Post],
        today: Date,
        calendar: Calendar = .soramoyouGregorian
    ) -> SkyStreakState {
        // 投稿日（createdAt）を暦日の先頭（startOfDay）に丸めてユニーク化
        let dayStarts = Set(posts.map { calendar.startOfDay(for: $0.createdAt) })
        guard !dayStarts.isEmpty else { return .empty }

        let todayStart = calendar.startOfDay(for: today)
        let didPostToday = dayStarts.contains(todayStart)

        // 現在のストリーク: 終端（今日投稿済みなら今日、未投稿なら昨日）から1日ずつ遡る
        var currentStreak = 0
        if let anchor = currentStreakAnchor(
            todayStart: todayStart, dayStarts: dayStarts, calendar: calendar
        ) {
            var cursor = anchor
            while dayStarts.contains(cursor) {
                currentStreak += 1
                guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previous
            }
        }

        // 最長ストリーク: ソート済みの暦日を走査して連続の最大長を求める
        var longestStreak = 0
        var runLength = 0
        var previousDay: Date?
        for day in dayStarts.sorted() {
            if let previous = previousDay,
               let expected = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(day, inSameDayAs: expected) {
                runLength += 1
            } else {
                runLength = 1
            }
            longestStreak = max(longestStreak, runLength)
            previousDay = day
        }

        let postedDays = Set(dayStarts.compactMap { SkyStreakDay(date: $0, calendar: calendar) })

        return SkyStreakState(
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            didPostToday: didPostToday,
            postedDays: postedDays
        )
    }

    /// 現在ストリークの終端となる日を返す。
    /// 今日投稿済み → 今日 / 今日未投稿で昨日投稿済み → 昨日（継続中扱い）/ どちらも無し → nil（途切れ）
    private static func currentStreakAnchor(
        todayStart: Date,
        dayStarts: Set<Date>,
        calendar: Calendar
    ) -> Date? {
        if dayStarts.contains(todayStart) {
            return todayStart
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart),
           dayStarts.contains(yesterday) {
            return yesterday
        }
        return nil
    }
}
