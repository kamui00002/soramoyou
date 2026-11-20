// ⭐️ 投稿詳細の「撮影:」の見出しと削除の文言を iOS 版と 1 文字も違えないことの単体テスト（タスク 10.2・24・要件 5.4・10.11・16.1）
package com.yoshidometoru.soramoyou.feature.detail

import com.yoshidometoru.soramoyou.ui.UiTextSources
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * 日時を差し込む前の見出し（`撮影: `）が、iOS の `Text("撮影: \(date.formatted(…))")` と同じであることを確かめる。
 * 削除の確認と失敗のダイアログの文言は、iOS の投稿詳細の 2 つの画面（HomeView・GalleryDetailView）の両方に、同じ書き方で現れることを確かめる。
 */
class DetailStringsTest {

    /** リソース名 → 文言を %s に置いた iOS の書き方。 */
    private val deleteExpectations = listOf(
        "detail_delete_confirm_title" to ".alert(\"%s\", isPresented: ${'$'}showingDeleteConfirmation)",
        "detail_delete_confirm_message" to "Text(\"%s\")",
        "action_delete" to "Button(\"%s\", role: .destructive)",
        "action_cancel" to "Button(\"%s\", role: .cancel)",
        "detail_delete_failed_title" to ".alert(\"%s\", isPresented: Binding(",
        "action_ok" to "Button(\"%s\") { viewModel.deleteError = nil }",
    )

    @Test
    fun `削除の確認と失敗のダイアログの文言はiOSの投稿詳細の2つの画面と同じ`() {
        UiTextSources.assertIosHasStrings(deleteExpectations, "Views/HomeView.swift", "Views/GalleryDetailView.swift")
    }

    @Test
    fun `撮影日時の見出しはiOSの詳細画面と同じ`() {
        val value = assertNotNull(UiTextSources.readStrings()["detail_captured_at"], "strings.xml に detail_captured_at が無い")
        val prefix = value.removeSuffix("%1\$s")
        val expected = "Text(\"$prefix\\(date.formatted"
        assertTrue(expected in UiTextSources.iosSource("Views/GalleryDetailView.swift"), "iOS の GalleryDetailView.swift に「$expected」が無い")
    }
}
