//
//  PostAvailability.swift
//  Soramoyou
//
//  投稿を 1 件ずつ get したときの失敗の分類 ⭐️
//
//  お気に入り・ランキング・おすすめの空は、どれも「postId の一覧 → 1 件ずつ fetchPost」で投稿を解決する。
//  （posts の read rule は visibility 依存のため、`documentID in [...]` の一括取得だと
//    1 件でも読めない投稿が混ざった時点でクエリ全体が permission denied になる。）
//  そのとき「もう出せない投稿」と「一時的な失敗」を同じ基準で分けるための共通ヘルパー。
//

import FirebaseFirestore
import Foundation

enum PostAvailability {
    /// 「もう出せない投稿」かどうかを判定する
    ///
    /// 削除済み（notFound）と、非公開化・フォロー解除で読めなくなったもの（permissionDenied）が該当。
    /// これ以外（ネットワーク断など）は一時的な失敗として扱い、再試行の余地を残す。
    static func isUnavailable(_ error: Error) -> Bool {
        guard let serviceError = error as? FirestoreServiceError else { return false }

        switch serviceError {
        case .notFound:
            return true
        case let .fetchFailed(underlying):
            let nsError = underlying as NSError
            return nsError.code == FirestoreErrorCode.permissionDenied.rawValue
        default:
            return false
        }
    }
}
