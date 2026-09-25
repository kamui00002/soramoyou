//
//  GalleryViewModel.swift
//  Soramoyou
//
//  Created on 2025-01-19.
//
//  ギャラリー画面用ViewModel ⭐️
//  PaginatedPostsViewModelを継承し、グリッド表示に最適化された設定を提供
//  探索ヘッダー（絞り込み・並び替え・色で探す・シャッフル）に対応する。
//  並び替えには「週間 / 月間ランキング」（期間中に押されたいいねの数）も含む ⭐️

import Foundation
import FirebaseFirestore
import Combine

/// ギャラリーの並び替え順
///
/// 新着・人気は Firestore の `order(by:)` で並べ替える。
/// 週間・月間ランキングは「期間中に押されたいいね」をアプリ内で集計する（`RankingService`）。
enum GallerySortOrder: Equatable {
    /// 新着順（createdAt 降順）
    case newest
    /// 人気順（likesCount 降順＝全期間の累計）
    case popular
    /// 週間ランキング（直近 7 日に押されたいいねの数）⭐️
    case weeklyRanking
    /// 月間ランキング（直近 30 日に押されたいいねの数）⭐️
    case monthlyRanking

    /// Firestore の並び替えフィールド名（ランキングは Firestore で並べ替えないため nil）
    var sortField: String? {
        switch self {
        case .newest: return "createdAt"
        case .popular: return "likesCount"
        case .weeklyRanking, .monthlyRanking: return nil
        }
    }

    /// ランキングの集計期間（ランキング以外は nil）
    var rankingPeriod: RankingPeriod? {
        switch self {
        case .weeklyRanking: return .weekly
        case .monthlyRanking: return .monthly
        case .newest, .popular: return nil
        }
    }

    /// 計測（gallery_sort_changed の sort パラメータ）に送る値
    var analyticsValue: String {
        switch self {
        case .newest: return "newest"
        case .popular: return "popular"
        case .weeklyRanking: return "weekly_ranking"
        case .monthlyRanking: return "monthly_ranking"
        }
    }
}

/// ギャラリーの写真配置レイアウト
enum GalleryLayoutMode {
    /// 正方形グリッド（従来）
    case grid
    /// 写真の縦横比そのままのモザイク（Pinterest 風）
    case mosaic
}

/// ギャラリー画面のViewModel
///
/// PaginatedPostsViewModelを継承し、グリッド表示に特化した設定を提供する。
/// ページサイズをホームより多め（30件）に設定してグリッド表示に最適化。
///
/// 探索ヘッダーの状態（時間帯・空の種類・並び替え・色・シャッフル）を保持し、
/// `executeQuery` を分岐させて絞り込み／並び替え／色検索を行う。
@MainActor
class GalleryViewModel: PaginatedPostsViewModel {
    // MARK: - 探索ヘッダーの状態

    /// 絞り込み: 時間帯（nil=すべて）
    @Published var selectedTimeOfDay: TimeOfDay?
    /// 絞り込み: 空の種類（nil=すべて）
    @Published var selectedSkyType: SkyType?
    /// 並び替え順（既定: 新着）
    @Published var sortOrder: GallerySortOrder = .newest
    /// 色で探す: 選択中の16進カラーコード（nil=色モードOFF）
    @Published var selectedColor: String?
    /// 表示順をシャッフルしているか
    @Published var isShuffled: Bool = false
    /// 写真配置レイアウト（グリッド/モザイク）
    @Published var layoutMode: GalleryLayoutMode = .grid

    /// 色検索の RGB 距離しきい値（SearchView と同じ既定値）
    private let colorThreshold: Double = 0.3

    // MARK: - PaginatedPostsViewModel Overrides

    /// ViewModel名（エラーログ用）
    override var viewModelName: String { "GalleryViewModel" }

    /// グリッド表示用に多めに取得（30件/ページ）
    override var pageSize: Int { 30 }

    /// ブロックしているユーザーIDのリスト
    private var blockedUserIds: [String] = []

    // MARK: - ランキング ⭐️

    /// ランキングのキャッシュ有効期間（秒）
    ///
    /// チップで 週間 ⇄ 月間 ⇄ 新着 を行き来するたびに、期間中のいいねを読み直さないため。
    /// 引っ張って更新（refresh）したときはキャッシュを捨てて取り直す。
    static let rankingCacheLifetime: TimeInterval = 5 * 60

