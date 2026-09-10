//
//  FavoritesViewModel.swift
//  Soramoyou
//
//  「私のお気に入りの空」一覧の ViewModel ⭐️
//
//  データの取り方:
//    users/{uid}/favorites を createdAt 降順で1ページ取得
//    → その postId 群を **1件ずつ** `fetchPost` で解決（TaskGroup で並列）
//
//  ⚠️ なぜ `whereField(documentID, in: [...])` の一括クエリを使わないか:
//    posts の read rule は visibility 依存（公開／フォロワー限定／非公開）。
//    複数件をまとめたクエリは「1件でも読めないものが混ざると全体が permission denied」になる。
//    1件ずつの get なら rules がドキュメント単位で評価されるので、
//    非公開化・削除された投稿を1件だけ落として他を巻き込まずに済む。
//
//  ⚠️ favorites は所有者サブコレクションなので、一覧クエリは order(by: createdAt) 1本＝
//    複合インデックス不要（index 欠落による「件数だけ増えて中身が出ない」事故の予防）。
//
//  ⚠️ 取得は **2層** になっている。ここがページングの設計の肝:
//      下の層 = favorites の1ページ取得。アトミック（失敗すればページ丸ごと throw）
//      上の層 = その postId を1件ずつ解決。**部分的に失敗しうる**
//    カーソルは下の層の位置を指すが、進めてよいのは **上の層で解決を終えた分まで**。
//    ページ末尾まで進めてしまうと、解決できなかった投稿を「消費済み」にしてしまい、
//    次ページはその先から始まる＝その投稿は二度と取りに行かれず静かに消える。
//

import Foundation
import FirebaseFirestore

@MainActor
final class FavoritesViewModel: ObservableObject {
    // MARK: - Published State

    /// お気に入り順（新しい順）に並んだ投稿
    @Published private(set) var posts: [Post] = []
    /// 初回ロード中
    @Published private(set) var isLoading = false
    /// 追加ページ読み込み中
    @Published private(set) var isLoadingMore = false
    /// 次ページがある見込み
    @Published private(set) var hasMore = false
    /// 非公開化・削除で表示できなかった件数（累計）
    @Published private(set) var unavailableCount = 0
    /// 初回ロードの失敗（ErrorStateView 表示用）
    @Published var lastError: Error?

    /// 続きの読み込みでの失敗
    ///
    /// ⚠️ `lastError`（＝1件も出せていない＝画面全体をエラーにする）とは別物。
    ///    こちらは既に出ている一覧をそのまま残し、フッターで再試行を促すために使う。
    ///    これが nil でない間は自動のページ送りを止める。放っておくと
    ///    スクロール位置のゆらぎで同じ失敗を叩き続けることになるため。
    @Published private(set) var loadMoreError: Error?

    // MARK: - Dependencies

    /// 閲覧者自身の userId（未ログインなら nil）
    let ownUserId: String?

    private let firestoreService: FirestoreServiceProtocol
    private let pageSize: Int

    /// 1回の読み込みで繰るページ数の上限
    ///
    /// ⚠️ 削除済み・非公開の favorites だけが数百件ある人で無限に回らないための予算。
    private let maxPagesPerRequest: Int

    /// 次ページ取得用カーソル（解決を終えた最後の favorite の createdAt）
    private var cursor: Date?

    /// 解決できた投稿の全量（favorites の並び順＝新しい順）
    ///
    /// ⚠️ 表示用の `posts` と分けて持つ理由:
    ///    詳細画面で🔖を解除したときに `posts` から消すだけだと、
    ///    「書き込みが失敗してリバートされた」「すぐ押し直した」場合に元へ戻せない。
    ///    全量を保持して表示だけ絞る形にすれば、戻すのは filter の掛け直しで済み、
    ///    並び順も favorites の順のまま自動的に正しくなる。
    private var resolvedPosts: [Post] = []

    /// 一覧から隠している postId（＝お気に入りから外れたもの）
    private var unfavoritedIds: Set<String> = []

