// ⭐️ 点ごとの色の計算（ColorKernel）の単体テスト（Kiro android-edit-tools タスク 4・C1・design.md:1123 の①〜⑤⑦）
package com.yoshidometoru.soramoyou.contract.edit

import com.yoshidometoru.soramoyou.contract.model.FilterId
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * [ColorKernel] の 1 画素の手順（design.md:806-813）と不変の決まり（:815-818）を確かめる。
 *
 * ## 期待値の作り方
 * ②④と「段の間で切り詰めない」の期待値は、iOS の Metal の道の式（ExposureContrast.metal:38-50：利用者の判断 U2）と
 * design.md「色の式」の表から手で計算した数字である。計算には本体と別に書いた電卓のスクリプトを使い、テストには
 * 数字だけを写した（本体の式をテストの中に写して比べない）。途中の値（線形の値・各段の後の値）は各テストのコメントに書いた。
 * ③の期待値は FilterIdTest の「今の 6 種の表」の数字を行列として掛け、0〜1 に切り詰めた値。
 *
 * ## 色温度の段とビンテージ
 * 本物の TemperatureTint・VintageLook（K1② が中身を入れる）には頼らない。`internal` の差し替えの口
 * （[ColorKernel.renderColorWith]・[ColorKernel.renderWith] に渡す [ColorKernel.Parts]）に偽物を入れて、
 * 「呼んだ結果を掛けている」こと・渡す行き先と位置を確かめる（design.md:1172）。K1② の前後で結果は変わらない。
 *
 * ## 陽性対照（tasks.md:277）
 * - 露出の 2.0 を 1.0 にする（ColorKernel の 2^EV の底でも、ToolMapping.exposureEv の倍率でも）→「露出は…」が赤
 * - 明るさとコントラストの順を入れ替える（ColorKernel の TOOL_ORDER）→「灰128に…234」が 199 になって赤
 * - 段の間に 0〜1 の切り詰めを入れる → 明るさとコントラストの間なら「白に…線形1点0」が赤。
 *   ほかの境目は「フィルター・露出・コントラスト・彩度・ブラックポイント・色温度の後でも切り詰めない」が拾う
 *   （フィルター・暖かみ・色合い・色温度・ホワイトバランスの直後も含む）
 * - 彩度の位置の入れ替えは値が変わらない（design.md:847）ので対照に使わない
 */
class ColorKernelTest {

    // ---- 試す色（ガンマ付きの 0〜1）。電卓で、各ツールの結果が切り詰めに張り付かないように選んだ ----

    /** 暗い色（露出の ×4 と明るさの ＋0.5 でも 1 を超えない）。線形＝(0.1328683, 0.0732390, 0.0331048) */
    private val dark = doubleArrayOf(0.4, 0.3, 0.2)

    /** 明るい色（明るさの −0.5 でも 0 を下回らない）。線形＝(0.7874123, 0.6920711, 0.6038273) */
    private val bright = doubleArrayOf(0.9, 0.85, 0.8)

    /** コントラスト用（線形 0.5 から離れた値）。線形＝(0.3185468, 0.2140411, 0.5225216) */
    private val contrasty = doubleArrayOf(0.6, 0.5, 0.75)

    /** 色のある中間の色（彩度・ブラックポイント・色温度の段）。線形＝(0.3185468, 0.2140411, 0.1706449)、輝度 L＝0.2331258 */
    private val tinted = doubleArrayOf(0.6, 0.5, 0.45)

    /** フェード用（傾き 1.15・持ち上げ −0.2 でも 0 を下回らない）。線形＝(0.4479884, 0.3185468, 0.2632734) */
    private val faded = doubleArrayOf(0.7, 0.6, 0.55)

    // ---- 偽の部品 ----

    /** 偽の色温度の行列（行優先）。対角でも対称でもない（F[1]＝0.08・F[3]＝0.05）ので、行と列を取り違えると値が変わる */
    private val fakeMatrix = doubleArrayOf(
        0.9, 0.08, 0.02,
        0.05, 0.85, 0.1,
        0.03, 0.12, 0.7,
    )

    /** 偽の部品が呼ばれた記録 */
    private class Calls {
        val targets = mutableListOf<TemperatureTarget>()
        val sepiaInputs = mutableListOf<List<Double>>()
        val gainCalls = mutableListOf<Triple<Double, Double, Double>>()
    }

    /** 偽のセピア：0.5×入力＋(0.10, 0.06, 0.02)。定数を足す形なので、周辺減光との順が値に出る */
    private fun fakeSepia(rgb: DoubleArray) {
        rgb[0] = 0.5 * rgb[0] + 0.10
        rgb[1] = 0.5 * rgb[1] + 0.06
        rgb[2] = 0.5 * rgb[2] + 0.02
    }

    /** 偽の周辺減光の倍率：1−0.25|2nx−1|−0.25|2ny−1|。中心 1.0・辺の中点 0.75・角 0.5（nx と ny の両方で変わる） */
    private fun fakeGain(nx: Double, ny: Double): Double = 1.0 - 0.25 * abs(2.0 * nx - 1.0) - 0.25 * abs(2.0 * ny - 1.0)

    /** 記録を取る偽の部品。色温度の行列は [matrixOf] が行き先から返す（既定は全部 [fakeMatrix]） */
    private fun fakeParts(
        calls: Calls = Calls(),
        matrixOf: (TemperatureTarget) -> DoubleArray = { fakeMatrix.copyOf() },
    ): ColorKernel.Parts = ColorKernel.Parts(
        temperatureMatrix = { target ->
            calls.targets += target
            matrixOf(target)
        },
        sepia = { rgb ->
            calls.sepiaInputs += rgb.toList()
            fakeSepia(rgb)
        },
        vignetteGain = { nx, ny, fullAspect ->
            calls.gainCalls += Triple(nx, ny, fullAspect)
            fakeGain(nx, ny)
        },
    )

    /** 呼ばれたら落ちる部品（色温度の段もビンテージも無いレシピが、部品を呼ばないことを確かめる） */
    private val throwing = ColorKernel.Parts(
        temperatureMatrix = { error("色温度の行列を呼んだ") },
        sepia = { error("セピアを呼んだ") },
        vignetteGain = { _, _, _ -> error("周辺減光を呼んだ") },
    )

    // ---- 道具 ----

