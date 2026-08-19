//
//  User.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import FirebaseAuth
import FirebaseFirestore
import Foundation

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
    var blockedUserIds: [String]?
    /// フォロー中のハッシュタグ（"#" を含まない生の単語）⭐️
    ///
    /// ⚠️ 正規化（小文字化・トリム）は絶対にしない。`PostViewModel.extractHashtags` は
    ///    正規表現のキャプチャグループ（＝"#" を含まない生の単語）をそのまま
    ///    `posts.hashtags` に保存しており、Firestore の `arrayContains` は完全一致でしか
    ///    マッチしないため、ここで正規化すると既存投稿に当たらなくなる。
    ///    （"#" は表示側で付け直す規約。cf. ShareHashtagSuggester のコメント）
    /// 上限は `User.maxFollowedTags`（30件）。旧ユーザーはフィールド自体が無いので Optional。
    var followedTags: [String]?

    // MARK: プッシュ通知の配信プレフ（端末の通知許可とは別物。Cloud Functions が送信可否判定に読む）

    // ⚠️ 既定値は Cloud Functions 側のフィールド欠落フォールバックと必ず一致させること
    //    （reactions=true / following=true / everyone=false）。旧ユーザーは欠落＝既定で動く。
    var notifyReactions: Bool
    var notifyNewPostsFromFollowing: Bool
    var notifyNewPostsFromEveryone: Bool
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
        blockedUserIds: [String]? = nil,
        followedTags: [String]? = nil,
        notifyReactions: Bool = true,
        notifyNewPostsFromFollowing: Bool = true,
        notifyNewPostsFromEveryone: Bool = false,
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
        self.blockedUserIds = blockedUserIds
        self.followedTags = followedTags
        self.notifyReactions = notifyReactions
        self.notifyNewPostsFromFollowing = notifyNewPostsFromFollowing
        self.notifyNewPostsFromEveryone = notifyNewPostsFromEveryone
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from firebaseUser: FirebaseAuth.User) {
        id = firebaseUser.uid
        email = firebaseUser.email
        displayName = firebaseUser.displayName
        photoURL = firebaseUser.photoURL?.absoluteString
        bio = nil
        customEditTools = nil
        customEditToolsOrder = nil
        followersCount = 0
        followingCount = 0
        postsCount = 0
        blockedUserIds = nil
        followedTags = nil
        notifyReactions = true
        notifyNewPostsFromFollowing = true
        notifyNewPostsFromEveryone = false
        createdAt = Date()
        updatedAt = Date()
    }

    // MARK: - Firestore Mapping

    /// Firestoreドキュメントデータに変換
    /// 注意: firestore.rules が 'id' フィールドを期待するため、'id' をキーとして使用
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "id": id,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt),
        ]

        if let email {
            data["email"] = email
        }

        if let displayName {
            data["displayName"] = displayName
        }

        if let photoURL {
            data["photoURL"] = photoURL
        }

        if let bio {
            data["bio"] = bio
        }

        if let customEditTools {
            data["customEditTools"] = customEditTools
        }

        if let customEditToolsOrder {
            data["customEditToolsOrder"] = customEditToolsOrder
        }

        data["followersCount"] = followersCount
        data["followingCount"] = followingCount
        data["postsCount"] = postsCount

        // プッシュ通知の配信プレフ（常に書く。merge 書き込みでも欠落させない）
        data["notifyReactions"] = notifyReactions
        data["notifyNewPostsFromFollowing"] = notifyNewPostsFromFollowing
        data["notifyNewPostsFromEveryone"] = notifyNewPostsFromEveryone

        if let blockedUserIds {
            data["blockedUserIds"] = blockedUserIds
        }

        // フォロー中タグ ⭐️: followedTags はここでは書かない（読み取り専用）。
        // このフィールドは followTag/unfollowTag の arrayUnion/arrayRemove 専用で、
        // User 全体を setData(merge) する updateUser 経由で書くと、キャッシュ済みの旧配列が
        // サーバーの最新値を巻き戻してしまうため
        // （updateNotificationPreferences が field-scoped に切られているのと同じ理由）。

        return data
    }

    /// Firestoreドキュメントデータから初期化
    /// 注意: 'id' と 'userId' の両方をサポート（後方互換性のため）
    init(from documentData: [String: Any]) throws {
        // 'id' フィールドを優先、なければ 'userId' を使用（後方互換性）
        guard let userId = documentData["id"] as? String ?? documentData["userId"] as? String else {
            throw UserModelError.missingUserId
        }

        id = userId
        email = documentData["email"] as? String
        displayName = documentData["displayName"] as? String
        photoURL = documentData["photoURL"] as? String
        bio = documentData["bio"] as? String
        customEditTools = documentData["customEditTools"] as? [String]
        customEditToolsOrder = documentData["customEditToolsOrder"] as? [String]
        followersCount = documentData["followersCount"] as? Int ?? 0
        followingCount = documentData["followingCount"] as? Int ?? 0
        postsCount = documentData["postsCount"] as? Int ?? 0
        blockedUserIds = documentData["blockedUserIds"] as? [String]
        // 旧ユーザーは followedTags フィールド自体が無い（＝nil）。後方互換のため Optional のまま。
        followedTags = documentData["followedTags"] as? [String]
        // 旧ユーザーはフィールド欠落＝既定値（Cloud Functions 側の欠落フォールバックと一致）
        notifyReactions = documentData["notifyReactions"] as? Bool ?? true
        notifyNewPostsFromFollowing = documentData["notifyNewPostsFromFollowing"] as? Bool ?? true
        notifyNewPostsFromEveryone = documentData["notifyNewPostsFromEveryone"] as? Bool ?? false

        // TimestampからDateに変換
        if let createdAtTimestamp = documentData["createdAt"] as? Timestamp {
            createdAt = createdAtTimestamp.dateValue()
        } else {
            createdAt = Date()
        }

        if let updatedAtTimestamp = documentData["updatedAt"] as? Timestamp {
            updatedAt = updatedAtTimestamp.dateValue()
        } else {
            updatedAt = Date()
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

// MARK: - フォロー中タグの上限 ⭐️

extension User {
    /// フォローできるハッシュタグの最大数。
    ///
    /// 後続のタグフィードは Firestore の `array-contains-any` でまとめて引く想定で、
    /// このクエリ演算子の上限が 30 個であることに由来する。
    /// arrayUnion は配列長を見ないため、上限チェックは書き込み前に呼び出し側で行う。
    static let maxFollowedTags = 30
}

// MARK: - UserModelError

enum UserModelError: Error {
    case missingUserId
    case invalidData
}
