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

/// 他人のプロフィールに出す「空カレンダー」「お気に入りの空」の入口の出し方 ⭐️（1.18.0・PR-B）
///
/// 入口を出すかどうかは View ではなく ViewModel の計算プロパティ（`sectionEntryState(for:)`）で決める。
/// View の private に置くと単体テストで固定できず、判定の取り違えが検出できないため
/// （`FollowListViewModel.followButtonTitle(for:)` と同じ教訓）。
enum UserProfileSectionEntryState: Equatable {
    /// 出さない（持ち主が OFF・自分のプロフィール・プロフィール未取得）
    case hidden
    /// 「フォローすると〜が見られます」の 1 行だけ出す（フォロワーでない・持ち主が ON。ゲストも含む）
    case followToSee
    /// 入口のボタンを出す（フォロワー・持ち主が ON）
    case open
}

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

    // MARK: - 見せる/見せない（1.18.0・PR-B）⭐️

    /// おすすめの空の欄を出す（＝読み込む）か
    ///
    /// 持ち主が OFF にしていたら欄を出さず、**読み込みもしない**（`UserProfileView` の `.task` がこれを見る）。
    /// プロフィールが取れていないときは、読む元の一覧（`recommendedPostIds`）も無いので false。
    var showsRecommendedSkies: Bool {
        publicProfile?.sectionVisibility.isShown(.recommendedSkies) == true
    }

    /// 「○○さんの空カレンダー」の入口の出し方
    var skyCalendarEntryState: UserProfileSectionEntryState {
        entryState(for: .skyCalendar)
    }

    /// 「○○さんのお気に入りの空」の入口の出し方
    var favoritesEntryState: UserProfileSectionEntryState {
        entryState(for: .favorites)
    }

    /// 入口の出し方を決める（判定はここ 1 か所だけ）⭐️
    ///
    /// 上から順に見て、最初に当てはまったものにする:
    /// 1. プロフィールが取れていない → 出さない（持ち主が ON にしているか分からない。読めないかもしれない中身へ誘わない）
    /// 2. 自分のプロフィール → 出さない（自分の分はプロフィールタブの入口から見る）
    /// 3. 持ち主が OFF → 出さない
    /// 4. ゲスト（`ownUserId` が nil か空）→「フォローすると〜が見られます」の 1 行 ⭐️ 1.18.0 PR-B
    ///    2026-10-24 利用者の決定でゲストにも出す。押しても何も起きない 1 行で、ログインのきっかけにする。
    ///    ⚠️ ゲストには入口のボタン（`.open`）を決して出さない（フォロワーでないので中身はルールでも読めない）。
    ///    `isFollowing` を見ずにここで決め打ちするのは、`isFollowing` がどんな道で true になってもゲストに開かせないため。
    /// 5. フォロー中 → 入口のボタン
    /// 6. それ以外（ログイン中・フォロワーでない）→「フォローすると〜が見られます」の 1 行
    ///
    /// 計算プロパティから呼ぶので、フォロー解除で `isFollowing` が false になると自動で 6 に変わる。
    /// フォロー状態の取得に失敗したときも `isFollowing` は false（安全側）なので、入口は開かない。
    /// - Parameter section: 空カレンダーかお気に入り（おすすめの空は入口ではないので `showsRecommendedSkies` を使う）
    private func entryState(for section: ProfileSection) -> UserProfileSectionEntryState {
        guard let visibility = publicProfile?.sectionVisibility else { return .hidden }
        guard !isOwnProfile else { return .hidden }
        guard visibility.isShown(section) else { return .hidden }
        guard let ownUserId, !ownUserId.isEmpty else { return .followToSee }
        return isFollowing ? .open : .followToSee
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
        publicProfile = profile
        isFollowing = following

        // フォロー状態が確定してから、閲覧できる公開範囲だけを絞って投稿を取得する
        posts = await fetchVisiblePostsSafe()
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

    /// フォロー状態を取得する。失敗しても安全側（未フォロー扱い）に倒すが、必ず可視化する ⭐️
    ///
    /// `isFollowing` は投稿クエリに渡す visibility 集合を決める入力である。
    /// 取得失敗を無言で「未フォロー」に倒すと、フォロワー限定投稿が理由も分からないまま
    /// 不可視に消え（＝「グリッドが常に空」と同じ見え方になる）、さらに
    /// 「rules の followers 枝が通るか」を確かめる R1 プローブの結果まで誤読させる。
    /// そのため安全側への降格そのものは維持しつつ、原因は必ずユーザーとログの両方に出す。
    private func fetchIsFollowingSafe() async -> Bool {
        guard let ownUserId, ownUserId != targetUserId else { return false }
        do {
            return try await followRepository.isFollowing(targetUserId, by: ownUserId)
        } catch {
            logger.error("isFollowing 失敗: \(error.localizedDescription)")
            // 未フォロー扱い（public のみ要求）に降格するが、握りつぶさず必ず見せる。
            errorMessage = error.userFriendlyMessage
            return false
        }
    }

    // MARK: - Follow / Unfollow

    /// フォローボタン押下時の動作（既にフォロー中なら解除、でなければフォロー）
    func toggleFollow() async {
        guard let ownUserId else {
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
                // 解除できた手ごたえ（軽いタップ）⭐️ 1.18.0 PR-B
                // ⚠️ 成功が分かるのはここ（View は押したことしか知らない）なので、触覚は ViewModel で鳴らす。
                //    投稿の取り直しを待たずに鳴らす（ボタンの見た目が変わるのと同じ瞬間にそろえる）
                Haptics.play(.tap)
            } else {
                try await followRepository.follow(targetUserId, by: ownUserId)
                isFollowing = true
                if var p = publicProfile {
                    p.followersCount += 1
                    publicProfile = p
                }
                // フォローできた手ごたえ ⭐️ 1.18.0 PR-B（解除と同じく、取り直しを待たずに鳴らす）
                Haptics.play(.success)
            }

            // フォロー状態が変わると閲覧できる範囲（フォロワー限定投稿）が変わるため、
            // フォロー時は増える／解除時は消える分を反映するために必ず再取得する。
            // 上で `isFollowing` を更新済みなので、新しい状態に対応した公開範囲で取得される。
            posts = await fetchVisiblePostsSafe()
        } catch {
            logger.error("toggleFollow 失敗: \(error.localizedDescription)")
            errorMessage = error.userFriendlyMessage
            // フォロー/解除が通らなかった手ごたえ ⭐️ 1.18.0 PR-B（下の「エラー」の知らせと一緒に鳴る）
            Haptics.play(.error)
        }
    }

    // MARK: - Block

    /// この人をブロックする ⭐️（C 項目 3。投稿が 0 件の人には投稿の「…」が無く、ブロックできなかった）
    ///
    /// 投稿詳細のブロック（`PostDetailViewModel.blockPostAuthor`）と同じく、保存できたときだけ
    /// `.userBlocked` を送り、開いている一覧（ホーム・あなた向け・タグ・ギャラリー・そらとも）から
    /// その人の投稿を消してもらう。お互いのフォローは Functions（onUserBlockListChanged）が消す。
    /// - Returns: ブロックを保存できたら true（View はこれを見て画面を閉じる）
    func blockUser() async -> Bool {
        // ログインしていない・自分のプロフィールなら何もしない（View も ⋯ を出さないが、念のため）
        guard let ownUserId, ownUserId != targetUserId else { return false }

        do {
            try await firestoreService.blockUser(userId: ownUserId, blockedUserId: targetUserId)
            // 失敗したときは送らない（一覧から消したのに実際はブロックされていない、を防ぐ）
            NotificationCenter.default.post(
                name: .userBlocked,
                object: nil,
                userInfo: [Notification.blockedUserIdKey: targetUserId]
            )
            return true
        } catch {
            logger.error("blockUser 失敗: \(error.localizedDescription)")
            errorMessage = error.userFriendlyMessage
            return false
        }
    }
}
