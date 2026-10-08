//
//  SoratomoTimelineViewModel.swift
//  Soramoyou
//
//  そらとものグループのタイムラインの ViewModel ⭐️
//  （tasks 13.5・13.6・design.md の SoratomoTimelineView・ViewModel・
//   要件 8.1〜8.3・8.10・8.11・8.13・8.15〜8.20・10.9・12.1・14.3・15.4）
//
//  - 監視は 2 本: グループ（名前・メンバー数）と、タイムライン（投稿の新しい順・上限 20 → 40 → 60 …）
//  - 監視の札はこの ViewModel のプロパティに持つ。張り直しは札の上書きだけで古い監視が止まる
//  - グループを最初に読めたらルーターへ「読めた」、読めなかったら「読めなかった」を知らせる（12.1 の記録）
//  - 自分の投稿の削除（13.6）: 通信の確認 → 投稿のデータの削除 → 成功なら画像とキャッシュの後始末（画面は待たせない）
//  - ⭐️ 通報・ブロック・隠す・続き読み（release-gate 10.1・要件 1.6・5.1〜5.8・9.1〜9.9・15.1）:
//    自分以外の投稿だけに通報とブロックを許し、隠す集合（ブロックした投稿者・この端末で通報した投稿）で表示を絞る。
//    全部隠れても続きを読む（自動で連続 3 回まで、その後は「さらに読み込む」）
//
//  ⚠️ この ViewModel はサービスの容れ物（SoratomoDependencies）を受け取らない。
//     protocol とクロージャと、隠す集合の 2 つの部品（SoratomoBlockedAuthors・SoratomoReportedSkies）だけを受け取り、
//     単体テストではモックとクロージャと、テスト用の通知センター・UserDefaults で作った部品で作る。
//

import Combine
import Foundation

/// 通報とブロックの結果を伝える知らせ（release-gate 要件 5.4〜5.7・9.9）
enum SoratomoModerationNotice: Equatable {
    /// 「通報を受け付けました」
    case reportAccepted
    /// 「通報を送信できませんでした」
    case reportFailed
    /// 「この投稿はもうありません」
    case skyGone
    /// 「ブロックできませんでした」
    case blockFailed

    /// 画面に出す文言（タイムラインと投稿詳細で同じものを出す・失敗の文言は既存の定義を使う）
    var userMessage: String {
        switch self {
        case .reportAccepted:
            "通報を受け付けました"
        case .reportFailed:
            SoratomoFailedAction.report.userMessage
        case .skyGone:
            SoratomoError.skyGone.userMessage
        case .blockFailed:
            SoratomoFailedAction.block.userMessage
        }
    }
}

/// そらとものグループのタイムラインの ViewModel
@MainActor
final class SoratomoTimelineViewModel: ObservableObject {
    // MARK: - 型

    /// 日付ごとの投稿のまとまり（見出しは `SoratomoDaySection.title(for:)` の規則）
    struct Day: Identifiable, Equatable {
        /// その日の 0 時（端末のタイムゾーン）。見出しの鍵に使う
        let id: Date
        /// 見出しの文字列（「今日」「昨日」「M月d日」「yyyy年M月d日」）
        let title: String
        /// その日の投稿（新しい順）
        let skies: [SoratomoSky]
    }

    // MARK: - 定数

    /// 1 回に読む件数（最初の 20 件・末尾で 20 件ずつ足す・引き下げで 20 件に戻す・要件 8.2・8.3・8.11）
    static let pageSize = 20

    /// 表示が増えないときに、自分で上限を伸ばす連続の回数の上限（release-gate 9.7・
    /// ルートの一覧の `PaginatedPostsViewModel.maxPagesPerLoad` と同じ上限）
    static let maxAutoExtensions = 3

    // MARK: - 公開する状態

    /// 表示するグループの ID
    let groupId: String

    /// グループ（名前・メンバー数）。まだ読めていなければ nil
    @Published private(set) var group: SoratomoGroup?

