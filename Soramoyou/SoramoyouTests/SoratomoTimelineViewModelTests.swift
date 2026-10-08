//
//  SoratomoTimelineViewModelTests.swift
//  SoramoyouTests
//
//  そらとものタイムラインの ViewModel のテスト ⭐️（tasks 13.5・13.6）
//
//  - グループを最初に読めたら reportAccessible を 1 回、読めなかったら reportNotAccessible を呼ぶこと
//  - 上限を 20 → 40 → 60 と伸ばし、引き下げの更新で 20 に戻すこと
//  - 同じ内容のスナップショットは何もしないこと
//  - 自分の投稿の削除の、成功と各失敗の分岐（通信の確認・結果が確定しない失敗の確かめ・画像の後始末）
//

@testable import Soramoyou
import XCTest

@MainActor
final class SoratomoTimelineViewModelTests: XCTestCase {
    // MARK: - 代役

    /// ViewModel から呼ばれたクロージャの記録
    private final class Recorder {
        var events: [SoratomoEvent] = []
        var accessible: [String] = []
        var notAccessible: [String] = []
        var remembered: [[SoratomoSky]] = []
        var forgotten: [(groupId: String, skyId: String)] = []
        var removedCaches: [SoratomoImagePaths] = []
        var isOnline = true
        var uid: String? = "me"
    }

    /// テスト用の部品
    private struct Fixture {
        let viewModel: SoratomoTimelineViewModel
        let groupService: MockSoratomoGroupService
        let skyService: MockSoratomoSkyService
        let imageStore: MockSoratomoImageStore
        let moderationService: MockSoratomoModerationService
        let blockedAuthors: SoratomoBlockedAuthors
        let reportedSkies: SoratomoReportedSkies
        let defaults: UserDefaults
        let recorder: Recorder
    }

    private let groupId = "g1"

    /// ViewModel をモックとクロージャだけで作る
    private func makeFixture() -> Fixture {
        let groupService = MockSoratomoGroupService()
        let skyService = MockSoratomoSkyService()
        let imageStore = MockSoratomoImageStore()
        let moderationService = MockSoratomoModerationService()
        // 隠す集合の部品は本物を、テスト専用の通知センターと UserDefaults で作る（ほかのテストと混ざらないため）
        let blockedAuthors = SoratomoBlockedAuthors(notificationCenter: NotificationCenter())
        let suiteName = "SoratomoTimelineViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let reportedSkies = SoratomoReportedSkies(defaults: defaults)
        let recorder = Recorder()
        let viewModel = SoratomoTimelineViewModel(
            groupId: groupId,
            groupService: groupService,
            skyService: skyService,
            imageStore: imageStore,
            currentUid: { recorder.uid },
            isOnline: { recorder.isOnline },
            reportAccessible: { recorder.accessible.append($0) },
            reportNotAccessible: { recorder.notAccessible.append($0) },
            rememberSkies: { recorder.remembered.append($0) },
            forgetSky: { recorder.forgotten.append(($0, $1)) },
            moderationService: moderationService,
            blockedAuthors: blockedAuthors,
            reportedSkies: reportedSkies,
            removeCachedImages: { recorder.removedCaches.append($0) },
            logEvent: { recorder.events.append($0) }
        )
        return Fixture(
            viewModel: viewModel,
            groupService: groupService,
            skyService: skyService,
            imageStore: imageStore,
            moderationService: moderationService,
            blockedAuthors: blockedAuthors,
            reportedSkies: reportedSkies,
            defaults: defaults,
            recorder: recorder
        )
    }

