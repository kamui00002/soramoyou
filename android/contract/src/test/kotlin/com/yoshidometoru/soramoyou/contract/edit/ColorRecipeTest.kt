// ⭐️ 編集の内容の色の部分（ColorRecipe）の単体テスト（Kiro android-edit-tools タスク 4・C1・design.md:1122）
package com.yoshidometoru.soramoyou.contract.edit

import com.yoshidometoru.soramoyou.contract.model.FilterId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * [ColorRecipe.of]・[ColorRecipe.isIdentity]・[ColorRecipe.legacyMatrixOnly] を確かめる（design.md:1122）。
 * - 中立なら isIdentity
 * - 今の 6 種だけなら legacyMatrixOnly にそのフィルター。ツールが 1 つでも付けば外れる
 * - 暖かみと色合いが共に 0 なら warmTint は null
 * - ツールの値はそれぞれ自分の物理の値にだけ写る。回転と切り抜きは見ない
 *
 * 物理の値の期待値は design.md「色の式」の表から手で計算した数字（ToolMappingTest と同じ計算）。
 * ToolValues は K0 で本物の `with`・`normalized` だけを使う（TODO() の関数には頼らない）。
 *
 * 陽性対照（tasks.md:277）：`legacyMatrixOnly` がツールを見ないようにする（toolsNeutral の条件を外す）と、
 * 「ツールが 1 つでも付けば…外れる」と「直接作ったレシピでも…」が赤になる。
 */
class ColorRecipeTest {

    /** 行列を持つ今の 6 種 */
    private val legacySix = listOf(FilterId.CLEAR, FilterId.DRAMA, FilterId.SOFT, FilterId.MONOCHROME, FilterId.PASTEL, FilterId.VIVID)

    /** スライダーのツール（10 個。トリミング・回転は値を持たない） */
    private val sliders = EditTool.entries.filter { it.isSlider }

    /** ツールの値を並べて ToolValues にする（百分の 1 の整数） */
    private fun tools(vararg pairs: Pair<EditTool, Int>): ToolValues =
        pairs.fold(ToolValues.NONE) { acc, (tool, value) -> acc.with(tool, value) }

    private fun assertTarget(expected: TemperatureTarget?, actual: TemperatureTarget?, message: String) {
        if (expected == null) {
            assertNull(actual, message)
            return
        }
        val a = assertNotNull(actual, message)
        assertEquals(expected.kelvin, a.kelvin, 1e-9, "$message の K")
        assertEquals(expected.tint, a.tint, 1e-9, "$message の色合い")
    }

    /** 11 個の項目を 1 つずつ比べる（浮動小数は 1e-9 の許し幅） */
    private fun assertRecipe(expected: ColorRecipe, actual: ColorRecipe, message: String) {
        assertEquals(expected.filter, actual.filter, "$message filter")
        assertEquals(expected.exposureEv, actual.exposureEv, 1e-9, "$message exposureEv")
        assertEquals(expected.saturation, actual.saturation, 1e-9, "$message saturation")
        assertEquals(expected.contrast, actual.contrast, 1e-9, "$message contrast")
        assertEquals(expected.brightness, actual.brightness, 1e-9, "$message brightness")
        assertEquals(expected.blackPointBias, actual.blackPointBias, 1e-9, "$message blackPointBias")
        assertTarget(expected.warmTint, actual.warmTint, "$message warmTint")
        assertTarget(expected.colorTemperature, actual.colorTemperature, "$message colorTemperature")
        assertTarget(expected.whiteBalance, actual.whiteBalance, "$message whiteBalance")
        assertEquals(expected.fadeGain, actual.fadeGain, 1e-9, "$message fadeGain")
        assertEquals(expected.fadeBias, actual.fadeBias, 1e-9, "$message fadeBias")
    }

    @Test
    fun `何も編集していなければIDENTITYと等しく中立`() {
        val recipe = ColorRecipe.of(PhotoEdit.NONE)
        // data class の等しさで比べる（−0.0 が混ざると等しくならないので、それも見ている）
        assertEquals(ColorRecipe.IDENTITY, recipe)
        assertTrue(recipe.isIdentity)
        assertNull(recipe.legacyMatrixOnly)
        assertTrue(ColorRecipe.IDENTITY.isIdentity)
    }

