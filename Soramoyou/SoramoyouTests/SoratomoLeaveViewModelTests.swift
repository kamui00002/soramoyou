//
//  SoratomoLeaveViewModelTests.swift
//  SoramoyouTests
//
//  そらとものグループを抜ける画面の状態（SoratomoLeaveViewModel）のテスト ⭐️
//  （leave-group 8.1・design.md の SoratomoLeaveViewModel・D1〜D4・要件 1.2〜1.9・4.3〜4.5・5.1・5.4・11.1・12.1）
//
//  - 予測（オーナーで残りあり・参加日時が同じときの uid の順・最後の 1 人・ただのメンバー）
//  - メニュー: オフラインでは何も呼ばない・材料を読めなければ確認を出さない・表示名の代替
//  - キャンセルで何も呼ばない
//  - 確定: 成功の順（記録 → キャッシュ → 計測 → ルーター）・計測の値・失敗の後の分け方（メンバーのまま／メンバーでない／確かめられない）
//  - D1: 確かめられなかった後に、監視かメニューで「メンバーでない」と分かったら抜けた扱い
//  - D4: 確定の時に通信が無ければ `leave_failed`（network）
//  - 処理中の二重の確定を受け付けない
//  - 確認の文言・題・抜けた後の一時表示の文言
//
//  順は、4 つのクロージャ（監視の停止と再開・記録・キャッシュ・ルーター）と計測が、同じ配列に名前を積む記録係で見る。
//

@testable import Soramoyou
import XCTest

// MARK: - テスト用の代役

/// 抜けるの呼び出しを、テストが放すまで止めておく門（`MockSoratomoLeaveService.onLeave` から呼ぶ）
///
/// `onLeave` は `@Sendable () async -> Void` で、モックの中（メインアクターの外のこともある）から呼ばれる。
/// 待っている呼び出しと「放した」印はロックで守る。放すのは何度呼んでもよい（2 回目以降は何もしない）。
/// 放した後に来た呼び出しは止めない（放し忘れ・タイムアウトの保険の後に、テストが永久に止まらないように）。
private final class SoratomoLeaveViewModelTestLatch: @unchecked Sendable {
    /// 待っている呼び出しと印を、複数のスレッドから同時に触らないためのロック
    private let lock = NSLock()
    /// 放すのを待っている呼び出し
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// 放したか（放した後に来た呼び出しは止めない）
    private var isReleased = false
    /// 門に着いた呼び出しの数
    private var arrivalCount = 0

    /// 呼び出しが門に着いた（`fulfillment(of:timeout:)` で待つ）
    let arrived: XCTestExpectation

    /// - Parameter arrived: 呼び出しが門に着いたときに満たす期待
    init(arrived: XCTestExpectation) {
        self.arrived = arrived
        // 誤って 2 回呼ばれても XCTest の API 違反で止めない（回数は `arrivals` で見る）
        arrived.assertForOverFulfill = false
    }

    /// 門に着いた呼び出しの数
    var arrivals: Int {
        lock.withLock { arrivalCount }
    }

    /// 放されるまで待つ（`onLeave` から呼ぶ）
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let passThrough = lock.withLock { () -> Bool in
                arrivalCount += 1
                if isReleased {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            arrived.fulfill()
            if passThrough {
                continuation.resume()
            }
        }
    }

    /// 待っている呼び出しをすべて放す（何度呼んでもよい）
    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isReleased = true
            let pending = waiters
            waiters = []
            return pending
        }
        pending.forEach { $0.resume() }
    }
}

// MARK: - テスト

@MainActor
final class SoratomoLeaveViewModelTests: XCTestCase {
    // MARK: - 記録係と部品

    /// 呼ばれた順と中身を覚え、テストの途中で通信・uid・グループを切り替える
    private final class Recorder {
        /// 監視の停止と再開・記録・キャッシュ・計測・ルーターが呼ばれた順（名前だけ）
        var calls: [String] = []
        /// 記録した計測
        var events: [SoratomoEvent] = []
        /// 端末の記録に渡された [グループ ID, uid]
        var remembered: [[String]] = []
        /// 画像と投稿の覚えを消したグループ ID
        var purged: [String] = []
        /// ルーターに渡された、抜けた後のもの
        var left: [SoratomoLeftContext] = []
        /// 表示名を読みに行った uid
        var displayNameRequests: [String] = []

        /// 通信できるか（途中で切り替える）
        var online = true
        /// いまの uid（途中で nil にする）
        var uid: String? = "me"
        /// 監視しているグループ（nil = まだ読めていない）
        var group: SoratomoGroup?
        /// 表示名（uid → 名前。無ければ nil を返す）
        var displayNames: [String: String] = [:]
    }

    /// 確認の材料の 3 通り（自分の uid は "me"）
    private enum Scenario: CaseIterable {
        /// 自分がオーナーで、ほかが残る（引き継ぐのは参加のいちばん古い "zen"。uid の順なら "amy" が先）
        case ownerWithOthers
        /// 自分が最後の 1 人（オーナー）
        case lastMember
        /// 自分はただのメンバー（オーナーの "boss" が残る）
        case plainMember
    }

