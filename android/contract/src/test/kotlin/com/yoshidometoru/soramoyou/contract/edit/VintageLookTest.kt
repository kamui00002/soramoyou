// ⭐️ ビンテージ（セピアと周辺減光）の単体テスト（Kiro android-edit-tools タスク 3・K1②・要件 2.1・2.7・11.1・11.2）
package com.yoshidometoru.soramoyou.contract.edit

import kotlin.math.abs
import kotlin.math.pow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * [VintageLook] が、Core Image の `CISepiaTone`（強さ 0.5）と `CIVignette`（強さ 0.5・半径 1.0）の実測と合うことを確かめる。
 * 期待値は、式を写して計算した値ではなく、Mac（Apple M3・macOS 27.2.1）の Core Image で測った値そのもの（結果のファイルと台本は手元・git の外）。
 *
 *  - セピア [SEPIAS] ＝ `edit-m2-result.txt`（台本 `edit-m2-sepia.swift`・2026-11-11）の「試験色ごとの表」49 色
 *    の入力と実測（線形の値）。黒・白・灰（0.02 から 0.9 まで。暗い色を含む）・原色・補色・ランダムな色が入っている。
 *    曲線の表は `edit-m2b-result.txt`（台本 `edit-m2b-sepia-curve.swift`）の 613 色で作ったので、
 *    この 49 色は表を作った色とは別の、独立した点として使える
 *  - 周辺減光 [VIGS] ＝ `edit-m3-result.txt`（台本 `edit-m3-vignette.swift`・2026-11-11）の「全部の標本」から、
 *    8 つの大きさ（4032×3024・3024×4032・1920×1080・1080×1920・3000×2000・512×512・3000×1000・1000×3000）× 5 点
 *    （中心からの距離 d の最小・25%・50%・75%・最大）。倍率は入力 1.0（白）の出力
 * 数字は結果ファイルの文字列を 9 桁のまま機械的に写した。
 *
 * 「1 階調」の式：線形の値を 0〜1 に切り詰め → sRGB の伝達関数 → ×255、丸めずに差の絶対値（[tone]。`SrgbTransfer` とは
 * 別に、このテストの中で独立に書いた）。
 */
class VintageLookTest {

    private class Sepia(val input: DoubleArray, val measured: DoubleArray)

    private class Vig(val width: Int, val height: Int, val nx: Double, val ny: Double, val measuredGain: Double)