    @Test
    fun `ナチュラルだけでも中立で、今の6種には入らない`() {
        val recipe = ColorRecipe.of(PhotoEdit(filter = FilterId.NATURAL))
        assertEquals(ColorRecipe.IDENTITY.copy(filter = FilterId.NATURAL), recipe)
        assertTrue(recipe.isIdentity)
        assertNull(recipe.legacyMatrixOnly)
    }

    @Test
    fun `フィルターはそのまま写る`() {
        for (filter in FilterId.entries + listOf(null)) {
            assertEquals(filter, ColorRecipe.of(PhotoEdit(filter = filter)).filter, "$filter")
        }
    }

    @Test
    fun `今の6種だけならlegacyMatrixOnlyにそのフィルターが入り、中立ではない`() {
        for (filter in legacySix) {
            val recipe = ColorRecipe.of(PhotoEdit(filter = filter))
            assertEquals(ColorRecipe.IDENTITY.copy(filter = filter), recipe, filter.raw)
            assertEquals(filter, recipe.legacyMatrixOnly, filter.raw)
            assertFalse(recipe.isIdentity, filter.raw)
        }
    }

    @Test
    fun `ウォーム・クール・ビンテージは中立でも今の6種でもない`() {
        for (filter in listOf(FilterId.WARM, FilterId.COOL, FilterId.VINTAGE)) {
            val recipe = ColorRecipe.of(PhotoEdit(filter = filter))
            assertFalse(recipe.isIdentity, filter.raw)
            assertNull(recipe.legacyMatrixOnly, filter.raw)
        }
    }

    @Test
    fun `ツールが1つでも付けばlegacyMatrixOnlyとisIdentityから外れる`() {
        // 10 個のツールそれぞれを、いちばん小さい値（±1＝±0.01）と端（±100）で付ける
        for (filter in legacySix + listOf(FilterId.NATURAL, null)) {
            for (tool in sliders) {
                for (value in listOf(1, -1, 100, -100)) {
                    val recipe = ColorRecipe.of(PhotoEdit(filter = filter, tools = tools(tool to value)))
                    assertNull(recipe.legacyMatrixOnly, "${filter?.raw} ＋ ${tool.raw}=$value")
                    assertFalse(recipe.isIdentity, "${filter?.raw} ＋ ${tool.raw}=$value")
                }
            }
        }
    }

    @Test
    fun `直接作ったレシピでも、中立でない項目が1つでもあればlegacyMatrixOnlyとisIdentityから外れる`() {
        val off = TemperatureTarget(6000.0, 10.0)
        val oneOff = listOf(
            "exposureEv" to ColorFixtures.recipe(exposureEv = 0.1),
            "saturation" to ColorFixtures.recipe(saturation = 1.1),
            "contrast" to ColorFixtures.recipe(contrast = 0.9),
            "brightness" to ColorFixtures.recipe(brightness = -0.1),
            "blackPointBias" to ColorFixtures.recipe(blackPointBias = 0.05),
            "warmTint" to ColorFixtures.recipe(warmTint = off),
            "colorTemperature" to ColorFixtures.recipe(colorTemperature = off),
            "whiteBalance" to ColorFixtures.recipe(whiteBalance = off),
            "fadeGain" to ColorFixtures.recipe(fadeGain = 0.9),
            "fadeBias" to ColorFixtures.recipe(fadeBias = 0.1),
        )
        for ((name, base) in oneOff) {
            assertFalse(base.isIdentity, name)
            for (filter in legacySix) {
                assertNull(base.copy(filter = filter).legacyMatrixOnly, "${filter.raw} ＋ $name")
            }
        }
        // 比べるための対：中立のまま 6 種を入れると legacyMatrixOnly に入る
        for (filter in legacySix) {
            assertEquals(filter, ColorFixtures.recipe(filter = filter).legacyMatrixOnly, filter.raw)
        }
    }

