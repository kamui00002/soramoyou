//
//  MotionTests.swift
//  SoramoyouTests
//
//  「視差効果を減らす」に合わせて動きを選ぶ `Motion.animation` のテスト ⭐️（1.18.0 UI 刷新 PR-U）
//
//  ⚠️ 期待値は直に書く（ON → nil・OFF → 渡した動きそのもの）。
//  ⚠️ OFF の比較は `Animation` の Equatable（==）で書いた（同じ式で作った 2 つは == で真になる＝2026-10-24 に確かめた）。
//     あわせて「違う動きどうしは等しくない」も確かめている（testReduceMotionOffDoesNotMatchDifferentAnimation）。
//     == がいつも真を返すなら OFF のテストは何も確かめていないことになるので、その見分けに使う。
//
//  ⚠️ 陽性対照（2026-10-24・Mac の使い捨て SwiftPM パッケージで実施。リポジトリの Motion.swift は触らず写しを壊した）:
//     `reduceMotion ? nil : base` → `reduceMotion ? base : nil` に逆にした写しで、
//     予言どおり 3 本が赤（ON の 2 本と testReduceMotionOffReturnsBaseAnimation）。
//     testReduceMotionOffDoesNotMatchDifferentAnimation は緑のまま（nil も linear と等しくないため・予言どおり）。
//     壊さない写しでは 4/4 緑。シミュレーター（iPhone 18 Pro・iOS 27.0）でも 4/4 緑
//

@testable import Soramoyou
import SwiftUI
import XCTest

final class MotionTests: XCTestCase {
    // MARK: - ON（視差効果を減らす）

    func testReduceMotionOnReturnsNil() {
        // ON のときは動かさない（withAnimation(nil) ＝ 一瞬で変わる）
        XCTAssertNil(Motion.animation(.easeInOut(duration: 1), reduceMotion: true))
    }

    func testReduceMotionOnReturnsNilForRepeatingAnimation() {
        // ずっと動く動き（repeatForever）でも ON なら nil
        XCTAssertNil(Motion.animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), reduceMotion: true))
    }

    // MARK: - OFF

    func testReduceMotionOffReturnsBaseAnimation() {
        // OFF のときは渡した動きをそのまま返す（今の動きを変えない）
        XCTAssertEqual(Motion.animation(.easeInOut(duration: 1), reduceMotion: false), Animation.easeInOut(duration: 1))
    }

    func testReduceMotionOffDoesNotMatchDifferentAnimation() {
        // 比べ方の確認: 違う動きと等しくならないこと（== がいつも真なら、上の OFF のテストは意味を持たない）
        XCTAssertNotEqual(Motion.animation(.easeInOut(duration: 1), reduceMotion: false), Animation.linear(duration: 1))
    }
}
