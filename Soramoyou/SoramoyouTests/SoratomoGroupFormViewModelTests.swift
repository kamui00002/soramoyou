//
//  SoratomoGroupFormViewModelTests.swift
//  SoramoyouTests
//
//  そらともの「グループを作る」「招待コードで参加」のシートの ViewModel のテスト ⭐️（tasks 13.2・13.3）
//
//  - 表示名が要るかを確かめられなかったら（どのエラーでも）、先へ進まないこと
//  - 表示名の保存に失敗したら、先へ進まず、入力が残ること
//  - 処理中は二重の確定を受け付けないこと
//  - 作成・参加に失敗したら、固定の文言を出し、入力が残ること
//  - 作成の要求 ID を、名前を変えるまで再利用すること（変えたら新しい ID）
//  - 成功の後の行き先と、事前説明の判定
//

@testable import Soramoyou
import XCTest

// MARK: - テスト用の代役

/// 通知の事前説明の判定の代役（決めておいた判定を返し、呼ばれた回数を数える）
@MainActor
private final class SoratomoGroupFormPrimerStub: SoratomoNotificationPrimerProtocol {
    /// `decide()` が返す判定
    var decision: SoratomoPrimerDecision = .none
    /// `decide()` が呼ばれた回数
    private(set) var decideCalls = 0

    func decide() async -> SoratomoPrimerDecision {
        decideCalls += 1
        return decision
    }

    func handle(choice _: SoratomoPrimerChoice) async -> Bool {
        false
    }

    func markSettingsGuideShown() {}
}

/// 作成と参加の結果を、テストが放すまで返さないグループのサービス
///
/// 共有のモック（`MockSoratomoGroupService`）はすぐに結果を返すので、「処理中」の間に 2 回目の確定を
/// 試すことができない。そこで、作成と参加の呼び出しを止めておき、テストの合図（`releaseAll()`）で返す。
private final class SoratomoGroupFormGatedGroupService: SoratomoGroupServiceProtocol, @unchecked Sendable {
    /// 呼び出し回数と待っている呼び出しを、複数のスレッドから同時に触らないためのロック
    private let lock = NSLock()
    private var createCount = 0
    private var joinCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 作成が返すグループ
    let summary = SoratomoGroupSummary(
        groupId: "g-created",
        name: "空の会",
        inviteCode: SoratomoInviteCode.parse(userInput: "ABCD-EFGH")!,
        memberCount: 1
    )

    /// 作成が呼ばれた回数
    var createCalls: Int {
        lock.withLock { createCount }
    }

    /// 参加が呼ばれた回数
    var joinCalls: Int {
        lock.withLock { joinCount }
    }

    /// 返すのを待っている呼び出しの数
    var waitingCount: Int {
        lock.withLock { waiters.count }
    }

