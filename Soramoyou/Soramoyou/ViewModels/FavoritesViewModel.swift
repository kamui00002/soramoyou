//
//  FavoritesViewModel.swift
//  Soramoyou
//
//  「私のお気に入りの空」一覧の ViewModel ⭐️
//
//  他人のお気に入り（`init(ownerId:viewerId:)`）⭐️:
//    持ち主が「お気に入りを見せる」を ON にしていると、フォロワーは持ち主の favorites を読める（ルール）。
//    他人用では ① 公開の投稿だけを出す ② 閲覧者がブロックしている人の投稿を除く ③ 件数を数えない・見せない
//    ④ 閲覧者の 🔖 の変化で一覧を変えない ⑤ 読み取りの拒否は「見られなくなりました」にする。
//    ⑥ 投稿詳細で投稿者をブロックしたら（`.userBlocked`）、一覧からすぐ消し、以降のページからも除く（⭐️ 1.18.0 PR-B）。
//    本人用の振る舞い（`init(ownUserId:)`）は何も変えていない。
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

import FirebaseFirestore
import Foundation

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

    /// 「続きはあるのに、今回の読み込みでは表示できる投稿が1件も増えなかった」状態
    ///
    /// ⚠️ ページ繰りの予算を使い切ったときに立つ。一覧が0件のときも、非空のときも起きうる。
    ///    `.onAppear` 起点の自動ページ送りは**末尾セルの id が変わらないと再発火しない**ので、
    ///    この状態で手動の導線を出さないと、ユーザーはそこから先へ進めなくなる。
    @Published private(set) var stalledWithMore = false

    /// 他人のお気に入りが「見られなくなった」状態（他人用だけで立つ）⭐️
    ///
    /// 見ている間に持ち主が「お気に入りを見せる」を OFF にした・フォローが外れた、などで
    /// favorites の読み取りがルールに拒否（permission-denied）されたときに立つ。
    /// ⚠️ `lastError`（汎用のエラー画面・「再試行」を促す）とは別物。拒否は待っても直らないので、
    ///    エラーではなく「見られなくなりました」の空の表示にする。
    @Published private(set) var isAccessRevoked = false

    // MARK: - Dependencies

    /// 閲覧者自身の userId（未ログインなら nil）
    ///
    /// ⚠️ 意味は今までどおり「閲覧者」。読む favorites の持ち主は `ownerId`（本人用では同じ値）。
    let ownUserId: String?

    /// 読む favorites の持ち主の userId（本人用なら `ownUserId` と同じ・他人用なら相手）⭐️
    let ownerId: String?

    /// 他人のお気に入りを見ているか ⭐️
    ///
    /// true のとき: 公開の投稿だけを出す・閲覧者がブロックしている人の投稿を除く・
    /// 件数を見せない・🔖 の解除で一覧から消さない（`syncFavorited` を何もしない）。
    let isViewingOtherUser: Bool

    /// 「非公開・削除された空 N 件」などの**件数を画面に出してよいか** ⭐️
    ///
    /// ⚠️ 他人用では false。件数を出すと、フォロワーに「持ち主が非公開・フォロワー限定の投稿を
    ///    N 件お気に入りにしている」ことが分かってしまうため。View は件数を出す前に必ずこれを見る。
    ///    （他人用では `unavailableCount` も数えない＝0 のまま。View の分岐を漏らしても件数は出ない）
    var showsUnavailableCount: Bool {
        !isViewingOtherUser
    }

    private let firestoreService: FirestoreServiceProtocol
    private let pageSize: Int

    /// 1回の読み込みで繰るページ数の上限
    ///
    /// ⚠️ 削除済み・非公開の favorites だけが数百件ある人で無限に回らないための予算。
    private let maxPagesPerRequest: Int

    /// 1 回の読み込み（`load()` / `loadMore()` の 1 回）で繰る favorites のページ数の既定の上限 ⭐️ 1.18.0 PR-B
    ///
    /// 値は以前から両方の init の既定値に直書きしていた 5 のまま（名前を付けて 1 か所にしただけ・振る舞いは同じ）。
    /// 本番の `pageSize` 30 なら 1 回の読み込みで最大 150 件ぶん読む。
    /// - 少なすぎると: 見せられない空（本人用＝削除済み・非公開、他人用＝それに加えてフォロワー限定・
    ///   ブロック相手の投稿）が続く人で、すぐ予算切れになり「続きを読み込む」を何度も押させることになる。
    /// - 多すぎると: 1 回の読み込みでの読み取りが膨らむ（5 ページなら favorites の list 5 回＋投稿の get 最大 150 回）。
    /// 他人用もこの予算で「見せられる空が 1 件も無いページ」を自動で読み進める（`fetchVisiblePages`）。
    /// ⚠️ `nonisolated` を付けるのは、init の既定値（メインアクターの外で評価される）から読むため。
    ///    付けないと「main actor-isolated static property … can not be referenced from a nonisolated context」の
    ///    警告になる（Swift 6 ではエラー）。変わらない Int の定数なのでどこから読んでも安全
    ///    （`SoratomoComposeViewModel.dailyPostLimit` と同じ形）。
    nonisolated static let defaultMaxPagesPerRequest = 5

    /// 投稿者のブロック通知（`.userBlocked`）の購読トークン ⭐️ 1.18.0 PR-B
    ///
    /// 他人用の init だけが購読する（本人用では nil のまま）。理由は `observeUserBlocked()` のコメント。
    private var userBlockedObserver: NSObjectProtocol?

    /// `.userBlocked` を購読する通知センター（テストで差し替える）⭐️ 1.18.0 PR-B
    ///
    /// 形は `SoratomoBlockedAuthors` と同じ（init で受け取り、deinit で同じ通知センターから外す）。
    private let notificationCenter: NotificationCenter

    /// 次ページ取得用カーソル（解決を終えた最後の favorite の createdAt。
    /// ページを最後まで消費したときは、壊れていて飛ばしたドキュメントも含めて読んだ最後の1件）
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

    /// 閲覧者がブロックしている人の userId（他人用だけで使う）⭐️
    ///
    /// `load()` のたびに読み直す（`loadMore()` では読み直さない）。読めなかったときは空にして続ける
    /// （`HomeViewModel.loadBlockedUsers` と同じ考え方＝ブロック一覧の失敗で一覧そのものを出さないことはしない）。
    private var viewerBlockedUserIds: Set<String> = []

    /// 本人のお気に入り（「私のお気に入りの空」・今までどおり）
    /// - Parameter ownUserId: 閲覧者自身の userId（＝読む favorites の持ち主。未ログインなら nil）
    init(ownUserId: String?,
         firestoreService: FirestoreServiceProtocol = FirestoreService(),
         pageSize: Int = 30,
         maxPagesPerRequest: Int = FavoritesViewModel.defaultMaxPagesPerRequest)
    {
        self.ownUserId = ownUserId
        ownerId = ownUserId
        isViewingOtherUser = false
        self.firestoreService = firestoreService
        self.pageSize = pageSize
        self.maxPagesPerRequest = maxPagesPerRequest
        // ⭐️ 1.18.0 PR-B: 本人用は `.userBlocked` を購読しない（理由は `observeUserBlocked()`）。
        //    通知センターは deinit で外すものが無いので、既定のものを入れておくだけ。
        notificationCenter = .default
    }

    /// 他人のお気に入り（他人のプロフィールの入口から開く）⭐️
    ///
    /// ⚠️ `pageSize` の既定値 30 は、ルールの `request.query.limit <= 30`（他人の favorites の list）と
    ///    結びついている。上げるとルールに拒否されて「見られなくなりました」になる。変えるならルールと同時に。
    /// - Parameters:
    ///   - ownerId: 読む favorites の持ち主（他人）の userId
    ///   - viewerId: 閲覧者自身の userId（ブロック一覧を読むのに使う）
    ///   - notificationCenter: `.userBlocked` を購読する通知センター。既定は `.default`（テストで差し替える）⭐️ 1.18.0 PR-B
    init(ownerId: String,
         viewerId: String,
         firestoreService: FirestoreServiceProtocol = FirestoreService(),
         pageSize: Int = 30,
         maxPagesPerRequest: Int = FavoritesViewModel.defaultMaxPagesPerRequest,
         notificationCenter: NotificationCenter = .default)
    {
        ownUserId = viewerId
        self.ownerId = ownerId
        isViewingOtherUser = true
        self.firestoreService = firestoreService
        self.pageSize = pageSize
        self.maxPagesPerRequest = maxPagesPerRequest
        self.notificationCenter = notificationCenter
        observeUserBlocked()
    }

    deinit {
        // ⭐️ 1.18.0 PR-B: 購読したのと同じ通知センターから外す（本人用は購読していないので nil のまま）
        if let observer = userBlockedObserver {
            notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Loading

    /// 1ページ目を読み込む（リセット付き。pull-to-refresh からも呼ばれる）
    func load() async {
        // 読む favorites の持ち主。本人用では閲覧者自身（`ownUserId` と同じ値）
        guard let userId = ownerId else {
            // 未ログインでは自分のお気に入りが存在しない。空表示で終える。
            resolvedPosts = []
            unfavoritedIds = []
            posts = []
            hasMore = false
            unavailableCount = 0
            loadMoreError = nil
            stalledWithMore = false
            return
        }

        // この取得の世代を確定。await 中により新しい load() が走ったら、こちらの結果は捨てる。
        fetchGeneration += 1
        let generation = fetchGeneration

        isLoading = true
        lastError = nil
        loadMoreError = nil
        stalledWithMore = false
        // 読み直すたびに「見られなくなった」をいったん解く（持ち主が ON に戻した・フォローし直した場合に戻れるように）
        isAccessRevoked = false
        // 世代が変わっていたら、ローディング解除は新しい load() 側の責務。
        // （世代を進めるのは load() だけで、進めた直後に必ず isLoading = true を立てるので、
        //   ここで解除を見送ってもスピナーが出たままになることはない）
        defer { if generation == fetchGeneration { isLoading = false } }

        // ⚠️ ブロック一覧は**他人用だけ**読む（本人用の振る舞いと読み取り回数は今までどおり）
        if isViewingOtherUser {
            await loadViewerBlockedUserIds()
            guard generation == fetchGeneration else { return }
        }

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
                // 記録に載せるのは閲覧者の uid（本人用では持ち主と同じ・他人用で相手の uid を載せない）
                ErrorHandler.logError(transientError, context: "FavoritesViewModel.load", userId: ownUserId)
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
            stalledWithMore = batch.hasMore && batch.posts.isEmpty
            logTruncationIfNeeded(batch, context: "FavoritesViewModel.load", userId: ownUserId)

            // ⚠️ 他人用では `favorites_viewed` を送らない。
            //    このイベントは「自分のお気に入りのアルバムを見た」数と、自分の削除済みのお気に入りの
            //    溜まり具合（unavailable_count・stalled_with_more）を見るためのもの。他人の分を混ぜると
            //    数の意味が変わる（他人用は件数を数えないので unavailable_count も 0 になる）。
            //    他人のお気に入りを開いた事実は、入口のボタンの `user_profile_section_opened` が記録している。
            if !isViewingOtherUser {
                LoggingService.shared.logEvent("favorites_viewed", parameters: [
                    "count": posts.count,
                    "unavailable_count": unavailableCount,
                    // 予算を使い切っても1件も出せなかったか
                    // （＝削除済みのお気に入りが溜まっている兆候。自己修復を入れるかの判断材料）
                    "stalled_with_more": stalledWithMore,
                ])
            }
        } catch {
            guard generation == fetchGeneration else { return }
            if isViewingOtherUser, Self.isPermissionDenied(error) {
                // 他人の favorites の読み取りがルールに拒否された（持ち主が OFF にした・フォローが外れた）。
                // 汎用のエラー画面にせず「見られなくなりました」にする。
                markAccessRevoked()
                return
            }
            resolvedPosts = []
            unfavoritedIds = []
            posts = []
            hasMore = false
            stalledWithMore = false
            lastError = error
            ErrorHandler.logError(error, context: "FavoritesViewModel.load", userId: ownUserId)
        }
    }

    /// 次のページを読み込んで末尾に追記する
    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        // 読む favorites の持ち主（本人用では閲覧者自身）
        guard let userId = ownerId, let cursor else { return }

        // このページングが属する世代。await 中に load() が走って世代が変わったら、
        // 古いカーソル基準の1ページを新しい一覧へ append しない。
        let generation = fetchGeneration

        isLoadingMore = true
        loadMoreError = nil
        // 世代不一致で早期 return しても追加読み込みが恒久ブロックされないよう、必ず解除する。
        defer { isLoadingMore = false }

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
            stalledWithMore = batch.hasMore && batch.posts.isEmpty
            logTruncationIfNeeded(batch, context: "FavoritesViewModel.loadMore", userId: ownUserId)
        } catch {
            guard generation == fetchGeneration else { return }
            if isViewingOtherUser, Self.isPermissionDenied(error) {
                // 続きを読む途中で持ち主が OFF にした・フォローが外れた。
                // 拒否は再試行しても直らないので、フッターの「再試行」ではなく「見られなくなりました」にする。
                // 出ている一覧も消す（持ち主が見せるのをやめたものを出し続けない）。
                markAccessRevoked()
                return
            }
            // 追加読み込みの失敗は画面全体をエラーにしない（既に出ているものは残す）。
            // 再試行できるよう hasMore は倒さず、フッターに失敗を出す。
            loadMoreError = error
            ErrorHandler.logError(error, context: "FavoritesViewModel.loadMore", userId: ownUserId)
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
    ///
    /// 🔴 他人用では**何もしない**。`FavoriteManager` が持つのは**閲覧者の** 🔖 で、ここに並ぶのは
    ///    **持ち主の**お気に入り。閲覧者が詳細で 🔖 を外しても（もともと付けていなくても）、
    ///    持ち主のお気に入りの一覧から消してはいけない。
    func syncFavorited(ids: Set<String>) {
        guard !isViewingOtherUser else { return }
        // 解除で消えた分は「非公開・削除で出せなかった件数」ではないので脚注には数えない。
        // hasMore も触らない（サーバー側にまだ次ページがある事実は変わらないため）。
        let hidden = Set(resolvedPosts.map(\.id)).subtracting(ids)
        guard hidden != unfavoritedIds else { return }
        unfavoritedIds = hidden
        refreshVisiblePosts()
    }

    // MARK: - ブロック通知（他人用だけ）⭐️ 1.18.0 PR-B

    /// 投稿詳細でのブロック（`.userBlocked` 通知）を購読する（他人用の init からだけ呼ぶ）
    ///
    /// 他人のお気に入りの一覧から投稿を開いて投稿者をブロックしても、今までは引っ張って更新するまで
    /// その人の投稿が一覧に残っていた。ホーム・ギャラリー・タグ・あなた向けはすぐ消している
    /// （`PaginatedPostsViewModel.setupUserBlockedObserver`）ので、同じ形で合わせる。
    ///
    /// ⚠️ 本人用（「私のお気に入りの空」）では購読しない。
    ///    本人用は「自分が 🔖 を付けた空のアルバム」で、投稿者をブロックしてもお気に入りが消えるわけではない。
    ///    本人用の振る舞いは今までどおり（ブロック相手の投稿も出す・ブロック一覧も読まない）にしておく。
    private func observeUserBlocked() {
        userBlockedObserver = notificationCenter.addObserver(
            forName: .userBlocked,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userId = notification.userInfo?[Notification.blockedUserIdKey] as? String,
                  !userId.isEmpty else { return }
            Task { @MainActor in
                self?.handleUserBlocked(userId)
            }
        }
    }

    /// ブロックした投稿者の投稿を、表示中の一覧と以降に読むページの両方から除く（他人用だけ）
    ///
    /// - 閲覧者のブロックの集合（`viewerBlockedUserIds`）に足す → 以降のページは `isShownToViewer` で除かれる。
    /// - 表示中の一覧は `refreshVisiblePosts()` で作り直す（そこでもブロックの集合を見る）。
    ///   全量の `resolvedPosts` から消すのではなく表示の段で絞るのは、読み込み中（`await` の最中）に
    ///   通知が来て、その後に戻ってきたページが `resolvedPosts` に入っても、表示には出さないため。
    /// - Parameter userId: ブロックした投稿者のユーザー ID
    private func handleUserBlocked(_ userId: String) {
        // 本人用は購読していないが、念のためここでも止める（本人用の振る舞いを変えない）
        guard isViewingOtherUser else { return }
        guard !viewerBlockedUserIds.contains(userId) else { return }
        viewerBlockedUserIds.insert(userId)
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
    ///   - userId: 読む favorites の持ち主の userId（本人用では閲覧者自身）
    ///   - startCursor: 開始位置（nil なら先頭から）
    /// - Returns: 積み上げた結果。`cursor` は解決を終えた最後の1件を指す
    ///   （ページを最後まで消費したときは、壊れていて飛ばしたドキュメントも含めて読んだ最後の1件）
    private func fetchVisiblePages(userId: String, after startCursor: Date?) async throws -> PageBatch {
        var batch = PageBatch(cursor: startCursor)

        for _ in 0 ..< maxPagesPerRequest {
            let page = try await firestoreService.fetchFavorites(
                userId: userId,
                limit: pageSize,
                after: batch.cursor
            )
            let favorites = page.favorites
            let resolution = await resolvePosts(for: favorites)

            batch.posts.append(contentsOf: resolution.posts)
            // ⚠️ 他人用では「出せなかった件数」を数えない（`showsUnavailableCount` のコメント参照）。
            //    0 のままにしておけば、View が件数の分岐を漏らしても件数は画面に出ない。
            if !isViewingOtherUser {
                batch.unavailable += resolution.unavailable
            }
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

            // ページを最後まで消費できた。カーソルは、壊れていて飛ばしたドキュメントも含めた
            // 「実際に読んだ最後の1件」まで進める。`favorites` の末尾で止めると、
            // ページ丸ごと壊れていたときに1歩も進まず、同じページを読み直し続ける。
            if let lastReadCreatedAt = page.lastReadCreatedAt {
                batch.cursor = lastReadCreatedAt
            }

            // 続きの有無は、変換後の件数ではなく実際に読んだドキュメント数で決まる `isExhausted` で判定する。
            // `favorites.count == pageSize` で見ると、壊れた1件を飛ばしただけの満杯のページで
            // 「続きなし」と誤判定してページ送りが止まる。
            batch.hasMore = !page.isExhausted
            // 1件でも出せたら止める。1件も出せなかったときだけ次のページへ進む。
            if !batch.posts.isEmpty || !batch.hasMore { return batch }
        }

        // 予算切れ。`hasMore` は true のまま返す。
        // ここで倒すと「お気に入りは全部消えました」という**嘘の断定**を表示することになる。
        //
        // ⭐️ 1.18.0 PR-B（他人用で残る穴）: 他人用も、見せられる空（公開・ブロック相手でない）が 1 件も無いページは
        //    上のループで自動で読み進める（1 件でも増えたら止まる・続きが無くなったら止まる）。
        //    ただし予算（`maxPagesPerRequest`・既定 5 ページ＝150 件）を使い切っても 0 件のままだと、ここで止まり、
        //    画面には「まだ続きがあります」と「続きを読み込む」が出る。このとき、フォロワーには
        //    「持ち主が、見せられない（フォロワー限定・非公開など）お気に入りを 150 件以上続けて持っている」ことが伝わってしまう。
        //    続きへ進む唯一の出口なので残している（読み取りを無制限にしないための上限との引き換え）。
        return batch
    }

    /// 切り詰めが起きたことをログに残す
    ///
    /// ⚠️ 画面（フッターの再試行）に出すだけでは**運用側から見えない**。
    ///    切り詰めが実ユーザーで発火しているのか、予算を使い切っているのかを後から
    ///    判断できるようにログにも残す（`docs/pre-release-checklist.md` §1）。
    private func logTruncationIfNeeded(_ batch: PageBatch, context: String, userId: String?) {
        guard let transientError = batch.transientError else { return }
        ErrorHandler.logError(transientError, context: "\(context)(truncated)", userId: userId)
    }

    /// 全量から「隠している投稿」を除いて表示用の `posts` を作り直す
    ///
    /// ⭐️ 1.18.0 PR-B: 閲覧者がブロックしている人の投稿もここで除く（`.userBlocked` を受けたときに、
    ///    表示中の一覧からすぐ消すため・`handleUserBlocked`）。
    ///    `viewerBlockedUserIds` は他人用でしか中身が入らない（読むのは他人用の `load()`・足すのは他人用の通知だけ）
    ///    ので、本人用では常に空＝本人用の表示は今までどおり。
    private func refreshVisiblePosts() {
        posts = resolvedPosts.filter {
            !unfavoritedIds.contains($0.id) && !viewerBlockedUserIds.contains($0.userId)
        }
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
                // ⚠️ 他人用はここで絞る（公開の投稿だけ・閲覧者がブロックしている人の投稿は除く）。
                //    ここで落とすと「消費はした（カーソルは進む）が表示しない」になり、
                //    切り詰め・カーソル・ページ繰りの仕組みはそのまま効く（1ページ丸ごと絞られても次のページへ繰る）。
                if isShownToViewer(post) {
                    resolved.append(post)
                }
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
    /// 判定基準はランキング・おすすめの空と共通（`PostAvailability`）。
    private static func isUnavailable(_ error: Error) -> Bool {
        PostAvailability.isUnavailable(error)
    }

    /// 閲覧者に見せてよい投稿か（本人用は常に true）⭐️
    ///
    /// 他人用は「公開」の投稿だけ（おすすめの空と同じく、誰が見ても同じ欄にするため）。
    /// フォロワー限定・非公開の投稿は、閲覧者が読める場合でも出さない。
    /// 閲覧者がブロックしている人の投稿も出さない（ホームなどの一覧と同じ）。
    private func isShownToViewer(_ post: Post) -> Bool {
        guard isViewingOtherUser else { return true }
        return post.visibility == .public && !viewerBlockedUserIds.contains(post.userId)
    }

    /// favorites の読み取りがルールに拒否された（permission-denied）か
    ///
    /// `fetchFavorites` は失敗を `FirestoreServiceError.fetchFailed(元のエラー)` で包んで投げる。
    /// 元のエラーの見分け方は `FollowRepository` / `SoratomoLeaveService` と同じ（ドメインとコードの両方を見る）。
    private static func isPermissionDenied(_ error: Error) -> Bool {
        guard case let .fetchFailed(underlying)? = error as? FirestoreServiceError else { return false }
        let nsError = underlying as NSError
        return nsError.domain == FirestoreErrorDomain
            && nsError.code == FirestoreErrorCode.permissionDenied.rawValue
    }

    /// 他人のお気に入りを「見られなくなった」状態にする（出ている一覧も消す）
    ///
    /// ⚠️ 想定どおりの状態（持ち主が OFF にした・フォローが外れた）なので、`ErrorHandler` には記録しない
    ///    （Crashlytics の非致命エラーに積むと、本物の不具合が埋もれる）。
    private func markAccessRevoked() {
        resolvedPosts = []
        unfavoritedIds = []
        posts = []
        hasMore = false
        cursor = nil
        lastError = nil
        loadMoreError = nil
        stalledWithMore = false
        isAccessRevoked = true
        print("ℹ️ 他人のお気に入り: 読み取りが拒否されたため「見られなくなりました」を表示します")
    }

    /// 閲覧者のブロック一覧を読む（他人用だけ）
    ///
    /// 読めなかったときは空にして続ける（`HomeViewModel.loadBlockedUsers` と同じ考え方）。
    /// ただし黙らずに記録には残す（ブロックした人の投稿が出てしまう可能性があるため）。
    private func loadViewerBlockedUserIds() async {
        guard let viewerId = ownUserId else {
            viewerBlockedUserIds = []
            return
        }
        do {
            viewerBlockedUserIds = try await Set(firestoreService.fetchBlockedUserIds(userId: viewerId))
        } catch {
            viewerBlockedUserIds = []
            ErrorHandler.logError(error, context: "FavoritesViewModel.loadViewerBlockedUserIds", userId: viewerId)
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
        /// 次に続ける位置（＝解決を終えた最後の1件の createdAt。
        /// ページを最後まで消費したときは、壊れていて飛ばしたドキュメントも含めて読んだ最後の1件）
        var cursor: Date?
        var hasMore = false
        var transientError: Error?
    }
}
