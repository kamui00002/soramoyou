// ⭐️ ライトとダークの色の一式（SkyPalette）の不変条件の単体テスト（タスク 4.2・要件 1.1・1.2・2.3・3.5〜3.7）
package com.yoshidometoru.soramoyou.ui.theme

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * [skyPaletteOf] が返す一式の形を確かめる。値の並びと数・部品どうしの約束（入力欄の文字は本文の色・入力欄に縁を付けない）を固定する。
 * iOS の値との突き合わせ（色相・雲の濃さ）は IosDesignTokensTest、コントラスト比は SkyContrastTest（タスク 5.1）が確かめる。
 * 画面（SoramoyouTheme・部品）とこのテストは、同じ [skyPaletteOf] を読む。
 */
class SkyPaletteTest {

    private val light = skyPaletteOf(darkTheme = false)
    private val dark = skyPaletteOf(darkTheme = true)
    private val both = listOf("ライト" to light, "ダーク" to dark)

    @Test
    fun `ライトは昼の空・ダークは夜の空の3色を、上から下への順に持つ`() {
        assertEquals(false, light.isDark, "ライトの一式の isDark が false でない")
        assertEquals(true, dark.isDark, "ダークの一式の isDark が true でない")
        // DesignTokens の空の色は、iOS の上→中→下の 3 色と IosDesignTokensTest が突き合わせている。順も数もそれと同じであること
        assertEquals(DesignTokens.Colors.daySkyGradient, light.skyGradient, "ライトの空が、昼の空の 3 色（上→中→下）でない")
        assertEquals(DesignTokens.Colors.nightSkyGradient, dark.skyGradient, "ダークの空が、夜の空の 3 色（上→中→下）でない")
    }

    @Test
    fun `雲は4つで、iOSの並び（上・上・中央・下）のとおり上から順に置く`() {
        both.forEach { (theme, palette) ->
            assertEquals(4, palette.clouds.size, "$theme の雲が 4 つでない: ${palette.clouds}")
            val tops = palette.clouds.map { it.topFraction }
            assertTrue(tops.zipWithNext().all { (upper, lower) -> upper < lower }, "$theme の雲が上から順に並んでいない: $tops")
        }
    }

    @Test
    fun `ダークの雲は、ライトと同じ大きさと位置で、濃さだけがライトの0_2倍である`() {
        // 濃さを 0 に揃えて、大きさ・寄せる側・横のずれ・縦の位置だけを比べる
        assertEquals(
            light.clouds.map { it.copy(alpha = 0f) },
            dark.clouds.map { it.copy(alpha = 0f) },
            "ダークの雲の大きさか位置が、ライトと違う",
        )
        // ダークでは雲の上にアクセントとエラーの文字が載るので、iOS の 0.2 倍に薄める（設計書の P3）
        light.clouds.zip(dark.clouds).forEachIndexed { i, (day, night) ->
            assertEquals(day.alpha * DARK_CLOUD_RATIO, night.alpha, 1e-6f, "ダークの ${i + 1} 番目の雲の濃さが、ライトの ${day.alpha} の 0.2 倍でない")
        }
    }

    @Test
    fun `ガラスの入力欄とボタンの文字の色は、本文の色と等しい`() {
        // 雲とガラスを重ねた所に文字として載せてよいのは本文の色だけ（アクセントとエラーはダークで 4.5 を割る。設計書「ガラスの部品」）
        both.forEach { (theme, palette) ->
            assertEquals(palette.text, palette.glass.inputContent, "$theme の入力欄の文字の色が本文の色でない")
            assertEquals(palette.text, palette.glass.buttonContent, "$theme のガラスのボタンの文字の色が本文の色でない")
        }
    }

    @Test
    fun `ガラスの入力欄には縁を付けず、枠はMaterial3の枠だけにする`() {
        // 白 30% の縁では、昼の空の上で選択中とエラーを 3.0 で示せない（要件 3.5・設計書「トークンに無い値と外した値」）
        both.forEach { (theme, palette) ->
            assertEquals(emptyList(), palette.glass.input.border, "$theme のガラスの入力欄に縁がある")
        }
    }

    private companion object {
        /** ダークの雲の濃さの、ライト（iOS の値）に対する倍率（設計書の P3）。 */
        const val DARK_CLOUD_RATIO = 0.2f
    }
}
