//
//  AppLocalizationTests.swift
//  SoramoyouTests
//
//  アプリが「日本語に対応している」と iOS に申告できているかの検証 ⭐️
//
//  申告が無いと、日本語の端末でも iOS に作らせる文字（日付など）が英語になる
//  （「8 hours ago」「5 minutes ago」#165 / #168）。
//

@testable import Soramoyou
import XCTest

final class AppLocalizationTests: XCTestCase {
    /// 日本語の端末では、アプリが日本語として動く
    ///
    /// ⚠️ 日本語の端末（言語 ja-JP）で走らせたときだけ意味がある。
    /// 英語の端末だと直す前も後も "en" になり区別がつかないので、そのときは飛ばす
    func testAppRunsInJapaneseOnJapaneseDevice() throws {
        try XCTSkipUnless(
            Locale.preferredLanguages.first?.hasPrefix("ja") == true,
            "端末の言語が日本語でない: \(Locale.preferredLanguages)"
        )
        XCTAssertEqual(Bundle.main.preferredLocalizations.first, "ja", "実際: \(Bundle.main.preferredLocalizations)")
        XCTAssertEqual(Locale.current.language.languageCode?.identifier, "ja", "実際: \(Locale.current.identifier)")
    }

    /// 日本語を好む人には日本語が選ばれる（端末の言語に頼らずに、選ぶ仕組みそのものを確かめる）
    func testJapaneseIsChosenForJapanesePreference() {
        let chosen = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: ["ja-JP", "en"])
        XCTAssertEqual(chosen.first, "ja", "対応言語: \(Bundle.main.localizations)")
    }

    /// 英語の端末では、今までどおり英語のまま
    func testEnglishIsChosenForEnglishPreference() {
        let chosen = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: ["en-US"])
        XCTAssertEqual(chosen.first, "en", "対応言語: \(Bundle.main.localizations)")
    }

    /// ウィジェットも日本語に対応している
    /// （ウィジェットは本体と別の入れ物なので、本体とは別に申告が要る）
    func testWidgetDeclaresJapanese() throws {
        let url = try XCTUnwrap(Bundle.main.builtInPlugInsURL?.appendingPathComponent("SoramoyouWidgetExtension.appex"))
        let widget = try XCTUnwrap(Bundle(url: url))
        XCTAssertTrue(widget.localizations.contains("ja"), "実際: \(widget.localizations)")
    }
}
