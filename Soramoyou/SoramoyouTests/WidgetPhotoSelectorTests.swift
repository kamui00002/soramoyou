//
//  WidgetPhotoSelectorTests.swift
//  SoramoyouTests
//
//  ウィジェットの写真選択（Mode A ローテ / Mode B 時間帯マッチ）の決定的純関数テスト。
//

import XCTest
@testable import Soramoyou

final class WidgetPhotoSelectorTests: XCTestCase {

    private func entry(_ id: String, timeOfDay: String?, createdAt: TimeInterval) -> WidgetIndex.Entry {
        WidgetIndex.Entry(
            postId: id,
            imageFileName: "\(id).jpg",
            timeOfDay: timeOfDay,
            skyColors: [],
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    private func date(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    // createdAt 降順で a(300) > b(200) > c(100)。
    private var threeEntries: [WidgetIndex.Entry] {
        [entry("a", timeOfDay: "evening", createdAt: 300),
         entry("b", timeOfDay: "evening", createdAt: 200),
         entry("c", timeOfDay: "morning", createdAt: 100)]
    }

    // MARK: - Mode A ローテーション

    func testAlbumPickRotatesDeterministicallyAcrossSlots() {
        let e = threeEntries
        let interval: TimeInterval = 3600
        // slot 0,1,2,3 → a,b,c,a（降順 a,b,c を順に巡回）
        XCTAssertEqual(WidgetPhotoSelector.albumPick(from: e, at: date(0), rotationInterval: interval)?.postId, "a")
        XCTAssertEqual(WidgetPhotoSelector.albumPick(from: e, at: date(3600), rotationInterval: interval)?.postId, "b")
        XCTAssertEqual(WidgetPhotoSelector.albumPick(from: e, at: date(7200), rotationInterval: interval)?.postId, "c")
        XCTAssertEqual(WidgetPhotoSelector.albumPick(from: e, at: date(10800), rotationInterval: interval)?.postId, "a")
    }

    func testAlbumPickIsStableForSameSlot() {
        let e = threeEntries
        let first = WidgetPhotoSelector.albumPick(from: e, at: date(1000), rotationInterval: 3600)?.postId
        let again = WidgetPhotoSelector.albumPick(from: e, at: date(1500), rotationInterval: 3600)?.postId
        XCTAssertEqual(first, again, "同一スロット内では同じ写真")
    }

    func testAlbumPickEmptyReturnsNil() {
        XCTAssertNil(WidgetPhotoSelector.albumPick(from: [], at: date(0)))
    }

    // MARK: - Mode B 時間帯マッチ

    func testSkyPickMatchesPhaseBucket() {
        // goldenHour → evening バケット。evening タグの a/b のどちらか。
        let picked = WidgetPhotoSelector.skyPick(from: threeEntries, phase: .goldenHour, at: date(0))
        XCTAssertEqual(picked?.timeOfDay, "evening")
        XCTAssertTrue(["a", "b"].contains(picked?.postId ?? ""))
    }

    func testSkyPickMorningBucket() {
        // morning 局面 → morning バケット → c のみ。
        let picked = WidgetPhotoSelector.skyPick(from: threeEntries, phase: .morning, at: date(0))
        XCTAssertEqual(picked?.postId, "c")
    }

    func testSkyPickNoMatchReturnsNil() {
        // night バケットの写真は無い → nil（呼び出し側で Mode C フォールバック）。
        XCTAssertNil(WidgetPhotoSelector.skyPick(from: threeEntries, phase: .night, at: date(0)))
    }

    // MARK: - タイムライン

    func testAlbumTimelineProducesIncreasingDates() {
        let pairs = WidgetPhotoSelector.albumTimeline(from: threeEntries, startingAt: date(0), count: 5, rotationInterval: 3600)
        XCTAssertEqual(pairs.count, 5)
        for i in 1..<pairs.count {
            XCTAssertGreaterThan(pairs[i].date, pairs[i - 1].date, "表示開始時刻は単調増加")
        }
        // 先頭は slot0 = a。
        XCTAssertEqual(pairs.first?.entry.postId, "a")
    }

    func testAlbumTimelineEmptyEntries() {
        XCTAssertTrue(WidgetPhotoSelector.albumTimeline(from: [], startingAt: date(0), count: 5).isEmpty)
    }
}
