//
//  FollowPage.swift
//  Soramoyou
//
//  フォロー一覧の 1 ページ分の取得結果 ⭐️
//

// Firebase SDK は Swift 6 strict concurrency 下で非 Sendable 型を含むため
// @preconcurrency で互換モードを宣言する（FollowRepository と同方針）
@preconcurrency import FirebaseFirestore
import Foundation

/// フォロー一覧の 1 ページ分の取得結果 ⭐️
///
/// 「続きがあるか」をフォローの件数ではなく `isExhausted` で持つための型。
/// 壊れたフォロードキュメントは `FollowRepository` が 1 件ずつ飛ばすため、
/// `follows.count` は実際に読んだドキュメント数より少なくなることがある。
/// 件数で判定すると、満杯のページでも「続きなし」と誤判定して一覧の続きが読めなくなる。
struct FollowPage {
    /// 表示できるフォロー関係（変換に失敗したドキュメントは含まない）
    let follows: [Follow]
    /// 次ページの起点（このページで実際に読んだ最後のドキュメント）
    let lastDocument: DocumentSnapshot?
    /// これ以上読めるものが無いか
    ///
    /// ⚠️ `follows.count` ではなく「実際に読んだドキュメント数 < limit」で決めること。
    ///    これが false のときは limit 件読めている（Firestore は limit に 1 以上しか許さない）ので、
    ///    `lastDocument` は必ずある。
    let isExhausted: Bool
}

extension FollowPage {
    /// Firestore のクエリ結果からページを作る
    ///
    /// カーソルと枯渇判定はどちらも「変換に成功したか」に関係なく、
    /// 実際に読んだドキュメントから決める（この規則をここ 1 か所に集める）。
    /// - Parameters:
    ///   - follows: `snapshot` を変換したフォロー関係
    ///   - snapshot: クエリ結果
    ///   - limit: クエリに付けた件数の上限
    init(follows: [Follow], snapshot: QuerySnapshot, limit: Int) {
        self.init(
            follows: follows,
            lastDocument: snapshot.documents.last,
            isExhausted: snapshot.documents.count < limit
        )
    }
}