    @Test
    fun `ツールの値はそれぞれ自分の物理の値にだけ写る`() {
        val neutral = ColorRecipe.IDENTITY
        // 期待値は「色の式」の表から手で計算した値（ToolMappingTest と同じ計算）
        val cases = listOf(
            Triple(EditTool.EXPOSURE, 50, neutral.copy(exposureEv = 1.0)),                         // 2.0×0.5
            Triple(EditTool.EXPOSURE, -100, neutral.copy(exposureEv = -2.0)),                      // 2.0×(−1)
            Triple(EditTool.BRIGHTNESS, 100, neutral.copy(brightness = 0.5)),                      // 0.5×1
            Triple(EditTool.BRIGHTNESS, -50, neutral.copy(brightness = -0.176776695297)),          // −0.5×0.5^1.5
            Triple(EditTool.CONTRAST, -50, neutral.copy(contrast = 0.875)),                        // 1−0.5×0.5^2
            Triple(EditTool.CONTRAST, 100, neutral.copy(contrast = 1.5)),                          // 1＋0.5×1
            Triple(EditTool.SATURATION, 50, neutral.copy(saturation = 1.923358310009)),            // 1＋1.5×0.5^0.7
            Triple(EditTool.SATURATION, -100, neutral.copy(saturation = 0.0)),                     // 1−1
            Triple(EditTool.BLACK_POINT, -100, neutral.copy(blackPointBias = -0.15)),              // 0.15×(−1)
            Triple(EditTool.WARMTH, 50, neutral.copy(warmTint = TemperatureTarget(5750.0, 0.0))),  // 6500−1500×0.5
            Triple(EditTool.TINT, -100, neutral.copy(warmTint = TemperatureTarget(6500.0, -250.0))), // 250×(−1)
            Triple(EditTool.COLOR_TEMPERATURE, -50, neutral.copy(colorTemperature = TemperatureTarget(5750.0, 0.0))), // 6500−750
            Triple(EditTool.WHITE_BALANCE, 50, neutral.copy(whiteBalance = TemperatureTarget(7500.0, 0.0))),          // 6500＋1000
            Triple(EditTool.FADE, 60, neutral.copy(fadeGain = 0.91, fadeBias = 0.12)),             // 1−0.15×0.6・0.2×0.6
        )
        for ((tool, value, expected) in cases) {
            assertRecipe(expected, ColorRecipe.of(PhotoEdit(tools = tools(tool to value))), "${tool.raw}=$value")
        }
        // 10 個のツールが全部どこかに写っている（写し忘れたツールは中立のままになる）
        assertEquals(sliders.toSet(), cases.map { it.first }.toSet())
    }

    @Test
    fun `暖かみと色合いは1つの行き先にまとまる`() {
        // 暖かみ 0.3・色合い −0.2 → (6500−1500×0.3, 250×(−0.2))＝(6050, −50)
        val recipe = ColorRecipe.of(PhotoEdit(tools = tools(EditTool.WARMTH to 30, EditTool.TINT to -20)))
        assertRecipe(ColorRecipe.IDENTITY.copy(warmTint = TemperatureTarget(6050.0, -50.0)), recipe, "暖かみ 30・色合い −20")
    }

    @Test
    fun `暖かみと色合いが共に0ならwarmTintはnull、色温度とホワイトバランスも0ならnull`() {
        val noTemperature = ColorRecipe.of(
            PhotoEdit(tools = tools(EditTool.EXPOSURE to 50, EditTool.CONTRAST to -30, EditTool.FADE to 20)),
        )
        assertNull(noTemperature.warmTint)
        assertNull(noTemperature.colorTemperature)
        assertNull(noTemperature.whiteBalance)
        // 片方だけでも行き先を作る
        assertNotNull(ColorRecipe.of(PhotoEdit(tools = tools(EditTool.WARMTH to 1))).warmTint)
        assertNotNull(ColorRecipe.of(PhotoEdit(tools = tools(EditTool.TINT to -1))).warmTint)
    }

    @Test
    fun `回転と切り抜きは見ない`() {
        val values = tools(EditTool.EXPOSURE to 40, EditTool.WARMTH to -60, EditTool.FADE to 10)
        val plain = ColorRecipe.of(PhotoEdit(filter = FilterId.DRAMA, tools = values))
        // EditGeometry の回転の関数（K0 では TODO()）は使わず、値を直接置く
        val geometry = EditGeometry(quarterTurns = 1, crop = NormalizedRect(0.1, 0.2, 0.8, 0.9))
        val turned = ColorRecipe.of(PhotoEdit(filter = FilterId.DRAMA, tools = values, geometry = geometry))
        assertEquals(plain, turned)
    }
}