    /** 実測（結果の「試験色ごとの表」49 色。入力と実測は線形の sRGB） */
    private val SEPIAS = listOf(
        Sepia(doubleArrayOf(0.000000000, 0.000000000, 0.000000000), doubleArrayOf(0.000000000, 0.000000000, 0.000000000)),
        Sepia(doubleArrayOf(1.000000000, 1.000000000, 1.000000000), doubleArrayOf(1.000326633, 0.994515181, 0.960277557)),
        Sepia(doubleArrayOf(0.020000000, 0.020000000, 0.020000000), doubleArrayOf(0.033974566, 0.017390978, 0.010205261)),
        Sepia(doubleArrayOf(0.050000000, 0.050000000, 0.050000000), doubleArrayOf(0.072728775, 0.044623304, 0.026639046)),
        Sepia(doubleArrayOf(0.100000000, 0.100000000, 0.100000000), doubleArrayOf(0.132766038, 0.090806268, 0.055901077)),
        Sepia(doubleArrayOf(0.180000000, 0.180000000, 0.180000000), doubleArrayOf(0.220587611, 0.166484624, 0.107543737)),
        Sepia(doubleArrayOf(0.250000000, 0.250000000, 0.250000000), doubleArrayOf(0.294310808, 0.234180003, 0.157544285)),
        Sepia(doubleArrayOf(0.400000000, 0.400000000, 0.400000000), doubleArrayOf(0.444841862, 0.382573336, 0.279549062)),
        Sepia(doubleArrayOf(0.500000000, 0.500000000, 0.500000000), doubleArrayOf(0.541142881, 0.483177513, 0.371928215)),
        Sepia(doubleArrayOf(0.600000000, 0.600000000, 0.600000000), doubleArrayOf(0.635299087, 0.584571898, 0.472953141)),
        Sepia(doubleArrayOf(0.750000000, 0.750000000, 0.750000000), doubleArrayOf(0.773915887, 0.737543344, 0.640347481)),
        Sepia(doubleArrayOf(0.900000000, 0.900000000, 0.900000000), doubleArrayOf(0.910421491, 0.891335011, 0.826285779)),
        Sepia(doubleArrayOf(1.000000000, 0.000000000, 0.000000000), doubleArrayOf(0.648893237, 0.091513038, 0.023953289)),
        Sepia(doubleArrayOf(0.000000000, 1.000000000, 0.000000000), doubleArrayOf(0.384455293, 0.844485879, 0.242369965)),
        Sepia(doubleArrayOf(0.000000000, 0.000000000, 1.000000000), doubleArrayOf(0.064524241, 0.028869206, 0.503235102)),
        Sepia(doubleArrayOf(0.000000000, 1.000000000, 1.000000000), doubleArrayOf(0.414467633, 0.882159829, 0.791364908)),
        Sepia(doubleArrayOf(1.000000000, 0.000000000, 1.000000000), doubleArrayOf(0.687542498, 0.125756487, 0.541599870)),
        Sepia(doubleArrayOf(1.000000000, 1.000000000, 0.000000000), doubleArrayOf(0.971652508, 0.956105113, 0.398921847)),
        Sepia(doubleArrayOf(0.500000000, 0.000000000, 0.000000000), doubleArrayOf(0.336656839, 0.043518767, 0.006597579)),
        Sepia(doubleArrayOf(0.000000000, 0.500000000, 0.000000000), doubleArrayOf(0.224397928, 0.411509871, 0.064263947)),
        Sepia(doubleArrayOf(0.000000000, 0.000000000, 0.500000000), doubleArrayOf(0.037087783, 0.013888158, 0.250867158)),
        Sepia(doubleArrayOf(0.800000000, 0.300000000, 0.100000000), doubleArrayOf(0.640938044, 0.328486621, 0.126473650)),
        Sepia(doubleArrayOf(0.180000000, 0.500000000, 0.730000000), doubleArrayOf(0.357656002, 0.457034856, 0.464048088)),
        Sepia(doubleArrayOf(1.000000000, 0.500000000, 0.000000000), doubleArrayOf(0.822320342, 0.519194186, 0.156852946)),
        Sepia(doubleArrayOf(0.200000000, 1.000000000, 0.600000000), doubleArrayOf(0.520102978, 0.889317632, 0.601128459)),
        Sepia(doubleArrayOf(0.056871591, 0.157282133, 0.220548213), doubleArrayOf(0.135937050, 0.137261182, 0.121332161)),
        Sepia(doubleArrayOf(0.997540639, 0.390278548, 0.296678551), doubleArrayOf(0.795566797, 0.434742868, 0.276211113)),
        Sepia(doubleArrayOf(0.025828051, 0.157955782, 0.565444844), doubleArrayOf(0.131497622, 0.146022886, 0.296681166)),
        Sepia(doubleArrayOf(0.599501121, 0.442528057, 0.182652439), doubleArrayOf(0.571362734, 0.432637036, 0.194025993)),
        Sepia(doubleArrayOf(0.133845314, 0.887082344, 0.864287545), doubleArrayOf(0.455558777, 0.793229282, 0.681037068)),
        Sepia(doubleArrayOf(0.433662284, 0.421270653, 0.746284561), doubleArrayOf(0.483910233, 0.417039871, 0.471664608)),
        Sepia(doubleArrayOf(0.664620389, 0.452061248, 0.618022620), doubleArrayOf(0.627591252, 0.463906944, 0.435273230)),
        Sepia(doubleArrayOf(0.807160221, 0.035206949, 0.230465525), doubleArrayOf(0.552930415, 0.109501623, 0.139361337)),
        Sepia(doubleArrayOf(0.861937275, 0.168537438, 0.180769879), doubleArrayOf(0.634988546, 0.225645691, 0.141369537)),
        Sepia(doubleArrayOf(0.403006350, 0.311004128, 0.371743031), doubleArrayOf(0.414644599, 0.305781424, 0.242565513)),
        Sepia(doubleArrayOf(0.075188953, 0.170285851, 0.690876538), doubleArrayOf(0.172523499, 0.165122375, 0.364396691)),
        Sepia(doubleArrayOf(0.638600486, 0.064530065, 0.061491840), doubleArrayOf(0.453483760, 0.111641318, 0.049456853)),
        Sepia(doubleArrayOf(0.865481876, 0.308812825, 0.310909042), doubleArrayOf(0.690462947, 0.350671202, 0.245688170)),
        Sepia(doubleArrayOf(0.268581546, 0.658761344, 0.916540537), doubleArrayOf(0.467175961, 0.611076891, 0.628158867)),
        Sepia(doubleArrayOf(0.214075186, 0.108045507, 0.418225335), doubleArrayOf(0.221912354, 0.118217386, 0.222057968)),
        Sepia(doubleArrayOf(0.521036557, 0.503926849, 0.000151477), doubleArrayOf(0.538600445, 0.470489562, 0.108923137)),
        Sepia(doubleArrayOf(0.475848512, 0.421739142, 0.004105908), doubleArrayOf(0.484254420, 0.395008743, 0.082794264)),
        Sepia(doubleArrayOf(0.841257309, 0.078339648, 0.513210526), doubleArrayOf(0.601497829, 0.158771873, 0.294732958)),
        Sepia(doubleArrayOf(0.386228392, 0.847644148, 0.271394824), doubleArrayOf(0.574481130, 0.764474988, 0.373311222)),
        Sepia(doubleArrayOf(0.050560741, 0.298307316, 0.431403512), doubleArrayOf(0.197397456, 0.260836244, 0.249552399)),
        Sepia(doubleArrayOf(0.087288347, 0.297517214, 0.399906734), doubleArrayOf(0.218401149, 0.262811661, 0.235061511)),
        Sepia(doubleArrayOf(0.329355488, 0.340890842, 0.681780049), doubleArrayOf(0.391678393, 0.334589750, 0.406988502)),
        Sepia(doubleArrayOf(0.756540427, 0.546085387, 0.088663673), doubleArrayOf(0.695160270, 0.535866141, 0.194722325)),
        Sepia(doubleArrayOf(0.855805172, 0.615326376, 0.288949830), doubleArrayOf(0.781660795, 0.614444852, 0.341925502)),
    )

