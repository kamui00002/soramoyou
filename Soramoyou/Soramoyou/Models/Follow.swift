//
//  Follow.swift
//  Soramoyou
//
//  フォロー関係を表す Firestore コレクションのモデル ⭐️ Issue #2
//
//  ドキュメント ID は "{followerId}_{followeeId}" の複合 ID とすることで、
//  Firestore レベルで重複フォローを防ぐ。
//

import Foundation
import FirebaseFirestore

/// フォロー関係エンティティ
///
/// `follows/{followerId}_{followeeId}` のドキュメント単位で保持する。
struct Follow: Identifiable, Codable, Equatable {
    /// 複合 ID `"{followerId}_{followeeId}"`
    let id: String
    /// フォローしているユーザー ID
    let followerId: String
    /// フォローされているユーザー ID
    let followeeId: String
    /// 作成日時（サーバータイムスタンプ）
    let createdAt: Date

    init(
        id: String,
        followerId: String,
        followeeId: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.followerId = followerId
        self.followeeId = followeeId
        self.createdAt = createdAt
    }

    /// follower / followee から複合 ID を生成
    /// 命名注意：Firestore Security Rules 側は `followeeId` と命名されているため
    /// それに合わせている。意味は「フォローされる側のユーザー ID」。
    static func makeId(followerId: String, followeeId: String) -> String {
        return "\(followerId)_\(followeeId)"
    }

    // MARK: - Firestore Mapping

    /// Firestore ドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        return [
            "followerId": followerId,
            "followeeId": followeeId,
            "createdAt": Timestamp(date: createdAt)
        ]
    }

    /// Firestore ドキュメントから初期化
    init?(from document: DocumentSnapshot) {
        guard let data = document.data(),
              let followerId = data["followerId"] as? String,
              let followeeId = data["followeeId"] as? String else {
            return nil
        }
        self.id = document.documentID
        self.followerId = followerId
        self.followeeId = followeeId
        if let ts = data["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
        } else {
            self.createdAt = Date()
        }
    }
}
