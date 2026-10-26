//
//  DailyPickViewModel.swift
//  Soramoyou
//
//  ホーム「すべて」の「今日のおすすめのそらもよう」カードの状態 ⭐️☁️
//
//  流れ: 今日の文書 → 無ければ前日の文書 → 候補を先頭から 1 件ずつ fetchPost →
//  公開・ブロックしていない投稿者の最初の 1 件を出す（ゲストも 1 件・名前は出さない＝利用者の決定 2026-10-26）。
//  ⚠️ 「私のおすすめの空」（publicProfiles.recommendedPostIds）とは別物。名前は dailyPick 系で統一する。
//

import Foundation

// MARK: - 表示する 1 件

/// カードに出す 1 件
struct DailyPickItem {
    /// 出す投稿（公開・ブロックしていない投稿者のもの）
    let post: Post
    /// 投稿者の表示名。ゲスト・取得失敗・名前なしは nil（カードは「ユーザー」と出す＝HomeView の投稿者欄と同じ扱い）
    let authorName: String?
    /// 出している文書の鍵（前日の文書なら前日の鍵）
    let dateKey: String
    /// postIds の何番目か（0 始まり）
    let candidateIndex: Int
    /// 今日の文書が無く、前日の文書から出しているか
    let isFallbackDay: Bool
}

// MARK: - 計装の差し替え口

/// 計装の送り先（テストでは記録するだけの偽物を渡す）
protocol DailyPickEventLogging: AnyObject {
    func logEvent(_ name: String, parameters: [String: Any]?)
}

/// 本番は LoggingService（PostHog・Firebase Analytics の両方に送る）。署名はそのまま合う
extension LoggingService: DailyPickEventLogging {}

// MARK: - セッション中 1 回の記録係

/// `daily_pick_shown`・`daily_pick_unavailable` を「同じ date_key でセッション中 1 回」に抑える記録係
///
/// タブの切り替えでホームが作り直される（＝VM も作り直される）ため、VM のインスタンス変数では守れない。
/// 本番は `shared`（アプリが生きている間だけ覚える）、テストはケースごとに `DailyPickSessionLog()` を作って渡す。
@MainActor
final class DailyPickSessionLog {
    static let shared = DailyPickSessionLog()

    /// 記録済みの鍵（イベント名と date_key を「#」でつないだもの）
    ///
    /// date_key は yyyy-MM-dd、イベント名は英小文字と「_」だけなので、「#」でつないでも別の組と同じ鍵にならない。
    private var markedKeys: Set<String> = []

    init() {}

    /// まだ記録していなければ記録して true、記録済みなら false
    /// - Parameters:
    ///   - event: イベント名（例: "daily_pick_shown"）
    ///   - dateKey: その日の鍵
    func markFirst(event: String, dateKey: String) -> Bool {
        // insert の inserted は「今回はじめて入った」ときだけ true（2 回目以降は false）
        markedKeys.insert(event + "#" + dateKey).inserted
    }
}

// MARK: - ViewModel

@MainActor
final class DailyPickViewModel: ObservableObject {
    /// カードに出す 1 件。nil ならカードを描かない
    @Published private(set) var item: DailyPickItem?

    private let dailyPickService: DailyPickServiceProtocol
    private let firestoreService: FirestoreServiceProtocol
    private let logger: DailyPickEventLogging
    private let sessionLog: DailyPickSessionLog
    private let notificationCenter: NotificationCenter
    private let now: () -> Date

    // MARK: - 計装の名前

    /// カードを出したとき（同じ date_key でセッション中 1 回）
    private static let shownEvent = "daily_pick_shown"
    /// カードをタップしたとき（タップのたび）
    private static let tappedEvent = "daily_pick_tapped"
    /// カードを出せなかったとき（同じ date_key でセッション中 1 回・reason が違っても 1 回）
    private static let unavailableEvent = "daily_pick_unavailable"
    /// 今日の文書も前日の文書も無い
    private static let reasonNoDocument = "no_document"
    /// 候補が全部「次へ」（削除済み・公開でない・ブロック中の投稿者）だった
    private static let reasonAllSkipped = "all_skipped"
    /// 一時的な失敗（ネットワーク断など）で止めた
    private static let reasonLoadFailed = "load_failed"

