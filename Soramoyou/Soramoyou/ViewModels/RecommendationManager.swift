//
//  RecommendationManager.swift
//  Soramoyou
//
//  「私のおすすめの空」の状態管理（自分の一覧の読み込み・追加・外す・並べ替え）⭐️
//
//  投稿詳細の「…」メニュー（追加 / 外す）と、自分のプロフィールのおすすめ欄（外す / 並べ替え）が
//  同じ一覧を見るため、全画面で 1 つのインスタンスを共有する。
//
//  ⚠️ LikeManager / FavoriteManager のような EnvironmentObject ではなく `shared` にしている。
//     投稿詳細（PostDetailView / GalleryDetailView）はシートや全画面カバーから 7 か所以上で開かれ、
//     EnvironmentObject は注入し忘れた経路で**実行時クラッシュ**になるため。
//     `SkyMotionCreditService.shared` を `@ObservedObject` で見るのと同じ流儀。
//
//  ⚠️ おすすめの空は publicProfiles に保存する＝**他の人にも見える**。
//     🔖 お気に入り（自分だけのプライベート保存）とは性質が逆なので混同しないこと。
//

import Foundation

@MainActor
final class RecommendationManager: ObservableObject {
    /// アプリ全体で共有するインスタンス
    static let shared = RecommendationManager()

    /// 追加・外す操作の結果（画面のアラート文言の出し分けに使う）
    enum Outcome: Equatable {
        /// 追加した
        case added
        /// 既に入っていた
        case alreadyAdded
        /// 上限（3 枚）に達していて追加できなかった
        case full
        /// 外した
        case removed
        /// 公開投稿ではないので追加できない
        case notPublic
        /// ログインしていない
        case requiresLogin
        /// 保存に失敗した
        case failed
    }

    /// 自分のおすすめの空（表示順の postId）
    @Published private(set) var recommendedPostIds: [String] = []
    /// 保存処理中か（連打による二重送信を防ぐ）
    @Published private(set) var isUpdating = false

    /// どのユーザーの一覧を読み込み済みか（アカウント切替の検知用）
    private var loadedUserId: String?

    private let firestoreService: FirestoreServiceProtocol
    private let authService: AuthServiceProtocol

    init(firestoreService: FirestoreServiceProtocol = FirestoreService(),
         authService: AuthServiceProtocol = AuthService()) {
        self.firestoreService = firestoreService
        self.authService = authService
    }

    // MARK: - 参照

    /// おすすめの空に入っているか
    func isRecommended(_ postId: String) -> Bool {
        recommendedPostIds.contains(postId)
    }

    /// 上限に達しているか
    var isFull: Bool {
        recommendedPostIds.count >= RecommendedSkies.maxCount
    }

    // MARK: - 読み込み

    /// 自分の一覧を読み込む
    ///
    /// - Parameter force: true なら読み込み済みでも取り直す（プロフィールを開いた・引っ張って更新したとき）
    func load(force: Bool = false) async {
        guard let userId = authService.currentUser()?.id else {
            clearOnSignOut()
            return
        }
        // 投稿詳細を開くたびに読み直さない（同じユーザーで読み込み済みなら何もしない）
        if !force, loadedUserId == userId { return }

        do {
            let profile = try await firestoreService.fetchPublicProfile(userId: userId)
            // ⚠️ await 中にサインアウト／アカウント切替が挟まっていたら反映しない
            guard authService.currentUser()?.id == userId else { return }
            recommendedPostIds = profile.recommendedPostIds
            loadedUserId = userId
        } catch FirestoreServiceError.notFound {
            // 公開プロフィール未作成の旧アカウント＝まだ何も選んでいない
            guard authService.currentUser()?.id == userId else { return }
            recommendedPostIds = []
            loadedUserId = userId
        } catch {
            ErrorHandler.logError(error, context: "RecommendationManager.load", userId: userId)
        }
    }

    // MARK: - 追加 / 外す

    /// おすすめの空に追加する（入っていれば外す）
    ///
    /// 投稿詳細の「…」メニューから呼ぶ。
    /// - Parameters:
    ///   - post: 対象の投稿
    ///   - source: 計装用の発生源（"post_detail" / "gallery_detail"）
    func toggle(post: Post, source: String) async -> Outcome {
        if isRecommended(post.id) {
            return await remove(postIds: [post.id], source: source)
        }
        return await add(post: post, source: source)
    }

