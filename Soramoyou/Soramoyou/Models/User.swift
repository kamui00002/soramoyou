//
//  User.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import FirebaseAuth

struct User: Identifiable, Codable {
    let id: String
    let email: String?
    let displayName: String?
    let photoURL: String?
    let bio: String?
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
}