    // MARK: - 読み込みの状態（private）

    /// 「同じ鍵なら取り直さない」ための鍵（今日の鍵と、見ている人）
    private struct LoadKey: Equatable {
        /// その読み込みの今日の鍵（前日の文書を出していても今日の鍵）
        let today: String
        /// 見ている人の uid（ゲストは nil）
        let viewerId: String?
    }

    /// 出している item の元になった文書と、そのときの条件
    ///
    /// `.userBlocked` を受けて「同じ文書の次の候補」を探すとき、文書を読み直さずに続きから見るために持つ。
    private struct DisplayedContext {
        /// 出している文書（前日の文書なら前日のもの）
        let pick: DailyPick
        /// 出している文書の鍵
        let docKey: String
        /// 前日の文書から出しているか
        let isFallbackDay: Bool
        /// その読み込みの今日の鍵（`daily_pick_unavailable` の date_key に使う）
        let todayKey: String
        /// その読み込みで見ていた人（ゲストは nil）
        let viewerId: String?
    }

    /// 候補を先頭（または途中）から見た結果
    private enum CandidateResult {
        /// 出す投稿が決まった
        case found(post: Post, candidateIndex: Int, authorName: String?)
        /// 全部「次へ」だった
        case allSkipped
        /// 一時的な失敗で止めた（次の候補を取りに行かない）
        case stopped
        /// 後から別の読み込みが始まったので、この結果は捨てる
        case superseded
    }

    /// load 1 回ぶんの結果
    private enum LoadResult {
        /// 出す 1 件が決まった
        case shown(item: DailyPickItem, context: DisplayedContext)
        /// 出すものが無いと確定した（no_document / all_skipped）
        case unavailable(reason: String)
        /// 一時的な失敗で止めた（load_failed）
        case failed
        /// 後から別の読み込みが始まったので、この結果は捨てる
        case superseded
    }

    /// 出している item の元になった文書と条件（item が nil のときは nil）
    private var displayedContext: DisplayedContext?
    /// 「出した」か「出すものが無いと確定」で終わった最後の読み込みの鍵（load_failed では nil に戻す）
    private var settledLoadKey: LoadKey?
    /// 進行中の load の鍵（同じ鍵の load を重ねないため。ブロックを受けた次の候補探しのときは nil）
    private var runningLoadKey: LoadKey?
    /// 読み込み（load か、ブロックを受けた次の候補探し）が進行中か
    private var isResolving = false
    /// 読み込みの世代。読み込みを始めるたびに +1 し、await から戻ったときに一致しなければ結果を捨てる
    /// （force の連打などで、先に始めた読み込みの結果が後から始めた読み込みの結果を上書きしないため。
    ///   `PaginatedPostsViewModel.fetchGeneration` と同じ考え方）
    private var generation = 0
    /// 見ている人がブロックしている投稿者（ゲストは空）。`.userBlocked` を受けたら足す
    private var blockedUserIds: Set<String> = []
    /// この VM が生きている間に `.userBlocked` で受けた投稿者
    ///
    /// ブロックの一覧を読み込み中に通知が来ても取りこぼさないよう、読み込んだ一覧と合わせて使う。
    private var blockedByNotification: Set<String> = []
    /// 投稿者のブロック通知（`.userBlocked`）の購読トークン
    private var userBlockedObserver: NSObjectProtocol?

    init(
        dailyPickService: DailyPickServiceProtocol = DailyPickService(),
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        logger: DailyPickEventLogging = LoggingService.shared,
        // nil の既定値にしているのは、`.shared`（MainActor の static）を既定値の式に書くと
        // 既定値が MainActor の外で評価されて警告になるため（Swift 6 ではエラー）。本体の中で解決する
        sessionLog: DailyPickSessionLog? = nil,
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.dailyPickService = dailyPickService
        self.firestoreService = firestoreService
        self.logger = logger
        self.sessionLog = sessionLog ?? .shared
        self.notificationCenter = notificationCenter
        self.now = now
        setupUserBlockedObserver()
    }