    /** 実測（結果の「全部の標本」から選んだ 40 点） */
    private val VIGS = listOf(
        Vig(4032, 3024, 0.500124008, 0.500165344, 1.000000000),
        Vig(4032, 3024, 0.750124008, 0.531250000, 0.950134277),
        Vig(4032, 3024, 0.718874008, 0.125165344, 0.899703562),
        Vig(4032, 3024, 0.781374008, 0.968750000, 0.839788616),
        Vig(4032, 3024, 0.999875992, 0.999834656, 0.691529453),
        Vig(3024, 4032, 0.500165344, 0.500124008, 1.000000000),
        Vig(3024, 4032, 0.531250000, 0.750124008, 0.950134277),
        Vig(3024, 4032, 0.125165344, 0.718874008, 0.899703562),
        Vig(3024, 4032, 0.968750000, 0.781374008, 0.839788616),
        Vig(3024, 4032, 0.999834656, 0.999875992, 0.691529453),
        Vig(1920, 1080, 0.500260417, 0.500462963, 0.999999821),
        Vig(1920, 1080, 0.281510417, 0.531018519, 0.932516932),
        Vig(1920, 1080, 0.812760417, 0.531018519, 0.862169445),
        Vig(1920, 1080, 0.125260417, 0.843981481, 0.750155270),
        Vig(1920, 1080, 0.999739583, 0.999537037, 0.538294256),
        Vig(1080, 1920, 0.500462963, 0.500260417, 0.999999821),
        Vig(1080, 1920, 0.531018519, 0.281510417, 0.932516932),
        Vig(1080, 1920, 0.531018519, 0.812760417, 0.862169445),
        Vig(1080, 1920, 0.843981481, 0.125260417, 0.750155270),
        Vig(1080, 1920, 0.999537037, 0.999739583, 0.538294256),
        Vig(3000, 2000, 0.500166667, 0.500250000, 0.999999940),
        Vig(3000, 2000, 0.687500000, 0.281250000, 0.943576396),
        Vig(3000, 2000, 0.375166667, 0.968750000, 0.886760414),
        Vig(3000, 2000, 0.937500000, 0.531250000, 0.808159709),
        Vig(3000, 2000, 0.999833333, 0.999750000, 0.639166594),
        Vig(512, 512, 0.500976562, 0.500976562, 0.999999166),
        Vig(512, 512, 0.438476562, 0.782226562, 0.962916911),
        Vig(512, 512, 0.719726562, 0.844726562, 0.925726175),
        Vig(512, 512, 0.063476562, 0.750976562, 0.887314677),
        Vig(512, 512, 0.999023438, 0.999023438, 0.778644979),
        Vig(3000, 1000, 0.500166667, 0.500500000, 0.999999762),
        Vig(3000, 1000, 0.562500000, 0.031500000, 0.886822879),
        Vig(3000, 1000, 0.750166667, 0.875500000, 0.686999798),
        Vig(3000, 1000, 0.875166667, 0.937500000, 0.351930439),
        Vig(3000, 1000, 0.999833333, 0.999500000, 0.000000000),
        Vig(1000, 3000, 0.500500000, 0.500166667, 0.999999762),
        Vig(1000, 3000, 0.687500000, 0.343833333, 0.886822879),
        Vig(1000, 3000, 0.875500000, 0.750166667, 0.686999798),
        Vig(1000, 3000, 0.937500000, 0.875166667, 0.351930439),
        Vig(1000, 3000, 0.999500000, 0.999833333, 0.000000000),
    )