    /// 集計済みのランキング（期間ごと）。順位表示（RankingListView）の元データにも使う
    ///
    /// ⚠️ 「表示中の期間」ごとに分けて持つ。1 つの変数に上書きすると、
    ///    週間 → 月間 とチップを連打したときに、遅れて返ってきた週間の結果が
    ///    月間の一覧に週間の順位を付けてしまう（posts 側は世代トークンで守られているが、
    ///    順位表示の元データは守られない）。
    @Published private(set) var rankingResults: [RankingPeriod: RankingResult] = [:]

    /// 期間ごとのランキング取得の世代（最新の取得だけがキャッシュへ書けるようにする）
    ///
    /// ⚠️ 同じ期間の取得が重なる（取得中に引っ張って更新・同じチップの再選択）と、
    ///    先に始まった古い取得が後から返ってきて `rankingResults` を上書きしうる。
    ///    posts 側は基底クラスの世代トークンで古い結果が捨てられるので、
    ///    一覧は新しいのに順位表示だけ古い（欠ける・別の順位になる）状態になる。
    private var rankingRequestGenerations: [RankingPeriod: Int] = [:]

    /// ランキング取得サービス
    private let rankingService: RankingServiceProtocol
    /// 現在時刻の取得元（テストでキャッシュ期限を検証できるよう差し替え可能）
    private let now: () -> Date

    /// ランキングに並ぶ投稿の投稿者（userId → 公開プロフィール）⭐️
    ///
    /// ランキング表示（`RankingListView`）で投稿者のアバターと名前を出すために使う。
    /// `Post` には表示名が無いため、HomeViewModel / TagDetailViewModel と同じく
    /// `publicProfiles` から一括取得してメモリに持つ（`users` は isOwner 制限で他人のものは読めない）。
    ///
    /// ⚠️ 取得するのはランキング表示中だけ。通常の新着・人気のグリッドは投稿者名を出さないので、
    ///    そこで読み取りを増やさない。
    @Published private(set) var authorsByUserId: [String: PublicProfile] = [:]

    // MARK: - Initialization

    /// 初期化
    /// - Parameters:
    ///   - firestoreService: Firestoreサービス（テスト時にモックを注入可能）
    ///   - rankingService: ランキング取得サービス（nil なら firestoreService を使う既定実装）
    ///   - now: 現在時刻の取得元
    init(
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        rankingService: RankingServiceProtocol? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.rankingService = rankingService ?? RankingService(firestoreService: firestoreService)
        self.now = now
        super.init(firestoreService: firestoreService)
    }

    // MARK: - 探索状態の派生プロパティ

    /// 時間帯・空の種類のいずれかで絞り込み中か
    var hasActiveFilter: Bool {
        selectedTimeOfDay != nil || selectedSkyType != nil
    }

    /// 色で探すモードか
    var isColorMode: Bool {
        selectedColor != nil
    }

    /// 実際に適用される並び替え順
    ///
    /// 時間帯／空の種類で絞り込み中は「新着」に固定する（人気・ランキングとも）。
    /// 「絞り込み × 人気順」の複合インデックス増殖を避けるための設計上の割り切り。
    /// ランキングも同じ扱いに揃える（上位 30 件を絞り込むと「絞り込み内のランキング」ではなくなるため）。
    var effectiveSortOrder: GallerySortOrder {
        hasActiveFilter ? .newest : sortOrder
    }

    /// 週間 / 月間ランキングを表示中か
    var isRankingMode: Bool {
        effectiveSortOrder.rankingPeriod != nil
    }

    /// 表示中のランキング（ランキング表示中でなければ nil）
    var currentRankingResult: RankingResult? {
        guard let period = effectiveSortOrder.rankingPeriod else { return nil }
        return rankingResults[period]
    }

    /// 投稿の順位情報（ランキング表示中で、その投稿が順位表に入っていれば返す）
    func rankedEntry(for postId: String) -> RankedPost? {
        currentRankingResult?.entries.first { $0.post.id == postId }
    }