    /// 待っている呼び出しを、すべて返す
    func releaseAll() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let pending = waiters
            waiters = []
            return pending
        }
        pending.forEach { $0.resume() }
    }

    func createGroup(name _: String, requestId _: UUID) async throws(SoratomoError) -> SoratomoGroupSummary {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock {
                createCount += 1
                waiters.append(continuation)
            }
        }
        return summary
    }

    func joinGroup(code _: SoratomoInviteCode) async throws(SoratomoError) -> SoratomoJoinResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock {
                joinCount += 1
                waiters.append(continuation)
            }
        }
        return SoratomoJoinResult(groupId: "g-joined", alreadyMember: false)
    }

    func regenerateInviteCode(groupId _: String) async throws(SoratomoError) -> SoratomoInviteCode {
        throw .unknown
    }

    func fetchMyGroups(uid _: String) async throws(SoratomoError) -> [SoratomoGroup] {
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
final class SoratomoGroupFormViewModelTests: XCTestCase {
    /// 記録した計測と、成功の後に渡された行き先を覚える
    private final class Recorder {
        var events: [SoratomoEvent] = []
        var completed: [[SoratomoDestination]] = []
        /// ガイドラインで「同意しない」を選んで閉じた回数
        var declined = 0
    }

    /// テスト用の ViewModel を作る
    /// - Parameters:
    ///   - mode: 作成か参加か
    ///   - groupService: グループのサービス（既定は共有のモック）
    ///   - profileService: 表示名のサービス
    ///   - guideline: ガイドラインの同意のサービス（既定は現行の版に同意済み・既存のテストを変えないため）
    ///   - primer: 事前説明の判定
    ///   - online: 通信できる状態か
    ///   - recorder: 計測と行き先の記録先
    private func makeViewModel(
        mode: SoratomoGroupFormMode,
        groupService: any SoratomoGroupServiceProtocol,
        profileService: MockSoratomoProfileService,
        guideline: MockSoratomoGuidelineService? = nil,
        // 既定の引数はメインアクターの外で評価されるので、@MainActor の代役は本体の中で作る
        primer: SoratomoGroupFormPrimerStub? = nil,
        online: Bool = true,
        recorder: Recorder
    ) -> SoratomoGroupFormViewModel {
        SoratomoGroupFormViewModel(
            mode: mode,
            groupService: groupService,
            profileService: profileService,
            guidelineService: guideline ?? agreedGuideline(),
            primer: primer ?? SoratomoGroupFormPrimerStub(),
            isOnline: { online },
            currentUid: { "me" },
            logEvent: { recorder.events.append($0) },
            onCompleted: { recorder.completed.append($0) },
            onDeclined: { recorder.declined += 1 }
        )
    }

    /// 現行の版に同意済みの利用者の同意のサービス
    private func agreedGuideline() -> MockSoratomoGuidelineService {
        let guideline = MockSoratomoGuidelineService()
        guideline.fetchConsentStatusResult = .success(
            SoratomoConsentStatus(agreedVersion: SoratomoGuideline.currentVersion, groupCount: 1)
        )
        return guideline
    }

    /// まだ同意していない利用者の同意のサービス（所属 0＝初めてグループを作る人）
    private func unagreedGuideline() -> MockSoratomoGuidelineService {
        let guideline = MockSoratomoGuidelineService()
        guideline.fetchConsentStatusResult = .success(SoratomoConsentStatus(agreedVersion: nil, groupCount: 0))
        return guideline
    }

    /// 表示名が設定済みの利用者の表示名のサービス
    private func profileWithName() -> MockSoratomoProfileService {
        let profile = MockSoratomoProfileService()
        profile.needsDisplayNameResult = .success(false)
        return profile
    }

    /// 条件が満たされるまで待つ（最大およそ 2 秒）
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 表示名が要るか（13.2）

    func testNeedsDisplayNameShowsDisplayNameStepFirst() async {
        let profile = MockSoratomoProfileService()
        profile.needsDisplayNameResult = .success(true)
        let viewModel = makeViewModel(
            mode: .create, groupService: MockSoratomoGroupService(), profileService: profile, recorder: Recorder()
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.step, .displayName)
        XCTAssertEqual(profile.needsDisplayNameCalls, ["me"])
    }

    func testDisplayNameAlreadySetSkipsDisplayNameStep() async {
        let viewModel = makeViewModel(
            mode: .join, groupService: MockSoratomoGroupService(), profileService: profileWithName(), recorder: Recorder()
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.step, .form)
    }

    func testNeedsDisplayNameFailureNeverProceeds() async {
        for error in [SoratomoError.network, .notMember, .permissionDenied, .unknown] {
            let profile = MockSoratomoProfileService()
            profile.needsDisplayNameResult = .failure(error)
            let groupService = MockSoratomoGroupService()
            let recorder = Recorder()
            let viewModel = makeViewModel(
                mode: .create, groupService: groupService, profileService: profile, recorder: recorder
            )

            await viewModel.start()
            // 確かめられなかった段では、確定しても作成へ進まない
            viewModel.groupNameInput = "空の会"
            await viewModel.submit()

            let expected = error == .network ? SoratomoError.network.userMessage : SoratomoError.unknown.userMessage
            XCTAssertEqual(viewModel.step, .checkFailed(message: expected), "error=\(error)")
            XCTAssertTrue(groupService.createGroupCalls.isEmpty, "error=\(error)")
            XCTAssertTrue(recorder.completed.isEmpty, "error=\(error)")
        }
    }

    func testRetryAfterNeedsDisplayNameFailureChecksAgain() async {
        let profile = MockSoratomoProfileService()
        profile.needsDisplayNameResult = .failure(.network)
        let viewModel = makeViewModel(
            mode: .create, groupService: MockSoratomoGroupService(), profileService: profile, recorder: Recorder()
        )

        await viewModel.start()
        profile.needsDisplayNameResult = .success(false)
        await viewModel.start()

        XCTAssertEqual(viewModel.step, .form)
        XCTAssertEqual(profile.needsDisplayNameCalls.count, 2)
    }

    // MARK: - 表示名の保存（13.2）

    func testSaveDisplayNameFailureKeepsInputAndDoesNotProceed() async {
        let profile = MockSoratomoProfileService()
        profile.needsDisplayNameResult = .success(true)
        profile.saveDisplayNameResult = .failure(.network)
        let groupService = MockSoratomoGroupService()
        let recorder = Recorder()
        let viewModel = makeViewModel(
            mode: .create, groupService: groupService, profileService: profile, recorder: recorder
        )
        await viewModel.start()

        viewModel.displayNameInput = "  そらさん  "
        await viewModel.saveDisplayName()
        // 先へ進んでいないので、作成の確定も受け付けない
        viewModel.groupNameInput = "空の会"
        await viewModel.submit()

        XCTAssertEqual(viewModel.step, .displayName)
        XCTAssertEqual(viewModel.displayNameInput, "  そらさん  ")
        XCTAssertEqual(viewModel.errorMessage, SoratomoFailedAction.saveDisplayName.userMessage)
        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertEqual(profile.saveDisplayNameCalls.map(\.name.value), ["そらさん"])
        XCTAssertEqual(recorder.events, [.displayNameFailed(.network)])
        XCTAssertTrue(groupService.createGroupCalls.isEmpty)
    }

    func testSaveDisplayNameUnknownFailureShowsSameOperationMessage() async {
        let profile = MockSoratomoProfileService()
        profile.needsDisplayNameResult = .success(true)
        profile.saveDisplayNameResult = .failure(.permissionDenied)
        let recorder = Recorder()
        let viewModel = makeViewModel(
            mode: .join, groupService: MockSoratomoGroupService(), profileService: profile, recorder: recorder
        )
        await viewModel.start()

        viewModel.displayNameInput = "そら"
        await viewModel.saveDisplayName()

        XCTAssertEqual(viewModel.step, .displayName)
        XCTAssertEqual(viewModel.errorMessage, SoratomoFailedAction.saveDisplayName.userMessage)
        XCTAssertEqual(recorder.events, [.displayNameFailed(.unknown)])
    }

    func testSaveDisplayNameInvalidLengthDoesNotSave() async {
        for input in ["   ", String(repeating: "あ", count: SoratomoTextRules.displayNameMax + 1)] {
            let profile = MockSoratomoProfileService()
            profile.needsDisplayNameResult = .success(true)
            profile.saveDisplayNameResult = .success(())
            let recorder = Recorder()
            let viewModel = makeViewModel(
                mode: .create, groupService: MockSoratomoGroupService(), profileService: profile, recorder: recorder
            )
            await viewModel.start()

            viewModel.displayNameInput = input
            await viewModel.saveDisplayName()

            XCTAssertEqual(viewModel.step, .displayName)
            XCTAssertEqual(viewModel.displayNameInput, input)
            XCTAssertEqual(viewModel.errorMessage, SoratomoError.displayNameInvalid.userMessage)
            XCTAssertTrue(profile.saveDisplayNameCalls.isEmpty)
            XCTAssertEqual(recorder.events, [.displayNameFailed(.invalidLength)])
        }
    }

    func testSaveDisplayNameOfflineDoesNotSave() async {
        let profile = MockSoratomoProfileService()
        profile.needsDisplayNameResult = .success(true)
        profile.saveDisplayNameResult = .success(())
        let recorder = Recorder()
        let viewModel = makeViewModel(
            mode: .create, groupService: MockSoratomoGroupService(), profileService: profile,
            online: false, recorder: recorder
        )
        await viewModel.start()

        viewModel.displayNameInput = "そら"
        await viewModel.saveDisplayName()

        XCTAssertEqual(viewModel.step, .displayName)
        XCTAssertEqual(viewModel.displayNameInput, "そら")
        XCTAssertEqual(viewModel.errorMessage, SoratomoFailedAction.saveDisplayName.userMessage)
        XCTAssertTrue(profile.saveDisplayNameCalls.isEmpty)
        XCTAssertEqual(recorder.events, [.displayNameFailed(.network)])
    }

    func testSaveDisplayNameSuccessProceedsToForm() async {
        let profile = MockSoratomoProfileService()
        profile.needsDisplayNameResult = .success(true)
        profile.saveDisplayNameResult = .success(())
        let recorder = Recorder()
        let viewModel = makeViewModel(
            mode: .join, groupService: MockSoratomoGroupService(), profileService: profile, recorder: recorder
        )
        await viewModel.start()

        viewModel.displayNameInput = " そら "
        await viewModel.saveDisplayName()

        XCTAssertEqual(viewModel.step, .form)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(profile.saveDisplayNameCalls.map(\.uid), ["me"])
        XCTAssertEqual(profile.saveDisplayNameCalls.map(\.name.value), ["そら"])
        XCTAssertEqual(recorder.events, [.displayNameSaved(trigger: .join)])
    }

    // MARK: - 二重の確定（13.3）

    func testCreateIgnoresSecondSubmitWhileProcessing() async {
        let groupService = SoratomoGroupFormGatedGroupService()
        let recorder = Recorder()
        let viewModel = makeViewModel(
            mode: .create, groupService: groupService, profileService: profileWithName(), recorder: recorder
        )
        await viewModel.start()
        viewModel.groupNameInput = "空の会"

        let first = Task { await viewModel.submit() }
        await waitUntil { groupService.waitingCount == 1 }
        XCTAssertEqual(viewModel.phase, .processing)

        // 処理中に、もう一度確定する
        let second = Task { await viewModel.submit() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(groupService.createCalls, 1)

        groupService.releaseAll()
        await first.value
        await second.value

        XCTAssertEqual(groupService.createCalls, 1)
        XCTAssertEqual(recorder.events, [.groupCreated])
        XCTAssertEqual(recorder.completed, [[.timeline(groupId: "g-created"), .invite(groupId: "g-created")]])
    }

    func testJoinIgnoresSecondSubmitWhileProcessing() async {
        let groupService = SoratomoGroupFormGatedGroupService()
        let recorder = Recorder()
        let viewModel = makeViewModel(
            mode: .join, groupService: groupService, profileService: profileWithName(), recorder: recorder
        )
        await viewModel.start()
        viewModel.inviteCodeInput = "abcd-efgh"

        let first = Task { await viewModel.submit() }
        await waitUntil { groupService.waitingCount == 1 }

        let second = Task { await viewModel.submit() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(groupService.joinCalls, 1)

        groupService.releaseAll()
        await first.value
        await second.value

        XCTAssertEqual(groupService.joinCalls, 1)
        XCTAssertEqual(recorder.completed, [[.timeline(groupId: "g-joined")]])
    }

    // MARK: - 失敗で入力が残る（13.3）

    func testCreateFailureKeepsInputAndShowsFixedMessage() async {
        for error in [SoratomoError.userLimit, .network, .flagOff, .unknown] {
            let groupService = MockSoratomoGroupService()
            groupService.createGroupResult = .failure(error)
            let recorder = Recorder()
            let viewModel = makeViewModel(
                mode: .create, groupService: groupService, profileService: profileWithName(), recorder: recorder
            )
            await viewModel.start()

            viewModel.groupNameInput = " 空の会 "
            await viewModel.submit()

            XCTAssertEqual(viewModel.groupNameInput, " 空の会 ", "error=\(error)")
            XCTAssertEqual(viewModel.errorMessage, error.userMessage, "error=\(error)")
            XCTAssertEqual(viewModel.step, .form, "error=\(error)")
            XCTAssertEqual(viewModel.phase, .idle, "error=\(error)")
            XCTAssertEqual(groupService.createGroupCalls.map(\.name), ["空の会"], "error=\(error)")
            XCTAssertEqual(recorder.events, [.createFailed(SoratomoCreateFailReason(error))], "error=\(error)")
            XCTAssertTrue(recorder.completed.isEmpty, "error=\(error)")
        }
    }

    func testJoinFailureKeepsInputAndShowsFixedMessage() async {
        for error in [SoratomoError.notFound, .groupFull, .userLimit, .network, .flagOff] {
            let groupService = MockSoratomoGroupService()
            groupService.joinGroupResult = .failure(error)
            let recorder = Recorder()
            let viewModel = makeViewModel(
                mode: .join, groupService: groupService, profileService: profileWithName(), recorder: recorder
            )
            await viewModel.start()

            viewModel.inviteCodeInput = "ａｂｃｄ－ｅｆｇｈ"
            await viewModel.submit()

            XCTAssertEqual(viewModel.inviteCodeInput, "ａｂｃｄ－ｅｆｇｈ", "error=\(error)")
            XCTAssertEqual(viewModel.errorMessage, error.userMessage, "error=\(error)")
            XCTAssertEqual(viewModel.phase, .idle, "error=\(error)")
            XCTAssertEqual(groupService.joinGroupCalls.map(\.rawValue), ["ABCDEFGH"], "error=\(error)")
            XCTAssertEqual(recorder.events, [.joinFailed(SoratomoJoinFailReason(error))], "error=\(error)")
            XCTAssertTrue(recorder.completed.isEmpty, "error=\(error)")
        }
    }

    func testOfflineDoesNotStartAndKeepsInput() async {
        let groupService = MockSoratomoGroupService()
        groupService.createGroupResult = .success(
            SoratomoGroupSummary(
                groupId: "g1", name: "空の会",
                inviteCode: SoratomoInviteCode.parse(userInput: "ABCD-EFGH")!, memberCount: 1
            )
        )
        groupService.joinGroupResult = .success(SoratomoJoinResult(groupId: "g1", alreadyMember: false))

        let createRecorder = Recorder()
        let create = makeViewModel(
            mode: .create, groupService: groupService, profileService: profileWithName(),
            online: false, recorder: createRecorder
        )
        await create.start()
        create.groupNameInput = "空の会"
        await create.submit()

        let joinRecorder = Recorder()
        let join = makeViewModel(
            mode: .join, groupService: groupService, profileService: profileWithName(),
            online: false, recorder: joinRecorder
        )
        await join.start()
        join.inviteCodeInput = "ABCD-EFGH"
        await join.submit()

        XCTAssertTrue(groupService.createGroupCalls.isEmpty)
        XCTAssertTrue(groupService.joinGroupCalls.isEmpty)
        XCTAssertEqual(create.groupNameInput, "空の会")
        XCTAssertEqual(join.inviteCodeInput, "ABCD-EFGH")
        XCTAssertEqual(create.errorMessage, SoratomoError.network.userMessage)
        XCTAssertEqual(join.errorMessage, SoratomoError.network.userMessage)
        XCTAssertEqual(createRecorder.events, [.createFailed(.network)])
        XCTAssertEqual(joinRecorder.events, [.joinFailed(.network)])
    }

    func testInvalidGroupNameDoesNotCreate() async {
        let groupService = MockSoratomoGroupService()
        let recorder = Recorder()
        let viewModel = makeViewModel(
            mode: .create, groupService: groupService, profileService: profileWithName(), recorder: recorder
        )
        await viewModel.start()

        viewModel.groupNameInput = "   "
        await viewModel.submit()

        XCTAssertTrue(groupService.createGroupCalls.isEmpty)
        XCTAssertEqual(viewModel.groupNameInput, "   ")
        XCTAssertEqual(viewModel.errorMessage, SoratomoError.invalidName.userMessage)
        XCTAssertEqual(recorder.events, [.createFailed(.invalidName)])
    }

    func testMalformedInviteCodeDoesNotQueryServer() async {
        let groupService = MockSoratomoGroupService()
        let recorder = Recorder()
        let viewModel = makeViewModel(
            mode: .join, groupService: groupService, profileService: profileWithName(), recorder: recorder
        )
        await viewModel.start()

        viewModel.inviteCodeInput = "ABC-DEF"
        await viewModel.submit()

        XCTAssertTrue(groupService.joinGroupCalls.isEmpty)
        XCTAssertEqual(viewModel.inviteCodeInput, "ABC-DEF")
        XCTAssertEqual(viewModel.errorMessage, SoratomoError.invalidFormat.userMessage)
        XCTAssertEqual(recorder.events, [.joinFailed(.invalidFormat)])
    }

    // MARK: - 要求 ID の再利用（13.3）

    func testCreateReusesRequestIdUntilNameChanges() async {
        let groupService = MockSoratomoGroupService()
        groupService.createGroupResult = .failure(.network)
        let viewModel = makeViewModel(
            mode: .create, groupService: groupService, profileService: profileWithName(), recorder: Recorder()
        )
        await viewModel.start()

        // 1 回目と、タイムアウトの後の再試行（同じ名前）
        viewModel.groupNameInput = "空の会"
        await viewModel.submit()
        await viewModel.submit()
        // 前後の空白だけを足した（サーバーへ送る名前は同じ）
        viewModel.groupNameInput = " 空の会 "
        await viewModel.submit()
        // 名前を変えた
        viewModel.groupNameInput = "夕焼けの会"
        await viewModel.submit()
        await viewModel.submit()

        let ids = groupService.createGroupCalls.map(\.requestId)
        XCTAssertEqual(ids.count, 5)
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertEqual(ids[0], ids[2])
        XCTAssertNotEqual(ids[0], ids[3])
        XCTAssertEqual(ids[3], ids[4])
    }

    // MARK: - 成功の後（13.3・12.2）

    func testCreateSuccessWithoutPrimerCompletesWithTimelineThenInvite() async {
        let groupService = MockSoratomoGroupService()
        groupService.createGroupResult = .success(
            SoratomoGroupSummary(
                groupId: "g1", name: "空の会",
                inviteCode: SoratomoInviteCode.parse(userInput: "ABCD-EFGH")!, memberCount: 1
            )
        )
        let primer = SoratomoGroupFormPrimerStub()
        primer.decision = .none
        let recorder = Recorder()
        let viewModel = makeViewModel(
            mode: .create, groupService: groupService, profileService: profileWithName(),
            primer: primer, recorder: recorder
        )
        await viewModel.start()

        viewModel.groupNameInput = "空の会"
        await viewModel.submit()
        // 完了の後の確定は受け付けない
        await viewModel.submit()

        XCTAssertEqual(primer.decideCalls, 1)
        XCTAssertEqual(viewModel.phase, .completed)
        XCTAssertEqual(groupService.createGroupCalls.count, 1)
        XCTAssertEqual(recorder.events, [.groupCreated])
        XCTAssertEqual(recorder.completed, [[.timeline(groupId: "g1"), .invite(groupId: "g1")]])
    }

    func testJoinAlreadyMemberCompletesWithTimeline() async {
        let groupService = MockSoratomoGroupService()
        groupService.joinGroupResult = .success(SoratomoJoinResult(groupId: "g1", alreadyMember: true))
        let recorder = Recorder()
        let viewModel = makeViewModel(
            mode: .join, groupService: groupService, profileService: profileWithName(), recorder: recorder
        )
        await viewModel.start()

        viewModel.inviteCodeInput = "ABCD-EFGH"
        await viewModel.submit()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(recorder.events, [.groupJoined(alreadyMember: true)])
        XCTAssertEqual(recorder.completed, [[.timeline(groupId: "g1")]])
    }

    func testPrimerIsShownBeforeCompletingAndCompletesOnce() async {
        for decision in [SoratomoPrimerDecision.showPrimer, .showSettingsGuide] {
            let groupService = MockSoratomoGroupService()
            groupService.joinGroupResult = .success(SoratomoJoinResult(groupId: "g1", alreadyMember: false))
            let primer = SoratomoGroupFormPrimerStub()
            primer.decision = decision
            let recorder = Recorder()
            let viewModel = makeViewModel(
                mode: .join, groupService: groupService, profileService: profileWithName(),
                primer: primer, recorder: recorder
            )
            await viewModel.start()

            viewModel.inviteCodeInput = "ABCD-EFGH"
            await viewModel.submit()

            // 事前説明（または設定の案内）を出している間は、まだ行き先を渡さない。閉じさせもしない
            XCTAssertEqual(viewModel.step, .primer(decision))
            XCTAssertFalse(viewModel.canCancel)
            XCTAssertTrue(recorder.completed.isEmpty)

            viewModel.finishPrimer()
            viewModel.finishPrimer()

            XCTAssertEqual(primer.decideCalls, 1)
            XCTAssertEqual(recorder.completed, [[.timeline(groupId: "g1")]])
        }
    }

    // MARK: - ガイドラインへの同意（release-gate 10.4）

    func testUnagreedShowsGuidelineBeforeDisplayNameAndProceedsAfterAgree() async {
        let profile = MockSoratomoProfileService()
        profile.needsDisplayNameResult = .success(true)
        let guideline = unagreedGuideline()
        guideline.agreeResult = .success(())
        let viewModel = makeViewModel(
            mode: .create, groupService: MockSoratomoGroupService(), profileService: profile,
            guideline: guideline, recorder: Recorder()
        )

        await viewModel.start()

        // 所属 0 でも、表示名・グループ名より先に全文を出す（要件 10.1）
        XCTAssertEqual(viewModel.step, .guideline(.create))
        XCTAssertTrue(viewModel.canCancel)

        await viewModel.agreeGuideline()

        // 記録に成功してから、表示名の入力へ進む（要件 10.6）
        XCTAssertEqual(guideline.agreeCalls, [SoratomoGuideline.currentVersion])
        XCTAssertEqual(viewModel.step, .displayName)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testAgreedSkipsGuidelineForCreateAndJoin() async {
        for mode in [SoratomoGroupFormMode.create, .join] {
            let guideline = agreedGuideline()
            let viewModel = makeViewModel(
                mode: mode, groupService: MockSoratomoGroupService(), profileService: profileWithName(),
                guideline: guideline, recorder: Recorder()
            )

            await viewModel.start()

            // 同意済みなら全文を出さない（要件 10.8）
            XCTAssertEqual(viewModel.step, .form, "mode=\(mode)")
            XCTAssertTrue(guideline.agreeCalls.isEmpty, "mode=\(mode)")
        }
    }

    func testJoinGuidelineUsesJoinTrigger() async {
        let viewModel = makeViewModel(
            mode: .join, groupService: MockSoratomoGroupService(), profileService: profileWithName(),
            guideline: unagreedGuideline(), recorder: Recorder()
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.step, .guideline(.join))
    }

    func testDeclineClosesWithoutRecording() async {
        let guideline = unagreedGuideline()
        let groupService = MockSoratomoGroupService()
        let recorder = Recorder()
        let viewModel = makeViewModel(
            mode: .create, groupService: groupService, profileService: profileWithName(),
            guideline: guideline, recorder: recorder
        )

        await viewModel.start()
        viewModel.declineGuideline()

        // 同意を記録せず、作成へ進ませずにシートを閉じる（要件 10.4）
        XCTAssertEqual(recorder.declined, 1)
        XCTAssertTrue(guideline.agreeCalls.isEmpty)
        XCTAssertTrue(groupService.createGroupCalls.isEmpty)
        XCTAssertTrue(recorder.completed.isEmpty)
    }

    func testAgreeFailureDoesNotProceed() async {
        for error in [SoratomoError.network, .unknown] {
            let guideline = unagreedGuideline()
            guideline.agreeResult = .failure(error)
            let viewModel = makeViewModel(
                mode: .create, groupService: MockSoratomoGroupService(), profileService: profileWithName(),
                guideline: guideline, recorder: Recorder()
            )

            await viewModel.start()
            await viewModel.agreeGuideline()

            // 先へ進ませず「同意を記録できませんでした」（要件 10.7）
            XCTAssertEqual(viewModel.step, .guideline(.create), "error=\(error)")
            XCTAssertEqual(viewModel.errorMessage, "同意を記録できませんでした", "error=\(error)")
            XCTAssertFalse(viewModel.isProcessing, "error=\(error)")
        }
    }

    func testAgreeOfflineDoesNotRecordOrProceed() async {
        let guideline = unagreedGuideline()
        guideline.agreeResult = .success(())
        let viewModel = makeViewModel(
            mode: .join, groupService: MockSoratomoGroupService(), profileService: profileWithName(),
            guideline: guideline, online: false, recorder: Recorder()
        )

        await viewModel.start()
        await viewModel.agreeGuideline()

        XCTAssertTrue(guideline.agreeCalls.isEmpty)
        XCTAssertEqual(viewModel.step, .guideline(.join))
        XCTAssertEqual(viewModel.errorMessage, "同意を記録できませんでした")
    }

    func testAgreeRejectedAsOutdatedAppShowsUpdateGuide() async {
        let guideline = unagreedGuideline()
        guideline.agreeResult = .failure(.outdatedApp)
        let viewModel = makeViewModel(
            mode: .create, groupService: MockSoratomoGroupService(), profileService: profileWithName(),
            guideline: guideline, recorder: Recorder()
        )

        await viewModel.start()
        await viewModel.agreeGuideline()

        XCTAssertEqual(viewModel.step, .guideline(.create))
        XCTAssertEqual(viewModel.errorMessage, "アプリを最新の版にアップデートしてください")
    }

    func testConsentStatusUnreadableDoesNotBlock() async {
        let guideline = MockSoratomoGuidelineService()
        guideline.fetchConsentStatusResult = .failure(.network)
        let viewModel = makeViewModel(
            mode: .create, groupService: MockSoratomoGroupService(), profileService: profileWithName(),
            guideline: guideline, recorder: Recorder()
        )

        await viewModel.start()

        // 読めなければ全文を出さずに進む（作成と参加はサーバーが同意を確かめる）
        XCTAssertEqual(viewModel.step, .form)
    }

    func testConsentRequiredReturnsToGuidelineKeepsInputAndResumesForm() async {
        let groupService = MockSoratomoGroupService()
        groupService.createGroupResult = .failure(.consentRequired)
        let guideline = agreedGuideline()
        guideline.agreeResult = .success(())
        let viewModel = makeViewModel(
            mode: .create, groupService: groupService, profileService: profileWithName(),
            guideline: guideline, recorder: Recorder()
        )

        await viewModel.start()
        viewModel.groupNameInput = "空の会"
        await viewModel.submit()

        // サーバーが同意を求めたら全文へ戻り、入力は残す（要件 10.11）
        XCTAssertEqual(viewModel.step, .guideline(.create))
        XCTAssertEqual(viewModel.groupNameInput, "空の会")
        XCTAssertNil(viewModel.errorMessage)

        await viewModel.agreeGuideline()

        // 同意したら入力の段へ戻り、入力したグループ名で確定し直せる
        XCTAssertEqual(viewModel.step, .form)
        XCTAssertEqual(viewModel.groupNameInput, "空の会")
    }

    func testConsentRequiredOnJoinKeepsInviteCode() async {
        let groupService = MockSoratomoGroupService()
        groupService.joinGroupResult = .failure(.consentRequired)
        let viewModel = makeViewModel(
            mode: .join, groupService: groupService, profileService: profileWithName(), recorder: Recorder()
        )

        await viewModel.start()
        viewModel.inviteCodeInput = "ABCD-EFGH"
        await viewModel.submit()

        XCTAssertEqual(viewModel.step, .guideline(.join))
        XCTAssertEqual(viewModel.inviteCodeInput, "ABCD-EFGH")
    }

    // MARK: - 作成・参加の拒否の文言（release-gate 10.4・要件 8.7・11.6・11.9）

    func testRejectionMessagesKeepInputAndDoNotRevealWord() async {
        let cases: [(SoratomoError, String)] = [
            (.suspended, "そらともの利用が停止されています。設定の『お問い合わせ』からご連絡ください"),
            (.outdatedApp, "アプリを最新の版にアップデートしてください"),
            (.ngWord, "使えない言葉が含まれています"),
        ]
        for (error, message) in cases {
            let groupService = MockSoratomoGroupService()
            groupService.createGroupResult = .failure(error)
            groupService.joinGroupResult = .failure(error)

            let create = makeViewModel(
                mode: .create, groupService: groupService, profileService: profileWithName(), recorder: Recorder()
            )
            await create.start()
            create.groupNameInput = "空の会"
            await create.submit()

            XCTAssertEqual(create.step, .form, "error=\(error)")
            XCTAssertEqual(create.errorMessage, message, "error=\(error)")
            XCTAssertEqual(create.groupNameInput, "空の会", "error=\(error)")
            XCTAssertFalse(create.errorMessage?.contains("空の会") ?? true, "error=\(error)")

            let join = makeViewModel(
                mode: .join, groupService: groupService, profileService: profileWithName(), recorder: Recorder()
            )
            await join.start()
            join.inviteCodeInput = "ABCD-EFGH"
            await join.submit()

            XCTAssertEqual(join.step, .form, "error=\(error)")
            XCTAssertEqual(join.errorMessage, message, "error=\(error)")
            XCTAssertEqual(join.inviteCodeInput, "ABCD-EFGH", "error=\(error)")
        }
    }
}
