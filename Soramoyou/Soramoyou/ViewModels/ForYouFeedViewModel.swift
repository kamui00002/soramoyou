//
//  ForYouFeedViewModel.swift
//  Soramoyou
//
//  ホーム「あなた向け」セグメント用 ViewModel ⭐️
//
//  HomeViewModel を継承して、ブロックリスト・通報/ブロック操作・著者キャッシュ
//  （authorsByUserId）をそのまま再利用する。クエリだけを MergedFeedPaginator
//  （フォロー中の投稿＋フォロータグの投稿の k-way マージ）に差し替える。
//
//  基底 PaginatedPostsViewModel との噛み合わせ:
//  - executeQuery は引数の lastDocument を無視する。カーソルは Paginator 内の
//    各ストリームが自前で保持する（基底はカーソルを不透明にしか扱わないため安全）。
//  - リフレッシュでは Paginator を「新規インスタンス」に差し替える。基底の
//    fetchGeneration は古い結果を捨てるだけでカーソルを巻き戻さないため、
//    同一インスタンスの使い回しはページ飛びを起こす。
//

import FirebaseFirestore
import Foundation

@MainActor
final class ForYouFeedViewModel: HomeViewModel {
    // MARK: - Overrides（基底の設定）

    override var viewModelName: String { "ForYouFeedViewModel" }

    // MARK: - Dependencies / State

    /// ストリーム構成の組み立て役（テスト時にモックを注入可能）
    private let sourceBuilder: ForYouFeedSourceBuilderProtocol
    /// 現在のマージページネーター。fetchPosts のたびに新規作成する。
    private var paginator: MergedFeedPaginator?
    /// 計装（for_you_feed_loaded）用に直近のソース構成を保持
    private var lastSources: ForYouFeedSources?
    /// fetchPosts の並行実行ガード。
    /// executeQuery は self.paginator を読むため、リフレッシュの二重発火で
    /// 「古い取得が新しい Paginator の1ページ目を先に消費してしまう」競合が起きうる。
    /// 基底の fetchGeneration は「結果の破棄」しか守らないので、ここで直列化する。
    private var isRefreshing = false

    // MARK: - Initializer

    init(
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        authService: AuthServiceProtocol = AuthService(),
        sourceBuilder: ForYouFeedSourceBuilderProtocol = ForYouFeedSourceBuilder()
    ) {
        self.sourceBuilder = sourceBuilder
        super.init(firestoreService: firestoreService, authService: authService)
    }

    // MARK: - Fetch

    /// あなた向けフィードを取得（ソース構成 → Paginator 差し替え → 基底の取得フロー）
    override func fetchPosts() async {
        // 二重リフレッシュは無視する（先行の取得が完走して画面を更新する）
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // ゲスト（未認証）はホーム側でセグメント自体を出さないが、万一呼ばれても安全に空へ
        guard let userId = currentUserId else {
            posts = []
            hasMorePosts = false
            return
        }

        // ソース構成前の待ち時間もローディング表示にする（基底が立てるのは super 呼び出し後のため）
        isLoading = posts.isEmpty
        errorMessage = nil
        lastError = nil

        // ブロック集合（Paginator の emit 前除外用）。
        // 基底 HomeViewModel の blockedUserIds は private なので自前で取得する。
        // 取得失敗時はフィード継続を優先して空扱い（基底 loadBlockedUsers と同じ方針）。
        // ただし失敗は必ずテレメトリに残す（クラッシュしない不具合を本番で拾うため）。
        var blockedIds: Set<String> = []
        do {
            blockedIds = try await Set(firestoreService.fetchBlockedUserIds(userId: userId))
        } catch {
            ErrorHandler.logError(error, context: "ForYouFeedViewModel.fetchBlockedUserIds", userId: userId)
        }

        do {
            let sources = try await sourceBuilder.buildSources(for: userId)
            lastSources = sources
            paginator = MergedFeedPaginator(
                sources: sources.streams,
                fetchPageSize: pageSize,
                isBlocked: { blockedIds.contains($0) }
            )
        } catch {
            // ソース構成（フォロー一覧の取得）に失敗したら、無言の空フィードにせず
            // エラーとして表示する（欠陥C「無言で消える」の反省）
            ErrorHandler.logError(error, context: "ForYouFeedViewModel.buildSources", userId: userId)
            paginator = nil
            posts = []
            hasMorePosts = false
            lastError = error
            errorMessage = error.userFriendlyMessage
            isLoading = false
            return
        }

        // 基底の取得フロー（ブロックフィルタ・著者一括取得を含む）を実行
        await super.fetchPosts()

        // 基底は「取得件数 < pageSize なら hasMorePosts=false」と近似するが、
        // マージフィードの残量は Paginator が正確に知っているので上書きする
        // （GalleryViewModel が isColorMode 時に再代入しているのと同じ前例）。
        hasMorePosts = paginator?.hasMore ?? false

        // 計装: フィード構成の内訳（PII なし。件数と出所種別のみ）。
        // 取得失敗時（lastError あり）は発火しない: 失敗を「loaded・0件」として数えると
        // 空フィード率とエラー率が混ざり、PostHog 実査の母数が歪む。失敗側は
        // ErrorHandler 経由の error_occurred が既に拾っている。
        if lastError == nil, let sources = lastSources {
            LoggingService.shared.logEvent("for_you_feed_loaded", parameters: [
                "post_count": posts.count,
                "followee_count": sources.followeeCount,
                "tag_count": sources.tagCount,
                "tag_source": sources.tagSource,
            ])
        }
    }

    /// 次のページを取得（基底の取得フロー後に残量を Paginator の真値へ上書き）
    override func loadMorePosts() async {
        // リフレッシュが Paginator を差し替えてから基底 fetchPosts が世代を進めるまでの
        // await 窓（ブロックリスト取得など）に、最終投稿の .onAppear 由来の追加読み込みが
        // 割り込むと、新しい Paginator の1ページ目を先食いして先頭ページが無言欠落する。
        // 基底の isLoadingMore/hasMorePosts ガードはこの再入を防げないため、
        // リフレッシュ中は追加読み込みを受け付けない（レビュー D4）。
        guard !isRefreshing else { return }
        await super.loadMorePosts()
        hasMorePosts = paginator?.hasMore ?? false
    }

    // MARK: - Query Hook

    /// 基底のクエリ実行を Paginator のマージ取得に差し替える。
    /// - Note: 引数 lastDocument は使わない（カーソルは各ストリームが保持）。
    ///   戻りの lastDocument も常に nil（基底はカーソルを不透明に保存するだけなので無害）。
    override func executeQuery(
        lastDocument _: DocumentSnapshot?
    ) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        guard let paginator else {
            return (posts: [], lastDocument: nil)
        }
        let page = try await paginator.nextPage(limit: pageSize)
        return (posts: page, lastDocument: nil)
    }
}
