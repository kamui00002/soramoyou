//
//  FollowRepository.swift
//  Soramoyou
//
//  フォロー関係の Firestore アクセスを集約する Repository ⭐️ Issue #2
//
//  follows コレクションへの create/delete と、users.followersCount /
//  users.followingCount の増減を Firestore トランザクションで原子的に行う。
//

import Foundation
import FirebaseFirestore
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.soramoyou.photo-editor",
    category: "FollowRepository"
)

// MARK: - Protocol

protocol FollowRepositoryProtocol {
    /// targetUserId をフォローする（自分は ownUserId）
    func follow(_ targetUserId: String, by ownUserId: String) async throws

    /// targetUserId のフォローを解除する
    func unfollow(_ targetUserId: String, by ownUserId: String) async throws

    /// ownUserId が targetUserId をフォロー中か確認
    func isFollowing(_ targetUserId: String, by ownUserId: String) async throws -> Bool
}

// MARK: - Implementation

final class FollowRepository: FollowRepositoryProtocol {
    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    private var followsCollection: CollectionReference {
        db.collection("follows")
    }

    private var usersCollection: CollectionReference {
        db.collection("users")
    }

    // MARK: - follow

    func follow(_ targetUserId: String, by ownUserId: String) async throws {
        guard ownUserId != targetUserId else {
            throw FollowRepositoryError.cannotFollowSelf
        }

        let followId = Follow.makeId(followerId: ownUserId, followingId: targetUserId)
        let followRef = followsCollection.document(followId)
        let ownUserRef = usersCollection.document(ownUserId)
        let targetUserRef = usersCollection.document(targetUserId)

        // トランザクションで follows 追加 + カウンタ増加を原子的に行う
        _ = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                // 既にフォロー中なら何もしない（冪等性確保）
                let existing = try transaction.getDocument(followRef)
                if existing.exists {
                    return nil
                }

                let follow = Follow(
                    id: followId,
                    followerId: ownUserId,
                    followingId: targetUserId
                )
                transaction.setData(follow.toFirestoreData(), forDocument: followRef)

                // カウンタ更新（FieldValue.increment で安全にインクリメント）
                transaction.updateData(
                    ["followingCount": FieldValue.increment(Int64(1))],
                    forDocument: ownUserRef
                )
                transaction.updateData(
                    ["followersCount": FieldValue.increment(Int64(1))],
                    forDocument: targetUserRef
                )
                return nil
            } catch let err as NSError {
                errorPointer?.pointee = err
                return nil
            }
        }

        logger.info("フォロー成功 \(ownUserId, privacy: .private) -> \(targetUserId, privacy: .private)")
    }

    // MARK: - unfollow

    func unfollow(_ targetUserId: String, by ownUserId: String) async throws {
        let followId = Follow.makeId(followerId: ownUserId, followingId: targetUserId)
        let followRef = followsCollection.document(followId)
        let ownUserRef = usersCollection.document(ownUserId)
        let targetUserRef = usersCollection.document(targetUserId)

        _ = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                // 存在しないなら何もしない
                let existing = try transaction.getDocument(followRef)
                guard existing.exists else {
                    return nil
                }
                transaction.deleteDocument(followRef)

                // カウンタ減少（負にならないよう Cloud Function 等での集計が望ましいが、
                // ここでは UX 即時反映のためクライアント側でもデクリメント）
                transaction.updateData(
                    ["followingCount": FieldValue.increment(Int64(-1))],
                    forDocument: ownUserRef
                )
                transaction.updateData(
                    ["followersCount": FieldValue.increment(Int64(-1))],
                    forDocument: targetUserRef
                )
                return nil
            } catch let err as NSError {
                errorPointer?.pointee = err
                return nil
            }
        }

        logger.info("フォロー解除 \(ownUserId, privacy: .private) -> \(targetUserId, privacy: .private)")
    }

    // MARK: - isFollowing

    func isFollowing(_ targetUserId: String, by ownUserId: String) async throws -> Bool {
        let followId = Follow.makeId(followerId: ownUserId, followingId: targetUserId)
        let snapshot = try await followsCollection.document(followId).getDocument()
        return snapshot.exists
    }
}

// MARK: - Errors

enum FollowRepositoryError: LocalizedError {
    case cannotFollowSelf

    var errorDescription: String? {
        switch self {
        case .cannotFollowSelf:
            return "自分自身をフォローすることはできません"
        }
    }
}
