//
//  SoratomoGuidelineTests.swift
//  SoramoyouTests
//
//  そらともガイドライン（SoratomoGuideline）のテスト ⭐️（release-gate 8・9.5）
//  - 版の固定（サーバーの GUIDELINE_VERSION と同じ）
//  - 本文の 4 つの節の語句（要件 10.13）
//  - 同意済みの判定（アプリの版以上）と、入口の判定（要件 10.2）
//

@testable import Soramoyou
import XCTest

final class SoratomoGuidelineTests: XCTestCase {
    func testCurrentVersionMatchesServer() {
        // ⚠️ functions/soratomoCore.test.js の「GUIDELINE_VERSION は 1」と同じ値に固定する。
        //    片方だけ上げると、同意しても outdated_guideline で拒否され続けるか、古いアプリだと誤って案内する
        XCTAssertEqual(SoratomoGuideline.currentVersion, 1)
    }

    // MARK: - 本文（release-gate 9.5・要件 10.13）

    /// 本文の 4 つの節のすべて（見出しと本文をつないだもの）
    private var sectionTexts: [String] {
        SoratomoGuideline.sections.map { $0.title + $0.body }
    }

    /// ⭐️ 4 つの節の語句が、それぞれ別の節にある
    ///
    /// 審査ガイドライン 1.2 が求める 4 つ（不快なものを許容しない・違反への対応・通報とブロック・連絡先）。
    /// 文案を直すときも、この語句は残すこと。
    func testSectionsContainFourRequiredTopics() {
        let required: [(topic: String, phrases: [String])] = [
            ("許容しない", ["不快なコンテンツ", "迷惑行為", "許容しません"]),
            ("違反への対応", ["違反", "開発者", "削除", "利用を停止"]),
            ("通報とブロック", ["通報", "ブロック", "長押し", "「…」"]),
            ("連絡先", ["お問い合わせ", "soramoyou.app@gmail.com"]),
        ]
        XCTAssertEqual(SoratomoGuideline.sections.count, 4)
        var usedSections = Set<Int>()
        for (topic, phrases) in required {
            let index = sectionTexts.firstIndex { text in phrases.allSatisfy { text.contains($0) } }
            XCTAssertNotNil(index, "「\(topic)」の語句 \(phrases) をすべて含む節が無い")
            if let index {
                XCTAssertFalse(usedSections.contains(index), "「\(topic)」がほかの話題と同じ節にある")
                usedSections.insert(index)
            }
        }
    }

    /// 連絡先は設定の「お問い合わせ」と同じメールアドレス
    func testContactEmailMatchesSettings() {
        XCTAssertEqual(SoratomoGuideline.contactEmail, "soramoyou.app@gmail.com")
    }

    // MARK: - 同意済みの判定

    /// アプリの版以上に同意していれば同意済み（新しい版で同意した人を古いアプリで止めない）
    func testHasAgreedCurrentWhenAgreedVersionIsAtLeastAppVersion() {
        let app = SoratomoGuideline.currentVersion
        XCTAssertTrue(SoratomoConsentStatus(agreedVersion: app, groupCount: 1).hasAgreedCurrent)
        XCTAssertTrue(SoratomoConsentStatus(agreedVersion: app + 1, groupCount: 1).hasAgreedCurrent)
        XCTAssertFalse(SoratomoConsentStatus(agreedVersion: app - 1, groupCount: 1).hasAgreedCurrent)
        XCTAssertFalse(SoratomoConsentStatus(agreedVersion: nil, groupCount: 1).hasAgreedCurrent)
    }

    // MARK: - 入口の判定（要件 10.2）

    /// ⭐️ 全文を出すのは「未同意で所属あり」だけ
    func testEntryGateShowsGuidelineOnlyWhenNotAgreedAndHasGroups() {
        let app = SoratomoGuideline.currentVersion
        let cases: [(String, SoratomoConsentStatus?, Bool)] = [
            ("同意済み", SoratomoConsentStatus(agreedVersion: app, groupCount: 2), false),
            ("未同意で所属あり", SoratomoConsentStatus(agreedVersion: nil, groupCount: 1), true),
            ("古い版に同意で所属あり", SoratomoConsentStatus(agreedVersion: app - 1, groupCount: 3), true),
            ("未同意で所属なし", SoratomoConsentStatus(agreedVersion: nil, groupCount: 0), false),
            ("読めない", nil, false),
        ]
        for (label, status, expected) in cases {
            XCTAssertEqual(SoratomoEntryGate.needsGuideline(status: status), expected, label)
        }
    }
}