    /** 1 階調の式の 1 つ分：線形の値を 0〜1 に切り詰め → sRGB の伝達関数 → ×255（丸めない） */
    private fun tone(linear: Double): Double {
        val c = linear.coerceIn(0.0, 1.0)
        val encoded = if (c <= 0.0031308) 12.92 * c else 1.055 * c.pow(1.0 / 2.4) - 0.055
        return encoded * 255.0
    }

    /** セピアを掛けた新しい色（渡した色は書き換えない） */
    private fun sepiaOf(rgb: DoubleArray): DoubleArray = rgb.copyOf().also { VintageLook.sepia(it) }

    // ---- セピア ----

    @Test
    fun `セピアは実測の点（黒・白・灰・原色・暗い色を含む49色）で実測の値と1階調以内`() {
        assertTrue(SEPIAS.size >= 20)
        // 暗い色（輝度 0.05 ほどまで）が入っている（暗い側で曲線が急に立つので、ここが一番外れやすい）
        val dark = SEPIAS.count { s -> 0.2126 * s.input[0] + 0.7152 * s.input[1] + 0.0722 * s.input[2] <= 0.0501 }
        assertTrue(dark >= 3, "暗い色が足りない: $dark")
        var worst = 0.0
        for (s in SEPIAS) {
            val out = sepiaOf(s.input)
            for (c in 0 until 3) {
                val diff = abs(tone(out[c]) - tone(s.measured[c]))
                worst = maxOf(worst, diff)
                assertTrue(
                    diff <= 1.0,
                    "入力 ${s.input.toList()} のチャンネル $c が実測 ${s.measured[c]} から ${diff} 階調ずれている（値 ${out[c]}）",
                )
            }
        }
        // 表を 256 区間でつないだ見込みは 0.1 階調に収まる。1.0 に近づいたら表か引き方が崩れている
        assertTrue(worst < 0.5, "最大 $worst 階調")
    }

