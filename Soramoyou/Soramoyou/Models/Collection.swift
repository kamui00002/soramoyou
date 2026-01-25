//
//  Collection.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import FirebaseFirestore

/// コレクションエンティティ
struct Collection: Identifiable, Codable {
    let id: String
    let userId: String
    var name: String
    var description: String?
    var coverImageURL: String?
    var postCount: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        userId: String,
        name: String,
        description: String? = nil,
        coverImageURL: String? = nil,
        postCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.description = description
        self.coverImageURL = coverImageURL
        self.postCount = postCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Firestore Mapping

    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "collectionId": id,
            "userId": userId,
            "name": name,
            "postCount": postCount,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt)
        ]

        if let description = description {
            data["description"] = description
        }

        if let coverImageURL = coverImageURL {
            data["coverImageURL"] = coverImageURL
        }

        return data
    }

    /// Firestoreドキュメントデータから初期化
    init(from documentData: [String: Any]) throws {
        guard let collectionId = documentData["collectionId"] as? String,
              let userId = documentData["userId"] as? String,
              let name = documentData["name"] as? String else {
            throw CollectionModelError.missingRequiredFields
        }

        self.id = collectionId
        self.userId = userId
        self.name = name
        self.description = documentData["description"] as? String
        self.coverImageURL = documentData["coverImageURL"] as? String
        self.postCount = documentData["postCount"] as? Int ?? 0

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

// MARK: - CollectionItem

/// コレクションアイテムエンティティ
struct CollectionItem: Identifiable, Codable {
    var id: String { "\(collectionId)_\(postId)" }
    let userId: String
    let collectionId: String
    let postId: String
    let createdAt: Date

    init(
        userId: String,
        collectionId: String,
        postId: String,
        createdAt: Date = Date()
    ) {
        self.userId = userId
        self.collectionId = collectionId
        self.postId = postId
        self.createdAt = createdAt
    }

    // MARK: - Firestore Mapping

    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        return [
            "userId": userId,
            "collectionId": collectionId,
            "postId": postId,
            "createdAt": Timestamp(date: createdAt)
        ]
    }

    /// Firestoreドキュメントデータから初期化
    init(from documentData: [String: Any]) throws {
        guard let userId = documentData["userId"] as? String,
              let collectionId = documentData["collectionId"] as? String,
              let postId = documentData["postId"] as? String else {
            throw CollectionItemModelError.missingRequiredFields
        }

        self.userId = userId
        self.collectionId = collectionId
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

// MARK: - CollectionModelError

enum CollectionModelError: LocalizedError {
    case missingRequiredFields
    case nameTooLong
    case nameEmpty

    var errorDescription: String? {
        switch self {
        case .missingRequiredFields:
            return "必須フィールドが不足しています"
        case .nameTooLong:
            return "コレクション名は50文字以内で入力してください"
        case .nameEmpty:
            return "コレクション名を入力してください"
        }
    }
}

// MARK: - CollectionItemModelError

enum CollectionItemModelError: LocalizedError {
    case missingRequiredFields

    var errorDescription: String? {
        switch self {
        case .missingRequiredFields:
            return "必須フィールドが不足しています"
        }
    }
}
