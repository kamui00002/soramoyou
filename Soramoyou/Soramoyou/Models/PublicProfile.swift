//
//  PublicProfile.swift
//  Soramoyou
//
//  公開プロフィール情報（機密情報を含まない）
//  セキュリティ: email, blockedUserIds等の機密情報はUserモデルで管理
//

import Foundation
import FirebaseFirestore

/// 公開プロフィール情報（他のユーザーから閲覧可能）
struct PublicProfile: Identifiable, Codable {
    let id: String
    var displayName: String?
    var photoURL: String?
    var bio: String?
    var customEditTools: [String]?
    var customEditToolsOrder: [String]?
    var followersCount: Int
    var followingCount: Int
    var postsCount: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        displayName: String? = nil,
        photoURL: String? = nil,
        bio: String? = nil,
        customEditTools: [String]? = nil,
        customEditToolsOrder: [String]? = nil,
        followersCount: Int = 0,
        followingCount: Int = 0,
        postsCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.photoURL = photoURL
        self.bio = bio
        self.customEditTools = customEditTools
        self.customEditToolsOrder = customEditToolsOrder
        self.followersCount = followersCount
        self.followingCount = followingCount
        self.postsCount = postsCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Userモデルから公開プロフィールを生成
    init(from user: User) {
        self.id = user.id
        self.displayName = user.displayName
        self.photoURL = user.photoURL
        self.bio = user.bio
        self.customEditTools = user.customEditTools
        self.customEditToolsOrder = user.customEditToolsOrder
        self.followersCount = user.followersCount
        self.followingCount = user.followingCount
        self.postsCount = user.postsCount
        self.createdAt = user.createdAt
        self.updatedAt = user.updatedAt
    }

    // MARK: - Firestore Mapping

    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "id": id,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt)
        ]

        if let displayName = displayName {
            data["displayName"] = displayName
        }

        if let photoURL = photoURL {
            data["photoURL"] = photoURL
        }

        if let bio = bio {
            data["bio"] = bio
        }

        if let customEditTools = customEditTools {
            data["customEditTools"] = customEditTools
        }

        if let customEditToolsOrder = customEditToolsOrder {
            data["customEditToolsOrder"] = customEditToolsOrder
        }

        data["followersCount"] = followersCount
        data["followingCount"] = followingCount
        data["postsCount"] = postsCount

        return data
    }

    /// Firestoreドキュメントデータから初期化
    init(from documentData: [String: Any]) throws {
        guard let userId = documentData["id"] as? String else {
            throw PublicProfileError.missingUserId
        }

        self.id = userId
        self.displayName = documentData["displayName"] as? String
        self.photoURL = documentData["photoURL"] as? String
        self.bio = documentData["bio"] as? String
        self.customEditTools = documentData["customEditTools"] as? [String]
        self.customEditToolsOrder = documentData["customEditToolsOrder"] as? [String]
        self.followersCount = documentData["followersCount"] as? Int ?? 0
        self.followingCount = documentData["followingCount"] as? Int ?? 0
        self.postsCount = documentData["postsCount"] as? Int ?? 0

        // TimestampからDateに変換
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

// MARK: - PublicProfileError

enum PublicProfileError: Error {
    case missingUserId
    case invalidData
}
