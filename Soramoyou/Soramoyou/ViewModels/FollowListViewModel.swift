//
//  FollowListViewModel.swift
//  Soramoyou
//
//  フォロワー / フォロー中一覧の ViewModel ⭐️ Issue #2（PR-5）
//
//  follows をページング取得 → 表示対象の uid 群 → publicProfiles を並列一括取得、
//  という 2 段構え。並列取得は HomeViewModel.fetchAuthorsForCurrentPosts の
//  withTaskGroup パターンを踏襲する（N+1 リクエスト回避）。
//
//  ⚠️ `users` コレクションは rules の isOwner 制限で他人の分は読めないため、
//     表示名・アバターは必ず `publicProfiles` から取る（docs/pre-release-checklist.md §2）。
//

import Foundation

// Firebase SDK は Swift 6 strict concurrency 下で非 Sendable 型を含むため
// @preconcurrency で互換モードを宣言する（FollowRepository と同方針）
@preconcurrency import FirebaseFirestore
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.soramoyou.photo-editor",
    category: "FollowListViewModel"
)

/// 一覧の種別（フォロワー / フォロー中）
enum FollowListType: String {
    /// targetUserId を「フォローしている」ユーザーの一覧
    case followers
    /// targetUserId が「フォローしている」ユーザーの一覧
    case following

    /// ナビゲーションタイトル
    var title: String {
        switch self {
        case .followers: "フォロワー"
        case .following: "フォロー中"
        }
    }
}

/// フォロワー / フォロー中一覧の ViewModel
@MainActor
final class FollowListViewModel: ObservableObject {
    // MARK: - Published State

    /// 取得済みのフォロー関係（作成日時の降順）
    @Published var follows: [Follow] = []
    /// 表示用プロフィール（userId -> PublicProfile）
    @Published var profilesByUserId: [String: PublicProfile] = [:]
    /// 初回ロード中
    @Published var isLoading = false
    /// 追加ページ取得中
    @Published var isLoadingMore = false
    /// まだ次ページがあるか
    @Published var hasMore = true
    /// 初回ロードの失敗（ErrorStateView 表示用）
    @Published var lastError: Error?
    /// フォロワー削除などの操作エラー（アラート表示用）
    @Published var errorMessage: String?
    /// フォロワー削除の実行中（多重タップ防止）
    @Published var isRemovingFollower = false
    /// 閲覧者自身がフォロー中のユーザー uid 集合（フォローバック表示の判定に使う）⭐️
    ///
    /// 行ごとに `isFollowing` を叩くと N+1 リクエストになるため、
    /// 自分のフォロー中一覧を 1 度だけ取って集合にしておく。
    @Published private(set) var followingUserIds: Set<String> = []
    /// フォロー状態を切り替え中の uid（そのボタンだけ無効化して多重タップを防ぐ）
    @Published private(set) var togglingUserIds: Set<String> = []

    // MARK: - Dependencies

    /// 一覧の種別
    let listType: FollowListType
    /// 誰の一覧か
    let targetUserId: String
    /// 閲覧者自身の userId（未ログインなら nil）
    let ownUserId: String?

    private let followRepository: FollowRepositoryProtocol
    private let firestoreService: FirestoreServiceProtocol
    /// 自分のフォロー中集合を読むときのページ数上限（= pageSize × この値が判定できる上限）
    private static let maxOwnFollowingPages = 5
    /// 1 ページあたりの件数（テストとページング手動検証のため注入可能にする）
    private let pageSize: Int
    private var lastDocument: DocumentSnapshot?

    /// 「自分のフォロワー一覧」か（フォロワー削除ボタンはこの場合のみ出す）
    var isOwnFollowersList: Bool {
        listType == .followers && ownUserId != nil && ownUserId == targetUserId
    }

    // MARK: - Initializer

    init(
        listType: FollowListType,
        targetUserId: String,
        ownUserId: String?,
        followRepository: FollowRepositoryProtocol = FollowRepository(),
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        pageSize: Int = 30
    ) {
        self.listType = listType
        self.targetUserId = targetUserId
        self.ownUserId = ownUserId
        self.followRepository = followRepository
        self.firestoreService = firestoreService
        self.pageSize = pageSize
    }

    // MARK: - 表示ヘルパー

    /// 一覧の行として表示するユーザーの uid
    ///
    /// フォロワー一覧なら「フォローしてきた側」= followerId、
    /// フォロー中一覧なら「フォローされている側」= followeeId。
    func displayUserId(for follow: Follow) -> String {
        switch listType {
        case .followers: follow.followerId
        case .following: follow.followeeId
        }
    }

