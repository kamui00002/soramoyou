//
//  SoratomoLeftGroupsTests.swift
//  SoramoyouTests
//
//  この端末で抜けたそらとものグループの記録（SoratomoLeftGroups）のテスト ⭐️
//  （leave-group 7.2・要件 5.3・5.6・5.7）
//
//  端末の記録はテストごとの UserDefaults（suite）に書き、終わったら消す。
//

@testable import Soramoyou
import XCTest

final class SoratomoLeftGroupsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "SoratomoLeftGroupsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testStorageKeyIsPerUser() {
        // 8.x と受け入れの確認（12.2）がこのキーを見る
        XCTAssertEqual(SoratomoLeftGroups.storageKey(uid: "user-a"), "soratomo.leftGroups.user-a")
    }

    func testLeftGroupsAreSeparatedPerUser() {
        // A が抜けたグループは、B では隠さない（アカウントを切り替えても漏らさない）
        let store = SoratomoLeftGroups(defaults: defaults)
        store.insert("group-a", uid: "user-a")
        XCTAssertTrue(store.contains("group-a", uid: "user-a"))
        XCTAssertFalse(store.contains("group-a", uid: "user-b"), "A の記録が B に見えている")

        store.insert("group-b", uid: "user-b")
        XCTAssertFalse(store.contains("group-b", uid: "user-a"), "B の記録が A に見えている")
        XCTAssertTrue(store.contains("group-a", uid: "user-a"))
    }

    func testLeftGroupsSurviveRecreation() {
        // 再起動（作り直し）しても残る。メモリに持たず毎回端末を読むので、読み込みの手順は無い
        SoratomoLeftGroups(defaults: defaults).insert("group-1", uid: "user-a")

        let reloaded = SoratomoLeftGroups(defaults: defaults)
        XCTAssertTrue(reloaded.contains("group-1", uid: "user-a"))
        XCTAssertFalse(reloaded.contains("group-2", uid: "user-a"))
    }

    func testLeftGroupsKeepNewestFifty() {
        XCTAssertEqual(SoratomoLeftGroups.maxCount, 50)
        let store = SoratomoLeftGroups(defaults: defaults)
        for index in 0 ... SoratomoLeftGroups.maxCount {
            store.insert("group-\(index)", uid: "user-a")
        }
        // 51 件目を足したら、いちばん古い 1 件だけを捨てる
        XCTAssertFalse(store.contains("group-0", uid: "user-a"))
        XCTAssertTrue(store.contains("group-1", uid: "user-a"))
        XCTAssertTrue(store.contains("group-50", uid: "user-a"))

        // 同じグループを足し直したら最新の扱いになり、次に捨てられるのは別のグループ
        store.insert("group-1", uid: "user-a")
        store.insert("group-new", uid: "user-a")
        XCTAssertTrue(store.contains("group-1", uid: "user-a"))
        XCTAssertFalse(store.contains("group-2", uid: "user-a"))
        XCTAssertTrue(store.contains("group-new", uid: "user-a"))
    }

    func testRemoveTakesOutOnlyThatGroupOfThatUser() {
        let store = SoratomoLeftGroups(defaults: defaults)
        store.insert("group-1", uid: "user-a")
        store.insert("group-2", uid: "user-a")
        store.insert("group-1", uid: "user-b")

        store.remove("group-1", uid: "user-a")

        XCTAssertFalse(store.contains("group-1", uid: "user-a"))
        XCTAssertTrue(store.contains("group-2", uid: "user-a"), "外していないグループまで消えた")
        XCTAssertTrue(store.contains("group-1", uid: "user-b"), "A が外したら B の記録まで消えた")
        XCTAssertTrue(SoratomoLeftGroups(defaults: defaults).contains("group-2", uid: "user-a"))
    }

    func testRemoveOfUnknownGroupDoesNothing() {
        // 記録に無いグループ・記録の無い利用者で外しても落ちず、ほかの記録も変えない
        let store = SoratomoLeftGroups(defaults: defaults)
        store.insert("group-1", uid: "user-a")

        store.remove("group-x", uid: "user-a")
        store.remove("group-1", uid: "user-nobody")

        XCTAssertTrue(store.contains("group-1", uid: "user-a"))
        XCTAssertFalse(store.contains("group-1", uid: "user-nobody"))
    }

    func testUnreadableRecordIsTreatedAsEmpty() {
        // 端末の記録が読めない形でも落とさない（空として扱い、足せば上書きされる）
        defaults.set(Data("not json".utf8), forKey: SoratomoLeftGroups.storageKey(uid: "user-a"))
        let store = SoratomoLeftGroups(defaults: defaults)
        XCTAssertFalse(store.contains("group-1", uid: "user-a"))

        store.insert("group-1", uid: "user-a")
        XCTAssertTrue(store.contains("group-1", uid: "user-a"))
    }
}