    /// ランキング表示に並べる順位付き投稿（`RankingListView` に渡す）⭐️
    ///
    /// 「いま `posts` に残っている投稿だけ」を「`posts` の並び順」で返す。
    /// - ランキング時の `posts` は `executeQuery` が `result.entries.map(\.post)` をそのまま入れたもの
    ///   （＝順位の昇順）で、シャッフルもされない（`fetchPosts` / `toggleShuffle` がランキング時は並べ替えない）。
    /// - ブロック除外（`filterBlockedUsers`）や削除（`removePost`）で `posts` から消えた投稿は、
    ///   ここを `posts` 起点にしておくことで自動的に表示からも消える。
    ///   順位（`rank`）は詰め直さない＝集計時の順位をそのまま出す（旧 RankingBadge と同じ扱い）。
    ///
    /// ⚠️ 順位表に対応する項目が無い投稿は並べない。通常は起きない
    ///    （posts と順位表は同じ取得の結果で、世代トークンで食い違いを防いでいる）。
    ///    body の評価のたびに呼ばれるため、ここでログは出さない。
    var rankingDisplayEntries: [RankedPost] {
        posts.compactMap { rankedEntry(for: $0.id) }
    }

    // MARK: - Fetch Overrides

    /// 投稿を取得（ブロックユーザーのフィルタリング付き）
    override func fetchPosts() async {
        // ⚠️ ブロックリストの読み込みはここでなく `executeQuery`（1 ページ目）で行う。
        //    ここで先に await すると、並び替え（sortOrder）だけ新しくなった状態で `posts` が前の一覧のまま残り、
        //    ランキング表示が「前の一覧 × 新しい期間の順位表」で一瞬空白・誤った順位になるため。
        //    super.fetchPosts は最初の await より前に `isLoading = true` / `posts = []` を行うので、
        //    タップ直後から読み込み中表示になる。
        await super.fetchPosts()
        filterBlockedUsers()
        // 色で探すモード・ランキングは単発取得のため、追加読み込みを無効化する
        if isColorMode || isRankingMode {
            hasMorePosts = false
        }
        // シャッフルON時は初回ページを並べ替える（ランキングは順位が意味なので並べ替えない）
        if isShuffled && !isRankingMode {
            posts.shuffle()
        }
        // ランキング表示中だけ、投稿者の名前・アバターを一括取得する ⭐️
        // （通常のグリッドは投稿者名を出さないので、余計な読み取りを増やさない）
        // loadMorePosts はランキング時に即 return するため、ここ 1 か所で足りる。
        if isRankingMode {
            await fetchAuthorsForCurrentPosts()
        }
    }

    /// 次のページの投稿を取得（ブロックユーザーのフィルタリング付き）
    override func loadMorePosts() async {
        // 色で探すモード（searchByColor）・ランキング（上位 30 件）は一括取得なのでページングしない
        guard !isColorMode && !isRankingMode else { return }

        let previousCount = posts.count
        await super.loadMorePosts()
        filterBlockedUsers()

        // シャッフルON時は「新しく追加された分だけ」を並べ替える。
        // 既存表示分の順序を保つことで、スクロール中に見た写真が飛び回るのを防ぐ。
        if isShuffled && posts.count > previousCount {
            let appended = Array(posts[previousCount...]).shuffled()
            posts.replaceSubrange(previousCount..., with: appended)
        }
    }

    // MARK: - 探索操作（View から呼ぶ）

    /// 時間帯で絞り込む（同じ値の再選択で解除）
    func selectTimeOfDay(_ timeOfDay: TimeOfDay?) async {
        selectedTimeOfDay = (selectedTimeOfDay == timeOfDay) ? nil : timeOfDay
        // 色モードとは排他（色で探す状態は解除する）
        selectedColor = nil
        // 絞り込み中の並び替えは effectiveSortOrder が新着に固定するため、ユーザー選択の
        // sortOrder 自体は書き換えない（絞り込み解除後に元の並び順を復元するため／レビュー F5）
        LoggingService.shared.logEvent(
            "gallery_filter_selected",
            parameters: ["filter_type": "time_of_day", "value": selectedTimeOfDay?.rawValue ?? "cleared"]
        )
        await fetchPosts()
    }

    /// 空の種類で絞り込む（同じ値の再選択で解除）
    func selectSkyType(_ skyType: SkyType?) async {
        selectedSkyType = (selectedSkyType == skyType) ? nil : skyType
        selectedColor = nil
        LoggingService.shared.logEvent(
            "gallery_filter_selected",
            parameters: ["filter_type": "sky_type", "value": selectedSkyType?.rawValue ?? "cleared"]
        )
        await fetchPosts()
    }

