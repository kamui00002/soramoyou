//
//  SoratomoGroupListViewModelTests.swift
//  SoramoyouTests
//
//  そらとものグループ一覧の ViewModel のテスト ⭐️（tasks 13.1）
//
//  - `soratomo_opened`（group_count）を、最初に読めたときだけ 1 回記録すること
//  - 読めなかったときは記録せず、固定の文言を出すこと
//  - 未ログインなら読まないこと
//  - 【leave-group 8.4】この端末で抜けたグループは、サーバーが「メンバーだ」と確かめたときだけ出し、記録から外すこと
//    （`.notMember`・`.unknown` では出さない・記録に無いグループは確かめない・`group_count` は隠した後の件数）
//  - 【leave-group 8.4】抜けた直後に一覧へ戻ったとき、読み直しの途中でも、前の一覧に抜けたグループを出さないこと
//

@testable import Soramoyou
import XCTest

// MARK: - テスト用の代役

/// 一覧の読み込み（`fetchMyGroups`）を、テストが放すまで返さないグループのサービス（leave-group 8.4）
///
/// 共有のモック（`MockSoratomoGroupService`）はすぐに結果を返すので、「読み直しの途中」の一覧を見ることができない。
/// そこで `gate()` の後の `fetchMyGroups` を止めておき、テストの合図（`releaseAll()`）で `groups` を返す。
/// `gate()` の前は止めずにすぐ返す（1 回目の読み込みで、前の一覧を作るため）。
/// ⚠️ 止めるかどうかの判断と、待ちの登録・放す合図は、同じロックの中で行う。放した後に届いた呼び出しは
///    止めずに返すので、合図より遅れて待ちに入った呼び出しが、永久に止まることは無い。
private final class SoratomoGroupListGatedGroupService: SoratomoGroupServiceProtocol, @unchecked Sendable {
    /// 止めるかどうかと待っている呼び出しを、複数のスレッドから同時に触らないためのロック
    private let lock = NSLock()
    private var gated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// `fetchMyGroups` が返すグループ
    let groups: [SoratomoGroup]

    /// - Parameter groups: `fetchMyGroups` が返すグループ
    init(groups: [SoratomoGroup]) {
        self.groups = groups
    }

    /// 返すのを待っている呼び出しの数
    var waitingCount: Int {
        lock.withLock { waiters.count }
    }

    /// これから先の `fetchMyGroups` を、`releaseAll()` まで止める
    func gate() {
        lock.withLock { gated = true }
    }

    /// 止めるのをやめ、待っている呼び出しを、すべて返す
    func releaseAll() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            gated = false
            let pending = waiters
            waiters = []
            return pending
        }
        pending.forEach { $0.resume() }
    }

    func fetchMyGroups(uid _: String) async throws(SoratomoError) -> [SoratomoGroup] {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // 止めていなければ、すぐに返す（待ちに入れない）
            let resumeNow = lock.withLock { () -> Bool in
                guard gated else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
        return groups
    }

    func createGroup(name _: String, requestId _: UUID) async throws(SoratomoError) -> SoratomoGroupSummary {
        throw .unknown
    }

    func joinGroup(code _: SoratomoInviteCode) async throws(SoratomoError) -> SoratomoJoinResult {
        throw .unknown
    }

    func regenerateInviteCode(groupId _: String) async throws(SoratomoError) -> SoratomoInviteCode {
        throw .unknown
    }

    func observeGroup(
        groupId _: String,
        onChange _: @escaping @MainActor (Result<SoratomoGroup, SoratomoError>) -> Void
    ) -> SoratomoListenerToken {
        SoratomoListenerToken {}
    }

    func fetchMembers(groupId _: String) async throws(SoratomoError) -> [SoratomoMember] {
        throw .unknown
    }
}

// MARK: - テスト

@MainActor
final class SoratomoGroupListViewModelTests: XCTestCase {
    /// テストごとの UserDefaults の suite 名（本物の記録を汚さない・`SoratomoLeftGroupsTests` と同じ作り方）
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "SoratomoGroupListViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    /// このテストの suite に書く「抜けたグループの記録」
    private func makeLeftGroups() -> SoratomoLeftGroups {
        SoratomoLeftGroups(defaults: defaults)
    }

    /// 記録した計測を覚える
    private final class EventLog {
        var events: [SoratomoEvent] = []
    }

