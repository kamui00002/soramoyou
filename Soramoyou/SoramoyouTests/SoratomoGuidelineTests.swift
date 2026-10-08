//
//  SoratomoGuidelineTests.swift
//  SoramoyouTests
//
//  そらともガイドライン（SoratomoGuideline）のテスト ⭐️（release-gate 8）
//  本文の 4 つの節と入口の判定のテストは release-gate 9.5 で足す。
//

@testable import Soramoyou
import XCTest

final class SoratomoGuidelineTests: XCTestCase {
    func testCurrentVersionMatchesServer() {
        // ⚠️ functions/soratomoCore.test.js の「GUIDELINE_VERSION は 1」と同じ値に固定する。
        //    片方だけ上げると、同意しても outdated_guideline で拒否され続けるか、古いアプリだと誤って案内する
        XCTAssertEqual(SoratomoGuideline.currentVersion, 1)
    }
}