    /** フィルターとツールの値（百分の 1 の整数）から、本物の ColorRecipe.of でレシピを作る（ToolMapping も通る） */
    private fun recipeOf(filter: FilterId?, vararg tools: Pair<EditTool, Int>): ColorRecipe =
        ColorRecipe.of(PhotoEdit(filter = filter, tools = tools.fold(ToolValues.NONE) { acc, (tool, value) -> acc.with(tool, value) }))

    private fun colorOf(
        input: DoubleArray,
        recipe: ColorRecipe,
        parts: ColorKernel.Parts = throwing,
        nx: Double = 0.5,
        ny: Double = 0.5,
        fullAspect: Double = 1.0,
    ): DoubleArray = ColorKernel.renderColorWith(parts, input[0], input[1], input[2], recipe, nx, ny, fullAspect)

    private fun assertColor(expected: DoubleArray, actual: DoubleArray, tolerance: Double, message: String) {
        assertEquals(3, actual.size, message)
        for (i in 0 until 3) {
            assertEquals(expected[i], actual[i], tolerance, "$message の ${"RGB"[i]}（全体は ${actual.toList()}）")
        }
    }

    private fun argb(r: Int, g: Int, b: Int): Int = (0xFF shl 24) or (r shl 16) or (g shl 8) or b

    private fun channels(pixel: Int): List<Int> = listOf((pixel ushr 16) and 0xFF, (pixel ushr 8) and 0xFF, pixel and 0xFF)

    /** 電卓で出した値は小数 7 桁で写したので、許し幅は 1e-6 */
    private val tolerance = 1e-6

    // ---- ① 中立 ----

    @Test
    fun `中立・なし・ナチュラルでは試す色がそのまま（11点3）`() {
        val recipes = listOf(
            "IDENTITY" to ColorRecipe.IDENTITY,
            "なし" to ColorRecipe.of(PhotoEdit.NONE),
            "ナチュラル" to ColorRecipe.of(PhotoEdit(filter = FilterId.NATURAL)),
        )
        for ((name, recipe) in recipes) {
            for (color in ColorFixtures.COLORS) {
                // 許し幅なし：中立なら計算を通さずに入力のまま返す
                assertContentEquals(color, colorOf(color, recipe), "$name ${color.toList()}")
                assertContentEquals(color, ColorKernel.renderColor(color[0], color[1], color[2], recipe), "$name（公開の口）${color.toList()}")
            }
        }
    }

    @Test
    fun `中立ならrenderは画素を1つも変えない`() {
        // 不透明でない画素も含めて、1 ビットも変えない（design.md:816）
        val original = intArrayOf(
            argb(0, 0, 0), argb(255, 255, 255), argb(128, 128, 128),
            argb(200, 100, 50), 0x80123456.toInt(), 0x00ABCDEF,
        )
        for (recipe in listOf(ColorRecipe.IDENTITY, ColorRecipe.of(PhotoEdit(filter = FilterId.NATURAL)))) {
            val pixels = original.copyOf()
            ColorKernel.renderWith(throwing, pixels, 3, 2, recipe, NormalizedRect.FULL, 1.5)
            assertContentEquals(original, pixels)
            ColorKernel.render(pixels, 3, 2, recipe, NormalizedRect.FULL, 1.5)
            assertContentEquals(original, pixels)
        }
    }

    // ---- ② ツール 1 つずつ（v＝±0.5・±1） ----

    @Test
    fun `露出はスライダーの値から2のEV乗で掛かる`() {
        // EV＝2.0v（EditRecipe.swift:353）→ 線形 c×2^EV（ExposureContrast.metal:38-39）
        // dark の線形 (0.1328683, 0.0732390, 0.0331048)
        val cases = listOf(
            -100 to doubleArrayOf(0.2003601, 0.1442370, 0.0881139),  // ×0.25 → (0.0332171, 0.0183097, 0.0082762)
            -50 to doubleArrayOf(0.2858649, 0.2109495, 0.1360342),   // ×0.5 → (0.0664342, 0.0366195, 0.0165524)
            50 to doubleArrayOf(0.5523521, 0.4188681, 0.2853842),    // ×2 → (0.2657366, 0.1464779, 0.0662095)
            100 to doubleArrayOf(0.7557178, 0.5775381, 0.3993583),   // ×4 → (0.5314733, 0.2929558, 0.1324191)
        )
        for ((value, expected) in cases) {
            assertColor(expected, colorOf(dark, recipeOf(null, EditTool.EXPOSURE to value)), tolerance, "露出 $value")
        }
    }

    @Test
    fun `明るさは線形の値に足す`() {
        // b＝(v≥0 ? 0.5v : −0.5(−v)^1.5)（EditRecipe.swift:356-360）→ c＋b（ExposureContrast.metal:42）
        val cases = listOf(
            Triple(50, dark, doubleArrayOf(0.6521687, 0.6040029, 0.5685871)),      // ＋0.25 → (0.3828683, 0.3232390, 0.2831048)
            Triple(100, dark, doubleArrayOf(0.8168994, 0.7816793, 0.7567539)),     // ＋0.5 → (0.6328683, 0.5732390, 0.5331048)
            Triple(-50, bright, doubleArrayOf(0.8040036, 0.7453419, 0.6850917)),   // −0.1767767 → (0.6106356, 0.5152944, 0.4270506)
            Triple(-100, bright, doubleArrayOf(0.5725230, 0.4755117, 0.3555654)),  // −0.5 → (0.2874123, 0.1920711, 0.1038273)
        )
        for ((value, input, expected) in cases) {
            assertColor(expected, colorOf(input, recipeOf(null, EditTool.BRIGHTNESS to value)), tolerance, "明るさ $value")
        }
    }

    @Test
    fun `コントラストは線形の0点5を軸に掛かる`() {
        // k＝1＋(v≥0 ? 0.5v : −0.5(−v)^2)（EditRecipe.swift:364-368）→ (c−0.5)k＋0.5（ExposureContrast.metal:46）
        // contrasty の線形 (0.3185468, 0.2140411, 0.5225216)
        val cases = listOf(
            -100 to doubleArrayOf(0.6720954, 0.6318701, 0.7427255),  // k＝0.5 → (0.4092734, 0.3570206, 0.5112608)
            -50 to doubleArrayOf(0.6190436, 0.5368875, 0.7481900),   // k＝0.875 → (0.3412284, 0.2497860, 0.5197064)
            50 to doubleArrayOf(0.5593867, 0.4135335, 0.7536030),    // k＝1.25 → (0.2731835, 0.1425514, 0.5281519)
            100 to doubleArrayOf(0.5146165, 0.2955640, 0.7571836),   // k＝1.5 → (0.2278202, 0.0710617, 0.5337823)
        )
        for ((value, expected) in cases) {
            assertColor(expected, colorOf(contrasty, recipeOf(null, EditTool.CONTRAST to value)), tolerance, "コントラスト $value")
        }
    }

