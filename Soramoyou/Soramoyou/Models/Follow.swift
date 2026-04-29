//
//  Follow.swift
//  Soramoyou
//
//  フォロー関係を表す Firestore コレクションのモデル ⭐️ Issue #2
//
//  ドキュメント ID は "{followerId}_{followingId}" の複合 ID とすることで、
//  Firestore レベルで重複フォローを防ぐ。
//

import Foundation
import FirebaseFirestore

/// フォロー関係エンティティ
///
/// `follows/{followerId}_{followingId}` のドキュメント単位で保持する。
struct Follow: Identifiable, Codable, Equatable {
    /// 複合 ID `"{followerId}_{followingId}"`
    let id: String
    /// フォローしているユーザー ID
    let followerId: String
    /// フォローされているユーザー ID
    let followingId: String
    /// 作成日時（サーバータイムスタンプ）
    let createdAt: Date

    init(
        id: String,
        followerId: String,
        followingId: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.followerId = followerId
        self.followingId = followingId
        self.createdAt = createdAt
    }

    /// follower / following から複合 ID を生成
    static func makeId(followerId: String, followingId: String) -> String {
        return "\(followerId)_\(followingId)"
    }

    // MARK: - Firestore Mapping

    /// Firestore ドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        return [
            "followerId": followerId,
            "followingId": followingId,
            "createdAt": Timestamp(date: createdAt)
        ]
    }

    /// Firestore ドキュメントから初期化
    init?(from document: DocumentSnapshot) {
        guard let data = document.data(),
              let followerId = data["followerId"] as? String,
              let followingId = data["followingId"] as? String else {
            return nil
        }
        self.id = document.documentID
        self.followerId = followerId
        self.followingId = followingId
        if let ts = data["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
        } else {
            self.createdAt = Date()
        }
    }
}
