//
//  OnThisDayService.swift
//  Soramoyou
//
//  On This Day（1年前の空）: 今日と同じ月日に撮った/投稿した過去の空を蘇らせる。
//  既存の posts + capturedAt/createdAt の再利用のみ。バックエンド/プッシュ不要。
//

import Foundation

/// 「N年前の今日の空」1件。
/// （`Post` が Equatable 非準拠のため Equatable は付けない。`.sheet(item:)` には Identifiable で十分。）
struct OnThisDayMemory: Identifiable {
    /// 元の投稿
    let post: Post
    /// 何年前か（1 = 去年）
    let yearsAgo: Int

    var id: String { post.id }
}

/// On This Day の抽出ロジック（純関数・Firestore/UI 非依存）。
enum OnThisDayService {

    /// 今日と同じ月日に撮影（無ければ投稿）された過去（去年以前）の投稿を、
    /// 新しい年順（yearsAgo の小さい順）で返す。
    /// - Parameters:
    ///   - posts: ユーザー自身の投稿。
    ///   - today: 基準日（既定は現在）。テストで固定可能。
    ///   - calendar: 判定に使うカレンダー（既定は端末ローカル）。
    static func memories(
        from posts: [Post],
        today: Date,
        calendar: Calendar = .current
    ) -> [OnThisDayMemory] {
        let todayComps = calendar.dateComponents([.year, .month, .day], from: today)
        guard let todayMonth = todayComps.month,
              let todayDay = todayComps.day,
              let todayYear = todayComps.year else {
            return []
        }

        var memories: [OnThisDayMemory] = []
        for post in posts {
            // 撮影日時を優先し、無ければ投稿日時で判定（季節・時間帯と同じフォールバック方針）
            let date = post.capturedAt ?? post.createdAt
            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            guard let month = comps.month,
                  let day = comps.day,
                  let year = comps.year else { continue }

            // 同じ月日・かつ過去の年だけを対象にする
            guard month == todayMonth, day == todayDay, year < todayYear else { continue }
            memories.append(OnThisDayMemory(post: post, yearsAgo: todayYear - year))
        }

        // 新しい年（yearsAgo が小さい）順に並べる
        return memories.sorted { $0.yearsAgo < $1.yearsAgo }
    }
}
