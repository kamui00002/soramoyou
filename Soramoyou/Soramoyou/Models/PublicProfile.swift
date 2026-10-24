//
//  PublicProfile.swift
//  Soramoyou
//
//  公開プロフィール情報（機密情報を含まない）
//  セキュリティ: email, blockedUserIds等の機密情報はUserモデルで管理
//

import FirebaseFirestore
import Foundation

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
    /// 私のおすすめの空 ⭐️（表示順の postId 配列・最大 `RecommendedSkies.maxCount` 件）
    ///
    /// 自分・他の人どちらの公開投稿も入れられる。旧データ（フィールド無し）は空配列として読む。
    /// ⚠️ 書き込みは `addRecommendedPost` / `removeRecommendedPosts` / `moveRecommendedPost` だけで行う
    ///    （PublicProfile 全体を書く経路で古い値に巻き戻さないため）。
    var recommendedPostIds: [String]
    /// プロフィールの見せる/見せない ⭐️（おすすめの空・空カレンダー・お気に入りの空）
    ///
    /// 項目が無い人（今いる人全員）は `ProfileSectionVisibility.default`＝おすすめ＝見せる・カレンダー＝見せない・お気に入り＝見せない。
    /// ⚠️ 書き込みは `updateProfileSectionVisibility` だけ（変えた欄だけを updateData）。`toFirestoreData()` には入れない
    ///    （丸ごと上書きの道 `createPublicProfile` で値が消えても、既定値＝閉じる側に戻るだけにするため）。
    var sectionVisibility: ProfileSectionVisibility
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
        recommendedPostIds: [String] = [],
        sectionVisibility: ProfileSectionVisibility = .default,
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
        self.recommendedPostIds = recommendedPostIds
        self.sectionVisibility = sectionVisibility
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Userモデルから公開プロフィールを生成
    init(from user: User) {
        id = user.id
        displayName = user.displayName
        photoURL = user.photoURL
        bio = user.bio
        customEditTools = user.customEditTools
        customEditToolsOrder = user.customEditToolsOrder
        followersCount = user.followersCount
        followingCount = user.followingCount
        postsCount = user.postsCount
        // おすすめの空は publicProfiles にしか無い（users には持たない）
        recommendedPostIds = []
        // 見せる/見せない も publicProfiles にしか無い（users には持たない）→ 既定値
        sectionVisibility = .default
        createdAt = user.createdAt
        updatedAt = user.updatedAt
    }

    // MARK: - Firestore Mapping

    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "id": id,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt),
        ]

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

        // 空のときはキーごと書かない（旧データと同じ形を保つ）
        if !recommendedPostIds.isEmpty {
            data["recommendedPostIds"] = recommendedPostIds
        }

        // ⚠️ sectionVisibility（showsRecommendedSkies など 3 項目）は意図して書かない ⭐️
        //    これは丸ごと上書き（createPublicProfile の setData）にも使われるので、ここに入れると
        //    手元の古い値で本人の選んだ値を巻き戻しうる。書くのは updateProfileSectionVisibility だけ。

        return data
    }

    /// Firestoreドキュメントデータから初期化
    init(from documentData: [String: Any]) throws {
        guard let userId = documentData["id"] as? String else {
            throw PublicProfileError.missingUserId
        }

        id = userId
        displayName = documentData["displayName"] as? String
        photoURL = documentData["photoURL"] as? String
        bio = documentData["bio"] as? String
        customEditTools = documentData["customEditTools"] as? [String]
        customEditToolsOrder = documentData["customEditToolsOrder"] as? [String]
        followersCount = documentData["followersCount"] as? Int ?? 0
        followingCount = documentData["followingCount"] as? Int ?? 0
        postsCount = documentData["postsCount"] as? Int ?? 0
        // 旧データ（フィールド無し）・型違いは空配列として扱う
        recommendedPostIds = RecommendedSkies.normalized(documentData["recommendedPostIds"] as? [String] ?? [])
        // 見せる/見せない ⭐️: 項目が無い（今いる人全員）・型違い（"true" の文字列など）は既定値として読む。
        // ルール（isValidProfileVisibility）は「無い or bool」しか書かせないが、ルール以前のデータや独自クライアントに備える
        let defaultVisibility = ProfileSectionVisibility.default
        sectionVisibility = ProfileSectionVisibility(
            showsRecommendedSkies: documentData[ProfileSection.recommendedSkies.firestoreField] as? Bool
                ?? defaultVisibility.showsRecommendedSkies,
            showsSkyCalendar: documentData[ProfileSection.skyCalendar.firestoreField] as? Bool
                ?? defaultVisibility.showsSkyCalendar,
            showsFavorites: documentData[ProfileSection.favorites.firestoreField] as? Bool
                ?? defaultVisibility.showsFavorites
        )

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

    /// Firestore ドキュメントデータから初期化し、中の `id` がドキュメント ID（＝持ち主の uid）と一致するか確かめる ⭐️
    ///
    /// ⚠️ 中の `id` だけを信じると、自分のドキュメントに他人の uid を書いた人が、
    ///    他人の投稿に自分の名前・アバターを付けて見せられる（呼び出し側は `profile.id` を辞書のキーにするため・issue #133）。
    ///    rules でも作成時に一致を強制しているが、独自クライアントや rules 以前のデータに備えて読み込みでも弾く。
    /// - Parameter documentId: 読み込んだドキュメントの ID（`publicProfiles/{userId}` の userId）
    init(from documentData: [String: Any], documentId: String) throws {
        try self.init(from: documentData)
        guard id == documentId else {
            throw PublicProfileError.idMismatch
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
    /// 中の `id` がドキュメント ID と一致しない（なりすましの疑い）
    case idMismatch
}
