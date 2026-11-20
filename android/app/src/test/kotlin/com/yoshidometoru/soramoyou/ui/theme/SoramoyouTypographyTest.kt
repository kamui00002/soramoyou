// ⭐️ 書体の一式（soramoyouTypography）が設計書の「書体の対応表」のとおりであることの単体テスト（タスク 4.3・要件 5.3・5.4・設計書 P7）
package com.yoshidometoru.soramoyou.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * [soramoyouTypography] の 15 の役の文字の大きさを、設計書の「書体の対応表」の iOS のトークンと突き合わせる。
 *
 * - 表はこのテストに「役 → iOS のトークンの名前」として独立して書き、値は [DesignTokens.Typography.byIosName] から引く
 *   （数を書き写すと、実装と同じ数の誤りを写しても通るため）。トークンの値そのものが iOS と一致することは IosDesignTokensTest が確かめる。
 * - 太さと「行の高さ÷大きさ」の比（設計書の P7）は、設計書のテストの表（大きさと sp）より広げて、ここで確かめる。
 *   行の高さの掛け忘れを拾う手段が、ほかに無いためである。
 *
 * 書体の一式は `android.*` を使わない値なので、JVM の単体テストで作って読める（タスク 2 で確かめた）。
 */
class SoramoyouTypographyTest {

    private val typography = soramoyouTypography()

    /** Material 3 の既定の書体。太さと「行の高さ÷大きさ」の比の基準にする。 */
    private val defaults = Typography()

    @Test
    fun `各役の文字の大きさは、書体の対応表のiOSのトークンと等しい`() {
        val expected = IOS_TOKEN_BY_ROLE.mapValues { (role, iosName) ->
            assertNotNull(DesignTokens.Typography.byIosName[iosName], "$role の iOS のトークン $iosName が DesignTokens.Typography に無い").value
        }
        val roles = typography.byRole()
        roles.forEach { (role, style) ->
            println("$role: 大きさ ${style.fontSize}（${IOS_TOKEN_BY_ROLE[role]}）・行の高さ ${style.lineHeight}・太さ ${style.fontWeight?.weight}")
        }

        assertEquals(expected, roles.mapValues { it.value.fontSize.value }, "書体の対応表と違う大きさの役がある")
    }

    @Test
    fun `各役の文字の大きさの単位はspである`() {
        // sp でないと、端末の文字サイズの設定で大きくならない（要件 5.4）
        assertEquals(emptySet(), typography.byRole().filterValues { !it.fontSize.isSp }.keys, "文字の大きさが sp でない役がある")
    }

    @Test
    fun `太さは各役の既定のままで、行の高さは既定の行の高さと大きさの比を保つ`() {
        val base = defaults.byRole()
        val changed = typography.byRole().flatMap { (role, style) ->
            val default = base.getValue(role)
            val ratio = style.lineHeight.value / style.fontSize.value
            val defaultRatio = default.lineHeight.value / default.fontSize.value
            listOfNotNull(
                "$role の太さ ${style.fontWeight} が既定の ${default.fontWeight} と違う".takeIf { style.fontWeight != default.fontWeight },
                // 行の高さが sp でない（決まっていない値の value は NaN）と、下の比の差の検査が黙って通るので、先に落とす
                "$role の行の高さ ${style.lineHeight} が sp でない".takeIf { !style.lineHeight.isSp },
                "$role の行の高さ÷大きさ $ratio が既定の $defaultRatio と違う".takeIf { abs(ratio - defaultRatio) > RATIO_TOLERANCE },
            )
        }

        assertEquals(emptyList(), changed, "太さか行の高さの比が既定から変わった役がある")
    }

    /** Material 3 の 15 の役の名前 → 書体。 */
    private fun Typography.byRole(): Map<String, TextStyle> = mapOf(
        "displayLarge" to displayLarge,
        "displayMedium" to displayMedium,
        "displaySmall" to displaySmall,
        "headlineLarge" to headlineLarge,
        "headlineMedium" to headlineMedium,
        "headlineSmall" to headlineSmall,
        "titleLarge" to titleLarge,
        "titleMedium" to titleMedium,
        "titleSmall" to titleSmall,
        "bodyLarge" to bodyLarge,
        "bodyMedium" to bodyMedium,
        "bodySmall" to bodySmall,
        "labelLarge" to labelLarge,
        "labelMedium" to labelMedium,
        "labelSmall" to labelSmall,
    )

    private companion object {
        /**
         * 設計書の「書体の対応表」の、Material 3 の役 → iOS のトークンの名前。
         * トークンに無い 24（headlineSmall）と 22（titleLarge）は subtitleSize（20）に寄せる（設計書の P7）。
         */
        val IOS_TOKEN_BY_ROLE: Map<String, String> = mapOf(
            "displayLarge" to "heroSize",
            "displayMedium" to "heroSize",
            "displaySmall" to "heroSize",
            "headlineLarge" to "titleSize",
            "headlineMedium" to "titleSize",
            "headlineSmall" to "subtitleSize",
            "titleLarge" to "subtitleSize",
            "titleMedium" to "bodySize",
            "titleSmall" to "captionSize",
            "bodyLarge" to "bodySize",
            "bodyMedium" to "captionSize",
            "bodySmall" to "smallCaptionSize",
            "labelLarge" to "buttonSize",
            "labelMedium" to "smallCaptionSize",
            "labelSmall" to "tabLabelSize",
        )

        /** 「行の高さ÷大きさ」の比の、既定からの差の上限（Float の割り算の誤差を許す幅。タスク 2 の実測では 1e-4 以内）。 */
        const val RATIO_TOLERANCE = 1e-4f
    }
}
