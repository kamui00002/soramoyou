//
//  ShareHashtagSuggesterTests.swift
//  SoramoyouTests
//
//  空カード共有パック ⭐️: ハッシュタグ提案（純関数）のテスト。
//

import XCTest
@testable import Soramoyou

final class ShareHashtagSuggesterTests: XCTestCase {

    // MARK: - 全て nil

    func testAllNilReturnsOnlyCommonTags() {
        let tags = ShareHashtagSuggester.suggest(skyType: nil, timeOfDay: nil, mood: nil)
        XCTAssertEqual(tags, ["イマソラ", "そらもよう"])
    }

    // MARK: - 個別マッピング

    func testSunsetSkyTypeIncludesExpectedTagFirst() {
        let tags = ShareHashtagSuggester.suggest(skyType: .sunset, timeOfDay: nil, mood: nil)
        XCTAssertEqual(tags.first, "夕焼け")
        XCTAssertTrue(tags.contains("イマソラ"))
        XCTAssertTrue(tags.contains("そらもよう"))
    }

    func testMorningTimeOfDayIncludesAsayake() {
        let tags = ShareHashtagSuggester.suggest(skyType: nil, timeOfDay: .morning, mood: nil)
        XCTAssertTrue(tags.contains("朝焼け"))
    }

    func testMoodIncludesExpectedTag() {
        let tags = ShareHashtagSuggester.suggest(skyType: nil, timeOfDay: nil, mood: .dreamy)
        XCTAssertTrue(tags.contains("夢見心地"))
    }

    // MARK: - 重複排除

    func testDuplicateAcrossSkyTypeAndTimeOfDayIsDeduplicated() {
        // skyType=.sunrise と timeOfDay=.morning はどちらも「朝焼け」にマップされる
        let tags = ShareHashtagSuggester.suggest(skyType: .sunrise, timeOfDay: .morning, mood: nil)
        XCTAssertEqual(tags.filter { $0 == "朝焼け" }.count, 1)
        XCTAssertEqual(tags, ["朝焼け", "イマソラ", "そらもよう"])
    }

    // MARK: - 5個上限

    func testAllThreePresentNoOverlapReturnsFiveUniqueTags() {
        let tags = ShareHashtagSuggester.suggest(skyType: .clear, timeOfDay: .night, mood: .dreamy)
        XCTAssertEqual(tags.count, 5)
        XCTAssertEqual(Set(tags).count, tags.count, "重複があってはならない")
    }

    func testNeverExceedsFiveTagsForAnyCombination() {
        for skyType in SkyType.allCases {
            for timeOfDay in TimeOfDay.allCases {
                for mood in Mood.allCases {
                    let tags = ShareHashtagSuggester.suggest(skyType: skyType, timeOfDay: timeOfDay, mood: mood)
                    XCTAssertLessThanOrEqual(tags.count, 5)
                    XCTAssertEqual(Set(tags).count, tags.count, "重複があってはならない")
                }
            }
        }
    }

    // MARK: - 共通タグは常に含まれる

    func testCommonTagsAlwaysPresent() {
        let tags = ShareHashtagSuggester.suggest(skyType: .storm, timeOfDay: .afternoon, mood: .dignified)
        XCTAssertTrue(tags.contains("イマソラ"))
        XCTAssertTrue(tags.contains("そらもよう"))
    }

    // MARK: - "#" を含まない

    func testTagsDoNotContainHashPrefix() {
        let tags = ShareHashtagSuggester.suggest(skyType: .sunset, timeOfDay: .evening, mood: .wistful)
        for tag in tags {
            XCTAssertFalse(tag.hasPrefix("#"), "生の単語のみを返し、\"#\" は呼び出し側で付与する")
        }
    }
}
