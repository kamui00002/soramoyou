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
        let recorder: Recorder
    }

    private let groupId = "g1"

    /// ViewModel をモックとクロージャだけで作る
    private func makeFixture() -> Fixture {
        let groupService = MockSoratomoGroupService()
        let skyService = MockSoratomoSkyService()
        let imageStore = MockSoratomoImageStore()
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
            removeCachedImages: { recorder.removedCaches.append($0) },
            logEvent: { recorder.events.append($0) }
        )
        return Fixture(
            viewModel: viewModel,
            groupService: groupService,
            skyService: skyService,
            imageStore: imageStore,
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
    private func showing(_ sky: SoratomoSky, in fixture: Fixture) {
        fixture.viewModel.start()
        fixture.skyService.emitTimeline(.success(
            SoratomoTimelineSnapshot(skies: [sky], isFromCache: false, mayHaveMore: false)
        ))
    }

    // MARK: - ルーターへの知らせ（12.1）

    func testFirstGroupReadReportsAccessibleOnlyOnce() {
        let fixture = makeFixture()
        fixture.viewModel.start()

        fixture.groupService.emitGroup(groupId: groupId, .success(makeGroup(memberCount: 3)))
        fixture.groupService.emitGroup(groupId: groupId, .success(makeGroup(memberCount: 4)))

        XCTAssertEqual(fixture.recorder.accessible, [groupId])
        XCTAssertTrue(fixture.recorder.notAccessible.isEmpty)
        // 2 回目の通知の内容（人数）は反映する
        XCTAssertEqual(fixture.viewModel.group?.memberCount, 4)
    }

    func testNotMemberReportsNotAccessible() {
        let fixture = makeFixture()
        fixture.viewModel.start()

        fixture.groupService.emitGroup(groupId: groupId, .failure(.notMember))

        XCTAssertEqual(fixture.recorder.notAccessible, [groupId])
        XCTAssertTrue(fixture.recorder.accessible.isEmpty)
    }

    func testPermissionDeniedOnGroupReportsNotAccessible() {
        let fixture = makeFixture()
        fixture.viewModel.start()

        fixture.groupService.emitGroup(groupId: groupId, .failure(.permissionDenied))

        XCTAssertEqual(fixture.recorder.notAccessible, [groupId])
        XCTAssertTrue(fixture.recorder.accessible.isEmpty)
    }

    func testNetworkFailureOnGroupReportsNeither() {
        let fixture = makeFixture()
        fixture.viewModel.start()

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

    func testStartTwiceDoesNotObserveTwice() {
        let fixture = makeFixture()

        fixture.viewModel.start()
        fixture.viewModel.start()

        XCTAssertEqual(fixture.groupService.observeGroupCalls, [groupId])
        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20])
    }

    // MARK: - 上限の伸ばしと引き下げ（8.2・8.3・8.11）

    func testLoadMoreExtendsLimitBy20AndRefreshResetsTo20() {
        let fixture = makeFixture()
        fixture.viewModel.start()
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

    func testLoadMoreDoesNothingWithoutMore() {
        let fixture = makeFixture()
        fixture.viewModel.start()
        fixture.skyService.emitTimeline(.success(makeSnapshot(count: 5, mayHaveMore: false)))

        fixture.viewModel.loadMoreIfNeeded()

        XCTAssertEqual(fixture.skyService.observeTimelineCalls.map(\.limit), [20])
    }

    // MARK: - 同じ内容のスナップショット

    func testSameSnapshotIsIgnored() {
        let fixture = makeFixture()
        fixture.viewModel.start()
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
        showing(othersSky, in: fixture)

        XCTAssertFalse(fixture.viewModel.canDelete(othersSky))
        XCTAssertTrue(fixture.viewModel.canDelete(makeSky(id: "mine", authorId: "me")))

        await fixture.viewModel.delete(othersSky)
        XCTAssertTrue(fixture.skyService.deleteSkyCalls.isEmpty)
        XCTAssertTrue(fixture.recorder.events.isEmpty)
    }

    func testDeleteSuccessRemovesSkyAndCleansUpImages() async {
        let fixture = makeFixture()
        let sky = makeSky(id: "s1")
        showing(sky, in: fixture)
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
        showing(sky, in: fixture)
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
        showing(sky, in: fixture)
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
        showing(sky, in: fixture)
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
        showing(sky, in: fixture)
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
        showing(sky, in: fixture)
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
        showing(sky, in: fixture)
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
        showing(sky, in: fixture)
        fixture.skyService.deleteSkyResult = .failure(.permissionDenied)
        fixture.skyService.skyExistsOnServerResult = .success(true)

        await fixture.viewModel.delete(sky)

        XCTAssertEqual(fixture.viewModel.skies.map(\.id), ["s1"])
        XCTAssertEqual(fixture.recorder.events, [.postDeleteFailed(.unknown)])
    }

    func testUncertainFailureThatCannotBeCheckedKeepsSky() async {
        let fixture = makeFixture()
        let sky = makeSky(id: "s1")
        showing(sky, in: fixture)
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

    func testDaysGroupSkiesByLocalDay() {
        let fixture = makeFixture()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!
        let todayLate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let todayEarly = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 1))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 23))!
        fixture.viewModel.start()
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
}
