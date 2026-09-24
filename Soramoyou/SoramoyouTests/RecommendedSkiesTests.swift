//
//  RecommendedSkiesTests.swift
//  SoramoyouTests
//
//  「私のおすすめの空」の一覧操作ルールのテスト ⭐️
//

import XCTest
@testable import Soramoyou

final class RecommendedSkiesTests: XCTestCase {
    // MARK: - adding

    func testAddingAppendsToEnd() {
        XCTAssertEqual(RecommendedSkies.adding("C", to: ["A", "B"]), .added(["A", "B", "C"]))
    }

    func testAddingExistingPostDoesNothing() {
        XCTAssertEqual(RecommendedSkies.adding("A", to: ["A", "B"]), .alreadyAdded(["A", "B"]))
    }

    func testAddingWhenFullIsRejected() {
        XCTAssertEqual(RecommendedSkies.adding("D", to: ["A", "B", "C"]), .full(["A", "B", "C"]))
    }

    func testAddingExistingPostWhenFullIsStillAlreadyAdded() {
        // 満杯でも、既に入っている投稿なら「上限です」と言わない
        XCTAssertEqual(RecommendedSkies.adding("B", to: ["A", "B", "C"]), .alreadyAdded(["A", "B", "C"]))
    }

    func testMaxCountIsThree() {
        // firestore.rules の size() <= 3 と揃っていること
        XCTAssertEqual(RecommendedSkies.maxCount, 3)
    }

    func testAddResultExposesPostIds() {
        XCTAssertEqual(RecommendedSkies.AddResult.full(["A"]).postIds, ["A"])
        XCTAssertEqual(RecommendedSkies.AddResult.added(["A", "B"]).postIds, ["A", "B"])
    }

    // MARK: - removing

    func testRemovingKeepsOrderOfRest() {
        XCTAssertEqual(RecommendedSkies.removing(["B"], from: ["A", "B", "C"]), ["A", "C"])
    }

    func testRemovingSeveralAtOnce() {
        XCTAssertEqual(RecommendedSkies.removing(["A", "C"], from: ["A", "B", "C"]), ["B"])
    }

    func testRemovingUnknownPostChangesNothing() {
        XCTAssertEqual(RecommendedSkies.removing(["Z"], from: ["A", "B"]), ["A", "B"])
    }

    // MARK: - moving

    func testMovingForward() {
        XCTAssertEqual(RecommendedSkies.moving("B", by: -1, in: ["A", "B", "C"]), ["B", "A", "C"])
    }

    func testMovingBackward() {
        XCTAssertEqual(RecommendedSkies.moving("B", by: 1, in: ["A", "B", "C"]), ["A", "C", "B"])
    }

    func testMovingPastEdgesDoesNothing() {
        XCTAssertEqual(RecommendedSkies.moving("A", by: -1, in: ["A", "B", "C"]), ["A", "B", "C"])
        XCTAssertEqual(RecommendedSkies.moving("C", by: 1, in: ["A", "B", "C"]), ["A", "B", "C"])
    }

    func testMovingUnknownPostDoesNothing() {
        XCTAssertEqual(RecommendedSkies.moving("Z", by: 1, in: ["A", "B"]), ["A", "B"])
    }

    // MARK: - normalized

    func testNormalizedDropsDuplicatesAndEmptyIds() {
        XCTAssertEqual(RecommendedSkies.normalized(["A", "", "B", "A"]), ["A", "B"])
    }

    func testAddingToDuplicatedListCountsUniqueIds() {
        // 重複が混ざった一覧でも、実質 2 枚なら追加できる
        XCTAssertEqual(RecommendedSkies.adding("C", to: ["A", "A", "B"]), .added(["A", "B", "C"]))
    }
}