    @Test
    fun `セピアは渡した配列をその場で書き換える（黒は黒のまま・白は実測のとおり）`() {
        val black = doubleArrayOf(0.0, 0.0, 0.0)
        VintageLook.sepia(black)
        assertEquals(3, black.size)
        assertTrue(black.all { abs(it) < 1e-9 }, "黒が黒でない: ${black.toList()}")
        // 白（実測 edit-m2-result.txt: 1.000326633, 0.994515181, 0.960277557）
        val white = doubleArrayOf(1.0, 1.0, 1.0)
        VintageLook.sepia(white)
        assertEquals(1.000326633, white[0], 1e-3)
        assertEquals(0.994515181, white[1], 1e-3)
        assertEquals(0.960277557, white[2], 1e-3)
    }

    @Test
    fun `セピアの輝度の重みは0・2126と0・7152と0・0722（Sは輝度だけで決まる）`() {
        // 出力 ＝ 0.5×入力 ＋ 0.5×S(Y)。だから「入力が違っても輝度 Y が同じなら、出力 − 0.5×入力 は同じ」になる。
        // 重みが違うと（0.299・0.587・0.114 や 1/3 ずつ）、赤・緑・青で Y が変わり、この等式が崩れる。
        val cases = listOf(
            doubleArrayOf(1.0, 0.0, 0.0),
            doubleArrayOf(0.0, 1.0, 0.0),
            doubleArrayOf(0.0, 0.0, 1.0),
            doubleArrayOf(0.5, 0.25, 0.75),
            doubleArrayOf(0.1, 0.6, 0.9),
        )
        for (x in cases) {
            val y = 0.2126 * x[0] + 0.7152 * x[1] + 0.0722 * x[2]
            val fromColor = sepiaOf(x)
            val fromGray = sepiaOf(doubleArrayOf(y, y, y))
            for (c in 0 until 3) {
                val sOfColor = (fromColor[c] - 0.5 * x[c]) / 0.5
                val sOfGray = (fromGray[c] - 0.5 * y) / 0.5
                assertEquals(sOfGray, sOfColor, 1e-9, "入力 ${x.toList()} のチャンネル $c で S(Y) が灰と食い違う")
            }
        }
        // 赤・緑・青は輝度が違うので、同じ強さの原色でも出力が違う（重みが 1/3 ずつなら同じになる）
        val r = sepiaOf(doubleArrayOf(1.0, 0.0, 0.0))
        val g = sepiaOf(doubleArrayOf(0.0, 1.0, 0.0))
        val b = sepiaOf(doubleArrayOf(0.0, 0.0, 1.0))
        val sR = r[0] - 0.5
        val sG = g[1] - 0.5
        val sB = b[2] - 0.5
        assertTrue(abs(sR - sG) > 0.01 && abs(sG - sB) > 0.01 && abs(sR - sB) > 0.01, "$sR $sG $sB")
    }

    @Test
    fun `セピアの輝度は0から1に切り詰めて引く（範囲の外でも落ちない）`() {
        // 輝度が 1 を超える色は S(1) で引く（edit-m2b-result.txt の曲線の端 S(1)＝(1.000653, 0.989030, 0.920555)）
        val over = doubleArrayOf(2.0, 2.0, 2.0)
        VintageLook.sepia(over)
        assertEquals(0.5 * 2.0 + 0.5 * 1.000653267, over[0], 1e-6)
        assertEquals(0.5 * 2.0 + 0.5 * 0.989030361, over[1], 1e-6)
        assertEquals(0.5 * 2.0 + 0.5 * 0.920555115, over[2], 1e-6)
        // 輝度が 0 を下回る色は S(0)＝(0, 0, 0) で引く
        val under = doubleArrayOf(-0.2, -0.2, -0.2)
        VintageLook.sepia(under)
        for (c in 0 until 3) assertEquals(0.5 * -0.2, under[c], 1e-9)
    }

