// ⭐️ 実測の値が本物の計算（ColorKernel・ToolMapping・ColorRecipe）を通って出ることの確かめ（Kiro android-edit-tools タスク 16・K1③・要件 2.1・2.7・11.2）
package com.yoshidometoru.soramoyou.contract.edit

import com.yoshidometoru.soramoyou.contract.model.FilterId
import kotlin.math.abs
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * ウォーム・クール・ビンテージと、暖かみ・色合い・色温度・ホワイトバランスが、**公開の入口だけ**
 * （[ColorKernel.render]・[ColorKernel.renderColor]・[ColorRecipe.of]）を通って、実測の値になることを確かめる。
 * 差し替えの口（renderWith・renderColorWith・Parts）は使わない（使うと、本物の [TemperatureTint]・[VintageLook] を
 * 壊しても赤にならないため）。
 *
 * 期待値は、式を写した計算ではなく、Mac の Core Image で測った値そのもの（結果のファイルは手元・git の外）：
 *  - 色温度の行列 ＝ `edit-m1b-result.txt`「## 必ず測る点」（6783〜6797 行）の行列。
 *    ウォーム・クールの行き先 5500K・7500K は同じ表の行（6785・6786 行）
 *  - セピア ＝ `edit-m2-result.txt` 34 行（線形の灰 0.5 → 0.541142881, 0.483177513, 0.371928215）
 *  - 周辺減光 ＝ `edit-m3-result.txt` 496 行（512×512 の角 (0.000976562, 0.000976562) の倍率 0.778644979）と
 *    1040 行（中心 (0.500976562, 0.500976562) の倍率 0.999999166）
 * 数字は結果ファイルの文字列を 9 桁のまま機械的に写した。
 *
 * sRGB の変換は、このテストの中で独立に書いた（[encode]・[decode]。`SrgbTransfer` を期待値の計算に使わない）。
 */
class MeasuredFiltersTest {

    private class Measured(val name: String, val m: DoubleArray)

    /** 実測の行列（行優先 9 要素）。ウォーム・クール：6785・6786 行 */
    private val WARM_M = doubleArrayOf(1.037666416, 0.049603405, 0.010518676, -0.003761757, 0.986287349, 0.007518461, -0.003835517, -0.012238015, 0.849926711)
    private val COOL_M = doubleArrayOf(0.973945617, -0.032388862, -0.007973300, 0.002414512, 1.007295842, -0.006442592, 0.003102545, 0.010212458, 1.123511553)

    private val WARMTH_PLUS = Measured("暖かみ+1", doubleArrayOf(1.062715059, 0.083709032, 0.017105901, -0.006372089, 0.975894086, 0.011796000, -0.006124135, -0.019358856, 0.761602932))
    private val WARMTH_MINUS = Measured("暖かみ−1", doubleArrayOf(0.963260825, -0.045514978, -0.011300486, 0.003389587, 1.010109771, -0.009185508, 0.004411593, 0.014542859, 1.175768369))
    private val TINT_PLUS = Measured("色合い+1", doubleArrayOf(0.687005932, -0.601730648, -0.018438689, 0.049704520, 1.329806798, 0.059923556, -0.012493189, -0.070651523, 0.303363710))
    private val TINT_MINUS = Measured("色合い−1", doubleArrayOf(1.430205446, 0.827070653, 0.025346077, -0.068318803, 0.546684262, -0.082365451, 0.017171277, 0.097109471, 1.957513937))
    private val WARMTH_PLUS_TINT_PLUS = Measured("暖かみ+1・色合い+1", doubleArrayOf(0.802888983, -0.435738385, 0.009049726, 0.036829349, 1.272376431, 0.074412194, -0.021159930, -0.096131580, -0.021080818))
    private val WARMTH_MINUS_TINT_MINUS = Measured("暖かみ−1・色合い−1", doubleArrayOf(1.423978081, 0.821369714, 0.022697707, -0.067940241, 0.546104316, -0.085222955, 0.018390459, 0.101405827, 2.007960322))
    private val TEMP_PLUS = Measured("色温度+1", doubleArrayOf(0.963260825, -0.045514978, -0.011300486, 0.003389587, 1.010109771, -0.009185508, 0.004411593, 0.014542859, 1.175768369))
    private val TEMP_MINUS = Measured("色温度−1", doubleArrayOf(1.062715059, 0.083709032, 0.017105901, -0.006372089, 0.975894086, 0.011796000, -0.006124135, -0.019358856, 0.761602932))
    private val WB_PLUS = Measured("ホワイトバランス+1", doubleArrayOf(0.954826120, -0.055159100, -0.014188169, 0.004089450, 1.011513603, -0.011814381, 0.005612975, 0.018614075, 1.224382039))
    private val WB_MINUS = Measured("ホワイトバランス−1", doubleArrayOf(1.094577656, 0.128770831, 0.024874480, -0.009855867, 0.960762329, 0.016153428, -0.008642547, -0.026890880, 0.666461231))

