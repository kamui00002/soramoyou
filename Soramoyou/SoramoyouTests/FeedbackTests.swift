//
//  FeedbackTests.swift
//  SoramoyouTests
//
//  Feedback モデルの Firestore マッピング・バリデーション検証
//

import XCTest
import FirebaseFirestore
@testable import Soramoyou

final class FeedbackTests: XCTestCase {

    /// 必須キー（userId/message/createdAt）と任意項目がある場合に書き込まれる
    func testToFirestoreDataIncludesRequiredAndOptionalFields() {
        let feedback = Feedback(
            userId: "u1",
            message: "アプリ最高です",
            category: "request",
            appVersion: "1.7.4 (57)",
            deviceInfo: "iOS 18.5 / iPhone"
        )

        let data = feedback.toFirestoreData()

        XCTAssertEqual(data["userId"] as? String, "u1")
        XCTAssertEqual(data["message"] as? String, "アプリ最高です")
        XCTAssertNotNil(data["createdAt"])  // serverTimestamp sentinel
        XCTAssertEqual(data["category"] as? String, "request")
        XCTAssertEqual(data["appVersion"] as? String, "1.7.4 (57)")
        XCTAssertEqual(data["deviceInfo"] as? String, "iOS 18.5 / iPhone")
    }

    /// 必須キーは rules の hasAll(['userId','message','createdAt']) を満たす
    func testToFirestoreDataSatisfiesRulesRequiredKeys() {
        let data = Feedback(userId: "u1", message: "hi").toFirestoreData()
        for key in ["userId", "message", "createdAt"] {
            XCTAssertNotNil(data[key], "必須キー \(key) が欠落")
        }
    }

    /// 任意項目が nil のときはキーを書き込まない
    func testToFirestoreDataOmitsNilOptionalFields() {
        let data = Feedback(userId: "u1", message: "hi").toFirestoreData()
        XCTAssertNil(data["category"])
        XCTAssertNil(data["appVersion"])
        XCTAssertNil(data["deviceInfo"])
    }

    /// バリデーション: 空・空白のみは無効、通常文は有効、上限超過は無効
    func testIsValid() {
        XCTAssertTrue(Feedback(userId: "u1", message: "感想です").isValid)
        XCTAssertFalse(Feedback(userId: "u1", message: "").isValid)
        XCTAssertFalse(Feedback(userId: "u1", message: "   \n ").isValid)
        XCTAssertFalse(Feedback(userId: "u1", message: String(repeating: "あ", count: 1001)).isValid)
        XCTAssertTrue(Feedback(userId: "u1", message: String(repeating: "あ", count: 1000)).isValid)
    }
}
