//
//  FavoritePage.swift
//  Soramoyou
//
//  お気に入り一覧（users/{uid}/favorites）の 1 ページ分の取得結果 ⭐️
//

import FirebaseFirestore
import Foundation

/// お気に入り一覧の 1 ページ分の取得結果 ⭐️
///
/// 「続きがあるか」をお気に入りの件数ではなく `isExhausted` で持つための型（`PostPage` と同じ考え方）。
/// 壊れたドキュメントは `fetchFavorites` が 1 件ずつ飛ばすため、`favorites.count` は
/// 実際に読んだドキュメント数より少なくなることがある。件数で判定すると、
/// 満杯のページでも「続きなし」と誤判定してページ送りが止まってしまう。
struct FavoritePage {
    /// 変換できたお気に入り（createdAt 降順。変換に失敗したドキュメントは含まない）
    let favorites: [Favorite]
    /// このページで実際に読んだ最後のドキュメントの createdAt（変換に失敗したものも含む）
    ///
    /// ページを最後まで消費したとき、次ページの起点にはこれを使う。
    /// ⚠️ `favorites.last` で決めると、末尾の壊れたドキュメントを毎回読み直し、
    ///    ページ丸ごと壊れていたときはカーソルが 1 歩も進まない（同じページを読み続ける）。
    /// 読んだドキュメントが 0 件、または createdAt が Timestamp でないときは nil。
    let lastReadCreatedAt: Date?
    /// これ以上読めるものが無いか
    ///
    /// ⚠️ `favorites.count` ではなく「実際に読んだドキュメント数 < limit」で決めること
    ///    （`PostPage.isExhausted` と同じ規則）。
    let isExhausted: Bool
}

extension FavoritePage {
    /// Firestore のクエリ結果からページを作る
    ///
    /// カーソルと枯渇判定はどちらも「変換に成功したか」に関係なく、
    /// 実際に読んだドキュメントから決める（この規則をここ 1 か所に集める）。
    /// - Parameters:
    ///   - favorites: `snapshot` を変換したお気に入り
    ///   - snapshot: クエリ結果
    ///   - limit: クエリに付けた件数の上限
    init(favorites: [Favorite], snapshot: QuerySnapshot, limit: Int) {
        let lastCreatedAt = snapshot.documents.last?.data()["createdAt"] as? Timestamp
        self.init(
            favorites: favorites,
            lastReadCreatedAt: lastCreatedAt?.dateValue(),
            isExhausted: snapshot.documents.count < limit
        )
    }
}