    /// 読み込みの世代
    ///
    /// ⚠️ `await` の最中に新しい `load()`（pull-to-refresh など）が走ったら、
    ///    古い側の結果を `posts` / `cursor` へ反映してはいけない（重複表示・カーソル巻き戻りの原因）。
    ///    既存の `PaginatedPostsViewModel` と同じ防ぎ方に揃える。
    private var fetchGeneration = 0

    init(ownUserId: String?,
         firestoreService: FirestoreServiceProtocol = FirestoreService(),
         pageSize: Int = 30,
         maxPagesPerRequest: Int = 5) {
        self.ownUserId = ownUserId
        self.firestoreService = firestoreService
        self.pageSize = pageSize
        self.maxPagesPerRequest = maxPagesPerRequest
    }

    // MARK: - Loading

    /// 1ページ目を読み込む（リセット付き。pull-to-refresh からも呼ばれる）
    func load() async {
        guard let userId = ownUserId else {
            // 未ログインでは自分のお気に入りが存在しない。空表示で終える。
            resolvedPosts = []
            unfavoritedIds = []
            posts = []
            hasMore = false
            unavailableCount = 0
            loadMoreError = nil
            return
        }

        // この取得の世代を確定。await 中により新しい load() が走ったら、こちらの結果は捨てる。
        fetchGeneration += 1
        let generation = fetchGeneration

        isLoading = true
        lastError = nil
        loadMoreError = nil
        // 世代が変わっていたら、ローディング解除は新しい load() 側の責務。
        // （世代を進めるのは load() だけで、進めた直後に必ず isLoading = true を立てるので、
        //   ここで解除を見送ってもスピナーが出たままになることはない）
        defer { if generation == fetchGeneration { isLoading = false } }

        do {
            let batch = try await fetchVisiblePages(userId: userId, after: nil)
            // await 中に新しい load() が始まっていたら、こちらの結果は反映しない。
            guard generation == fetchGeneration else { return }

            // 1件も出せず、かつ一時的な失敗（ネットワーク等）があるなら
            // 「0件」と嘘をつかずエラー表示にする。
            if batch.posts.isEmpty, let transientError = batch.transientError {
                resolvedPosts = []
                unfavoritedIds = []
                posts = []
                hasMore = false
                unavailableCount = batch.unavailable
                lastError = transientError
                return
            }

            resolvedPosts = batch.posts
            unfavoritedIds = []
            refreshVisiblePosts()
            unavailableCount = batch.unavailable
            cursor = batch.cursor
            hasMore = batch.hasMore
            // 一覧は出せたが、続きの解決でつまずいた場合はフッターから再試行させる。
            loadMoreError = batch.transientError

            LoggingService.shared.logEvent("favorites_viewed", parameters: [
                "count": posts.count,
                "unavailable_count": unavailableCount
            ])
        } catch {
            guard generation == fetchGeneration else { return }
            resolvedPosts = []
            unfavoritedIds = []
            posts = []
            hasMore = false
            lastError = error
            ErrorHandler.logError(error, context: "FavoritesViewModel.load", userId: userId)
        }
    }

    /// 次のページを読み込んで末尾に追記する
    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        guard let userId = ownUserId, let cursor else { return }

        // このページングが属する世代。await 中に load() が走って世代が変わったら、
        // 古いカーソル基準の1ページを新しい一覧へ append しない。
        let generation = fetchGeneration

        isLoadingMore = true
        // 世代不一致で早期 return しても追加読み込みが恒久ブロックされないよう、必ず解除する。
        defer { isLoadingMore = false }
        loadMoreError = nil