    /// テスト用のグループ
    private func makeGroup(memberCount: Int = 3) -> SoratomoGroup {
        SoratomoGroup(
            id: groupId,
            name: "空の会",
            ownerId: "owner",
            inviteCode: SoratomoInviteCode.parse(userInput: "ABCD-EFGH")!,
            memberCount: memberCount,
            createdAt: Date(timeIntervalSince1970: 0),
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
    }

    /// テスト用の投稿
    private func makeSky(id: String, authorId: String = "me", createdAt: Date = Date(timeIntervalSince1970: 1000)) -> SoratomoSky {
        SoratomoSky(
            id: id,
            groupId: groupId,
            authorId: authorId,
            caption: nil,
            pixelWidth: 100,
            pixelHeight: 100,
            createdAt: createdAt
        )
    }

    /// 投稿 n 件のスナップショット
    private func makeSnapshot(count: Int, mayHaveMore: Bool, isFromCache: Bool = false) -> SoratomoTimelineSnapshot {
        let skies = (0 ..< count).map { index in
            makeSky(id: "s\(index)", createdAt: Date(timeIntervalSince1970: TimeInterval(100_000 - index)))
        }
        return SoratomoTimelineSnapshot(skies: skies, isFromCache: isFromCache, mayHaveMore: mayHaveMore)
    }

    /// 投稿 1 件を出した状態にする
    private func showing(_ sky: SoratomoSky, in fixture: Fixture) async {
        await fixture.viewModel.start()
        fixture.skyService.emitTimeline(.success(
            SoratomoTimelineSnapshot(skies: [sky], isFromCache: false, mayHaveMore: false)
        ))
    }

    // MARK: - ルーターへの知らせ（12.1）

    func testFirstGroupReadReportsAccessibleOnlyOnce() async {
        let fixture = makeFixture()
        await fixture.viewModel.start()

        fixture.groupService.emitGroup(groupId: groupId, .success(makeGroup(memberCount: 3)))
        fixture.groupService.emitGroup(groupId: groupId, .success(makeGroup(memberCount: 4)))

        XCTAssertEqual(fixture.recorder.accessible, [groupId])
        XCTAssertTrue(fixture.recorder.notAccessible.isEmpty)
        // 2 回目の通知の内容（人数）は反映する
        XCTAssertEqual(fixture.viewModel.group?.memberCount, 4)
    }

    func testNotMemberReportsNotAccessible() async {
        let fixture = makeFixture()
        await fixture.viewModel.start()

        fixture.groupService.emitGroup(groupId: groupId, .failure(.notMember))

        XCTAssertEqual(fixture.recorder.notAccessible, [groupId])
        XCTAssertTrue(fixture.recorder.accessible.isEmpty)
    }

    func testPermissionDeniedOnGroupReportsNotAccessible() async {
        let fixture = makeFixture()
        await fixture.viewModel.start()

        fixture.groupService.emitGroup(groupId: groupId, .failure(.permissionDenied))

        XCTAssertEqual(fixture.recorder.notAccessible, [groupId])
        XCTAssertTrue(fixture.recorder.accessible.isEmpty)
    }

    func testNetworkFailureOnGroupReportsNeither() async {
        let fixture = makeFixture()
        await fixture.viewModel.start()

        // 端末のキャッシュに無いだけの「不在」は .network。読めないとは決まっていないので一覧へ戻さない
        fixture.groupService.emitGroup(groupId: groupId, .failure(.network))

        XCTAssertTrue(fixture.recorder.accessible.isEmpty)
        XCTAssertTrue(fixture.recorder.notAccessible.isEmpty)
        // 監視は止めない（サービスの監視は続いていて、つながれば結果が届く。レビューで直した）
        XCTAssertTrue(fixture.groupService.cancelledGroupObservations.isEmpty)

        // つながってグループが届いたら、手動の更新なしで「読めた」を知らせる
        fixture.groupService.emitGroup(groupId: groupId, .success(makeGroup()))
        XCTAssertEqual(fixture.recorder.accessible, [groupId])
        XCTAssertEqual(fixture.groupService.observeGroupCalls, [groupId])
    }

    func testStartTwiceDoesNotObserveTwice() async {
        let fixture = makeFixture()

        await fixture.viewModel.start()
        await fixture.viewModel.start()

        XCTAssertEqual(fixture.groupService.observeGroupCalls, [groupId])
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20])
    }

    // MARK: - 上限の伸ばしと引き下げ（8.2・8.3・8.11）

    func testLoadMoreExtendsLimitBy20AndRefreshResetsTo20() async {
        let fixture = makeFixture()
        await fixture.viewModel.start()
        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 20, mayHaveMore: true)))

        fixture.viewModel.loadMoreIfNeeded()
        // 結果が届く前は、もう一度呼んでも伸ばさない
        fixture.viewModel.loadMoreIfNeeded()
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20, 40])
        XCTAssertTrue(fixture.viewModel.isLoadingMore)

        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 40, mayHaveMore: true)))
        XCTAssertFalse(fixture.viewModel.isLoadingMore)
        XCTAssertEqual(fixture.viewModel.skies.count, 40)

        fixture.viewModel.loadMoreIfNeeded()
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20, 40, 60])

        fixture.viewModel.refresh()
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20, 40, 60, 20])
        XCTAssertEqual(fixture.viewModel.limit, 20)
        // 張り直しは札の上書きだけで、古い監視は止まっている
        XCTAssertEqual(fixture.skyService.cancelledTimelineIndexes, [0, 1, 2])
    }

    func testLoadMoreDoesNothingWithoutMore() async {
        let fixture = makeFixture()
        await fixture.viewModel.start()
        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 5, mayHaveMore: false)))

        fixture.viewModel.loadMoreIfNeeded()

        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20])
    }

    // MARK: - 同じ内容のスナップショット

    func testSameSnapshotIsIgnored() async {
        let fixture = makeFixture()
        await fixture.viewModel.start()
        let snapshot = makeSnapshot(count: 3, mayHaveMore: false, isFromCache: true)

        fixture.skyService.emitTimeline(.success(snapshot))
        fixture.skyService.emitTimeline(.success(snapshot))
        // キャッシュ由来かどうかだけが変わった通知（includeMetadataChanges）も、同じ内容として扱う
        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 3, mayHaveMore: false, isFromCache: false)))

        XCTAssertEqual(fixture.recorder.remembered.count, 1)
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["s0", "s1", "s2"])

        // 中身が変われば反映する（ほかのメンバーの新しい投稿・8.10）
        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 4, mayHaveMore: false)))
        XCTAssertEqual(fixture.recorder.remembered.count, 2)
        XCTAssertEqual(fixture.viewModel.skies.count, 4)
    }

    // MARK: - 削除（13.6）

    func testDeleteIsOfferedOnlyToAuthor() async {
        let fixture = makeFixture()
        let othersSky = makeSky(id: "x", authorId: "someone")
        await showing(othersSky, in: fixture)

        XCTAssertFalse(fixture.viewModel.canDelete(othersSky))
        XCTAssertTrue(fixture.viewModel.canDelete(makeSky(id: "mine", authorId: "me")))

        await fixture.viewModel.delete(othersSky)
        XCTAssertTrue(fixture.skyService.deleteSkyCalls.isEmpty)
        XCTAssertTrue(fixture.recorder.events.isEmpty)
    }

    func testDeleteSuccessRemovesSkyAndCleansUpImages() async {
        let fixture = makeFixture()
        let sky = makeSky(id: "s1")
        await showing(sky, in: fixture)
        fixture.skyService.deleteSkyResult = .success(())
        fixture.imageStore.deleteOutcome = .deleted

        await fixture.viewModel.delete(sky)

        XCTAssertTrue(fixture.viewModel.skies.isEmpty)
        XCTAssertEqual(fixture.recorder.forgotten.map(\.skyId), ["s1"])
        XCTAssertEqual(fixture.recorder.removedCaches, [sky.imagePaths])
        XCTAssertNil(fixture.viewModel.deleteErrorMessage)
        XCTAssertTrue(fixture.skyService.skyExistsOnServerCalls.isEmpty)

        await fixture.viewModel.imageCleanupTask?.value
        XCTAssertEqual(fixture.imageStore.deleteCalls, [sky.imagePaths])
        XCTAssertEqual(fixture.recorder.events, [.postDeleted(imageCleanup: .deleted)])
    }

    func testImageCleanupFailureKeepsSkyRemovedAndLogsFailed() async {
        let fixture = makeFixture()
        let sky = makeSky(id: "s1")
        await showing(sky, in: fixture)
        fixture.skyService.deleteSkyResult = .success(())
        fixture.imageStore.deleteOutcome = .partiallyFailed

        await fixture.viewModel.delete(sky)
        await fixture.viewModel.imageCleanupTask?.value

        // 画像の削除だけが失敗しても、投稿は戻さない（8.20）
        XCTAssertTrue(fixture.viewModel.skies.isEmpty)
        XCTAssertNil(fixture.viewModel.deleteErrorMessage)
        XCTAssertEqual(fixture.recorder.events, [.postDeleted(imageCleanup: .failed)])

        // 遅れて届いた古い結果に、消した投稿が混ざっていても出さない
        fixture.skyService.emitTimeline(.success(
            SoratomoTimelineSnapshot(skies: [sky, makeSky(id: "s2")], isFromCache: true, mayHaveMore: false)
        ))
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["s2"])
        // 投稿詳細の覚えにも、消した投稿を戻さない
        XCTAssertEqual(fixture.recorder.remembered.last?.map(\.id), ["s2"])
    }

    func testDeleteWhileOfflineDoesNotStart() async {
        let fixture = makeFixture()
        let sky = makeSky(id: "s1")
        await showing(sky, in: fixture)
        fixture.recorder.isOnline = false

        await fixture.viewModel.delete(sky)

        XCTAssertTrue(fixture.skyService.deleteSkyCalls.isEmpty)
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["s1"])
        XCTAssertEqual(fixture.viewModel.deleteErrorMessage, SoratomoFailedAction.deleteSky.userMessage)
        XCTAssertEqual(fixture.recorder.events, [.postDeleteFailed(.network)])
    }

    func testDefiniteFailureDoesNotCheckServerAndKeepsSky() async {
        let fixture = makeFixture()
        let sky = makeSky(id: "s1")
        await showing(sky, in: fixture)
        fixture.skyService.deleteSkyResult = .failure(.unknown)

        await fixture.viewModel.delete(sky)

        XCTAssertTrue(fixture.skyService.skyExistsOnServerCalls.isEmpty)
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["s1"])
        XCTAssertEqual(fixture.viewModel.deleteErrorMessage, SoratomoFailedAction.deleteSky.userMessage)
        XCTAssertEqual(fixture.recorder.events, [.postDeleteFailed(.unknown)])
        XCTAssertTrue(fixture.imageStore.deleteCalls.isEmpty)
        XCTAssertTrue(fixture.recorder.forgotten.isEmpty)
    }

    func testUncertainNetworkFailureWithSkyStillOnServerKeepsSky() async {
        let fixture = makeFixture()
        let sky = makeSky(id: "s1")
        await showing(sky, in: fixture)
        fixture.skyService.deleteSkyResult = .failure(.network)
        fixture.skyService.skyExistsOnServerResult = .success(true)

        await fixture.viewModel.delete(sky)

        XCTAssertEqual(fixture.skyService.skyExistsOnServerCalls.map(\.skyId), ["s1"])
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["s1"])
        XCTAssertEqual(fixture.viewModel.deleteErrorMessage, SoratomoFailedAction.deleteSky.userMessage)
        XCTAssertEqual(fixture.recorder.events, [.postDeleteFailed(.network)])
        XCTAssertTrue(fixture.imageStore.deleteCalls.isEmpty)
    }

    func testUncertainNetworkFailureWithSkyGoneIsTreatedAsSuccess() async {
        let fixture = makeFixture()
        let sky = makeSky(id: "s1")
        await showing(sky, in: fixture)
        fixture.skyService.deleteSkyResult = .failure(.network)
        fixture.skyService.skyExistsOnServerResult = .success(false)
        fixture.imageStore.deleteOutcome = .deleted

        await fixture.viewModel.delete(sky)
        await fixture.viewModel.imageCleanupTask?.value

        XCTAssertTrue(fixture.viewModel.skies.isEmpty)
        XCTAssertNil(fixture.viewModel.deleteErrorMessage)
        XCTAssertEqual(fixture.imageStore.deleteCalls, [sky.imagePaths])
        XCTAssertEqual(fixture.recorder.events, [.postDeleted(imageCleanup: .deleted)])
    }

    func testPermissionDeniedWithSkyGoneIsTreatedAsSuccess() async {
        let fixture = makeFixture()
        let sky = makeSky(id: "s1")
        await showing(sky, in: fixture)
        // すでに無い投稿の削除は、ルールが評価できずに permissionDenied になる
        fixture.skyService.deleteSkyResult = .failure(.permissionDenied)
        fixture.skyService.skyExistsOnServerResult = .success(false)

        await fixture.viewModel.delete(sky)
        await fixture.viewModel.imageCleanupTask?.value

        XCTAssertEqual(fixture.skyService.skyExistsOnServerCalls.count, 1)
        XCTAssertTrue(fixture.viewModel.skies.isEmpty)
        XCTAssertEqual(fixture.recorder.events, [.postDeleted(imageCleanup: .deleted)])
    }

    func testPermissionDeniedWithSkyStillOnServerLogsUnknown() async {
        let fixture = makeFixture()
        let sky = makeSky(id: "s1")
        await showing(sky, in: fixture)
        fixture.skyService.deleteSkyResult = .failure(.permissionDenied)
        fixture.skyService.skyExistsOnServerResult = .success(true)

        await fixture.viewModel.delete(sky)

        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["s1"])
        XCTAssertEqual(fixture.recorder.events, [.postDeleteFailed(.unknown)])
    }

    func testUncertainFailureThatCannotBeCheckedKeepsSky() async {
        let fixture = makeFixture()
        let sky = makeSky(id: "s1")
        await showing(sky, in: fixture)
        fixture.skyService.deleteSkyResult = .failure(.network)
        fixture.skyService.skyExistsOnServerResult = .failure(.network)

        await fixture.viewModel.delete(sky)

        // 確かめられなければ、投稿を残したまま失敗を出す
        XCTAssertEqual(fixture.skyService.skyExistsOnServerCalls.count, 1)
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["s1"])
        XCTAssertEqual(fixture.viewModel.deleteErrorMessage, SoratomoFailedAction.deleteSky.userMessage)
        XCTAssertEqual(fixture.recorder.events, [.postDeleteFailed(.network)])
        XCTAssertTrue(fixture.imageStore.deleteCalls.isEmpty)
        XCTAssertTrue(fixture.recorder.removedCaches.isEmpty)
    }

    // MARK: - 日付の見出し（8.4）

    func testDaysGroupSkiesByLocalDay() async {
        let fixture = makeFixture()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!
        let todayLate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let todayEarly = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 1))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 23))!
        await fixture.viewModel.start()
        fixture.skyService.emitTimeline(.success(SoratomoTimelineSnapshot(
            skies: [makeSky(id: "a", createdAt: todayLate), makeSky(id: "b", createdAt: todayEarly),
                    makeSky(id: "c", createdAt: yesterday)],
            isFromCache: false,
            mayHaveMore: false
        )))

        let days = fixture.viewModel.days(now: now, calendar: calendar)

        XCTAssertEqual(days.map(\.title), ["今日", "昨日"])
        XCTAssertEqual(days.map { $0.skies.map(\.id) }, [["a", "b"], ["c"]])
    }

    // MARK: - 投稿画像の VoiceOver の説明（14.3 の点検で直した・要件 16.5）

    func testRowImageLabelUsesCaptionOrFallsBackForEmptyOrWhitespace() {
        // キャプションがあればキャプション
        XCTAssertEqual(SoratomoTimelineRow.imageAccessibilityLabel(caption: "夕焼け", authorName: "そら"), "夕焼け")
        // nil・空・空白だけは「{表示名}さんの空」
        XCTAssertEqual(SoratomoTimelineRow.imageAccessibilityLabel(caption: nil, authorName: "そら"), "そらさんの空")
        XCTAssertEqual(SoratomoTimelineRow.imageAccessibilityLabel(caption: "", authorName: "そら"), "そらさんの空")
        XCTAssertEqual(SoratomoTimelineRow.imageAccessibilityLabel(caption: "  ", authorName: "そら"), "そらさんの空")
    }

    // MARK: - 隠す・続き読み（release-gate 10.1）

    /// 通報を処理中で止めておく門（開けるまで待たせる）
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// 指定した投稿者の投稿 n 件のスナップショット（ID は prefix + 番号・新しい順）
    private func makeSnapshot(
        count: Int,
        authorId: String,
        prefix: String,
        mayHaveMore: Bool
    ) -> SoratomoTimelineSnapshot {
        let skies = (0 ..< count).map { index in
            makeSky(
                id: "\(prefix)\(index)",
                authorId: authorId,
                createdAt: Date(timeIntervalSince1970: TimeInterval(100_000 - index))
            )
        }
        return SoratomoTimelineSnapshot(skies: skies, isFromCache: false, mayHaveMore: mayHaveMore)
    }

    /// 他人（a・b）の投稿を出した状態にする
    private func showingOthers(in fixture: Fixture) async -> (a: SoratomoSky, b: SoratomoSky) {
        let a = makeSky(id: "a1", authorId: "alice", createdAt: Date(timeIntervalSince1970: 3000))
        let b = makeSky(id: "b1", authorId: "bob", createdAt: Date(timeIntervalSince1970: 2000))
        await fixture.viewModel.start()
        fixture.skyService.emitTimeline(.success(
            SoratomoTimelineSnapshot(skies: [a, b], isFromCache: false, mayHaveMore: false)
        ))
        return (a, b)
    }

    func testHiddenSetChangeFiltersDeliveredSkiesImmediately() async {
        let fixture = makeFixture()
        let (a, b) = await showingOthers(in: fixture)
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["a1", "b1"])

        // ルートの画面などでブロックした（手動の更新なしで、届いている結果から直ちに絞る・9.4）
        fixture.blockedAuthors.add("bob")
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["a1"])
        XCTAssertTrue(fixture.viewModel.isHidden(b))
        // 投稿詳細の覚えにも、隠した投稿を戻さない
        XCTAssertEqual(fixture.recorder.remembered.last?.map(\.id), ["a1"])

        // この端末で通報した投稿も直ちに隠す
        fixture.reportedSkies.add(SoratomoSkyKey(a), uid: "me")
        XCTAssertTrue(fixture.viewModel.skies.isEmpty)
        XCTAssertTrue(fixture.viewModel.isHidden(a))
    }

    func testBlockedAuthorsAreLoadedBeforeTheFirstDisplay() async {
        let fixture = makeFixture()
        fixture.moderationService.fetchBlockedUserIdsResult = .success(["bob"])

        await fixture.viewModel.start()
        // 読み込みが終わってから監視を始める（最初の表示でブロックした相手を出さない・9.6）
        XCTAssertEqual(fixture.moderationService.fetchBlockedUserIdsCalls, ["me"])
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.count, 1)

        fixture.skyService.emitTimeline(.success(SoratomoTimelineSnapshot(
            skies: [makeSky(id: "a1", authorId: "alice"), makeSky(id: "b1", authorId: "bob")],
            isFromCache: false,
            mayHaveMore: false
        )))
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["a1"])

        // 読めた後は、もう一度 start() が呼ばれても読み直さない
        await fixture.viewModel.start()
        XCTAssertEqual(fixture.moderationService.fetchBlockedUserIdsCalls, ["me"])
    }

    func testFailedBlockedAuthorsLoadStillShowsAndRetriesOnNextStart() async {
        let fixture = makeFixture()
        fixture.moderationService.fetchBlockedUserIdsResult = .failure(.network)

        await fixture.viewModel.start()
        // 読めなくても表示を優先する
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.count, 1)

        fixture.moderationService.fetchBlockedUserIdsResult = .success(["bob"])
        await fixture.viewModel.start()
        XCTAssertEqual(fixture.moderationService.fetchBlockedUserIdsCalls, ["me", "me"])
        XCTAssertEqual(fixture.blockedAuthors.ids, ["bob"])
        // 監視は張り直さない
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.count, 1)
    }

    func testStartLoadsReportedSkiesOfTheCurrentUser() async {
        let fixture = makeFixture()
        // 前のセッションで通報した記録（端末に残っている）
        let writer = SoratomoReportedSkies(defaults: fixture.defaults)
        writer.add(SoratomoSkyKey(groupId: groupId, skyId: "b1"), uid: "me")

        let (_, b) = await showingOthers(in: fixture)

        XCTAssertEqual(fixture.reportedSkies.currentUid, "me")
        XCTAssertTrue(fixture.viewModel.isHidden(b))
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["a1"])
    }

    func testAllHiddenPagesExtendAutomaticallyThreeTimesThenOfferManualLoad() async {
        let fixture = makeFixture()
        fixture.moderationService.fetchBlockedUserIdsResult = .success(["spammer"])
        await fixture.viewModel.start()

        // 最初の 20 件が全部隠れていて、続きがありうる → 自分で伸ばす
        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 20, authorId: "spammer", prefix: "x", mayHaveMore: true)))
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20, 40])
        XCTAssertFalse(fixture.viewModel.showsEmptyGuide)

        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 40, authorId: "spammer", prefix: "x", mayHaveMore: true)))
        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 60, authorId: "spammer", prefix: "x", mayHaveMore: true)))
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20, 40, 60, 80])
        XCTAssertFalse(fixture.viewModel.canLoadMoreManually)

        // 連続 3 回伸ばしても表示が増えない → 自動はここで止め、「さらに読み込む」を出す
        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 80, authorId: "spammer", prefix: "x", mayHaveMore: true)))
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20, 40, 60, 80])
        XCTAssertTrue(fixture.viewModel.canLoadMoreManually)
        XCTAssertTrue(fixture.viewModel.skies.isEmpty)
        // 続きがありうる間は、空の案内を出さない
        XCTAssertFalse(fixture.viewModel.showsEmptyGuide)

        // 「さらに読み込む」の 1 回の操作で、また続く
        fixture.viewModel.loadMoreIfNeeded()
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20, 40, 60, 80, 100])
        XCTAssertFalse(fixture.viewModel.canLoadMoreManually)

        // 隠れていない投稿が出たら、自動の続き読みは止まる
        let mixed = SoratomoTimelineSnapshot(
            skies: makeSnapshot(count: 99, authorId: "spammer", prefix: "x", mayHaveMore: true).skies
                + [makeSky(id: "ok", authorId: "alice", createdAt: Date(timeIntervalSince1970: 1))],
            isFromCache: false,
            mayHaveMore: true
        )
        fixture.skyService.emitTimeline(.success(mixed))
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["ok"])
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.count, 5)
        XCTAssertFalse(fixture.viewModel.canLoadMoreManually)
    }

    func testScrollExtensionThatAddsOnlyHiddenSkiesKeepsReading() async {
        let fixture = makeFixture()
        fixture.moderationService.fetchBlockedUserIdsResult = .success(["spammer"])
        await fixture.viewModel.start()
        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 20, mayHaveMore: true)))

        // 末尾で伸ばした 20 件が全部隠れていた → 表示が増えないので、自分でもう一度伸ばす
        fixture.viewModel.loadMoreIfNeeded()
        let shown = makeSnapshot(count: 20, mayHaveMore: true).skies
        let hiddenTail = makeSnapshot(count: 20, authorId: "spammer", prefix: "x", mayHaveMore: true).skies
        fixture.skyService.emitTimeline(.success(
            SoratomoTimelineSnapshot(skies: shown + hiddenTail, isFromCache: false, mayHaveMore: true)
        ))

        XCTAssertEqual(fixture.viewModel.skies.count, 20)
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20, 40, 60])
    }

    func testBlockingEveryoneShownContinuesReading() async {
        let fixture = makeFixture()
        await fixture.viewModel.start()
        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 20, authorId: "bob", prefix: "b", mayHaveMore: true)))
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20])

        // 表示中の投稿が全部隠れた（末尾の行が無くなり、スクロールでは続きが始まらない）→ 自分で続きを読む
        fixture.blockedAuthors.add("bob")

        XCTAssertTrue(fixture.viewModel.skies.isEmpty)
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20, 40])
        XCTAssertFalse(fixture.viewModel.showsEmptyGuide)
    }

    func testEmptyGuideOnlyWhenLoadedEmptyAndNoMore() async {
        let fixture = makeFixture()
        await fixture.viewModel.start()
        // 読めていなければ出さない
        XCTAssertFalse(fixture.viewModel.showsEmptyGuide)

        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 0, mayHaveMore: false)))
        XCTAssertTrue(fixture.viewModel.showsEmptyGuide)

        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 1, mayHaveMore: false)))
        XCTAssertFalse(fixture.viewModel.showsEmptyGuide)
    }

    // MARK: - 通報とブロック（release-gate 10.1）

    func testModerationIsOfferedOnlyForOthersSkies() async {
        let fixture = makeFixture()
        let mine = makeSky(id: "mine", authorId: "me")
        let others = makeSky(id: "x", authorId: "someone")

        XCTAssertFalse(fixture.viewModel.canModerate(mine))
        XCTAssertTrue(fixture.viewModel.canModerate(others))
        fixture.recorder.uid = nil
        XCTAssertFalse(fixture.viewModel.canModerate(others))
        fixture.recorder.uid = "me"

        // 自分の投稿では、通報もブロックも何もしない（5.2）
        let reported = await fixture.viewModel.report(mine, reason: .spam, source: .timeline)
        let blocked = await fixture.viewModel.block(mine, source: .timeline)
        XCTAssertFalse(reported)
        XCTAssertFalse(blocked)
        XCTAssertTrue(fixture.moderationService.reportCalls.isEmpty)
        XCTAssertTrue(fixture.moderationService.blockCalls.isEmpty)
        XCTAssertTrue(fixture.recorder.events.isEmpty)
    }

    func testReportSuccessHidesAndRemembersOnThisDevice() async {
        let fixture = makeFixture()
        let (a, _) = await showingOthers(in: fixture)
        fixture.moderationService.reportResult = .success(())

        let accepted = await fixture.viewModel.report(a, reason: .harassment, source: .timeline)

        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.moderationService.reportCalls.map(\.skyId), ["a1"])
        XCTAssertEqual(fixture.moderationService.reportCalls.map(\.reason), [.harassment])
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["b1"])
        XCTAssertEqual(fixture.viewModel.moderationNotice, .reportAccepted)
        XCTAssertEqual(fixture.recorder.events, [.reportSubmitted(reason: .harassment, source: .timeline)])
        XCTAssertTrue(fixture.viewModel.reportingSkyIds.isEmpty)
        // 端末の記録にも残る（再起動しても隠したまま・5.5）
        let reloaded = SoratomoReportedSkies(defaults: fixture.defaults)
        reloaded.load(uid: "me")
        XCTAssertEqual(reloaded.keys, [SoratomoSkyKey(a)])
    }

    func testReportFailureDoesNotHideAndLaterSuccessIsShown() async {
        let fixture = makeFixture()
        let (a, _) = await showingOthers(in: fixture)
        fixture.moderationService.reportResult = .failure(.unknown)

        let accepted = await fixture.viewModel.report(a, reason: .spam, source: .detail)

        // 失敗では隠さない（5.6）
        XCTAssertFalse(accepted)
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["a1", "b1"])
        XCTAssertFalse(fixture.viewModel.isHidden(a))
        XCTAssertEqual(fixture.viewModel.moderationNotice, .reportFailed)
        XCTAssertEqual(fixture.recorder.events, [.reportFailed(.unknown)])

        // 前回の知らせは、次の通報の始めに消す（一度失敗すると以後の成功が出ない、を作らない・5.4）
        fixture.moderationService.reportResult = .success(())
        await fixture.viewModel.report(a, reason: .spam, source: .detail)
        XCTAssertEqual(fixture.viewModel.moderationNotice, .reportAccepted)
    }

    func testReportWhileOfflineDoesNotSend() async {
        let fixture = makeFixture()
        let (a, _) = await showingOthers(in: fixture)
        fixture.recorder.isOnline = false

        let accepted = await fixture.viewModel.report(a, reason: .spam, source: .timeline)

        XCTAssertFalse(accepted)
        XCTAssertTrue(fixture.moderationService.reportCalls.isEmpty)
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["a1", "b1"])
        XCTAssertEqual(fixture.viewModel.moderationNotice, .reportFailed)
        XCTAssertEqual(fixture.recorder.events, [.reportFailed(.network)])
    }

    func testReportOfSkyThatIsGoneRemovesItWithoutTouchingImages() async {
        let fixture = makeFixture()
        let (a, _) = await showingOthers(in: fixture)
        fixture.moderationService.reportResult = .failure(.skyGone)

        let accepted = await fixture.viewModel.report(a, reason: .other, source: .timeline)

        // 削除済みと同じく取り除く（5.7）
        XCTAssertFalse(accepted)
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["b1"])
        XCTAssertEqual(fixture.recorder.forgotten.map(\.skyId), ["a1"])
        XCTAssertEqual(fixture.viewModel.moderationNotice, .skyGone)
        XCTAssertEqual(fixture.recorder.events, [.reportFailed(.notFound)])
        // 他人の投稿の画像は消しに行かない
        XCTAssertTrue(fixture.recorder.removedCaches.isEmpty)
        XCTAssertTrue(fixture.imageStore.deleteCalls.isEmpty)
        // 遅れて届いた古い結果に混ざっていても出さない
        fixture.skyService.emitTimeline(.success(
            SoratomoTimelineSnapshot(skies: [a, makeSky(id: "c1", authorId: "carol")], isFromCache: true, mayHaveMore: false)
        ))
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["c1"])
    }

    func testReportWhileReportingIsNotAcceptedTwice() async {
        let fixture = makeFixture()
        let (a, _) = await showingOthers(in: fixture)
        let gate = Gate()
        fixture.moderationService.reportResult = .success(())
        fixture.moderationService.onReport = { await gate.wait() }

        let viewModel = fixture.viewModel
        let first = Task { await viewModel.report(a, reason: .spam, source: .timeline) }
        // 1 回目が送信中になるまで待つ
        for _ in 0 ..< 1000 where !viewModel.reportingSkyIds.contains("a1") {
            await Task.yield()
        }
        XCTAssertTrue(viewModel.reportingSkyIds.contains("a1"))

        // 送信中の 2 回目の確定は受け付けない（5.8）
        let second = await viewModel.report(a, reason: .spam, source: .timeline)
        XCTAssertFalse(second)

        await gate.open()
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        XCTAssertEqual(fixture.moderationService.reportCalls.count, 1)
        XCTAssertEqual(fixture.recorder.events, [.reportSubmitted(reason: .spam, source: .timeline)])
    }

    func testBlockSuccessHidesAuthorsSkiesAndLogs() async {
        let fixture = makeFixture()
        let (_, b) = await showingOthers(in: fixture)
        fixture.moderationService.blockResult = .success(())

        let blocked = await fixture.viewModel.block(b, source: .timeline)

        XCTAssertTrue(blocked)
        XCTAssertEqual(fixture.moderationService.blockCalls.map(\.uid), ["me"])
        XCTAssertEqual(fixture.moderationService.blockCalls.map(\.authorId), ["bob"])
        XCTAssertEqual(fixture.blockedAuthors.ids, ["bob"])
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["a1"])
        XCTAssertNil(fixture.viewModel.moderationNotice)
        XCTAssertEqual(fixture.recorder.events, [.userBlocked(source: .timeline)])
        XCTAssertTrue(fixture.viewModel.blockingAuthorIds.isEmpty)
    }

    func testBlockFailureDoesNotHide() async {
        let fixture = makeFixture()
        let (_, b) = await showingOthers(in: fixture)
        fixture.moderationService.blockResult = .failure(.network)

        let blocked = await fixture.viewModel.block(b, source: .detail)

        // 失敗では隠さない（9.9）
        XCTAssertFalse(blocked)
        XCTAssertTrue(fixture.blockedAuthors.ids.isEmpty)
        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["a1", "b1"])
        XCTAssertEqual(fixture.viewModel.moderationNotice, .blockFailed)
        XCTAssertTrue(fixture.recorder.events.isEmpty)
    }
}
