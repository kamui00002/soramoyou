//
//  UserModelTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore
import FirebaseAuth

final class UserModelTests: XCTestCase {
    
    func testUserInitialization() {
        // Given
        let userId = "test-user-id"
        let email = "test@example.com"
        let displayName = "Test User"
        
        // When
        let user = User(
            id: userId,
            email: email,
            displayName: displayName,
            bio: "Test bio",
            customEditTools: ["brightness", "contrast"],
            customEditToolsOrder: ["brightness", "contrast"],
            followersCount: 10,
            followingCount: 5,
            postsCount: 3
        )
        
        // Then
        XCTAssertEqual(user.id, userId)
        XCTAssertEqual(user.email, email)
        XCTAssertEqual(user.displayName, displayName)
        XCTAssertEqual(user.bio, "Test bio")
        XCTAssertEqual(user.customEditTools, ["brightness", "contrast"])
        XCTAssertEqual(user.customEditToolsOrder, ["brightness", "contrast"])
        XCTAssertEqual(user.followersCount, 10)
        XCTAssertEqual(user.followingCount, 5)
        XCTAssertEqual(user.postsCount, 3)
    }
    
    func testUserDefaultValues() {
        // Given & When
        let user = User(
            id: "firebase-uid",
            email: "firebase@example.com",
            displayName: "Firebase User"
        )
        
        // Then
        XCTAssertEqual(user.id, "firebase-uid")
        XCTAssertEqual(user.email, "firebase@example.com")
        XCTAssertEqual(user.displayName, "Firebase User")
        XCTAssertEqual(user.followersCount, 0)
        XCTAssertEqual(user.followingCount, 0)
        XCTAssertEqual(user.postsCount, 0)
        XCTAssertNil(user.bio)
        XCTAssertNil(user.photoURL)
        XCTAssertNil(user.customEditTools)
        XCTAssertNil(user.customEditToolsOrder)
    }
    
    func testUserCodable() throws {
        // Given
        let user = User(
            id: "test-id",
            email: "test@example.com",
            displayName: "Test User",
            bio: "Test bio",
            customEditTools: ["brightness"],
            customEditToolsOrder: ["brightness"]
        )
        
        // When
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(user)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedUser = try decoder.decode(User.self, from: data)
        
        // Then
        XCTAssertEqual(decodedUser.id, user.id)
        XCTAssertEqual(decodedUser.email, user.email)
        XCTAssertEqual(decodedUser.displayName, user.displayName)
        XCTAssertEqual(decodedUser.bio, user.bio)
        XCTAssertEqual(decodedUser.customEditTools, user.customEditTools)
        XCTAssertEqual(decodedUser.customEditToolsOrder, user.customEditToolsOrder)
    }
    
    func testUserToFirestoreDocument() {
        // Given
        let user = User(
            id: "test-id",
            email: "test@example.com",
            displayName: "Test User",
            photoURL: "https://example.com/photo.jpg",
            bio: "Test bio",
            customEditTools: ["brightness", "contrast"],
            customEditToolsOrder: ["brightness", "contrast"],
            followersCount: 10,
            followingCount: 5,
            postsCount: 3
        )
        
        // When
        let documentData = user.toFirestoreData()
        
        // Then
        XCTAssertEqual(documentData["userId"] as? String, "test-id")
        XCTAssertEqual(documentData["email"] as? String, "test@example.com")
        XCTAssertEqual(documentData["displayName"] as? String, "Test User")
        XCTAssertEqual(documentData["photoURL"] as? String, "https://example.com/photo.jpg")
        XCTAssertEqual(documentData["bio"] as? String, "Test bio")
        XCTAssertEqual(documentData["customEditTools"] as? [String], ["brightness", "contrast"])
        XCTAssertEqual(documentData["customEditToolsOrder"] as? [String], ["brightness", "contrast"])
        XCTAssertEqual(documentData["followersCount"] as? Int, 10)
        XCTAssertEqual(documentData["followingCount"] as? Int, 5)
        XCTAssertEqual(documentData["postsCount"] as? Int, 3)
        XCTAssertNotNil(documentData["createdAt"] as? Timestamp)
        XCTAssertNotNil(documentData["updatedAt"] as? Timestamp)
    }
    
