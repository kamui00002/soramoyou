//
//  FirestoreDocumentDecoderTests.swift
//  SoramoyouTests
//
//  壊れたコメント・下書きドキュメントが混ざっても、他が返ることを確かめる ⭐️
//  偽ドキュメントを使うため Firestore（エミュレータ含む）無しで実行できる。
//

@testable import Soramoyou
import XCTest

final class FirestoreDocumentDecoderTests: XCTestCase {
    // MARK: - Helpers

    /// テスト用の偽ドキュメント（ID・パス・中身だけを持つ）
    private struct FakeDocument: FirestoreSourceDocument {
        let documentID: String
        let firestorePath: String
        let fields: [String: Any]

        func data() -> [String: Any] { fields }
    }

    /// `Comment(from:documentId:)` が受け付ける最小限のコメントドキュメント
    private func validComment(id: String) -> FakeDocument {
        FakeDocument(
            documentID: id,
            firestorePath: "comments/\(id)",
            fields: ["userId": "u1", "postId": "p1", "content": "きれいな空"]
        )
    }

    /// `Draft(from:)` が受け付ける最小限の下書きドキュメント
    private func validDraft(id: String) -> FakeDocument {
        FakeDocument(
            documentID: id,
            firestorePath: "drafts/\(id)",
            fields: ["id": id, "userId": "u1", "images": [[String: Any]]()]
        )
    }

    // MARK: - コメント: 壊れたドキュメントのスキップ

    /// 必須項目（content）が欠けた 1 件だけを飛ばし、前後のコメントは順番どおり返すこと
    ///
    /// Android 版など別クライアントが必須項目を欠いたコメントを 1 件書いても、
    /// その投稿のコメント欄全体が開けなくなってはいけない。
    func testDecodeCommentsSkipsDocumentMissingRequiredFieldsAndReturnsOthers() {
        let documents = [
            validComment(id: "c1"),
            FakeDocument(
                documentID: "broken",
                firestorePath: "comments/broken",
                fields: ["userId": "u1", "postId": "p1"]
            ),
            validComment(id: "c3"),
        ]
        var failures: [FirestoreDocumentDecoder.Failure] = []

        let comments = FirestoreDocumentDecoder.decodeComments(documents) {
            failures.append($0)
        }

        XCTAssertEqual(comments.map(\.id), ["c1", "c3"])
        // 壊れたドキュメントを後から探せるよう、パスと種類とエラーが記録されていること
        XCTAssertEqual(failures.map(\.path), ["comments/broken"])
        XCTAssertEqual(failures.map(\.kind), [.comment])
        XCTAssertTrue(failures.first?.error is CommentModelError)
    }

    /// 項目の型が違う 1 件（userId が数値）も同じく飛ばすこと
    func testDecodeCommentsSkipsDocumentWithWrongFieldType() {
        let documents = [
            FakeDocument(
                documentID: "bad-type",
                firestorePath: "comments/bad-type",
                fields: ["userId": 123, "postId": "p1", "content": "きれいな空"]
            ),
            validComment(id: "c2"),
        ]
        var failures: [FirestoreDocumentDecoder.Failure] = []

        let comments = FirestoreDocumentDecoder.decodeComments(documents) {
            failures.append($0)
        }

        XCTAssertEqual(comments.map(\.id), ["c2"])
        XCTAssertEqual(failures.map(\.path), ["comments/bad-type"])
    }

    // MARK: - コメント: 正常系

    /// すべて正常なら全件をドキュメントの順で返し、ID はドキュメント ID になること
    func testDecodeCommentsReturnsAllWhenEveryDocumentIsValid() {
        let documents = [validComment(id: "c1"), validComment(id: "c2")]
        var failures: [FirestoreDocumentDecoder.Failure] = []

        let comments = FirestoreDocumentDecoder.decodeComments(documents) {
            failures.append($0)
        }

        XCTAssertEqual(comments.map(\.id), ["c1", "c2"])
        XCTAssertTrue(failures.isEmpty)
    }

    /// ドキュメントが 0 件なら空配列を返すこと
    func testDecodeCommentsReturnsEmptyForNoDocuments() {
        var failures: [FirestoreDocumentDecoder.Failure] = []

        let comments = FirestoreDocumentDecoder.decodeComments([FakeDocument]()) {
            failures.append($0)
        }

        XCTAssertTrue(comments.isEmpty)
        XCTAssertTrue(failures.isEmpty)
    }

    // MARK: - 下書き: 壊れたドキュメントのスキップ

    /// 必須項目（userId）が欠けた 1 件だけを飛ばし、前後の下書きは順番どおり返すこと
    func testDecodeDraftsSkipsDocumentMissingRequiredFieldsAndReturnsOthers() {
        let documents = [
            validDraft(id: "d1"),
            FakeDocument(
                documentID: "broken",
                firestorePath: "drafts/broken",
                fields: ["id": "broken", "images": [[String: Any]]()]
            ),
            validDraft(id: "d3"),
        ]
        var failures: [FirestoreDocumentDecoder.Failure] = []

        let drafts = FirestoreDocumentDecoder.decodeDrafts(documents) {
            failures.append($0)
        }

        XCTAssertEqual(drafts.map(\.id), ["d1", "d3"])
        XCTAssertEqual(failures.map(\.path), ["drafts/broken"])
        XCTAssertEqual(failures.map(\.kind), [.draft])
        XCTAssertTrue(failures.first?.error is DraftModelError)
    }

    /// images が配列でない 1 件も同じく飛ばすこと
    func testDecodeDraftsSkipsDocumentWithInvalidImages() {
        let documents = [
            FakeDocument(
                documentID: "bad-images",
                firestorePath: "drafts/bad-images",
                fields: ["id": "bad-images", "userId": "u1", "images": "not-an-array"]
            ),
            validDraft(id: "d2"),
        ]
        var failures: [FirestoreDocumentDecoder.Failure] = []

        let drafts = FirestoreDocumentDecoder.decodeDrafts(documents) {
            failures.append($0)
        }

        XCTAssertEqual(drafts.map(\.id), ["d2"])
        XCTAssertEqual(failures.map(\.path), ["drafts/bad-images"])
    }

    // MARK: - 下書き: 正常系

    /// すべて正常なら全件をドキュメントの順で返すこと
    func testDecodeDraftsReturnsAllWhenEveryDocumentIsValid() {
        let documents = [validDraft(id: "d1"), validDraft(id: "d2")]
        var failures: [FirestoreDocumentDecoder.Failure] = []

        let drafts = FirestoreDocumentDecoder.decodeDrafts(documents) {
            failures.append($0)
        }

        XCTAssertEqual(drafts.map(\.id), ["d1", "d2"])
        XCTAssertTrue(failures.isEmpty)
    }
}
