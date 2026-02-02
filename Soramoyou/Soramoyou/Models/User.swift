//
//  User.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

struct User: Identifiable, Codable {
    let id: String
    let email: String?
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
        email: String? = nil,
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
        self.email = email
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
    
    init(from firebaseUser: FirebaseAuth.User) {
        self.id = firebaseUser.uid
        self.email = firebaseUser.email
        self.displayName = firebaseUser.displayName
        self.photoURL = firebaseUser.photoURL?.absoluteString
        self.bio = nil
        self.customEditTools = nil
        self.customEditToolsOrder = nil
        self.followersCount = 0
        self.followingCount = 0
        self.postsCount = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    // MARK: - Firestore Mapping
    
    /// Firestoreドキュメントデータに変換
    /// 注意: firestore.rules が 'id' フィールドを期待するため、'id' をキーとして使用
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "id": id,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt)
        ]

        if let email = email {
            data["email"] = email
        }
        
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
    /// 注意: 'id' と 'userId' の両方をサポート（後方互換性のため）
    init(from documentData: [String: Any]) throws {
        // 'id' フィールドを優先、なければ 'userId' を使用（後方互換性）
        guard let userId = documentData["id"] as? String ?? documentData["userId"] as? String else {
            throw UserModelError.missingUserId
        }

        self.id = userId
        self.email = documentData["email"] as? String
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

// MARK: - UserModelError

enum UserModelError: Error {
    case missingUserId
    case invalidData
}

