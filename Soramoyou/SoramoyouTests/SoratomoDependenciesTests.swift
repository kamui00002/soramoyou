//
//  SoratomoDependenciesTests.swift
//  SoramoyouTests
//
//  そらともの組み立て口（SoratomoDependencies）のサインアウトの後片付けのテスト ⭐️（release-gate 9.6）
//  - サインアウトで、ブロックの一覧と通報の記録のメモリが空になる（別のアカウントに前の人の隠す集合が残らない）
//  - 端末の通報の記録は残る（同じ人が入り直したときに隠したままにする）
//  - 投稿の覚え（SoratomoSkyLookup）は、抜けたグループの分だけを忘れる（leave-group 7.3）
//  - 抜けたグループの判定（`isLeftGroup`）は、いまの利用者が記録したグループだけを真にする（未ログインは偽・leave-group 8.3・要件 5.7）
//
//  ⚠️ Firebase には接続しない。サービスはすべてモック、通報の記録の置き場はテスト用の UserDefaults。
//

@testable import Soramoyou
import XCTest

// MARK: - 代役

/// 通知の事前説明の判定の代役（このテストでは呼ばれない）
@MainActor
private final class DependenciesPrimerStub: SoratomoNotificationPrimerProtocol {
    func decide() async -> SoratomoPrimerDecision {
        .none
    }

    func handle(choice _: SoratomoPrimerChoice) async -> Bool {
        false
    }

    func markSettingsGuideShown() {}
}

/// 公開プロフィールの取得の代役（このテストでは呼ばれない）
private struct DependenciesProfileFetcherStub: SoratomoProfileFetcher {
    func fetchPublicProfile(userId _: String) async throws -> PublicProfile {
        throw NSError(domain: "DependenciesProfileFetcherStub", code: -1)
    }
}

