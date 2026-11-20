// ⭐️ テーマが端末のダークテーマの設定に追従することの単体テスト（タスク 5.2・要件 16.4）。色の役と書体の付け替え（android-ui-ios-parity タスク 4.4）
package com.yoshidometoru.soramoyou.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 端末の設定（ダークかどうか）から配色を決める部分は純関数 [soramoyouColorScheme] にして、ここで確かめる。
 * Composable の [SoramoyouTheme] 自体は JVM の単体テストでは描画できないため、「既定値が端末の設定を読む」
 * 「その値で配色を選ぶ」「書体の一式を渡し、色の一式を配る」をソースの文字列で確かめる。実際の画面の見た目は端末で確かめる（タスク 11.3）。
 */
class SoramoyouThemeTest {

    /** :app の単体テストの作業ディレクトリ（android/app）から見た、テーマのソース。 */
    private val themeSource = File("src/main/kotlin/com/yoshidometoru/soramoyou/ui/theme/SoramoyouTheme.kt")

    @Test
    fun `ダークの配色はライトの配色より背景が暗い`() {
        // 端末がダークのときにダークの配色を選ぶこと。2 つの配色の取り違えも、どちらでも同じ配色を返すことも、ここで失敗する
        val dark = soramoyouColorScheme(darkTheme = true).background.luminance()
        val light = soramoyouColorScheme(darkTheme = false).background.luminance()
        assertTrue(dark < light, "ダークの背景の明るさ $dark がライトの $light より暗くない")
    }

    @Test
    fun `主色の上の文字と、背景の上の主色の文字は、どちらの配色でもコントラスト比が4_5以上ある`() {
        // 主色はここで決めた値なので、文字が読める濃さであることを固定する（WCAG の本文の基準 4.5:1）。
        // 主色はボタンの背景（上に onPrimary の文字）と、文字だけのボタンの文字の色（背景の上）の両方に使われる
        listOf("ライト" to soramoyouColorScheme(darkTheme = false), "ダーク" to soramoyouColorScheme(darkTheme = true))
            .forEach { (name, scheme) ->
                val onPrimary = contrastRatio(scheme.primary, scheme.onPrimary)
                val onBackground = contrastRatio(scheme.primary, scheme.background)
                assertTrue(onPrimary >= 4.5, "$name の主色と onPrimary のコントラスト比 $onPrimary が 4.5 未満")
                assertTrue(onBackground >= 4.5, "$name の主色と背景のコントラスト比 $onBackground が 4.5 未満")
            }
    }

    @Test
    fun `テーマの既定値は端末のダークテーマの設定を読み、その値で配色を選ぶ`() {
        assertTrue(themeSource.isFile, "テーマのソースが見つからない: ${themeSource.absolutePath}")
        val source = themeSource.readText()

        assertTrue(
            Regex("""fun\s+SoramoyouTheme\s*\(\s*darkTheme\s*:\s*Boolean\s*=\s*isSystemInDarkTheme\s*\(\s*\)""").containsMatchIn(source),
            "SoramoyouTheme の darkTheme の既定値が isSystemInDarkTheme() ではない（端末の設定に追従しない）",
        )
        assertTrue(
            Regex("""colorScheme\s*=\s*soramoyouColorScheme\s*\(\s*darkTheme\s*\)""").containsMatchIn(source),
            "SoramoyouTheme が soramoyouColorScheme(darkTheme) の配色を使っていない",
        )
    }

