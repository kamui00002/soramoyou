// ⭐️ 色温度の部品の単体テスト（Kiro android-edit-tools タスク 3・K1②・要件 2.1・3.2・11.1・11.2）
package com.yoshidometoru.soramoyou.contract.edit

import kotlin.math.abs
import kotlin.math.pow
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotSame
import kotlin.test.assertTrue

/**
 * [TemperatureTint.matrix] が、Core Image の `CITemperatureAndTint`（基準 6500K・色合い 0）の実測と合うことを確かめる。
 *
 * 期待値は、行列の式を写して計算した値ではなく、Mac（Apple M3・macOS 27.2.1）の Core Image で測った行列そのもの。
 * 出どころ：手元（git の外）の台本 `edit-m1b-temperature.swift`・結果 `edit-m1b-result.txt`（2026-11-12）。
 *  - [POINTS] ＝ 結果の「## 必ず測る点」の 15 行（表の点そのもの。ウォーム・クール・ツールの端の行き先）
 *  - [MIDS]   ＝ 結果の「## 刻みの真ん中」から選んだ 15 点（表に無い点。つないだ行列が実測と合うかを見る）。
 *    3 種類（色温度の向き・色合いの向き・升の中心）を含み、いちばんずれの大きい (6650K, 色合い 237.5) を必ず含む
 *    （表の点を表と比べても同じことの言い直しになるので、表に無い点で確かめる）
 * 数字は結果ファイルの文字列を 9 桁のまま機械的に写した。
 *
 * 「1 階調」の式：線形の値を 0〜1 に切り詰め → sRGB の伝達関数 → ×255、丸めずに差の絶対値（[tone]。`SrgbTransfer` とは
 * 別に、このテストの中で独立に書いた）。
 */
class TemperatureTintTest {

    private class Point(val name: String, val kelvin: Double, val tint: Double, val measured: DoubleArray)

    private class Mid(val kind: String, val kelvin: Double, val tint: Double, val measured: DoubleArray)

    /** 線形の sRGB の試験色（0〜1）。黒・白・灰・暗い色・原色・普通の色 */
    private val COLORS = listOf(
        doubleArrayOf(0.0, 0.0, 0.0),
        doubleArrayOf(1.0, 1.0, 1.0),
        doubleArrayOf(0.5, 0.5, 0.5),
        doubleArrayOf(0.2158, 0.2158, 0.2158),
        doubleArrayOf(0.05, 0.05, 0.05),
        doubleArrayOf(1.0, 0.0, 0.0),
        doubleArrayOf(0.0, 1.0, 0.0),
        doubleArrayOf(0.0, 0.0, 1.0),
        doubleArrayOf(0.8, 0.3, 0.1),
        doubleArrayOf(0.1, 0.6, 0.9),
        doubleArrayOf(0.6, 0.6, 0.2),
        doubleArrayOf(0.3, 0.1, 0.5),
    )

