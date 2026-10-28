//
//  HomeDetailZoomTests.swift ⭐️
//  SoramoyouTests
//
//  ホームのカードの写真から詳細へ広がるズーム遷移（iOS 18 以上）の目印（HomeView.swift の
//  HomeDetailZoom.sourceID）のテスト
//  1.18.0 PR-H「5: 写真が広がって詳細へ」
//
//  ⚠️ 期待値は 1 つずつ直に書く（実装の式から期待値を作って比べると、式が間違っていても緑になる）。
//     ①（同じ入力を 2 回）は、決まった文字を返すだけの仮の実装でも緑になる。
//     ②（ページ違いは別の値）と ③（文字の形）で中身を押さえるので、3 本そろえて意味がある。
//

@testable import Soramoyou
import XCTest

final class HomeDetailZoomTests: XCTestCase {
    // MARK: - 目印の同じ・違う

    /// ① 同じページ・同じ投稿 → 2 回作っても同じ目印
    /// （カードの写真と詳細のシートは別々に目印を作るので、同じ入力から同じ値が出ないと結び付かない）
    func testSameSegmentAndSamePostReturnsSameID() {
        let first = HomeDetailZoom.sourceID(segment: .all, postID: "p1")
        let second = HomeDetailZoom.sourceID(segment: .all, postID: "p1")
        XCTAssertEqual(first, second)
    }

    /// ② 同じ投稿でもページが違えば違う目印
    /// （同じ投稿が「すべて」と「あなた向け」の両方に出ても、2 枚の写真の目印が衝突しない）
    func testSamePostOnDifferentSegmentsReturnsDifferentIDs() {
        XCTAssertNotEqual(
            HomeDetailZoom.sourceID(segment: .all, postID: "p1"),
            HomeDetailZoom.sourceID(segment: .forYou, postID: "p1")
        )
    }

    // MARK: - 文字の形

    /// ③ 目印の文字の形を固定する（ページ名の rawValue ＋ "-" ＋ 投稿 ID）
    func testSourceIDFormatIsFixed() {
        XCTAssertEqual(HomeDetailZoom.sourceID(segment: .all, postID: "p1"), "all-p1")
        XCTAssertEqual(HomeDetailZoom.sourceID(segment: .forYou, postID: "p1"), "forYou-p1")
    }
}
