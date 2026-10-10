//
//  SoratomoError+Firebase.swift
//  Soramoyou
//
//  Firestore と通信のエラーを、そらとものエラー（SoratomoError）へ写す ⭐️
//  （tasks 11.1・11.2・11.5 で共有・design.md の Error Strategy）
//
//  ⚠️ ここで扱うのは Firestore と NSURLError だけ。
//     - Callable（Functions）のエラーの写し（`details["reason"]` の flag_off など）は SoratomoGroupService（tasks 11.1）
//     - Storage のエラーの写しは SoratomoImageStore（tasks 11.4）
//     がそれぞれ持つ。どちらも、自分で写せないエラーはここへ回してよい。
//

import FirebaseFirestore
import Foundation

/// Firestore の失敗が、読み取りと書き込みのどちらで起きたか
///
/// 権限の拒否の意味が変わるので、写すときに必ず指定する。
enum SoratomoFirestoreAccess {
    /// 読み取り・監視。権限の拒否と不在は「メンバーでない」（グループを読めない・design.md の SoratomoGroupService）
    case read
    /// 書き込み（トランザクション・updateData）。権限の拒否は `.permissionDenied` のまま
    case write
}

extension SoratomoError {
    /// Firestore（と通信）のエラーを写す
    ///
    /// | 元のエラー | 読み取り | 書き込み |
    /// |---|---|---|
    /// | `SoratomoError` | そのまま | そのまま |
    /// | `NSURLErrorDomain`（取り消しを除く） | `.network` | `.network` |
    /// | `unavailable`・`deadlineExceeded` | `.network` | `.network` |
    /// | `permissionDenied` | `.notMember` | `.permissionDenied` |
    /// | `notFound` | `.notMember` | `.unknown` |
    /// | `unauthenticated` | `.permissionDenied` | `.permissionDenied` |
    /// | それ以外 | `.unknown` | `.unknown` |
    ///
    /// - Note: `unavailable` と `deadlineExceeded` は、書き込みでは結果が確定していないことがある
    ///   （サーバーには届いた可能性がある）。削除の後は `skyExistsOnServer` で確かめること（design.md の Error Handling）。
    ///   投稿の作成は Callable なので、この表ではなく `SoratomoGroupService.mapCallableError` で写す（release-gate 9.3）。
    /// - Parameters:
    ///   - error: 元のエラー
    ///   - access: 読み取りか書き込みか
    /// - Returns: 写した種類
    static func fromFirestore(_ error: Error, access: SoratomoFirestoreAccess) -> SoratomoError {
        if let soratomoError = error as? SoratomoError {
            return soratomoError
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            // 取り消しは通信の失敗ではない（呼び出し側が止めた）
            return nsError.code == NSURLErrorCancelled ? .unknown : .network
        }
        // 判定の形は FirestoreService.isPostUnreachableError と同じ（ドメインを確かめてから番号を比べる）
        guard nsError.domain == FirestoreErrorDomain else {
            return .unknown
        }
        switch nsError.code {
        case FirestoreErrorCode.unavailable.rawValue, FirestoreErrorCode.deadlineExceeded.rawValue:
            return .network
        case FirestoreErrorCode.permissionDenied.rawValue:
            return access == .read ? .notMember : .permissionDenied
        case FirestoreErrorCode.notFound.rawValue:
            return access == .read ? .notMember : .unknown
        case FirestoreErrorCode.unauthenticated.rawValue:
            return .permissionDenied
        default:
            return .unknown
        }
    }
}
