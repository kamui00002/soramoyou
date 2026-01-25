//
//  Comment.swift
//  Soramoyou
//
//  Created on 2025-12-06.
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
    var updatedAt: Date

    // 表示用のユーザー情報（Firestoreには保存しない）
    var userName: String?
    var userPhotoURL: String?

    init(
        id: String = UUID().uuidString,
        userId: String,
        postId: String,
        content: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        userName: String? = nil,
        userPhotoURL: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.postId = postId
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.userName = userName
        self.userPhotoURL = userPhotoURL
    }

    // MARK: - Firestore Mapping

    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        return [
            "commentId": id,
            "userId": userId,
            "postId": postId,
            "content": content,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt)
        ]
    }

    /// Firestoreドキュメントデータから初期化
    init(from documentData: [String: Any]) throws {
        guard let commentId = documentData["commentId"] as? String,
              let userId = documentData["userId"] as? String,
              let postId = documentData["postId"] as? String,
              let content = documentData["content"] as? String else {
            throw CommentModelError.missingRequiredFields
        }

        self.id = commentId
        self.userId = userId
        self.postId = postId
        self.content = content

        if let createdAtTimestamp = documentData["createdAt"] as? Timestamp {
            self.createdAt = createdAtTimestamp.dateValue()
        } else {
            self.createdAt = Date()
        }

        if let updatedAtTimestamp = documentData["updatedAt"] as? Timestamp {
            self.updatedAt = updatedAtTimestamp.dateValue()
        } else {
            self.updatedAt = Date()
        }

        self.userName = documentData["userName"] as? String
        self.userPhotoURL = documentData["userPhotoURL"] as? String
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

// MARK: - CommentModelError

enum CommentModelError: LocalizedError {
    case missingRequiredFields
    case contentTooLong
    case contentEmpty

    var errorDescription: String? {
        switch self {
        case .missingRequiredFields:
            return "必須フィールドが不足しています"
        case .contentTooLong:
            return "コメントは500文字以内で入力してください"
        case .contentEmpty:
            return "コメントを入力してください"
        }
    }
}