    /// テストに使う部品一式
    private struct Fixture {
        let viewModel: SoratomoLeaveViewModel
        let leaveService: MockSoratomoLeaveService
        let groupService: MockSoratomoGroupService
        let recorder: Recorder
    }

    /// テストのグループ ID
    private let groupId = "group-1"
    /// テストのグループ名
    private let groupName = "空の会"
    /// 確認の共通の本文（要件 1.3。実装の定数は使わず、ここに全文を書く）
    private let commonText =
        "このグループにあなたが投稿した空（写真とキャプション）は、すべて削除され、元に戻せません。招待コードがあればまた参加できますが、削除した投稿は戻りません。"

    /// テスト用のメンバー
    /// - Parameters:
    ///   - id: uid
    ///   - role: オーナーかメンバーか
    ///   - joinedAt: 参加日時（1970 年からの秒）
    private func member(_ id: String, _ role: SoratomoMemberRole = .member, joinedAt: TimeInterval) -> SoratomoMember {
        SoratomoMember(id: id, role: role, joinedAt: Date(timeIntervalSince1970: joinedAt))
    }

    /// 場合ごとのメンバー一覧（順不同で渡す）
    private func members(for scenario: Scenario) -> [SoratomoMember] {
        switch scenario {
        case .ownerWithOthers:
            [member("me", .owner, joinedAt: 0), member("amy", joinedAt: 300), member("zen", joinedAt: 100)]
        case .lastMember:
            [member("me", .owner, joinedAt: 0)]
        case .plainMember:
            [member("me", joinedAt: 100), member("boss", .owner, joinedAt: 0), member("amy", joinedAt: 50)]
        }
    }

    /// 場合ごとのオーナーの uid
    private func ownerId(for scenario: Scenario) -> String {
        scenario == .plainMember ? "boss" : "me"
    }

    /// 場合ごとの、期待する予測
    private func expectedPrediction(for scenario: Scenario) -> SoratomoLeavePrediction {
        switch scenario {
        case .ownerWithOthers:
            SoratomoLeavePrediction(isOwner: true, isLastMember: false, successorUid: "zen")
        case .lastMember:
            SoratomoLeavePrediction(isOwner: true, isLastMember: true, successorUid: nil)
        case .plainMember:
            SoratomoLeavePrediction(isOwner: false, isLastMember: false, successorUid: nil)
        }
    }