    @Test
    fun `彩度はBT709の輝度を軸に掛かる`() {
        // s＝1＋(v≥0 ? 1.5v^0.7 : −(−v))（EditRecipe.swift:384-388）→ L＋s(c−L)、L＝0.2126R＋0.7152G＋0.0722B（ExposureContrast.metal:49-50）
        // tinted の線形 (0.3185468, 0.2140411, 0.1706449)、L＝0.2331258
        val cases = listOf(
            -100 to doubleArrayOf(0.5201067, 0.5201067, 0.5201067),  // s＝0 → (L, L, L)
            -50 to doubleArrayOf(0.5618656, 0.5101786, 0.4866426),   // s＝0.5 → (0.2758363, 0.2235835, 0.2018854)
            50 to doubleArrayOf(0.6632466, 0.4804830, 0.3702321),    // s＝1.9233583 → (0.3974209, 0.1964191, 0.1129527)
            100 to doubleArrayOf(0.6990792, 0.4677715, 0.3073353),   // s＝2.5 → (0.4466782, 0.1854141, 0.0769236)
        )
        for ((value, expected) in cases) {
            assertColor(expected, colorOf(tinted, recipeOf(null, EditTool.SATURATION to value)), tolerance, "彩度 $value")
        }
    }

    @Test
    fun `ブラックポイントは線形の値に足す`() {
        // bias＝0.15v（EditRecipe.swift:380）→ c＋bias（FilterGraphBuilder.swift:873-883）
        val cases = listOf(
            -100 to doubleArrayOf(0.4474035, 0.2806941, 0.1544553),  // −0.15 → (0.1685468, 0.0640411, 0.0206449)
            -50 to doubleArrayOf(0.5306819, 0.4086912, 0.3417604),   // −0.075 → (0.2435468, 0.1390411, 0.0956449)
            50 to doubleArrayOf(0.6603209, 0.5740024, 0.5327790),    // ＋0.075 → (0.3935468, 0.2890411, 0.2456449)
            100 to doubleArrayOf(0.7142477, 0.6374661, 0.6017942),   // ＋0.15 → (0.4685468, 0.3640411, 0.3206449)
        )
        for ((value, expected) in cases) {
            assertColor(expected, colorOf(tinted, recipeOf(null, EditTool.BLACK_POINT to value)), tolerance, "ブラックポイント $value")
        }
    }

    @Test
    fun `フェードは傾きを掛けて持ち上げを足す`() {
        // gain＝1−0.15v・bias＝0.2v（FilterGraphBuilder.swift:1103-1104）→ c×gain＋bias（:1105-1109）
        // faded の線形 (0.4479884, 0.3185468, 0.2632734)
        val cases = listOf(
            -100 to doubleArrayOf(0.5971123, 0.4446381, 0.3538088),  // ×1.15−0.2 → (0.3151867, 0.1663288, 0.1027644)
            -50 to doubleArrayOf(0.6511821, 0.5295692, 0.4649470),   // ×1.075−0.1 → (0.3815875, 0.2424378, 0.1830189)
            50 to doubleArrayOf(0.7447558, 0.6611601, 0.6209325),    // ×0.925＋0.1 → (0.5143893, 0.3946558, 0.3435279)
            100 to doubleArrayOf(0.7862540, 0.7157628, 0.6827264),   // ×0.85＋0.2 → (0.5807902, 0.4707648, 0.4237824)
        )
        for ((value, expected) in cases) {
            assertColor(expected, colorOf(faded, recipeOf(null, EditTool.FADE to value)), tolerance, "フェード $value")
        }
    }

    @Test
    fun `暖かみ・色合い・色温度・ホワイトバランスは行き先の行列を行優先で掛ける`() {
        // 偽の行列を tinted の線形 (0.3185468, 0.2140411, 0.1706449) に行優先で掛ける
        // → (0.3072283, 0.2149268, 0.1546928) → (0.5902004, 0.5009557, 0.4297655)
        // （転置で掛けると (0.5860562, 0.5146956, 0.4198757) になって外れる）
        val expected = doubleArrayOf(0.5902004, 0.5009557, 0.4297655)
        // 行き先は ToolMapping の式（FilterGraphBuilder.swift:905-909, 920-921, 926-928, 935-937）
        val cases = listOf(
            Triple(EditTool.WARMTH, -100, TemperatureTarget(8000.0, 0.0)),
            Triple(EditTool.WARMTH, -50, TemperatureTarget(7250.0, 0.0)),
            Triple(EditTool.WARMTH, 50, TemperatureTarget(5750.0, 0.0)),
            Triple(EditTool.WARMTH, 100, TemperatureTarget(5000.0, 0.0)),
            Triple(EditTool.TINT, -100, TemperatureTarget(6500.0, -250.0)),
            Triple(EditTool.TINT, -50, TemperatureTarget(6500.0, -125.0)),
            Triple(EditTool.TINT, 50, TemperatureTarget(6500.0, 125.0)),
            Triple(EditTool.TINT, 100, TemperatureTarget(6500.0, 250.0)),
            Triple(EditTool.COLOR_TEMPERATURE, -100, TemperatureTarget(5000.0, 0.0)),
            Triple(EditTool.COLOR_TEMPERATURE, -50, TemperatureTarget(5750.0, 0.0)),
            Triple(EditTool.COLOR_TEMPERATURE, 50, TemperatureTarget(7250.0, 0.0)),
            Triple(EditTool.COLOR_TEMPERATURE, 100, TemperatureTarget(8000.0, 0.0)),
            Triple(EditTool.WHITE_BALANCE, -100, TemperatureTarget(4500.0, 0.0)),
            Triple(EditTool.WHITE_BALANCE, -50, TemperatureTarget(5500.0, 0.0)),
            Triple(EditTool.WHITE_BALANCE, 50, TemperatureTarget(7500.0, 0.0)),
            Triple(EditTool.WHITE_BALANCE, 100, TemperatureTarget(8500.0, 0.0)),
        )
        for ((tool, value, target) in cases) {
            val calls = Calls()
            val out = colorOf(tinted, recipeOf(null, tool to value), fakeParts(calls))
            assertEquals(listOf(target), calls.targets, "${tool.raw} $value の行き先")
            assertColor(expected, out, tolerance, "${tool.raw} $value")
            assertTrue(calls.sepiaInputs.isEmpty() && calls.gainCalls.isEmpty(), "${tool.raw} $value でビンテージの部品を呼んだ")
        }
    }

