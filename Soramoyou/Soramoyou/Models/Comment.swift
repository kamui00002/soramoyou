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
    /// 投稿者の表示名（投稿時点の値を非正規化して保存。旧コメントは nil）
    let authorName: String?
    /// 投稿者のプロフィール画像URL（投稿時点の値を非正規化して保存。旧コメントは nil）
    let authorPhotoURL: String?

    init(
        id: String = UUID().uuidString,
        userId: String,
        postId: String,
        content: String,
        createdAt: Date = Date(),
        authorName: String? = nil,
        authorPhotoURL: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.postId = postId
        self.content = content
        self.createdAt = createdAt
        self.authorName = authorName
        self.authorPhotoURL = authorPhotoURL
    }

    /// コンテンツのバリデーション（1〜500文字）
    var isValid: Bool {
        !content.isEmpty && content.count <= 500
    }

    // MARK: - Firestore Mapping

    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "userId": userId,
            "postId": postId,
            "content": content,
            "createdAt": Timestamp(date: createdAt)
        ]
        // 投稿者情報は値があるときだけ書き込む（旧コメント・匿名は省略）
        if let authorName = authorName {
            data["authorName"] = authorName
        }
        if let authorPhotoURL = authorPhotoURL {
            data["authorPhotoURL"] = authorPhotoURL
        }
        return data
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
        // 投稿者情報は任意（旧コメントには存在しない）
        self.authorName = documentData["authorName"] as? String
        self.authorPhotoURL = documentData["authorPhotoURL"] as? String

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
