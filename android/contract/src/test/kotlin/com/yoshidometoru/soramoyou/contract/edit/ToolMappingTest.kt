// ⭐️ スライダーの値から物理の値への写しの単体テスト（Kiro android-edit-tools タスク 4・C1・design.md:1121）
package com.yoshidometoru.soramoyou.contract.edit

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * [ToolMapping] の式が design.md「色の式」の表（822-834）どおりであることを、v＝−1・−0.5・0・0.5・1 で確かめる。
 *
 * 期待値は表の式から手で計算した数字で、本体を呼んで作った値ではない。途中の計算は各テストの中に書いた
 * （電卓には本体と別に書いたスクリプトを使い、テストには数字だけを写した）。
 *
 * 陽性対照（tasks.md:277）：`ToolMapping.contrast` の負の側の指数 2.0 を 1.0 にすると、
 * v＝−0.5 の 0.875 が 0.75 になって「コントラストは…」が赤になる（v＝−1 は指数に依らず 0.5 なので見分けられない）。
 */
class ToolMappingTest {

    /** 確かめるスライダーの値（design.md:1121） */
    private val sliderValues = listOf(-1.0, -0.5, 0.0, 0.5, 1.0)

    /** [sliderValues] の順に並べた期待値と、関数の値を比べる */
    private fun check(name: String, f: (Double) -> Double, expected: List<Double>) {
        assertEquals(sliderValues.size, expected.size, name)
        for ((v, e) in sliderValues.zip(expected)) {
            assertEquals(e, f(v), 1e-9, "$name(v=$v)")
        }
    }

    @Test
    fun `露出はEVで2倍（iOSのEditRecipe 353行）`() {
        // EV＝2.0v
        check("exposureEv", ToolMapping::exposureEv, listOf(-2.0, -1.0, 0.0, 1.0, 2.0))
    }

    @Test
    fun `明るさは負の側だけ指数1点5で、端は0点5（iOSのEditRecipe 356から360行）`() {
        // v≥0：0.5v → 0・0.25・0.5
        // v＜0：−0.5×(−v)^1.5 → v＝−0.5：0.5^1.5＝0.353553390593 → ×0.5＝0.176776695297 → −0.176776695297。v＝−1：−0.5
        check("brightness", ToolMapping::brightness, listOf(-0.5, -0.176776695297, 0.0, 0.25, 0.5))
    }

    @Test
    fun `コントラストは負の側だけ指数2点0で、0点5から1点5（iOSのEditRecipe 364から368行）`() {
        // k＝1＋(v≥0 ? 0.5v : −0.5(−v)^2)
        // v＝−1：1−0.5×1＝0.5。v＝−0.5：1−0.5×0.25＝0.875（指数が 1.0 なら 1−0.5×0.5＝0.75）。v＝0.5：1.25。v＝1：1.5
        check("contrast", ToolMapping::contrast, listOf(0.5, 0.875, 1.0, 1.25, 1.5))
    }

    @Test
    fun `彩度は正の側だけ指数0点7と倍率1点5で、0から2点5（iOSのEditRecipe 384から388行）`() {
        // s＝1＋(v≥0 ? 1.5×v^0.7 : −(−v))
        // v＝−1：0。v＝−0.5：0.5。v＝0.5：0.5^0.7＝0.615572206672 → ×1.5＝0.923358310009 → 1.923358310009。v＝1：2.5
        check("saturation", ToolMapping::saturation, listOf(0.0, 0.5, 1.0, 1.923358310009, 2.5))
    }

    @Test
    fun `ブラックポイントは0点15倍（iOSのEditRecipe 380行）`() {
        check("blackPointBias", ToolMapping::blackPointBias, listOf(-0.15, -0.075, 0.0, 0.075, 0.15))
    }

    @Test
    fun `フェードは傾き1マイナス0点15vと持ち上げ0点2v（iOSのFilterGraphBuilder 1103と1104行）`() {
        // gain＝1−0.15v → 1.15・1.075・1・0.925・0.85。bias＝0.2v → −0.2・−0.1・0・0.1・0.2
        check("fadeGain", ToolMapping::fadeGain, listOf(1.15, 1.075, 1.0, 0.925, 0.85))
        check("fadeBias", ToolMapping::fadeBias, listOf(-0.2, -0.1, 0.0, 0.1, 0.2))
    }

