//
//  Favorite.swift
//  Soramoyou
//
//  お気に入りエンティティ（私のお気に入りの空）⭐️
//  保存先: users/{userId}/favorites/{postId}
//  ドキュメントID = postId。所有者のサブコレクションなので userId はフィールドに持たない。
//
//  ⚠️ ❤️いいねとは別物のプライベート保存。通知しない・件数を公開しない・自分だけが見られる。
//

import Foundation
import FirebaseFirestore

/// お気に入りエンティティ
struct Favorite: Identifiable, Codable {
    /// Identifiable 用のID（= postId = ドキュメントID）
    let id: String
    let postId: String
    let createdAt: Date

    init(postId: String, createdAt: Date = Date()) {
        // ドキュメントIDと postId を同一にすることで、
        // rules 側で `request.resource.data.postId == postId` を検証できる。
        self.id = postId
        self.postId = postId
        self.createdAt = createdAt
    }

    // MARK: - Firestore Mapping

    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        [
            "postId": postId,
            "createdAt": Timestamp(date: createdAt)
        ]
    }

    /// Firestoreドキュメントデータから初期化
    /// - Parameters:
    ///   - documentData: Firestore のフィールド辞書
    ///   - documentId: ドキュメントID（= postId）
    init(from documentData: [String: Any], documentId: String) throws {
        guard let postId = documentData["postId"] as? String else {
            throw FavoriteModelError.missingRequiredFields
        }

        self.id = documentId
        self.postId = postId

        if let createdAtTimestamp = documentData["createdAt"] as? Timestamp {
            self.createdAt = createdAtTimestamp.dateValue()
        } else {
            // createdAt 欠落は致命的ではないため現在時刻で代替する（並び順だけが崩れる）。
            self.createdAt = Date()
        }
    }
}

// MARK: - FavoriteModelError

enum FavoriteModelError: Error {
    case missingRequiredFields
}