    /// 表示中の投稿（作成日時の新しい順・削除済みのものは除く）
    @Published private(set) var skies: [SoratomoSky] = []

    /// タイムラインを 1 回でも読めたか（空の案内「まだ投稿がありません」を出してよいかの判定に使う）
    @Published private(set) var hasLoadedTimeline = false

    /// タイムラインの監視の失敗（読めていればnil）。投稿を読めていない間だけ、画面に失敗を出す
    @Published private(set) var timelineError: SoratomoError?

    /// 続きを読み込み中か（上限を伸ばして張り直し、まだ新しい結果が届いていない）
    @Published private(set) var isLoadingMore = false

    /// 削除の途中の投稿の ID（二重の削除を防ぎ、行に「削除中」を出す）
    @Published private(set) var deletingSkyIds: Set<String> = []

    /// 削除の失敗を伝える文言（出し終えたら画面が nil に戻す）
    @Published var deleteErrorMessage: String?

    /// 通報の途中の投稿の ID（二重の通報を防ぐ・要件 5.8）
    @Published private(set) var reportingSkyIds: Set<String> = []

    /// ブロックの途中の投稿者の uid（二重のブロックを防ぐ）
    @Published private(set) var blockingAuthorIds: Set<String> = []

    /// 通報とブロックの結果の知らせ（出し終えたら画面が nil に戻す）
    @Published var moderationNotice: SoratomoModerationNotice?

    /// 自動の続き読みが上限に達しても表示が増えず、続きがありうる（末尾に「さらに読み込む」を出す・9.7）
    @Published private(set) var canLoadMoreManually = false

    /// いまの監視の上限（20・40・60 …）
    private(set) var limit = SoratomoTimelineViewModel.pageSize

    /// 削除が成功した後の、画像の後始末のタスク（単体テストで完了を待つために公開する）
    private(set) var imageCleanupTask: Task<Void, Never>?

    // MARK: - 依存

    /// グループのサービス
    private let groupService: any SoratomoGroupServiceProtocol
    /// 投稿のサービス
    private let skyService: any SoratomoSkyServiceProtocol
    /// 画像の保存と削除
    private let imageStore: any SoratomoImageStoreProtocol
    /// いまログインしている利用者の uid（未ログインなら nil）
    private let currentUid: () -> String?
    /// 通信できる状態か（削除の前の確認・要件 8.19）
    private let isOnline: @MainActor () -> Bool
    /// グループを読めたことをルーターへ知らせる
    private let reportAccessible: @MainActor (String) -> Void
    /// グループを読めなかったことをルーターへ知らせる（ルーターが一覧へ戻す）
    private let reportNotAccessible: @MainActor (String) -> Void
    /// 届いた投稿を覚える（投稿詳細が読む・`SoratomoSkyLookup.remember`）
    private let rememberSkies: @MainActor ([SoratomoSky]) -> Void
    /// 削除した投稿を忘れる（`SoratomoSkyLookup.forget`）
    private let forgetSky: @MainActor (_ groupId: String, _ skyId: String) -> Void
    /// 削除した投稿の画像を、端末のキャッシュから消す（既定は `SoratomoImageCache.remove`）
    private let removeCachedImages: @MainActor (SoratomoImagePaths) -> Void
    /// 計測の記録（既定は `SoratomoAnalytics.log`。単体テストで差し替える）
    private let logEvent: (SoratomoEvent) -> Void
    /// 通報とブロック
    private let moderationService: any SoratomoModerationServiceProtocol
    /// ブロックした投稿者（アプリ全体で 1 つ）
    private let blockedAuthors: SoratomoBlockedAuthors
    /// この端末で通報した投稿（アプリ全体で 1 つ）
    private let reportedSkies: SoratomoReportedSkies

    // MARK: - 隠す集合の状態

