//
//  PostQueryBuilder.swift
//  Soramoyou
//
//  Firestoreクエリの条件構築を担当するビルダー
//  FirestoreServiceから分離された検索クエリ組み立てロジック
//

import Foundation
import FirebaseFirestore

/// 投稿検索用のFirestoreクエリを構築するビルダー
/// Firestoreの制約（arrayContainsは1クエリにつき1つのみ）を考慮した
/// クエリ構築ロジックを提供する
struct PostQueryBuilder {

    // MARK: - クエリ構築結果

    /// クエリ構築の結果
    /// Firestoreクエリと、クライアント側で追加フィルタリングが必要な条件を含む
    struct QueryResult {
        /// 構築されたFirestoreクエリ
        let query: Query
        /// クライアント側で色の完全一致フィルタリングが必要かどうか
        /// （hashtagとcolorが同時指定された場合、colorはクエリに含められないため）
        let needsClientSideColorFilter: Bool
        /// クライアント側フィルタリング用の色（needsClientSideColorFilterがtrueの場合に使用）
        let clientSideFilterColor: String?
    }

    // MARK: - クエリ構築

    /// 検索条件からFirestoreクエリを構築する
    /// - Parameters:
    ///   - collection: 対象のコレクション参照
    ///   - hashtag: ハッシュタグ検索条件（nil可）
    ///   - color: 色検索条件（nil可）
    ///   - timeOfDay: 時間帯検索条件（nil可）
    ///   - skyType: 空の種類検索条件（nil可）
    ///   - limit: 取得上限数
    /// - Returns: クエリ構築結果（Firestoreクエリとクライアントサイドフィルタ情報）
    static func buildSearchQuery(
        collection: CollectionReference,
        hashtag: String?,
        color: String?,
        timeOfDay: TimeOfDay?,
        skyType: SkyType?,
        limit: Int
    ) -> QueryResult {
        var query: Query = collection
            .whereField("visibility", isEqualTo: Visibility.public.rawValue)

        // Firestoreの制約: arrayContainsは1クエリにつき1つのみ使用可能
        // hashtagとcolorの両方が指定された場合、hashtagをクエリで処理し、
        // colorはクライアント側でフィルタリングする
        let useHashtagInQuery = hashtag != nil

        if let hashtag = hashtag {
            query = query.whereField("hashtags", arrayContains: hashtag)
        }

        if let timeOfDay = timeOfDay {
            query = query.whereField("timeOfDay", isEqualTo: timeOfDay.rawValue)
        }

        if let skyType = skyType {
            query = query.whereField("skyType", isEqualTo: skyType.rawValue)
        }

        // hashtagが指定されていない場合のみ、colorのarrayContainsをクエリに含める
        if let color = color, !useHashtagInQuery {
            query = query.whereField("skyColors", arrayContains: color)
        }

        query = query.order(by: "createdAt", descending: true)
            .limit(to: limit)

        // hashtagとcolorの両方が指定された場合は、クライアントサイドフィルタが必要
        let needsClientSideColorFilter = (color != nil && useHashtagInQuery)

        return QueryResult(
            query: query,
            needsClientSideColorFilter: needsClientSideColorFilter,
            clientSideFilterColor: needsClientSideColorFilter ? color : nil
        )
    }

    // MARK: - クライアントサイドフィルタリング

    /// クエリ結果にクライアントサイドの色フィルタリングとRGB距離フィルタリングを適用する
    /// - Parameters:
    ///   - posts: Firestoreから取得した投稿リスト
    ///   - queryResult: クエリ構築結果（クライアントサイドフィルタ情報を含む）
    ///   - color: 色検索条件（nil可）
    ///   - colorThreshold: 色距離の閾値（nil可）
    /// - Returns: フィルタリング後の投稿リスト
    static func applyClientSideFilters(
        posts: [Post],
        queryResult: QueryResult,
        color: String?,
        colorThreshold: Double?
    ) -> [Post] {
        var filteredPosts = posts

        // hashtagとcolorの両方が指定された場合、colorはクライアント側でフィルタリング
        // skyColorsはOptional型のため、nil安全なアクセスを使用
        if let filterColor = queryResult.clientSideFilterColor, queryResult.needsClientSideColorFilter {
            filteredPosts = filteredPosts.filter { post in
                post.skyColors?.contains(filterColor) ?? false
            }
        }

        // 色検索で閾値が指定されている場合は、RGB距離によるフィルタリングを適用
        if let color = color, let threshold = colorThreshold {
            filteredPosts = ColorMatching.filterPostsByColorDistance(
                posts: filteredPosts,
                targetColor: color,
                threshold: threshold
            )
        }

        return filteredPosts
    }
}
