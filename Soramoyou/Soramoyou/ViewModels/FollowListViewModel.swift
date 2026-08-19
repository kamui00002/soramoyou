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

    // MARK: - Dependencies

    /// 一覧の種別
    let listType: FollowListType
    /// 誰の一覧か
    let targetUserId: String
    /// 閲覧者自身の userId（未ログインなら nil）
    let ownUserId: String?

    private let followRepository: FollowRepositoryProtocol
    private let firestoreService: FirestoreServiceProtocol
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
