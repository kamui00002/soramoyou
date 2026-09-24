//
//  RankingAggregator.swift
//  Soramoyou
//
//  いいねランキング（週間 / 月間）の集計ロジック ⭐️
//
//  「期間中に押されたいいね」を投稿ごとに数えて順位を付ける純関数群。
//  Firestore にも UI にも触らないので、単体テストで挙動を固定できる（`RankingAggregatorTests`）。
//  Firestore からの取得（likes の期間クエリ・投稿の個別 get）は `RankingService` が担う。
//
//  ⚠️ 数える対象は `posts.likesCount`（全期間の累計）ではなく `likes` ドキュメントそのもの。
//     likesCount はクライアントの ±1 で更新されるためずれうる（ReactedUsersViewModel の注記と同じ理由）うえ、
//     「いつ押されたか」を持たないので期間で区切れない。
//

import Foundation

// MARK: - 集計期間

/// ランキングの集計期間 ⭐️
///
/// カレンダー区切り（今週の月曜〜）ではなく「開いた時点から直近 N 日」のスライド窓。
/// 期間の始めにランキングが空になる問題を避けるため（利用者がまだ少ない今のそらもように合わせた選択）。
enum RankingPeriod: String, CaseIterable {
    /// 週間ランキング（直近 7 日）
    case weekly
    /// 月間ランキング（直近 30 日）
    case monthly

    /// 集計する日数
    var days: Int {
        switch self {
        case .weekly: return 7
        case .monthly: return 30
        }
    }

    /// 画面表示名
    var displayName: String {
        switch self {
        case .weekly: return "週間"
        case .monthly: return "月間"
        }
    }

    /// 期間の説明（空状態・見出しで使う）
    var windowDescription: String {
        switch self {
        case .weekly: return "この1週間"
        case .monthly: return "この30日間"
        }
    }

    /// 集計窓の開始時刻（`now` から `days` 日さかのぼった時刻）
    func windowStart(now: Date) -> Date {
        now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }
}

// MARK: - 集計結果

/// ランキングの 1 件 ⭐️
struct RankedPost: Identifiable {
    /// 順位（1 始まり。同じいいね数は同順位＝1, 2, 2, 4 の競技方式）
    let rank: Int
    /// 対象の投稿
    let post: Post
    /// 期間中に付いたいいね数（投稿者本人のいいねは除く）
    let likeCount: Int

    var id: String { post.id }
}

// MARK: - 集計ロジック（純関数）

/// ランキング集計の純関数群 ⭐️
enum RankingAggregator {
    /// 投稿ごとに束ねた「期間中のいいね」
    struct Candidate: Equatable {
        /// 投稿 ID
        let postId: String
        /// いいねした人 → いいねした時刻（likes のドキュメント ID が `{userId}_{postId}` なので 1 人 1 件）
        let likedAtByUserId: [String: Date]

        /// 投稿者本人のいいねも含めた件数（投稿を取得する前の暫定値）
        var rawLikeCount: Int { likedAtByUserId.count }

        /// 最も新しいいいねの時刻（同数時の並び順に使う）
        var latestLikedAt: Date { likedAtByUserId.values.max() ?? .distantPast }
    }

    /// いいねを投稿ごとに束ね、暫定いいね数の多い順に並べる。
    ///
    /// - 並び順: 暫定いいね数の降順 → 最新のいいねが新しい順 → postId の昇順。
    ///   ⚠️ Swift の `sorted(by:)` は安定ソートではないので、最後に postId で並びを決定的にする。
    /// - 同じ人・同じ投稿のいいねが重複していても 1 件として数える
    ///   （ID の設計上は起きないが、集計が壊れないよう防御する）。
    static func candidates(from likes: [Like]) -> [Candidate] {
        var grouped: [String: [String: Date]] = [:]
        for like in likes {
            var likers = grouped[like.postId, default: [:]]
            // 重複時は新しい方の時刻を残す
            if let existing = likers[like.userId], existing >= like.createdAt {
                continue
            }
            likers[like.userId] = like.createdAt
            grouped[like.postId] = likers
        }

        return grouped
            .map { Candidate(postId: $0.key, likedAtByUserId: $0.value) }
            .sorted(by: isOrderedBefore)
    }

