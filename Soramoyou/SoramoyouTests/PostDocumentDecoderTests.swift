//
//  PostDocumentDecoderTests.swift
//  SoramoyouTests
//
//  壊れた投稿ドキュメントが混ざっても、他の投稿が返ることを確かめる ⭐️
//  偽ドキュメントを使うため Firestore（エミュレータ含む）無しで実行できる。
//

@testable import Soramoyou
import XCTest

final class PostDocumentDecoderTests: XCTestCase {
    // MARK: - Helpers

    /// テスト用の偽ドキュメント（パスと中身だけを持つ）
    private struct FakeDocument: PostSourceDocument {
        let documentPath: String
        let fields: [String: Any]

        func data() -> [String: Any] { fields }
    }

    /// `Post(from:)` が受け付ける最小限の投稿ドキュメント
    private func validDocument(id: String) -> FakeDocument {
        FakeDocument(
            documentPath: "posts/\(id)",
            fields: [
                "postId": id,
                "userId": "u1",
                "images": [[String: Any]](),
            ]
        )
    }

    // MARK: - 壊れたドキュメントのスキップ

    /// 必須項目（userId）が欠けた 1 件だけを飛ばし、前後の投稿は順番どおり返すこと
    ///
    /// Android 版など別クライアントが必須項目を欠いた投稿を 1 件書いても、
    /// フィードのそのページ全体が表示されなくなってはいけない。
    func testSkipsDocumentMissingRequiredFieldsAndReturnsOthers() {
        let documents = [
            validDocument(id: "p1"),
            FakeDocument(
                documentPath: "posts/broken",
                fields: ["postId": "broken", "images": [[String: Any]]()]
            ),
            validDocument(id: "p3"),
        ]
        var failures: [PostDocumentDecoder.Failure] = []

        let posts = PostDocumentDecoder.decodePosts(documents, source: "test_feed") {
            failures.append($0)
        }

        XCTAssertEqual(posts.map(\.id), ["p1", "p3"])
        // 壊れたドキュメントを後から探せるよう、パスと取得経路が記録されていること
        XCTAssertEqual(failures.map(\.path), ["posts/broken"])
        XCTAssertEqual(failures.first?.source, "test_feed")
    }

    /// images が配列でない 1 件も同じく飛ばすこと
    func testSkipsDocumentWithInvalidImages() {
        let documents = [
            FakeDocument(
                documentPath: "posts/bad-images",
                fields: ["postId": "bad-images", "userId": "u1", "images": "not-an-array"]
            ),
            validDocument(id: "p2"),
        ]
        var failures: [PostDocumentDecoder.Failure] = []

        let posts = PostDocumentDecoder.decodePosts(documents, source: "test_feed") {
            failures.append($0)
        }

        XCTAssertEqual(posts.map(\.id), ["p2"])
        XCTAssertEqual(failures.map(\.path), ["posts/bad-images"])
    }

    // MARK: - 正常系

    /// すべて正常なら全件返し、失敗は記録しないこと
    func testReturnsAllPostsWhenEveryDocumentIsValid() {
        let documents = [validDocument(id: "p1"), validDocument(id: "p2")]
        var failures: [PostDocumentDecoder.Failure] = []

        let posts = PostDocumentDecoder.decodePosts(documents, source: "test_feed") {
            failures.append($0)
        }

        XCTAssertEqual(posts.map(\.id), ["p1", "p2"])
        XCTAssertTrue(failures.isEmpty)
    }

    /// ドキュメントが 0 件なら空配列を返すこと
    func testReturnsEmptyForNoDocuments() {
        var failures: [PostDocumentDecoder.Failure] = []

        let posts = PostDocumentDecoder.decodePosts([FakeDocument](), source: "test_feed") {
            failures.append($0)
        }

        XCTAssertTrue(posts.isEmpty)
        XCTAssertTrue(failures.isEmpty)
    }
}