    /** 試す色（ガンマ付きの 0〜1）：灰 0.5 と、色のついた 1 色 */
    private val GRAY = doubleArrayOf(0.5, 0.5, 0.5)
    private val COLORED = doubleArrayOf(0.25, 0.5, 0.75)

    // ---- 独立に書いた sRGB の変換と行列の掛け算 ----

    private fun decode(e: Double): Double = if (e <= 0.04045) e / 12.92 else ((e + 0.055) / 1.055).pow(2.4)

    private fun encode(l: Double): Double {
        val c = l.coerceIn(0.0, 1.0)
        return if (c <= 0.0031308) 12.92 * c else 1.055 * c.pow(1.0 / 2.4) - 0.055
    }

    /** ガンマ付きの色に、線形の空間で行列を掛け、切り詰めてガンマ付きに戻した期待値 */
    private fun expected(m: DoubleArray, c: DoubleArray): DoubleArray {
        val r = decode(c[0])
        val g = decode(c[1])
        val b = decode(c[2])
        return doubleArrayOf(
            encode(m[0] * r + m[1] * g + m[2] * b),
            encode(m[3] * r + m[4] * g + m[5] * b),
            encode(m[6] * r + m[7] * g + m[8] * b),
        )
    }

    private fun toolRecipe(vararg pairs: Pair<EditTool, Int>): ColorRecipe {
        var tools = ToolValues.NONE
        for ((tool, value) in pairs) tools = tools.with(tool, value)
        return ColorRecipe.of(PhotoEdit(tools = tools))
    }

    private fun assertColor(label: String, want: DoubleArray, got: DoubleArray, tolerance: Double) {
        for (i in 0 until 3) {
            assertTrue(abs(want[i] - got[i]) <= tolerance, "$label のチャンネル $i が期待 ${want[i]} から離れている（値 ${got[i]}）")
        }
    }

    private fun gray(v: Int): Int = (0xFF shl 24) or (v shl 16) or (v shl 8) or v

    // ---- ウォーム・クール ----

    @Test
    fun `ウォームを掛けた灰色が元の灰色と違う`() {
        val before = 128
        val pixels = intArrayOf(gray(before))
        ColorKernel.render(pixels, 1, 1, ColorFixtures.recipe(filter = FilterId.WARM), NormalizedRect.FULL, 1.0)
        val r = (pixels[0] ushr 16) and 0xFF
        val b = pixels[0] and 0xFF
        // 暖色：赤が増え、青が減る（元の灰 128 のまま、ではない）
        assertTrue(r > before + 5, "ウォームで赤が増えていない: $r")
        assertTrue(b < before - 5, "ウォームで青が減っていない: $b")
        // 実測の行列（5500K）から出した期待値と、四捨五入の分だけで一致する
        val want = expected(WARM_M, doubleArrayOf(before / 255.0, before / 255.0, before / 255.0))
        assertEquals((want[0] * 255.0).roundToInt().toDouble(), r.toDouble(), 1.0)
        assertEquals((want[2] * 255.0).roundToInt().toDouble(), b.toDouble(), 1.0)
    }

