//
//  TagDetailViewModel.swift
//  Soramoyou
//
//  タグ詳細画面用ViewModel ⭐️
//  PaginatedPostsViewModel を継承し、ハッシュタグ絞り込みのページングと
//  タグのフォロー状態を扱う。
//

import Combine
import FirebaseFirestore
import Foundation

/// タグ詳細画面のViewModel
///
/// `executeQuery` を override して `TagFeedService` のハッシュタグ検索に差し替える。
/// 投稿者情報の一括取得とブロックユーザーの除外は HomeViewModel と同じ方針。
@MainActor
class TagDetailViewModel: PaginatedPostsViewModel {
    // MARK: - Properties

    /// 対象のハッシュタグ（"#" を含まない生の単語）
    /// ⚠️ 正規化しない。Firestore の arrayContains は完全一致のため。
    let tag: String

    /// タグフィード取得サービス
    private let tagFeedService: TagFeedServiceProtocol
    /// 認証サービス
    private let authService: AuthServiceProtocol

    /// 投稿者キャッシュ（userId -> PublicProfile）
    /// `users` は isOwner 制限があるため、公開可能な `publicProfiles` を使う。
    @Published var authorsByUserId: [String: PublicProfile] = [:]

    /// このタグをフォロー中か
    @Published var isFollowingTag = false
    /// フォロー状態を読み込み済みか（未読込のうちはボタンを出さない）
    @Published var hasLoadedFollowState = false
    /// フォロー切り替えの通信中フラグ（連打防止）
    @Published var isTogglingFollow = false
    /// フォロー操作のエラー（上限超過を含む）。ユーザーに必ず見せる。
    @Published var followErrorMessage: String?

    /// ブロックしているユーザーIDのリスト
    private var blockedUserIds: [String] = []

    // MARK: - PaginatedPostsViewModel Overrides

    /// ViewModel名（エラーログ用）
    override var viewModelName: String { "TagDetailViewModel" }

    /// 1ページあたりの取得件数（ホームフィードと同じ）
    override var pageSize: Int { 20 }

    // MARK: - Computed

    /// ログイン中のユーザーID（未ログインなら nil）
    var currentUserId: String? { authService.currentUser()?.id }

    /// ゲスト（未ログイン）かどうか。フォローボタンの出し分けに使う。
    var isGuest: Bool { currentUserId == nil }

    // MARK: - Initializer

    init(
        tag: String,
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        tagFeedService: TagFeedServiceProtocol = TagFeedService(),
        authService: AuthServiceProtocol = AuthService()
    ) {
        self.tag = tag
        self.tagFeedService = tagFeedService
        self.authService = authService
        super.init(firestoreService: firestoreService)
    }

    // MARK: - Query Override

    /// ハッシュタグ絞り込みのページング取得に差し替える
    override func executeQuery(lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        try await tagFeedService.fetchPostsByHashtag(
            tag,
            limit: pageSize,
            lastDocument: lastDocument
        )
    }

    // MARK: - Fetch Overrides

    /// 投稿を取得（ブロックユーザー除外＋投稿者情報の一括取得つき）
    override func fetchPosts() async {
        await loadBlockedUsers()
        await super.fetchPosts()
        filterBlockedUsers()
        await fetchAuthorsForCurrentPosts()
    }

    /// 次ページを取得
    ///
    /// ⚠️ fetchPosts だけでなくこちらも override しないと、2ページ目以降の投稿者情報が
    ///    読み込まれず「ユーザー」＋既定アバターのまま表示される（スクロールして初めて気づく不具合）。
    override func loadMorePosts() async {
        await super.loadMorePosts()
        filterBlockedUsers()
        await fetchAuthorsForCurrentPosts()
    }

    // MARK: - Authors

