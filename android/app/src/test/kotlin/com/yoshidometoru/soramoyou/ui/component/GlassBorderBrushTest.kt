// ⭐️ ガラスの縁の描き方の分け方（空なら描かない・1 色は単色・2 色以上はグラデーション）を確かめる（android-ui-ios-parity タスク 9.1・要件 2.1・5.2）
package com.yoshidometoru.soramoyou.ui.component

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import com.yoshidometoru.soramoyou.ui.theme.SkyPalette
import com.yoshidometoru.soramoyou.ui.theme.skyPaletteOf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [glassBorderBrush] の、縁の色の数による分け方を確かめる。
 * タスク 9.1 に定めた単体テストは無いが、Brush.linearGradient は色が 2 つ未満だと描くときに例外を投げるので、
 * 空と 1 色の縁をグラデーションにしない分け方を、ここで守る（壊れると、その部品を初めて描いたときに落ちる）。
 *
 * 色の値はテストに書き写さず、画面と同じ色の一式（[skyPaletteOf]）の実際の縁を渡す。ライトとダークの両方で確かめる。
 * 色の一式が変わって縁の色の数がずれると、下の 3 つの検査が狙った分かれ道を通らずに空振りするので、色の数も前提として確かめる。
 */
class GlassBorderBrushTest {

    /** ライトとダークの両方の色の一式。 */
    private val palettes: List<SkyPalette> = listOf(skyPaletteOf(darkTheme = false), skyPaletteOf(darkTheme = true))

    /** 失敗の文言に添える、どちらの一式か。 */
    private fun SkyPalette.label(): String = if (isDark) "ダーク" else "ライト"

    @Test
    fun `前提：縁の色の数は入力欄が0・カードが1・ボタンと投稿のカードが2`() {
        palettes.forEach { palette ->
            val glass = palette.glass
            assertEquals(
                "${palette.label()}の縁の色の数（入力欄・カード・ボタン・投稿のカードの順）",
                listOf(0, 1, 2, 2),
                listOf(glass.input.border, glass.card.border, glass.button.border, glass.postCard.border).map { it.size },
            )
        }
    }

    @Test
    fun `縁が空なら筆を返さず縁を描かない`() {
        palettes.forEach { palette ->
            assertNull("${palette.label()}の入力欄の縁", glassBorderBrush(palette.glass.input.border))
        }
    }

    @Test
    fun `縁が1色ならその色の単色で描く`() {
        palettes.forEach { palette ->
            val border = palette.glass.card.border
            assertEquals("${palette.label()}のカードの縁", SolidColor(border.single()), glassBorderBrush(border))
        }
    }

    @Test
    fun `縁が2色なら左上から右下へのグラデーションで描く`() {
        palettes.forEach { palette ->
            listOf("ボタン" to palette.glass.button.border, "投稿のカード" to palette.glass.postCard.border)
                .forEach { (name, border) ->
                    // 既定の始まり（左上）と終わり（右下）で作った筆と等しい
                    assertEquals("${palette.label()}の${name}の縁", Brush.linearGradient(border), glassBorderBrush(border))
                }
        }
    }
}
