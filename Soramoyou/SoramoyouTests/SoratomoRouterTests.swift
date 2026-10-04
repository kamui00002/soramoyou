//
//  SoratomoRouterTests.swift
//  SoramoyouTests
//
//  そらともへの遷移を決めるルーター（SoratomoRouter）のテスト ⭐️（tasks 12.1）
//
//  確かめること:
//  - 通知のデータの読み取り（そらともの通知だけを読み、既存の通知・ゴールデンアワーは無視する）
//  - 4 つの結果（opened・not_member・flag_off・signed_out）の分岐と、記録が 1 回だけなこと
//  - 保留の行き先が、表示できるまで（canPresent == false の間）残ること
//  - 通知のタイムラインを開いた時点では記録せず（結果待ち）、読めた・読めなかった・閉じた・開き直した・
//    次の通知で置き換えた、のどれかで結果が決まって 1 回だけ記録すること（1 回のタップで 2 件にならない）
//

@testable import Soramoyou
import XCTest

@MainActor
final class SoratomoRouterTests: XCTestCase {
    // MARK: - 道具

    /// ルーターが記録したイベントを集める入れ物
    private final class EventLog {
        var events: [SoratomoEvent] = []
    }

    private var eventLog: EventLog!
    private var router: SoratomoRouter!

    override func setUp() async throws {
        let log = EventLog()
        eventLog = log
        router = SoratomoRouter(logEvent: { log.events.append($0) })
    }

    /// そらともの新着通知の `userInfo`（送信側 functions/soratomo.js の data と同じ形）
    private func soratomoUserInfo(groupId: String = "group-1", postId: String = "sky-1") -> [AnyHashable: Any] {
        ["type": "soratomoPost", "groupId": groupId, "postId": postId]
    }

    /// 既存の通知の `userInfo`（functions/index.js の data の形。type と各通知のキーだけ）
    private var existingNotificationUserInfos: [(name: String, userInfo: [AnyHashable: Any])] {
        // 型の推論を軽くするため、1 件ずつ別の文で足す
        var list: [(name: String, userInfo: [AnyHashable: Any])] = []
        list.append((name: "like", userInfo: ["type": "like", "postId": "post-1"]))
        list.append((name: "comment", userInfo: ["type": "comment", "postId": "post-1"]))
        list.append((name: "newPost", userInfo: ["type": "newPost", "postId": "post-1"]))
        list.append((name: "follow", userInfo: ["type": "follow", "followerId": "user-1"]))
        list.append((name: "recommend", userInfo: ["type": "recommend", "postId": "post-1"]))
        // groupId と postId が揃っていても、type が違えばそらともの通知ではない
        list.append((name: "newPost + groupId", userInfo: ["type": "newPost", "groupId": "group-1", "postId": "post-1"]))
        // 実機の remote 通知には aps などのキーも付く
        let apsOnly: [AnyHashable: Any] = ["aps": ["alert": "まもなくゴールデンアワー", "sound": "default"]]
        let likeWithAps: [AnyHashable: Any] = ["aps": ["alert": "いいね"], "gcm.message_id": "id-1", "type": "like", "postId": "post-1"]
        list.append((name: "like + aps", userInfo: likeWithAps))
        // ゴールデンアワーはローカル通知で、userInfo を持たない（空）
        let empty: [AnyHashable: Any] = [:]
        list.append((name: "goldenHour (empty)", userInfo: empty))
        list.append((name: "goldenHour (aps only)", userInfo: apsOnly))
        return list
    }

    /// 通知を受け取り、表示できる状況で開く（開いた後の検証の前置き）
    private func receiveAndPresent(groupId: String = "group-1") {
        router.receive(userInfo: soratomoUserInfo(groupId: groupId))
        router.resolvePending(session: .signedIn, gate: .enabled, canPresent: true)
    }

    // MARK: - SoratomoNotificationPayload.parse

