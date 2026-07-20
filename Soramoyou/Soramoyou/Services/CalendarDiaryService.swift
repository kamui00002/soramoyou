//
//  CalendarDiaryService.swift
//  Soramoyou
//
//  空カレンダー日記: 投稿を暦日ごとにグルーピングする純関数（Firestore/UI 非依存）。
//
//  基準日は capturedAt ?? createdAt（OnThisDayService と同じ規約）。
//  - カレンダー日記は「空そのもの」の記録を日ごとに振り返る機能なので、撮影日基準が軸に合う
//    （ストリークが投稿日=行動日基準なのとは目的が異なる。SkyStreakCalculator.swift 冒頭コメント参照）。
//
//  日付キーには SkyStreakCalculator.swift の SkyStreakDay（年/月/日の値型）をそのまま再利用する。
//  カレンダー機能内で「年/月/日キー」を重複定義しないための意図的な選択 ⭐️。
//

import Foundation

/// 空カレンダー日記の集計ロジック（純関数・Firestore/UI 非依存）。
enum CalendarDiaryService {

    /// 投稿配列を暦日（年/月/日）ごとにグルーピングする。
    /// 同じ日に複数投稿がある場合は、新しい投稿から順（createdAt 降順）に並べる。
    /// - Parameters:
    ///   - posts: ユーザー自身の投稿（順不同でよい）。
    ///   - calendar: 暦日の丸めに使うカレンダー（既定は端末ローカル）。
    /// - Returns: 暦日キー（SkyStreakDay）→ その日の投稿配列。投稿が無い日はキー自体が存在しない。
    static func groupByDay(
        posts: [Post],
        calendar: Calendar = .current
    ) -> [SkyStreakDay: [Post]] {
        var grouped: [SkyStreakDay: [Post]] = [:]

        for post in posts {
            // 撮影日時を優先し、無ければ投稿日時で判定（On This Day・季節・時間帯と同じフォールバック方針）
            let date = post.capturedAt ?? post.createdAt
            guard let key = SkyStreakDay(date: date, calendar: calendar) else { continue }
            grouped[key, default: []].append(post)
        }

        for key in grouped.keys {
            grouped[key]?.sort { $0.createdAt > $1.createdAt }
        }

        return grouped
    }
}