    func testUserFromFirestoreDocument() throws {
        // Given
        let timestamp = Timestamp(date: Date())
        let documentData: [String: Any] = [
            "userId": "test-id",
            "email": "test@example.com",
            "displayName": "Test User",
            "photoURL": "https://example.com/photo.jpg",
            "bio": "Test bio",
            "customEditTools": ["brightness", "contrast"],
            "customEditToolsOrder": ["brightness", "contrast"],
            "followersCount": 10,
            "followingCount": 5,
            "postsCount": 3,
            "createdAt": timestamp,
            "updatedAt": timestamp
        ]
        
        // When
        let user = try User(from: documentData)
        
        // Then
        XCTAssertEqual(user.id, "test-id")
        XCTAssertEqual(user.email, "test@example.com")
        XCTAssertEqual(user.displayName, "Test User")
        XCTAssertEqual(user.photoURL, "https://example.com/photo.jpg")
        XCTAssertEqual(user.bio, "Test bio")
        XCTAssertEqual(user.customEditTools, ["brightness", "contrast"])
        XCTAssertEqual(user.customEditToolsOrder, ["brightness", "contrast"])
        XCTAssertEqual(user.followersCount, 10)
        XCTAssertEqual(user.followingCount, 5)
        XCTAssertEqual(user.postsCount, 3)
    }
    
    func testUserFromFirestoreDocumentWithMissingFields() throws {
        // Given - 最小限のフィールドのみ
        let timestamp = Timestamp(date: Date())
        let documentData: [String: Any] = [
            "userId": "test-id",
            "email": "test@example.com",
            "createdAt": timestamp,
            "updatedAt": timestamp
        ]
        
        // When
        let user = try User(from: documentData)
        
        // Then
        XCTAssertEqual(user.id, "test-id")
        XCTAssertEqual(user.email, "test@example.com")
        XCTAssertNil(user.displayName)
        XCTAssertNil(user.photoURL)
        XCTAssertNil(user.bio)
        XCTAssertNil(user.customEditTools)
        XCTAssertNil(user.customEditToolsOrder)
        XCTAssertEqual(user.followersCount, 0)
        XCTAssertEqual(user.followingCount, 0)
        XCTAssertEqual(user.postsCount, 0)
    }

    // MARK: - プッシュ通知の配信プレフ

    /// 旧ユーザー（通知プレフのキーが無い）でも壊れず、既定値で読めること。
    /// Cloud Functions 側の欠落フォールバックと一致（reactions=true / following=true / everyone=false）。
    func testNotificationPreferencesDefaultWhenMissing() throws {
        // Given - 通知プレフのキーが無い documentData
        let timestamp = Timestamp(date: Date())
        let documentData: [String: Any] = [
            "id": "old-user",
            "createdAt": timestamp,
            "updatedAt": timestamp
        ]

        // When
        let user = try User(from: documentData)

        // Then - 既定値で読める
        XCTAssertTrue(user.notifyReactions)
        XCTAssertTrue(user.notifyNewPostsFromFollowing)
        XCTAssertFalse(user.notifyNewPostsFromEveryone)
    }

    /// 明示的な値が読み込み・書き出しで保たれること（送信側が読むため toFirestoreData に必ず出る）。
    func testNotificationPreferencesRoundTrip() throws {
        // Given - 既定と異なる値を持つ documentData
        let timestamp = Timestamp(date: Date())
        let documentData: [String: Any] = [
            "id": "user-2",
            "createdAt": timestamp,
            "updatedAt": timestamp,
            "notifyReactions": false,
            "notifyNewPostsFromFollowing": false,
            "notifyNewPostsFromEveryone": true
        ]

        // When
        let user = try User(from: documentData)

        // Then - 明示値が反映される
        XCTAssertFalse(user.notifyReactions)
        XCTAssertFalse(user.notifyNewPostsFromFollowing)
        XCTAssertTrue(user.notifyNewPostsFromEveryone)

        // toFirestoreData が3キーを書き出す（Cloud Functions が送信可否判定に読む）
        let out = user.toFirestoreData()
        XCTAssertEqual(out["notifyReactions"] as? Bool, false)
        XCTAssertEqual(out["notifyNewPostsFromFollowing"] as? Bool, false)
        XCTAssertEqual(out["notifyNewPostsFromEveryone"] as? Bool, true)
    }
}

