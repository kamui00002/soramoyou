//
//  SoratomoInviteViewModelTests.swift
//  SoramoyouTests
//
//  そらともの招待コードの共有と再発行の ViewModel のテスト ⭐️（tasks 13.4）
//
//  - オーナーにだけ再発行の操作を出すこと（uid と ownerId の比較・未ログインはオーナーでない）
//  - 再発行に成功したら新しいコードを出し、soratomo_invite_code_regenerated を記録すること
//  - 再発行に失敗したら（通信を含む）表示中のコードを変えず、固定の文言と理由つきの記録を残すこと
//  - コピーで「XXXX-XXXX」をクリップボードへ写し、soratomo_invite_shared(copy) を記録すること
//  - 招待文が要件 3.5 の 4 行のままであること
//

@testable import Soramoyou
import XCTest

@MainActor
final class SoratomoInviteViewModelTests: XCTestCase {
    /// 記録した計測を覚える
    private final class EventLog {
        var events: [SoratomoEvent] = []
    }

    /// クリップボードの代役（写した文字列を覚える）
    private final class PasteboardSpy {
        var copied: [String] = []
    }

    /// テスト用のグループの ID
    private let groupId = "g1"

    /// テスト用の招待コード
    private func code(_ text: String) -> SoratomoInviteCode {
        SoratomoInviteCode.parse(userInput: text)!
    }

