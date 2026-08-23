//
//  HorizontalScrollEdgeRuleTests.swift
//  SoramoyouTests
//
//  横スクロール行の「まだ続きがある」判定（純関数）の単体テスト ⭐️
//
//  レビュー D1 対応: 判定基準を画面幅（UIScreen）からスクロールビュー自身の右端へ変えた際に、
//  判定を純関数へ切り出してテストできるようにした。iPad の Split View や iPhone 横向きでは
//  「画面幅」と「コンテナ幅」が一致せず、旧実装では手がかりが出ない／早く消える不具合になる。
//

@testable import Soramoyou
import XCTest

final class HorizontalScrollEdgeRuleTests: XCTestCase {
    private typealias Rule = HorizontalScrollEdgeRule

    // MARK: - 基本の判定

    /// 内容がコンテナより右へはみ出していれば手がかりを出す
    func testはみ出していれば手がかりを出す() {
        XCTAssertTrue(
            Rule.hasMoreTrailing(contentTrailingEdgeX: 900, containerTrailingEdgeX: 402)
        )
    }

    /// 内容がコンテナに収まっていれば手がかりを出さない
    func test収まっていれば手がかりを出さない() {
        XCTAssertFalse(
            Rule.hasMoreTrailing(contentTrailingEdgeX: 300, containerTrailingEdgeX: 402)
        )
    }

    /// 内容の右端がコンテナの右端とちょうど一致するときは出さない（＝読み切っている）
    func testちょうど一致は手がかりを出さない() {
        XCTAssertFalse(
            Rule.hasMoreTrailing(contentTrailingEdgeX: 402, containerTrailingEdgeX: 402)
        )
    }

    // MARK: - 許容誤差（epsilon）の境界

    /// 許容誤差ちょうどのはみ出しは「読み切った」とみなす（バウンス等の揺れを吸収する）
    func test許容誤差ちょうどは手がかりを出さない() {
        XCTAssertFalse(
            Rule.hasMoreTrailing(
                contentTrailingEdgeX: 402 + Rule.defaultEpsilon,
                containerTrailingEdgeX: 402
            )
        )
    }

    /// 許容誤差を超えたら手がかりを出す
    func test許容誤差を超えたら手がかりを出す() {
        XCTAssertTrue(
            Rule.hasMoreTrailing(
                contentTrailingEdgeX: 402 + Rule.defaultEpsilon + 0.5,
                containerTrailingEdgeX: 402
            )
        )
    }

    // MARK: - 未計測時のフォールバック

    /// 内容の右端が未計測（0）のときは、出さないより出すほうを選ぶ
    func test内容が未計測なら手がかりを出す() {
        XCTAssertTrue(
            Rule.hasMoreTrailing(contentTrailingEdgeX: 0, containerTrailingEdgeX: 402)
        )
    }

    /// コンテナ幅が未確定（0）のときも、出さないより出すほうを選ぶ
    func testコンテナが未計測なら手がかりを出す() {
        XCTAssertTrue(
            Rule.hasMoreTrailing(contentTrailingEdgeX: 900, containerTrailingEdgeX: 0)
        )
    }

    // MARK: - 回帰: 画面幅ではなくコンテナ幅で判定する（レビュー D1）

    /// iPad の Split View 相当。画面幅 1024 に対しウィンドウ内のスクロールビューは右端 500。
    /// 旧実装（画面幅と比較）では 900 > 1024 が偽になり手がかりが永久に出なかった。
    func testSplitView相当でも手がかりが出る() {
        let screenWidth: CGFloat = 1024
        let containerTrailingEdgeX: CGFloat = 500
        let contentTrailingEdgeX: CGFloat = 900

        XCTAssertTrue(
            Rule.hasMoreTrailing(
                contentTrailingEdgeX: contentTrailingEdgeX,
                containerTrailingEdgeX: containerTrailingEdgeX
            ),
            "コンテナ基準なら、はみ出しを正しく検出できること"
        )
        XCTAssertFalse(
            contentTrailingEdgeX > screenWidth,
            "画面幅基準だと検出できないこと（旧実装の不具合を明示する対比）"
        )
    }

    /// iPhone 横向き相当。画面幅 874 に対し safe area の分だけ内側の右端 815。
    /// 内容の右端 830 は「まだ 15pt 隠れている」状態だが、
    /// 旧実装（画面幅と比較）では 830 > 874 が偽になり手がかりが早く消えていた。
    func test横向きのSafeAreaでも手がかりが出る() {
        let screenWidth: CGFloat = 874
        let containerTrailingEdgeX: CGFloat = 815
        let contentTrailingEdgeX: CGFloat = 830

        XCTAssertTrue(
            Rule.hasMoreTrailing(
                contentTrailingEdgeX: contentTrailingEdgeX,
                containerTrailingEdgeX: containerTrailingEdgeX
            ),
            "コンテナ基準なら、safe area 内側のはみ出しを検出できること"
        )
        XCTAssertFalse(
            contentTrailingEdgeX > screenWidth,
            "画面幅基準だと検出できないこと（旧実装の不具合を明示する対比）"
        )
    }
}
