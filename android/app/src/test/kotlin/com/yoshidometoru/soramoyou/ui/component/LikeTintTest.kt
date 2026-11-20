// ⭐️ いいねのハートの色の規則（いいね済みで押せるときだけ、色の一式のいいね済みの色）を、ライトとダークの両方で確かめる（android-ui-ios-parity タスク 10.1・要件 3.5・6.2・9.4）
package com.yoshidometoru.soramoyou.ui.component

import androidx.compose.ui.graphics.Color
import com.yoshidometoru.soramoyou.ui.theme.SkyPalette
import com.yoshidometoru.soramoyou.ui.theme.skyPaletteOf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * [likeTint] の規則（いいね済みで押せるときだけいいね済みの色、それ以外は今の文字色）を、画面と同じ色の一式
 * （[skyPaletteOf] のライトとダーク）で確かめる。
 *
 * - default には本文の色（palette.text。ハートの既定の文字色に当たる）を、liked には色の一式のいいね済みの色（palette.liked）を渡す。
 *   色の値はここに書かず、両方とも色の一式から読む。
 * - 配色ごと・場合ごとの結果を「配色 ／ 場合 → 返った色の名前」の文字列に並べ、期待の一覧と丸ごと比べる。
 *   1 つの組で止まらず、落ちた組がライトとダークの両方とも 1 回の失敗の文言に並ぶ。
 *
 * いいね済みの色そのものは、ここでは確かめない（以前ここにあった色の値の固定のテストの代わりに、次の 2 つが受け持つ）。
 * - 比：いいね済みの色が、空の 3 色・空にガラスの面を重ねた色・無地の、全ての背景で 3.0 以上あることは、
 *   SkyContrastTest が両方の配色で確かめる（空・ガラス・無地の層に載る色の一覧 onSky に「いいね済み（liked）」として入っている）。
 * - 色相：ライトのいいね済みの色相が iOS の softPink から 10° 以内であることは、IosDesignTokensTest の
 *   「濃さを変えた色の色相は、iOSの元の色から10度以内である」が見る。ダークのいいね済みは softPink そのもので
 *   （SkyPalette.kt がダークの liked に DesignTokens の softPink を入れている）、softPink が iOS の値と一致することは、
 *   同じテストの「空の6色と暗い文字の色とsoftPinkは、iOSの色と一致する」が見る。
 */
class LikeTintTest {

    @Test
    fun `前提として、両方の配色で本文の色といいね済みの色は違う色である`() {
        // 2 つが同じ色だと、どちらを返しても同じ名前になり、下の規則のテストが空振りする
        palettes.forEach { (theme, palette) ->
            assertNotEquals("$theme の本文の色といいね済みの色が同じで、規則のテストが空振りする", palette.text, palette.liked)
        }
    }

    @Test
    fun `いいね済みで押せるときは、両方の配色でいいね済みの色にする`() {
        assertRule(listOf(Case("いいね済みで押せる", isLiked = true, enabled = true, expected = LIKED)))
    }

    @Test
    fun `未いいねと押せないときは、両方の配色で今の文字色のまま`() {
        assertRule(
            listOf(
                Case("未いいねで押せる", isLiked = false, enabled = true, expected = DEFAULT),
                Case("いいね済みで押せない", isLiked = true, enabled = false, expected = DEFAULT),
                Case("未いいねで押せない", isLiked = false, enabled = false, expected = DEFAULT),
            ),
        )
    }

    /**
     * [cases] を両方の配色で [likeTint] に通し、返った色の名前が期待どおりかを、配色と場合の名前を付けた一覧で丸ごと比べる。
     */
    private fun assertRule(cases: List<Case>) {
        val expected = mutableListOf<String>()
        val actual = mutableListOf<String>()
        palettes.forEach { (theme, palette) ->
            cases.forEach { case ->
                val tint = likeTint(isLiked = case.isLiked, enabled = case.enabled, default = palette.text, liked = palette.liked)
                expected += "$theme ／ ${case.name} → ${case.expected}"
                actual += "$theme ／ ${case.name} → ${nameOf(tint, palette)}"
            }
        }
        assertEquals("ハートの色の規則と違う組がある", expected, actual)
    }

    /** 返った色が、色の一式のどの色か（いいね済みの色か本文の色か）の名前。どちらでもなければ色の値をそのまま出す。 */
    private fun nameOf(color: Color, palette: SkyPalette): String = when (color) {
        palette.liked -> LIKED
        palette.text -> DEFAULT
        else -> "どちらでもない色（$color）"
    }

    /** 確かめる場合 1 つ。[expected] は返るはずの色の名前（[LIKED] か [DEFAULT]）。 */
    private data class Case(val name: String, val isLiked: Boolean, val enabled: Boolean, val expected: String)

    /** 確かめる 2 つの配色。画面と同じ関数から色の一式を読む。 */
    private val palettes: List<Pair<String, SkyPalette>> =
        listOf("ライト" to skyPaletteOf(darkTheme = false), "ダーク" to skyPaletteOf(darkTheme = true))

    private companion object {
        /** いいね済みの色（palette.liked）を返したときの名前。 */
        const val LIKED = "いいね済みの色"

        /** 既定の色（default に渡した本文の色 palette.text）を返したときの名前。 */
        const val DEFAULT = "本文の色"
    }
}
