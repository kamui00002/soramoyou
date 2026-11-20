// ⭐️ 画面の文言（strings.xml）の用語を iOS 版の表示名に固定する単体テスト（タスク 5.2・要件 16.1）
package com.yoshidometoru.soramoyou.ui

import com.yoshidometoru.soramoyou.contract.model.FeedbackCategory
import com.yoshidometoru.soramoyou.contract.model.FilterId
import com.yoshidometoru.soramoyou.contract.model.ReportReason
import com.yoshidometoru.soramoyou.contract.model.SkyType
import com.yoshidometoru.soramoyou.contract.model.TimeOfDay
import com.yoshidometoru.soramoyou.contract.model.Visibility
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * 公開範囲・時間帯・空の種類・フィルター・通報理由・フィードバックの種別の用語は、iOS 版の表示名と 1 文字も違えない（要件 16.1）。
 * 違うと、同じものが OS ごとに違う言葉で見える。期待値はテストに直書きせず、iOS 版のソースを毎回読んで突き合わせる
 * （iOS 側で表示名を変えたら、ここで気づく。ただし読むのはこの枝に取り込んだ iOS のソース〔[UiTextSources.iosSourceRoot]〕で、
 * 出荷中の iOS〔origin/main〕の変更には、main を取り込んでから流すまで気づかない＝tasks.md の 37・39）。
 *
 * 用語のリソース名は `term_<種類>_<iOS の文字列値>` とする。種類ごとに、iOS の全ての case が揃っていることと、
 * iOS に無い値のリソースが残っていないことの両方を確かめる。
 *
 * 根拠（読んだ現物。行番号は 2026-10-04 時点）:
 * - Soramoyou/Soramoyou/Models/Visibility.swift:17-23・TimeOfDay.swift:17-25・SkyType.swift:18-27
 * - Soramoyou/Soramoyou/Models/FilterType.swift:24-37・ReportReason.swift:19-32・Feedback.swift:22-28（FeedbackCategory）
 * - 共通の状態表示: Views/Components/LoadingStateView.swift:23・ErrorStateView.swift:39, 45, 183・AsyncContentView.swift:84
 */
class UiStringsTest {

    private val strings = UiTextSources.readStrings()

    /** iOS の enum の表示名と、`term_<prefix>_` のリソースが、過不足なく一致することを確かめる。 */
    private fun assertTermsMatchIos(swiftPath: String, enumName: String, prefix: String) {
        val ios = UiTextSources.readEnumDisplayNames(UiTextSources.iosSource(swiftPath), enumName)
        val resources = strings
            .filterKeys { it.startsWith("term_${prefix}_") }
            .mapKeys { (name, _) -> name.removePrefix("term_${prefix}_") }

        assertEquals(ios, resources, "strings.xml の term_${prefix}_* が iOS 版の $enumName.displayName と一致しない")
    }

    @Test
    fun `公開範囲の用語はiOSの表示名と一致する`() {
        assertTermsMatchIos("Models/Visibility.swift", "Visibility", "visibility")
    }

    @Test
    fun `時間帯の用語はiOSの表示名と一致する`() {
        assertTermsMatchIos("Models/TimeOfDay.swift", "TimeOfDay", "time_of_day")
    }

    @Test
    fun `空の種類の用語はiOSの表示名と一致する`() {
        assertTermsMatchIos("Models/SkyType.swift", "SkyType", "sky_type")
    }

    @Test
    fun `フィルターの用語はiOSの表示名と一致する`() {
        // MVP で出すのは 6 種と「なし」だけ（設計書 Q2）だが、用語は iOS の全 10 種を機械的に揃えておく
        assertTermsMatchIos("Models/FilterType.swift", "FilterType", "filter")
    }

    @Test
    fun `通報理由の用語はiOSの表示名と一致する`() {
        assertTermsMatchIos("Models/ReportReason.swift", "ReportReason", "report_reason")
    }

    @Test
    fun `フィードバックの種別の用語はiOSの表示名と一致する`() {
        // Feedback.swift には FeedbackCategory と Feedback の 2 つの型がある。読むのは FeedbackCategory だけ
        assertTermsMatchIos("Models/Feedback.swift", "FeedbackCategory", "feedback_category")
    }

    @Test
    fun `契約モジュールの表示名と画面の用語のリソースは一致する`() {
        // 公開範囲・時間帯・空の種類は、:contract の displayName（タスク 3.2）にも同じ用語がある。フィルターも同じ（タスク 20.3。
        // :contract には MVP で出す 6 種だけがある）。通報理由も同じ（タスク 28 で :contract に置き、29.2 で通報の選択肢に displayName を出す）。
        // フィードバックの種別も同じ（タスク 28 で :contract に置き、30 でフィードバックの選択肢に displayName を出す）。
        // 2 か所に持つので、どちらを画面に出しても同じ言葉になることをここで固定する
        val pairs = Visibility.entries.map { "term_visibility_${it.raw}" to it.displayName } +
            TimeOfDay.entries.map { "term_time_of_day_${it.raw}" to it.displayName } +
            SkyType.entries.map { "term_sky_type_${it.raw}" to it.displayName } +
            FilterId.entries.map { "term_filter_${it.raw}" to it.displayName } +
            ReportReason.entries.map { "term_report_reason_${it.raw}" to it.displayName } +
            FeedbackCategory.entries.map { "term_feedback_category_${it.raw}" to it.displayName }

        pairs.forEach { (name, displayName) ->
            assertEquals(displayName, strings[name], "strings.xml の $name が :contract の displayName と一致しない")
        }
    }

