//
//  PostPage.swift
//  Soramoyou
//
//  投稿一覧の 1 ページ分の取得結果 ⭐️
//

import FirebaseFirestore
import Foundation

/// 投稿一覧の 1 ページ分の取得結果 ⭐️
///
/// 「続きがあるか」を投稿の件数ではなく `isExhausted` で持つための型。
/// 壊れた投稿は `PostDocumentDecoder` が 1 件ずつ飛ばすため、`posts.count` は
/// 実際に読んだドキュメント数より少なくなることがある。件数で判定すると、
/// 満杯のページでも「続きなし」と誤判定して無限スクロールが止まってしまう。
struct PostPage {
    /// 表示できる投稿（変換に失敗したドキュメントは含まない）
    let posts: [Post]
    /// 次ページの起点（このページで実際に読んだ最後のドキュメント）
    let lastDocument: DocumentSnapshot?
    /// これ以上読めるものが無いか
    ///
    /// ⚠️ `posts.count` ではなく「実際に読んだドキュメント数 < limit」で決めること
    ///    （`FeedStreamPage.isExhausted` と同じ規則）。
    let isExhausted: Bool
}

extension PostPage {
    /// Firestore のクエリ結果からページを作る
    ///
    /// カーソルと枯渇判定はどちらも「変換に成功したか」に関係なく、
    /// 実際に読んだドキュメントから決める（この規則をここ 1 か所に集める）。
    /// - Parameters:
    ///   - posts: `snapshot` を変換した投稿
    ///   - snapshot: クエリ結果
    ///   - limit: クエリに付けた件数の上限
    init(posts: [Post], snapshot: QuerySnapshot, limit: Int) {
        self.init(
            posts: posts,
            lastDocument: snapshot.documents.last,
            isExhausted: snapshot.documents.count < limit
        )
    }
}
