// ⭐️ iOS のデザイントークンの写し（DesignTokens）と色の一式（SkyPalette）を、iOS 版のソースと突き合わせる単体テスト（タスク 4.1・4.2・要件 1.8・2.3・5.1〜5.3・5.6・5.9）
package com.yoshidometoru.soramoyou.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.yoshidometoru.soramoyou.ui.SwiftTokenReader
import com.yoshidometoru.soramoyou.ui.SwiftTokenReader.SwiftColor
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * [DesignTokens] の値を、iOS 版の `Utils/DesignTokens.swift` から [SwiftTokenReader] で読んだ値と突き合わせる。
 * 余白・角丸・文字の大きさは、名前の集合と値の両方が完全に一致すること（使わない名前も写す）を確かめる。
 * 色は、そのまま使うもの（空の 6 色・暗い文字の色・`softPink`・白の不透明度）が一致することを確かめる。
 *
 * Kotlin の写しは Float（dp・sp・不透明度）、Swift から読んだ値は Double なので、Swift の側を Float にして比べる
 * （`0.85f` を Double にすると 0.8500000238… になり、0.85 と等しくならないため）。
 * [SkyPalette] については、要件 3 のために濃さを変えた色の色相が iOS の元の色から 10° 以内であること（要件 5.6）と、
 * ライトの雲の濃さが iOS の `SkyBackgroundView` の値と一致すること（要件 2.3）を確かめる。
 */
class IosDesignTokensTest {

    private val swift = SwiftTokenReader.ios("Utils/DesignTokens.swift")

    @Test
    fun `余白はiOSのSpacingと名前の集合も値も完全に一致する`() {
        val ios = swift.enumBody("Spacing").numbers().mapValues { it.value.toFloat() }
        val kotlin = DesignTokens.Spacing.byIosName.mapValues { it.value.value }
        println("余白: iOS=$ios ／ Kotlin=$kotlin")

        assertEquals(ios, kotlin, "余白の写し（dp）が iOS の Spacing と違う")
    }

    @Test
    fun `角丸はiOSのRadiusと名前の集合も値も完全に一致する`() {
        val ios = swift.enumBody("Radius").numbers().mapValues { it.value.toFloat() }
        val kotlin = DesignTokens.Radius.byIosName.mapValues { it.value.value }
        println("角丸: iOS=$ios ／ Kotlin=$kotlin")

        assertEquals(ios, kotlin, "角丸の写し（dp）が iOS の Radius と違う")
    }

    @Test
    fun `文字の大きさはiOSのTypographyと名前の集合も値も完全に一致し、単位はspである`() {
        val ios = swift.enumBody("Typography").numbers().mapValues { it.value.toFloat() }
        val kotlin = DesignTokens.Typography.byIosName
        println("文字の大きさ: iOS=$ios ／ Kotlin=$kotlin")

        assertEquals(ios, kotlin.mapValues { it.value.value }, "文字の大きさの写しが iOS の Typography と違う")
        // sp でないと、端末の文字サイズの設定で大きくならない（要件 5.4）
        assertEquals(emptySet(), kotlin.filterValues { !it.isSp }.keys, "sp でない文字の大きさがある")
    }

    @Test
    fun `空の6色と暗い文字の色とsoftPinkは、iOSの色と一致する`() {
        val colors = swift.enumBody("Colors")

        assertSameColors("daySkyGradient", colors.colors("daySkyGradient"), DesignTokens.Colors.daySkyGradient)
        assertSameColors("nightSkyGradient", colors.colors("nightSkyGradient"), DesignTokens.Colors.nightSkyGradient)
        assertSameColors("textDark", listOf(colors.color("textDark")), listOf(DesignTokens.Colors.textDark))
        assertSameColors("softPink", listOf(colors.color("softPink")), listOf(DesignTokens.Colors.softPink))
        // iOS の textPrimary は Color.white で、Color(red:green:blue:) ではないので補助では読まない。白であることだけを見る
        assertEquals(Color.White, DesignTokens.Colors.textPrimary, "textPrimary が白でない")
    }

    @Test
    fun `白の不透明度は、iOSの同じ役の白の不透明度と一致する`() {
        val tokens = DesignTokens.Colors
        // iOS の名前 → Kotlin の写し。glassBorderAccent は始点と終点の 2 つを 1 組で持つ
        val kotlin = mapOf(
            "glassPrimary" to tokens.glassPrimaryAlpha,
            "glassSecondary" to tokens.glassSecondaryAlpha,
            "glassTertiary" to tokens.glassTertiaryAlpha,
            "glassBorderSecondary" to tokens.glassBorderSecondaryAlpha,
            "glassBorderAccentStart" to tokens.glassBorderAccentAlphas.first,
            "glassBorderAccentEnd" to tokens.glassBorderAccentAlphas.second,
            "textSecondary" to tokens.textSecondaryAlpha,
            "textTertiary" to tokens.textTertiaryAlpha,
        )
        val colors = swift.enumBody("Colors")
        val ios = kotlin.keys.associateWith { colors.whiteOpacity(it).toFloat() }
        println("白の不透明度: iOS=$ios ／ Kotlin=$kotlin")

        assertEquals(ios, kotlin, "白の不透明度の写しが iOS と違う")
    }

