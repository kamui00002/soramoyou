//
//  SoratomoGroupListViewModelTests.swift
//  SoramoyouTests
//
//  そらとものグループ一覧の ViewModel のテスト ⭐️（tasks 13.1）
//
//  - `soratomo_opened`（group_count）を、最初に読めたときだけ 1 回記録すること
//  - 読めなかったときは記録せず、固定の文言を出すこと
//  - 未ログインなら読まないこと
//

@testable import Soramoyou
import XCTest

@MainActor
final class SoratomoGroupListViewModelTests: XCTestCase {
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
            logsOpened: false,
            logEvent: { log.events.append($0) }
        )

        await viewModel.load()

        XCTAssertTrue(log.events.isEmpty)
        XCTAssertEqual(service.fetchMyGroupsCalls, ["me"])
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