    @Test
    fun `クールを掛けた灰色が元の灰色と違う`() {
        val before = 128
        val pixels = intArrayOf(gray(before))
        ColorKernel.render(pixels, 1, 1, ColorFixtures.recipe(filter = FilterId.COOL), NormalizedRect.FULL, 1.0)
        val r = (pixels[0] ushr 16) and 0xFF
        val b = pixels[0] and 0xFF
        // 寒色：赤が減り、青が増える
        assertTrue(r < before - 3, "クールで赤が減っていない: $r")
        assertTrue(b > before + 5, "クールで青が増えていない: $b")
        val want = expected(COOL_M, doubleArrayOf(before / 255.0, before / 255.0, before / 255.0))
        assertEquals((want[0] * 255.0).roundToInt().toDouble(), r.toDouble(), 1.0)
        assertEquals((want[2] * 255.0).roundToInt().toDouble(), b.toDouble(), 1.0)
    }

    @Test
    fun `ウォームとクールは実測の行列（5500Kと7500K）を掛けた値になる（灰と色つきの色）`() {
        for ((filter, m, name) in listOf(
            Triple(FilterId.WARM, WARM_M, "ウォーム"),
            Triple(FilterId.COOL, COOL_M, "クール"),
        )) {
            for (c in listOf(GRAY, COLORED)) {
                val got = ColorKernel.renderColor(c[0], c[1], c[2], ColorFixtures.recipe(filter = filter))
                assertColor("$name ${c.toList()}", expected(m, c), got, 5e-5)
            }
        }
    }

    // ---- ツール（暖かみ・色合い・色温度・ホワイトバランス） ----

    @Test
    fun `暖かみ・色合い・色温度・ホワイトバランスは、ツールの値から実測の行列を掛けた値になる`() {
        // (ツールの値、期待する実測の行列)。ColorRecipe.of → ToolMapping の行き先 → 実測の表、の全部を通す
        val cases = listOf(
            Pair(toolRecipe(EditTool.WARMTH to 100), WARMTH_PLUS),                                 // 行き先 5000K・色合い 0
            Pair(toolRecipe(EditTool.WARMTH to -100), WARMTH_MINUS),                               // 8000K・0
            Pair(toolRecipe(EditTool.TINT to 100), TINT_PLUS),                                     // 6500K・250
            Pair(toolRecipe(EditTool.TINT to -100), TINT_MINUS),                                   // 6500K・−250
            Pair(toolRecipe(EditTool.WARMTH to 100, EditTool.TINT to 100), WARMTH_PLUS_TINT_PLUS), // 5000K・250（1 つの段）
            Pair(toolRecipe(EditTool.WARMTH to -100, EditTool.TINT to -100), WARMTH_MINUS_TINT_MINUS),
            Pair(toolRecipe(EditTool.COLOR_TEMPERATURE to 100), TEMP_PLUS),                        // 8000K・0
            Pair(toolRecipe(EditTool.COLOR_TEMPERATURE to -100), TEMP_MINUS),                      // 5000K・0
            Pair(toolRecipe(EditTool.WHITE_BALANCE to 100), WB_PLUS),                              // 8500K・0
            Pair(toolRecipe(EditTool.WHITE_BALANCE to -100), WB_MINUS),                            // 4500K・0
        )
        for ((recipe, measured) in cases) {
            for (c in listOf(GRAY, COLORED)) {
                val got = ColorKernel.renderColor(c[0], c[1], c[2], recipe)
                assertColor("${measured.name} ${c.toList()}", expected(measured.m, c), got, 5e-5)
            }
        }
    }

    @Test
    fun `暖かみ・色温度・ホワイトバランスで灰色が元の灰色と違う（向きも合う）`() {
        val warm = intArrayOf(gray(128), gray(128), gray(128), gray(128))
        // 暖かみ+1 と 色温度−1 は暖色（赤が増え青が減る）、暖かみ−1 と ホワイトバランス+1 は寒色
        val warmRecipe = toolRecipe(EditTool.WARMTH to 100)
        val coolRecipe = toolRecipe(EditTool.WHITE_BALANCE to 100)
        ColorKernel.render(warm, 2, 2, warmRecipe, NormalizedRect.FULL, 1.0)
        assertTrue(((warm[0] ushr 16) and 0xFF) > 128 && (warm[0] and 0xFF) < 128, "暖かみ+1 が暖色でない")
        val cool = intArrayOf(gray(128), gray(128), gray(128), gray(128))
        ColorKernel.render(cool, 2, 2, coolRecipe, NormalizedRect.FULL, 1.0)
        assertTrue(((cool[0] ushr 16) and 0xFF) < 128 && (cool[0] and 0xFF) > 128, "ホワイトバランス+1 が寒色でない")
    }