    /// この行にフォロー操作ボタンを出すか
    ///
    /// 未ログイン（ゲスト）と自分自身の行には出さない。
    /// ⚠️ ゲストは `enterGuestMode` で Firebase 認証を一切しないため `ownUserId` が nil になる
    ///    （PR-6 の judge で確定した事実。匿名認証ユーザーとは別物）。
    func canToggleFollow(for userId: String) -> Bool {
        guard let ownUserId, !ownUserId.isEmpty else { return false }
        return userId != ownUserId
    }

    /// その uid を自分がフォロー中か
    func isFollowingUser(_ userId: String) -> Bool {
        followingUserIds.contains(userId)
    }

    /// そのボタンが処理中か（多重タップ防止）
    func isTogglingFollow(for userId: String) -> Bool {
        togglingUserIds.contains(userId)
    }

    // MARK: - Loading

    /// 初回ページを取得する（再取得にも使う）
    func fetchFirstPage() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let page = try await fetchPage(after: nil)
            follows = page.follows
            lastDocument = page.lastDocument
            // 1 ページに満たなければ末尾（PaginatedPostsViewModel と同じ判定）
            hasMore = page.follows.count >= pageSize
            await fetchMissingProfiles()
            // フォローバック表示のため、自分のフォロー中集合も取り直す
            await loadOwnFollowingIds()
        } catch {
            logger.error("フォロー一覧の初回取得失敗: \(error.localizedDescription)")
            LoggingService.shared.logErrorEvent(
                error,
                context: "FollowListViewModel.fetchFirstPage",
                category: ErrorHandler.categorize(error)
            )
            if follows.isEmpty {
                lastError = error
            } else {
                // pull-to-refresh の失敗: 一覧表示中は ErrorStateView に切り替わらず
                // 無反応に見えるため、アラートで見せる（loadMore の失敗と同じ流儀）
                errorMessage = error.userFriendlyMessage
            }
        }
    }

    /// 次ページを取得して末尾に追加する
    func loadMore() async {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await fetchPage(after: lastDocument)
            // 既に表示中の ID は追加しない（再取得の境界での重複を防ぐ）
            let existingIds = Set(follows.map(\.id))
            follows.append(contentsOf: page.follows.filter { !existingIds.contains($0.id) })
            lastDocument = page.lastDocument
            hasMore = page.follows.count >= pageSize
            await fetchMissingProfiles()
        } catch {
            logger.error("フォロー一覧の追加取得失敗: \(error.localizedDescription)")
            LoggingService.shared.logErrorEvent(
                error,
                context: "FollowListViewModel.loadMore",
                category: ErrorHandler.categorize(error)
            )
            // 追加ページの失敗は一覧を壊さずアラートのみ（既存表示は生かす）
            errorMessage = error.userFriendlyMessage
        }
    }

    /// 種別に応じた follows のページを取得する
    private func fetchPage(
        after lastDocument: DocumentSnapshot?
    ) async throws -> (follows: [Follow], lastDocument: DocumentSnapshot?) {
        switch listType {
        case .followers:
            try await followRepository.fetchFollowers(
                of: targetUserId, limit: pageSize, lastDocument: lastDocument
            )
        case .following:
            try await followRepository.fetchFollowing(
                of: targetUserId, limit: pageSize, lastDocument: lastDocument
            )
        }
    }

    /// 未取得の PublicProfile を並列で一括取得する
    /// （HomeViewModel.fetchAuthorsForCurrentPosts :86-103 のパターンを踏襲）
    private func fetchMissingProfiles() async {
        let missingUserIds = Set(follows.map { displayUserId(for: $0) })
            .subtracting(profilesByUserId.keys)
        guard !missingUserIds.isEmpty else { return }

        await withTaskGroup(of: PublicProfile?.self) { group in
            for userId in missingUserIds {
                group.addTask { [firestoreService] in
                    // プロフィール未作成のユーザーは行をプレースホルダ表示にするため
                    // 個別の失敗は握りつぶす（一覧全体は生かす）
                    try? await firestoreService.fetchPublicProfile(userId: userId)
                }
            }
            for await profile in group {
                if let profile {
                    profilesByUserId[profile.id] = profile
                }
            }
        }
    }

    /// 閲覧者自身がフォローしているユーザーの uid を集合として読み込む ⭐️
    ///
    /// 「フォローバック」ボタンの状態判定に使う。取得に失敗しても一覧表示は続ける
    /// （ボタンが「フォローバック」のまま出るだけで、押せば正しく処理される）。
    /// ⚠️ ページングの上限は設けている。数百人規模のフォローがある場合は
    ///    先頭ページ分しか判定できないが、現状の規模では十分。
    private func loadOwnFollowingIds() async {
        guard let ownUserId, !ownUserId.isEmpty else { return }

        // 自分のフォロー中一覧なら、いま表示している follows がそのまま自分のフォロー中集合。
        // 追加のクエリを投げずに済む。
        if listType == .following, ownUserId == targetUserId {
            followingUserIds = Set(follows.map(\.followeeId))
            return
        }

        do {
            var ids: Set<String> = []
            var cursor: DocumentSnapshot?
            // 最大 5 ページ（= 150 件）まで。無制限ループを避けるための上限。
            for _ in 0 ..< Self.maxOwnFollowingPages {
                let page = try await followRepository.fetchFollowing(
                    of: ownUserId, limit: pageSize, lastDocument: cursor
                )
                ids.formUnion(page.follows.map(\.followeeId))
                cursor = page.lastDocument
                if page.follows.count < pageSize || cursor == nil { break }
            }
            followingUserIds = ids
        } catch {
            // 失敗してもフォロー状態が「未フォロー」に見えるだけで一覧は壊れない
            logger.error("自分のフォロー中一覧の取得失敗: \(error.localizedDescription)")
            LoggingService.shared.logErrorEvent(
                error,
                context: "FollowListViewModel.loadOwnFollowingIds",
                category: ErrorHandler.categorize(error)
            )
        }
    }

    // MARK: - フォロー / フォロー解除

    /// 一覧の行からフォロー状態を切り替える ⭐️
    ///
    /// 一覧に「フォローバック」を置くのが目的（相互フォローの導線）。
    /// カウンタは触らない（Cloud Functions の onFollowCreated / onFollowDeleted が
    /// count() の結果を代入する）。
    func toggleFollow(userId targetId: String) async {
        guard canToggleFollow(for: targetId), let ownUserId else { return }
        guard !togglingUserIds.contains(targetId) else { return }

        let wasFollowing = followingUserIds.contains(targetId)
        togglingUserIds.insert(targetId)
        defer { togglingUserIds.remove(targetId) }

        do {
            if wasFollowing {
                try await followRepository.unfollow(targetId, by: ownUserId)
                followingUserIds.remove(targetId)
            } else {
                try await followRepository.follow(targetId, by: ownUserId)
                followingUserIds.insert(targetId)
            }
            // ⚠️ 相手の uid はパラメータに載せない（removeFollower と同じ方針。
            //    他ユーザーの内部 ID を外部 SaaS へ送らない）。
            //    どちらの一覧から押されたかだけを残す。
            LoggingService.shared.logEvent(
                wasFollowing ? "follow_list_unfollowed" : "follow_list_followed",
                parameters: ["list_type": listType.rawValue]
            )
        } catch {
            logger.error("フォロー切り替え失敗: \(error.localizedDescription)")
            LoggingService.shared.logErrorEvent(
                error,
                context: "FollowListViewModel.toggleFollow",
                category: ErrorHandler.categorize(error)
            )
            errorMessage = error.userFriendlyMessage
        }
    }

    // MARK: - フォロワー削除

    /// 自分のフォロワーから相手を外す
    ///
    /// 成功したら一覧から行を消すだけで、カウンタは触らない
    /// （Cloud Functions の onFollowDeleted が count() の結果を代入する）。
    func removeFollower(userId followerUserId: String) async {
        guard isOwnFollowersList, let ownUserId else { return }
        guard !isRemovingFollower else { return }

        isRemovingFollower = true
        defer { isRemovingFollower = false }

        do {
            try await followRepository.removeFollower(followerUserId, from: ownUserId)
            follows.removeAll { $0.followerId == followerUserId }
            // ⚠️ 削除相手の uid はパラメータに載せない。他ユーザーの内部 ID を
            //    外部 SaaS（Firebase/PostHog）へ送らないため（既存イベントに前例なし）。
            //    削除回数の分析は identify 済みの自分の distinct_id とイベント名で足りる。
            LoggingService.shared.logEvent("follower_removed")
        } catch {
            logger.error("フォロワー削除失敗: \(error.localizedDescription)")
            LoggingService.shared.logErrorEvent(
                error,
                context: "FollowListViewModel.removeFollower",
                category: ErrorHandler.categorize(error)
            )
            errorMessage = error.userFriendlyMessage
        }
    }
}