    @Test
    fun `ウォームは5500K、クールは7500Kの行列を掛ける`() {
        // FilterGraphBuilder.swift:517-529。結果は上と同じ偽の行列の値
        val expected = doubleArrayOf(0.5902004, 0.5009557, 0.4297655)
        for ((filter, target) in listOf(FilterId.WARM to TemperatureTarget(5500.0, 0.0), FilterId.COOL to TemperatureTarget(7500.0, 0.0))) {
            val calls = Calls()
            val out = colorOf(tinted, recipeOf(filter), fakeParts(calls))
            assertEquals(listOf(target), calls.targets, filter.raw)
            assertColor(expected, out, tolerance, filter.raw)
            assertTrue(calls.sepiaInputs.isEmpty() && calls.gainCalls.isEmpty(), "${filter.raw} でビンテージの部品を呼んだ")
        }
    }

    // ---- ③ 今の 6 種 ----

    @Test
    fun `今の6種はガンマ付きの値に行列を掛けて切り詰めた値`() {
        // FilterIdTest の「今の 6 種の表」を行列として掛け（5 列目は 255 で割る）、0〜1 に切り詰めた値
        val gray = doubleArrayOf(0.5, 0.5, 0.5)
        val orange = doubleArrayOf(200.0 / 255.0, 100.0 / 255.0, 50.0 / 255.0)
        val red = doubleArrayOf(1.0, 0.0, 0.0)
        val blueish = doubleArrayOf(0.25, 0.5, 0.75)
        val cases = listOf(
            Triple(FilterId.CLEAR, gray, doubleArrayOf(0.5, 0.5, 0.5)),
            Triple(FilterId.CLEAR, orange, doubleArrayOf(0.8324403, 0.3794991, 0.1530285)),
            Triple(FilterId.CLEAR, red, doubleArrayOf(1.0, 0.0, 0.0)),                 // 切り詰め前 (1.1076875, −0.0473125, −0.0473125)
            Triple(FilterId.CLEAR, blueish, doubleArrayOf(0.2149355, 0.5036855, 0.7924355)),
            Triple(FilterId.DRAMA, gray, doubleArrayOf(0.5, 0.5, 0.5)),
            Triple(FilterId.DRAMA, orange, doubleArrayOf(0.9535776, 0.3418129, 0.0359306)),
            Triple(FilterId.DRAMA, red, doubleArrayOf(1.0, 0.0, 0.0)),                 // 切り詰め前 (1.35475, −0.20525, −0.20525)
            Triple(FilterId.DRAMA, blueish, doubleArrayOf(0.1191260, 0.5091260, 0.8991260)),
            Triple(FilterId.SOFT, gray, doubleArrayOf(0.5, 0.5, 0.5)),
            Triple(FilterId.SOFT, orange, doubleArrayOf(0.6977494, 0.4153965, 0.2742200)),
            Triple(FilterId.SOFT, red, doubleArrayOf(0.8082500, 0.0882500, 0.0882500)),
            Triple(FilterId.SOFT, blueish, doubleArrayOf(0.3136820, 0.4936820, 0.6736820)),
            Triple(FilterId.MONOCHROME, gray, doubleArrayOf(0.6851755, 0.6851755, 0.6851755)),
            Triple(FilterId.MONOCHROME, orange, doubleArrayOf(0.6322155, 0.6322155, 0.6322155)),
            Triple(FilterId.MONOCHROME, red, doubleArrayOf(0.2911996, 0.2911996, 0.2911996)),
            Triple(FilterId.MONOCHROME, blueish, doubleArrayOf(0.6370762, 0.6370762, 0.6370762)),
            Triple(FilterId.PASTEL, gray, doubleArrayOf(0.6, 0.6, 0.6)),
            Triple(FilterId.PASTEL, orange, doubleArrayOf(0.7396165, 0.5278518, 0.4219694)),
            Triple(FilterId.PASTEL, red, doubleArrayOf(0.7665000, 0.2265000, 0.2265000)),
            Triple(FilterId.PASTEL, blueish, doubleArrayOf(0.4523640, 0.5873640, 0.7223640)),
            Triple(FilterId.VIVID, gray, doubleArrayOf(0.5, 0.5, 0.5)),
            Triple(FilterId.VIVID, orange, doubleArrayOf(1.0, 0.3290706, 0.0)),        // 切り詰め前 (1.0349529, 0.3290706, −0.0238706)
            Triple(FilterId.VIVID, red, doubleArrayOf(1.0, 0.0, 0.0)),                 // 切り詰め前 (1.5725, −0.2275, −0.2275)
            Triple(FilterId.VIVID, blueish, doubleArrayOf(0.0710600, 0.5210600, 0.9710600)),
        )
        for ((filter, input, expected) in cases) {
            // 行列の係数は Float なので、許し幅は FilterIdTest と同じ桁（1e-5）
            assertColor(expected, colorOf(input, recipeOf(filter)), 1e-5, "${filter.raw} ${input.toList()}")
        }
    }

    @Test
    fun `今の6種にツールを足すと、行列で切り詰めた後に線形のツールが掛かる`() {
        // ヴィヴィッドの赤：行列の後 (1.5725, −0.2275, −0.2275) → 切り詰め (1, 0, 0) → 線形 (1, 0, 0)
        // → 明るさ v＝−0.5（b＝−0.1767767）→ (0.8232233, −0.1767767, −0.1767767) → 切り詰めて戻す (0.9178625, 0, 0)
        // （行列の後に切り詰めないと、線形 2.8303783 から始まって R は 1.0 に張り付く）
        assertColor(
            doubleArrayOf(0.9178625, 0.0, 0.0),
            colorOf(doubleArrayOf(1.0, 0.0, 0.0), recipeOf(FilterId.VIVID, EditTool.BRIGHTNESS to -50)),
            1e-5,
            "ヴィヴィッドの赤＋明るさ −50",
        )
        // ドラマの (200,100,50)：行列の後 (0.9535776, 0.3418129, 0.0359306) → 線形 (0.8976282, 0.0956754, 0.0027810)
        // → 露出 v＝0.5（×2）→ (1.7952565, 0.1913507, 0.0055620) → 切り詰めて戻す (1.0, 0.4746817, 0.0662734)
        assertColor(
            doubleArrayOf(1.0, 0.4746817, 0.0662734),
            colorOf(doubleArrayOf(200.0 / 255.0, 100.0 / 255.0, 50.0 / 255.0), recipeOf(FilterId.DRAMA, EditTool.EXPOSURE to 50)),
            1e-5,
            "ドラマ＋露出 50",
        )
    }

