//
//  HapticsTests.swift
//  SoramoyouTests
//
//  触覚の共通部品 `Haptics` の「場面 → 中身」の対応表のテスト ⭐️（1.18.0 UI 刷新 PR-U）
//
//  ⚠️ 期待値は 1 つずつ直に書く（実装の表から期待値を作って比べると、表が間違っていても緑になる）。
//     場面ごとにテストを分けているのは、落ちたときにどの場面か分かるようにするため。
//

@testable import Soramoyou
import XCTest

final class HapticsTests: XCTestCase {
    // MARK: - 場面の数

    func testKindCountIsFive() {
        // 場面を足したのに下の期待値を足し忘れたら、ここで赤になる
        XCTAssertEqual(Haptics.Kind.allCases.count, 5)
    }

    // MARK: - 場面 → 中身

    func testLikeOnIsMediumImpact() {
        // いいねを付けた → impact medium（軽いタップより一段強い）
        XCTAssertEqual(Haptics.Kind.likeOn.pattern, .impact(.medium))
    }

    func testTapIsLightImpact() {
        // いいねを外した・🔖・入口ボタン・カードを開く → impact light（今までの直書きと同じ）
        XCTAssertEqual(Haptics.Kind.tap.pattern, .impact(.light))
    }

    func testSuccessIsSuccessNotification() {
        // フォローした・投稿完了 → notification success
        XCTAssertEqual(Haptics.Kind.success.pattern, .notification(.success))
    }

    func testSelectionIsSelectionChanged() {
        // 切り替えた → selection changed
        XCTAssertEqual(Haptics.Kind.selection.pattern, .selection)
    }

    func testErrorIsErrorNotification() {
        // 失敗した → notification error
        XCTAssertEqual(Haptics.Kind.error.pattern, .notification(.error))
    }
}