    // ---- ビンテージ ----

    /** 線形の灰 0.5 を、ガンマ付きにした値（セピアの実測の入力と同じ色） */
    private val SEPIA_INPUT_GAMMA = encode(0.5)

    /** 実測のセピア（線形の灰 0.5 の出力）。edit-m2-result.txt 34 行 */
    private val SEPIA_OUT = doubleArrayOf(0.541142881, 0.483177513, 0.371928215)

    /** 512×512 の標本の位置にぴったり重なる 1 画素の枠（その画素の中心が (cx, cy) になる） */
    private fun frameAt(cx: Double, cy: Double): NormalizedRect = NormalizedRect(cx - 0.001, cy - 0.001, cx + 0.001, cy + 0.001)

    @Test
    fun `ビンテージで中心と端の明るさが違う`() {
        // 1 画素ずつ、同じ灰を中心と角の位置で掛ける（位置は frame で決まる。fullAspect は 512×512 の標本と同じ 1.0）
        val center = intArrayOf(gray(188))
        val corner = intArrayOf(gray(188))
        val recipe = ColorFixtures.recipe(filter = FilterId.VINTAGE)
        ColorKernel.render(center, 1, 1, recipe, frameAt(0.500976562, 0.500976562), 1.0)
        ColorKernel.render(corner, 1, 1, recipe, frameAt(0.000976562, 0.000976562), 1.0)
        val centerR = (center[0] ushr 16) and 0xFF
        val cornerR = (corner[0] ushr 16) and 0xFF
        assertTrue(centerR > cornerR + 15, "中心 $centerR と角 $cornerR の明るさが近すぎる（周辺減光が効いていない）")
        // 角の青も暗い
        assertTrue((center[0] and 0xFF) > (corner[0] and 0xFF) + 10)
    }

    @Test
    fun `ビンテージの中心は実測のセピアの値・角は実測のセピアに実測の倍率0・7786を掛けた値になる`() {
        val recipe = ColorFixtures.recipe(filter = FilterId.VINTAGE)
        val input = doubleArrayOf(SEPIA_INPUT_GAMMA, SEPIA_INPUT_GAMMA, SEPIA_INPUT_GAMMA)
        // 中心：倍率 0.999999166（edit-m3-result.txt 1040 行）
        val centerWant = DoubleArray(3) { encode(SEPIA_OUT[it] * 0.999999166) }
        val center = ColorKernel.renderColor(input[0], input[1], input[2], recipe, 0.500976562, 0.500976562, 1.0)
        // セピアの許し幅は 1 階調（VintageLookTest と同じ）、倍率は線形で 0.003 以内。余裕を見て 2 階調
        assertColor("ビンテージの中心", centerWant, center, 2.0 / 255.0)
        // 角：倍率 0.778644979（edit-m3-result.txt 496 行）
        val cornerWant = DoubleArray(3) { encode(SEPIA_OUT[it] * 0.778644979) }
        val corner = ColorKernel.renderColor(input[0], input[1], input[2], recipe, 0.000976562, 0.000976562, 1.0)
        assertColor("ビンテージの角", cornerWant, corner, 2.0 / 255.0)
        // 中心の方が明るい（3 チャンネルとも）
        for (i in 0 until 3) assertTrue(center[i] > corner[i] + 0.03, "チャンネル $i：中心 ${center[i]} 角 ${corner[i]}")
        // 灰がセピアで色づく（赤＞緑＞青）
        assertTrue(center[0] > center[1] && center[1] > center[2], "セピアで色づいていない: ${center.toList()}")
    }
}
