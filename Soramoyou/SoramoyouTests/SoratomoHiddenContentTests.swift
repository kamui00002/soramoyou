//
//  SoratomoHiddenContentTests.swift
//  SoramoyouTests
//
//  そらともの隠す集合（SoratomoHiddenContent・SoratomoBlockedAuthors・SoratomoReportedSkies）のテスト ⭐️
//  （release-gate 9.1）
//
//  端末の記録はテストごとの UserDefaults（suite）に書き、終わったら消す。通知もテストごとの NotificationCenter で送る。
//

@testable import Soramoyou
import XCTest

@MainActor
final class SoratomoHiddenContentTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "SoratomoHiddenContentTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    // MARK: - 部品

    private func makeSky(id: String = "sky-1", groupId: String = "group-1", authorId: String = "author-1") -> SoratomoSky {
        SoratomoSky(
            id: id,
            groupId: groupId,
            authorId: authorId,
            caption: nil,
            pixelWidth: 100,
            pixelHeight: 100,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func key(_ skyId: String, group: String = "group-1") -> SoratomoSkyKey {
        SoratomoSkyKey(groupId: group, skyId: skyId)
    }

    /// 読み込みの口（呼ばれたら止まり、テストが `continuation` で結果を返す）
    @MainActor
    private final class PendingFetch {
        var continuation: CheckedContinuation<Set<String>, Error>?
        func fetch(_: String) async throws -> Set<String> {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    // MARK: - 判定

    func testHidesBlockedAuthorAndReportedSkyOnly() {
        let content = SoratomoHiddenContent(blockedAuthorIds: ["blocked"], reportedSkies: [key("reported")])
        XCTAssertTrue(content.hides(makeSky(authorId: "blocked")))
        XCTAssertTrue(content.hides(makeSky(id: "reported")))
        XCTAssertFalse(content.hides(makeSky(id: "other", authorId: "other")))
        // 同じ投稿 ID でも、別のグループの投稿は隠さない
        XCTAssertFalse(content.hides(makeSky(id: "reported", groupId: "group-2")))
        XCTAssertFalse(SoratomoHiddenContent().hides(makeSky()))
    }

    // MARK: - 通報した投稿（端末の記録）

    func testReportedSkiesAreSeparatedPerUser() {
        // A が通報した投稿は、B では隠さない（アカウントを切り替えても漏らさない）
        let store = SoratomoReportedSkies(defaults: defaults)
        store.load(uid: "user-a")
        store.add(key("sky-a"), uid: "user-a")
        XCTAssertEqual(store.keys, [key("sky-a")])

        store.clear()
        store.load(uid: "user-b")
        XCTAssertEqual(store.keys, [], "A の通報が B に見えている")
        store.add(key("sky-b"), uid: "user-b")

        store.clear()
        store.load(uid: "user-a")
        XCTAssertEqual(store.keys, [key("sky-a")], "B の通報が A に見えている")
    }

    func testReportedSkiesSurviveRecreationAndSignOut() {
        // 再起動（作り直し）しても隠したまま。サインアウト（clear）はメモリだけで、端末の記録は残る
        let first = SoratomoReportedSkies(defaults: defaults)
        first.load(uid: "user-a")
        first.add(key("sky-1"), uid: "user-a")
        first.clear()
        XCTAssertEqual(first.keys, [])
        XCTAssertNil(first.currentUid)

        let second = SoratomoReportedSkies(defaults: defaults)
        second.load(uid: "user-a")
        XCTAssertEqual(second.keys, [key("sky-1")])
    }

    func testEraseRemovesOnlyThatUser() {
        let store = SoratomoReportedSkies(defaults: defaults)
        store.add(key("sky-a"), uid: "user-a")
        store.add(key("sky-b"), uid: "user-b")

        SoratomoReportedSkies.erase(uid: "user-a", defaults: defaults)

        store.load(uid: "user-a")
        XCTAssertEqual(store.keys, [])
        store.load(uid: "user-b")
        XCTAssertEqual(store.keys, [key("sky-b")])
    }

    func testAddForAnotherUserDoesNotChangeMemory() {
        // 読み込んでいる人と違う uid で足しても、いまの表示（メモリ）は変えない
        let store = SoratomoReportedSkies(defaults: defaults)
        store.load(uid: "user-a")
        store.add(key("sky-b"), uid: "user-b")
        XCTAssertEqual(store.keys, [])
    }

    func testReportedSkiesKeepNewestThousand() {
        XCTAssertEqual(SoratomoReportedSkies.maxCount, 1000)
        let store = SoratomoReportedSkies(defaults: defaults)
        store.load(uid: "user-a")
        for index in 0 ... SoratomoReportedSkies.maxCount {
            store.add(key("sky-\(index)"), uid: "user-a")
        }
        // 1,001 件目を足したら、いちばん古い 1 件だけを捨てる
        XCTAssertEqual(store.keys.count, 1000)
        XCTAssertFalse(store.keys.contains(key("sky-0")))
        XCTAssertTrue(store.keys.contains(key("sky-1")))
        XCTAssertTrue(store.keys.contains(key("sky-1000")))

        // 同じ投稿を足し直したら最新の扱いになり、次に捨てられるのは別の投稿
        store.add(key("sky-1"), uid: "user-a")
        store.add(key("sky-new"), uid: "user-a")
        XCTAssertTrue(store.keys.contains(key("sky-1")))
        XCTAssertFalse(store.keys.contains(key("sky-2")))

        let reloaded = SoratomoReportedSkies(defaults: defaults)
        reloaded.load(uid: "user-a")
        XCTAssertEqual(reloaded.keys, store.keys)
    }

    // MARK: - ブロックの一覧

    func testBlockedAuthorsLoadAddAndClear() async {
        let blocked = SoratomoBlockedAuthors(notificationCenter: NotificationCenter())
        let loaded = await blocked.load(uid: "me") { _ in ["a", "b"] }
        XCTAssertTrue(loaded)
        XCTAssertEqual(blocked.ids, ["a", "b"])

        blocked.add("c")
        XCTAssertEqual(blocked.ids, ["a", "b", "c"])

        // 読み直したら、サーバーの一覧で置き換える（ルートの画面で解除した相手は外れる）
        await blocked.load(uid: "me") { _ in ["a"] }
        XCTAssertEqual(blocked.ids, ["a"])

        blocked.clear()
        XCTAssertEqual(blocked.ids, [])
    }

    func testBlockedAuthorsKeepCurrentListWhenLoadFails() async {
        let blocked = SoratomoBlockedAuthors(notificationCenter: NotificationCenter())
        blocked.add("a")
        let loaded = await blocked.load(uid: "me") { _ in throw SoratomoError.network }
        XCTAssertFalse(loaded)
        XCTAssertEqual(blocked.ids, ["a"])
    }

    func testBlockedAuthorsAddedDuringLoadSurviveTheResult() async throws {
        let blocked = SoratomoBlockedAuthors(notificationCenter: NotificationCenter())
        let pending = PendingFetch()
        let task = Task { await blocked.load(uid: "me", using: pending.fetch) }
        while pending.continuation == nil {
            await Task.yield()
        }
        // 読み込み中にそらともでブロックした相手は、結果で消さない
        blocked.add("new")
        pending.continuation?.resume(returning: ["old"])
        let loaded = await task.value
        XCTAssertTrue(loaded)
        XCTAssertEqual(blocked.ids, ["old", "new"])
    }

    func testBlockedAuthorsDiscardLoadThatFinishesAfterClear() async throws {
        // サインアウトの前に始めた読み込みが、後で前の人の一覧を戻さない
        let blocked = SoratomoBlockedAuthors(notificationCenter: NotificationCenter())
        let pending = PendingFetch()
        let task = Task { await blocked.load(uid: "user-a", using: pending.fetch) }
        while pending.continuation == nil {
            await Task.yield()
        }
        blocked.clear()
        pending.continuation?.resume(returning: ["a-blocked"])
        let loaded = await task.value
        XCTAssertFalse(loaded)
        XCTAssertEqual(blocked.ids, [])
    }

    func testBlockedAuthorsFollowUserBlockedNotification() async {
        // 既存のブロックの通知（ルートの投稿詳細・そらとものブロック）でも足す
        let center = NotificationCenter()
        let blocked = SoratomoBlockedAuthors(notificationCenter: center)
        center.post(name: .userBlocked, object: nil, userInfo: [Notification.blockedUserIdKey: "from-root"])
        center.post(name: .userBlocked, object: nil, userInfo: [Notification.blockedUserIdKey: ""])
        center.post(name: .userBlocked, object: nil, userInfo: nil)
        // 購読は main の queue で受けて MainActor の Task で足すので、一巡させてから確かめる
        for _ in 0 ..< 20 where !blocked.ids.contains("from-root") {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(blocked.ids, ["from-root"])
    }
}
