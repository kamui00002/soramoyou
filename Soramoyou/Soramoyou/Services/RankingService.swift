//
//  RankingService.swift
//  Soramoyou
//
//  いいねランキング（週間 / 月間）の取得サービス ⭐️
//
//  集計はアプリ内で行う（Cloud Functions は使わない）:
//    1. `likes` を「createdAt が直近 N 日」の範囲クエリで新しい順に読む
//    2. 投稿ごとに束ねて暫定いいね数の多い順に並べる（`RankingAggregator.candidates`）
//    3. 上位から少しずつ投稿を 1 件ずつ get し、公開投稿だけで順位を付ける（`RankingAggregator.rank`）
//
//  ⚠️ インデックス: 1 の範囲クエリは createdAt 単一フィールドの範囲＋同フィールドの並び替えなので
//     単一フィールドの自動インデックスで足りる。**firestore.indexes.json の追加・deploy は不要**。
//
//  ⚠️ 読み取り量: 1 回の表示で「期間中のいいね件数（上限 likeReadLimit）＋ 投稿の get（上限 maxPostFetches）」。
//     いいねが増えるほど増えるため、`ranking_loaded` の like_count / is_truncated を見て、
//     上限に張り付くようになったらサーバー側（Cloud Functions の定期集計）へ差し替えること。
//     差し替えは `RankingServiceProtocol` の実装を替えるだけで済むようにしてある。
//

import Foundation

// MARK: - 取得結果

/// ランキングの取得結果 ⭐️
struct RankingResult {
    /// 集計期間
    let period: RankingPeriod
    /// 順位付きの投稿（順位の昇順）
    let entries: [RankedPost]
    /// 集計に使ったいいねの件数（計測用）
    let likeCount: Int
    /// いいねの読み取り上限に達したか（true なら古い側のいいねを数え漏らしている）
    let isTruncated: Bool
    /// 集計した時刻（キャッシュの有効期限判定に使う）
    let fetchedAt: Date
}

// MARK: - Protocol

/// ランキング取得のインターフェース（テスト時にモックを注入可能・将来サーバー集計へ差し替え可能）
protocol RankingServiceProtocol {
    /// 指定期間のいいねランキングを取得する
    /// - Parameters:
    ///   - period: 集計期間（週間 / 月間）
    ///   - blockedUserIds: 閲覧者がブロックしているユーザー ID（その人の投稿は順位に入れない）
    ///   - now: 集計の基準時刻（テストで固定できるよう引数にしている）
    func fetchRanking(period: RankingPeriod, blockedUserIds: Set<String>, now: Date) async throws -> RankingResult
}

// MARK: - Implementation

final class RankingService: RankingServiceProtocol {
    /// ランキングに出す最大件数（ギャラリーの 1 ページ分と同じ）
    static let rankingLimit = 30
    /// いいねの読み取り上限（暴走防止の非常弁）
    ///
    /// 新しい順に読むので、上限に達したときに数え漏れるのは期間の**古い側**のいいね。
    static let likeReadLimit = 3000
    /// 投稿を 1 回にまとめて get する件数
    static let postFetchBatchSize = 30
    /// 投稿を get する総数の上限（非公開・削除済みが多くても読み取りが膨らまないように）
    static let maxPostFetches = 90

    private let firestoreService: FirestoreServiceProtocol

    init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.firestoreService = firestoreService
    }

    func fetchRanking(period: RankingPeriod, blockedUserIds: Set<String>, now: Date) async throws -> RankingResult {
        // ⚠️ 上限を now にしているのは、端末時計で createdAt を未来にしたいいねが
        //    ずっと窓に居座るのを防ぐため（likes の createdAt はクライアント時刻で書かれる）。
        let likes = try await firestoreService.fetchLikes(
            from: period.windowStart(now: now),
            to: now,
            limit: Self.likeReadLimit
        )
        let isTruncated = likes.count >= Self.likeReadLimit
        if isTruncated {
            // 例外にならないので、ここで痕跡を残さないと誰も気づけない
            print("⚠️ ランキング集計がいいねの読み取り上限 \(Self.likeReadLimit) 件に到達。期間の古い側を数え漏らしています period=\(period.rawValue)")
        }

        let candidates = RankingAggregator.candidates(from: likes)
        let fetchableCount = min(candidates.count, Self.maxPostFetches)

        var posts: [String: Post] = [:]
        var ranked: [RankedPost] = []
        var nextIndex = 0

        // 暫定いいね数の多い順に少しずつ投稿を取得し、順位表が変わらなくなった所で止める
        while nextIndex < fetchableCount,
              RankingAggregator.shouldFetchMore(
                ranked: ranked,
                nextCandidate: candidates[nextIndex],
                limit: Self.rankingLimit
              ) {
            let end = min(nextIndex + Self.postFetchBatchSize, fetchableCount)
            let batchIds = candidates[nextIndex..<end].map(\.postId)
            let fetched = try await fetchPostsIndividually(postIds: batchIds)
            posts.merge(fetched) { current, _ in current }
            nextIndex = end

            ranked = RankingAggregator.rank(
                candidates: Array(candidates[..<nextIndex]),
                posts: posts,
                blockedUserIds: blockedUserIds,
                limit: Self.rankingLimit
            )
        }

        return RankingResult(
            period: period,
            entries: ranked,
            likeCount: likes.count,
            isTruncated: isTruncated,
            fetchedAt: now
        )
    }

    // MARK: - Private

    /// 投稿を 1 件ずつ並列に取得する
    ///
    /// - 削除済み・非公開化で読めない投稿は、その 1 件だけ落とす（ランキングに出さない）。
    /// - ネットワーク等の一時的な失敗は投げ直す。
    ///   ⚠️ 1 件だけ落として続けると、本当は上位の投稿が**黙って**ランキングから消える。
    ///      嘘の順位を出すより、エラー表示（再試行できる）にする方が正直。
    private func fetchPostsIndividually(postIds: [String]) async throws -> [String: Post] {
        let results: [(String, Result<Post, Error>)] = await withTaskGroup(
            of: (String, Result<Post, Error>).self
        ) { group in
            for postId in postIds {
                group.addTask { [firestoreService] in
                    do {
                        return (postId, .success(try await firestoreService.fetchPost(postId: postId)))
                    } catch {
                        return (postId, .failure(error))
                    }
                }
            }

            var collected: [(String, Result<Post, Error>)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        var posts: [String: Post] = [:]
        for (postId, result) in results {
            switch result {
            case let .success(post):
                posts[postId] = post
            case let .failure(error):
                if PostAvailability.isUnavailable(error) {
                    // 削除済み・非公開：ランキングに出せないだけで異常ではない
                    continue
                }
                print("❌ ランキング用の投稿取得に失敗 postId=\(postId) error=\(error.localizedDescription)")
                throw error
            }
        }
        return posts
    }
}
