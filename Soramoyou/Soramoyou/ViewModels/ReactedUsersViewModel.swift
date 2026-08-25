//
//  ReactedUsersViewModel.swift
//  Soramoyou
//
//  「あなたの投稿に反応した人」一覧の ViewModel ⭐️
//
//  狙い: フォロワーが増える体験の入口を作る。自分の空に反応してくれた人が見えれば
//  「届いた」実感になり、そのままフォローへ進める（相互フォローの導線と同じ出口）。
//
//  データの取り方:
//    自分の直近投稿（最大30件）→ その postId 群で `likes` を1クエリ取得
//    → userId で重複排除 → publicProfiles を並列一括取得
//  `likes` にはドキュメントに投稿者が入っていないため、
//  「自分の投稿 → その投稿へのいいね」という順で辿る。
//
//  ⚠️ 30投稿の壁（意図的な割り切り）:
//    Firestore の `in` は最大30要素。よってこの一覧は「**最近の**投稿への反応」であり、
//    それより古い投稿への反応は出ない。画面の文言もそう名乗ること（嘘をつかない）。
//
//  ⚠️ ブロック済みユーザーは **除外しない**。
//    Home / TagDetail / Gallery は除外するが、フォロー一覧は「出す」と決めてある
//    （PR #89 の defer #7・削除導線を残すため）。この一覧は人物一覧なので後者に揃える。
//

import Foundation
@preconcurrency import FirebaseFirestore
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.soramoyou.photo-editor",
    category: "ReactedUsersViewModel"
)

/// 反応してくれた1人ぶんの表示データ
struct ReactedUser: Identifiable, Equatable {
    /// 相手の userId
    let id: String
    /// その人が自分の投稿に付けたいいねの件数（取得した like ドキュメントから数える）
    let reactionCount: Int
    /// 最後に反応した日時（新しい順の並べ替えに使う）
    let latestReactedAt: Date
}

@MainActor
final class ReactedUsersViewModel: ObservableObject {
    // MARK: - Published State

    /// 反応してくれた人（最後に反応した順）
    @Published private(set) var reactedUsers: [ReactedUser] = []
    /// 表示用プロフィール（userId -> PublicProfile）
    @Published private(set) var profilesByUserId: [String: PublicProfile] = [:]
    /// 自分がフォロー中の uid 集合（フォローボタンの状態判定）
    @Published private(set) var followingUserIds: Set<String> = []
    /// フォロー切り替え中の uid（そのボタンだけ無効化して多重タップを防ぐ）
    @Published private(set) var togglingUserIds: Set<String> = []

    @Published private(set) var isLoading = false
    /// 初回ロードの失敗（ErrorStateView 表示用）
    @Published var lastError: Error?
    /// 操作エラー（アラート表示用）
    @Published var errorMessage: String?

    // MARK: - Dependencies

    /// 閲覧者自身の userId（未ログインなら nil）
    let ownUserId: String?

    private let firestoreService: FirestoreServiceProtocol
    private let followRepository: FollowRepositoryProtocol

    // MARK: - 件数の設定

    // ⚠️ 既定値は本番用。テストから小さい値を注入して境界（ページ上限・30件の壁）を
    //    実データ量なしで突けるようにするため、static ではなく注入可能にしている。

    /// 反応を辿る対象にする自分の投稿の件数（Firestore の `in` 上限と同じ 30）
    private let recentPostsWindow: Int
    /// 投稿を取ってくるときの件数。非公開投稿を除外したあとに 30 件を確保するため広めに取る
    private let postsFetchWindow: Int
    /// 自分のフォロー中集合を読むときの1ページ件数
    private let followingPageSize: Int
    /// 同上のページ数上限（= 件数 × この値が判定できる上限）
    private let maxFollowingPages: Int

    // MARK: - Initializer

    init(
        ownUserId: String?,
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        followRepository: FollowRepositoryProtocol = FollowRepository(),
        recentPostsWindow: Int = 30,
        postsFetchWindow: Int = 60,
        followingPageSize: Int = 30,
        maxFollowingPages: Int = 5
    ) {
        self.ownUserId = ownUserId
        self.firestoreService = firestoreService
        self.followRepository = followRepository
        self.recentPostsWindow = recentPostsWindow
        self.postsFetchWindow = postsFetchWindow
        self.followingPageSize = followingPageSize
        self.maxFollowingPages = maxFollowingPages
    }