    /// テスト用のグループ
    private func makeGroup(ownerId: String) -> SoratomoGroup {
        SoratomoGroup(
            id: groupId,
            name: groupName,
            ownerId: ownerId,
            inviteCode: SoratomoInviteCode.parse(userInput: "ABCD-EFGH")!,
            memberCount: 3,
            createdAt: Date(timeIntervalSince1970: 0),
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
    }

    /// テスト用の ViewModel（クロージャはすべて記録係に積む）
    private func makeViewModel(
        leaveService: MockSoratomoLeaveService,
        groupService: MockSoratomoGroupService,
        recorder: Recorder
    ) -> SoratomoLeaveViewModel {
        SoratomoLeaveViewModel(
            groupId: groupId,
            leaveService: leaveService,
            groupService: groupService,
            currentUid: { recorder.uid },
            isOnline: { recorder.online },
            currentGroup: { recorder.group },
            displayName: { uid in
                recorder.displayNameRequests.append(uid)
                return recorder.displayNames[uid]
            },
            suspendTimeline: { recorder.calls.append("suspendTimeline") },
            resumeTimeline: { recorder.calls.append("resumeTimeline") },
            rememberLeft: { groupId, uid in
                recorder.calls.append("rememberLeft")
                recorder.remembered.append([groupId, uid])
            },
            purgeLocalData: { groupId in
                recorder.calls.append("purgeLocalData")
                recorder.purged.append(groupId)
            },
            onLeft: { context in
                recorder.calls.append("onLeft")
                recorder.left.append(context)
            },
            logEvent: { event in
                recorder.calls.append("logEvent")
                recorder.events.append(event)
            }
        )
    }

    /// 部品一式を作る（メンバー一覧は読める・グループは読めている・"zen" の表示名は「ぜん」）
    private func makeFixture(_ scenario: Scenario = .ownerWithOthers) -> Fixture {
        let leaveService = MockSoratomoLeaveService()
        let groupService = MockSoratomoGroupService()
        groupService.fetchMembersResult = .success(members(for: scenario))
        let recorder = Recorder()
        recorder.group = makeGroup(ownerId: ownerId(for: scenario))
        recorder.displayNames = ["zen": "ぜん"]
        let viewModel = makeViewModel(leaveService: leaveService, groupService: groupService, recorder: recorder)
        return Fixture(viewModel: viewModel, leaveService: leaveService, groupService: groupService, recorder: recorder)
    }

    /// 確認（`.confirming`）まで進めた部品一式を作る
    private func makeConfirmingFixture(_ scenario: Scenario = .ownerWithOthers) async -> Fixture {
        let fixture = makeFixture(scenario)
        await fixture.viewModel.requestLeave()
        XCTAssertNotNil(confirmation(of: fixture.viewModel), "確認まで進んでいない: \(scenario)")
        return fixture
    }

    /// いま出している確認（確認を出していなければ nil）
    private func confirmation(of viewModel: SoratomoLeaveViewModel) -> SoratomoLeaveConfirmation? {
        if case let .confirming(confirmation) = viewModel.phase {
            return confirmation
        }
        return nil
    }

    /// 「抜けた後」の 4 つの呼び出しの順（記録 → キャッシュ → 計測 → ルーター）
    private let finishingCalls = ["rememberLeft", "purgeLocalData", "logEvent", "onLeft"]

    // MARK: - 予測（純関数）

    func testPredictOwnerWithOthersPicksEarliestJoinedAsSuccessor() {
        // uid の順なら "amy" が先だが、参加の古い "zen" を引き継ぐ人にする（サーバーの pickNextOwner と同じ）
        let prediction = SoratomoLeaveViewModel.predict(
            members: members(for: .ownerWithOthers), ownerId: "me", uid: "me"
        )
        XCTAssertEqual(prediction, SoratomoLeavePrediction(isOwner: true, isLastMember: false, successorUid: "zen"))
    }

    func testPredictBreaksJoinedAtTieByUid() {
        // 参加日時が同じ "mika" と "kai" は uid の順で "kai"。uid がいちばん小さい "aki" は参加が新しいので選ばない
        let members = [
            member("me", .owner, joinedAt: 0),
            member("mika", joinedAt: 100),
            member("aki", joinedAt: 500),
            member("kai", joinedAt: 100),
        ]
        let prediction = SoratomoLeaveViewModel.predict(members: members, ownerId: "me", uid: "me")
        XCTAssertEqual(prediction, SoratomoLeavePrediction(isOwner: true, isLastMember: false, successorUid: "kai"))
    }

    func testPredictLastMember() {
        let prediction = SoratomoLeaveViewModel.predict(members: members(for: .lastMember), ownerId: "me", uid: "me")
        XCTAssertEqual(prediction, SoratomoLeavePrediction(isOwner: true, isLastMember: true, successorUid: nil))
    }

    func testPredictPlainMemberHasNoSuccessor() {
        // オーナーが残るので引き継ぎは無い（参加の古い "amy" がいても引き継ぐ人にしない）
        let prediction = SoratomoLeaveViewModel.predict(
            members: members(for: .plainMember), ownerId: "boss", uid: "me"
        )
        XCTAssertEqual(prediction, SoratomoLeavePrediction(isOwner: false, isLastMember: false, successorUid: nil))
    }

    func testPredictReturnsNilWhenSelfIsNotInMembers() {
        let members = [member("boss", .owner, joinedAt: 0), member("amy", joinedAt: 50)]
        XCTAssertNil(SoratomoLeaveViewModel.predict(members: members, ownerId: "boss", uid: "me"))
    }

    // MARK: - メニュー → 確認

    func testRequestLeaveWhileOfflineShowsNetworkMessageAndCallsNothing() async {
        // 通信が無ければ、通信の文言だけ。材料も読まず、計測もしない（要件 1.7）
        let fixture = makeFixture()
        fixture.recorder.online = false

        await fixture.viewModel.requestLeave()

        XCTAssertEqual(fixture.viewModel.alertMessage, SoratomoError.network.userMessage)
        XCTAssertEqual(fixture.viewModel.phase, .idle)
        XCTAssertTrue(fixture.groupService.fetchMembersCalls.isEmpty)
        XCTAssertTrue(fixture.recorder.displayNameRequests.isEmpty)
        XCTAssertTrue(fixture.recorder.calls.isEmpty, "計測もクロージャも呼ばない")
        XCTAssertTrue(fixture.leaveService.leaveCalls.isEmpty)
    }

    func testRequestLeaveShowsPrepareFailureWhenMembersCannotBeRead() async {
        // メンバー一覧を読めなければ、確認を出さずに戻る（要件 1.8）。
        // 「メンバーでない」も、未確定の抜けるを覚えていなければ同じ扱い
        for error in [SoratomoError.network, .unknown, .notMember, .permissionDenied] {
            let fixture = makeFixture()
            fixture.groupService.fetchMembersResult = .failure(error)

            await fixture.viewModel.requestLeave()

            XCTAssertEqual(fixture.viewModel.alertMessage, SoratomoFailedAction.prepareLeave.userMessage, "error=\(error)")
            XCTAssertEqual(fixture.viewModel.phase, .idle, "error=\(error)")
            XCTAssertEqual(fixture.groupService.fetchMembersCalls, [groupId], "error=\(error)")
            XCTAssertTrue(fixture.recorder.calls.isEmpty, "error=\(error)")
            XCTAssertTrue(fixture.leaveService.leaveCalls.isEmpty, "error=\(error)")
        }
    }

    func testRequestLeaveShowsPrepareFailureWithoutUidOrGroup() async {
        // uid が無い・空・グループをまだ読めていない → メンバー一覧も読まずに戻る
        let cases: [(label: String, uid: String?, hasGroup: Bool)] = [
            ("uid なし", nil, true),
            ("uid が空", "", true),
            ("グループ未読込", "me", false),
        ]
        for testCase in cases {
            let fixture = makeFixture()
            fixture.recorder.uid = testCase.uid
            if !testCase.hasGroup {
                fixture.recorder.group = nil
            }

            await fixture.viewModel.requestLeave()

            XCTAssertEqual(fixture.viewModel.alertMessage, SoratomoFailedAction.prepareLeave.userMessage, testCase.label)
            XCTAssertEqual(fixture.viewModel.phase, .idle, testCase.label)
            XCTAssertTrue(fixture.groupService.fetchMembersCalls.isEmpty, testCase.label)
            XCTAssertTrue(fixture.recorder.calls.isEmpty, testCase.label)
        }
    }

    func testRequestLeaveShowsPrepareFailureWhenSelfIsNotInMembers() async {
        let fixture = makeFixture()
        fixture.groupService.fetchMembersResult = .success([member("boss", .owner, joinedAt: 0), member("amy", joinedAt: 50)])

        await fixture.viewModel.requestLeave()

        XCTAssertEqual(fixture.viewModel.alertMessage, SoratomoFailedAction.prepareLeave.userMessage)
        XCTAssertEqual(fixture.viewModel.phase, .idle)
        XCTAssertTrue(fixture.recorder.displayNameRequests.isEmpty)
    }

    func testRequestLeaveBuildsConfirmationForEachScenario() async {
        // 予測と引き継ぐ人の表示名で確認を作る。表示名を読むのは引き継ぐ人がいるときだけ。この時点では何も呼ばない
        for scenario in Scenario.allCases {
            let fixture = makeFixture(scenario)

            await fixture.viewModel.requestLeave()

            let expected = SoratomoLeaveConfirmation(
                groupName: groupName,
                prediction: expectedPrediction(for: scenario),
                successorName: scenario == .ownerWithOthers ? "ぜん" : nil
            )
            XCTAssertEqual(fixture.viewModel.phase, .confirming(expected), "\(scenario)")
            XCTAssertEqual(
                fixture.recorder.displayNameRequests, scenario == .ownerWithOthers ? ["zen"] : [], "\(scenario)"
            )
            XCTAssertEqual(fixture.groupService.fetchMembersCalls, [groupId], "\(scenario)")
            XCTAssertNil(fixture.viewModel.alertMessage, "\(scenario)")
            XCTAssertTrue(fixture.recorder.calls.isEmpty, "確認を出すまでは計測もクロージャも呼ばない: \(scenario)")
            XCTAssertTrue(fixture.leaveService.leaveCalls.isEmpty, "\(scenario)")
        }
    }

    func testSuccessorNameFallsBackWhenDisplayNameUnavailable() async {
        // 表示名が読めない（nil）・空白だけ → メンバー一覧と同じ代替の「ユーザー」で確認を出す（D2）
        for name in [nil, "  \n"] as [String?] {
            let fixture = makeFixture(.ownerWithOthers)
            fixture.recorder.displayNames = name.map { ["zen": $0] } ?? [:]

            await fixture.viewModel.requestLeave()

            let shown = confirmation(of: fixture.viewModel)
            XCTAssertEqual(shown?.successorName, RankingDisplayText.authorName(nil), "name=\(String(describing: name))")
            XCTAssertEqual(
                shown?.message,
                commonText + "\n\n" + "オーナーは" + RankingDisplayText.authorName(nil) + "さんに引き継がれます。",
                "name=\(String(describing: name))"
            )
            XCTAssertEqual(shown?.prediction.successorUid, "zen", "name=\(String(describing: name))")
        }
    }

    func testRequestLeaveIsIgnoredUnlessIdle() async {
        // 確認を出している間に、もう一度メニューを押しても読み直さない
        let fixture = await makeConfirmingFixture()
        let before = fixture.viewModel.phase

        await fixture.viewModel.requestLeave()

        XCTAssertEqual(fixture.groupService.fetchMembersCalls.count, 1)
        XCTAssertEqual(fixture.viewModel.phase, before)
    }

    // MARK: - キャンセル

    func testCancelReturnsToIdleAndCallsNothing() async {
        let fixture = await makeConfirmingFixture()
        fixture.leaveService.leaveResult = .success(SoratomoLeaveResult(groupDeleted: false))

        fixture.viewModel.cancel()

        XCTAssertEqual(fixture.viewModel.phase, .idle)
        XCTAssertNil(fixture.viewModel.alertMessage)
        XCTAssertTrue(fixture.recorder.calls.isEmpty, "キャンセルでは何も呼ばない")
        XCTAssertTrue(fixture.leaveService.leaveCalls.isEmpty)
        XCTAssertTrue(fixture.leaveService.membershipCalls.isEmpty)

        // キャンセルの後の「抜ける」は受け付けない
        await fixture.viewModel.confirm()
        XCTAssertTrue(fixture.leaveService.leaveCalls.isEmpty)
        XCTAssertTrue(fixture.recorder.calls.isEmpty)
    }

    // MARK: - 確定の成功

    func testConfirmSuccessRunsStepsInOrder() async {
        // 監視を止める → 抜ける → 記録 → キャッシュ → 計測 → ルーター。画面はルーターが閉じるので .leaving のまま
        let fixture = await makeConfirmingFixture(.ownerWithOthers)
        fixture.leaveService.leaveResult = .success(SoratomoLeaveResult(groupDeleted: false))

        await fixture.viewModel.confirm()

        XCTAssertEqual(fixture.recorder.calls, ["suspendTimeline"] + finishingCalls)
        XCTAssertEqual(fixture.leaveService.leaveCalls, [groupId])
        XCTAssertEqual(fixture.recorder.remembered, [[groupId, "me"]])
        XCTAssertEqual(fixture.recorder.purged, [groupId])
        XCTAssertEqual(fixture.recorder.events, [.groupLeft(role: .owner, groupDeleted: false, completed: true)])
        XCTAssertEqual(fixture.recorder.left, [SoratomoLeftContext(groupId: groupId, groupName: groupName, completed: true)])
        XCTAssertEqual(fixture.viewModel.phase, .leaving)
        XCTAssertNil(fixture.viewModel.alertMessage)
        XCTAssertTrue(fixture.leaveService.membershipCalls.isEmpty, "成功ならメンバーかどうかを確かめない")
    }

    func testGroupLeftEventMatchesExactlyAndCarriesNoNames() async {
        // 計測は .groupLeft と完全一致（role は予測の isOwner・group_deleted はサーバーの値・completed は真）。
        // グループ名・引き継ぐ人の表示名・uid は、どの値にも入らない（要件 11.1・12.4）
        let cases: [(scenario: Scenario, serverDeleted: Bool, expected: SoratomoEvent)] = [
            (.ownerWithOthers, false, .groupLeft(role: .owner, groupDeleted: false, completed: true)),
            // 予測は「残りあり」でも、サーバーが消えたと言えばサーバーの値（再試行の間にほかの人が抜けた）
            (.ownerWithOthers, true, .groupLeft(role: .owner, groupDeleted: true, completed: true)),
            (.lastMember, true, .groupLeft(role: .owner, groupDeleted: true, completed: true)),
            (.plainMember, false, .groupLeft(role: .member, groupDeleted: false, completed: true)),
        ]
        for testCase in cases {
            let label = "\(testCase.scenario) serverDeleted=\(testCase.serverDeleted)"
            let fixture = await makeConfirmingFixture(testCase.scenario)
            fixture.leaveService.leaveResult = .success(SoratomoLeaveResult(groupDeleted: testCase.serverDeleted))

            await fixture.viewModel.confirm()

            XCTAssertEqual(fixture.recorder.events, [testCase.expected], label)
            for event in fixture.recorder.events {
                XCTAssertEqual(Set(event.parameters.keys), ["role", "group_deleted", "completed"], label)
                for value in event.parameters.values {
                    guard case let .value(text) = value else { continue }
                    // ⚠️ uid の "me" は role の値 "member" に含まれてしまうので見ない（uid は型の上で入らない）
                    for secret in [groupName, "ぜん", "zen", groupId] {
                        XCTAssertFalse(text.contains(secret), "計測に \(secret) が入っている: \(label)")
                    }
                }
            }
        }
    }

    func testConfirmRemembersUidReadAtRequestLeave() async {
        // 確認を出した後に currentUid が nil を返しても（サインアウト直後など）、記録には確認のときの uid を渡す
        let fixture = await makeConfirmingFixture()
        fixture.recorder.uid = nil
        fixture.leaveService.leaveResult = .success(SoratomoLeaveResult(groupDeleted: false))

        await fixture.viewModel.confirm()

        XCTAssertEqual(fixture.recorder.remembered, [[groupId, "me"]])
        XCTAssertEqual(fixture.recorder.left.count, 1)
    }

    func testMembershipCheckUsesUidReadAtRequestLeave() async {
        // 失敗の後にメンバーかどうかを確かめるときも、確認のときの uid を使う
        let fixture = await makeConfirmingFixture()
        fixture.recorder.uid = nil
        fixture.leaveService.leaveResult = .failure(.unknown)
        fixture.leaveService.membershipResult = .member

        await fixture.viewModel.confirm()

        XCTAssertEqual(fixture.leaveService.membershipCalls.map(\.groupId), [groupId])
        XCTAssertEqual(fixture.leaveService.membershipCalls.map(\.uid), ["me"])
    }

    // MARK: - 確定の失敗

    func testFailureWhileStillMemberResumesTimelineAndLogsLeaveFailed() async {
        // メンバーのまま → 失敗の文言・監視の張り直し・leave_failed で .idle（もう一度選べる・要件 4.4・12.1）
        let cases: [(error: SoratomoLeaveError, message: String, reason: SoratomoLeaveFailReason)] = [
            (.network, SoratomoError.network.userMessage, .network),
            (.incomplete, SoratomoFailedAction.leaveGroup.userMessage, .unknown),
            (.unknown, SoratomoFailedAction.leaveGroup.userMessage, .unknown),
        ]
        for testCase in cases {
            let label = "error=\(testCase.error)"
            let fixture = await makeConfirmingFixture()
            fixture.leaveService.leaveResult = .failure(testCase.error)
            fixture.leaveService.membershipResult = .member

            await fixture.viewModel.confirm()

            XCTAssertEqual(fixture.viewModel.alertMessage, testCase.message, label)
            XCTAssertEqual(fixture.recorder.calls, ["suspendTimeline", "resumeTimeline", "logEvent"], label)
            XCTAssertEqual(fixture.recorder.events, [.leaveFailed(testCase.reason)], label)
            XCTAssertEqual(fixture.viewModel.phase, .idle, label)
            XCTAssertTrue(fixture.recorder.remembered.isEmpty, label)
            XCTAssertTrue(fixture.recorder.purged.isEmpty, label)
            XCTAssertTrue(fixture.recorder.left.isEmpty, label)
            XCTAssertEqual(fixture.leaveService.membershipCalls.count, 1, label)
            XCTAssertFalse(fixture.viewModel.absorbLostMembership(groupId: groupId), "メンバーのままなら覚えない: \(label)")
        }
    }

    func testFailureButNotMemberFinishesAsLeftWithoutCompletion() async {
        // 失敗でも、サーバーで「メンバーでない」と分かれば抜けた扱い（4.5）。
        // completed は偽、group_deleted は予測の isLastMember、失敗の文言・張り直し・leave_failed は無い
        let cases: [(scenario: Scenario, expected: SoratomoEvent)] = [
            (.ownerWithOthers, .groupLeft(role: .owner, groupDeleted: false, completed: false)),
            (.lastMember, .groupLeft(role: .owner, groupDeleted: true, completed: false)),
            (.plainMember, .groupLeft(role: .member, groupDeleted: false, completed: false)),
        ]
        for testCase in cases {
            let label = "\(testCase.scenario)"
            let fixture = await makeConfirmingFixture(testCase.scenario)
            fixture.leaveService.leaveResult = .failure(.unknown)
            fixture.leaveService.membershipResult = .notMember

            await fixture.viewModel.confirm()

            XCTAssertEqual(fixture.recorder.calls, ["suspendTimeline"] + finishingCalls, label)
            XCTAssertEqual(fixture.recorder.events, [testCase.expected], label)
            XCTAssertEqual(
                fixture.recorder.left, [SoratomoLeftContext(groupId: groupId, groupName: groupName, completed: false)], label
            )
            XCTAssertEqual(fixture.recorder.remembered, [[groupId, "me"]], label)
            XCTAssertEqual(fixture.viewModel.phase, .leaving, label)
            XCTAssertNil(fixture.viewModel.alertMessage, label)
        }
    }

    // MARK: - D1: 確かめられなかった後

    func testUnknownMembershipThenLostMembershipFinishesAsLeft() async {
        // 確かめられない → まず 4.4 と同じ（文言・張り直し・leave_failed）。
        // 後で監視が「メンバーでない」を届けたら（absorbLostMembership）、抜けた扱い（completed: false）
        let fixture = await makeConfirmingFixture(.lastMember)
        fixture.leaveService.leaveResult = .failure(.network)
        fixture.leaveService.membershipResult = .unknown

        await fixture.viewModel.confirm()

        XCTAssertEqual(fixture.viewModel.alertMessage, SoratomoError.network.userMessage)
        XCTAssertEqual(fixture.recorder.calls, ["suspendTimeline", "resumeTimeline", "logEvent"])
        XCTAssertEqual(fixture.recorder.events, [.leaveFailed(.network)])
        XCTAssertEqual(fixture.viewModel.phase, .idle)

        fixture.viewModel.alertMessage = nil
        XCTAssertTrue(fixture.viewModel.absorbLostMembership(groupId: groupId))

        XCTAssertEqual(fixture.recorder.calls, ["suspendTimeline", "resumeTimeline", "logEvent"] + finishingCalls)
        XCTAssertEqual(
            fixture.recorder.events,
            [.leaveFailed(.network), .groupLeft(role: .owner, groupDeleted: true, completed: false)]
        )
        XCTAssertEqual(fixture.recorder.left, [SoratomoLeftContext(groupId: groupId, groupName: groupName, completed: false)])
        XCTAssertEqual(fixture.recorder.remembered, [[groupId, "me"]])
        XCTAssertEqual(fixture.viewModel.phase, .leaving)
        XCTAssertNil(fixture.viewModel.alertMessage)

        // 覚えは消えたので、2 回目は何もしない
        XCTAssertFalse(fixture.viewModel.absorbLostMembership(groupId: groupId))
        XCTAssertEqual(fixture.recorder.left.count, 1)
    }

    func testAbsorbIgnoresOtherGroup() async {
        let fixture = await makeConfirmingFixture()
        fixture.leaveService.leaveResult = .failure(.network)
        fixture.leaveService.membershipResult = .unknown
        await fixture.viewModel.confirm()
        let callsAfterFailure = fixture.recorder.calls

        XCTAssertFalse(fixture.viewModel.absorbLostMembership(groupId: "group-2"))
        XCTAssertEqual(fixture.recorder.calls, callsAfterFailure, "別のグループでは何も呼ばない")
        XCTAssertEqual(fixture.viewModel.phase, .idle)

        // 自分のグループなら、覚えたまま進める
        XCTAssertTrue(fixture.viewModel.absorbLostMembership(groupId: groupId))
    }

    func testUnknownMembershipThenMenuWithNotMemberFinishesAsLeft() async {
        // 確かめられない → もう一度メニューを押すと、メンバー一覧が「メンバーでない」で読めない → 抜けた扱い（D1）
        let fixture = await makeConfirmingFixture(.ownerWithOthers)
        fixture.leaveService.leaveResult = .failure(.network)
        fixture.leaveService.membershipResult = .unknown
        await fixture.viewModel.confirm()
        XCTAssertEqual(fixture.viewModel.phase, .idle)

        // 利用者がアラートを閉じてから、もう一度メニューを押す
        fixture.viewModel.alertMessage = nil
        fixture.recorder.calls = []
        fixture.recorder.events = []
        fixture.groupService.fetchMembersResult = .failure(.notMember)

        await fixture.viewModel.requestLeave()

        XCTAssertEqual(fixture.recorder.calls, finishingCalls)
        XCTAssertEqual(fixture.recorder.events, [.groupLeft(role: .owner, groupDeleted: false, completed: false)])
        XCTAssertEqual(fixture.recorder.left, [SoratomoLeftContext(groupId: groupId, groupName: groupName, completed: false)])
        XCTAssertEqual(fixture.recorder.remembered, [[groupId, "me"]])
        XCTAssertEqual(fixture.viewModel.phase, .leaving)
        XCTAssertNil(fixture.viewModel.alertMessage, "「グループの情報を読み込めませんでした」を出さない")
        XCTAssertEqual(fixture.leaveService.leaveCalls.count, 1, "もう一度は抜けるを呼ばない")
    }

    func testAbsorbWithoutUnresolvedLeaveReturnsFalseAndCallsNothing() async {
        // 覚えが無ければ false で何もしない（画面はルーターへ「読めなかった」を知らせる）
        let idle = makeFixture()
        XCTAssertFalse(idle.viewModel.absorbLostMembership(groupId: groupId))
        XCTAssertTrue(idle.recorder.calls.isEmpty)
        XCTAssertEqual(idle.viewModel.phase, .idle)

        let confirming = await makeConfirmingFixture()
        XCTAssertFalse(confirming.viewModel.absorbLostMembership(groupId: groupId))
        XCTAssertTrue(confirming.recorder.calls.isEmpty)
        XCTAssertNotNil(confirmation(of: confirming.viewModel), "確認はそのまま")
    }

    func testMemberAfterUnknownClearsUnresolvedLeave() async {
        // 1 回目: 確かめられない（覚える）→ 2 回目: メンバーのまま（覚えを消す）→ 監視の「メンバーでない」は吸わない
        let fixture = await makeConfirmingFixture()
        fixture.leaveService.leaveResult = .failure(.network)
        fixture.leaveService.membershipResult = .unknown
        await fixture.viewModel.confirm()

        fixture.viewModel.alertMessage = nil
        await fixture.viewModel.requestLeave()
        XCTAssertNotNil(confirmation(of: fixture.viewModel))
        fixture.leaveService.leaveResult = .failure(.unknown)
        fixture.leaveService.membershipResult = .member
        await fixture.viewModel.confirm()

        XCTAssertEqual(fixture.viewModel.phase, .idle)
        XCTAssertFalse(fixture.viewModel.absorbLostMembership(groupId: groupId))
        XCTAssertFalse(fixture.recorder.calls.contains("rememberLeft"))
        XCTAssertTrue(fixture.recorder.left.isEmpty)
        XCTAssertEqual(fixture.recorder.events, [.leaveFailed(.network), .leaveFailed(.unknown)])
    }

    // MARK: - D4: 確定の時の通信なし

    func testConfirmWhileOfflineLogsNetworkFailureAndDoesNotLeave() async {
        // 確認を出した後に通信が切れた → 抜けるを呼ばず、通信の文言と leave_failed（network）で .idle（D4）
        let fixture = await makeConfirmingFixture()
        fixture.leaveService.leaveResult = .success(SoratomoLeaveResult(groupDeleted: false))
        fixture.recorder.online = false

        await fixture.viewModel.confirm()

        XCTAssertEqual(fixture.viewModel.alertMessage, SoratomoError.network.userMessage)
        XCTAssertEqual(fixture.recorder.events, [.leaveFailed(.network)])
        XCTAssertEqual(fixture.recorder.calls, ["logEvent"], "監視は止めない")
        XCTAssertEqual(fixture.viewModel.phase, .idle)
        XCTAssertTrue(fixture.leaveService.leaveCalls.isEmpty)
        XCTAssertTrue(fixture.leaveService.membershipCalls.isEmpty)
    }

    // MARK: - 処理中

    func testConfirmIgnoresSecondConfirmWhileLeaving() async {
        // 抜けるの呼び出しを門で止めておき、処理中にもう一度「抜ける」・メニュー・キャンセルを試す
        let fixture = await makeConfirmingFixture()
        let latch = SoratomoLeaveViewModelTestLatch(arrived: expectation(description: "抜けるの呼び出しが門に着いた"))
        // タイムアウトの保険: 何があっても 5 秒で門を開ける（終わりの cancel でもすぐ開く。開けるのは何度でもよい）
        let safety = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            latch.release()
        }
        defer {
            safety.cancel()
            latch.release()
        }
        fixture.leaveService.leaveResult = .success(SoratomoLeaveResult(groupDeleted: false))
        fixture.leaveService.onLeave = { await latch.wait() }

        let first = Task { await fixture.viewModel.confirm() }
        await fulfillment(of: [latch.arrived], timeout: 5)
        XCTAssertEqual(fixture.viewModel.phase, .leaving)

        // 処理中に、もう一度「抜ける」を押す（受け付けない）
        let second = Task { await fixture.viewModel.confirm() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(latch.arrivals, 1)
        XCTAssertEqual(fixture.leaveService.leaveCalls.count, 1)

        // メニューとキャンセルも受け付けない
        await fixture.viewModel.requestLeave()
        fixture.viewModel.cancel()
        XCTAssertEqual(fixture.groupService.fetchMembersCalls.count, 1)
        XCTAssertEqual(fixture.viewModel.phase, .leaving)

        latch.release()
        await first.value
        await second.value

        XCTAssertEqual(fixture.leaveService.leaveCalls.count, 1)
        XCTAssertEqual(fixture.recorder.calls, ["suspendTimeline"] + finishingCalls)
        XCTAssertEqual(fixture.recorder.left.count, 1)
        XCTAssertEqual(fixture.viewModel.phase, .leaving)
    }

    func testAbsorbDuringLeavingReturnsFalse() async {
        // 未確定の覚えがあっても、処理中（.leaving）に監視の「メンバーでない」が届いたら吸わない（処理の結果に任せる）
        let fixture = await makeConfirmingFixture()
        fixture.leaveService.leaveResult = .failure(.network)
        fixture.leaveService.membershipResult = .unknown
        await fixture.viewModel.confirm()
        fixture.viewModel.alertMessage = nil
        await fixture.viewModel.requestLeave()
        XCTAssertNotNil(confirmation(of: fixture.viewModel))

        let latch = SoratomoLeaveViewModelTestLatch(arrived: expectation(description: "抜けるの呼び出しが門に着いた"))
        let safety = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            latch.release()
        }
        defer {
            safety.cancel()
            latch.release()
        }
        fixture.leaveService.leaveResult = .success(SoratomoLeaveResult(groupDeleted: false))
        fixture.leaveService.onLeave = { await latch.wait() }

        let leaving = Task { await fixture.viewModel.confirm() }
        await fulfillment(of: [latch.arrived], timeout: 5)
        XCTAssertEqual(fixture.viewModel.phase, .leaving)

        XCTAssertFalse(fixture.viewModel.absorbLostMembership(groupId: groupId))
        XCTAssertFalse(fixture.recorder.calls.contains("onLeft"), "処理中は抜けた後へ進めない")

        latch.release()
        await leaving.value

        // 処理の成功で 1 回だけ抜けた後へ進む（completed: true）
        XCTAssertEqual(fixture.recorder.left, [SoratomoLeftContext(groupId: groupId, groupName: groupName, completed: true)])
        XCTAssertEqual(fixture.recorder.calls.filter { $0 == "onLeft" }.count, 1)
    }

