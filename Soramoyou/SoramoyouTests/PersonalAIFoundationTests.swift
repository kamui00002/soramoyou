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
        r.appliedFilter = .vivid
        r.cropRectNorm = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
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

    // MARK: - EditRecipe.isNeutral（未編集ゲート / G1修正）

    func testIsNeutralForDefaultRecipe() {
        XCTAssertTrue(EditRecipe().isNeutral, "デフォルト（未編集）は中立")
    }

    func testIsNeutralFalseWhenEdited() {
        var r = EditRecipe()
        r.exposureEV = 0.5
        XCTAssertFalse(r.isNeutral, "編集があれば非中立")
    }

    func testIsNeutralIgnoresMetadata() {
        var r = EditRecipe()
        r.createdAt = Date()
        r.lastModifiedAt = Date()
        r.schemaVersion = 99
        XCTAssertTrue(r.isNeutral, "タイムスタンプ/バージョンの差は中立判定に影響しない")
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

        // Codable(JSON, iso8601)往復で各種フィールドが保たれることを検証（物理/正規化/enum/CGRect）
        let recipe = read.first?.recipe
        XCTAssertEqual(recipe?.exposureEV ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(recipe?.warmthNorm ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(recipe?.clarityNorm ?? 0, -0.2, accuracy: 0.0001)
        XCTAssertEqual(recipe?.appliedFilter, .vivid, "フィルター(enum)が往復で保たれる")
        XCTAssertEqual(recipe?.cropRectNorm, CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), "cropRectNorm(CGRect)が往復で保たれる")
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

    // MARK: - PersonalRecipeProfile.representative()（欠陥修正の回帰テスト）
    //
    // 実バグ（使ったことのないドラマフィルターが提案される・直近の編集が反映されない）の
    // 確定原因3件の修正を検証する:
    // 1. mostCommonFilter が compactMap で「フィルターなし」の多数派票を捨てていた
    // 2. averageOptional が「一度でも使った項目」を常に提案してしまっていた
    // 3. savedAt を使った新しさによる重み付けが未実装だった

    /// representative() 検証用エントリ生成。`minutesAgo` が小さいほど新しい（savedAt が現在に近い）。
    private func personalRecipeEntry(
        exposure: Double = 0,
        filter: FilterType? = nil,
        vignette: Double? = nil,
        sharpness: Double? = nil,
        sky: SkyType? = nil,
        minutesAgo: Double
    ) -> RecipeCorpusEntry {
        var r = EditRecipe()
        r.exposureEV = exposure
        r.appliedFilter = filter
        r.vignetteNorm = vignette
        r.sharpnessNorm = sharpness
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-minutesAgo * 60)
        return RecipeCorpusEntry(recipe: r, skyType: sky, savedAt: savedAt)
    }

    func test_representative_majorityNoFilter_returnsNilFilter() throws {
        // バグ再現: 5件中4件は最近フィルターなしで編集、1件だけ100分前に .drama を使った。
        // 旧実装は appliedFilter を compactMap してから最頻値を取るため「なし」票が消え、
        // 1件しかない .drama が最頻扱いになっていた。
        let entries = [
            personalRecipeEntry(filter: .drama, minutesAgo: 100),
            personalRecipeEntry(filter: nil, minutesAgo: 30),
            personalRecipeEntry(filter: nil, minutesAgo: 20),
            personalRecipeEntry(filter: nil, minutesAgo: 10),
            personalRecipeEntry(filter: nil, minutesAgo: 0)
        ]
        let result = try XCTUnwrap(
            PersonalRecipeProfile.representative(for: nil, from: entries, minimumSamples: 3)
        )
        XCTAssertNil(result.appliedFilter, "多数派の『フィルターなし』が定番として選ばれるべき（compactMap投票バグの再現テスト）")
    }

    func test_representative_majorityFilter_wins() throws {
        // 5件中3件（かつより新しい）が .natural、2件（より古い）がフィルターなし → .natural が定番。
        let entries = [
            personalRecipeEntry(filter: .natural, minutesAgo: 20),
            personalRecipeEntry(filter: .natural, minutesAgo: 10),
            personalRecipeEntry(filter: .natural, minutesAgo: 0),
            personalRecipeEntry(filter: nil, minutesAgo: 40),
            personalRecipeEntry(filter: nil, minutesAgo: 30)
        ]
        let result = try XCTUnwrap(
            PersonalRecipeProfile.representative(for: nil, from: entries, minimumSamples: 3)
        )
        XCTAssertEqual(result.appliedFilter, .natural, "多数派のフィルターが定番として選ばれる")
    }

    func test_representative_rarelyUsedOptional_notAdopted() throws {
        // 5件中1件だけ vignetteNorm を設定 → 重み付き使用率が閾値(50%)を超えないため nil のまま。
        let entries = [
            personalRecipeEntry(vignette: 0.8, minutesAgo: 0),
            personalRecipeEntry(minutesAgo: 10),
            personalRecipeEntry(minutesAgo: 20),
            personalRecipeEntry(minutesAgo: 30),
            personalRecipeEntry(minutesAgo: 40)
        ]
        let result = try XCTUnwrap(
            PersonalRecipeProfile.representative(for: nil, from: entries, minimumSamples: 3)
        )
        XCTAssertNil(result.vignetteNorm, "一度だけ使った項目は使用率不足のため提案しない（欠陥2の再現テスト）")
    }

    func test_representative_frequentOptional_adopted() throws {
        // 5件中4件（新しい順）で sharpnessNorm を設定 → 重み付き使用率が閾値を超え採用される。
        let entries = [
            personalRecipeEntry(sharpness: 0.2, minutesAgo: 0),
            personalRecipeEntry(sharpness: 0.4, minutesAgo: 10),
            personalRecipeEntry(sharpness: 0.6, minutesAgo: 20),
            personalRecipeEntry(sharpness: 0.8, minutesAgo: 30),
            personalRecipeEntry(minutesAgo: 40)
        ]
        let result = try XCTUnwrap(
            PersonalRecipeProfile.representative(for: nil, from: entries, minimumSamples: 3)
        )
        // 使用率 ≈ 87.8%（重み付き）> 50% → 採用。値は savedAt の重み付き平均 ≈ 0.445。
        XCTAssertEqual(try XCTUnwrap(result.sharpnessNorm), 0.4449864498644987, accuracy: 0.0001)
    }

    func test_representative_recencyWeighting_favorsRecent() throws {
        // 古い5件は exposureEV=0.0、最新1件だけ exposureEV=1.0、decay=0.8。
        // 重み(0.8^i, i=新しい順の順位0〜5): 最新1.0, 以降 0.8,0.64,0.512,0.4096,0.32768（古い5件がこの並び）。
        // exposureEV = (1.0*1.0 + 0.0*(0.8+0.64+0.512+0.4096+0.32768)) / Σ(0.8^k, k=0..5)
        //            = 1.0 / 3.68928 = 3125/11529 ≈ 0.27105559892445136
        // 減衰係数の変質（例: 0.75 に変わる等）を確実に検出するため、閾値比較でなく理論値の厳密一致で検証する。
        let entries = [
            personalRecipeEntry(exposure: 1.0, minutesAgo: 0),
            personalRecipeEntry(exposure: 0.0, minutesAgo: 10),
            personalRecipeEntry(exposure: 0.0, minutesAgo: 20),
            personalRecipeEntry(exposure: 0.0, minutesAgo: 30),
            personalRecipeEntry(exposure: 0.0, minutesAgo: 40),
            personalRecipeEntry(exposure: 0.0, minutesAgo: 50)
        ]
        let result = try XCTUnwrap(
            PersonalRecipeProfile.representative(for: nil, from: entries, minimumSamples: 3)
        )
        XCTAssertEqual(result.exposureEV, 0.27105559892445136, accuracy: 0.0001, "直近の編集が定番へ強く反映される（欠陥3の修正・decay=0.8の理論値で厳密検証）")
    }
}