    @Test
    fun `付け替えた役は、どちらの配色でも色の一式の色である`() {
        // 設計書の「Material 3 の役の付け替え」の表。ずれた役を全て集めてから比べ、1 回の失敗で全て並べる
        val mismatches = themes.flatMap { (name, darkTheme) ->
            val scheme = soramoyouColorScheme(darkTheme)
            val palette = skyPaletteOf(darkTheme)
            listOf(
                Triple("primary", scheme.primary, palette.accent),
                Triple("onPrimary", scheme.onPrimary, palette.onAccent),
                Triple("onBackground", scheme.onBackground, palette.text),
                Triple("onSurface", scheme.onSurface, palette.text),
                Triple("onSurfaceVariant", scheme.onSurfaceVariant, palette.textSecondary),
                Triple("error", scheme.error, palette.error),
                Triple("onError", scheme.onError, palette.onError),
                Triple("outline", scheme.outline, palette.outline),
            ).filter { (_, actual, expected) -> actual != expected }
                .map { (role, actual, expected) -> "$name の $role が $actual（色の一式は $expected）" }
        }
        assertEquals(emptyList(), mismatches, "Material 3 の役が、付け替えの表の色の一式の色でない")
    }

    @Test
    fun `面の役は、どちらの配色でもMaterial_3の既定のままで不透明である`() {
        // 無地の画面・ダイアログ・メニュー・写真の下地の面。空の色もガラスの半透明も持ち込まない（ダイアログとメニューを不透明のまま出す）
        val problems = themes.flatMap { (name, darkTheme) ->
            val scheme = soramoyouColorScheme(darkTheme)
            val default = if (darkTheme) darkColorScheme() else lightColorScheme()
            surfaceRoles.flatMap { (role, read) ->
                val actual = read(scheme)
                listOfNotNull(
                    "$name の $role が既定の ${read(default)} でなく $actual".takeIf { actual != read(default) },
                    "$name の $role が不透明でない（不透明度 ${actual.alpha}）".takeIf { actual.alpha != 1f },
                )
            }
        }
        assertEquals(emptyList(), problems, "面の役が Material 3 の既定の不透明な色のままでない")
    }

    @Test
    fun `テーマは書体の一式を渡し、色の一式を画面の中へ配る`() {
        assertTrue(themeSource.isFile, "テーマのソースが見つからない: ${themeSource.absolutePath}")
        val source = themeSource.readText()

        // 足りないものを全て集めてから比べる。書体は作り直さないように remember で包んでもよい
        val missing = listOfNotNull(
            "MaterialTheme に soramoyouTypography() の書体を渡していない".takeUnless {
                Regex("""typography\s*=\s*(remember\s*\{\s*)?soramoyouTypography\s*\(\s*\)""").containsMatchIn(source)
            },
            "LocalSkyPalette に skyPaletteOf(darkTheme) の色の一式を入れていない".takeUnless {
                Regex("""LocalSkyPalette\s+provides\s+skyPaletteOf\s*\(\s*darkTheme\s*\)""").containsMatchIn(source)
            },
        )
        assertEquals(emptyList(), missing, "SoramoyouTheme が書体か色の一式を配っていない")
    }

    /** 確かめる 2 つの配色（名前と、端末がダークか）。 */
    private val themes = listOf("ライト" to false, "ダーク" to true)

    /** 既定のまま不透明に保つ面の役（名前と、配色からその色を読む関数）。surfaceTint は面の色でないので入れない。 */
    private val surfaceRoles: List<Pair<String, (ColorScheme) -> Color>> = listOf(
        "background" to { it.background },
        "surface" to { it.surface },
        "surfaceVariant" to { it.surfaceVariant },
        "surfaceBright" to { it.surfaceBright },
        "surfaceDim" to { it.surfaceDim },
        "surfaceContainerLowest" to { it.surfaceContainerLowest },
        "surfaceContainerLow" to { it.surfaceContainerLow },
        "surfaceContainer" to { it.surfaceContainer },
        "surfaceContainerHigh" to { it.surfaceContainerHigh },
        "surfaceContainerHighest" to { it.surfaceContainerHighest },
    )

    /** WCAG 2 のコントラスト比（明るい方 + 0.05）/（暗い方 + 0.05）。 */
    private fun contrastRatio(a: Color, b: Color): Double {
        val (high, low) = listOf(a.luminance(), b.luminance()).sortedDescending()
        return (high + 0.05) / (low + 0.05)
    }
}