    @Test
    fun `共通の状態表示の文言はiOSの同じ場面の文言と一致する`() {
        val errorTitles = UiTextSources.switchReturns(UiTextSources.iosSource("Views/Components/ErrorStateView.swift"), "title")
        val loadingMessages = UiTextSources.switchReturns(UiTextSources.iosSource("Views/Components/LoadingStateView.swift"), "message")
        val retry = assertNotNull(
            Regex("""isRetrying\s*\?\s*"[^"]*"\s*:\s*"([^"]*)"""")
                .find(UiTextSources.iosSource("Views/Components/ErrorStateView.swift"))?.groupValues?.get(1),
            "iOS 版の再試行ボタンの文言が見つからない（書き方が変わった可能性）",
        )
        val emptyTitle = assertNotNull(
            Regex("""icon:\s*"tray",\s*title:\s*"([^"]*)"""")
                .find(UiTextSources.iosSource("Views/Components/AsyncContentView.swift"))?.groupValues?.get(1),
            "iOS 版の既定の 0 件の見出しが見つからない（書き方が変わった可能性）",
        )

        val expected = mapOf(
            "state_loading" to loadingMessages["initial"],
            "state_empty_title" to emptyTitle,
            "state_error_title" to errorTitles["unknown"],
            "offline_title" to errorTitles["network"],
            "action_retry" to retry,
        )
        expected.forEach { (name, ios) ->
            assertNotNull(ios, "$name に対応する iOS の文言が読めない")
            assertEquals(ios, strings[name], "strings.xml の $name が iOS 版の文言と一致しない")
        }
    }

    @Test
    fun `Swiftの読み出しは改行をはさむreturnと値の無いcaseと同じファイルの別の型を正しく扱う`() {
        // 読み出し器そのものの陽性対照。iOS の 6 ファイルにある書き方を 1 つにまとめた
        val source = """
            enum Other: String {
                case bug = "other_bug"
                var displayName: String {
                    switch self {
                    case .bug: return "別の型"
                    }
                }
            }

            enum Sample: String, CaseIterable {
                case `public` = "public"
                case bug      // 不具合
                case multi = "multi_raw"

                var id: String { rawValue }

                /// 表示名
                var displayName: String {
                    switch self {
                    case .public: return "公開"
                    case .bug: return "不具合"
                    case .multi:
                        return "改行のあと"
                    }
                }

                var iconName: String {
                    switch self {
                    case .public: return "globe"
                    case .bug: return "ant"
                    case .multi: return "square"
                    }
                }
            }
        """.trimIndent()

        assertEquals(
            mapOf("public" to "公開", "bug" to "不具合", "multi_raw" to "改行のあと"),
            UiTextSources.readEnumDisplayNames(source, "Sample"),
        )
    }

    @Test
    fun `Swiftの読み出しはreturnを省いた分岐とreturnのある分岐を同じに読み、次のvarの分岐は読まない`() {
        // 読み出し器そのものの陽性対照（2026-11-06 に main を取り込んだら、iOS の 3 ファイルが return を省く書き方になっていた）。
        // return を省いた形・改行をはさんで省いた形・return のある形を 1 つの switch に混ぜる
        val source = """
            enum Sample: String {
                case `public` = "public"
                case bug
                case multi = "multi_raw"

                var displayName: String {
                    switch self {
                    case .public: "公開"
                    case .bug: return "不具合"
                    case .multi:
                        "改行のあと"
                    }
                }

                var note: String? {
                    switch self {
                    case .public: "説明"
                    case .bug, .multi: nil
                    }
                }
            }
        """.trimIndent()

        assertEquals(
            mapOf("public" to "公開", "bug" to "不具合", "multi_raw" to "改行のあと"),
            UiTextSources.readEnumDisplayNames(source, "Sample"),
        )
        assertEquals(mapOf("public" to "説明"), UiTextSources.switchReturns(source, "note"))
    }

    @Test
    fun `Swiftの読み出しはcaseの宣言と表示名の分岐が食い違えば失敗する`() {
        // 表示名を読み落としたときに、空や一部だけの対応で「一致した」としないこと
        val source = """
            enum Broken: String {
                case a = "a"
                case b = "b"
                var displayName: String {
                    switch self {
                    case .a: return "エー"
                    default: return "ほか"
                    }
                }
            }
        """.trimIndent()

        val error = assertFailsWith<IllegalStateException> { UiTextSources.readEnumDisplayNames(source, "Broken") }
        assertTrue("一致しない" in error.message.orEmpty(), "想定外の失敗: ${error.message}")
    }
}
