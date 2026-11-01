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
    /// 「そらとも通知」（友達グループの新着投稿の通知）⭐️
    ///
    /// 読み取り専用: `toFirestoreData()` では書かない（`followedTags` と同じ扱い）。
    /// 保存は `users/{uid}.notifySoratomo` だけを `updateData` で書く（そらとものプロフィールの窓口・tasks 11.5）。
    /// 未保存（旧ユーザー・未設定）は nil。実際に使う値は `notifySoratomoEnabled`（既定 ON）。
    var notifySoratomo: Bool?
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
        notifySoratomo: Bool? = nil,
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
        self.notifySoratomo = notifySoratomo
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
        notifySoratomo = nil
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

        // フォロー中タグ ⭐️: followedTags はここでは書かない（読み取り専用）。
        // このフィールドは followTag/unfollowTag の arrayUnion/arrayRemove 専用で、
        // User 全体を setData(merge) する updateUser 経由で書くと、キャッシュ済みの旧配列が
        // サーバーの最新値を巻き戻してしまうため
        // （updateNotificationPreferences が field-scoped に切られているのと同じ理由）。
        // そらとも通知 ⭐️: notifySoratomo も同じ理由でここでは書かない（読み取り専用）。
        // ブロックの一覧 ⭐️: blockedUserIds も同じ理由でここでは書かない（読み取り専用）。
        // 書くのは blockUser/unblockUser の arrayUnion/arrayRemove だけ。ここで書くと、
        // プロフィールを開いた後に足したブロックが保存で消える（空の配列なら全部消える）。

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
        // そらとも通知 ⭐️: 欠落・真偽値でないときは nil（＝既定の ON。Functions の読み方と同じ）
        notifySoratomo = documentData["notifySoratomo"] as? Bool

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

// MARK: - そらとも通知の既定値 ⭐️

extension User {
    /// 「そらとも通知」が未保存のときの扱い（ON・要件 9.14）
    ///
    /// ⚠️ Functions の `SORATOMO_PREF_DEFAULT`（functions/soratomoCore.js）と必ず一致させること。
    ///    食い違うと、設定画面には ON と出るのに通知が届かない（またはその逆）になる。
    ///    既存の 3 つの通知設定（functions/index.js の `PREF_DEFAULTS`）には混ぜず、
    ///    別の項目・別の既定値として持つ（要件 13.7）。
    static let notifySoratomoDefault = true

    /// 実際に使う「そらとも通知」の値（未保存なら既定の ON）
    var notifySoratomoEnabled: Bool {
        notifySoratomo ?? Self.notifySoratomoDefault
    }
}

// MARK: - プロフィール編集で消す項目 ⭐️

/// プロフィール編集で「消す」（Firestore のキーごと消す）ことのできる項目
///
/// ⚠️ 書き込みでは nil は「書かない＝前の値のまま」の意味になる（`toFirestoreData` は nil のキーを入れず、
///    users は `setData(merge: true)`・publicProfiles は `updateData`）。そのため表示名を空にしても、
///    アイコンを削除しても古い値が残っていた（自己紹介文と同じ穴・2026-11-01 にコードで確認）。
///    消したいときはこの型で明示し、`FieldValue.delete()` でキーごと消す。
///    読む側は「キーが無い」を新規ユーザーと同じく「ユーザー」と人型の印で出す（Android も同じ消し方）。
/// - Note: rawValue は users と publicProfiles の両方で同じキー名。
enum ProfileClearableField: String {
    case displayName
    case photoURL

    /// 書き込む内容に「消す」印（`FieldValue.delete()`）を足す
    ///
    /// ⚠️ merge の `setData` と `updateData` でだけ使うこと。merge なしの `setData`
    ///    （`createPublicProfile` など）に `FieldValue.delete()` を入れると、SDK が NSException を投げる。
    ///    Swift の do/catch では捕まえられず、その場でアプリが落ちる。
    /// - Parameters:
    ///   - fields: 消す項目
    ///   - data: 書き込む内容
    /// - Returns: 消す項目に `FieldValue.delete()` を入れた内容。値が入っている項目は消さない（値を優先する）
    static func applyingDeletes(_ fields: Set<ProfileClearableField>, to data: [String: Any]) -> [String: Any] {
        var result = data
        // 値が入っている項目は消さない（同じ書き込みで「値を書く」と「消す」がぶつからないように）
        for field in fields where result[field.rawValue] == nil {
            result[field.rawValue] = FieldValue.delete()
        }
        return result
    }
}

// MARK: - UserModelError

enum UserModelError: Error {
    case missingUserId
    case invalidData
}