    // ---- ④ 段の順 ----

    @Test
    fun `灰128に明るさプラス1とコントラストプラス1で234（明るさはコントラストの前）`() {
        // 灰 128 の線形 0.2158605 → 明るさ ＋0.5 → 0.7158605 → コントラスト 1.5：(0.7158605−0.5)×1.5＋0.5＝0.8237908
        // → ガンマ付き 0.9181419 → ×255＝234.13 → 234（design.md:846）
        // 入れ替える（コントラスト→明るさ）と 0.5737908 → 0.7820147 → 199
        val recipe = recipeOf(null, EditTool.BRIGHTNESS to 100, EditTool.CONTRAST to 100)
        val g = 128.0 / 255.0
        assertColor(doubleArrayOf(0.9181419, 0.9181419, 0.9181419), ColorKernel.renderColor(g, g, g, recipe), tolerance, "灰 128")
        val pixels = intArrayOf(argb(128, 128, 128))
        ColorKernel.render(pixels, 1, 1, recipe, NormalizedRect.FULL, 1.0)
        assertEquals(listOf(234, 234, 234), channels(pixels[0]))
    }

    @Test
    fun `露出とコントラストを両方動かすと露出が先`() {
        // tinted の線形 (0.3185468, 0.2140411, 0.1706449) → 露出 ×2 → (0.6370936, 0.4280823, 0.3412899)
        // → コントラスト 1.25 → (0.6713669, 0.4101029, 0.3016123) → (0.8386191, 0.6727091, 0.5852598)
        // （コントラストが先なら (0.7651078, 0.5704171, 0.4572845)）
        assertColor(
            doubleArrayOf(0.8386191, 0.6727091, 0.5852598),
            colorOf(tinted, recipeOf(null, EditTool.EXPOSURE to 50, EditTool.CONTRAST to 50)),
            tolerance,
            "露出 50・コントラスト 50",
        )
    }

    @Test
    fun `4つ組を全部動かした色はMetalの道の順の値`() {
        // 露出 v＝0.25（EV 0.5）・明るさ v＝0.2（b 0.1）・コントラスト v＝0.4（k 1.2）・彩度 v＝0.3（s＝1＋1.5×0.3^0.7＝1.6457674）
        // tinted の線形 → ×2^0.5 → (0.4504932, 0.3026999, 0.2413284) → ＋0.1 → (0.5504932, 0.4026999, 0.3413284)
        // → (c−0.5)×1.2＋0.5 → (0.5605918, 0.3832399, 0.3095941)、L＝0.4156277 → L＋s(c−L) → (0.6542049, 0.3623249, 0.2411210)
        // → (0.8290291, 0.6361039, 0.5282442)
        // （明るさとコントラストを入れ替えると (0.8176662, 0.6199452, 0.5075766)・露出と明るさを入れ替えると (0.8564190, 0.6741323, 0.5756185)）
        val recipe = recipeOf(
            null,
            EditTool.EXPOSURE to 25, EditTool.BRIGHTNESS to 20, EditTool.CONTRAST to 40, EditTool.SATURATION to 30,
        )
        assertColor(doubleArrayOf(0.8290291, 0.6361039, 0.5282442), colorOf(tinted, recipe), tolerance, "4 つ組")
    }

    /** 全部の段の確かめに使う、行き先ごとに違う偽の行列（どれも対角でも対称でもない） */
    private val warmTintFake = doubleArrayOf(0.95, 0.04, 0.01, 0.02, 0.9, 0.08, 0.0, 0.05, 1.1)
    private val colorTemperatureFake = doubleArrayOf(1.05, -0.03, 0.0, 0.01, 0.98, 0.0, 0.02, 0.0, 0.85)
    private val whiteBalanceFake = doubleArrayOf(0.9, 0.1, 0.0, 0.0, 1.0, 0.0, 0.05, 0.05, 0.92)

    private fun near(t: TemperatureTarget, kelvin: Double, tint: Double): Boolean =
        abs(t.kelvin - kelvin) < 1e-6 && abs(t.tint - tint) < 1e-6

    /** 全部の段のレシピの行き先から偽の行列を引く。知らない行き先は落とす（渡す行き先の確かめを兼ねる） */
    private val chainMatrixOf: (TemperatureTarget) -> DoubleArray = { t ->
        when {
            near(t, 6050.0, -50.0) -> warmTintFake.copyOf()
            near(t, 7250.0, 0.0) -> colorTemperatureFake.copyOf()
            near(t, 5500.0, 0.0) -> whiteBalanceFake.copyOf()
            else -> error("知らない行き先: $t")
        }
    }

    /** 10 個のツールを全部動かしたレシピ */
    private val allTools: ColorRecipe
        get() = recipeOf(
            null,
            EditTool.EXPOSURE to 25, EditTool.BRIGHTNESS to 20, EditTool.CONTRAST to 40, EditTool.SATURATION to -30,
            EditTool.BLACK_POINT to -40, EditTool.WARMTH to 30, EditTool.TINT to -20,
            EditTool.COLOR_TEMPERATURE to 50, EditTool.WHITE_BALANCE to -50, EditTool.FADE to 60,
        )

    @Test
    fun `全部の段が決まった順に掛かる`() {
        // 4 つ組（EV 0.5・b 0.1・k 1.2・s 0.7）→ (0.5171026, 0.3929562, 0.3414041)
        // → ブラックポイント −0.06 → (0.4571026, 0.3329562, 0.2814041)
        // → 暖かみ・色合い（行き先 (6050, −50)）の偽の行列 → (0.4503797, 0.3313150, 0.3261924)
        // → 色温度（(7250, 0)）→ (0.4629593, 0.3291925, 0.2862711)
        // → ホワイトバランス（(5500, 0)）→ (0.4495826, 0.3291925, 0.3029770)
        // → フェード ×0.91＋0.12 → (0.5291201, 0.4195651, 0.3957091) → (0.7542203, 0.6796586, 0.6619559)
        // （温度の 3 段を逆に掛けると (0.7544287, 0.6787403, 0.6635626)、フェードを前に出すと (0.7520165, 0.6748608, 0.6594478)）
        val calls = Calls()
        val out = colorOf(tinted, allTools, fakeParts(calls, chainMatrixOf))
        assertColor(doubleArrayOf(0.7542203, 0.6796586, 0.6619559), out, tolerance, "全部の段")
        assertEquals(3, calls.targets.size)
        assertEquals(
            setOf(TemperatureTarget(6050.0, -50.0), TemperatureTarget(7250.0, 0.0), TemperatureTarget(5500.0, 0.0)),
            calls.targets.map { t -> TemperatureTarget(t.kelvin.roundToInt().toDouble(), t.tint.roundToInt().toDouble()) }.toSet(),
        )
    }