    deinit {
        // 購読を外す先は、購読した（注入された）通知センター（SoratomoBlockedAuthors と同じ形）
        if let observer = userBlockedObserver {
            notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - 読み込み

    /// 今日のおすすめを読み込む（HomeView の onAppear からログイン条件なしで呼ぶ）
    ///
    /// - 同じ（今日の鍵・見ている人）で「出した」か「出すものが無いと確定」していれば、force でない限り何もしない。
    /// - 同じ鍵の読み込みが進行中なら、force でない限り重ねない。force は常に取り直し、後から始めた読み込みの結果だけを反映する。
    /// - 一時的な失敗（load_failed）では、出している item を消さない（引っ張って更新の失敗でカードが消えないように）。
    ///   次の呼び出しでは取り直す。
    /// - Parameters:
    ///   - viewerId: 見ている人の uid。ゲストは nil（ブロック一覧と名前を取りに行かない）
    ///   - force: 引っ張って更新のとき true（同じ鍵でも取り直す）
    func load(viewerId: String?, force: Bool = false) async {
        let keys = DailyPickKey.keys(now: now())
        let loadKey = LoadKey(today: keys.today, viewerId: viewerId)

        if !force {
            // 同じ鍵で終わっていれば取り直さない（タブの行き来・onAppear の重なりで読み取りを増やさない）
            if settledLoadKey == loadKey { return }
            // 同じ鍵の読み込みが進行中なら重ねない
            // （見ている人が変わったときは鍵が違うので、新しい読み込みを始めて古い結果を世代で捨てる）
            if isResolving, runningLoadKey == loadKey { return }
        }

        // この読み込みの世代（プロパティの generation と別の名前にして、取り違えないようにする）
        generation += 1
        let loadGeneration = generation
        isResolving = true
        runningLoadKey = loadKey

        let result = await resolveLoad(keys: keys, viewerId: viewerId, generation: loadGeneration)

        // 後から別の読み込み（force・見ている人の切り替え・ブロックを受けた次の候補探し）が始まっていたら、
        // この結果は捨てる（進行中の印も、後から始めた方が片付ける）
        guard loadGeneration == generation else { return }
        isResolving = false
        runningLoadKey = nil

        switch result {
        case let .shown(newItem, context):
            settledLoadKey = loadKey
            show(newItem, context: context)
        case let .unavailable(reason):
            settledLoadKey = loadKey
            hide()
            logUnavailableIfFirst(reason: reason, todayKey: keys.today, viewerId: viewerId)
        case .failed:
            // 次の呼び出しで取り直す
            settledLoadKey = nil
            // 出している item は消さない。ただし次の 2 つは下げる
            // - 別の人（ログアウトしてゲストになった等）の読み込みで出したもの
            //   （前の人の画面で読んだ名前や、今の人がブロックしている人の投稿を出し続けないため）
            // - 今の Set では出せなくなったもの（ブロックを受けて次の候補を探している間に force の読み込みが始まり、
            //   次の候補探しの結果が捨てられたまま、この読み込みが失敗した場合。ブロックした人の投稿を出し続けない）
            if let displayedContext, let current = item,
               displayedContext.viewerId != viewerId || outcome(for: current.post) != .show
            {
                hide()
            }
            logUnavailableIfFirst(reason: Self.reasonLoadFailed, todayKey: keys.today, viewerId: viewerId)
        case .superseded:
            // resolveLoad は世代が変わったときだけこれを返す＝上の guard で戻っているので、ここには来ない
            break
        }
    }

    /// カードがタップされたときに呼ぶ（計装だけ。画面の遷移は HomeView が selectedPost で行う）
    ///
    /// タップのたびに送る（重複は抑えない）。出しているものが無ければ何もしない。
    func recordTapped() {
        guard let item, let displayedContext else { return }
        logger.logEvent(Self.tappedEvent, parameters: eventParameters(for: item, viewerId: displayedContext.viewerId))
    }

    // MARK: - 読み込みの中身（private）

    /// 今日の文書 → 無ければ前日の文書 → ブロック一覧 → 候補、の順に見て、出す 1 件を決める
    /// - Parameters:
    ///   - keys: 今日の鍵と前日の鍵
    ///   - viewerId: 見ている人（ゲストは nil）
    ///   - generation: この読み込みの世代
    private func resolveLoad(
        keys: (today: String, fallback: String),
        viewerId: String?,
        generation: Int
    ) async -> LoadResult {
        // 1) 今日の文書。読み取りが throw したらそこで止める＝前日に回らない
        //    （今日の文書があるのに一時的に読めないだけかもしれない。前日の 1 枚を出すと「全員に同じ 1 枚」が崩れる）
        let todayPick: DailyPick?
        do {
            todayPick = try await dailyPickService.fetchDailyPick(dateKey: keys.today)
        } catch {
            print("❌ 今日のおすすめの文書（今日）の取得に失敗:", error.localizedDescription)
            return .failed
        }
        guard generation == self.generation else { return .superseded }

        // 2) 今日の文書が無ければ前日の文書。こちらも throw したら止める
        let pick: DailyPick
        let docKey: String
        let isFallbackDay: Bool
        if let todayPick {
            pick = todayPick
            docKey = keys.today
            isFallbackDay = false
        } else {
            let fallbackPick: DailyPick?
            do {
                fallbackPick = try await dailyPickService.fetchDailyPick(dateKey: keys.fallback)
            } catch {
                print("❌ 今日のおすすめの文書（前日）の取得に失敗:", error.localizedDescription)
                return .failed
            }
            guard generation == self.generation else { return .superseded }
            guard let fallbackPick else { return .unavailable(reason: Self.reasonNoDocument) }
            pick = fallbackPick
            docKey = keys.fallback
            isFallbackDay = true
        }

        // 3) ブロック一覧（ログイン中だけ）。失敗したら止める＝ブロック中の人の投稿を出してしまう危険を取らない
        if let viewerId {
            let fetched: [String]
            do {
                fetched = try await firestoreService.fetchBlockedUserIds(userId: viewerId)
            } catch {
                print("❌ 今日のおすすめ: ブロック一覧の取得に失敗:", error.localizedDescription)
                return .failed
            }
            guard generation == self.generation else { return .superseded }
            // 読み込み中に `.userBlocked` で受けた人も落とさない
            blockedUserIds = Set(fetched).union(blockedByNotification)
        } else {
            // ゲストはブロック一覧を持たない（読みに行かない・空の Set）
            blockedUserIds = []
        }

        // 4) 候補を先頭から
        let context = DisplayedContext(
            pick: pick,
            docKey: docKey,
            isFallbackDay: isFallbackDay,
            todayKey: keys.today,
            viewerId: viewerId
        )
        switch await resolveCandidates(in: pick, from: 0, viewerId: viewerId, generation: generation) {
        case let .found(post, candidateIndex, authorName):
            let newItem = DailyPickItem(
                post: post,
                authorName: authorName,
                dateKey: docKey,
                candidateIndex: candidateIndex,
                isFallbackDay: isFallbackDay
            )
            return .shown(item: newItem, context: context)
        case .allSkipped:
            return .unavailable(reason: Self.reasonAllSkipped)
        case .stopped:
            return .failed
        case .superseded:
            return .superseded
        }
    }

    /// 候補を startIndex から順に fetchPost して、出す 1 件を探す（load と、ブロックを受けた次の候補探しで共用）
    ///
    /// 読めた投稿は `outcome(for:)`（＝ `DailyPickResolver.classify(post:blockedUserIds:)`）、
    /// 読めなかった投稿は `DailyPickResolver.classify(error:)` で分ける。
    /// `.show` で決まり・`.skip` で次へ・`.stop` でそこで止める（次の候補を取りに行かない）。
    /// - Parameters:
    ///   - pick: 見る文書
    ///   - startIndex: 何番目の候補から見るか（0 始まり）
    ///   - viewerId: 見ている人（ゲストは nil＝名前を取りに行かない）
    ///   - generation: この読み込みの世代
    private func resolveCandidates(
        in pick: DailyPick,
        from startIndex: Int,
        viewerId: String?,
        generation: Int
    ) async -> CandidateResult {
        // サーバーが書くのは最大 5 件。手で増やされても端末で見る数は抑える
        let candidates = Array(pick.postIds.prefix(DailyPick.maxCandidates))

        // where で絞るのは、startIndex が候補の数を超えても範囲の作成で落ちないようにするため
        for index in candidates.indices where index >= startIndex {
            let post: Post
            do {
                post = try await firestoreService.fetchPost(postId: candidates[index])
            } catch {
                guard generation == self.generation else { return .superseded }
                switch DailyPickResolver.classify(error: error) {
                case .skip:
                    // 削除済み・読めない・壊れている → 次の候補へ
                    continue
                case .stop, .show:
                    // 一時的な失敗 → 止める（読めなかった投稿に .show は来ないが、来ても出せないので止める側に倒す）
                    print("❌ 今日のおすすめ: 候補の取得に失敗（そこで止める）:", error.localizedDescription)
                    return .stopped
                }
            }
            guard generation == self.generation else { return .superseded }

            switch outcome(for: post) {
            case .show:
                break
            case .skip:
                continue
            case .stop:
                return .stopped
            }

            // 名前（ログイン中だけ。失敗しても止めない）
            let authorName = await fetchAuthorName(of: post, viewerId: viewerId)
            guard generation == self.generation else { return .superseded }

            // 名前を待つ間に `.userBlocked` でこの投稿者がブロックされていたら、同じ規則でもう一度見て次へ
            guard outcome(for: post) == .show else { continue }
            return .found(post: post, candidateIndex: index, authorName: authorName)
        }
        return .allSkipped
    }

    /// 読めた投稿を、今のブロック済みの Set で分類する
    ///
    /// `DailyPickResolver.classify(post:blockedUserIds:)` を呼ぶのはここ 1 か所だけにしている
    /// （load・名前を待った後の見直し・ブロックを受けたときの判定が、同じ Set・同じ規則で動くように）。
    private func outcome(for post: Post) -> DailyPickOutcome {
        DailyPickResolver.classify(post: post, blockedUserIds: blockedUserIds)
    }

    /// 投稿者の表示名を読む（ログイン中だけ）
    ///
    /// ゲストは publicProfiles を読めない（firestore.rules）ので呼ばない。
    /// 失敗・nil・空白だけの名前は nil（カードは「ユーザー」と出す）。名前の取得の失敗では止めない。
    private func fetchAuthorName(of post: Post, viewerId: String?) async -> String? {
        guard viewerId != nil else { return nil }
        do {
            let profile = try await firestoreService.fetchPublicProfile(userId: post.userId)
            guard let name = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else {
                return nil
            }
            return name
        } catch {
            print("⚠️ 今日のおすすめ: 投稿者の名前の取得に失敗（名前なしで出す）:", error.localizedDescription)
            return nil
        }
    }

    // MARK: - 出す・下げる（private）

    /// item を出し、shown を同じ date_key でセッション中 1 回だけ送る
    private func show(_ newItem: DailyPickItem, context: DisplayedContext) {
        item = newItem
        displayedContext = context
        // ブロックを受けて同じ文書の次の候補に差し替えたときは同じ date_key なので、ここで false になり重ねて送らない
        if sessionLog.markFirst(event: Self.shownEvent, dateKey: newItem.dateKey) {
            logger.logEvent(Self.shownEvent, parameters: eventParameters(for: newItem, viewerId: context.viewerId))
        }
    }

    /// item を下げる
    private func hide() {
        item = nil
        displayedContext = nil
    }

    // MARK: - 計装（private）

    /// shown・tapped のパラメータ（uid・名前・キャプションは入れない。キー名に auth を含めない）
    private func eventParameters(for item: DailyPickItem, viewerId: String?) -> [String: Any] {
        [
            "date_key": item.dateKey,
            "candidate_index": item.candidateIndex,
            "is_fallback_day": item.isFallbackDay,
            "is_guest": viewerId == nil,
            "is_own_post": viewerId == item.post.userId,
        ]
    }

    /// `daily_pick_unavailable` を送る（同じ date_key＝今日の鍵でセッション中 1 回）
    ///
    /// 1 回の鍵は「イベント名と今日の鍵」だけで作り、reason は鍵に含めない。
    /// ＝その日に最初に起きた理由だけが届き、後から別の理由で出せなかったときは送らない
    /// （「出せなかった日」を 1 セッション 1 日 1 回で数えるため。reason が違うたびに送ると同じ日が何度も数えられる）。
    private func logUnavailableIfFirst(reason: String, todayKey: String, viewerId: String?) {
        guard sessionLog.markFirst(event: Self.unavailableEvent, dateKey: todayKey) else { return }
        logger.logEvent(
            Self.unavailableEvent,
            parameters: [
                "reason": reason,
                "date_key": todayKey,
                "is_guest": viewerId == nil,
            ]
        )
    }

    // MARK: - ブロック通知（private）

    /// 投稿詳細でのブロック（`.userBlocked` 通知）を購読する ☁️
    ///
    /// 形は `PaginatedPostsViewModel.setupUserBlockedObserver` と同じ。購読する先は注入された通知センター。
    private func setupUserBlockedObserver() {
        userBlockedObserver = notificationCenter.addObserver(
            forName: .userBlocked,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userId = notification.userInfo?[Notification.blockedUserIdKey] as? String,
                  !userId.isEmpty else { return }
            Task { @MainActor in
                await self?.handleUserBlocked(userId)
            }
        }
    }

    /// 投稿者がブロックされたとき
    ///
    /// ブロック済みの Set に足す。出している投稿の投稿者なら、同じ文書の次の候補（candidateIndex + 1 から）を
    /// load と同じ規則で探す（文書は読み直さない）。見つかれば差し替え、無ければ item = nil・unavailable "all_skipped"、
    /// 次が一時失敗なら item = nil（ブロックした人の投稿を出し続けない）。出している投稿の投稿者でなければ足すだけ。
    /// - Parameter userId: ブロックされたユーザーの ID
    private func handleUserBlocked(_ userId: String) async {
        blockedByNotification.insert(userId)
        blockedUserIds.insert(userId)

        // 出している投稿が、足した後の Set でもまだ出せるなら何もしない（＝出している投稿の投稿者ではない）
        guard let current = item, let context = displayedContext, outcome(for: current.post) != .show else { return }

        // 読み込みが進行中（引っ張って更新・前のブロックを受けた次の候補探し）なら、その読み込みが新しい Set で
        // 選び直すので、ここでは出している投稿を下げるだけにする（2 本を同時に走らせて item を取り合わないため）
        if isResolving {
            hide()
            return
        }

        // この次の候補探しの世代（プロパティの generation と別の名前にして、取り違えないようにする）
        generation += 1
        let searchGeneration = generation
        isResolving = true
        runningLoadKey = nil

        let result = await resolveCandidates(
            in: context.pick,
            from: current.candidateIndex + 1,
            viewerId: context.viewerId,
            generation: searchGeneration
        )
        // 探している間に load（force など）が始まっていたら、そちらの結果に任せる
        guard searchGeneration == generation else { return }
        isResolving = false

        switch result {
        case let .found(post, candidateIndex, authorName):
            let newItem = DailyPickItem(
                post: post,
                authorName: authorName,
                dateKey: context.docKey,
                candidateIndex: candidateIndex,
                isFallbackDay: context.isFallbackDay
            )
            show(newItem, context: context)
        case .allSkipped:
            hide()
            logUnavailableIfFirst(reason: Self.reasonAllSkipped, todayKey: context.todayKey, viewerId: context.viewerId)
        case .stopped:
            hide()
            // 次の load で取り直す（一時失敗の後は取り直す、の決まりに合わせる）
            settledLoadKey = nil
        case .superseded:
            // 上の guard で戻っているので、ここには来ない
            break
        }
    }
}
