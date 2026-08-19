//
//  FollowRepository.swift
//  Soramoyou
//
//  フォロー関係の Firestore アクセスを集約する Repository ⭐️ Issue #2
//
//  follows コレクションへの create/delete「だけ」を行う。
//  followersCount / followingCount は Cloud Functions（onFollowCreated /
//  onFollowDeleted）が follows を count() して users・publicProfiles の両方へ
//  「代入」する方式に変更したため、クライアントからはカウンタを一切書かない。
//  （クライアントが increment すると Functions の代入と二重計上になり、
//   さらに publicProfiles 側は所有者しか書けないため他人からは 0 のままだった）
//

import Foundation

// Firebase SDK は Swift 6 strict concurrency 下で `Firestore` を非 Sendable と扱うため、
// `@preconcurrency` で互換モードを宣言する（rules/swift.md「サードパーティの非 Sendable
// 型には @preconcurrency import で段階的に対応」に準拠）。
@preconcurrency import FirebaseFirestore
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.soramoyou.photo-editor",
    category: "FollowRepository"
)

// MARK: - Protocol

/// Sendable に準拠することで `@MainActor` な ViewModel から越境して
/// 安全に呼び出せる。Swift 6 strict concurrency 対応。
protocol FollowRepositoryProtocol: Sendable {
    /// targetUserId をフォローする（自分は ownUserId）
    func follow(_ targetUserId: String, by ownUserId: String) async throws

    /// targetUserId のフォローを解除する
    func unfollow(_ targetUserId: String, by ownUserId: String) async throws

    /// ownUserId が targetUserId をフォロー中か確認
    func isFollowing(_ targetUserId: String, by ownUserId: String) async throws -> Bool

    /// userId のフォロワー（userId をフォローしているユーザー）を新しい順にページング取得
    /// - Returns: フォロー関係と、次ページ取得に使う最後のドキュメント
    func fetchFollowers(
        of userId: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> (follows: [Follow], lastDocument: DocumentSnapshot?)

    /// userId がフォロー中のユーザーを新しい順にページング取得
    /// - Returns: フォロー関係と、次ページ取得に使う最後のドキュメント
    func fetchFollowing(
        of userId: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> (follows: [Follow], lastDocument: DocumentSnapshot?)

    /// 自分（ownUserId）のフォロワーから followerUserId を外す
    ///
    /// unfollow との違いはドキュメント ID の向きだけ:
    /// unfollow = "{自分}_{相手}" を消す ／ removeFollower = "{相手}_{自分}" を消す。
    /// rules 側は followeeId == request.auth.uid の delete 許可が必要（PR-5 で追加）。
    func removeFollower(_ followerUserId: String, from ownUserId: String) async throws
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

    // MARK: - follow

    func follow(_ targetUserId: String, by ownUserId: String) async throws {
        guard ownUserId != targetUserId else {
            throw FollowRepositoryError.cannotFollowSelf
        }

        let followId = Follow.makeId(followerId: ownUserId, followeeId: targetUserId)
        let followRef = followsCollection.document(followId)

        // トランザクションは follows の「存在確認 → 作成」だけを原子的に行う。
        // カウンタはここでは触らない（Cloud Functions が count() の結果を代入する）。
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
                    followeeId: targetUserId
                )
                transaction.setData(follow.toFirestoreData(), forDocument: followRef)
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
        let followId = Follow.makeId(followerId: ownUserId, followeeId: targetUserId)
        let followRef = followsCollection.document(followId)

        // トランザクションは follows の「存在確認 → 削除」だけを原子的に行う。
        // カウンタはここでは触らない（Cloud Functions が count() の結果を代入するので、
        // 負の値になったりフォロワー削除と食い違ったりしない）。
        _ = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                // 存在しないなら何もしない
                let existing = try transaction.getDocument(followRef)
                guard existing.exists else {
                    return nil
                }
                transaction.deleteDocument(followRef)
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
        let followId = Follow.makeId(followerId: ownUserId, followeeId: targetUserId)
        let snapshot = try await followsCollection.document(followId).getDocument()
        return snapshot.exists
    }

    // MARK: - fetchFollowers / fetchFollowing

    func fetchFollowers(
        of userId: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> (follows: [Follow], lastDocument: DocumentSnapshot?) {
        try await fetchFollows(
            field: "followeeId",
            equalTo: userId,
            limit: limit,
            lastDocument: lastDocument
        )
    }

    func fetchFollowing(
        of userId: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> (follows: [Follow], lastDocument: DocumentSnapshot?) {
        try await fetchFollows(
            field: "followerId",
            equalTo: userId,
            limit: limit,
            lastDocument: lastDocument
        )
    }

    /// follows を「等値フィルタ + createdAt 降順」でページング取得する共通実装
    ///
    /// 複合インデックス `followerId+createdAt DESC` / `followeeId+createdAt DESC` は
    /// PR-2（#85）で deploy 済み。
    private func fetchFollows(
        field: String,
        equalTo userId: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> (follows: [Follow], lastDocument: DocumentSnapshot?) {
        var query: Query = followsCollection
            .whereField(field, isEqualTo: userId)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)

        // ページネーション: 前ページの最後のドキュメントの続きから取得
        if let lastDocument {
            query = query.start(afterDocument: lastDocument)
        }

        let snapshot = try await query.getDocuments()

        // ⚠️ 壊れたドキュメントを無言で落とさない（tech-spec.md の方針）。
        //    パスをログに残したうえでその1件だけスキップし、一覧全体は生かす。
        let follows = snapshot.documents.compactMap { document -> Follow? in
            if let follow = Follow(from: document) {
                return follow
            }
            logger.error("フォロードキュメントのデコード失敗 path=\(document.reference.path)")
            return nil
        }

        // 次ページの起点は「デコード成否に関わらず実際に読んだ最後のドキュメント」。
        // follows.last 由来にするとスキップした壊れたドキュメントで無限ループになる。
        return (follows: follows, lastDocument: snapshot.documents.last)
    }

    // MARK: - removeFollower

    func removeFollower(_ followerUserId: String, from ownUserId: String) async throws {
        // ドキュメント ID は「フォローしている側_されている側」。
        // フォロワー削除では相手（followerUserId）がフォローしている側になる。
        let followId = Follow.makeId(followerId: followerUserId, followeeId: ownUserId)
        let followRef = followsCollection.document(followId)

        // unfollow と同じ「存在確認 → 削除」の原子操作。
        // 存在しないドキュメントの delete は rules の resource.data 評価で
        // permission-denied になり得るため、必ず存在確認を先に行う。
        // カウンタは触らない（Cloud Functions の onFollowDeleted が count() を代入する）。
        _ = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let existing = try transaction.getDocument(followRef)
                guard existing.exists else {
                    return nil
                }
                transaction.deleteDocument(followRef)
                return nil
            } catch let err as NSError {
                errorPointer?.pointee = err
                return nil
            }
        }

        logger.info("フォロワー削除 \(followerUserId, privacy: .private) を \(ownUserId, privacy: .private) から")
    }
}

// MARK: - Errors

enum FollowRepositoryError: LocalizedError {
    case cannotFollowSelf

    var errorDescription: String? {
        switch self {
        case .cannotFollowSelf:
            "自分自身をフォローすることはできません"
        }
    }
}
