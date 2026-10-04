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
}
