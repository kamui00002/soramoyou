// ⭐️ 通報・ブロックの文言を iOS 版の投稿詳細の 2 つの画面と 1 文字も違えないことの単体テスト（タスク 29.2・要件 11.3・16.1）
package com.yoshidometoru.soramoyou.feature.moderation

import com.yoshidometoru.soramoyou.ui.UiTextSources
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * iOS は通報とブロックを、投稿詳細の 2 つの画面（HomeView の PostDetailView と GalleryDetailView）の「…」のメニューから出す。
 * Android の文言が、その両方に同じ書き方で現れることを確かめる（DetailStringsTest と同じ考え方。期待値は strings.xml から取る）。
 * 通報理由の選択肢は、iOS が `reason.displayName` をそのまま出していることを確かめる（Android も :contract の
 * ReportReason.displayName を出す。表示名どうしの一致は UiStringsTest が iOS の ReportReason.swift と突き合わせる）。
 *
 * ブロックの確認文だけは、iOS の文の画面の並び（ホーム・ギャラリー・そらとも）を、Android にある画面（ホーム）にした文を使う
 * （2026-11-06 の利用者の決定）。Android でブロックした人の投稿を除くのはフィード（ホーム）だけで、ギャラリーとそらともの画面が無い。
 * 後ろの 2 文（お互いのフォローが外れる・相手に知らされない）は iOS と同じ。両方向のフォローを消すのはサーバーの
 * onUserBlockListChanged（functions/followBlock.js。users/{uid}.blockedUserIds の変化で動き、Android のブロックも同じ所を書く）。
 * 違いが画面の並びだけであることは、Android の文の並びを iOS の並びに替えた文が、iOS の 2 つの画面にそのまま現れることで確かめる。
 */
class ModerationStringsTest {

    /** リソース名 → 文言を %s に置いた iOS の書き方。ブロックの確認文（block_confirm_message）は下の別のテストで見る。 */
    private val expectations = listOf(
        "action_report_post" to "Label(\"%s\", systemImage: \"flag\")",
        "action_block_user" to "Label(\"%s\", systemImage: \"hand.raised\")",
        "report_reason_title" to ".confirmationDialog(\"%s\", isPresented: ${'$'}showingReportSheet)",
        "block_confirm_title" to ".alert(\"%s\", isPresented: ${'$'}showingBlockConfirmation)",
        "action_block" to "Button(\"%s\", role: .destructive)",
        "report_done_title" to ".alert(\"%s\", isPresented: ${'$'}showingReportConfirmation)",
        "report_done_message" to "Text(\"%s\")",
        "action_ok" to "Button(\"%s\") {}",
        "action_cancel" to "Button(\"%s\", role: .cancel)",
    )

    @Test
    fun `通報とブロックの文言は、iOSの投稿詳細の2つの画面と同じ`() {
        UiTextSources.assertIosHasStrings(expectations, "Views/HomeView.swift", "Views/GalleryDetailView.swift")
    }

    @Test
    fun `ブロックの確認文は、iOSの文の画面の並びをAndroidにある画面だけにしたもので、ほかはiOSと同じ`() {
        val android = assertNotNull(UiTextSources.readStrings()["block_confirm_message"], "strings.xml に block_confirm_message が無い")
        // 替える所がちょうど 1 か所あること（無いと、替えずに iOS の全文と比べることになり、違いが画面の並びだけとは言えない）
        assertEquals(1, android.split(ANDROID_SCREENS).size - 1, "Android のブロックの確認文に「$ANDROID_SCREENS」がちょうど 1 つ無い")
        val ios = "Text(\"${android.replace(ANDROID_SCREENS, IOS_SCREENS)}\")"
        listOf("Views/HomeView.swift", "Views/GalleryDetailView.swift").forEach { file ->
            assertTrue(ios in UiTextSources.iosSource(file), "iOS の $file に「$ios」が無い（ブロックの確認文が画面の並び以外でも iOS と違う）")
        }
    }

    @Test
    fun `通報理由の選択肢は、iOSも通報理由の表示名をそのまま出している`() {
        listOf("Views/HomeView.swift", "Views/GalleryDetailView.swift").forEach { file ->
            val source = UiTextSources.iosSource(file)
            assertTrue("ForEach(ReportReason.allCases" in source, "iOS の $file が通報理由を全て並べていない")
            assertTrue("Button(reason.displayName)" in source, "iOS の $file が通報理由の表示名を出していない")
        }
    }

    private companion object {
        /** Android のブロックの確認文の画面の並び。ブロックした人の投稿を除くのはフィード（ホーム）だけ（FeedViewModel）。 */
        const val ANDROID_SCREENS = "、ホームに"

        /** iOS のブロックの確認文の画面の並び（HomeView.swift:1204・GalleryDetailView.swift:286）。ギャラリーとそらともは Android に無い画面。 */
        const val IOS_SCREENS = "、ホーム・ギャラリー・そらともに"
    }
}
