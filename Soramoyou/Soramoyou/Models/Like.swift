//
//  Like.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import FirebaseFirestore

/// いいねエンティティ
struct Like: Identifiable, Codable {
    var id: String { "\(userId)_\(postId)" }
    let userId: String
    let postId: String
    let createdAt: Date

    init(
        userId: String,
        postId: String,
        createdAt: Date = Date()
    ) {
        self.userId = userId
        self.postId = postId
        self.createdAt = createdAt
    }

    // MARK: - Firestore Mapping

    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        return [
            "userId": userId,
            "postId": postId,
            "createdAt": Timestamp(date: createdAt)
        ]
    }

    /// Firestoreドキュメントデータから初期化
    init(from documentData: [String: Any]) throws {
        guard let userId = documentData["userId"] as? String,
              let postId = documentData["postId"] as? String else {
            throw LikeModelError.missingRequiredFields
        }

        self.userId = userId
        self.postId = postId

        if let createdAtTimestamp = documentData["createdAt"] as? Timestamp {
            self.createdAt = createdAtTimestamp.dateValue()
        } else {
            self.createdAt = Date()
        }
    }

    /// Firestore DocumentSnapshotから初期化
    init?(from document: DocumentSnapshot) {
        guard let data = document.data() else {
            return nil
        }

        do {
            try self.init(from: data)
        } catch {
            return nil
        }
    }
}

// MARK: - LikeModelError

enum LikeModelError: LocalizedError {
    case missingRequiredFields

    var errorDescription: String? {
        switch self {
        case .missingRequiredFields:
            return "必須フィールドが不足しています"
        }
    }
}