@MainActor
final class SoratomoDependenciesTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!
    private var dependencies: SoratomoDependencies!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "SoratomoDependenciesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        dependencies = SoratomoDependencies(
            groupService: MockSoratomoGroupService(),
            skyService: MockSoratomoSkyService(),
            imageStore: MockSoratomoImageStore(),
            profileService: MockSoratomoProfileService(),
            profileStore: SoratomoProfileStore(fetcher: DependenciesProfileFetcherStub()),
            primer: DependenciesPrimerStub(),
            network: .shared,
            skyLookup: SoratomoSkyLookup(),
            moderationService: MockSoratomoModerationService(),
            guidelineService: MockSoratomoGuidelineService(),
            blockedAuthors: SoratomoBlockedAuthors(notificationCenter: NotificationCenter()),
            reportedSkies: SoratomoReportedSkies(defaults: defaults),
            leaveService: MockSoratomoLeaveService(),
            leftGroups: SoratomoLeftGroups(defaults: defaults),
            currentUid: { nil }
        )
    }

    /// 利用者を切り替えられる組み立て口を作る（`isLeftGroup` のテスト用。記録の置き場は同じテスト用の UserDefaults）
    private func makeDependencies(uid: @escaping () -> String?) -> SoratomoDependencies {
        SoratomoDependencies(
            groupService: MockSoratomoGroupService(),
            skyService: MockSoratomoSkyService(),
            imageStore: MockSoratomoImageStore(),
            profileService: MockSoratomoProfileService(),
            profileStore: SoratomoProfileStore(fetcher: DependenciesProfileFetcherStub()),
            primer: DependenciesPrimerStub(),
            network: .shared,
            skyLookup: SoratomoSkyLookup(),
            moderationService: MockSoratomoModerationService(),
            guidelineService: MockSoratomoGuidelineService(),
            blockedAuthors: SoratomoBlockedAuthors(notificationCenter: NotificationCenter()),
            reportedSkies: SoratomoReportedSkies(defaults: defaults),
            leaveService: MockSoratomoLeaveService(),
            leftGroups: SoratomoLeftGroups(defaults: defaults),
            currentUid: uid
        )
    }

    override func tearDown() {
        dependencies = nil
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        super.tearDown()
    }

    /// ⭐️ サインアウトの後に別のアカウントで入っても、前のアカウントの隠す集合が残らない
    ///
    /// 次の人のブロックの一覧が読めなかったとき（圏外など）、ブロックの一覧は今の一覧のままになる。
    /// サインアウトで空にしていなければ、前の人がブロックした相手が、次の人の画面でも隠れる。
    func testSignOutClearsHiddenSetsSoTheNextAccountDoesNotInheritThem() async {
        let key = SoratomoSkyKey(groupId: "g1", skyId: "s1")

        // アカウント A: ブロックと通報をした状態
        let loadedA = await dependencies.blockedAuthors.load(uid: "userA") { _ in ["blockedByA"] }
        XCTAssertTrue(loadedA)
        dependencies.reportedSkies.load(uid: "userA")
        dependencies.reportedSkies.add(key, uid: "userA")
        XCTAssertEqual(dependencies.blockedAuthors.ids, ["blockedByA"])
        XCTAssertEqual(dependencies.reportedSkies.keys, [key])

        // サインアウト
        dependencies.clearSessionState()

        XCTAssertTrue(dependencies.blockedAuthors.ids.isEmpty, "ブロックの一覧のメモリを空にする")
        XCTAssertTrue(dependencies.reportedSkies.keys.isEmpty, "通報の記録のメモリを空にする")
        XCTAssertNil(dependencies.reportedSkies.currentUid)

        // アカウント B: ブロックの一覧が読めなかった（圏外など）
        let loadedB = await dependencies.blockedAuthors.load(uid: "userB") { _ in
            throw SoratomoError.network
        }
        dependencies.reportedSkies.load(uid: "userB")

        XCTAssertFalse(loadedB)
        XCTAssertTrue(dependencies.blockedAuthors.ids.isEmpty, "B の画面で A がブロックした相手を隠さない")
        XCTAssertTrue(dependencies.reportedSkies.keys.isEmpty, "B の画面で A が通報した投稿を隠さない")
    }

    /// サインアウトしても、端末の通報の記録は残る（同じ人が入り直したら隠したまま・決定事項 6）
    func testSignOutKeepsReportedSkiesOnDeviceForTheSameAccount() {
        let key = SoratomoSkyKey(groupId: "g1", skyId: "s1")
        dependencies.reportedSkies.load(uid: "userA")
        dependencies.reportedSkies.add(key, uid: "userA")

        dependencies.clearSessionState()
        dependencies.reportedSkies.load(uid: "userA")

        XCTAssertEqual(dependencies.reportedSkies.keys, [key])
    }

    // MARK: - 投稿の覚え（SoratomoSkyLookup）

    /// グループを抜けたら、そのグループの投稿だけを忘れる（ほかのグループの覚えは残す・leave-group 7.3）
    func testSkyLookupForgetGroupKeepsOtherGroups() {
        let lookup = SoratomoSkyLookup()
        lookup.remember([
            makeSky(id: "s1", groupId: "g1"),
            makeSky(id: "s2", groupId: "g1"),
            makeSky(id: "s1", groupId: "g2"),
        ])

        lookup.forget(groupId: "g1")

        XCTAssertNil(lookup.sky(groupId: "g1", skyId: "s1"))
        XCTAssertNil(lookup.sky(groupId: "g1", skyId: "s2"))
        XCTAssertNotNil(lookup.sky(groupId: "g2", skyId: "s1"), "抜けていないグループの投稿まで忘れた")
    }

    // MARK: - 抜けたグループの判定（leave-group 8.3）

    /// 記録にあるグループは、記録した利用者でログインしているときだけ真
    func testIsLeftGroupIsTrueForRecordedGroupOfCurrentUser() {
        SoratomoLeftGroups(defaults: defaults).insert("g1", uid: "userA")
        let deps = makeDependencies(uid: { "userA" })

        XCTAssertTrue(deps.isLeftGroup("g1"))
        XCTAssertFalse(deps.isLeftGroup("g2"), "記録に無いグループは偽")
    }

    /// 別の利用者が抜けたグループは、いまの利用者には偽（記録は利用者ごと）
    func testIsLeftGroupIsFalseForGroupLeftByAnotherUser() {
        SoratomoLeftGroups(defaults: defaults).insert("g1", uid: "userA")
        let deps = makeDependencies(uid: { "userB" })

        XCTAssertFalse(deps.isLeftGroup("g1"))
    }

    /// 未ログインなら、記録があっても偽
    func testIsLeftGroupIsFalseWhenSignedOut() {
        SoratomoLeftGroups(defaults: defaults).insert("g1", uid: "userA")
        let deps = makeDependencies(uid: { nil })

        XCTAssertFalse(deps.isLeftGroup("g1"))
    }

    private func makeSky(id: String, groupId: String) -> SoratomoSky {
        SoratomoSky(
            id: id,
            groupId: groupId,
            authorId: "author-1",
            caption: nil,
            pixelWidth: 100,
            pixelHeight: 100,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