    @Test
    fun `濃さを変えた色の色相は、iOSの元の色から10度以内である`() {
        val colors = swift.enumBody("Colors")
        val skyBlue = colors.color("skyBlue")
        val error = colors.color("error")
        val accentGradient = colors.colors("accentGradient")
        val light = skyPaletteOf(darkTheme = false)
        val dark = skyPaletteOf(darkTheme = true)

        // 名前 →（iOS の元の色, 濃さを変えた色）。ダークのいいね済みは softPink そのものなので、ここには入れない
        val pairs = mutableListOf(
            "ライトのアクセント（skyBlue）" to (skyBlue to light.accent),
            "ダークのアクセント（skyBlue）" to (skyBlue to dark.accent),
            "ライトのエラー（error）" to (error to light.error),
            "ダークのエラー（error）" to (error to dark.error),
            "ライトのいいね済み（softPink）" to (colors.color("softPink") to light.liked),
        )
        // ログインのボタンのグラデーションは、端ごとに iOS の accentGradient の同じ端と比べる（両端を 1 つの色と比べない）
        listOf("ライト" to light, "ダーク" to dark).forEach { (theme, palette) ->
            assertEquals(accentGradient.size, palette.accentGradient.size, "$theme のログインのボタンの色の数が iOS の accentGradient と違う")
            accentGradient.zip(palette.accentGradient).forEachIndexed { i, (ios, android) ->
                pairs += "$theme のログインのボタンの ${i + 1} 番目（accentGradient）" to (ios to android)
            }
        }

        val rows = pairs.map { (name, pair) ->
            val (ios, android) = pair
            val iosHue = ContrastMath.hueDegrees(ios.toColor())
            val androidHue = ContrastMath.hueDegrees(android)
            val distance = ContrastMath.hueDistance(iosHue, androidHue)
            println("$name: ${hex(android)} ${"%.1f".format(androidHue)}° ／ iOS $ios ${"%.1f".format(iosHue)}° → 差 ${"%.1f".format(distance)}°")
            name to distance
        }

        val far = rows.filter { (_, distance) -> distance > MAX_HUE_DISTANCE }.map { (name, distance) -> "$name: ${"%.1f".format(distance)}°" }
        assertEquals(emptyList(), far, "色相が iOS の元の色から ${MAX_HUE_DISTANCE}° を超えて離れた色がある")
    }

    @Test
    fun `ライトの雲の濃さは、iOSのSkyBackgroundViewの雲の白の不透明度と並びも値も一致する`() {
        // iOS の雲は名前の無い .fill(.white.opacity(数)) なので、cloudsLayer の本体から現れる順に読む
        val ios = SwiftTokenReader.ios("Views/SkyBackgroundView.swift")
            .block(Regex("""\bvar\s+cloudsLayer\b"""), "var cloudsLayer")
            .whiteOpacities()
            .map { it.toFloat() }
        val kotlin = skyPaletteOf(darkTheme = false).clouds.map { it.alpha }
        println("ライトの雲の濃さ: iOS=$ios ／ Kotlin=$kotlin")

        assertEquals(ios, kotlin, "ライトの雲の濃さが iOS の cloudsLayer と違う")
    }

    /** iOS の色を、色相を求めるために Compose の不透明の色にする。 */
    private fun SwiftColor.toColor(): Color = Color(red = red.toFloat(), green = green.toFloat(), blue = blue.toFloat())

    /** [kotlin] の色が、並びの順に [ios] の色と同じ数だけあり、1 つずつ等しいこと（[SwiftColor.matches]）。 */
    private fun assertSameColors(name: String, ios: List<SwiftColor>, kotlin: List<Color>) {
        println("$name: iOS=$ios ／ Kotlin=${kotlin.map(::hex)}")
        assertEquals(ios.size, kotlin.size, "$name の色の数が iOS と違う")
        ios.zip(kotlin).forEachIndexed { i, (expected, actual) ->
            assertTrue(expected.matches(actual), "$name の ${i + 1} 番目 ${hex(actual)} が iOS の $expected と違う")
        }
    }

    private fun hex(color: Color): String = "#%08X".format(color.toArgb())

    private companion object {
        /** 濃さを変えた色の色相の、iOS の元の色からの差の上限（度。要件 5.6・設計書「トークンに無い値と外した値」）。 */
        const val MAX_HUE_DISTANCE = 10.0
    }
}
