//
//  UserProfileViewModel.swift
//  Soramoyou
//
//  他ユーザーのプロフィール画面用 ViewModel ⭐️ Issue #2
//

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.soramoyou.photo-editor",
    category: "UserProfileViewModel"
)

@MainActor
class UserProfileViewModel: ObservableObject {

    // MARK: - Published State

    /// 他ユーザーから読める公開プロフィール（users コレクションは
    /// `isOwner` 制限のため他人のドキュメントは取得不可。`publicProfiles`
    /// コレクションを使う）⭐️
    @Published var publicProfile: PublicProfile?
    @Published var posts: [Post] = []
    @Published var isFollowing: Bool = false
    @Published var isLoading: Bool = false
    @Published var isFollowOperationInFlight: Bool = false
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let targetUserId: String
    private let ownUserId: String?
    private let firestoreService: FirestoreServiceProtocol
    private let followRepository: FollowRepositoryProtocol

    var isOwnProfile: Bool {
        ownUserId == targetUserId
    }

    init(
        targetUserId: String,
        ownUserId: String?,
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        followRepository: FollowRepositoryProtocol = FollowRepository()
    ) {
        self.targetUserId = targetUserId
        self.ownUserId = ownUserId
        self.firestoreService = firestoreService
        self.followRepository = followRepository
    }

    // MARK: - Loading

    /// プロフィール本体・投稿一覧・フォロー状態を並列ロード
    func load() async {
        isLoading = true
        defer { isLoading = false }

        async let profileTask = fetchPublicProfileSafe()
        async let postsTask = fetchPostsSafe()
        async let followingTask = fetchIsFollowingSafe()

        let (profile, posts, following) = await (profileTask, postsTask, followingTask)
        self.publicProfile = profile
        // 公開投稿のみ表示（他ユーザーから見るのは原則 public のみ）
        self.posts = posts.filter { $0.visibility == .public }
        self.isFollowing = following
    }

    /// 他ユーザーの公開プロフィールを取得する。
    /// `users` コレクションは Firestore Security Rules で `isOwner` 制限が
    /// かかっており、自分以外のドキュメントは読めないため
    /// `publicProfiles/{userId}` 経由で取得する。
    private func fetchPublicProfileSafe() async -> PublicProfile? {
        do {
            return try await firestoreService.fetchPublicProfile(userId: targetUserId)
        } catch {
            logger.error("fetchPublicProfile 失敗: \(error.localizedDescription)")
            errorMessage = error.userFriendlyMessage
            return nil
        }
    }

    private func fetchPostsSafe() async -> [Post] {
        do {
            return try await firestoreService.fetchUserPosts(
                userId: targetUserId,
                limit: 50,
                lastDocument: nil
            )
        } catch {
            logger.error("fetchUserPosts 失敗: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchIsFollowingSafe() async -> Bool {
        guard let ownUserId = ownUserId, ownUserId != targetUserId else { return false }
        do {
            return try await followRepository.isFollowing(targetUserId, by: ownUserId)
        } catch {
            logger.error("isFollowing 失敗: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Follow / Unfollow

    /// フォローボタン押下時の動作（既にフォロー中なら解除、でなければフォロー）
    func toggleFollow() async {
        guard let ownUserId = ownUserId else {
            errorMessage = "ログインが必要です"
            return
        }
        guard ownUserId != targetUserId else {
            errorMessage = "自分自身をフォローすることはできません"
            return
        }
        guard !isFollowOperationInFlight else { return }

        isFollowOperationInFlight = true
        defer { isFollowOperationInFlight = false }

        do {
            if isFollowing {
                try await followRepository.unfollow(targetUserId, by: ownUserId)
                isFollowing = false
                if var p = publicProfile {
                    p.followersCount = max(0, p.followersCount - 1)
                    publicProfile = p
                }
            } else {
                try await followRepository.follow(targetUserId, by: ownUserId)
                isFollowing = true
                if var p = publicProfile {
                    p.followersCount += 1
                    publicProfile = p
                }
            }
        } catch {
            logger.error("toggleFollow 失敗: \(error.localizedDescription)")
            errorMessage = error.userFriendlyMessage
        }
    }
}