    // ---- 周辺減光 ----

    @Test
    fun `周辺減光は実測の点（8つの大きさ×中心から角まで）で実測の倍率と1階調以内`() {
        assertEquals(40, VIGS.size)
        var worstLinear = 0.0
        for (v in VIGS) {
            val gain = VintageLook.vignetteGain(v.nx, v.ny, v.width.toDouble() / v.height.toDouble())
            // 白（入力 1.0）に掛けた結果が実測と 1 階調以内
            val diff = abs(tone(gain) - tone(v.measuredGain))
            assertTrue(
                diff <= 1.0,
                "${v.width}x${v.height} の (${v.nx}, ${v.ny}) が実測 ${v.measuredGain} から ${diff} 階調ずれている（倍率 $gain）",
            )
            worstLinear = maxOf(worstLinear, abs(gain - v.measuredGain))
        }
        // 線形でも小さい（表を 256 区間でつないだ見込みは 0.003 以内）
        assertTrue(worstLinear < 3e-3, "線形の差の最大 $worstLinear")
    }

    @Test
    fun `周辺減光は中心で1・四隅で1より小さく・中心から離れるほど弱くならない向きに単調`() {
        assertEquals(1.0, VintageLook.vignetteGain(0.5, 0.5, 4.0 / 3.0), 1e-5)
        // 4032×3024 の四隅の倍率は 0.6915（edit-m3-result.txt）
        assertEquals(0.6915, VintageLook.vignetteGain(0.0, 0.0, 4032.0 / 3024.0), 1e-3)
        assertEquals(0.6915, VintageLook.vignetteGain(1.0, 1.0, 4032.0 / 3024.0), 1e-3)
        // 右へ進むほど倍率は小さくなる（増えない）
        var prev = VintageLook.vignetteGain(0.5, 0.5, 1.0)
        for (i in 1..100) {
            val g = VintageLook.vignetteGain(0.5 + i * 0.005, 0.5, 1.0)
            assertTrue(g <= prev + 1e-12, "i=$i で倍率が増えた: $prev → $g")
            prev = g
        }
        assertTrue(prev < 0.95)
    }

    @Test
    fun `周辺減光は縦横を入れ替えても同じ（短辺で正規化した距離だけで決まる）`() {
        // 横長で (nx, ny) の位置と、縦長で (ny, nx) の位置は、同じ距離
        val pairs = listOf(Triple(0.1, 0.2, 1.5), Triple(0.9, 0.4, 16.0 / 9.0), Triple(0.3, 0.8, 3.0))
        for ((nx, ny, a) in pairs) {
            assertEquals(
                VintageLook.vignetteGain(nx, ny, a),
                VintageLook.vignetteGain(ny, nx, 1.0 / a),
                1e-12,
            )
        }
    }

    @Test
    fun `周辺減光は表の外（遠すぎる位置）で端の値のまま、落ちない`() {
        val far1 = VintageLook.vignetteGain(10.0, 10.0, 1.0)
        val far2 = VintageLook.vignetteGain(-50.0, 30.0, 1.5)
        assertEquals(far1, far2, 1e-12)
        assertTrue(far1.isFinite() && far1 >= 0.0 && far1 < 0.6, "端の倍率 $far1")
        // 四隅（0.6915）より暗い（表の端 D_MAX では倍率が 0 になる）
        assertTrue(far1 < VintageLook.vignetteGain(0.0, 0.0, 4032.0 / 3024.0))
    }
}