    /// いまの隠す集合（2 つの部品の値の写し。部品が変わるたびに購読で入れ替える）
    private var hidden: SoratomoHiddenContent
    /// 隠す集合の購読
    private var hiddenSubscription: AnyCancellable?
    /// ブロックの一覧を読めたか（読めなかったら、次に start() が呼ばれたときに読み直す）
    private var hasLoadedBlockedAuthors = false
    /// ブロックの一覧を読み込み中か（start() が重なっても二重に読まない）
    private var isLoadingBlockedAuthors = false

    // MARK: - 続き読みの状態

    /// 自分で上限を伸ばした連続の回数（表示が増えたら 0 に戻す）
    private var autoExtensionCount = 0
    /// 上限を伸ばす前の表示の件数（伸ばした結果を待っている間だけ値がある）
    private var visibleCountBeforeExtension: Int?

    // MARK: - 監視の状態

    /// グループの監視の札（持っている間だけ監視が続く）
    private var groupToken: SoratomoListenerToken?
    /// タイムラインの監視の札（上限を変えるときは上書きで張り直す）
    private var timelineToken: SoratomoListenerToken?

    /// グループの読み取りの結果をルーターへ知らせたか（最初の 1 回だけ知らせる）
    private var hasReportedAccess = false

    /// 最後に受け取ったタイムラインの内容（同じ内容のスナップショットを無視するため）
    ///
    /// `includeMetadataChanges: true` の監視なので、キャッシュ由来かどうか（`isFromCache`）だけが変わった
    /// 通知も届く。中身（投稿の並びと「続きがありうるか」）が同じなら何もしない。
    private var lastSkies: [SoratomoSky]?
    /// 最後に受け取った「続きがありうるか」
    private var lastMayHaveMore = false

    /// 削除が確定した投稿の ID（監視の遅れた結果に、消した投稿が混ざっていても出さないため）
    private var deletedSkyIds: Set<String> = []

    // MARK: - Init

    /// - Parameters:
    ///   - groupId: 表示するグループの ID
    ///   - groupService: グループのサービス
    ///   - skyService: 投稿のサービス
    ///   - imageStore: 画像の保存と削除
    ///   - currentUid: いまログインしている利用者の uid を返す
    ///   - isOnline: 通信できる状態かを返す
    ///   - reportAccessible: グループを読めたときに呼ぶ（本番は `SoratomoRouter.reportAccessible(groupId:)`）
    ///   - reportNotAccessible: グループを読めなかったときに呼ぶ（本番は `SoratomoRouter.reportNotAccessible(groupId:)`）
    ///   - rememberSkies: 届いた投稿を覚える（本番は `SoratomoSkyLookup.remember`）
    ///   - forgetSky: 削除した投稿を忘れる（本番は `SoratomoSkyLookup.forget`）
    ///   - moderationService: 通報とブロック
    ///   - blockedAuthors: ブロックした投稿者（本番は `SoratomoDependencies.live.blockedAuthors`）
    ///   - reportedSkies: この端末で通報した投稿（本番は `SoratomoDependencies.live.reportedSkies`）
    ///   - removeCachedImages: 削除した投稿の画像をキャッシュから消す。既定は `SoratomoImageCache.remove`
    ///   - logEvent: 計測の記録。既定は本番の `SoratomoAnalytics.log`
    init(
        groupId: String,
        groupService: any SoratomoGroupServiceProtocol,
        skyService: any SoratomoSkyServiceProtocol,
        imageStore: any SoratomoImageStoreProtocol,
        currentUid: @escaping () -> String?,
        isOnline: @escaping @MainActor () -> Bool,
        reportAccessible: @escaping @MainActor (String) -> Void,
        reportNotAccessible: @escaping @MainActor (String) -> Void,
        rememberSkies: @escaping @MainActor ([SoratomoSky]) -> Void,
        forgetSky: @escaping @MainActor (_ groupId: String, _ skyId: String) -> Void,
        moderationService: any SoratomoModerationServiceProtocol,
        blockedAuthors: SoratomoBlockedAuthors,
        reportedSkies: SoratomoReportedSkies,
        removeCachedImages: @escaping @MainActor (SoratomoImagePaths) -> Void = { SoratomoImageCache.remove($0) },
        logEvent: @escaping (SoratomoEvent) -> Void = SoratomoAnalytics.log
    ) {
        self.groupId = groupId
        self.groupService = groupService
        self.skyService = skyService
        self.imageStore = imageStore
        self.currentUid = currentUid
        self.isOnline = isOnline
        self.reportAccessible = reportAccessible
        self.reportNotAccessible = reportNotAccessible
        self.rememberSkies = rememberSkies
        self.forgetSky = forgetSky
        self.removeCachedImages = removeCachedImages
        self.logEvent = logEvent
        self.moderationService = moderationService
        self.blockedAuthors = blockedAuthors
        self.reportedSkies = reportedSkies
        hidden = SoratomoHiddenContent(blockedAuthorIds: blockedAuthors.ids, reportedSkies: reportedSkies.keys)

        // 隠す集合が変わったら、届いている結果から直ちに作り直す（9.4 の「手動で更新しなくても」）。
        // ⚠️ @Published は値が入る「前」に流れるので、部品のプロパティは読まず、流れてきた値を使う。
        //    receive(on:) を付けないのは、変更と同じ流れで直ちに作り直すため（部品はどちらもメインアクター）
        hiddenSubscription = blockedAuthors.$ids
            .combineLatest(reportedSkies.$keys)
            .dropFirst()
            .sink { [weak self] ids, keys in
                MainActor.assumeIsolated {
                    self?.applyHidden(SoratomoHiddenContent(blockedAuthorIds: ids, reportedSkies: keys))
                }
            }
    }

