//
//  SoratomoProfileStoreTests.swift
//  SoramoyouTests
//
//  投稿者とメンバーの表示名・アイコン（SoratomoProfileStore）のテスト ⭐️（tasks 11.5）
//
//  公開プロフィールの取得は `SoratomoProfileFetcher` の差し替えで済ませる。確かめること:
//  - 取れた公開プロフィールが保持され、表示名とアイコンの URL が出ること
//  - 代替の規則（未取得・取得に失敗・未設定・空・空白だけは「ユーザー」。内部 ID から作った文字で代用しない）
//  - 取れなかった uid は保持せず、次の prefetch でもう一度取りに行くこと
//  - 持っている uid・取得中の uid・空の uid は取りに行かないこと
//  - clear() で保持が消えること。取得中に clear() が呼ばれたら、戻ってきた結果を捨てること
//

@testable import Soramoyou
import XCTest

@MainActor
final class SoratomoProfileStoreTests: XCTestCase {
    // MARK: - 補助

    /// 公開プロフィールの取得口の代役
    ///
    /// uid ごとに返すプロフィールか失敗を先に決める（どちらも決めていない uid は「プロフィールが無い」で失敗）。
    /// `holdFetches` を呼ぶと、最初の取得を `release()` が呼ばれるまで止められる（取得中の状態を作るため）。
    /// 取得は子タスクから並行して呼ばれるので、状態はロックの中でだけ触る。
    private final class SoratomoProfileFetcherStub: SoratomoProfileFetcher, @unchecked Sendable {
        private let lock = NSLock()
        private var profilesByUid: [String: PublicProfile] = [:]
        private var errorsByUid: [String: Error] = [:]
        private var calls: [String] = []
        private var holdsRemaining = 0
        private var isReleased = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func setProfile(_ profile: PublicProfile, for uid: String) {
            lock.lock()
            profilesByUid[uid] = profile
            lock.unlock()
        }

        func setError(_ error: Error?, for uid: String) {
            lock.lock()
            errorsByUid[uid] = error
            lock.unlock()
        }

        /// 最初の取得 1 回だけを、`release()` まで止める（2 回目以降は止めない。二重の取得でテストが固まらないように）
        func holdFetches() {
            lock.lock()
            holdsRemaining = 1
            lock.unlock()
        }

        /// 止めていた取得を再開する（以降は止めない）
        func release() {
            lock.lock()
            isReleased = true
            let pending = waiters
            waiters = []
            lock.unlock()
            for waiter in pending {
                waiter.resume()
            }
        }

