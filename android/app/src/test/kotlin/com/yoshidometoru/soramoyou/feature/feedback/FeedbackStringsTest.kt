// ⭐️ フィードバックの文言と送る値の形を iOS 版と 1 文字も違えないことの単体テスト（タスク 30・要件 13.1・13.2・16.1）
package com.yoshidometoru.soramoyou.feature.feedback

import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.ui.UiTextSources
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * iOS のフィードバックの画面（FeedbackView）・設定の項目（SettingsView）・本文の範囲の案内（FeedbackViewModel）の文言が、
 * Android の strings.xml と同じ書き方で現れることを確かめる（ModerationStringsTest と同じ考え方。期待値は strings.xml から取る）。
 * 種別の選択肢は :contract の FeedbackCategory.displayName で、iOS の表示名との一致は UiStringsTest が確かめる。
 * 送るアプリのバージョンと端末情報の形、ドキュメント ID が大文字の UUID であることも、iOS のソースの書き方で固定する。
 */
class FeedbackStringsTest {

    private val strings = UiTextSources.readStrings()

    /** リソース名 → 文言を %s に置いた iOS の書き方（Views/FeedbackView.swift）。 */
    private val viewExpectations = listOf(
        "feedback_title" to ".navigationTitle(\"%s\")",
        "feedback_intro" to "Text(\"%s\")",
        "feedback_category_label" to "Text(\"%s\")",
        "feedback_category_label" to "Picker(\"%s\", selection:",
        "feedback_message_label" to "Text(\"%s\")",
        "feedback_message_hint" to "TextField(\"%s\",",
        "feedback_send" to "Text(\"%s\")",
        "feedback_done_title" to "Text(\"%s\")",
        "feedback_done_message" to "Text(\"%s\")",
        "action_close" to "Button(\"%s\") { dismiss() }",
        "action_close" to "Text(\"%s\")",
    )

    @Test
    fun `フィードバック画面の文言は、iOSのFeedbackViewと同じ`() {
        UiTextSources.assertIosHasStrings(viewExpectations, "Views/FeedbackView.swift")
    }

    @Test
    fun `設定の項目の名前は、iOSの設定の「ご意見・ご要望」と同じ`() {
        val value = assertNotNull(strings["feedback_title"], "strings.xml に feedback_title が無い")
        val source = UiTextSources.iosSource("Views/SettingsView.swift")
        assertTrue("title: \"$value\"," in source, "iOS の SettingsView.swift に title: \"$value\" が無い")
    }

    @Test
    fun `本文の範囲の案内は、iOSと同じ文言で、上限はAndroidの上限と同じ`() {
        val source = UiTextSources.iosSource("ViewModels/FeedbackViewModel.swift")
        val value = assertNotNull(strings["feedback_message_range"], "strings.xml に feedback_message_range が無い")
        // iOS は上限を maxLength で埋め込む。埋め込む値が Android の上限（TextLimits.FEEDBACK_MAX）と同じであることも確かめる
        assertTrue("let maxLength = ${TextLimits.FEEDBACK_MAX}" in source, "iOS の maxLength が ${TextLimits.FEEDBACK_MAX} でない")
        val expected = "errorMessage = \"${value.replace(TextLimits.FEEDBACK_MAX.toString(), "\\(maxLength)")}\""
        assertTrue(expected in source, "iOS の FeedbackViewModel.swift に「$expected」が無い")
    }

    @Test
    fun `送るバージョンと端末情報の形は、iOSと同じ並び`() {
        val source = UiTextSources.iosSource("ViewModels/FeedbackViewModel.swift")
        assertTrue("return \"\\(version) (\\(build))\"" in source, "iOS のアプリのバージョンの書き方が変わった")
        assertTrue(
            "\"iOS \\(UIDevice.current.systemVersion) / \\(UIDevice.current.model)\"" in source,
            "iOS の端末情報の書き方が変わった",
        )
        // Android も同じ並び（名前 (番号)・OS名 版 / 機種）
        assertEquals("1.0.0 (1)", FeedbackMetadata.appVersion("1.0.0", 1))
        assertEquals("Android 14 / Pixel 8", FeedbackMetadata.deviceInfo("14", "Pixel 8"))
    }

    @Test
    fun `ドキュメントIDは、iOSもUUIDの文字列（大文字）にしている`() {
        val source = UiTextSources.iosSource("Models/Feedback.swift")
        assertTrue("id: String = UUID().uuidString" in source, "iOS のドキュメント ID の作り方が変わった")
    }
}
