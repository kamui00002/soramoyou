//
//  SoratomoDependenciesTests.swift
//  SoramoyouTests
//
//  そらともの組み立て口（SoratomoDependencies）のサインアウトの後片付けのテスト ⭐️（release-gate 9.6）
//  - サインアウトで、ブロックの一覧と通報の記録のメモリが空になる（別のアカウントに前の人の隠す集合が残らない）
//  - 端末の通報の記録は残る（同じ人が入り直したときに隠したままにする）
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
            currentUid: { nil }
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
}