    // ---- 段の間で切り詰めない ----

    @Test
    fun `白に明るさプラス1とコントラストマイナス1で線形1点0（段の間で切り詰めない）`() {
        // 白の線形 1.0 → 明るさ ＋0.5 → 1.5 → コントラスト 0.5：(1.5−0.5)×0.5＋0.5＝1.0 → 1.0
        // 明るさの後で 1.0 に切り詰めると (1.0−0.5)×0.5＋0.5＝0.75 → ガンマ付き 0.8808250 になって外れる
        val recipe = recipeOf(null, EditTool.BRIGHTNESS to 100, EditTool.CONTRAST to -100)
        assertColor(doubleArrayOf(1.0, 1.0, 1.0), colorOf(doubleArrayOf(1.0, 1.0, 1.0), recipe), tolerance, "白")
    }

    @Test
    fun `フィルター・露出・コントラスト・彩度・ブラックポイント・色温度の後でも切り詰めない`() {
        // 露出の後：(0.6, 0.3, 0.2) の線形 (0.3185468, 0.0732390, 0.0331048) → ×4 → R 1.2741871 → −0.5 → R 0.7741871
        // → (0.8932837, 0, 0)。露出の後で切り詰めると R は 0.5 → 0.7353570
        assertColor(
            doubleArrayOf(0.8932837, 0.0, 0.0),
            colorOf(doubleArrayOf(0.6, 0.3, 0.2), recipeOf(null, EditTool.EXPOSURE to 100, EditTool.BRIGHTNESS to -100)),
            tolerance,
            "露出の後",
        )
        // コントラストの後：(0.95, 0.5, 0.3) の線形 (0.8900054, 0.2140411, 0.0732390) → k 1.5 → R が 1 を超える → 彩度 0 で L＝0.2713778
        // → 0.5576914。コントラストの後で切り詰めると L＝0.2634233 → 0.5501435
        assertColor(
            doubleArrayOf(0.5576914, 0.5576914, 0.5576914),
            colorOf(doubleArrayOf(0.95, 0.5, 0.3), recipeOf(null, EditTool.CONTRAST to 100, EditTool.SATURATION to -100)),
            tolerance,
            "コントラストの後",
        )
        // 彩度の後：(0.7, 0.2, 0.2) の線形 (0.4479884, 0.0331048, 0.0331048) → s 2.5 → (0.9380075, −0.0992016, −0.0992016)
        // → ＋0.15 → (1.0880075, 0.0507984, 0.0507984) → (1.0, 0.2498058, 0.2498058)。彩度の後で切り詰めると G・B は 0.4235829
        assertColor(
            doubleArrayOf(1.0, 0.2498058, 0.2498058),
            colorOf(doubleArrayOf(0.7, 0.2, 0.2), recipeOf(null, EditTool.SATURATION to 100, EditTool.BLACK_POINT to 100)),
            tolerance,
            "彩度の後",
        )
        // ブラックポイントの後：(0.6, 0.25, 0.1) の線形 (0.3185468, 0.0508761, 0.0100228) → −0.15 → G・B が負
        // → ×0.85＋0.2 → (0.3432648, 0.1157447, 0.0810194) → (0.6207167, 0.3745805, 0.3152524)。間で切り詰めると G・B は 0.4845292
        assertColor(
            doubleArrayOf(0.6207167, 0.3745805, 0.3152524),
            colorOf(doubleArrayOf(0.6, 0.25, 0.1), recipeOf(null, EditTool.BLACK_POINT to -100, EditTool.FADE to 100)),
            tolerance,
            "ブラックポイントの後",
        )
        // 色温度の後：偽の行列 diag(−0.2, 1, 1) で tinted の R を負にする → R −0.0637094 → ×0.85＋0.2 → 0.1458470
        // → (0.4180167, 0.6514499, 0.6221773)。間で切り詰めると R は 0.2 → 0.4845292
        val negativeRed = doubleArrayOf(-0.2, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
        assertColor(
            doubleArrayOf(0.4180167, 0.6514499, 0.6221773),
            colorOf(
                tinted,
                recipeOf(null, EditTool.COLOR_TEMPERATURE to 50, EditTool.FADE to 100),
                fakeParts(matrixOf = { negativeRed.copyOf() }),
            ),
            tolerance,
            "色温度の後",
        )
        // フィルター（手順 4）・暖かみ・ホワイトバランスの後：同じ偽の行列を返させ、フェード v＝1 を足す
        // → どれも上と同じ計算で (0.4180167, 0.6514499, 0.6221773)
        val sameAsColorTemperature = listOf(
            "フィルター（ウォーム）の後" to recipeOf(FilterId.WARM, EditTool.FADE to 100),
            "暖かみの後" to recipeOf(null, EditTool.WARMTH to 50, EditTool.FADE to 100),
            "ホワイトバランスの後" to recipeOf(null, EditTool.WHITE_BALANCE to 50, EditTool.FADE to 100),
        )
        for ((name, recipe) in sameAsColorTemperature) {
            assertColor(
                doubleArrayOf(0.4180167, 0.6514499, 0.6221773),
                colorOf(tinted, recipe, fakeParts(matrixOf = { negativeRed.copyOf() })),
                tolerance,
                name,
            )
        }
    }

    // ---- ⑤ render と renderColor ----

    /** 8×9 の試す画素（はっきりした色 8 つ＋決まった式で散らした色） */
    private fun samplePixels(width: Int, height: Int): IntArray {
        val fixed = intArrayOf(
            argb(0, 0, 0), argb(255, 255, 255), argb(128, 128, 128), argb(200, 100, 50),
            argb(255, 0, 0), argb(0, 255, 0), argb(0, 0, 255), argb(64, 128, 191),
        )
        return IntArray(width * height) { i ->
            if (i < fixed.size) fixed[i] else argb((i * 37 + 11) % 256, (i * 71 + 5) % 256, (i * 113 + 29) % 256)
        }
    }

    /** 確かめるレシピ（ツール 1 つずつの ±0.5・±1、今の 6 種とツール付き、新しい 3 種、全部の段） */
    private fun sampleRecipes(): List<Pair<String, ColorRecipe>> {
        val list = mutableListOf<Pair<String, ColorRecipe>>()
        for (tool in EditTool.entries.filter { it.isSlider }) {
            for (value in listOf(-100, -50, 50, 100)) list += "${tool.raw}=$value" to recipeOf(null, tool to value)
        }
        for (filter in listOf(FilterId.CLEAR, FilterId.DRAMA, FilterId.SOFT, FilterId.MONOCHROME, FilterId.PASTEL, FilterId.VIVID)) {
            list += filter.raw to recipeOf(filter)
            list += "${filter.raw}＋露出 30" to recipeOf(filter, EditTool.EXPOSURE to 30)
        }
        list += "warm" to recipeOf(FilterId.WARM)
        list += "cool" to recipeOf(FilterId.COOL)
        list += "vintage" to recipeOf(FilterId.VINTAGE)
        list += "vintage＋コントラスト 40＋フェード −30" to recipeOf(FilterId.VINTAGE, EditTool.CONTRAST to 40, EditTool.FADE to -30)
        list += "natural＋彩度 60" to recipeOf(FilterId.NATURAL, EditTool.SATURATION to 60)
        list += "全部の段" to allTools
        return list
    }

    @Test
    fun `renderはrenderColorを四捨五入した値と1階調以内で、不透明の画素にする`() {
        val width = 8
        val height = 9
        val fullAspect = width.toDouble() / height
        val source = samplePixels(width, height)
        for ((name, recipe) in sampleRecipes()) {
            val parts = fakeParts()
            val pixels = source.copyOf()
            ColorKernel.renderWith(parts, pixels, width, height, recipe, NormalizedRect.FULL, fullAspect)
            for (y in 0 until height) {
                for (x in 0 until width) {
                    val index = y * width + x
                    val input = channels(source[index])
                    // 画素の中心の位置（FULL なので全体の割合そのもの）
                    val expected = ColorKernel.renderColorWith(
                        parts, input[0] / 255.0, input[1] / 255.0, input[2] / 255.0, recipe,
                        nx = (x + 0.5) / width, ny = (y + 0.5) / height, fullAspect = fullAspect,
                    )
                    val actual = channels(pixels[index])
                    for (i in 0 until 3) {
                        val rounded = (expected[i] * 255.0).roundToInt()
                        assertTrue(abs(actual[i] - rounded) <= 1, "$name 画素($x, $y) の ${"RGB"[i]}：render ${actual[i]}・renderColor $rounded")
                    }
                    assertEquals(0xFF, pixels[index] ushr 24, "$name 画素($x, $y) の不透明度")
                }
            }
        }
    }

    @Test
    fun `公開のrenderとrenderColorも同じ値になる（部品を使わないレシピ）`() {
        val width = 8
        val height = 9
        val source = samplePixels(width, height)
        val withoutParts = sampleRecipes().filter { (_, r) ->
            r.filter != FilterId.WARM && r.filter != FilterId.COOL && r.filter != FilterId.VINTAGE &&
                r.warmTint == null && r.colorTemperature == null && r.whiteBalance == null
        }
        assertTrue(withoutParts.size > 30, "部品を使わないレシピが ${withoutParts.size} 個しかない")
        for ((name, recipe) in withoutParts) {
            val pixels = source.copyOf()
            ColorKernel.render(pixels, width, height, recipe, NormalizedRect.FULL, 1.0)
            for (index in source.indices) {
                val input = channels(source[index])
                val expected = ColorKernel.renderColor(input[0] / 255.0, input[1] / 255.0, input[2] / 255.0, recipe)
                val actual = channels(pixels[index])
                for (i in 0 until 3) {
                    assertTrue(abs(actual[i] - (expected[i] * 255.0).roundToInt()) <= 1, "$name 画素 $index の ${"RGB"[i]}")
                }
            }
        }
    }

    @Test
    fun `画素の数が幅と高さに足りなければ落ち、多ければ先頭だけを掛ける`() {
        val recipe = recipeOf(null, EditTool.EXPOSURE to 10)
        assertFailsWith<IllegalArgumentException> {
            ColorKernel.render(IntArray(3), 2, 2, recipe, NormalizedRect.FULL, 1.0)
        }
        // 帯ごとに同じ配列を使い回す形（2×1 の帯に 4 個の配列）：先頭の 2 個だけが変わり、残りはそのまま
        val pixels = intArrayOf(argb(100, 100, 100), argb(100, 100, 100), 0x11223344, 0x55667788)
        ColorKernel.render(pixels, 2, 1, recipe, NormalizedRect.FULL, 2.0)
        assertFalse(pixels[0] == argb(100, 100, 100), "先頭の画素が変わっていない")
        assertEquals(pixels[0], pixels[1])
        assertEquals(0x11223344, pixels[2])
        assertEquals(0x55667788, pixels[3])
    }

    // ---- ⑦ ビンテージ ----

    @Test
    fun `ビンテージはセピアの後に周辺減光を掛け、セピアには線形の値を渡す`() {
        // 灰 0.5 の線形 0.2140411 → 偽のセピア → (0.2070206, 0.1670206, 0.1270206)
        // → 角 (0, 0) の偽の倍率 0.5 → (0.1035103, 0.0835103, 0.0635103) → (0.3550425, 0.3199535, 0.2795319)
        // （倍率を先に掛けると (0.4282180, 0.3711055, 0.3005474) になって外れる）
        val calls = Calls()
        val out = colorOf(doubleArrayOf(0.5, 0.5, 0.5), recipeOf(FilterId.VINTAGE), fakeParts(calls), nx = 0.0, ny = 0.0, fullAspect = 1.5)
        assertColor(doubleArrayOf(0.3550425, 0.3199535, 0.2795319), out, tolerance, "角")
        assertEquals(1, calls.sepiaInputs.size)
        for (v in calls.sepiaInputs.single()) assertEquals(0.2140411405, v, 1e-9, "セピアに渡した値（線形）")
        assertEquals(listOf(Triple(0.0, 0.0, 1.5)), calls.gainCalls)
        assertTrue(calls.targets.isEmpty(), "ビンテージで色温度の行列を呼んだ")

        // renderColor の nx・ny・fullAspect がそのまま倍率に渡る：(0.25, 0.75) は倍率 0.75 → (0.4305123, 0.3889651, 0.3411036)
        val calls2 = Calls()
        val out2 = colorOf(doubleArrayOf(0.5, 0.5, 0.5), recipeOf(FilterId.VINTAGE), fakeParts(calls2), nx = 0.25, ny = 0.75, fullAspect = 1.5)
        assertColor(doubleArrayOf(0.4305123, 0.3889651, 0.3411036), out2, tolerance, "(0.25, 0.75)")
        assertEquals(listOf(Triple(0.25, 0.75, 1.5)), calls2.gainCalls)

        // 中心は倍率 1.0 → (0.4923411, 0.4455029, 0.3915465)
        assertColor(
            doubleArrayOf(0.4923411, 0.4455029, 0.3915465),
            colorOf(doubleArrayOf(0.5, 0.5, 0.5), recipeOf(FilterId.VINTAGE), fakeParts()),
            tolerance,
            "中心",
        )
    }

    @Test
    fun `ビンテージはツールより前に掛かる`() {
        // 灰 0.5 の中心：セピア → (0.2070206, 0.1670206, 0.1270206) → 倍率 1 → 露出 ×2 → (0.4140411, 0.3340411, 0.2540411)
        // → (0.6756128, 0.6130912, 0.5410680)（露出が先なら (0.5961237, 0.5601897, 0.5210465)）
        assertColor(
            doubleArrayOf(0.6756128, 0.6130912, 0.5410680),
            colorOf(doubleArrayOf(0.5, 0.5, 0.5), recipeOf(FilterId.VINTAGE, EditTool.EXPOSURE to 50), fakeParts()),
            tolerance,
            "ビンテージ＋露出 50",
        )
    }

    @Test
    fun `ビンテージは中心が端より明るい`() {
        // 5×5 の灰 128 を FULL で。中心の画素 (2, 2) は位置 (0.5, 0.5)・倍率 1.0 → (0.4933420, 0.4466369, 0.3928762) → (126, 114, 100)
        // 角の画素 (0, 0) は位置 (0.1, 0.1)・倍率 0.6 → (0.3882151, 0.3504642, 0.3070104) → (99, 89, 78)
        val pixels = IntArray(25) { argb(128, 128, 128) }
        ColorKernel.renderWith(fakeParts(), pixels, 5, 5, recipeOf(FilterId.VINTAGE), NormalizedRect.FULL, 1.0)
        val center = channels(pixels[2 * 5 + 2])
        val corner = channels(pixels[0])
        assertEquals(listOf(126, 114, 100), center)
        assertEquals(listOf(99, 89, 78), corner)
        for (i in 0 until 3) assertTrue(center[i] > corner[i], "${"RGB"[i]}：中心 ${center[i]}・角 ${corner[i]}")
    }

    @Test
    fun `周辺減光の位置はframeと画素の中心で決まる`() {
        // 4×2 の帯が全体の (0.25, 0.25)〜(0.75, 0.75) に当たるとき、画素 (x, y) の位置は
        // nx＝0.25＋(x＋0.5)÷4×0.5 → 0.3125・0.4375・0.5625・0.6875、ny＝0.25＋(y＋0.5)÷2×0.5 → 0.375・0.625
        val calls = Calls()
        val pixels = IntArray(8) { argb(128, 128, 128) }
        ColorKernel.renderWith(fakeParts(calls), pixels, 4, 2, recipeOf(FilterId.VINTAGE), NormalizedRect(0.25, 0.25, 0.75, 0.75), 2.0)
        val expected = listOf(0.3125, 0.4375, 0.5625, 0.6875).flatMap { nx -> listOf(0.375, 0.625).map { ny -> Triple(nx, ny, 2.0) } }.toSet()
        assertEquals(expected, calls.gainCalls.toSet())
    }

    @Test
    fun `同じ場所なら切り抜いても同じ値で、frameが違えば値が変わる`() {
        // 8×4 の全体を FULL で掛けた結果と、その (2, 1)〜(5, 2) の 4×2 を frame (0.25, 0.25, 0.75, 0.75) で掛けた結果は同じ画素になる
        val fullWidth = 8
        val fullHeight = 4
        val full = IntArray(fullWidth * fullHeight) { i ->
            val x = i % fullWidth
            val y = i / fullWidth
            argb((x * 29 + y * 7 + 40) % 256, (x * 13 + y * 31 + 90) % 256, (x * 53 + y * 17 + 10) % 256)
        }
        val crop = IntArray(4 * 2) { j -> full[(j / 4 + 1) * fullWidth + (j % 4 + 2)] }
        val recipe = recipeOf(FilterId.VINTAGE, EditTool.CONTRAST to 40)

        val fullOut = full.copyOf()
        ColorKernel.renderWith(fakeParts(), fullOut, fullWidth, fullHeight, recipe, NormalizedRect.FULL, 2.0)
        val cropOut = crop.copyOf()
        ColorKernel.renderWith(fakeParts(), cropOut, 4, 2, recipe, NormalizedRect(0.25, 0.25, 0.75, 0.75), 2.0)
        for (j in cropOut.indices) {
            assertEquals(fullOut[(j / 4 + 1) * fullWidth + (j % 4 + 2)], cropOut[j], "切り抜いた画素 $j")
        }

        // 同じ 4×2 でも、全体の絵の別の場所（FULL＝全体そのもの）として掛けると値が変わる
        val asWhole = crop.copyOf()
        ColorKernel.renderWith(fakeParts(), asWhole, 4, 2, recipe, NormalizedRect.FULL, 2.0)
        assertFalse(asWhole.contentEquals(cropOut), "frame を変えても値が同じ（位置を見ていない）")
    }

    @Test
    fun `位置を使うのはビンテージだけ`() {
        // 全部の段（色温度の系統を含む）でも、位置を変えて値が変わらず、周辺減光とセピアを呼ばない
        val calls = Calls()
        val parts = fakeParts(calls, chainMatrixOf)
        val atCorner = colorOf(tinted, allTools, parts, nx = 0.0, ny = 0.0, fullAspect = 1.0)
        val atOther = colorOf(tinted, allTools, parts, nx = 1.0, ny = 0.7, fullAspect = 3.0)
        assertContentEquals(atCorner, atOther)
        assertTrue(calls.gainCalls.isEmpty() && calls.sepiaInputs.isEmpty())
    }
}
