//
//  PostReactionButtonFeedbackTests.swift ⭐️
//  SoramoyouTests
//
//  いいね・🔖 の共通ボタン（PostReactionButtons.swift）の「触覚の強さ」と「弾ませるか」の判定のテスト
//  1.18.0 PR-H「2: いいね・🔖 の共通ボタン」
//
//  ⚠️ 期待値は 1 つずつ直に書く（実装の式から期待値を作って比べると、式が間違っていても緑になる）。
//     押し方ごとにテストを分けているのは、落ちたときにどの押し方か分かるようにするため。
//

@testable import Soramoyou
import XCTest

final class PostReactionButtonFeedbackTests: XCTestCase {
    // MARK: - いいね

    /// いいねが OFF のときに押す（付ける）→ 触覚は一段強い likeOn・弾み待ちにする
    func testLikeOffWithActionPlaysLikeOnAndWaitsForBounce() {
        XCTAssertEqual(PostReactionButtonFeedback.haptic(isLike: true, isOnBefore: false, hasAction: true), .likeOn)
        XCTAssertTrue(PostReactionButtonFeedback.shouldWaitForBounce(isOnBefore: false, hasAction: true))
    }

    /// いいねが ON のときに押す（外す）→ 触覚は軽い tap・弾み待ちにしない
    func testLikeOnWithActionPlaysTapAndDoesNotWaitForBounce() {
        XCTAssertEqual(PostReactionButtonFeedback.haptic(isLike: true, isOnBefore: true, hasAction: true), .tap)
        XCTAssertFalse(PostReactionButtonFeedback.shouldWaitForBounce(isOnBefore: true, hasAction: true))
    }

    /// 押したときの処理が無い（検索の画面のカード）→ OFF で押しても tap・弾み待ちにしない（押しても何も起きないため）
    func testLikeOffWithoutActionPlaysTapAndDoesNotWaitForBounce() {
        XCTAssertEqual(PostReactionButtonFeedback.haptic(isLike: true, isOnBefore: false, hasAction: false), .tap)
        XCTAssertFalse(PostReactionButtonFeedback.shouldWaitForBounce(isOnBefore: false, hasAction: false))
    }

    // MARK: - 🔖

    /// 🔖 が OFF のときに押す（付ける）→ 触覚は tap（likeOn はいいね専用）・弾み待ちにする
    func testFavoriteOffWithActionPlaysTapAndWaitsForBounce() {
        XCTAssertEqual(PostReactionButtonFeedback.haptic(isLike: false, isOnBefore: false, hasAction: true), .tap)
        XCTAssertTrue(PostReactionButtonFeedback.shouldWaitForBounce(isOnBefore: false, hasAction: true))
    }

    /// 🔖 が ON のときに押す（外す）→ 触覚は tap・弾み待ちにしない
    func testFavoriteOnWithActionPlaysTapAndDoesNotWaitForBounce() {
        XCTAssertEqual(PostReactionButtonFeedback.haptic(isLike: false, isOnBefore: true, hasAction: true), .tap)
        XCTAssertFalse(PostReactionButtonFeedback.shouldWaitForBounce(isOnBefore: true, hasAction: true))
    }

    // MARK: - 弾むか

    /// 弾み待ち（付けるタップの後）で ON になった → 弾む
    func testBouncesWhenWaitingAndTurnedOn() {
        XCTAssertTrue(PostReactionButtonFeedback.shouldBounce(waitingForBounce: true, isOnNow: true))
    }

    /// 弾まない 2 つ
    /// - 弾み待ちでないのに ON になった（フィードの読み込みで checkLikeStatus がいいね済みにした）→ 弾まない
    /// - 弾み待ちだったが OFF になった → 弾まない
    func testDoesNotBounceWhenNotWaitingOrTurnedOff() {
        XCTAssertFalse(PostReactionButtonFeedback.shouldBounce(waitingForBounce: false, isOnNow: true))
        XCTAssertFalse(PostReactionButtonFeedback.shouldBounce(waitingForBounce: true, isOnNow: false))
    }
}