        /// 取りに来た uid（呼ばれた順）
        var fetchedUids: [String] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        func fetchPublicProfile(userId: String) async throws -> PublicProfile {
            if recordCallAndShouldHold(userId) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    parkOrResume(continuation)
                }
            }
            let (profile, error) = lookup(userId)
            if let error {
                throw error
            }
            guard let profile else {
                throw FirestoreServiceError.notFound
            }
            return profile
        }

        // ロックは同期のメソッドの中でだけ使う（async の関数の中で NSLock を触ると警告になるため）

        private func recordCallAndShouldHold(_ uid: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            calls.append(uid)
            if holdsRemaining > 0, !isReleased {
                holdsRemaining -= 1
                return true
            }
            return false
        }

        private func parkOrResume(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if isReleased {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }

        private func lookup(_ uid: String) -> (PublicProfile?, Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (profilesByUid[uid], errorsByUid[uid])
        }
    }

    private var fetcher: SoratomoProfileFetcherStub!
    private var store: SoratomoProfileStore!

    override func setUp() async throws {
        fetcher = SoratomoProfileFetcherStub()
        store = SoratomoProfileStore(fetcher: fetcher)
    }

    /// 条件が満たされるまで待つ（上限つき。満たされなければ戻って、呼び出し側の assert で落とす）
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - 取得と表示

    func testPrefetchStoresProfilesAndShowsNameAndPhoto() async {
        fetcher.setProfile(
            PublicProfile(id: "u1", displayName: " そら ", photoURL: "https://example.com/a.jpg"),
            for: "u1"
        )
        fetcher.setProfile(PublicProfile(id: "u2", displayName: "くも", photoURL: nil), for: "u2")

        await store.prefetch(uids: ["u1", "u2"])

        XCTAssertEqual(Set(fetcher.fetchedUids), ["u1", "u2"])
        XCTAssertEqual(store.profiles.count, 2)
        // 前後の空白は除いて出す（既存の `RankingDisplayText.authorName` と同じ）
        XCTAssertEqual(store.displayName(for: "u1"), "そら")
        XCTAssertEqual(store.displayName(for: "u2"), "くも")
        XCTAssertEqual(store.photoURL(for: "u1"), URL(string: "https://example.com/a.jpg"))
        // 写真が未設定なら nil（呼び出し側がプレースホルダーのアイコンを出す）
        XCTAssertNil(store.photoURL(for: "u2"))
    }

    // MARK: - 代替の規則

    func testFallbackNameForUnknownAndBlankNamesIsUser() async {
        fetcher.setProfile(PublicProfile(id: "nil-name", displayName: nil), for: "nil-name")
        fetcher.setProfile(PublicProfile(id: "empty-name", displayName: ""), for: "empty-name")
        fetcher.setProfile(PublicProfile(id: "blank-name", displayName: "  \n "), for: "blank-name")

        // まだ取っていない uid も、同じ代替になる
        XCTAssertEqual(store.displayName(for: "not-loaded"), "ユーザー")

        await store.prefetch(uids: ["nil-name", "empty-name", "blank-name"])

        XCTAssertEqual(store.profiles.count, 3)
        XCTAssertEqual(store.displayName(for: "nil-name"), "ユーザー")
        XCTAssertEqual(store.displayName(for: "empty-name"), "ユーザー")
        XCTAssertEqual(store.displayName(for: "blank-name"), "ユーザー")
    }

    func testFallbackNeverUsesTextMadeFromUid() async {
        // 内部 ID から作った文字（頭文字・先頭の数文字・ID そのもの）で代用しない（要件 8.7）
        let uid = "abcd1234efgh"
        fetcher.setProfile(PublicProfile(id: uid, displayName: nil), for: uid)

        XCTAssertEqual(store.displayName(for: uid), "ユーザー")
        await store.prefetch(uids: [uid])

        let name = store.displayName(for: uid)
        XCTAssertEqual(name, "ユーザー")
        XCTAssertFalse(name.contains("abcd"))
        XCTAssertFalse(name.contains("A"))
    }

    func testPhotoURLIsNilForBlankPhoto() async {
        fetcher.setProfile(PublicProfile(id: "u1", displayName: "そら", photoURL: ""), for: "u1")
        fetcher.setProfile(PublicProfile(id: "u2", displayName: "くも", photoURL: "  \n"), for: "u2")

        await store.prefetch(uids: ["u1", "u2"])

        XCTAssertNil(store.photoURL(for: "u1"))
        XCTAssertNil(store.photoURL(for: "u2"))
        XCTAssertNil(store.photoURL(for: "not-loaded"))
    }

    // MARK: - 取れなかったとき

    func testFailedFetchIsNotStoredAndIsRetriedByNextPrefetch() async {
        fetcher.setError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), for: "u1")
        fetcher.setProfile(PublicProfile(id: "u2", displayName: "くも"), for: "u2")

        await store.prefetch(uids: ["u1", "u2"])

        // 失敗した uid は保持しない（代替の表示のまま）。ほかの uid の取得は止まらない
        XCTAssertNil(store.profiles["u1"])
        XCTAssertEqual(store.displayName(for: "u1"), "ユーザー")
        XCTAssertEqual(store.displayName(for: "u2"), "くも")

        // 回復したあと、もう一度 prefetch すると、失敗した uid だけを取りに行く
        fetcher.setError(nil, for: "u1")
        fetcher.setProfile(PublicProfile(id: "u1", displayName: "そら"), for: "u1")
        await store.prefetch(uids: ["u1", "u2"])

        XCTAssertEqual(store.displayName(for: "u1"), "そら")
        XCTAssertEqual(fetcher.fetchedUids.filter { $0 == "u1" }.count, 2)
        XCTAssertEqual(fetcher.fetchedUids.filter { $0 == "u2" }.count, 1)
    }

    func testMissingProfileFallsBackToUser() async {
        // 公開プロフィールが無い（取得が notFound で失敗する）uid も、代替の表示になる
        await store.prefetch(uids: ["no-profile"])

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(store.displayName(for: "no-profile"), "ユーザー")
        XCTAssertNil(store.photoURL(for: "no-profile"))
    }

    // MARK: - 取りに行く対象

    func testAlreadyLoadedUidsAreNotFetchedAgain() async {
        fetcher.setProfile(PublicProfile(id: "u1", displayName: "そら"), for: "u1")

        await store.prefetch(uids: ["u1"])
        await store.prefetch(uids: ["u1"])

        XCTAssertEqual(fetcher.fetchedUids, ["u1"])
    }

    func testEmptyUidIsNotFetched() async {
        await store.prefetch(uids: [""])

        XCTAssertTrue(fetcher.fetchedUids.isEmpty)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testUidBeingFetchedIsNotFetchedTwice() async {
        fetcher.setProfile(PublicProfile(id: "u1", displayName: "そら"), for: "u1")
        fetcher.holdFetches()

        let firstPrefetch = Task { await store.prefetch(uids: ["u1"]) }
        await waitUntil { fetcher.fetchedUids.count == 1 }
        XCTAssertEqual(fetcher.fetchedUids, ["u1"])

        // 取得中の uid をもう一度頼んでも、二重には取りに行かず、待たずに戻る
        await store.prefetch(uids: ["u1"])
        XCTAssertEqual(fetcher.fetchedUids, ["u1"])
        XCTAssertNil(store.profiles["u1"])

        fetcher.release()
        await firstPrefetch.value

        XCTAssertEqual(store.displayName(for: "u1"), "そら")
    }

    // MARK: - 消去

    func testClearRemovesProfilesAndNextPrefetchFetchesAgain() async {
        fetcher.setProfile(PublicProfile(id: "u1", displayName: "そら", photoURL: "https://example.com/a.jpg"), for: "u1")
        await store.prefetch(uids: ["u1"])
        XCTAssertEqual(store.displayName(for: "u1"), "そら")

        store.clear()

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(store.displayName(for: "u1"), "ユーザー")
        XCTAssertNil(store.photoURL(for: "u1"))

        await store.prefetch(uids: ["u1"])
        XCTAssertEqual(store.displayName(for: "u1"), "そら")
        XCTAssertEqual(fetcher.fetchedUids, ["u1", "u1"])
    }

    func testClearWhileFetchingDiscardsLateResult() async {
        // サインアウト・アカウント切替の前に始めた取得が、切替のあとに前の保持を復活させない
        fetcher.setProfile(PublicProfile(id: "u1", displayName: "そら"), for: "u1")
        fetcher.holdFetches()

        let running = Task { await store.prefetch(uids: ["u1"]) }
        await waitUntil { fetcher.fetchedUids.count == 1 }
        XCTAssertEqual(fetcher.fetchedUids, ["u1"])

        store.clear()
        fetcher.release()
        await running.value

        XCTAssertNil(store.profiles["u1"])
        XCTAssertEqual(store.displayName(for: "u1"), "ユーザー")

        // clear() は取得中の記録も作り直す。もう一度 prefetch すれば、取りに行って保持する
        await store.prefetch(uids: ["u1"])
        XCTAssertEqual(store.displayName(for: "u1"), "そら")
        XCTAssertEqual(fetcher.fetchedUids, ["u1", "u1"])
    }

    // MARK: - 自分のプロフィールの保存（.profileUpdated 通知）

    /// 回帰テスト ⭐️: プロフィール編集で表示名とアイコンを保存したら、持っている覚えも新しい値になる
    ///
    /// 以前は一度取った uid を読み直さなかったため、プロフィール編集で「空」→「天名」に変えても、
    /// そらとものタイムラインは再起動するまで「空」のままだった（2026-10-06 実測）。
    func testProfileUpdatedNotificationReplacesStoredNameAndPhoto() async {
        fetcher.setProfile(
            PublicProfile(id: "u1", displayName: "空", photoURL: "https://example.com/old.jpg", followersCount: 3),
            for: "u1"
        )
        await store.prefetch(uids: ["u1"])
        XCTAssertEqual(store.displayName(for: "u1"), "空")

        postProfileUpdated(uid: "u1", displayName: "天名", photoURL: "https://example.com/new.jpg")
        await waitUntil { store.displayName(for: "u1") == "天名" }

        XCTAssertEqual(store.displayName(for: "u1"), "天名")
        XCTAssertEqual(store.photoURL(for: "u1"), URL(string: "https://example.com/new.jpg"))
        // 表示名とアイコン以外（サーバーが保つカウンタなど）は触らない
        XCTAssertEqual(store.profiles["u1"]?.followersCount, 3)
        // 新しい値は通知から入れる。取りに行き直さない
        XCTAssertEqual(fetcher.fetchedUids, ["u1"])
    }

    /// 表示名とアイコンを消して保存したら（キーが無い）、代替の表示に戻る
    func testProfileUpdatedNotificationWithoutNameAndPhotoFallsBack() async {
        fetcher.setProfile(PublicProfile(id: "u1", displayName: "空", photoURL: "https://example.com/old.jpg"), for: "u1")
        await store.prefetch(uids: ["u1"])

        postProfileUpdated(uid: "u1", displayName: nil, photoURL: nil)
        await waitUntil { store.displayName(for: "u1") == "ユーザー" }

        XCTAssertEqual(store.displayName(for: "u1"), "ユーザー")
        XCTAssertNil(store.photoURL(for: "u1"))
    }

    /// 持っていない uid の通知では、覚えを増やさない（次の prefetch がサーバーの新しい値を取る）
    func testProfileUpdatedNotificationForUnknownUidAddsNothing() async {
        fetcher.setProfile(PublicProfile(id: "u1", displayName: "空"), for: "u1")
        await store.prefetch(uids: ["u1"])

        postProfileUpdated(uid: "u2", displayName: "天名", photoURL: nil)
        // 同じ通知で u1 も差し替えて、通知の処理が終わったことを確かめてから u2 を見る
        postProfileUpdated(uid: "u1", displayName: "天名", photoURL: nil)
        await waitUntil { store.displayName(for: "u1") == "天名" }

        XCTAssertEqual(store.displayName(for: "u1"), "天名")
        XCTAssertNil(store.profiles["u2"])
        XCTAssertEqual(store.profiles.count, 1)
    }

    /// サインアウト（clear）の後に届いた通知で、前の覚えを復活させない
    func testProfileUpdatedNotificationAfterClearDoesNotRestore() async {
        fetcher.setProfile(PublicProfile(id: "u1", displayName: "空"), for: "u1")
        await store.prefetch(uids: ["u1"])
        store.clear()

        postProfileUpdated(uid: "u1", displayName: "天名", photoURL: nil)
        await waitUntil(timeout: 0.3) { store.profiles["u1"] != nil }

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(store.displayName(for: "u1"), "ユーザー")
    }

    /// プロフィール編集の保存と同じ通知を送る（nil の値はキーごと入れない）
    private func postProfileUpdated(uid: String, displayName: String?, photoURL: String?) {
        var userInfo: [String: Any] = [Notification.profileUpdatedUserIdKey: uid]
        if let displayName {
            userInfo[Notification.profileUpdatedDisplayNameKey] = displayName
        }
        if let photoURL {
            userInfo[Notification.profileUpdatedPhotoURLKey] = photoURL
        }
        NotificationCenter.default.post(name: .profileUpdated, object: nil, userInfo: userInfo)
    }
}