    /// テスト用のグループ
    private func makeGroup(ownerId: String = "owner", inviteCode: String = "ABCD-EFGH") -> SoratomoGroup {
        SoratomoGroup(
            id: groupId,
            name: "空の会",
            ownerId: ownerId,
            inviteCode: code(inviteCode),
            memberCount: 3,
            createdAt: Date(timeIntervalSince1970: 0),
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
    }

    /// ViewModel を作り、監視を始めてグループを 1 回届ける
    private func makeStartedViewModel(
        service: MockSoratomoGroupService,
        uid: String?,
        log: EventLog = EventLog(),
        pasteboard: PasteboardSpy = PasteboardSpy()
    ) -> SoratomoInviteViewModel {
        let viewModel = SoratomoInviteViewModel(
            groupId: groupId,
            groupService: service,
            currentUid: { uid },
            logEvent: { log.events.append($0) },
            copyToPasteboard: { pasteboard.copied.append($0) }
        )
        viewModel.start()
        service.emitGroup(groupId: groupId, .success(makeGroup()))
        return viewModel
    }

    // MARK: - 監視とオーナー判定

    func testOwnerSeesRegenerateAndGroupIsShown() {
        let service = MockSoratomoGroupService()
        let viewModel = makeStartedViewModel(service: service, uid: "owner")

        XCTAssertEqual(service.observeGroupCalls, [groupId])
        XCTAssertTrue(viewModel.isOwner)
        XCTAssertEqual(viewModel.groupName, "空の会")
        XCTAssertEqual(viewModel.inviteCode?.displayText, "ABCD-EFGH")
        XCTAssertNil(viewModel.loadErrorMessage)
    }

    func testMemberWhoIsNotOwnerDoesNotSeeRegenerate() {
        let service = MockSoratomoGroupService()
        let viewModel = makeStartedViewModel(service: service, uid: "member")

        XCTAssertFalse(viewModel.isOwner)
    }

    func testSignedOutIsNotOwner() {
        let service = MockSoratomoGroupService()
        let viewModel = makeStartedViewModel(service: service, uid: nil)

        XCTAssertFalse(viewModel.isOwner)
    }

    func testStartTwiceObservesOnce() {
        let service = MockSoratomoGroupService()
        let viewModel = makeStartedViewModel(service: service, uid: "owner")

        viewModel.start()

        XCTAssertEqual(service.observeGroupCalls, [groupId])
    }

    func testObserveFailureBeforeFirstLoadShowsFixedMessage() {
        let service = MockSoratomoGroupService()
        let viewModel = SoratomoInviteViewModel(
            groupId: groupId,
            groupService: service,
            currentUid: { "owner" },
            logEvent: { _ in },
            copyToPasteboard: { _ in }
        )
        viewModel.start()

        service.emitGroup(groupId: groupId, .failure(.notMember))

        XCTAssertEqual(viewModel.loadErrorMessage, SoratomoError.notMember.userMessage)
        XCTAssertNil(viewModel.inviteCode)
        XCTAssertFalse(viewModel.isOwner)
    }

    func testObserveFailureAfterLoadKeepsShownCode() {
        let service = MockSoratomoGroupService()
        let viewModel = makeStartedViewModel(service: service, uid: "owner")

        service.emitGroup(groupId: groupId, .failure(.network))

        // 一度読めた内容は、一時的な失敗で消さない
        XCTAssertEqual(viewModel.inviteCode?.displayText, "ABCD-EFGH")
        XCTAssertNil(viewModel.loadErrorMessage)
    }

    // MARK: - 再発行

    func testRegenerateSuccessShowsNewCodeAndLogs() async {
        let service = MockSoratomoGroupService()
        service.regenerateInviteCodeResult = .success(code("WXYZ-2345"))
        let log = EventLog()
        let viewModel = makeStartedViewModel(service: service, uid: "owner", log: log)

        await viewModel.regenerate()

        XCTAssertEqual(service.regenerateInviteCodeCalls, [groupId])
        XCTAssertEqual(viewModel.inviteCode?.displayText, "WXYZ-2345")
        XCTAssertNil(viewModel.regenerateErrorMessage)
        XCTAssertFalse(viewModel.isRegenerating)
        XCTAssertEqual(log.events, [.inviteCodeRegenerated])
    }

    func testRegenerateFailureKeepsShownCodeAndLogsReason() async {
        // 通信を含む各失敗で、表示中のコードを変えずに固定の文言を出し、理由を写して記録する
        let cases: [(SoratomoError, SoratomoRegenerateFailReason)] = [
            (.network, .network),
            (.notOwner, .notOwner),
            (.unknown, .unknown),
            (.permissionDenied, .unknown),
        ]
        for (error, reason) in cases {
            let service = MockSoratomoGroupService()
            service.regenerateInviteCodeResult = .failure(error)
            let log = EventLog()
            let viewModel = makeStartedViewModel(service: service, uid: "owner", log: log)

            await viewModel.regenerate()

            XCTAssertEqual(viewModel.inviteCode?.displayText, "ABCD-EFGH", "\(error)")
            XCTAssertEqual(
                viewModel.regenerateErrorMessage,
                SoratomoFailedAction.regenerateInviteCode.userMessage,
                "\(error)"
            )
            XCTAssertFalse(viewModel.isRegenerating, "\(error)")
            XCTAssertEqual(log.events, [.inviteRegenerateFailed(reason)], "\(error)")
        }
    }

    func testNonOwnerCannotRegenerate() async {
        let service = MockSoratomoGroupService()
        service.regenerateInviteCodeResult = .success(code("WXYZ-2345"))
        let log = EventLog()
        let viewModel = makeStartedViewModel(service: service, uid: "member", log: log)

        await viewModel.regenerate()

        XCTAssertTrue(service.regenerateInviteCodeCalls.isEmpty)
        XCTAssertEqual(viewModel.inviteCode?.displayText, "ABCD-EFGH")
        XCTAssertTrue(log.events.isEmpty)
    }

    // MARK: - 共有・コピー

    func testCopyWritesDisplayTextAndLogsCopy() {
        let service = MockSoratomoGroupService()
        let log = EventLog()
        let pasteboard = PasteboardSpy()
        let viewModel = makeStartedViewModel(service: service, uid: "member", log: log, pasteboard: pasteboard)

        viewModel.copyInviteCode()

        XCTAssertEqual(pasteboard.copied, ["ABCD-EFGH"])
        XCTAssertTrue(viewModel.didCopy)
        XCTAssertEqual(log.events, [.inviteShared(.copy)])
    }

    func testRecordShareSheetOpenedLogsShareSheet() {
        let service = MockSoratomoGroupService()
        let log = EventLog()
        let viewModel = makeStartedViewModel(service: service, uid: "member", log: log)

        viewModel.recordShareSheetOpened()

        XCTAssertEqual(log.events, [.inviteShared(.shareSheet)])
    }

    func testInviteTextIsTheFourLinesOfRequirement3_5() {
        let text = SoratomoInviteViewModel.makeInviteText(
            groupName: "空の会",
            inviteCode: code("ABCDEFGH"),
            appStoreURL: "https://example.com/app"
        )

        XCTAssertEqual(
            text,
            """
            「空の会」に招待されました。
            そらもようで空を共有しよう！
            招待コード: ABCD-EFGH
            アプリをお持ちでない方: https://example.com/app
            """
        )
        XCTAssertEqual(text.components(separatedBy: "\n").count, 4)
    }

    func testInviteTextIsNilBeforeGroupIsLoaded() {
        let viewModel = SoratomoInviteViewModel(
            groupId: groupId,
            groupService: MockSoratomoGroupService(),
            currentUid: { "owner" },
            logEvent: { _ in },
            copyToPasteboard: { _ in }
        )

        XCTAssertNil(viewModel.inviteText)
    }
}