    /// 並び替え順を変更する
    func setSortOrder(_ order: GallerySortOrder) async {
        // 絞り込み中は新着以外（人気・ランキング）に切り替えられない（新着固定）
        if order != .newest && hasActiveFilter { return }
        sortOrder = order
        // 並び替えは通常モード。色モードを抜ける
        selectedColor = nil
        LoggingService.shared.logEvent(
            "gallery_sort_changed",
            parameters: ["sort": order.analyticsValue]
        )
        await fetchPosts()
    }

    /// 色で探す（同じ色の再選択で解除）。色モードは絞り込み・並び替えと排他。
    func selectColor(_ color: String?) async {
        selectedColor = (selectedColor == color) ? nil : color
        if isColorMode {
            selectedTimeOfDay = nil
            selectedSkyType = nil
            sortOrder = .newest
        }
        LoggingService.shared.logEvent(
            "gallery_color_searched",
            parameters: ["color": selectedColor ?? "cleared"]
        )
        await fetchPosts()
    }

    /// 表示順シャッフルを切り替える
    func toggleShuffle() async {
        // ランキングは順位そのものが内容なのでシャッフルしない（ボタンも無効化している）
        guard !isRankingMode else { return }
        isShuffled.toggle()
        LoggingService.shared.logEvent(
            "gallery_shuffle_toggled",
            parameters: ["state": isShuffled ? "on" : "off"]
        )
        if isShuffled {
            // ON: 取得済みの投稿をその場でシャッフル（再取得不要）
            posts.shuffle()
        } else {
            // OFF: 元の並び順に戻すため再取得する
            await fetchPosts()
        }
    }

    /// 表示レイアウト（グリッド/モザイク）を切り替える
    func toggleLayoutMode() {
        layoutMode = (layoutMode == .grid) ? .mosaic : .grid
        LoggingService.shared.logEvent(
            "gallery_layout_toggled",
            parameters: ["mode": layoutMode == .mosaic ? "mosaic" : "grid"]
        )
    }

    // MARK: - Refresh

    /// 引っ張って更新: ランキングのキャッシュも捨てて取り直す
    override func refresh() async {
        rankingResults = [:]
        await super.refresh()
    }

    // MARK: - Query Hook

    /// Firestore クエリを実行する（探索状態に応じて分岐）
    ///
    /// - ランキング: 期間中のいいねをアプリ内で集計して上位 30 件を一括取得（ページング無効）
    /// - 色モード: `searchByColor` で一括取得（ページング無効）
    /// - 通常: 時間帯／空の種類フィルタ ＋ 並び替え ＋ ページング
    override func executeQuery(lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        // 1 ページ目の取得時だけブロックリストを読み直す（従来 fetchPosts の先頭で行っていたのと同じ頻度）。
        // ランキング集計（loadRanking）と、取得後の filterBlockedUsers の両方がこの結果を使う。
        if lastDocument == nil {
            await loadBlockedUsers()
        }

        // ランキング: 2 ページ目以降は無い（空を返してページング終了）
        if let period = effectiveSortOrder.rankingPeriod {
            if lastDocument != nil {
                return (posts: [], lastDocument: nil)
            }
            let result = try await loadRanking(period: period)
            return (posts: result.entries.map(\.post), lastDocument: nil)
        }

        // 色で探すモード: SearchView と同じ一括取得方式。
        // RGB 距離のクライアント側フィルタで件数が減りページング判定を壊すため、
        // 2ページ目以降は取得しない（空を返してページング終了）。
        if let color = selectedColor {
            if lastDocument != nil {
                return (posts: [], lastDocument: nil)
            }
            let colorPosts = try await firestoreService.searchByColor(color, threshold: colorThreshold)
            return (posts: colorPosts, lastDocument: nil)
        }

        // 通常モード: フィルタ＋並び替え＋ページング
        return try await firestoreService.fetchPostsWithSnapshot(
            timeOfDay: selectedTimeOfDay,
            skyType: selectedSkyType,
            sortField: effectiveSortOrder.sortField ?? "createdAt",
            limit: pageSize,
            lastDocument: lastDocument
        )
    }

    // MARK: - ランキング取得

