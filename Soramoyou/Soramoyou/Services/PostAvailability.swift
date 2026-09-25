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
    /// 削除済み（notFound）と、非公開化・フォロー解除で読めなくなったもの（permissionDenied）、
    /// 中身が壊れていてデコードできないもの（`PostModelError`）が該当。
    /// これ以外（ネットワーク断など）は一時的な失敗として扱い、再試行の余地を残す。
    ///
    /// ⚠️ デコード失敗を「一時的」と扱うと、壊れた投稿が 1 件あるだけでランキング全体が
    ///    エラー（しかも RetryableOperation が全体を何度もやり直す）になる。
    ///    何度取り直しても直らないので、tech-spec.md の方針どおり 1 件だけスキップする。
    static func isUnavailable(_ error: Error) -> Bool {
        guard let serviceError = error as? FirestoreServiceError else { return false }

        switch serviceError {
        case .notFound:
            return true
        case let .fetchFailed(underlying):
            if underlying is PostModelError {
                print("❌ 投稿のデコード失敗（壊れた投稿として 1 件スキップ） error=\(underlying)")
                return true
            }
            let nsError = underlying as NSError
            return nsError.code == FirestoreErrorCode.permissionDenied.rawValue
        default:
            return false
        }
    }
}