    // MARK: - 文言

    func testConfirmationTitle() {
        let confirmation = SoratomoLeaveConfirmation(
            groupName: groupName,
            prediction: SoratomoLeavePrediction(isOwner: false, isLastMember: false, successorUid: nil),
            successorName: nil
        )
        XCTAssertEqual(confirmation.title, "空の会を抜けますか？")
    }

    func testConfirmationMessagesMatchFixedTexts() {
        // design.md の「確認の文言」の表の 3 通り（全文の完全一致）
        let owner = SoratomoLeaveConfirmation(
            groupName: groupName,
            prediction: SoratomoLeavePrediction(isOwner: true, isLastMember: false, successorUid: "zen"),
            successorName: "ぜん"
        )
        XCTAssertEqual(
            owner.message,
            "このグループにあなたが投稿した空（写真とキャプション）は、すべて削除され、元に戻せません。招待コードがあればまた参加できますが、削除した投稿は戻りません。"
                + "\n\nオーナーはぜんさんに引き継がれます。"
        )

        let last = SoratomoLeaveConfirmation(
            groupName: groupName,
            prediction: SoratomoLeavePrediction(isOwner: true, isLastMember: true, successorUid: nil),
            successorName: nil
        )
        XCTAssertEqual(
            last.message,
            "このグループにあなたが投稿した空（写真とキャプション）は、すべて削除され、元に戻せません。招待コードがあればまた参加できますが、削除した投稿は戻りません。"
                + "\n\nあなたが最後のメンバーのため、グループと招待コードも削除され、だれも参加できなくなります。"
        )

        let plain = SoratomoLeaveConfirmation(
            groupName: groupName,
            prediction: SoratomoLeavePrediction(isOwner: false, isLastMember: false, successorUid: nil),
            successorName: nil
        )
        XCTAssertEqual(plain.message, commonText)
    }

    func testLeftContextNotice() {
        // 「グループを開けませんでした」とは違う、固定の文（要件 5.1・5.2・4.5）
        let completed = SoratomoLeftContext(groupId: groupId, groupName: groupName, completed: true)
        XCTAssertEqual(completed.notice, "空の会を抜けました")

        let incomplete = SoratomoLeftContext(groupId: groupId, groupName: groupName, completed: false)
        XCTAssertEqual(incomplete.notice, "空の会を抜けました。残りの片づけは自動で終わります")

        XCTAssertNotEqual(completed.notice, SoratomoError.notMember.userMessage)
        XCTAssertNotEqual(incomplete.notice, SoratomoError.notMember.userMessage)
    }
}