    /// ランキングを取得する（有効期間内ならキャッシュを返す）
    private func loadRanking(period: RankingPeriod) async throws -> RankingResult {
        let currentTime = now()
        if let cached = rankingResults[period],
           currentTime.timeIntervalSince(cached.fetchedAt) < Self.rankingCacheLifetime {
            return cached
        }

        let requestGeneration = (rankingRequestGenerations[period] ?? 0) + 1
        rankingRequestGenerations[period] = requestGeneration

        let result = try await rankingService.fetchRanking(
            period: period,
            blockedUserIds: Set(blockedUserIds),
            now: currentTime
        )
        // より新しい同じ期間の取得が始まっていたら、キャッシュ（順位表示の元データ）へは書かない。
        // 呼び出し元の fetchPosts も世代違いで posts を捨てるので、ここでは結果を返すだけでよい。
        guard rankingRequestGenerations[period] == requestGeneration else {
            return result
        }
        rankingResults[period] = result

        // いいねの読み取り量が上限に近づいていないかを運用側で見るための計測
        // （is_truncated=true が出始めたらサーバー集計への切り替えどき。RankingService の注記参照）
        LoggingService.shared.logEvent("ranking_loaded", parameters: [
            "period": period.rawValue,
            "entry_count": result.entries.count,
            "like_count": result.likeCount,
            "is_truncated": result.isTruncated
        ])
        return result
    }

    // MARK: - 投稿者の取得（ランキング表示用）⭐️

    // ⚠️ HomeViewModel / TagDetailViewModel の `fetchAuthorsForCurrentPosts` と同じ形
    //    （userId の重複排除 → 未取得分だけ並列取得 → 辞書に貯める）。
    //    ただし失敗を `try?` で黙って落とさず、どの userId が取れなかったかをログに残す。

    /// 現在 posts に含まれる userId のうち、未取得の PublicProfile を並列で取得する
    ///
    /// - 同じ人が複数枚ランクインしていても 1 回だけ読む（`Set` で重複排除）。
    /// - 一度取れた人は `authorsByUserId` に残るので、週間 ⇄ 月間の行き来で読み直さない。
    /// - 取得に失敗した人（プロフィール未作成・通信失敗など）は辞書に入れない。
    ///   表示側は「ユーザー」＋既定アバターに落とし、次にランキングを開いたときに取り直す。
    private func fetchAuthorsForCurrentPosts() async {
        let missingUserIds = Set(posts.map(\.userId))
            .subtracting(authorsByUserId.keys)
        guard !missingUserIds.isEmpty else { return }

        await withTaskGroup(of: PublicProfile?.self) { group in
            for userId in missingUserIds {
                group.addTask { [firestoreService] in
                    do {
                        return try await firestoreService.fetchPublicProfile(userId: userId)
                    } catch {
                        // 1 人取れなくてもランキング全体は表示を続ける（名前は「ユーザー」表示になる）。
                        // 取れなかった事実は運用で気づけるようログに残す（print はリリースビルドで運用に届かないため
                        // ErrorHandler 経由にする。notFound＝プロフィール未作成は userError 扱いで Crashlytics へは送られない）。
                        // ⚠️ logError の `userId:` 引数は Crashlytics の利用者 ID を設定するので、投稿者の ID は渡さず context に含める。
                        ErrorHandler.logError(error, context: "GalleryViewModel.fetchAuthorsForCurrentPosts authorId=\(userId)")
                        return nil
                    }
                }
            }
            for await profile in group {
                if let profile {
                    authorsByUserId[profile.id] = profile
                }
            }
        }
    }

    // MARK: - ブロックユーザー処理

    /// ブロックユーザーリストを読み込む
    private func loadBlockedUsers() async {
        let authService = AuthService()
        guard let currentUserId = authService.currentUser()?.id else { return }

        do {
            blockedUserIds = try await firestoreService.fetchBlockedUserIds(userId: currentUserId)
        } catch {
            blockedUserIds = []
        }
    }

    /// ブロックユーザーの投稿をフィルタリング
    private func filterBlockedUsers() {
        guard !blockedUserIds.isEmpty else { return }
        posts = posts.filter { !blockedUserIds.contains($0.userId) }
    }

    /// 投稿をローカル一覧から削除する（削除完了後のUI更新用）
    func removePost(postId: String) {
        posts.removeAll { $0.id == postId }
    }
}