    /// テスト用のグループ
    private func makeGroup(id: String) -> SoratomoGroup {
        SoratomoGroup(
            id: id,
            name: "空の会",
            ownerId: "owner",
            inviteCode: SoratomoInviteCode.parse(userInput: "ABCD-EFGH")!,
            memberCount: 3,
            createdAt: Date(timeIntervalSince1970: 0),
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
    }

    func testFirstSuccessfulLoadLogsOpenedOnceWithGroupCount() async {
        let service = MockSoratomoGroupService()
        service.fetchMyGroupsResult = .success([makeGroup(id: "g1"), makeGroup(id: "g2")])
        let log = EventLog()
        let viewModel = SoratomoGroupListViewModel(
            groupService: service,
            currentUid: { "me" },
            leaveService: MockSoratomoLeaveService(),
            leftGroups: makeLeftGroups(),
            logEvent: { log.events.append($0) }
        )

        await viewModel.load()
        await viewModel.load()

        // 2 回読んでも、記録は最初の 1 回だけ
        XCTAssertEqual(log.events, [.opened(groupCount: 2)])
        XCTAssertEqual(service.fetchMyGroupsCalls, ["me", "me"])
        guard case let .loaded(groups) = viewModel.state else {
            return XCTFail("読み込みが完了していない")
        }
        XCTAssertEqual(groups.map(\.id), ["g1", "g2"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testFailedLoadShowsFixedMessageAndDoesNotLogOpened() async {
        let service = MockSoratomoGroupService()
        service.fetchMyGroupsResult = .failure(.network)
        let log = EventLog()
        let viewModel = SoratomoGroupListViewModel(
            groupService: service,
            currentUid: { "me" },
            leaveService: MockSoratomoLeaveService(),
            leftGroups: makeLeftGroups(),
            logEvent: { log.events.append($0) }
        )

        await viewModel.load()

        XCTAssertTrue(log.events.isEmpty)
        XCTAssertEqual(viewModel.errorMessage, SoratomoError.network.userMessage)
    }

    func testOpenedFromNotificationDoesNotLogOpened() async {
        // 通知から開いたとき（一覧の上にタイムライン）は、入口から開いたことにならない（14.3 の点検で直した）
        let service = MockSoratomoGroupService()
        service.fetchMyGroupsResult = .success([makeGroup(id: "g1")])
        let log = EventLog()
        let viewModel = SoratomoGroupListViewModel(
            groupService: service,
            currentUid: { "me" },
            leaveService: MockSoratomoLeaveService(),
            leftGroups: makeLeftGroups(),
            logsOpened: false,
            logEvent: { log.events.append($0) }
        )

        await viewModel.load()

        XCTAssertTrue(log.events.isEmpty)
        XCTAssertEqual(service.fetchMyGroupsCalls, ["me"])
    }

    // MARK: - 抜けたグループを隠す（leave-group 8.4・要件 5.3・5.6）

    /// 抜けた記録のあるグループ 1 件を読む一覧の ViewModel を作る（サーバーの答えは `membership`）
    private func makeLeftGroupViewModel(
        membership: SoratomoMembershipCheck,
        service: MockSoratomoGroupService,
        leaveService: MockSoratomoLeaveService,
        log: EventLog
    ) -> SoratomoGroupListViewModel {
        leaveService.membershipResult = membership
        return SoratomoGroupListViewModel(
            groupService: service,
            currentUid: { "me" },
            leaveService: leaveService,
            leftGroups: makeLeftGroups(),
            logEvent: { log.events.append($0) }
        )
    }

    /// 条件が満たされるまで待つ（最大およそ 2 秒・`SoratomoGroupFormViewModelTests` と同じ形）
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 一覧に出ているグループの ID（読み込みが終わっていなければ失敗にする）
    private func loadedIds(_ viewModel: SoratomoGroupListViewModel, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard case let .loaded(groups) = viewModel.state else {
            XCTFail("読み込みが完了していない", file: file, line: line)
            return []
        }
        return groups.map(\.id)
    }

    func testLeftGroupIsShownOnlyWhenServerSaysMemberAndRemovedFromRecord() async {
        // 別の端末で入り直した: キャッシュに残った抜けたグループが、サーバーでは「メンバー」→ 出して記録から外す
        let service = MockSoratomoGroupService()
        service.fetchMyGroupsResult = .success([makeGroup(id: "g1")])
        let leaveService = MockSoratomoLeaveService()
        makeLeftGroups().insert("g1", uid: "me")
        let viewModel = makeLeftGroupViewModel(membership: .member, service: service, leaveService: leaveService, log: EventLog())

        await viewModel.load()

        XCTAssertEqual(loadedIds(viewModel), ["g1"])
        XCTAssertFalse(makeLeftGroups().contains("g1", uid: "me"), "メンバーと確かめたのに、記録に残っている")
        XCTAssertEqual(leaveService.membershipCalls.map(\.groupId), ["g1"])
        XCTAssertEqual(leaveService.membershipCalls.map(\.uid), ["me"])
    }

    func testLeftGroupIsHiddenWhenServerSaysNotMember() async {
        let service = MockSoratomoGroupService()
        service.fetchMyGroupsResult = .success([makeGroup(id: "g1")])
        makeLeftGroups().insert("g1", uid: "me")
        let viewModel = makeLeftGroupViewModel(
            membership: .notMember, service: service, leaveService: MockSoratomoLeaveService(), log: EventLog()
        )

        await viewModel.load()

        XCTAssertEqual(loadedIds(viewModel), [], "抜けたグループが出ている")
        XCTAssertTrue(makeLeftGroups().contains("g1", uid: "me"), "出さないときは記録を残す")
    }

    func testLeftGroupIsHiddenWhenMembershipUnknown() async {
        // 圏外などで確かめられないときは出さない（キャッシュに残った抜けたグループを出さない・P7）
        let service = MockSoratomoGroupService()
        service.fetchMyGroupsResult = .success([makeGroup(id: "g1")])
        makeLeftGroups().insert("g1", uid: "me")
        let viewModel = makeLeftGroupViewModel(
            membership: .unknown, service: service, leaveService: MockSoratomoLeaveService(), log: EventLog()
        )

        await viewModel.load()

        XCTAssertEqual(loadedIds(viewModel), [], "確かめられないのに出している")
        XCTAssertTrue(makeLeftGroups().contains("g1", uid: "me"), "出さないときは記録を残す")
    }

    func testGroupNotInRecordIsShownWithoutMembershipCheck() async {
        // 記録に無いグループは今のまま出す。サーバーへの再確認も呼ばない
        let service = MockSoratomoGroupService()
        service.fetchMyGroupsResult = .success([makeGroup(id: "g1"), makeGroup(id: "g2")])
        let leaveService = MockSoratomoLeaveService()
        // 別の利用者の記録・別のグループの記録は、この利用者の g1・g2 に効かない
        makeLeftGroups().insert("g1", uid: "other")
        makeLeftGroups().insert("g9", uid: "me")
        let viewModel = makeLeftGroupViewModel(membership: .notMember, service: service, leaveService: leaveService, log: EventLog())

        await viewModel.load()

        XCTAssertEqual(loadedIds(viewModel), ["g1", "g2"])
        XCTAssertTrue(leaveService.membershipCalls.isEmpty, "記録に無いのに再確認を呼んでいる")
    }

    func testOnlyMemberGroupAppearsWhenTwoAreRecorded() async {
        // 記録にあるグループが 2 つで、片方だけ .member: .member の方だけ出て記録から外れ、もう片方は記録に残る
        let service = MockSoratomoGroupService()
        service.fetchMyGroupsResult = .success([makeGroup(id: "g1"), makeGroup(id: "g2")])
        let leaveService = MockSoratomoLeaveService()
        leaveService.membershipResultsByGroup = ["g1": .notMember, "g2": .member]
        let left = makeLeftGroups()
        left.insert("g1", uid: "me")
        left.insert("g2", uid: "me")
        let viewModel = SoratomoGroupListViewModel(
            groupService: service,
            currentUid: { "me" },
            leaveService: leaveService,
            leftGroups: makeLeftGroups(),
            logEvent: { _ in }
        )

        await viewModel.load()

        XCTAssertEqual(loadedIds(viewModel), ["g2"])
        XCTAssertTrue(makeLeftGroups().contains("g1", uid: "me"), ".notMember の方の記録が消えている")
        XCTAssertFalse(makeLeftGroups().contains("g2", uid: "me"), ".member の方の記録が残っている")
        XCTAssertEqual(leaveService.membershipCalls.map(\.groupId), ["g1", "g2"])
    }

    func testOpenedGroupCountIsCountAfterHiding() async {
        // soratomo_opened の group_count は、隠した後（出す）件数
        let service = MockSoratomoGroupService()
        service.fetchMyGroupsResult = .success([makeGroup(id: "g1"), makeGroup(id: "g2"), makeGroup(id: "g3")])
        makeLeftGroups().insert("g2", uid: "me")
        let log = EventLog()
        let viewModel = makeLeftGroupViewModel(
            membership: .notMember, service: service, leaveService: MockSoratomoLeaveService(), log: log
        )

        await viewModel.load()

        XCTAssertEqual(loadedIds(viewModel), ["g1", "g3"])
        XCTAssertEqual(log.events, [.opened(groupCount: 2)])
    }

    func testLeftGroupDisappearsFromPreviousListBeforeReloadFinishes() async {
        // 抜けた直後に一覧へ戻った: 読み直しが終わるのを待たずに、前の一覧から抜けたグループを外す（要件 5.2・5.3）
        // （読み直しの間に前の一覧のカードを押すと、抜けたグループのタイムラインが開いて
        //   「グループを開けませんでした」が出てしまうため）
        let service = SoratomoGroupListGatedGroupService(groups: [makeGroup(id: "g1"), makeGroup(id: "g2")])
        let leaveService = MockSoratomoLeaveService()
        leaveService.membershipResult = .notMember
        let log = EventLog()
        let viewModel = SoratomoGroupListViewModel(
            groupService: service,
            currentUid: { "me" },
            leaveService: leaveService,
            leftGroups: makeLeftGroups(),
            logEvent: { log.events.append($0) }
        )
        await viewModel.load()
        XCTAssertEqual(loadedIds(viewModel), ["g1", "g2"])

        // g1 を抜けた（記録は、抜けるの処理が一覧へ戻す前に書く）。一覧へ戻って読み直しを始め、問い合わせの途中で止める
        makeLeftGroups().insert("g1", uid: "me")
        service.gate()
        let reload = Task { await viewModel.load() }
        await waitUntil { service.waitingCount == 1 }

        XCTAssertEqual(service.waitingCount, 1, "読み直しが問い合わせで止まっていない（途中の一覧を見られない）")
        XCTAssertEqual(loadedIds(viewModel), ["g2"], "読み直しの途中で、抜けたグループが前の一覧に出ている")
        XCTAssertTrue(leaveService.membershipCalls.isEmpty, "問い合わせの前に所属を確かめている")

        // 放すと読み直しが終わり、サーバーでも「メンバーでない」ので出ないまま。計測は最初の 1 回だけ（触れない）
        service.releaseAll()
        await reload.value

        XCTAssertEqual(loadedIds(viewModel), ["g2"])
        XCTAssertEqual(leaveService.membershipCalls.map(\.groupId), ["g1"])
        XCTAssertEqual(log.events, [.opened(groupCount: 2)])
    }

    func testScreenNameFollowsLastDestinationInPath() {
        // 画面名は、パスの末尾（いま見えている画面）で決まる。空なら一覧（14.3 の点検で根の画面へ集約）
        XCTAssertEqual(SoratomoRootView.screen(for: []), .groupList)
        XCTAssertEqual(SoratomoRootView.screen(for: [.timeline(groupId: "g")]), .timeline)
        XCTAssertEqual(SoratomoRootView.screen(for: [.timeline(groupId: "g"), .invite(groupId: "g")]), .invite)
        XCTAssertEqual(SoratomoRootView.screen(for: [.timeline(groupId: "g"), .members(groupId: "g")]), .members)
        XCTAssertEqual(SoratomoRootView.screen(for: [.timeline(groupId: "g"), .skyDetail(groupId: "g", skyId: "s")]), .skyDetail)
    }

    func testSignedOutDoesNotLoad() async {
        let service = MockSoratomoGroupService()
        let viewModel = SoratomoGroupListViewModel(
            groupService: service,
            currentUid: { nil },
            leaveService: MockSoratomoLeaveService(),
            leftGroups: makeLeftGroups(),
            logEvent: { _ in }
        )

        await viewModel.load()

        XCTAssertTrue(service.fetchMyGroupsCalls.isEmpty)
        guard case .idle = viewModel.state else {
            return XCTFail("未ログインでは状態を変えない")
        }
    }

    // MARK: - カードの文字（2026-10-05 ガラスのカード G3）

    /// 作成日時と最後の活動の時刻を指定したグループ
    private func makeGroup(createdAt: Date, lastActivityAt: Date) -> SoratomoGroup {
        SoratomoGroup(
            id: "g1",
            name: "空の会",
            ownerId: "owner",
            inviteCode: SoratomoInviteCode.parse(userInput: "ABCD-EFGH")!,
            memberCount: 3,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt
        )
    }

    /// 投稿が一度も無い（作成時の時刻のまま）なら「まだ空なし」、投稿があれば相対の時刻
    func testLastSkyTextSaysNoSkyUntilFirstPost() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ja = Locale(identifier: "ja_JP")
        let created = now.addingTimeInterval(-86400 * 3)

        let noSky = makeGroup(createdAt: created, lastActivityAt: created)
        XCTAssertFalse(SoratomoGroupListView.hasSky(noSky))
        XCTAssertEqual(SoratomoGroupListView.lastSkyText(for: noSky, now: now, locale: ja), "まだ空なし")

        let fiveMinutes = makeGroup(createdAt: created, lastActivityAt: now.addingTimeInterval(-300))
        XCTAssertTrue(SoratomoGroupListView.hasSky(fiveMinutes))
        let text = SoratomoGroupListView.lastSkyText(for: fiveMinutes, now: now, locale: ja)
        XCTAssertTrue(text.contains("5") && text.contains("分前"), "実際: \(text)")

        let yesterday = makeGroup(createdAt: created, lastActivityAt: now.addingTimeInterval(-86400))
        XCTAssertEqual(SoratomoGroupListView.lastSkyText(for: yesterday, now: now, locale: ja), "昨日")
    }

    /// 言語を渡さない（画面と同じ呼び方の）ときも日本語で出る
    ///
    /// 当時アプリは日本語に対応していると申告しておらず（developmentRegion = en・.lproj なし）、
    /// `Locale.current` は端末を日本語にしても英語になっていた（2026-10-06「8 hours ago」の不具合）。
    /// 上のテストは日本語を渡していたのでこれを見逃した。既定値のまま呼んで確かめる
    /// ⚠️ 2026-10-07 に日本語を申告した後は、日本語の端末では既定値が `.current` でもこのテストは通る。
    /// 既定値の ja_JP 固定を守れるのは、英語の端末で走らせたときだけ
    func testLastSkyTextDefaultsToJapanese() {
        let now = Date()
        let created = now.addingTimeInterval(-86400 * 3)

        let yesterday = makeGroup(createdAt: created, lastActivityAt: now.addingTimeInterval(-86400))
        XCTAssertEqual(SoratomoGroupListView.lastSkyText(for: yesterday, now: now), "昨日")

        let fiveMinutes = makeGroup(createdAt: created, lastActivityAt: now.addingTimeInterval(-300))
        let text = SoratomoGroupListView.lastSkyText(for: fiveMinutes, now: now)
        XCTAssertTrue(text.contains("5") && text.contains("分前"), "実際: \(text)")

        XCTAssertEqual(SoratomoGroupListView.cardAccessibilityLabel(for: yesterday, now: now), "空の会、3人、最後の空は昨日")
    }

    /// VoiceOver は「名前、N人、最後の空は…」。投稿が無ければ「名前、N人、まだ空なし」
    func testCardAccessibilityLabel() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ja = Locale(identifier: "ja_JP")
        let created = now.addingTimeInterval(-86400 * 3)

        let noSky = makeGroup(createdAt: created, lastActivityAt: created)
        XCTAssertEqual(SoratomoGroupListView.cardAccessibilityLabel(for: noSky, now: now, locale: ja), "空の会、3人、まだ空なし")

        let yesterday = makeGroup(createdAt: created, lastActivityAt: now.addingTimeInterval(-86400))
        XCTAssertEqual(SoratomoGroupListView.cardAccessibilityLabel(for: yesterday, now: now, locale: ja), "空の会、3人、最後の空は昨日")
    }

    /// 頭文字は 1 文字目（絵文字も 1 文字）。空の名前なら空文字
    func testGroupIconInitial() {
        XCTAssertEqual(SoratomoGroupIcon.initial(of: "空の会"), "空")
        XCTAssertEqual(SoratomoGroupIcon.initial(of: "🌅夕焼け部"), "🌅")
        XCTAssertEqual(SoratomoGroupIcon.initial(of: ""), "")
    }

    /// 「透明度を下げる」が ON なら白のカード。OFF なら iOS 26 以上はガラス
    func testCardStyleFallsBackToOpaqueWhenReduceTransparency() {
        XCTAssertEqual(SoratomoCardStyle.resolve(reduceTransparency: true), .opaque)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(SoratomoCardStyle.resolve(reduceTransparency: false), .glass)
        } else {
            XCTAssertEqual(SoratomoCardStyle.resolve(reduceTransparency: false), .opaque)
        }
    }
}