    // MARK: - 表示ヘルパー

    /// この行にフォロー操作ボタンを出すか（ゲストと自分自身には出さない）
    func canToggleFollow(for userId: String) -> Bool {
        guard let ownUserId else { return false }
        return userId != ownUserId
    }

    func isFollowingUser(_ userId: String) -> Bool {
        followingUserIds.contains(userId)
    }

    func isTogglingFollow(for userId: String) -> Bool {
        togglingUserIds.contains(userId)
    }

    /// フォローボタンの文言
    ///
    /// ⚠️ この一覧は「自分のフォロワー」ではないので **「フォローバック」とは出さない**。
    ///    反応してくれた人が自分をフォローしているとは限らないため
    ///    （フォロワー一覧の同名バグ＝PR #97 の D1 と同じ取り違えを繰り返さない）。
    func followButtonTitle(for userId: String) -> String {
        isFollowingUser(userId) ? "フォロー中" : "フォロー"
    }

    // MARK: - Loading

    /// 一覧を読み込む（再読み込みにも使う）
    func load() async {
        guard !isLoading else { return }
        guard let ownUserId else {
            // ゲスト（未認証）は自分の投稿が無いので空で終える
            reactedUsers = []
            return
        }

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            // 1. 自分の直近投稿 → その postId 群でいいねを1クエリ取得
            // ⚠️ 非公開（private）の投稿は他人が閲覧できず新しいいいねが付かないため、
            //    30件の枠をそれで埋めると「実在する反応」が一覧から落ちる。
            //    そこで少し広めに取ってから除外し、改めて30件に切る
            //    （createdAt 降順は filter / prefix を通しても保たれる。クエリ数は増えない）。
            let myPosts = try await firestoreService.fetchUserPosts(
                userId: ownUserId, limit: postsFetchWindow, lastDocument: nil
            )
            let postIds = myPosts
                .filter { $0.visibility != .private }
                .prefix(recentPostsWindow)
                .map(\.id)
            let likes = try await firestoreService.fetchLikes(forPostIds: postIds)

            // 2. 自分のいいねを除外し、userId で集約する
            //    ⚠️ 自分の投稿に自分でいいねした like が実データに存在するため、
            //       除外しないと自分の一覧に自分が並ぶ。
            reactedUsers = Self.aggregate(likes: likes, excluding: ownUserId)

            // 3. 表示用プロフィールと自分のフォロー中集合
            await fetchMissingProfiles()
            await loadOwnFollowingIds(ownUserId: ownUserId)

            // ⚠️ `like_count` が `fetchLikes` の上限（500）に張り付いていたら、
            //    表示している「N件のいいね」は**過小**になっている可能性がある。
            //    `order(by:)` を付けていないため切り捨てられるのは末尾ではなく
            //    ドキュメントID順の任意の部分集合で、全員の件数が同時に目減りし、
            //    人によっては一覧から丸ごと消える。エラーにも例外にもならない
            //    ＝これを送らないと誰も気づけないので、必ず計測に載せる。
            LoggingService.shared.logEvent("reacted_users_loaded", parameters: [
                "user_count": reactedUsers.count,
                "post_window": postIds.count,
                "like_count": likes.count,
            ])
        } catch {
            logger.error("反応した人一覧の取得失敗: \(error.localizedDescription)")
            LoggingService.shared.logErrorEvent(
                error,
                context: "ReactedUsersViewModel.load",
                category: ErrorHandler.categorize(error)
            )
            if reactedUsers.isEmpty {
                lastError = error
            } else {
                errorMessage = error.userFriendlyMessage
            }
        }
    }

    /// いいね群を「人」単位に集約する純関数 ⭐️
    ///
    /// - 同じ人が複数の投稿に反応していても 1 行にまとめ、件数を数える
    /// - 並びは「最後に反応した日時」の降順。同時刻は userId 昇順で決定的にする
    /// - `excluding` に渡した uid（＝自分）は除く
    ///
    /// ⚠️ 件数は **取得した like ドキュメントから数える**。`posts.likesCount` は
    ///    クライアントの ±1 更新でドリフトしうるため、表示の出典にしない。
    static func aggregate(likes: [Like], excluding ownUserId: String) -> [ReactedUser] {
        var countByUser: [String: Int] = [:]
        var latestByUser: [String: Date] = [:]

        for like in likes where like.userId != ownUserId {
            countByUser[like.userId, default: 0] += 1
            if let current = latestByUser[like.userId] {
                latestByUser[like.userId] = max(current, like.createdAt)
            } else {
                latestByUser[like.userId] = like.createdAt
            }
        }

        return countByUser.keys
            .map { userId in
                ReactedUser(
                    id: userId,
                    reactionCount: countByUser[userId] ?? 0,
                    latestReactedAt: latestByUser[userId] ?? .distantPast
                )
            }
            .sorted { lhs, rhs in
                if lhs.latestReactedAt != rhs.latestReactedAt {
                    return lhs.latestReactedAt > rhs.latestReactedAt
                }
                // 同時刻は uid 昇順（実行のたびに順序が変わらないようにする）
                return lhs.id < rhs.id
            }
    }

    /// 未取得の PublicProfile を並列で一括取得する
    /// （HomeViewModel.fetchAuthorsForCurrentPosts のパターンを踏襲）
    private func fetchMissingProfiles() async {
        let missingUserIds = Set(reactedUsers.map(\.id)).subtracting(profilesByUserId.keys)
        guard !missingUserIds.isEmpty else { return }

        await withTaskGroup(of: PublicProfile?.self) { group in
            for userId in missingUserIds {
                group.addTask { [firestoreService] in
                    // プロフィール未作成のユーザーはプレースホルダ表示にする
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

    /// 自分がフォロー中の uid を集合として読む（行ごとに isFollowing を叩く N+1 を避ける）
    private func loadOwnFollowingIds(ownUserId: String) async {
        do {
            var ids: Set<String> = []
            var cursor: DocumentSnapshot?
            for _ in 0 ..< maxFollowingPages {
                let page = try await followRepository.fetchFollowing(
                    of: ownUserId, limit: followingPageSize, lastDocument: cursor
                )
                ids.formUnion(page.follows.map(\.followeeId))
                cursor = page.lastDocument
                if page.follows.count < followingPageSize || cursor == nil { break }
            }
            followingUserIds = ids
        } catch {
            // 失敗してもフォロー状態が「未フォロー」に見えるだけで一覧は壊れない
            logger.error("自分のフォロー中一覧の取得失敗: \(error.localizedDescription)")
            LoggingService.shared.logErrorEvent(
                error,
                context: "ReactedUsersViewModel.loadOwnFollowingIds",
                category: ErrorHandler.categorize(error)
            )
        }
    }

    // MARK: - フォロー

    /// 一覧の行からフォロー状態を切り替える
    ///
    /// カウンタは触らない（Cloud Functions が count() の結果を代入する）。
    /// 楽観的更新はせず、成功後にだけ状態を変える。
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
            // ⚠️ イベント名は一覧ごとに増やさず、**由来をパラメータで区別する**。
            //    「アプリ内でフォローされた回数」という 1 つの指標が
            //    イベント名の数だけ分裂すると、後から合算できなくなるため
            //    （FollowListViewModel と同じ follow_list_followed を共有する）。
            //    ⚠️ イベント名はリリース後に変えると過去データと繋がらないので、増やすなら今しかない。
            // ⚠️ 相手の uid はパラメータに載せない（PR #89 で確立した方針）
            LoggingService.shared.logEvent(
                wasFollowing ? "follow_list_unfollowed" : "follow_list_followed",
                parameters: [
                    "list_type": "reacted_users",
                    // この一覧は「自分の投稿への反応」なので常に自分の一覧
                    "is_own_list": true,
                ]
            )
        } catch {
            logger.error("フォロー切り替え失敗: \(error.localizedDescription)")
            LoggingService.shared.logErrorEvent(
                error,
                context: "ReactedUsersViewModel.toggleFollow",
                category: ErrorHandler.categorize(error)
            )
            errorMessage = error.userFriendlyMessage
        }
    }
}
