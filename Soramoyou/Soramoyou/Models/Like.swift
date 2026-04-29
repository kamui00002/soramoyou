//
//  Like.swift
//  Soramoyou
//
//  いいねエンティティ
//  ドキュメントID: {userId}_{postId}
//

import Foundation
import FirebaseFirestore

/// いいねエンティティ
struct Like: Identifiable, Codable {
    let id: String
    let userId: String
    let postId: String
    let createdAt: Date

    init(userId: String, postId: String, createdAt: Date = Date()) {
        self.id = Like.documentId(userId: userId, postId: postId)
        self.userId = userId
        self.postId = postId
        self.createdAt = createdAt
    }

    /// ドキュメントIDを生成（{userId}_{postId} 形式）
    static func documentId(userId: String, postId: String) -> String {
        "\(userId)_\(postId)"
    }

    // MARK: - Firestore Mapping

    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        [
            "userId": userId,
            "postId": postId,
            "createdAt": Timestamp(date: createdAt)
        ]
    }

    /// Firestoreドキュメントデータから初期化
    init(from documentData: [String: Any], documentId: String) throws {
        guard let userId = documentData["userId"] as? String,
              let postId = documentData["postId"] as? String else {
            throw LikeModelError.missingRequiredFields
        }

        self.id = documentId
        self.userId = userId
        self.postId = postId

        if let createdAtTimestamp = documentData["createdAt"] as? Timestamp {
            self.createdAt = createdAtTimestamp.dateValue()
        } else {
            self.createdAt = Date()
        }
    }
}

// MARK: - LikeModelError

enum LikeModelError: Error {
    case missingRequiredFields
}