    @Test
    fun `暖かみは6500から1500vを引き、色合いは250v（iOSのFilterGraphBuilder 905から909行）`() {
        // 暖かみだけ：行き先＝(6500−1500w, 0) → 8000・7250・6500・5750・5000（正の暖かみは低い K＝暖色）
        val warmthKelvin = listOf(8000.0, 7250.0, 6500.0, 5750.0, 5000.0)
        for ((w, k) in sliderValues.zip(warmthKelvin)) {
            val target = ToolMapping.warmTintTarget(warmth = w, tint = 0.0)
            assertEquals(k, target.kelvin, 1e-9, "warmth=$w の K")
            assertEquals(0.0, target.tint, 1e-9, "warmth=$w の色合い")
        }
        // 色合いだけ：行き先＝(6500, 250t) → −250・−125・0・125・250
        val tintValues = listOf(-250.0, -125.0, 0.0, 125.0, 250.0)
        for ((t, e) in sliderValues.zip(tintValues)) {
            val target = ToolMapping.warmTintTarget(warmth = 0.0, tint = t)
            assertEquals(6500.0, target.kelvin, 1e-9, "tint=$t の K")
            assertEquals(e, target.tint, 1e-9, "tint=$t の色合い")
        }
        // 両方：暖かみ 0.3・色合い −0.2 → (6500−450, −50)＝(6050, −50)。引数の取り違え（K に色合いを入れる）も見る
        val both = ToolMapping.warmTintTarget(warmth = 0.3, tint = -0.2)
        assertEquals(6050.0, both.kelvin, 1e-9)
        assertEquals(-50.0, both.tint, 1e-9)
    }

    @Test
    fun `色温度は6500に1500vを足し、ホワイトバランスは2000vを足す（iOSのFilterGraphBuilder 920から937行）`() {
        // 色温度：(6500＋1500v, 0) → 5000・5750・6500・7250・8000
        val colorTemperatureKelvin = listOf(5000.0, 5750.0, 6500.0, 7250.0, 8000.0)
        for ((v, k) in sliderValues.zip(colorTemperatureKelvin)) {
            val target = ToolMapping.colorTemperatureTarget(v)
            assertEquals(k, target.kelvin, 1e-9, "colorTemperature v=$v の K")
            assertEquals(0.0, target.tint, 1e-9, "colorTemperature v=$v の色合い")
        }
        // ホワイトバランス：(6500＋2000v, 0) → 4500・5500・6500・7500・8500
        val whiteBalanceKelvin = listOf(4500.0, 5500.0, 6500.0, 7500.0, 8500.0)
        for ((v, k) in sliderValues.zip(whiteBalanceKelvin)) {
            val target = ToolMapping.whiteBalanceTarget(v)
            assertEquals(k, target.kelvin, 1e-9, "whiteBalance v=$v の K")
            assertEquals(0.0, target.tint, 1e-9, "whiteBalance v=$v の色合い")
        }
    }

    @Test
    fun `0は中立（ぴったり中立の値になる）`() {
        // ColorRecipe.isIdentity は == で中立を見るので、許し幅なしで比べる
        assertEquals(0.0, ToolMapping.exposureEv(0.0))
        assertEquals(0.0, ToolMapping.brightness(0.0))
        assertEquals(1.0, ToolMapping.contrast(0.0))
        assertEquals(1.0, ToolMapping.saturation(0.0))
        assertEquals(0.0, ToolMapping.blackPointBias(0.0))
        assertEquals(1.0, ToolMapping.fadeGain(0.0))
        assertEquals(0.0, ToolMapping.fadeBias(0.0))
        assertEquals(TemperatureTarget.NEUTRAL, ToolMapping.warmTintTarget(0.0, 0.0))
        assertEquals(TemperatureTarget.NEUTRAL, ToolMapping.colorTemperatureTarget(0.0))
        assertEquals(TemperatureTarget.NEUTRAL, ToolMapping.whiteBalanceTarget(0.0))
    }

    @Test
    fun `非対称の写しは正と負で別の指数と倍率を使う（iOSのEditRecipe 292から310行）`() {
        // 正：4×0.25^0.5＝4×0.5＝2.0。負：−3×0.25^2＝−3×0.0625＝−0.1875（正と負の引数を取り違えると値が変わる）
        assertEquals(2.0, ToolMapping.asymmetricForward(0.25, pNeg = 2.0, scaleNeg = 3.0, pPos = 0.5, scalePos = 4.0), 1e-12)
        assertEquals(-0.1875, ToolMapping.asymmetricForward(-0.25, pNeg = 2.0, scaleNeg = 3.0, pPos = 0.5, scalePos = 4.0), 1e-12)
        assertEquals(0.0, ToolMapping.asymmetricForward(0.0, pNeg = 2.0, scaleNeg = 3.0, pPos = 0.5, scalePos = 4.0))
    }

    @Test
    fun `非対称の写しは入力や結果が有限でなければ0（iOSのEditRecipe 298と309行）`() {
        for (n in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            assertEquals(0.0, ToolMapping.asymmetricForward(n, pNeg = 1.0, scaleNeg = 1.0, pPos = 1.0, scalePos = 1.0), "n=$n")
        }
        // 2^2000 は無限になる → 0。負の側も同じ
        assertEquals(0.0, ToolMapping.asymmetricForward(2.0, pNeg = 1.0, scaleNeg = 1.0, pPos = 2000.0, scalePos = 1.0))
        assertEquals(0.0, ToolMapping.asymmetricForward(-2.0, pNeg = 2000.0, scaleNeg = 1.0, pPos = 1.0, scalePos = 1.0))
    }
}
