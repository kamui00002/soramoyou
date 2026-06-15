//
//  CommentTests.swift
//  SoramoyouTests
//
//  Comment モデルの投稿者情報（authorName / authorPhotoURL）非正規化の検証
//

import XCTest
import FirebaseFirestore
@testable import Soramoyou

final class CommentTests: XCTestCase {

    /// 投稿者情報があるときは Firestore データに含まれる
    func testToFirestoreDataIncludesAuthorFieldsWhenPresent() {
        let comment = Comment(
            userId: "u1",
            postId: "p1",
            content: "きれいな空",
            authorName: "Soumatou",
            authorPhotoURL: "https://example.com/a.jpg"
        )

        let data = comment.toFirestoreData()

        XCTAssertEqual(data["authorName"] as? String, "Soumatou")
        XCTAssertEqual(data["authorPhotoURL"] as? String, "https://example.com/a.jpg")
        XCTAssertEqual(data["content"] as? String, "きれいな空")
    }

    /// 投稿者情報が nil のときはキー自体を書き込まない（旧コメント・匿名）
    func testToFirestoreDataOmitsAuthorFieldsWhenNil() {
        let comment = Comment(userId: "u1", postId: "p1", content: "きれいな空")

        let data = comment.toFirestoreData()

        XCTAssertNil(data["authorName"])
        XCTAssertNil(data["authorPhotoURL"])
    }

    /// Firestore ドキュメントから投稿者情報を復元できる
    func testInitFromDocumentParsesAuthorFields() throws {
        let data: [String: Any] = [
            "userId": "u1",
            "postId": "p1",
            "content": "きれいな空",
            "authorName": "Soumatou",
            "authorPhotoURL": "https://example.com/a.jpg",
            "createdAt": Timestamp(date: Date())
        ]

        let comment = try Comment(from: data, documentId: "c1")

        XCTAssertEqual(comment.authorName, "Soumatou")
        XCTAssertEqual(comment.authorPhotoURL, "https://example.com/a.jpg")
    }

    /// 旧コメント（投稿者情報なし）でも壊れず nil になる（後方互換）
    func testInitFromLegacyDocumentWithoutAuthorFields() throws {
        let data: [String: Any] = [
            "userId": "u1",
            "postId": "p1",
            "content": "きれいな空",
            "createdAt": Timestamp(date: Date())
        ]

        let comment = try Comment(from: data, documentId: "c1")

        XCTAssertNil(comment.authorName)
        XCTAssertNil(comment.authorPhotoURL)
        XCTAssertEqual(comment.content, "きれいな空")
    }
}