        do {
            let batch = try await fetchVisiblePages(userId: userId, after: cursor)
            // 途中で load()（pull-to-refresh など）が走っていたら、この旧ページは捨てる。
            guard generation == fetchGeneration else { return }

            resolvedPosts.append(contentsOf: batch.posts)
            refreshVisiblePosts()
            unavailableCount += batch.unavailable
            self.cursor = batch.cursor ?? cursor
            hasMore = batch.hasMore
            loadMoreError = batch.transientError
        } catch {
            guard generation == fetchGeneration else { return }
            // 追加読み込みの失敗は画面全体をエラーにしない（既に出ているものは残す）。
            // 再試行できるよう hasMore は倒さず、フッターに失敗を出す。
            loadMoreError = error
            ErrorHandler.logError(error, context: "FavoritesViewModel.loadMore", userId: userId)
        }
    }

    // MARK: - Mutation

    /// お気に入り状態の変化を一覧へ反映する（**双方向**）
    ///
    /// 詳細画面で🔖を解除して戻ってきたとき、一覧に残り続けないようにする。
    /// ただし**消して終わりにはしない**のが要点:
    ///   - 解除の書き込みが失敗して `FavoriteManager` がローカルをリバートした
    ///   - ユーザーが誤タップに気づいてすぐ押し直した
    /// このどちらでも「お気に入りのままなのに一覧から消えている」状態になってしまい、
    /// pull-to-refresh するまで直らない。
    ///
    /// 全量 `resolvedPosts` は触らず、隠す postId の集合だけを差し替えるので、
    /// 戻したときの並び順は favorites の順（新しい順）のまま自動的に正しくなる。
    /// - Parameter ids: 現在お気に入り済みの postId 集合（FavoriteManager の最新状態）
    func syncFavorited(ids: Set<String>) {
        // 解除で消えた分は「非公開・削除で出せなかった件数」ではないので脚注には数えない。
        // hasMore も触らない（サーバー側にまだ次ページがある事実は変わらないため）。
        let hidden = Set(resolvedPosts.map(\.id)).subtracting(ids)
        guard hidden != unfavoritedIds else { return }
        unfavoritedIds = hidden
        refreshVisiblePosts()
    }

    // MARK: - Private

    /// 表示できる投稿が1件以上取れるまでページを繰る
    ///
    /// ⚠️ 1ページが丸ごと「削除済み・非公開」だと `posts` が1件も増えない。
    ///    一覧が空のままだと画面に最後のセルが存在せず、`.onAppear` 起点の `loadMore` が
    ///    発火しない＝その先に生きている投稿があっても永久に辿り着けなくなる。
    ///    View の空表示に再読込を足しても半分しか塞げない（2ページ目以降で全滅した場合は
    ///    末尾セルが変わらず、やはり再発火しない）ので、ここ＝ViewModel 側で繰る。
    ///
    /// - Parameters:
    ///   - userId: 閲覧者自身の userId
    ///   - startCursor: 開始位置（nil なら先頭から）
    /// - Returns: 積み上げた結果。`cursor` は解決を終えた最後の1件を指す
    private func fetchVisiblePages(userId: String, after startCursor: Date?) async throws -> PageBatch {
        var batch = PageBatch(cursor: startCursor)

        for _ in 0..<maxPagesPerRequest {
            let favorites = try await firestoreService.fetchFavorites(
                userId: userId,
                limit: pageSize,
                after: batch.cursor
            )
            let resolution = await resolvePosts(for: favorites)

            batch.posts.append(contentsOf: resolution.posts)
            batch.unavailable += resolution.unavailable
            // カーソルは「解決を終えた最後の1件」まで。切り詰めた分は消費していない。
            if resolution.consumed > 0 {
                batch.cursor = favorites[resolution.consumed - 1].createdAt
            }

            if let transientError = resolution.transientError {
                // 切り詰めた＝このページの残りがサーバーにまだある。
                batch.transientError = transientError
                batch.hasMore = true
                return batch
            }

            batch.hasMore = favorites.count == pageSize
            // 1件でも出せたら止める。1件も出せなかったときだけ次のページへ進む。
            if !batch.posts.isEmpty || !batch.hasMore { return batch }
        }

        // 予算切れ。`hasMore` は true のまま返す。
        // ここで倒すと「お気に入りは全部消えました」という**嘘の断定**を表示することになる。
        return batch
    }

    /// 全量から「隠している投稿」を除いて表示用の `posts` を作り直す
    private func refreshVisiblePosts() {
        posts = resolvedPosts.filter { !unfavoritedIds.contains($0.id) }
    }

    /// favorites の並び順を保ったまま投稿を解決する
    ///
    /// `fetchPost` は TaskGroup で並列に走らせるため完了順はバラバラになる。
    /// 順序は favorites 側が正なので、辞書に集めてから並べ直す。
    ///
    /// ⚠️ 一時的な失敗（ネットワーク等）に当たったら、**そこでページを切り詰める**。
    ///    失敗した1件だけ飛ばして先を積むと、カーソルはページ末尾まで進むのに
    ///    その投稿は積まれていない＝二度と取りに行かれず静かに消える。
    ///    「レジで30個スキャンして袋に入ったのが25個なら、レシートは25個分で切る」。
    private func resolvePosts(for favorites: [Favorite]) async -> PageResolution {
        guard !favorites.isEmpty else { return PageResolution() }

        // 各 postId の結果（成功 or 失敗）を集める
        let results: [String: Result<Post, Error>] = await withTaskGroup(
            of: (String, Result<Post, Error>).self
        ) { group in
            for favorite in favorites {
                group.addTask { [firestoreService] in
                    do {
                        let post = try await firestoreService.fetchPost(postId: favorite.postId)
                        return (favorite.postId, .success(post))
                    } catch {
                        return (favorite.postId, .failure(error))
                    }
                }
            }

            var collected: [String: Result<Post, Error>] = [:]
            for await (postId, result) in group {
                collected[postId] = result
            }
            return collected
        }

        var resolved: [Post] = []
        var unavailable = 0

        // favorites の順（新しい順）で並べ直す
        for (index, favorite) in favorites.enumerated() {
            guard let result = results[favorite.postId] else { continue }
            switch result {
            case let .success(post):
                resolved.append(post)
            case let .failure(error):
                if Self.isUnavailable(error) {
                    // 削除済み・非公開化 → この1件だけ落とす（脚注で件数を伝える）
                    unavailable += 1
                } else {
                    // ネットワーク等の一時的な失敗 → ここで打ち切る。
                    // `index` が「ここまでに消費した件数」（この1件は消費していない）。
                    return PageResolution(
                        posts: resolved,
                        unavailable: unavailable,
                        consumed: index,
                        transientError: error
                    )
                }
            }
        }

        return PageResolution(posts: resolved, unavailable: unavailable, consumed: favorites.count)
    }

    /// 「もう出せない投稿」かどうかを判定する
    ///
    /// 削除済み（notFound）と、非公開化・フォロー解除で読めなくなったもの（permissionDenied）が該当。
    /// これ以外（ネットワーク断など）は一時的な失敗として扱い、再試行の余地を残す。
    private static func isUnavailable(_ error: Error) -> Bool {
        guard let serviceError = error as? FirestoreServiceError else { return false }

        switch serviceError {
        case .notFound:
            return true
        case let .fetchFailed(underlying):
            let nsError = underlying as NSError
            return nsError.code == FirestoreErrorCode.permissionDenied.rawValue
        default:
            return false
        }
    }

    // MARK: - Types

    /// 1ページ分の解決結果
    private struct PageResolution {
        /// 解決できた投稿（favorites の順）
        var posts: [Post] = []
        /// 出せなかった（削除済み・非公開）件数。**消費した範囲内**のみ数える
        ///
        /// ⚠️ 切り詰めて捨てた後半に unavailable が混じっていても数えない。
        ///    数えると、再取得したときに二重計上されて脚注の件数が膨らむ。
        var unavailable = 0
        /// 消費した favorites の件数（切り詰め後）。カーソルはここまでしか進めない
        var consumed = 0
        /// 切り詰めの原因になった一時的な失敗
        var transientError: Error?
    }

    /// 連続して繰ったページの積み上げ結果
    private struct PageBatch {
        var posts: [Post] = []
        var unavailable = 0
        /// 次に続ける位置（＝解決を終えた最後の1件の createdAt）
        var cursor: Date?
        var hasMore = false
        var transientError: Error?
    }
}
