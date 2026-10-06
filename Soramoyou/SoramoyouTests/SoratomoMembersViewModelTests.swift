//
//  SoratomoMembersViewModelTests.swift
//  SoramoyouTests
//
//  そらとものメンバー一覧の ViewModel と、投稿詳細の画像の説明のテスト ⭐️（tasks 13.9）
//
//  - オーナーを先頭に、その後は参加の古い順に並べること（オーナーの参加日時が最後でも先頭に来ること）
//  - `soratomo_members_viewed`（member_count）を、最初に読めたときだけ 1 回記録すること
//  - 読めなかったときは記録せず、固定の文言を出すこと
//  - 投稿画像の VoiceOver の説明が、キャプション（無ければ「{表示名}さんの空」）になること
//

@testable import Soramoyou
import XCTest

@MainActor
final class SoratomoMembersViewModelTests: XCTestCase {
    /// 記録した計測を覚える
    private final class EventLog {
        var events: [SoratomoEvent] = []
    }

    /// テスト用のメンバー
    /// - Parameters:
    ///   - id: uid
    ///   - role: オーナーかメンバーか
    ///   - joinedAt: 参加日時（1970 年からの秒）
    private func makeMember(id: String, role: SoratomoMemberRole, joinedAt: TimeInterval) -> SoratomoMember {
        SoratomoMember(id: id, role: role, joinedAt: Date(timeIntervalSince1970: joinedAt))
    }

    // MARK: - 並び順

    func testOwnerComesFirstEvenIfJoinedLastThenJoinOrder() async {
        // オーナーの参加日時がいちばん新しい（記録がずれた場合）。それでも先頭に来ること
        let service = MockSoratomoGroupService()
        service.fetchMembersResult = .success([
            makeMember(id: "late", role: .member, joinedAt: 300),
            makeMember(id: "owner", role: .owner, joinedAt: 999),
            makeMember(id: "early", role: .member, joinedAt: 100),
            makeMember(id: "middle", role: .member, joinedAt: 200),
        ])
        let viewModel = SoratomoMembersViewModel(
            groupId: "g1",
            groupService: service,
            logEvent: { _ in }
        )

        await viewModel.load()

        guard case let .loaded(members) = viewModel.state else {
            return XCTFail("読み込みが完了していない")
        }
        XCTAssertEqual(members.map(\.id), ["owner", "early", "middle", "late"])
        XCTAssertEqual(service.fetchMembersCalls, ["g1"])
        XCTAssertEqual(viewModel.memberUids, ["owner", "early", "middle", "late"])
    }

    func testSameJoinedAtIsOrderedByUid() {
        // 参加日時が同じなら uid の順（毎回同じ並びにするため）
        let ordered = SoratomoMembersViewModel.ordered([
            makeMember(id: "b", role: .member, joinedAt: 100),
            makeMember(id: "a", role: .member, joinedAt: 100),
            makeMember(id: "owner", role: .owner, joinedAt: 50),
        ])
        XCTAssertEqual(ordered.map(\.id), ["owner", "a", "b"])
    }

    // MARK: - 計測

    func testFirstSuccessfulLoadLogsMembersViewedOnceWithMemberCount() async {
        let service = MockSoratomoGroupService()
        service.fetchMembersResult = .success([
            makeMember(id: "owner", role: .owner, joinedAt: 0),
            makeMember(id: "m1", role: .member, joinedAt: 10),
            makeMember(id: "m2", role: .member, joinedAt: 20),
        ])
        let log = EventLog()
        let viewModel = SoratomoMembersViewModel(
            groupId: "g1",
            groupService: service,
            logEvent: { log.events.append($0) }
        )

        // 引き下げの更新などで 2 回読んでも、記録は最初の 1 回だけ
        await viewModel.load()
        await viewModel.load()

        XCTAssertEqual(log.events, [.membersViewed(memberCount: 3)])
        XCTAssertEqual(service.fetchMembersCalls, ["g1", "g1"])
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - 失敗

    func testFailedLoadShowsFixedMessageAndDoesNotLog() async {
        let service = MockSoratomoGroupService()
        service.fetchMembersResult = .failure(.network)
        let log = EventLog()
        let viewModel = SoratomoMembersViewModel(
            groupId: "g1",
            groupService: service,
            logEvent: { log.events.append($0) }
        )

        await viewModel.load()

        XCTAssertTrue(log.events.isEmpty)
        XCTAssertEqual(viewModel.errorMessage, SoratomoError.network.userMessage)
        XCTAssertTrue(viewModel.memberUids.isEmpty)
    }

    func testRetryAfterFailureLogsMembersViewedOnSuccess() async {
        // 失敗の後に読み直して読めたら、そのときに 1 回記録する
        let service = MockSoratomoGroupService()
        service.fetchMembersResult = .failure(.notMember)
        let log = EventLog()
        let viewModel = SoratomoMembersViewModel(
            groupId: "g1",
            groupService: service,
            logEvent: { log.events.append($0) }
        )

        await viewModel.load()
        XCTAssertEqual(viewModel.errorMessage, SoratomoError.notMember.userMessage)

        service.fetchMembersResult = .success([makeMember(id: "owner", role: .owner, joinedAt: 0)])
        await viewModel.load()

        XCTAssertEqual(log.events, [.membersViewed(memberCount: 1)])
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - 投稿詳細の画像の説明（要件 16.5）

    func testSkyDetailImageLabelUsesCaption() {
        XCTAssertEqual(
            SoratomoSkyDetailView.imageAccessibilityLabel(caption: "夕焼けがきれい", displayName: "そら"),
            "夕焼けがきれい"
        )
    }

    func testSkyDetailImageLabelFallsBackToDisplayNameWithoutCaption() {
        XCTAssertEqual(
            SoratomoSkyDetailView.imageAccessibilityLabel(caption: nil, displayName: "そら"),
            "そらさんの空"
        )
        XCTAssertEqual(
            SoratomoSkyDetailView.imageAccessibilityLabel(caption: "  ", displayName: "ユーザー"),
            "ユーザーさんの空"
        )
    }
}