    /** 実測（結果の「## 必ず測る点」）。表の点そのもの */
    private val POINTS = listOf(
        Point("基準", 6500.0, 0.0, doubleArrayOf(0.999999997, -0.000000000, 0.000000002, 0.000000005, 0.999999999, -0.000000004, -0.000000002, 0.000000002, 1.000000004)),
        Point("ウォーム", 5500.0, 0.0, doubleArrayOf(1.037666416, 0.049603405, 0.010518676, -0.003761757, 0.986287349, 0.007518461, -0.003835517, -0.012238015, 0.849926711)),
        Point("クール", 7500.0, 0.0, doubleArrayOf(0.973945617, -0.032388862, -0.007973300, 0.002414512, 1.007295842, -0.006442592, 0.003102545, 0.010212458, 1.123511553)),
        Point("暖かみ+1", 5000.0, 0.0, doubleArrayOf(1.062715059, 0.083709032, 0.017105901, -0.006372089, 0.975894086, 0.011796000, -0.006124135, -0.019358856, 0.761602932)),
        Point("暖かみ−1", 8000.0, 0.0, doubleArrayOf(0.963260825, -0.045514978, -0.011300486, 0.003389587, 1.010109771, -0.009185508, 0.004411593, 0.014542859, 1.175768369)),
        Point("色合い+1", 6500.0, 250.0, doubleArrayOf(0.687005932, -0.601730648, -0.018438689, 0.049704520, 1.329806798, 0.059923556, -0.012493189, -0.070651523, 0.303363710)),
        Point("色合い−1", 6500.0, -250.0, doubleArrayOf(1.430205446, 0.827070653, 0.025346077, -0.068318803, 0.546684262, -0.082365451, 0.017171277, 0.097109471, 1.957513937)),
        Point("暖かみ+1・色合い+1", 5000.0, 250.0, doubleArrayOf(0.802888983, -0.435738385, 0.009049726, 0.036829349, 1.272376431, 0.074412194, -0.021159930, -0.096131580, -0.021080818)),
        Point("暖かみ+1・色合い−1", 5000.0, -250.0, doubleArrayOf(1.439718714, 0.837419287, 0.028795250, -0.069056708, 0.545702869, -0.079059150, 0.015692565, 0.092037178, 1.897265097)),
        Point("暖かみ−1・色合い+1", 8000.0, 250.0, doubleArrayOf(0.615048527, -0.700710595, -0.036996480, 0.057301012, 1.360807305, 0.048283949, -0.006153726, -0.051108568, 0.546793823)),
        Point("暖かみ−1・色合い−1", 8000.0, -250.0, doubleArrayOf(1.423978081, 0.821369714, 0.022697707, -0.067940241, 0.546104316, -0.085222955, 0.018390459, 0.101405827, 2.007960322)),
        Point("色温度+1", 8000.0, 0.0, doubleArrayOf(0.963260825, -0.045514978, -0.011300486, 0.003389587, 1.010109771, -0.009185508, 0.004411593, 0.014542859, 1.175768369)),
        Point("色温度−1", 5000.0, 0.0, doubleArrayOf(1.062715059, 0.083709032, 0.017105901, -0.006372089, 0.975894086, 0.011796000, -0.006124135, -0.019358856, 0.761602932)),
        Point("ホワイトバランス+1", 8500.0, 0.0, doubleArrayOf(0.954826120, -0.055159100, -0.014188169, 0.004089450, 1.011513603, -0.011814381, 0.005612975, 0.018614075, 1.224382039)),
        Point("ホワイトバランス−1", 4500.0, 0.0, doubleArrayOf(1.094577656, 0.128770831, 0.024874480, -0.009855867, 0.960762329, 0.016153428, -0.008642547, -0.026890880, 0.666461231)),
    )

    /** 実測（結果の「## 刻みの真ん中」から選んだ点）。表に無い点 */
    private val MIDS = listOf(
        Mid("色温度の向き", 6650.0, 237.5, doubleArrayOf(0.691941736, -0.587715150, -0.019794600, 0.048480138, 1.319451104, 0.056055579, -0.011236801, -0.065421832, 0.360763910)),
        Mid("色温度の向き", 6650.0, 137.5, doubleArrayOf(0.809604276, -0.362129806, -0.012636766, 0.029855256, 1.196175100, 0.033929493, -0.006685677, -0.039426634, 0.616280324)),
        Mid("色温度の向き", 4950.0, 200.0, doubleArrayOf(0.852844654, -0.338352985, 0.011503268, 0.028765195, 1.218204742, 0.063978999, -0.018851035, -0.083631687, 0.103904606)),
        Mid("色温度の向き", 5350.0, -250.0, doubleArrayOf(1.437390918, 0.835103123, 0.027872705, -0.068897178, 0.545697032, -0.080007640, 0.016104943, 0.093474690, 1.914222001)),
        Mid("色温度の向き", 6950.0, -250.0, doubleArrayOf(1.428240064, 0.825346274, 0.024482928, -0.068206619, 0.546415810, -0.083315771, 0.017573637, 0.098533681, 1.974205006)),
        Mid("色合いの向き", 4500.0, 168.75, doubleArrayOf(0.925893353, -0.215478280, 0.022195714, 0.018873970, 1.161231643, 0.061334093, -0.020045520, -0.083110034, 0.086411179)),
        Mid("色合いの向き", 4800.0, 193.75, doubleArrayOf(0.872995072, -0.305686170, 0.014899517, 0.026156228, 1.203887356, 0.064042431, -0.019467949, -0.084604361, 0.086486527)),
        Mid("色合いの向き", 4600.0, 206.25, doubleArrayOf(0.882565140, -0.297685844, 0.019246182, 0.025648511, 1.205644838, 0.068924945, -0.021519602, -0.091898456, 0.001162204)),
        Mid("色合いの向き", 5300.0, -143.75, doubleArrayOf(1.252840415, 0.469556438, 0.020910359, -0.038543645, 0.752401643, -0.037733694, 0.006223090, 0.042043764, 1.393249874)),
        Mid("色合いの向き", 6900.0, 56.25, doubleArrayOf(0.907368112, -0.169428633, -0.008605240, 0.013867597, 1.087749968, 0.012144648, -0.001671708, -0.013039551, 0.882584338)),
        Mid("升の中心", 6650.0, 56.25, doubleArrayOf(0.915617832, -0.158878208, -0.006187577, 0.013074295, 1.085103866, 0.013993969, -0.002585122, -0.016005052, 0.846499808)),
        Mid("升の中心", 5750.0, 81.25, doubleArrayOf(0.922454710, -0.168929796, 0.002653733, 0.014246142, 1.104315398, 0.027663908, -0.007741044, -0.035551911, 0.623865193)),
        Mid("升の中心", 4850.0, 231.25, doubleArrayOf(0.834542386, -0.380347819, 0.012902025, 0.032334354, 1.245244145, 0.071879891, -0.021175115, -0.093953744, -0.006649068)),
        Mid("升の中心", 5350.0, -243.75, doubleArrayOf(1.425526048, 0.811657829, 0.027404698, -0.066951176, 0.558922408, -0.077326007, 0.015482750, 0.090219123, 1.881303083)),
        Mid("升の中心", 6950.0, -243.75, doubleArrayOf(1.415303935, 0.800665453, 0.023652100, -0.066170690, 0.559831800, -0.080961021, 0.017101480, 0.095785306, 1.947348967)),
    )