    /// 取得済みの投稿を使って最終的な順位を作る。
    ///
    /// ランキングに入れない投稿:
    /// - 取得できなかった投稿（削除済み・非公開化されて読めない）
    /// - 公開範囲が `public` 以外の投稿（フォロワー限定は見る人によって見え方が変わるため、
    ///   誰が開いても同じランキングになるよう公開投稿だけに揃える）
    /// - 閲覧者がブロックしている人の投稿（順位を詰めて表示する＝欠番を作らない）
    /// - 投稿者本人のいいねを除くと 0 件になる投稿
    ///
    /// - Parameters:
    ///   - candidates: `candidates(from:)` の結果
    ///   - posts: postId → 投稿（取得できたものだけ）
    ///   - blockedUserIds: 閲覧者がブロックしているユーザー ID
    ///   - limit: 返す最大件数
    /// - Returns: 順位付きの投稿（順位の昇順）
    static func rank(
        candidates: [Candidate],
        posts: [String: Post],
        blockedUserIds: Set<String>,
        limit: Int
    ) -> [RankedPost] {
        guard limit > 0 else { return [] }

        // 投稿者本人のいいねを除いた候補を作り直す
        let eligible: [(candidate: Candidate, post: Post)] = candidates.compactMap { candidate in
            guard let post = posts[candidate.postId],
                  post.visibility == .public,
                  !blockedUserIds.contains(post.userId) else {
                return nil
            }
            var likers = candidate.likedAtByUserId
            // 自分の投稿への自いいねは数えない（全員が +1 できてしまい順位の意味が薄れるため）
            likers.removeValue(forKey: post.userId)
            guard !likers.isEmpty else { return nil }
            return (Candidate(postId: candidate.postId, likedAtByUserId: likers), post)
        }

        let sorted = eligible
            .sorted { isOrderedBefore($0.candidate, $1.candidate) }
            .prefix(limit)

        // 競技方式の順位（同数は同順位、次の順位は人数分とばす）
        var result: [RankedPost] = []
        for (index, entry) in sorted.enumerated() {
            let count = entry.candidate.rawLikeCount
            let rank: Int
            if let previous = result.last, previous.likeCount == count {
                rank = previous.rank
            } else {
                rank = index + 1
            }
            result.append(RankedPost(rank: rank, post: entry.post, likeCount: count))
        }
        return result
    }

    /// まだ投稿を取得していない候補の中に、現在の順位表へ割り込める候補が残っているか。
    ///
    /// 投稿者本人のいいねを除くと件数は「暫定値 − 1」まで下がりうるため、
    /// 暫定値の多い順に少しずつ投稿を取得し、これ以上取っても順位表が変わらない所で止める。
    ///
    /// - Parameters:
    ///   - ranked: ここまでの順位表
    ///   - nextCandidate: 次に取得する予定の候補（nil＝候補が尽きた）
    ///   - limit: 順位表の最大件数
    /// - Returns: 取得を続けるべきなら true
    ///
    /// ⚠️ 境界で「同数」の候補は取りに行かない（既に取得した方を優先する）。
    ///    同数を全部取りに行くと、いいね 1 件の投稿が大量にあるときに読み取りが膨らむため。
    static func shouldFetchMore(ranked: [RankedPost], nextCandidate: Candidate?, limit: Int) -> Bool {
        guard let next = nextCandidate else { return false }
        // 順位表がまだ埋まっていないなら、候補がある限り取りに行く
        guard ranked.count >= limit, let boundary = ranked.last?.likeCount else { return true }
        // 次の候補は（本人のいいねを除いても）境界を超えうるときだけ取りに行く
        return next.rawLikeCount > boundary
    }

    // MARK: - Private

    /// 並び順: いいね数の降順 → 最新のいいねが新しい順 → postId の昇順
    private static func isOrderedBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.rawLikeCount != rhs.rawLikeCount {
            return lhs.rawLikeCount > rhs.rawLikeCount
        }
        if lhs.latestLikedAt != rhs.latestLikedAt {
            return lhs.latestLikedAt > rhs.latestLikedAt
        }
        return lhs.postId < rhs.postId
    }
}