    // MARK: - 監視の開始

    /// グループとタイムラインの監視を始める（画面の表示で呼ぶ）
    ///
    /// すでに監視しているものは張り直さない（投稿詳細から戻ったときなど、何度呼んでもよい）。
    /// - この端末で通報した投稿を、いまの利用者の分に読み込む（読む場所がほかに無いため、ここで読む）
    /// - ブロックの一覧を読み込んでから、タイムラインの監視を始める（最初の表示でブロックした相手を出さない・9.6）。
    ///   読めなかったら表示を優先して監視を始め、次に呼ばれたときに読み直す
    func start() async {
        if groupToken == nil {
            observeGroup()
        }
        if let uid = currentUid(), !uid.isEmpty {
            if reportedSkies.currentUid != uid {
                reportedSkies.load(uid: uid)
            }
            if !hasLoadedBlockedAuthors, !isLoadingBlockedAuthors {
                isLoadingBlockedAuthors = true
                let service = moderationService
                hasLoadedBlockedAuthors = await blockedAuthors.load(uid: uid) { uid in
                    try await service.fetchBlockedUserIds(uid: uid)
                }
                isLoadingBlockedAuthors = false
            }
        }
        // 待っている間に、重なった start() が監視を始めていれば張り直さない
        if timelineToken == nil {
            observeTimeline()
        }
    }

    /// 末尾に達したとき・「さらに読み込む」を押したときに呼ぶ。続きがありうるなら、上限を 20 件伸ばして張り直す（要件 8.3・9.7）
    ///
    /// いまの上限の結果がまだ届いていない間（読み込み中）・続きが無いときは何もしない（二重に伸ばさない）。
    /// 利用者の操作なので、自動の続き読みの回数は 0 に戻す。
    func loadMoreIfNeeded() {
        guard hasLoadedTimeline, !isLoadingMore, lastMayHaveMore else { return }

        autoExtensionCount = 0
        canLoadMoreManually = false
        extendLimit()
    }

    /// 引き下げて更新したときに呼ぶ。上限を 20 件に戻して、最新の 20 件を取り直す（要件 8.11）
    ///
    /// 張り直しの間も、読み込んだ投稿は出したままにする（ちらつかせない）。
    /// グループの監視が失敗で止まっていれば、グループも張り直す。
    func refresh() {
        limit = Self.pageSize
        isLoadingMore = false
        autoExtensionCount = 0
        canLoadMoreManually = false
        visibleCountBeforeExtension = nil
        observeTimeline()
        if groupToken == nil {
            observeGroup()
        }
    }

