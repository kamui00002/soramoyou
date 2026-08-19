//
//  TagFeedServiceTests.swift
//  SoramoyouTests
//
//  推定タグの頻度集計ロジック（純関数 HashtagFrequencyRanker）の単体テスト ⭐️
//  Firestore に触らないため、エミュレータ無しで実行できる。
//

@testable import Soramoyou
import XCTest

final class TagFeedServiceTests: XCTestCase {
    // MARK: - 基本の頻度集計

    /// 出現回数の多い順に並ぶこと
    func testTopTagsOrdersByFrequencyDescending() {
        let groups = [
            ["朝焼け", "雲"],
            ["朝焼け", "夕焼け"],
            ["朝焼け"],
            ["雲"],
        ]

        let result = HashtagFrequencyRanker.topTags(fromHashtagGroups: groups, topN: 10)

        // 朝焼け=3, 雲=2, 夕焼け=1
        XCTAssertEqual(result, ["朝焼け", "雲", "夕焼け"])
    }

    /// topN で件数が制限されること
    func testTopTagsRespectsTopN() {
        let groups = [
            ["a", "b", "c"],
            ["a", "b"],
            ["a"],
        ]

        let result = HashtagFrequencyRanker.topTags(fromHashtagGroups: groups, topN: 2)

        XCTAssertEqual(result, ["a", "b"])
    }

    /// topN が 0 以下なら空配列を返すこと
    func testTopTagsReturnsEmptyForNonPositiveTopN() {
        let groups = [["a"], ["a"]]

        XCTAssertEqual(HashtagFrequencyRanker.topTags(fromHashtagGroups: groups, topN: 0), [])
        XCTAssertEqual(HashtagFrequencyRanker.topTags(fromHashtagGroups: groups, topN: -1), [])
    }

    /// 投稿が無い場合は空配列
    func testTopTagsReturnsEmptyForNoGroups() {
        XCTAssertEqual(HashtagFrequencyRanker.topTags(fromHashtagGroups: [], topN: 5), [])
    }

    // MARK: - 同一投稿内の重複

    /// 同じ投稿の中で同じタグが繰り返されても 1 回として数えること
    ///
    /// 「#空 #空 #空」と書いた 1 投稿が、2 投稿で使われたタグより上位に来てはいけない。
    func testTopTagsCountsDuplicateTagWithinOnePostOnce() {
        let groups = [
            ["空", "空", "空"], // 空 = 1投稿ぶん
            ["雲"],
            ["雲"], // 雲 = 2投稿ぶん
        ]

        let result = HashtagFrequencyRanker.topTags(fromHashtagGroups: groups, topN: 10)

        XCTAssertEqual(result, ["雲", "空"])
    }

    // MARK: - 決定性（タイブレーク）

    /// 同数のタグはタグ名の昇順で安定して並ぶこと
    ///
    /// Swift の sorted(by:) は安定ソートではないため、タイブレークが無いと
    /// 実行のたびに順序が変わりテストが不定期に落ちる。
    func testTopTagsBreaksTiesByTagNameAscending() {
        let groups = [["banana"], ["apple"], ["cherry"]] // すべて 1 回ずつ

        // 複数回実行しても同じ順序であること
        for _ in 0 ..< 20 {
            let result = HashtagFrequencyRanker.topTags(fromHashtagGroups: groups, topN: 10)
            XCTAssertEqual(result, ["apple", "banana", "cherry"])
        }
    }

    // MARK: - 空文字・空白の除外

    /// 空文字・空白のみのタグは集計対象外
    func testTopTagsIgnoresEmptyAndWhitespaceTags() {
        let groups = [
            ["", "   ", "空"],
            ["\n", "空"],
        ]

        let result = HashtagFrequencyRanker.topTags(fromHashtagGroups: groups, topN: 10)

        XCTAssertEqual(result, ["空"])
    }

    // MARK: - 正規化しないこと

    /// 大文字小文字は別のタグとして扱うこと（正規化しない）
    ///
    /// ⚠️ Firestore の arrayContains は完全一致。ここで小文字化すると
    ///    フォロータグが既存投稿にマッチしなくなるため、絶対に正規化しない。
    func testTopTagsDoesNotNormalizeCase() {
        let groups = [
            ["Sky", "sky"],
            ["sky"],
        ]

        let result = HashtagFrequencyRanker.topTags(fromHashtagGroups: groups, topN: 10)

        // sky=2, Sky=1。統合されず別々に数えられる
        XCTAssertEqual(result, ["sky", "Sky"])
    }

    /// 全角・記号を含むタグもそのまま保持されること
    func testTopTagsPreservesRawTagString() {
        let groups = [["イマソラ"], ["イマソラ"], ["ｲﾏｿﾗ"]]

        let result = HashtagFrequencyRanker.topTags(fromHashtagGroups: groups, topN: 10)

        XCTAssertEqual(result, ["イマソラ", "ｲﾏｿﾗ"])
    }

    // MARK: - Post 配列からの集計

    /// Post 配列を渡すラッパーが hashtags を正しく拾うこと（nil は空扱い）
    func testTopTagsFromPostsUsesHashtagsAndTreatsNilAsEmpty() {
        let posts = [
            makePost(id: "1", hashtags: ["夕焼け", "雲"]),
            makePost(id: "2", hashtags: ["夕焼け"]),
            makePost(id: "3", hashtags: nil),
        ]

        let result = HashtagFrequencyRanker.topTags(from: posts, topN: 10)

        XCTAssertEqual(result, ["夕焼け", "雲"])
    }

    // MARK: - Helper

    /// テスト用の最小限の Post を作る
    private func makePost(id: String, hashtags: [String]?) -> Post {
        Post(
            id: id,
            userId: "user-\(id)",
            images: [ImageInfo(url: "https://example.com/\(id).jpg", width: 100, height: 100, order: 0)],
            hashtags: hashtags
        )
    }
}