    /** 1 階調の式の 1 つ分：線形の値を 0〜1 に切り詰め → sRGB の伝達関数 → ×255（丸めない） */
    private fun tone(linear: Double): Double {
        val c = linear.coerceIn(0.0, 1.0)
        val encoded = if (c <= 0.0031308) 12.92 * c else 1.055 * c.pow(1.0 / 2.4) - 0.055
        return encoded * 255.0
    }

    /** 3×3（行優先）を 1 色に掛ける */
    private fun apply(m: DoubleArray, c: DoubleArray): DoubleArray =
        DoubleArray(3) { i -> m[3 * i] * c[0] + m[3 * i + 1] * c[1] + m[3 * i + 2] * c[2] }

    /** 2 つの行列を全部の試験色に掛けた結果の、1 階調の式での差の最大 */
    private fun maxToneDiff(a: DoubleArray, b: DoubleArray): Double {
        var worst = 0.0
        for (c in COLORS) {
            val x = apply(a, c)
            val y = apply(b, c)
            for (i in 0 until 3) worst = maxOf(worst, abs(tone(x[i]) - tone(y[i])))
        }
        return worst
    }

    private fun maxAbsDiff(a: DoubleArray, b: DoubleArray): Double {
        assertEquals(9, a.size)
        assertEquals(9, b.size)
        return a.indices.maxOf { abs(a[it] - b[it]) }
    }

    private fun target(kelvin: Double, tint: Double) = TemperatureTarget(kelvin, tint)

    @Test
    fun `基準（6500K・色合い0）は単位行列`() {
        val identity = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
        val m = TemperatureTint.matrix(target(6500.0, 0.0))
        assertTrue(maxAbsDiff(m, identity) < 1e-6, "基準が単位行列から離れている: ${m.toList()}")
        // TemperatureTarget.NEUTRAL（基準）も同じ
        assertTrue(maxAbsDiff(TemperatureTint.matrix(TemperatureTarget.NEUTRAL), identity) < 1e-6)
    }

    @Test
    fun `表の点そのもの（必ず測る点・ウォーム・クール・ツールの端）は実測の行列と線形で1e-6以内`() {
        assertEquals(15, POINTS.size)
        for (p in POINTS) {
            val m = TemperatureTint.matrix(target(p.kelvin, p.tint))
            val diff = maxAbsDiff(m, p.measured)
            assertTrue(diff < 1e-6, "${p.name}（${p.kelvin}K・色合い${p.tint}）が実測と食い違う: 最大差 $diff")
        }
        // 5500・7500 とツールの端（4500・5000・8000・8500・色合い±250）が入っている
        for (k in listOf(5500.0, 7500.0, 4500.0, 5000.0, 8000.0, 8500.0)) {
            assertTrue(POINTS.any { it.kelvin == k }, "${k}K の点が無い")
        }
        assertTrue(POINTS.any { it.tint == 250.0 } && POINTS.any { it.tint == -250.0 })
    }

    @Test
    fun `刻みの真ん中（表に無い点）は実測の行列を掛けた結果と1階調以内で一致する`() {
        assertTrue(MIDS.size >= 6)
        // 3 種類を全部含む
        assertEquals(setOf("色温度の向き", "色合いの向き", "升の中心"), MIDS.map { it.kind }.toSet())
        // いちばんずれの大きい点（つないだ行列と実測の差が 0.4863 階調）を必ず含む
        assertTrue(MIDS.any { it.kelvin == 6650.0 && it.tint == 237.5 }, "(6650K, 237.5) が入っていない")
        for (p in MIDS) {
            val m = TemperatureTint.matrix(target(p.kelvin, p.tint))
            val diff = maxToneDiff(m, p.measured)
            assertTrue(diff <= 1.0, "${p.kind}（${p.kelvin}K・色合い${p.tint}）が実測から ${diff} 階調ずれている")
        }
    }