    // MARK: - 表示用

    /// 投稿を日付ごとに区切ったもの（端末のタイムゾーン・新しい順）
    /// - Parameters:
    ///   - now: 現在時刻（テストで差し替える）
    ///   - calendar: 日付の区切りに使うカレンダー（テストでタイムゾーンを固定する）
    func days(now: Date = Date(), calendar: Calendar = SoratomoDaySection.deviceCalendar) -> [Day] {
        var result: [Day] = []
        for sky in skies {
            let start = SoratomoDaySection.startOfDay(for: sky.createdAt, calendar: calendar)
            if let last = result.last, last.id == start {
                result[result.count - 1] = Day(id: last.id, title: last.title, skies: last.skies + [sky])
            } else {
                let title = SoratomoDaySection.title(for: sky.createdAt, now: now, calendar: calendar)
                result.append(Day(id: start, title: title, skies: [sky]))
            }
        }
        return result
    }

    /// この投稿の削除の操作を出してよいか（投稿者本人だけ・要件 8.15）
    func canDelete(_ sky: SoratomoSky) -> Bool {
        guard let uid = currentUid(), !uid.isEmpty else { return false }
        return sky.authorId == uid
    }

    /// この投稿に通報とブロックの操作を出してよいか（自分以外の投稿だけ・要件 5.1・5.2・9.1）
    func canModerate(_ sky: SoratomoSky) -> Bool {
        guard let uid = currentUid(), !uid.isEmpty else { return false }
        return sky.authorId != uid
    }

    /// この投稿を見せないか（ブロックした投稿者・この端末で通報した投稿・要件 9.4・9.6）
    func isHidden(_ sky: SoratomoSky) -> Bool {
        hidden.hides(sky)
    }

    /// 空の案内（「まだ投稿がありません」）を出してよいか
    ///
    /// 読めていて、表示が 0 件で、続きも無いときだけ。全部隠れていて続きがありうるときは出さない（9.7）。
    var showsEmptyGuide: Bool {
        hasLoadedTimeline && skies.isEmpty && !lastMayHaveMore
    }

    // MARK: - 通報とブロック（release-gate 10.1）

    /// 投稿を通報する（理由を選んで確定した後に呼ぶ）
    ///
    /// 1. 自分の投稿・通報の途中なら何もしない（要件 5.2・5.8）
    /// 2. 前回の知らせを消す（一度失敗すると以後の成功が出ない、を作らない・5.4）
    /// 3. 通信できなければ、送らずに失敗を出す
    /// 4. 成功したら、この端末の通報の記録に足して隠し、受け付けたことを出す（5.5）
    /// 5. 投稿がもう無い（`.skyGone`）なら、削除済みと同じく取り除いて「もう無い」を出す（5.7）
    /// 6. それ以外の失敗では、隠さずに失敗を出す（5.6）
    /// - Returns: 受け付けられたら true
    @discardableResult
    func report(_ sky: SoratomoSky, reason: ReportReason, source: SoratomoModerationSource) async -> Bool {
        guard canModerate(sky), !reportingSkyIds.contains(sky.id), let uid = currentUid() else { return false }
        moderationNotice = nil

        guard isOnline() else {
            failReport(.network)
            return false
        }

        reportingSkyIds.insert(sky.id)
        defer { reportingSkyIds.remove(sky.id) }

        do {
            try await moderationService.report(groupId: sky.groupId, skyId: sky.id, reason: reason)
        } catch .skyGone {
            removeFromTimeline(sky)
            moderationNotice = .skyGone
            logEvent(.reportFailed(.notFound))
            return false
        } catch {
            failReport(error)
            return false
        }

        reportedSkies.add(SoratomoSkyKey(sky), uid: uid)
        moderationNotice = .reportAccepted
        logEvent(.reportSubmitted(reason: reason, source: source))
        return true
    }

