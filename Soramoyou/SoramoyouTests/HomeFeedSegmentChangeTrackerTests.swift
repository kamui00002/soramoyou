//
//  HomeFeedSegmentChangeTrackerTests.swift ⭐️
//  SoramoyouTests
//
//  ホームのフィード切り替えが「上のタップ」か「左右のめくり」かを見分ける印（HomeView.swift の
//  HomeFeedSegmentChangeTracker）と、計装 home_feed_segment_changed の via に送る文字のテスト
//  1.18.0 PR-H「3: 切り替えの via（tap / swipe）」
//
//  ⚠️ 期待値は 1 つずつ直に書く（実装の式から期待値を作って比べると、式が間違っていても緑になる）。
//     手順ごとにテストを分けているのは、落ちたときにどの手順か分かるようにするため。
//

@testable import Soramoyou
import XCTest

final class HomeFeedSegmentChangeTrackerTests: XCTestCase {
    // MARK: - 印の立ち方と下り方

    /// 何もしていない（タップの印が無い）まま切り替わった → めくり（swipe）
    func testConsumeWithoutTapReturnsSwipe() {
        var tracker = HomeFeedSegmentChangeTracker()
        XCTAssertEqual(tracker.consume(), .swipe)
    }

    /// 別の値をタップで選んだ（すべて → あなた向け）後の切り替え → tap
    func testConsumeAfterTapToDifferentSegmentReturnsTap() {
        var tracker = HomeFeedSegmentChangeTracker()
        tracker.noteTap(from: .all, to: .forYou)
        XCTAssertEqual(tracker.consume(), .tap)
    }

    /// 印は 1 回読んだら下りる → タップの後の 2 回目の切り替えは swipe
    func testSecondConsumeAfterTapReturnsSwipe() {
        var tracker = HomeFeedSegmentChangeTracker()
        tracker.noteTap(from: .all, to: .forYou)
        XCTAssertEqual(tracker.consume(), .tap)
        XCTAssertEqual(tracker.consume(), .swipe)
    }

    /// 今と同じ値を選び直しただけ（すべて → すべて）では印を立てない → swipe
    func testConsumeAfterTapToSameSegmentReturnsSwipe() {
        var tracker = HomeFeedSegmentChangeTracker()
        tracker.noteTap(from: .all, to: .all)
        XCTAssertEqual(tracker.consume(), .swipe)
    }

    /// 選び直しの後にめくった → swipe（選び直しの印が残って tap にならない）。
    /// 続けて別の値をタップで選んだ → tap（選び直しの後でもタップは正しく tap になる）
    func testReselectThenSwipeThenTapReturnsSwipeThenTap() {
        var tracker = HomeFeedSegmentChangeTracker()
        tracker.noteTap(from: .all, to: .all)
        XCTAssertEqual(tracker.consume(), .swipe)
        tracker.noteTap(from: .forYou, to: .all)
        XCTAssertEqual(tracker.consume(), .tap)
    }

    // MARK: - 送る文字

    /// PostHog に送る via の文字を固定する（変えると過去の記録と分かれて集計できなくなる）
    func testViaRawValuesAreFixed() {
        XCTAssertEqual(HomeFeedSegmentChangeVia.tap.rawValue, "tap")
        XCTAssertEqual(HomeFeedSegmentChangeVia.swipe.rawValue, "swipe")
    }
}
