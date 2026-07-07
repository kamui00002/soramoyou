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

    // MARK: - ギャラリー用クエリ構築（絞り込み＋並び替え＋ページング）

    /// ギャラリータブ用の Firestore クエリを構築する。
    ///
    /// `visibility==public` を土台に、時間帯／空の種類の任意フィルタを重ね、
    /// 指定フィールドで降順ソートしたページング付きクエリを返す。
    /// - Parameters:
    ///   - collection: 対象コレクション参照
    ///   - timeOfDay: 時間帯フィルタ（nil=すべて）
    ///   - skyType: 空の種類フィルタ（nil=すべて）
    ///   - sortField: 並び替えフィールド（"createdAt" or "likesCount"）
    ///   - limit: 取得上限数
    ///   - lastDocument: ページング用の最後のドキュメント（nil=最初のページ）
    /// - Returns: 構築済みの Firestore クエリ
    static func buildGalleryQuery(
        collection: CollectionReference,
        timeOfDay: TimeOfDay?,
        skyType: SkyType?,
        sortField: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) -> Query {
        var query: Query = collection
            .whereField("visibility", isEqualTo: Visibility.public.rawValue)

        if let timeOfDay = timeOfDay {
            query = query.whereField("timeOfDay", isEqualTo: timeOfDay.rawValue)
        }

        if let skyType = skyType {
            query = query.whereField("skyType", isEqualTo: skyType.rawValue)
        }

        query = query.order(by: sortField, descending: true)
            .limit(to: limit)

        // ページング: 指定があればそのドキュメントの後続を取得
        if let lastDocument = lastDocument {
            query = query.start(afterDocument: lastDocument)
        }

        return query
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