    /// 投稿者をブロックする（確認ダイアログで確定した後に呼ぶ）
    ///
    /// 成功したら、ブロックの一覧に足して隠す（既存のブロックの通知はサービスが送る・9.3・9.4・9.8）。
    /// 失敗したら、隠さずに失敗を出す（9.9）。
    /// - Returns: 保存できたら true
    @discardableResult
    func block(_ sky: SoratomoSky, source: SoratomoModerationSource) async -> Bool {
        let authorId = sky.authorId
        guard canModerate(sky), !blockingAuthorIds.contains(authorId), let uid = currentUid() else { return false }
        moderationNotice = nil

        blockingAuthorIds.insert(authorId)
        defer { blockingAuthorIds.remove(authorId) }

        do {
            try await moderationService.block(uid: uid, authorId: authorId)
        } catch {
            moderationNotice = .blockFailed
            return false
        }

        blockedAuthors.add(authorId)
        logEvent(.userBlocked(source: source))
        return true
    }

    // MARK: - 削除（tasks 13.6）

    /// 自分の投稿を削除する（確認ダイアログで確定した後に呼ぶ）
    ///
    /// 1. 投稿者本人でなければ何もしない。削除の途中なら何もしない（二重の確定を防ぐ）
    /// 2. 通信できなければ、始めずに「削除できませんでした」を出す（`reason=network`）
    /// 3. 投稿のデータを消す。失敗したら:
    ///    - 結果が確定しない失敗（`.network`・`.permissionDenied`）は、サーバーで有無を確かめる。
    ///      無ければ成功として扱う。有る・確かめられなければ、投稿を残したまま失敗を出す
    ///      （すでに無い投稿の削除はルールが評価できず `.permissionDenied` になるため、これも確かめる）
    ///    - それ以外の失敗は、投稿を残したまま失敗を出す
    /// 4. 成功したら、タイムラインから消し、覚えとキャッシュから消し、2 枚の画像の削除を裏で行う
    ///    （画像の削除は圏外で最大 120 秒かかりうるので、画面は待たせない。結果は `post_deleted` の `image_cleanup` に記録）
    func delete(_ sky: SoratomoSky) async {
        guard canDelete(sky), !deletingSkyIds.contains(sky.id) else { return }

        // 送る前の通信の確認（明らかに通信できないときは始めない）
        guard isOnline() else {
            fail(reasonFrom: .network)
            return
        }

        deletingSkyIds.insert(sky.id)
        defer { deletingSkyIds.remove(sky.id) }

        do {
            try await skyService.deleteSky(groupId: sky.groupId, skyId: sky.id)
        } catch {
            // 失敗は固定の文脈で記録する（文脈に ID・キャプションを混ぜない・要件 15.1・15.4）
            SoratomoError.record(error, context: "soratomo.deleteSky")
            guard Self.isUncertain(error) else {
                fail(reasonFrom: error)
                return
            }
            // 結果が確定しない失敗: サーバーで有無を確かめる
            do {
                let exists = try await skyService.skyExistsOnServer(groupId: sky.groupId, skyId: sky.id)
                if exists {
                    fail(reasonFrom: error)
                    return
                }
                // サーバーに無い → 削除は済んでいる。成功として続ける
            } catch let checkError {
                // 確かめられなかった: 投稿を残したまま失敗を出す（理由は削除の失敗のほう）
                SoratomoError.record(checkError, context: "soratomo.skyExistsOnServer")
                fail(reasonFrom: error)
                return
            }
        }

        finishDeletion(of: sky)
    }

    // MARK: - Private: 監視

    /// グループの監視を張る（札の上書きで、前の監視は止まる）
    private func observeGroup() {
        groupToken = groupService.observeGroup(groupId: groupId) { [weak self] result in
            self?.handleGroup(result)
        }
    }