    @Test
    fun `刻みの真ん中は両隣の直線のつなぎ（2方向の双一次）になっている`() {
        // 色温度の向き：5550K は 5500K と 5600K の平均
        val a = TemperatureTint.matrix(target(5500.0, 0.0))
        val b = TemperatureTint.matrix(target(5600.0, 0.0))
        val mid = TemperatureTint.matrix(target(5550.0, 0.0))
        for (j in 0 until 9) assertEquals((a[j] + b[j]) / 2.0, mid[j], 1e-12)
        // 色合いの向き：6500K・色合い 6.25 は 0 と 12.5 の平均
        val c = TemperatureTint.matrix(target(6500.0, 0.0))
        val d = TemperatureTint.matrix(target(6500.0, 12.5))
        val midT = TemperatureTint.matrix(target(6500.0, 6.25))
        for (j in 0 until 9) assertEquals((c[j] + d[j]) / 2.0, midT[j], 1e-12)
        // 升の中心：4 つの角の平均
        val p00 = TemperatureTint.matrix(target(7000.0, 50.0))
        val p01 = TemperatureTint.matrix(target(7000.0, 62.5))
        val p10 = TemperatureTint.matrix(target(7100.0, 50.0))
        val p11 = TemperatureTint.matrix(target(7100.0, 62.5))
        val center = TemperatureTint.matrix(target(7050.0, 56.25))
        for (j in 0 until 9) assertEquals((p00[j] + p01[j] + p10[j] + p11[j]) / 4.0, center[j], 1e-12)
    }

    @Test
    fun `範囲の外は端に切り詰めてから引く`() {
        // 色温度の上下
        assertContentEquals(
            TemperatureTint.matrix(target(8500.0, 0.0)),
            TemperatureTint.matrix(target(12000.0, 0.0)),
        )
        assertContentEquals(
            TemperatureTint.matrix(target(4500.0, 0.0)),
            TemperatureTint.matrix(target(1000.0, 0.0)),
        )
        // 色合いの上下
        assertContentEquals(
            TemperatureTint.matrix(target(6500.0, 250.0)),
            TemperatureTint.matrix(target(6500.0, 900.0)),
        )
        assertContentEquals(
            TemperatureTint.matrix(target(6500.0, -250.0)),
            TemperatureTint.matrix(target(6500.0, -900.0)),
        )
        // 両方の角
        assertContentEquals(
            TemperatureTint.matrix(target(8500.0, 250.0)),
            TemperatureTint.matrix(target(99999.0, 99999.0)),
        )
        // 最後の節点（8500K・色合い 250）が実測と合う（升の端の引き方で外に出ない）
        val end = POINTS.first { it.kelvin == 8500.0 }
        assertTrue(maxAbsDiff(TemperatureTint.matrix(target(8500.0, 0.0)), end.measured) < 1e-6)
        assertTrue(TemperatureTint.matrix(target(8500.0, 250.0)).all { it.isFinite() })
    }

    @Test
    fun `返した配列を書き換えても、次に返す行列は変わらない`() {
        val first = TemperatureTint.matrix(target(5500.0, 0.0))
        val copy = first.copyOf()
        first.fill(99.0)
        val second = TemperatureTint.matrix(target(5500.0, 0.0))
        assertNotSame(first, second)
        assertContentEquals(copy, second)
    }

    @Test
    fun `色温度が低い行き先は暖色（白の赤が増え青が減る）、高い行き先は寒色`() {
        val white = doubleArrayOf(1.0, 1.0, 1.0)
        val warm = apply(TemperatureTint.matrix(target(5500.0, 0.0)), white)
        val cool = apply(TemperatureTint.matrix(target(7500.0, 0.0)), white)
        assertTrue(warm[0] > 1.0 && warm[2] < 1.0, "ウォームの白: ${warm.toList()}")
        assertTrue(cool[0] < 1.0 && cool[2] > 1.0, "クールの白: ${cool.toList()}")
        // 結果ファイルの「必ず測る点」の白の出力（ウォーム 1.097788453 / 0.833853185）と合う
        assertEquals(1.097788453, warm[0], 1e-6)
        assertEquals(0.833853185, warm[2], 1e-6)
    }
}
