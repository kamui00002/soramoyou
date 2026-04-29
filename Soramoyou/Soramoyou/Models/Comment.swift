//
//  Comment.swift
//  Soramoyou
//
//  コメントエンティティ
//

import Foundation
import FirebaseFirestore

/// コメントエンティティ
struct Comment: Identifiable, Codable {
    let id: String
    let userId: String
    let postId: String
    let content: String
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        userId: String,
        postId: String,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.postId = postId
        self.content = content
        self.createdAt = createdAt
    }

    /// コンテンツのバリデーション（1〜500文字）
    var isValid: Bool {
        !content.isEmpty && content.count <= 500
    }

    // MARK: - Firestore Mapping

    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        [
            "userId": userId,
            "postId": postId,
            "content": content,
            "createdAt": Timestamp(date: createdAt)
        ]
    }

    /// Firestoreドキュメントデータから初期化
    init(from documentData: [String: Any], documentId: String) throws {
        guard let userId = documentData["userId"] as? String,
              let postId = documentData["postId"] as? String,
              let content = documentData["content"] as? String else {
            throw CommentModelError.missingRequiredFields
        }

        self.id = documentId
        self.userId = userId
        self.postId = postId
        self.content = content

        if let createdAtTimestamp = documentData["createdAt"] as? Timestamp {
            self.createdAt = createdAtTimestamp.dateValue()
        } else {
            self.createdAt = Date()
        }
    }
}

// MARK: - CommentModelError

enum CommentModelError: Error {
    case missingRequiredFields
    case contentTooLong
    case contentEmpty
}