    /// おすすめの空に追加する
    func add(post: Post, source: String) async -> Outcome {
        guard let userId = authService.currentUser()?.id else { return .requiresLogin }
        // 他の人にも見える場所なので、公開投稿だけを飾れる
        // （フォロワー限定・非公開の投稿は、見る人によって表示できない）
        guard post.visibility == .public else { return .notPublic }
        guard !isUpdating else { return .failed }

        isUpdating = true
        defer { isUpdating = false }

        do {
            let result = try await addWithProfileFallback(postId: post.id, userId: userId)
            guard authService.currentUser()?.id == userId else { return .failed }
            recommendedPostIds = result.postIds
            loadedUserId = userId

            let outcome: Outcome
            switch result {
            case .added: outcome = .added
            case .alreadyAdded: outcome = .alreadyAdded
            case .full: outcome = .full
            }
            LoggingService.shared.logEvent("recommended_sky_added", parameters: [
                "result": Self.analyticsValue(outcome),
                "source": source,
                "is_own_post": post.userId == userId,
                "count": result.postIds.count
            ])
            return outcome
        } catch {
            ErrorHandler.logError(error, context: "RecommendationManager.add", userId: userId)
            return .failed
        }
    }

    /// おすすめの空から外す（複数まとめて外せる＝表示できなくなった空の整理にも使う）
    func remove(postIds: Set<String>, source: String) async -> Outcome {
        guard let userId = authService.currentUser()?.id else { return .requiresLogin }
        guard !isUpdating else { return .failed }

        let previous = recommendedPostIds
        let updated = RecommendedSkies.removing(postIds, from: previous)
        guard updated != previous else { return .removed }

        isUpdating = true
        defer { isUpdating = false }

        // オプティミスティック更新（プロフィールの欄から即座に消す）
        recommendedPostIds = updated
        do {
            try await firestoreService.updateRecommendedPostIds(updated, userId: userId)
            LoggingService.shared.logEvent("recommended_sky_removed", parameters: [
                "source": source,
                "removed_count": previous.count - updated.count
            ])
            return .removed
        } catch {
            // 失敗時は元に戻す（UIが嘘をつかないように）。切替後なら前ユーザーの値を書き戻さない
            if authService.currentUser()?.id == userId {
                recommendedPostIds = previous
            }
            ErrorHandler.logError(error, context: "RecommendationManager.remove", userId: userId)
            return .failed
        }
    }

    /// 並び順を 1 つ動かす（offset: -1 で前へ、+1 で後ろへ）
    func move(postId: String, by offset: Int) async {
        guard let userId = authService.currentUser()?.id, !isUpdating else { return }

        let previous = recommendedPostIds
        let updated = RecommendedSkies.moving(postId, by: offset, in: previous)
        guard updated != previous else { return }

        isUpdating = true
        defer { isUpdating = false }

        recommendedPostIds = updated
        do {
            try await firestoreService.updateRecommendedPostIds(updated, userId: userId)
        } catch {
            if authService.currentUser()?.id == userId {
                recommendedPostIds = previous
            }
            ErrorHandler.logError(error, context: "RecommendationManager.move", userId: userId)
        }
    }

    // MARK: - サインアウト

    /// サインアウト時にローカル状態を捨てる（共有端末で前のユーザーの一覧を見せない）
    func clearOnSignOut() {
        recommendedPostIds = []
        loadedUserId = nil
    }

    // MARK: - Private

    /// 追加する。公開プロフィールが無い旧アカウントなら作ってから 1 回だけ再試行する
    private func addWithProfileFallback(postId: String, userId: String) async throws -> RecommendedSkies.AddResult {
        do {
            return try await firestoreService.addRecommendedPost(postId: postId, userId: userId)
        } catch FirestoreServiceError.notFound {
            let user = try await firestoreService.fetchUser(userId: userId)
            try await firestoreService.createPublicProfile(from: user)
            return try await firestoreService.addRecommendedPost(postId: postId, userId: userId)
        }
    }

    /// 計測に送る結果の値
    private static func analyticsValue(_ outcome: Outcome) -> String {
        switch outcome {
        case .added: return "added"
        case .alreadyAdded: return "already_added"
        case .full: return "full"
        case .removed: return "removed"
        case .notPublic: return "not_public"
        case .requiresLogin: return "requires_login"
        case .failed: return "failed"
        }
    }
}