    /// タイムラインの監視を、いまの上限で張る（札の上書きで、前の監視は止まる）
    private func observeTimeline() {
        timelineToken = skyService.observeTimeline(groupId: groupId, limit: limit) { [weak self] result in
            self?.handleTimeline(result)
        }
    }

    /// グループの監視の結果を受け取る
    ///
    /// - 最初に読めたら、ルーターへ「読めた」を 1 回だけ知らせる
    /// - メンバーでない（`.notMember`）・拒否（`.permissionDenied`）は「読めなかった」として知らせる
    ///   （ルーターがパスにこのタイムラインがあるときだけ一覧へ戻す）。読めた後にメンバーでなくなったときも戻す
    /// - 通信の失敗（`.network`）は、読めないと決まったわけではない（端末のキャッシュに無いだけのこともある）ので、
    ///   一覧へは戻さず、オフラインの表示のまま待つ（要件 12.1）。⚠️ このとき監視の札は手放さない
    ///   （サービスの監視は続いていて、つながれば正しい結果が届く。札を捨てると監視が外れ、通信が戻っても
    ///   グループ名・人数・ルーターへの知らせが来ない。レビューで直した）
    private func handleGroup(_ result: Result<SoratomoGroup, SoratomoError>) {
        switch result {
        case let .success(newGroup):
            if group != newGroup {
                group = newGroup
            }
            if !hasReportedAccess {
                hasReportedAccess = true
                reportAccessible(groupId)
            }
        case let .failure(error):
            SoratomoError.record(error, context: "soratomo.observeGroup")
            switch error {
            case .notMember, .permissionDenied:
                hasReportedAccess = true
                reportNotAccessible(groupId)
            case .network:
                // 監視は続いている（キャッシュに無いだけ・再接続を待っている）。札を持ったまま、つながるのを待つ
                break
            default:
                // 失敗で止まった監視は、引き下げの更新（refresh）で張り直す。読めていたグループ名は出したままにする
                groupToken = nil
            }
        }
    }

    /// タイムラインの監視の結果を受け取る
    private func handleTimeline(_ result: Result<SoratomoTimelineSnapshot, SoratomoError>) {
        switch result {
        case let .success(snapshot):
            isLoadingMore = false
            if timelineError != nil {
                timelineError = nil
            }
            // 同じ内容（メタデータだけが変わった通知など）なら何もしない
            if lastSkies == snapshot.skies, lastMayHaveMore == snapshot.mayHaveMore {
                return
            }
            lastSkies = snapshot.skies
            lastMayHaveMore = snapshot.mayHaveMore
            hasLoadedTimeline = true

            rebuildSkies()
            continueReadingIfStalled()
        case let .failure(error):
            isLoadingMore = false
            SoratomoError.record(error, context: "soratomo.observeTimeline")
            // 読み込んだ投稿があれば、出したままにする（失敗は投稿が無いときだけ出す）
            timelineError = error
            // 失敗で止まった監視は、引き下げの更新（refresh）で張り直す
            timelineToken = nil
        }
    }

    // MARK: - Private: 隠す・続き読み

    /// 届いている結果から、表示する投稿を作り直す
    ///
    /// 削除が確定した投稿（遅れた結果に混ざっていても出さない）と、隠す集合に当たる投稿を除く。
    /// 表示する投稿は、投稿詳細が読めるように覚える（隠した投稿は覚えに戻さない）。
    private func rebuildSkies() {
        guard let lastSkies else { return }
        let visible = lastSkies.filter { !deletedSkyIds.contains($0.id) && !hidden.hides($0) }
        rememberSkies(visible)
        skies = visible
    }

    /// 隠す集合が変わった
    ///
    /// 届いている結果から作り直す。全部隠れて続きがありうるなら、続きを読む（ブロックの直後に、
    /// 何も出ず末尾の行も無いので読み込みが始まらない、を作らない）。
    private func applyHidden(_ newHidden: SoratomoHiddenContent) {
        guard newHidden != hidden else { return }
        hidden = newHidden
        guard hasLoadedTimeline else { return }
        rebuildSkies()
        if !isLoadingMore {
            continueReadingIfStalled()
        }
    }