    /// posts に含まれる userId のうち未取得の PublicProfile を並列取得する
    private func fetchAuthorsForCurrentPosts() async {
        let missingUserIds = Set(posts.map(\.userId))
            .subtracting(authorsByUserId.keys)
        guard !missingUserIds.isEmpty else { return }

        await withTaskGroup(of: PublicProfile?.self) { group in
            for userId in missingUserIds {
                group.addTask { [firestoreService] in
                    try? await firestoreService.fetchPublicProfile(userId: userId)
                }
            }
            for await profile in group {
                if let profile {
                    authorsByUserId[profile.id] = profile
                }
            }
        }
    }

    // MARK: - Blocked Users

    /// ブロックユーザーリストを読み込む
    ///
    /// タグフィードは全公開投稿を横断するため、ここで除外しないと
    /// ブロック済みユーザーの投稿が出てしまう（ホーム／ギャラリーと同じ扱いに揃える）。
    private func loadBlockedUsers() async {
        guard let currentUserId else { return }

        do {
            blockedUserIds = try await firestoreService.fetchBlockedUserIds(userId: currentUserId)
        } catch {
            // ブロックリスト取得に失敗しても投稿表示は継続する
            blockedUserIds = []
        }
    }

    /// ブロックユーザーの投稿を除外する
    private func filterBlockedUsers() {
        guard !blockedUserIds.isEmpty else { return }
        posts = posts.filter { !blockedUserIds.contains($0.userId) }
    }

    // MARK: - Follow State

    /// このタグをフォロー済みかどうかをサーバーから読み込む
    func loadFollowState() async {
        guard let userId = currentUserId else {
            // 未ログインならフォロー状態は無い（ボタンはログイン導線として扱う）
            isFollowingTag = false
            hasLoadedFollowState = true
            return
        }

        do {
            let user = try await firestoreService.fetchUser(userId: userId)
            isFollowingTag = (user.followedTags ?? []).contains(tag)
        } catch {
            // 取得失敗時は未フォロー扱い。操作時に再取得するので致命的ではない。
            ErrorHandler.logError(error, context: "TagDetailViewModel.loadFollowState", userId: userId)
            isFollowingTag = false
        }
        hasLoadedFollowState = true
    }

    /// タグのフォロー / フォロー解除を切り替える
    ///
    /// ⚠️ 上限判定は必ず「サーバーから取り直した最新の followedTags」に対して行う。
    ///    ローカルのキャッシュで数えると、別端末で追加された分を見落として
    ///    arrayUnion が黙って 30 件を超える。
    func toggleFollowTag() async {
        guard let userId = currentUserId else {
            followErrorMessage = "タグをフォローするにはログインが必要です"
            return
        }
        // 連打による二重書き込みを防ぐ
        guard !isTogglingFollow else { return }

        isTogglingFollow = true
        defer { isTogglingFollow = false }
        followErrorMessage = nil

        do {
            // 最新状態を取得してから判定する（上記の理由）
            let user = try await firestoreService.fetchUser(userId: userId)
            let currentTags = user.followedTags ?? []
            let alreadyFollowing = currentTags.contains(tag)

            if alreadyFollowing {
                try await firestoreService.unfollowTag(userId: userId, tag: tag)
                isFollowingTag = false
            } else {
                // 上限チェック。超過は「無言で失敗」させずユーザーに見せる。
                guard currentTags.count < User.maxFollowedTags else {
                    followErrorMessage = "フォローできるタグは\(User.maxFollowedTags)件までです。他のタグのフォローを解除してください。"
                    return
                }
                try await firestoreService.followTag(userId: userId, tag: tag)
                isFollowingTag = true
            }

            // 計装: 成功したときだけ記録する（上限で弾かれた場合は送らない）
            LoggingService.shared.logEvent("tag_follow_toggled", parameters: [
                "tag": tag,
                "state": alreadyFollowing ? "unfollowed" : "followed",
            ])
        } catch {
            ErrorHandler.logError(error, context: "TagDetailViewModel.toggleFollowTag", userId: userId)
            followErrorMessage = error.userFriendlyMessage
        }
    }
}
