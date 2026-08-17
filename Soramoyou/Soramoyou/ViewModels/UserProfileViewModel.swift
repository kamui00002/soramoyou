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

    /// プロフィール本体とフォロー状態を並列ロードし、**フォロー状態が確定してから**投稿を取得する ⭐️
    ///
    /// 投稿クエリに渡す公開範囲（`visibility`）はフォロー状態で変わるため、
    /// `isFollowing` より先に投稿を取りに行くことはできない（並列にすると
    /// 未フォロー扱いのクエリを投げてしまい、フォロワー限定投稿が永久に出ない）。
    func load() async {
        isLoading = true
        defer { isLoading = false }

        // プロフィール本体とフォロー状態は互いに独立なので並列で取る
        async let profileTask = fetchPublicProfileSafe()
        async let followingTask = fetchIsFollowingSafe()

        let (profile, following) = await (profileTask, followingTask)
        self.publicProfile = profile
        self.isFollowing = following

        // フォロー状態が確定してから、閲覧できる公開範囲だけを絞って投稿を取得する
        self.posts = await fetchVisiblePostsSafe()
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

    /// 現在のフォロー状態で「読めると証明できる」公開範囲だけを絞って投稿を取得する ⭐️
    ///
    /// Firestore Security Rules はクエリの結果集合に対する **静的な証明** であり、
    /// 1 件でも読めない可能性があるとクエリ全体が permission-denied になる。
    /// 旧実装は `visibility` で絞らずに取得して手元で `.filter` していたため、
    /// private を含みうるクエリと判断されて他人のプロフィールでは常に denied ＝
    /// 投稿グリッドが空になっていた（欠陥 D）。
    private func fetchVisiblePostsSafe() async -> [Post] {
        // ⚠️ 未フォローの相手に ['public','followers'] を投げると 'followers' 枝が rules を
        //    満たせず「クエリ全体」が denied になり、公開投稿まで巻き添えで消える。
        //    そのため必ずフォロー状態で分岐し、証明できる範囲だけを要求する。
        let visibilities: [Visibility] = isFollowing ? [.public, .followers] : [.public]

        do {
            return try await firestoreService.fetchVisibleUserPosts(
                userId: targetUserId,
                visibilities: visibilities,
                limit: 50,
                lastDocument: nil
            )
        } catch {
            // ⚠️ 旧実装はここでエラーを握りつぶして [] を返していたため、
            //    「グリッドが常に空」という不具合が本番で見えないままだった。
            //    原因（権限・インデックス欠落）を必ずユーザーとログの両方に出す。
            logger.error("fetchVisibleUserPosts 失敗: \(error.localizedDescription)")
            errorMessage = error.userFriendlyMessage
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

            // フォロー状態が変わると閲覧できる範囲（フォロワー限定投稿）が変わるため、
            // フォロー時は増える／解除時は消える分を反映するために必ず再取得する。
            // 上で `isFollowing` を更新済みなので、新しい状態に対応した公開範囲で取得される。
            self.posts = await fetchVisiblePostsSafe()
        } catch {
            logger.error("toggleFollow 失敗: \(error.localizedDescription)")
            errorMessage = error.userFriendlyMessage
        }
    }
}