    /// 表示が増えない・0 件で、続きがありうるなら、自分で上限を伸ばす（9.7）
    ///
    /// - 伸ばした結果を待っていたなら、表示が増えたかを見る。増えたら回数を 0 に戻して終わる
    /// - 待っていなければ、表示が 0 件のとき（最初の読み込み・全部隠れた）だけ続きを読む
    /// - 連続 `maxAutoExtensions` 回伸ばしても増えなければ、末尾に「さらに読み込む」を出す
    private func continueReadingIfStalled() {
        if let before = visibleCountBeforeExtension {
            visibleCountBeforeExtension = nil
            if skies.count > before {
                autoExtensionCount = 0
                canLoadMoreManually = false
                return
            }
        } else if !skies.isEmpty {
            return
        }

        guard lastMayHaveMore else {
            canLoadMoreManually = false
            return
        }
        if autoExtensionCount < Self.maxAutoExtensions {
            autoExtensionCount += 1
            extendLimit()
        } else {
            canLoadMoreManually = true
        }
    }

    /// 上限を 20 件伸ばして張り直す（結果が届くまで「読み込み中」）
    private func extendLimit() {
        visibleCountBeforeExtension = skies.count
        limit += Self.pageSize
        isLoadingMore = true
        observeTimeline()
    }

    /// 投稿をタイムラインから取り除き、覚えから外す（削除が確定した・通報で「もう無い」と分かった）
    ///
    /// ⚠️ 画像の後始末はしない（他人の投稿の画像を消しに行かないため）。自分の削除は `finishDeletion` が続けて行う。
    private func removeFromTimeline(_ sky: SoratomoSky) {
        deletedSkyIds.insert(sky.id)
        skies.removeAll { $0.id == sky.id }
        if var cached = lastSkies {
            cached.removeAll { $0.id == sky.id }
            lastSkies = cached
        }
        forgetSky(sky.groupId, sky.id)
    }

    /// 通報の失敗を出して記録する（投稿は隠さない・要件 5.6）
    private func failReport(_ error: SoratomoError) {
        moderationNotice = .reportFailed
        logEvent(.reportFailed(SoratomoReportFailReason(error)))
    }

    // MARK: - Private: 削除

    /// 結果が確定しない失敗か（サーバーに届いて消えている可能性がある）
    ///
    /// - `.network`: 通信の途中で切れた・期限切れ（サーバーには届いた可能性がある）
    /// - `.permissionDenied`: すでに無い投稿の削除は、ルールが評価できずに拒否される
    private static func isUncertain(_ error: SoratomoError) -> Bool {
        error == .network || error == .permissionDenied
    }

    /// 削除の失敗を出して記録する（投稿は残す・要件 8.19）
    private func fail(reasonFrom error: SoratomoError) {
        deleteErrorMessage = SoratomoFailedAction.deleteSky.userMessage
        logEvent(.postDeleteFailed(SoratomoDeleteFailReason(error)))
    }

    /// 投稿のデータを消せた後の処理（タイムラインから消し、画像の後始末を裏で行う）
    private func finishDeletion(of sky: SoratomoSky) {
        removeFromTimeline(sky)

        let paths = sky.imagePaths
        // 端末のキャッシュは先に消す（削除した画像が端末に残らないように）
        removeCachedImages(paths)

        // 画像の削除は画面を待たせない（圏外で最大 120 秒）。self を捕まえず、画面を閉じても最後まで行う。
        // 画像の削除の失敗は、画像のサービスが非致命エラーとして記録済み（要件 8.20）。投稿は戻さない
        let store = imageStore
        let log = logEvent
        imageCleanupTask = Task {
            let outcome = await store.delete(paths)
            log(.postDeleted(imageCleanup: outcome == .deleted ? .deleted : .failed))
        }
    }
}
