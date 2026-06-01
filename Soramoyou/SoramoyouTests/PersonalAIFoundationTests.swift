//
//  PersonalAIFoundationTests.swift
//  SoramoyouTests
//
//  増分1（土台モデル）の回帰テスト:
//  - Post への attachedRecipe(editRecipeV1) 追加の round-trip と後方互換
//  - RecipeCorpusStore のローカル永続化（追記・容量上限・ユーザー分離・削除）
//
//  既存テストに合わせ XCTest を使用（@testable import で内部 API へアクセス）。
//

import XCTest
@testable import Soramoyou

final class PersonalAIFoundationTests: XCTestCase {

    // MARK: - Helpers

    /// 識別しやすい値を持つレシピを作る（round-trip 検証用）
    private func makeDistinctRecipe() -> EditRecipe {
        var r = EditRecipe()
        r.exposureEV = 1.5
        r.saturationCI = 1.3
        r.contrastCI = 1.2
        r.warmthNorm = 0.4
        r.clarityNorm = -0.2
        return r
    }

    // MARK: - Post: attachedRecipe(editRecipeV1) round-trip

    func testPostRoundTripPreservesAttachedRecipe() throws {
        // Arrange: レシピ添付つきの投稿
        let recipe = makeDistinctRecipe()
        let post = Post(id: "p1", userId: "u1", images: [], attachedRecipe: recipe)

        // Act: Firestore 辞書 → 復元
        let data = post.toFirestoreData()
        let restored = try Post(from: data)

        // Assert: editRecipeV1 が辞書に含まれ、主要パラメータが保たれる
        XCTAssertNotNil(data["editRecipeV1"], "editRecipeV1 が保存辞書に含まれるべき")
        let rr = try XCTUnwrap(restored.attachedRecipe, "復元後も attachedRecipe が存在するべき")
        XCTAssertEqual(rr.exposureEV, 1.5, accuracy: 0.0001)
        XCTAssertEqual(rr.saturationCI, 1.3, accuracy: 0.0001)
        XCTAssertEqual(rr.contrastCI, 1.2, accuracy: 0.0001)
        XCTAssertEqual(rr.warmthNorm ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(rr.clarityNorm ?? 0, -0.2, accuracy: 0.0001)
    }

    func testPostToFirestoreOmitsRecipeKeyWhenNil() {
        // attachedRecipe 無しのとき editRecipeV1 キーを書かない（無駄なフィールドを増やさない）
        let post = Post(id: "p2", userId: "u1", images: [])
        let data = post.toFirestoreData()
        XCTAssertNil(data["editRecipeV1"], "レシピ未添付なら editRecipeV1 は書かれない")
    }

    func testPostBackwardCompatWithoutRecipe() throws {
        // editRecipeV1 を持たない旧投稿データでも問題なく復元でき、attachedRecipe は nil
        let legacyData: [String: Any] = [
            "postId": "p3",
            "userId": "u1",
            "images": [[String: Any]]()
        ]
        let restored = try Post(from: legacyData)
        XCTAssertNil(restored.attachedRecipe, "editRecipeV1 が無い旧投稿は attachedRecipe = nil")
        XCTAssertEqual(restored.id, "p3")
    }

    // MARK: - RecipeCorpusStore

    /// テスト専用の一時ディレクトリに紐づくストアを作る
    private func makeTempStore(capacity: Int = 300) -> (RecipeCorpusStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-test-\(UUID().uuidString)", isDirectory: true)
        let store = RecipeCorpusStore(baseDirectory: tmp, capacity: capacity)
        return (store, tmp)
    }

    private func removeTemp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func testCorpusAppendAndRead() {
        let (store, tmp) = makeTempStore()
        defer { removeTemp(tmp) }

        let entry = RecipeCorpusEntry(recipe: makeDistinctRecipe(), skyType: .sunset)
        store.append(entry, userId: "u1")

        let read = store.entries(userId: "u1")
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.skyType, .sunset)
        XCTAssertEqual(read.first?.recipe.exposureEV ?? 0, 1.5, accuracy: 0.0001)
    }

    func testCorpusEmptyWhenMissing() {
        let (store, tmp) = makeTempStore()
        defer { removeTemp(tmp) }
        XCTAssertEqual(store.entries(userId: "never-saved").count, 0)
    }

    func testCorpusCapacityTrimKeepsNewest() {
        let (store, tmp) = makeTempStore(capacity: 3)
        defer { removeTemp(tmp) }

        // 5 件追記 → 直近 3 件のみ残る
        for i in 0..<5 {
            var r = EditRecipe()
            r.exposureEV = Double(i)  // 0,1,2,3,4
            store.append(RecipeCorpusEntry(recipe: r, skyType: .clear), userId: "u1")
        }

        let read = store.entries(userId: "u1")
        XCTAssertEqual(read.count, 3, "容量 3 を超えた分は古い順に破棄される")
        XCTAssertEqual(read.map { $0.recipe.exposureEV }, [2, 3, 4], "直近 3 件（新しい順序で末尾）が残る")
    }

    func testCorpusPerUserIsolation() {
        let (store, tmp) = makeTempStore()
        defer { removeTemp(tmp) }

        store.append(RecipeCorpusEntry(recipe: EditRecipe(), skyType: .clear), userId: "alice")
        store.append(RecipeCorpusEntry(recipe: EditRecipe(), skyType: .storm), userId: "bob")
        store.append(RecipeCorpusEntry(recipe: EditRecipe(), skyType: .storm), userId: "bob")

        XCTAssertEqual(store.entries(userId: "alice").count, 1)
        XCTAssertEqual(store.entries(userId: "bob").count, 2)
    }

    func testCorpusClear() {
        let (store, tmp) = makeTempStore()
        defer { removeTemp(tmp) }

        store.append(RecipeCorpusEntry(recipe: EditRecipe(), skyType: .clear), userId: "u1")
        XCTAssertEqual(store.entries(userId: "u1").count, 1)

        store.clear(userId: "u1")
        XCTAssertEqual(store.entries(userId: "u1").count, 0)
    }
}