    /// そらともの通知は、type・groupId・postId を読める（ほかのキーが付いていても読める）
    func testParse_readsSoratomoPayload() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": "新しい空"],
            "gcm.message_id": "id-1",
            "type": "soratomoPost",
            "groupId": "group-1",
            "postId": "sky-1",
        ]

        let payload = SoratomoNotificationPayload.parse(userInfo)

        XCTAssertEqual(payload, SoratomoNotificationPayload(groupId: "group-1", postId: "sky-1"))
    }

    /// 既存の通知とゴールデンアワーは読まない
    func testParse_ignoresExistingNotificationsAndGoldenHour() {
        for (name, userInfo) in existingNotificationUserInfos {
            XCTAssertNil(SoratomoNotificationPayload.parse(userInfo), "\(name) はそらともの通知として読まれてはいけない")
        }
    }

    /// type・groupId・postId のどれかが欠けていれば読まない
    func testParse_returnsNilWhenAnyKeyIsMissing() {
        XCTAssertNil(SoratomoNotificationPayload.parse(["groupId": "group-1", "postId": "sky-1"]), "type 無し")
        XCTAssertNil(SoratomoNotificationPayload.parse(["type": "soratomoPost", "postId": "sky-1"]), "groupId 無し")
        XCTAssertNil(SoratomoNotificationPayload.parse(["type": "soratomoPost", "groupId": "group-1"]), "postId 無し")
    }

    /// type の値が違う（大文字小文字・文字列でない値を含む）なら読まない
    func testParse_returnsNilWhenTypeDoesNotMatch() {
        XCTAssertNil(SoratomoNotificationPayload.parse(["type": "SoratomoPost", "groupId": "g", "postId": "s"]))
        XCTAssertNil(SoratomoNotificationPayload.parse(["type": "soratomo", "groupId": "g", "postId": "s"]))
        XCTAssertNil(SoratomoNotificationPayload.parse(["type": 1, "groupId": "g", "postId": "s"]))
    }

    /// groupId・postId が空・文字列でない・`/` を含むなら読まない
    func testParse_returnsNilWhenIdIsNotUsable() {
        XCTAssertNil(SoratomoNotificationPayload.parse(["type": "soratomoPost", "groupId": "", "postId": "s"]), "groupId が空")
        XCTAssertNil(SoratomoNotificationPayload.parse(["type": "soratomoPost", "groupId": "g", "postId": ""]), "postId が空")
        XCTAssertNil(SoratomoNotificationPayload.parse(["type": "soratomoPost", "groupId": 1, "postId": "s"]), "groupId が数値")
        XCTAssertNil(SoratomoNotificationPayload.parse(["type": "soratomoPost", "groupId": "g", "postId": 2]), "postId が数値")
        XCTAssertNil(SoratomoNotificationPayload.parse(["type": "soratomoPost", "groupId": "a/b", "postId": "s"]), "groupId に /")
        XCTAssertNil(SoratomoNotificationPayload.parse(["type": "soratomoPost", "groupId": "g", "postId": "a/b"]), "postId に /")
    }

    // MARK: - receive

    /// そらともの通知を受け取ると保留になる。この時点では表示も記録もしない
    func testReceive_holdsSoratomoPayloadAsPending() {
        router.receive(userInfo: soratomoUserInfo())

        XCTAssertEqual(router.pending, SoratomoNotificationPayload(groupId: "group-1", postId: "sky-1"))
        XCTAssertFalse(router.isPresented)
        XCTAssertEqual(router.path, [])
        XCTAssertEqual(eventLog.events, [])
    }

    /// 既存の通知とゴールデンアワーは、保留にも表示にも記録にもならない
    func testReceive_ignoresExistingNotificationsAndGoldenHour() {
        for (name, userInfo) in existingNotificationUserInfos {
            router.receive(userInfo: userInfo)

            XCTAssertNil(router.pending, "\(name) で保留ができてはいけない")
        }
        // 保留が無いので、状況が揃っても何も起きない
        router.resolvePending(session: .signedIn, gate: .enabled, canPresent: true)
        XCTAssertFalse(router.isPresented)
        XCTAssertEqual(router.path, [])
        XCTAssertEqual(eventLog.events, [])
    }

    /// 既存の通知を受け取っても、すでにある保留は消えない
    func testReceive_existingNotificationKeepsPendingAsIs() {
        router.receive(userInfo: soratomoUserInfo())

        router.receive(userInfo: ["type": "like", "postId": "post-1"])
        router.receive(userInfo: [:])

        XCTAssertEqual(router.pending, SoratomoNotificationPayload(groupId: "group-1", postId: "sky-1"))
    }

    /// 保留があるときに新しいそらともの通知を受け取ると、新しい行き先に置き換わる
    func testReceive_newerTapReplacesPending() {
        router.receive(userInfo: soratomoUserInfo(groupId: "group-1", postId: "sky-1"))
        router.receive(userInfo: soratomoUserInfo(groupId: "group-2", postId: "sky-2"))

        XCTAssertEqual(router.pending, SoratomoNotificationPayload(groupId: "group-2", postId: "sky-2"))
    }

    // MARK: - resolvePending: 保留が無いとき

    /// 保留が無いときは何もしない（記録もしない）
    func testResolvePending_doesNothingWithoutPending() {
        router.resolvePending(session: .signedIn, gate: .enabled, canPresent: true)
        router.resolvePending(session: .signedOut, gate: .disabled(.signedOut), canPresent: true)

        XCTAssertFalse(router.isPresented)
        XCTAssertEqual(router.path, [])
        XCTAssertEqual(eventLog.events, [])
    }

    // MARK: - resolvePending: signed_out

    /// 未ログインなら、破棄して signed_out を記録する。そらともの画面は出さない
    func testResolvePending_signedOutDiscardsAndLogsSignedOut() {
        router.receive(userInfo: soratomoUserInfo())

        router.resolvePending(session: .signedOut, gate: .enabled, canPresent: true)

        XCTAssertNil(router.pending)
        XCTAssertFalse(router.isPresented)
        XCTAssertEqual(router.path, [])
        XCTAssertEqual(eventLog.events, [.notificationOpened(.signedOut)])
    }

    /// 未ログインのとき、フラグは「無効（未ログイン）」や「未判定」になる。それでも結果は signed_out
    func testResolvePending_signedOutWinsOverGateState() {
        let gates: [SoratomoFeatureGate.State] = [.disabled(.signedOut), .unknown]
        for gate in gates {
            eventLog.events.removeAll()
            router.receive(userInfo: soratomoUserInfo())

            router.resolvePending(session: .signedOut, gate: gate, canPresent: true)

            XCTAssertNil(router.pending, "\(gate)")
            XCTAssertEqual(eventLog.events, [.notificationOpened(.signedOut)], "\(gate)")
        }
    }

    /// 未ログインの破棄は、ほかの全画面が出ている間（canPresent == false）でも待たずに行う
    func testResolvePending_signedOutDiscardsEvenWhenCannotPresent() {
        router.receive(userInfo: soratomoUserInfo())

        router.resolvePending(session: .signedOut, gate: .enabled, canPresent: false)

        XCTAssertNil(router.pending)
        XCTAssertEqual(eventLog.events, [.notificationOpened(.signedOut)])
    }

    // MARK: - resolvePending: flag_off

    /// フラグが無効なら、理由に関わらず、破棄して flag_off を記録する。そらともの画面は出さない
    func testResolvePending_disabledGateDiscardsAndLogsFlagOff() {
        let reasons: [SoratomoFeatureGate.DisabledReason] = [.signedOut, .anonymous, .claimMissing, .tokenUnavailable]
        for reason in reasons {
            eventLog.events.removeAll()
            router.receive(userInfo: soratomoUserInfo())

            router.resolvePending(session: .signedIn, gate: .disabled(reason), canPresent: true)

            XCTAssertNil(router.pending, "\(reason)")
            XCTAssertFalse(router.isPresented, "\(reason)")
            XCTAssertEqual(router.path, [], "\(reason)")
            XCTAssertEqual(eventLog.events, [.notificationOpened(.flagOff)], "\(reason)")
        }
    }

    /// フラグが無効なら、ほかの全画面が出ている間（canPresent == false）でも待たずに破棄する
    func testResolvePending_disabledGateDiscardsEvenWhenCannotPresent() {
        router.receive(userInfo: soratomoUserInfo())

        router.resolvePending(session: .signedIn, gate: .disabled(.claimMissing), canPresent: false)

        XCTAssertNil(router.pending)
        XCTAssertEqual(eventLog.events, [.notificationOpened(.flagOff)])
    }

    /// フラグがまだ判定されていない間は、flag_off を記録せず保留のまま待つ。判定が済んだら続きを行う
    func testResolvePending_unknownGateKeepsPendingUntilDecided() {
        router.receive(userInfo: soratomoUserInfo())

        router.resolvePending(session: .signedIn, gate: .unknown, canPresent: true)

        XCTAssertEqual(router.pending, SoratomoNotificationPayload(groupId: "group-1", postId: "sky-1"))
        XCTAssertFalse(router.isPresented)
        XCTAssertEqual(eventLog.events, [])

        router.resolvePending(session: .signedIn, gate: .enabled, canPresent: true)

        XCTAssertNil(router.pending)
        XCTAssertTrue(router.isPresented)
        // 開いた時点では、まだ記録しない（結果待ち）
        XCTAssertEqual(eventLog.events, [])
    }

    // MARK: - resolvePending: 開く（この時点では記録しない）

    /// 表示できるときは、一覧の上にタイムラインを開く。この時点では記録しない（結果待ち）
    func testResolvePending_enabledOpensTimelineOverListWithoutLogging() {
        router.receive(userInfo: soratomoUserInfo(groupId: "group-7"))

        router.resolvePending(session: .signedIn, gate: .enabled, canPresent: true)

        XCTAssertNil(router.pending)
        XCTAssertTrue(router.isPresented)
        XCTAssertEqual(router.path, [.timeline(groupId: "group-7")])
        XCTAssertNil(router.notice)
        XCTAssertEqual(eventLog.events, [], "タイムラインが読めるか決まるまで、記録しない")
    }

    /// 表示できない間（canPresent == false）は保留のまま残り、記録もしない。表示できたら開く（開いた時点でも記録しない）
    func testResolvePending_keepsPendingWhileCannotPresentThenOpens() {
        router.receive(userInfo: soratomoUserInfo())

        // What's New など、ほかの全画面が出ている間は何度呼んでも待つ
        for _ in 0 ..< 3 {
            router.resolvePending(session: .signedIn, gate: .enabled, canPresent: false)

            XCTAssertEqual(router.pending, SoratomoNotificationPayload(groupId: "group-1", postId: "sky-1"))
            XCTAssertFalse(router.isPresented)
            XCTAssertEqual(router.path, [])
            XCTAssertEqual(eventLog.events, [])
        }

        // 閉じられて表示できるようになったら開く
        router.resolvePending(session: .signedIn, gate: .enabled, canPresent: true)

        XCTAssertNil(router.pending)
        XCTAssertTrue(router.isPresented)
        XCTAssertEqual(router.path, [.timeline(groupId: "group-1")])
        XCTAssertEqual(eventLog.events, [])
    }

    /// 破棄で結果が決まる signed_out と flag_off は、何度呼んでも記録が 1 件のまま
    func testResolvePending_discardedResultsAreLoggedOnlyOnce() {
        let cases: [(session: SoratomoSession, gate: SoratomoFeatureGate.State, expected: SoratomoNotificationOpenResult)] = [
            (.signedOut, .enabled, .signedOut),
            (.signedIn, .disabled(.claimMissing), .flagOff),
        ]
        for testCase in cases {
            eventLog.events.removeAll()
            router.receive(userInfo: soratomoUserInfo())

            for _ in 0 ..< 3 {
                router.resolvePending(session: testCase.session, gate: testCase.gate, canPresent: true)
            }

            XCTAssertEqual(eventLog.events, [.notificationOpened(testCase.expected)], "\(testCase.expected)")
        }
    }

    /// 開いた後に resolvePending を何度呼んでも、記録は増えない（保留が無いので何も起きない）
    func testResolvePending_repeatedCallsAfterOpeningDoNotLog() {
        router.receive(userInfo: soratomoUserInfo())

        for _ in 0 ..< 3 {
            router.resolvePending(session: .signedIn, gate: .enabled, canPresent: true)
        }

        XCTAssertEqual(router.path, [.timeline(groupId: "group-1")])
        XCTAssertEqual(eventLog.events, [])
    }

    /// そらともの画面をすでに開いているときは、通知のグループのタイムラインへ置き換える
    func testResolvePending_replacesPathWhenAlreadyPresented() {
        router.openFromEntry()
        router.path = [.members(groupId: "group-x")]
        router.receive(userInfo: soratomoUserInfo(groupId: "group-2"))

        router.resolvePending(session: .signedIn, gate: .enabled, canPresent: true)

        XCTAssertTrue(router.isPresented)
        XCTAssertEqual(router.path, [.timeline(groupId: "group-2")])
        XCTAssertEqual(eventLog.events, [], "入口から開いた画面の置き換えでは、通知の結果はまだ決まらない")
    }

    /// 結果が決まる前に次のそらともの通知で開き直したら、前の分を opened として 1 回記録してから置き換える
    func testResolvePending_nextTapSettlesPreviousAsOpenedThenReplaces() {
        receiveAndPresent(groupId: "group-1")
        router.receive(userInfo: soratomoUserInfo(groupId: "group-2", postId: "sky-2"))

        router.resolvePending(session: .signedIn, gate: .enabled, canPresent: true)

        XCTAssertEqual(router.path, [.timeline(groupId: "group-2")])
        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened)], "前の分だけ記録する")

        // 前のグループの知らせは、もう結果待ちではない（記録も画面の変更もしない）
        router.reportAccessible(groupId: "group-1")
        router.reportNotAccessible(groupId: "group-1")
        XCTAssertEqual(router.path, [.timeline(groupId: "group-2")])
        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened)])

        // 新しい分は、新しい結果待ち
        router.reportAccessible(groupId: "group-2")
        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened), .notificationOpened(.opened)])
    }

    /// 同じグループの通知を続けて開いても、タップごとに結果は 1 件ずつ
    func testResolvePending_nextTapForSameGroupIsCountedPerTap() {
        receiveAndPresent(groupId: "group-1")
        receiveAndPresent(groupId: "group-1")
        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened)], "1 回目のタップの分")

        router.reportNotAccessible(groupId: "group-1")

        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened), .notificationOpened(.notMember)], "2 回目のタップの分")
    }

    // MARK: - reportAccessible: opened

    /// タイムラインがグループを読めたら、opened を 1 回だけ記録する。画面は変えない
    func testReportAccessible_logsOpenedOnceForTheAwaitedGroup() {
        receiveAndPresent(groupId: "group-1")
        XCTAssertEqual(eventLog.events, [])

        router.reportAccessible(groupId: "group-1")
        router.reportAccessible(groupId: "group-1")

        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened)])
        XCTAssertTrue(router.isPresented)
        XCTAssertEqual(router.path, [.timeline(groupId: "group-1")])
        XCTAssertNil(router.notice)
    }

    /// 結果待ちと別のグループの知らせでは記録せず、結果待ちも消さない
    func testReportAccessible_otherGroupDoesNothingAndKeepsWaiting() {
        receiveAndPresent(groupId: "group-1")

        router.reportAccessible(groupId: "group-2")

        XCTAssertEqual(eventLog.events, [])

        router.reportAccessible(groupId: "group-1")

        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened)])
    }

    /// 入口から開いたグループが読めたときは、通知の結果を記録しない
    func testReportAccessible_fromEntryDoesNotLogNotificationResult() {
        router.openFromEntry()
        router.path = [.timeline(groupId: "group-1")]

        router.reportAccessible(groupId: "group-1")

        XCTAssertEqual(eventLog.events, [])
    }

    // MARK: - reportNotAccessible: not_member

    /// タイムラインが読めなかったら、一覧へ戻して一時表示を出し、not_member だけを記録する（opened は記録しない）
    func testReportNotAccessible_returnsToListShowsNoticeAndLogsOnlyNotMember() {
        receiveAndPresent(groupId: "group-1")

        router.reportNotAccessible(groupId: "group-1")

        XCTAssertEqual(router.path, [])
        XCTAssertTrue(router.isPresented, "画面は閉じず、一覧を見せる")
        XCTAssertEqual(router.notice, "グループを開けませんでした")
        XCTAssertEqual(router.notice, SoratomoError.notMember.userMessage)
        XCTAssertEqual(eventLog.events, [.notificationOpened(.notMember)])
    }

    /// not_member の記録は 1 回だけ。同じグループのタイムラインから、もう一度知らされても増えない
    func testReportNotAccessible_logsNotMemberOnlyOnce() {
        receiveAndPresent(groupId: "group-1")
        router.reportNotAccessible(groupId: "group-1")

        // 一覧から同じグループを開き直して、また読めなかった（通知のタップの結果ではない）
        router.path = [.timeline(groupId: "group-1")]
        router.reportNotAccessible(groupId: "group-1")

        XCTAssertEqual(router.path, [])
        XCTAssertEqual(eventLog.events, [.notificationOpened(.notMember)])
    }

    /// 入口から開いたグループが読めなかったときは、一覧へ戻して一時表示は出すが、通知の結果は記録しない
    func testReportNotAccessible_fromEntryDoesNotLogNotificationResult() {
        router.openFromEntry()
        router.path = [.timeline(groupId: "group-1")]

        router.reportNotAccessible(groupId: "group-1")

        XCTAssertEqual(router.path, [])
        XCTAssertEqual(router.notice, SoratomoError.notMember.userMessage)
        XCTAssertEqual(eventLog.events, [])
    }

    /// 通知のグループと別のグループの知らせは、通知の結果にならない（結果待ちも消さない）
    func testReportNotAccessible_otherGroupDoesNotLogNotificationResult() {
        receiveAndPresent(groupId: "group-1")
        router.path = [.timeline(groupId: "group-1"), .timeline(groupId: "group-2")]

        router.reportNotAccessible(groupId: "group-2")

        XCTAssertEqual(eventLog.events, [])

        router.reportAccessible(groupId: "group-1")

        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened)], "通知のグループの結果待ちは残っていた")
    }

    /// パスにそのグループのタイムラインが無いとき（すでに離れた後の知らせ）は、画面を変えない。
    /// 結果待ちと一致していれば、グループを読めないという結果は決まっているので、not_member は記録する
    func testReportNotAccessible_leavesScreenAloneButLogsWhenTimelineIsNotOnPath() {
        receiveAndPresent(groupId: "group-1")
        router.path = []

        router.reportNotAccessible(groupId: "group-1")

        XCTAssertNil(router.notice)
        XCTAssertEqual(router.path, [])
        XCTAssertEqual(eventLog.events, [.notificationOpened(.notMember)])
    }

    // MARK: - 閉じる・入口から開く・サインアウト（結果待ちの扱い）

    /// 入口から開くと、一覧を開く。前の一時表示とパスは消え、記録はしない
    func testOpenFromEntry_opensListAndClearsNoticeAndPath() {
        router.path = [.timeline(groupId: "group-1")]
        router.notice = "前の一時表示"

        router.openFromEntry()

        XCTAssertTrue(router.isPresented)
        XCTAssertEqual(router.path, [])
        XCTAssertNil(router.notice)
        XCTAssertEqual(eventLog.events, [])
    }

    /// 通知のタイムラインの結果が決まる前に入口から開き直したら、opened を 1 回記録する
    func testOpenFromEntry_beforeResultLogsOpenedOnce() {
        receiveAndPresent(groupId: "group-1")

        router.openFromEntry()

        XCTAssertEqual(router.path, [])
        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened)])

        // 開き直した一覧から同じグループを開いて読めなかったとしても、通知の結果は増えない
        router.path = [.timeline(groupId: "group-1")]
        router.reportNotAccessible(groupId: "group-1")
        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened)])
    }

    /// 閉じると、画面・パス・一時表示を片づける。保留の行き先は消さない
    func testDismiss_closesAndClearsButKeepsPending() {
        receiveAndPresent()
        router.receive(userInfo: soratomoUserInfo(groupId: "group-2", postId: "sky-2"))
        router.notice = "一時表示"

        router.dismiss()

        XCTAssertFalse(router.isPresented)
        XCTAssertEqual(router.path, [])
        XCTAssertNil(router.notice)
        XCTAssertEqual(router.pending, SoratomoNotificationPayload(groupId: "group-2", postId: "sky-2"))
    }

    /// 結果が決まる前に閉じたら、opened を 1 回だけ記録する。その後に遅れて知らせが来ても増えない
    func testDismiss_beforeResultLogsOpenedOnce() {
        receiveAndPresent(groupId: "group-1")
        XCTAssertEqual(eventLog.events, [])

        router.dismiss()
        router.dismiss()

        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened)])

        router.path = [.timeline(groupId: "group-1")]
        router.reportNotAccessible(groupId: "group-1")
        router.reportAccessible(groupId: "group-1")

        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened)])
    }

    /// カバーの閉じる操作が isPresented を直接 false にした場合も、dismiss と同じく opened を 1 回記録する
    func testDismiss_closingByBindingLogsOpenedOnce() {
        receiveAndPresent(groupId: "group-1")

        router.isPresented = false

        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened)])

        router.dismiss()

        XCTAssertEqual(eventLog.events, [.notificationOpened(.opened)])
    }

    /// 通知から開いていない画面を閉じても、何も記録しない
    func testDismiss_withoutNotificationLogsNothing() {
        router.openFromEntry()

        router.dismiss()

        XCTAssertEqual(eventLog.events, [])
    }

    /// サインアウトすると、保留・結果待ち・画面・パス・一時表示をすべて破棄する。結果待ちは記録せずに消す
    func testClearOnSignOut_discardsEverythingWithoutLogging() {
        receiveAndPresent()
        router.notice = "一時表示"
        router.receive(userInfo: soratomoUserInfo(groupId: "group-2", postId: "sky-2"))

        router.clearOnSignOut()

        XCTAssertNil(router.pending)
        XCTAssertFalse(router.isPresented)
        XCTAssertEqual(router.path, [])
        XCTAssertNil(router.notice)
        XCTAssertEqual(eventLog.events, [], "サインアウトの破棄では、結果待ちを記録しない")

        // 破棄した行き先は開かれない
        router.resolvePending(session: .signedIn, gate: .enabled, canPresent: true)
        XCTAssertFalse(router.isPresented)

        // 結果待ちも消えているので、遅れて来る知らせや閉じる操作でも記録されない
        router.path = [.timeline(groupId: "group-1")]
        router.reportAccessible(groupId: "group-1")
        router.reportNotAccessible(groupId: "group-1")
        router.dismiss()
        XCTAssertEqual(eventLog.events, [])
    }

    // MARK: - 1 回のタップで、記録がちょうど 1 件

    /// 結果が決まる道（結果待ちを終わらせる操作）
    private enum Ending: CaseIterable {
        case reportAccessible
        case reportNotAccessible
        case dismiss
        /// カバーの閉じる操作が isPresented を直接 false にする
        case closeByBinding
        case openFromEntry

        /// 最初にその道で結果が決まったときに記録される結果
        var expectedResult: SoratomoNotificationOpenResult {
            self == .reportNotAccessible ? .notMember : .opened
        }
    }

    /// 結果が決まる道を 1 つ実行する（通知のグループは group-1）
    private func perform(_ ending: Ending, on target: SoratomoRouter) {
        switch ending {
        case .reportAccessible: target.reportAccessible(groupId: "group-1")
        case .reportNotAccessible: target.reportNotAccessible(groupId: "group-1")
        case .dismiss: target.dismiss()
        case .closeByBinding: target.isPresented = false
        case .openFromEntry: target.openFromEntry()
        }
    }

    /// 通知を開いた後、どの道で結果が決まっても記録は 1 件。続けて別の道が来ても、2 件にならない
    func testOneTap_isLoggedExactlyOnceForEveryPairOfEndings() {
        for first in Ending.allCases {
            for second in Ending.allCases {
                let log = EventLog()
                let target = SoratomoRouter(logEvent: { log.events.append($0) })
                target.receive(userInfo: soratomoUserInfo(groupId: "group-1"))
                target.resolvePending(session: .signedIn, gate: .enabled, canPresent: true)

                perform(first, on: target)
                XCTAssertEqual(log.events, [.notificationOpened(first.expectedResult)], "\(first)")

                perform(second, on: target)
                XCTAssertEqual(log.events, [.notificationOpened(first.expectedResult)], "\(first) の後に \(second)")
            }
        }
    }

    /// 破棄で結果が決まったタップ（signed_out・flag_off）は、その後にどの操作があっても記録が増えない
    func testDiscardedTap_isNotLoggedAgainByAnyEnding() {
        let cases: [(session: SoratomoSession, gate: SoratomoFeatureGate.State, expected: SoratomoNotificationOpenResult)] = [
            (.signedOut, .enabled, .signedOut),
            (.signedIn, .disabled(.claimMissing), .flagOff),
        ]
        for testCase in cases {
            for ending in Ending.allCases {
                let log = EventLog()
                let target = SoratomoRouter(logEvent: { log.events.append($0) })
                target.receive(userInfo: soratomoUserInfo(groupId: "group-1"))
                target.resolvePending(session: testCase.session, gate: testCase.gate, canPresent: true)

                perform(ending, on: target)

                XCTAssertEqual(log.events, [.notificationOpened(testCase.expected)], "\(testCase.expected) の後に \(ending)")
            }
        }
    }

    // MARK: - shared

    /// アプリ全体で使う `shared` は、いつも同じオブジェクト
    func testShared_isSingleInstance() {
        XCTAssertTrue(SoratomoRouter.shared === SoratomoRouter.shared)
    }
}
