// ⭐️ フィルターの識別子と色の変換の単体テスト（タスク 20.3・要件 6.6・8.3）
package com.yoshidometoru.soramoyou.contract.model

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * [FilterId] の文字列値・表示名が iOS と同じであること、色の変換が Core Image の計算と一致することを確かめる。
 *
 * 色の変換の黄金値は、iOS と同じ係数の `CIColorControls` を、作業色空間を sRGB にした Core Image（Swift 6.4・macOS 27）で
 * 1 画素ずつ計算させた値である（手元（git の外）の `20.3-ci.swift`・`20.3-ci.tsv`）。行列の式を写して計算した値ではないので、
 * 式の書き間違い（彩度の軸・コントラストの軸・明るさの順序・輝度の重み）を外から捕まえられる。
 * モノクロは倍率を変えているので（[FilterId] の説明）、iOS アプリの実際の作業空間での実測（`20.3-mono.tsv`）と性質で確かめる。
 *
 * 陽性対照（係数を壊して赤を確かめたもの）の手順は手元の台本（git の外）。
 */
class FilterIdTest {

    /** 行列を 0〜1 の色に掛ける（0〜255 に直して掛け、255 で戻す。Android と同じく最後に切り詰めるかは [clamp] で選ぶ）。 */
    private fun apply(filter: FilterId, r: Float, g: Float, b: Float, clamp: Boolean = false): FloatArray {
        val m = checkNotNull(filter.legacyMatrix()) { filter.raw }
        val input = floatArrayOf(r * 255f, g * 255f, b * 255f, 255f)
        return FloatArray(3) { row ->
            val v = (0 until 4).sumOf { col -> (m[row * 5 + col] * input[col]).toDouble() }.toFloat() + m[row * 5 + 4]
            val unit = v / 255f
            if (clamp) unit.coerceIn(0f, 1f) else unit
        }
    }

    /** 行列を持つ今の 6 種（形を変える前から同じ並び）。 */
    private val 今の6種 = listOf(FilterId.CLEAR, FilterId.DRAMA, FilterId.SOFT, FilterId.MONOCHROME, FilterId.PASTEL, FilterId.VIVID)

    private data class Golden(val filter: FilterId, val r: Float, val g: Float, val b: Float, val outR: Float, val outG: Float, val outB: Float)

    @Test
    fun `文字列値・表示名・並び順はiOSと同じ`() {
        assertEquals(
            listOf(
                "natural" to "ナチュラル", "clear" to "クリア", "drama" to "ドラマ", "soft" to "ソフト",
                "warm" to "ウォーム", "cool" to "クール", "vintage" to "ビンテージ",
                "monochrome" to "モノクロ", "pastel" to "パステル", "vivid" to "ヴィヴィッド",
            ),
            FilterId.entries.map { it.raw to it.displayName },
        )
    }

    @Test
    fun `文字列値から10個とも引けて、未知の値はnull`() {
        FilterId.entries.forEach { assertEquals(it, FilterId.fromRaw(it.raw)) }
        assertEquals(10, FilterId.entries.size)
        for (raw in listOf("Clear", " clear", "", null)) {
            assertNull(FilterId.fromRaw(raw), "$raw")
        }
    }

    @Test
    fun `ナチュラル・ウォーム・クール・ビンテージは行列を持たない`() {
        for (filter in listOf(FilterId.NATURAL, FilterId.WARM, FilterId.COOL, FilterId.VINTAGE)) {
            assertNull(filter.legacyMatrix(), filter.raw)
        }
        // 行列を持つのは今の 6 種だけ（10 個のうち残りの 4 個が null）
        assertEquals(今の6種.toSet(), FilterId.entries.filter { it.legacyMatrix() != null }.toSet())
    }

    @Test
    fun `行列は20要素で全て有限、不透明度はそのまま、呼び出しごとに別の配列`() {
        for (filter in 今の6種) {
            val m = checkNotNull(filter.legacyMatrix()) { filter.raw }
            assertEquals(20, m.size, filter.raw)
            assertTrue(m.all { it.isFinite() }, filter.raw)
            assertEquals(listOf(0f, 0f, 0f, 1f, 0f), m.slice(15 until 20), filter.raw)
            assertNotSame(m, filter.legacyMatrix())
        }
    }

    @Test
    fun `彩度・コントラスト・明るさのフィルターはCoreImageの計算と一致する`() {
        val golden = listOf(
            Golden(FilterId.CLEAR, 1f, 0f, 0f, 1.107687f, -0.047312f, -0.047312f),
            Golden(FilterId.CLEAR, 0f, 1f, 0f, -0.100117f, 1.054883f, -0.100117f),
            Golden(FilterId.CLEAR, 0f, 0f, 1f, -0.032570f, -0.032570f, 1.122429f),
            Golden(FilterId.CLEAR, 0.5f, 0.5f, 0.5f, 0.500000f, 0.500000f, 0.500000f),
            Golden(FilterId.CLEAR, 0.2f, 0.2f, 0.2f, 0.185000f, 0.185000f, 0.185000f),
            Golden(FilterId.CLEAR, 0.8f, 0.3f, 0.1f, 0.857858f, 0.280358f, 0.049358f),
            Golden(FilterId.DRAMA, 1f, 0f, 0f, 1.354750f, -0.205250f, -0.205250f),
            Golden(FilterId.DRAMA, 0f, 1f, 0f, -0.336004f, 1.223996f, -0.336004f),
            Golden(FilterId.DRAMA, 0f, 0f, 1f, -0.168746f, -0.168746f, 1.391254f),
            Golden(FilterId.DRAMA, 0.5f, 0.5f, 0.5f, 0.500000f, 0.500000f, 0.500000f),
            Golden(FilterId.DRAMA, 0.2f, 0.2f, 0.2f, 0.110000f, 0.110000f, 0.110000f),
            Golden(FilterId.DRAMA, 0.8f, 0.3f, 0.1f, 0.996124f, 0.216124f, -0.095876f),
            Golden(FilterId.SOFT, 1f, 0f, 0f, 0.808250f, 0.088250f, 0.088250f),
            Golden(FilterId.SOFT, 0f, 1f, 0f, 0.178772f, 0.898772f, 0.178772f),
            Golden(FilterId.SOFT, 0f, 0f, 1f, 0.062978f, 0.062978f, 0.782978f),
            Golden(FilterId.SOFT, 0.5f, 0.5f, 0.5f, 0.500000f, 0.500000f, 0.500000f),
            Golden(FilterId.SOFT, 0.2f, 0.2f, 0.2f, 0.230000f, 0.230000f, 0.230000f),
            Golden(FilterId.SOFT, 0.8f, 0.3f, 0.1f, 0.696529f, 0.336529f, 0.192529f),
            Golden(FilterId.PASTEL, 1f, 0f, 0f, 0.766500f, 0.226500f, 0.226500f),
            Golden(FilterId.PASTEL, 0f, 1f, 0f, 0.407544f, 0.947544f, 0.407544f),
            Golden(FilterId.PASTEL, 0f, 0f, 1f, 0.175956f, 0.175956f, 0.715956f),
            Golden(FilterId.PASTEL, 0.5f, 0.5f, 0.5f, 0.600000f, 0.600000f, 0.600000f),
            Golden(FilterId.PASTEL, 0.2f, 0.2f, 0.2f, 0.330000f, 0.330000f, 0.330000f),
            Golden(FilterId.PASTEL, 0.8f, 0.3f, 0.1f, 0.723059f, 0.453059f, 0.345059f),
            Golden(FilterId.VIVID, 1f, 0f, 0f, 1.572500f, -0.227500f, -0.227500f),
            Golden(FilterId.VIVID, 0f, 1f, 0f, -0.529240f, 1.270760f, -0.529240f),
            Golden(FilterId.VIVID, 0f, 0f, 1f, -0.143260f, -0.143260f, 1.656740f),
            Golden(FilterId.VIVID, 0.5f, 0.5f, 0.5f, 0.500000f, 0.500000f, 0.500000f),
            Golden(FilterId.VIVID, 0.2f, 0.2f, 0.2f, 0.140000f, 0.140000f, 0.140000f),
            Golden(FilterId.VIVID, 0.8f, 0.3f, 0.1f, 1.104902f, 0.204902f, -0.155098f),
        )
        for (g in golden) {
            val out = apply(g.filter, g.r, g.g, g.b)
            val expected = floatArrayOf(g.outR, g.outG, g.outB)
            for (i in 0 until 3) {
                assertTrue(abs(out[i] - expected[i]) <= 1e-4f, "${g.filter.raw} (${g.r}, ${g.g}, ${g.b}) の ${"RGB"[i]}: ${out[i]} ≠ ${expected[i]}")
            }
        }
    }

    @Test
    fun `パステルの明るさは0から255の尺度で平行移動に入る`() {
        // 0.5·(1−0.9)＋0.1＝0.15 → 0〜255 の尺度で 38.25
        val m = checkNotNull(FilterId.PASTEL.legacyMatrix())
        for (row in 0 until 3) assertEquals(38.25f, m[row * 5 + 4], 1e-3f)
    }

    @Test
    fun `モノクロは灰色を出し、黒は黒・白は白・灰0点5は約0点686`() {
        for ((r, g, b) in listOf(Triple(1f, 0f, 0f), Triple(0f, 1f, 0f), Triple(0.8f, 0.3f, 0.1f), Triple(0.2f, 0.6f, 0.9f))) {
            val out = apply(FilterId.MONOCHROME, r, g, b)
            assertEquals(out[0], out[1], 1e-6f)
            assertEquals(out[1], out[2], 1e-6f)
        }
        assertEquals(0f, apply(FilterId.MONOCHROME, 0f, 0f, 0f, clamp = true)[0], 1e-6f)
        assertEquals(1f, apply(FilterId.MONOCHROME, 1f, 1f, 1f, clamp = true)[0], 1e-6f)
        // iOS アプリの作業空間（線形 sRGB）での実測は 0.6858（20.3-mono.tsv）
        assertEquals(0.6858f, apply(FilterId.MONOCHROME, 0.5f, 0.5f, 0.5f)[0], 0.01f)
    }

    @Test
    fun `彩度だけを変えるフィルターは灰色を灰色のまま保つ`() {
        for (filter in listOf(FilterId.CLEAR, FilterId.DRAMA, FilterId.SOFT, FilterId.PASTEL, FilterId.VIVID)) {
            for (v in listOf(0.1f, 0.5f, 0.9f)) {
                val out = apply(filter, v, v, v)
                assertEquals(out[0], out[1], 1e-5f, filter.raw)
                assertEquals(out[1], out[2], 1e-5f, filter.raw)
            }
        }
    }

    /** 行列の取り出し口。今の 6 種は null でない前提。 */
    private fun matrixOf(filter: FilterId): FloatArray = checkNotNull(filter.legacyMatrix()) { filter.raw }

    // 形を変える前の値を固定する表（要件 2.2・11.4・タスク 2.1）。
    // CIColorControls 系は 3×3 が k·((1−s)·LUMA[j] ＋ (i==j ? s : 0))、5 列目が (0.5·(1−k)＋b)·255。
    // モノクロは 3 行とも LUMA·2^(1/2.2)。式から計算した数字のリテラルで、本体を呼んで作った値ではない。
    private val 今の6種の表: List<Pair<FilterId, FloatArray>> = listOf(
        FilterId.CLEAR to floatArrayOf(
            1.1326875f, -0.075117f, -0.0075705f, 0f, -6.375f,
            -0.0223125f, 1.079883f, -0.0075705f, 0f, -6.375f,
            -0.0223125f, -0.075117f, 1.1474295f, 0f, -6.375f,
            0f, 0f, 0f, 1f, 0f,
        ),
        FilterId.DRAMA to floatArrayOf(
            1.50475f, -0.186004f, -0.018746f, 0f, -38.25f,
            -0.05525f, 1.373996f, -0.018746f, 0f, -38.25f,
            -0.05525f, -0.186004f, 1.541254f, 0f, -38.25f,
            0f, 0f, 0f, 1f, 0f,
        ),
        FilterId.SOFT to floatArrayOf(
            0.75825f, 0.128772f, 0.012978f, 0f, 12.75f,
            0.03825f, 0.848772f, 0.012978f, 0f, 12.75f,
            0.03825f, 0.128772f, 0.732978f, 0f, 12.75f,
            0f, 0f, 0f, 1f, 0f,
        ),
        FilterId.MONOCHROME to floatArrayOf(
            0.2911996f, 0.9803491f, 0.0988023f, 0f, 0f,
            0.2911996f, 0.9803491f, 0.0988023f, 0f, 0f,
            0.2911996f, 0.9803491f, 0.0988023f, 0f, 0f,
            0f, 0f, 0f, 1f, 0f,
        ),
        FilterId.PASTEL to floatArrayOf(
            0.6165f, 0.257544f, 0.025956f, 0f, 38.25f,
            0.0765f, 0.797544f, 0.025956f, 0f, 38.25f,
            0.0765f, 0.257544f, 0.565956f, 0f, 38.25f,
            0f, 0f, 0f, 1f, 0f,
        ),
        FilterId.VIVID to floatArrayOf(
            1.6725f, -0.42924f, -0.04326f, 0f, -25.5f,
            -0.1275f, 1.37076f, -0.04326f, 0f, -25.5f,
            -0.1275f, -0.42924f, 1.75674f, 0f, -25.5f,
            0f, 0f, 0f, 1f, 0f,
        ),
    )

    @Test
    fun `今の6種の行列は数字の表と一致する（本仕様の前の値）`() {
        val failures = mutableListOf<String>()
        for ((filter, expected) in 今の6種の表) {
            val actual = matrixOf(filter)
            // 1〜4 列目（係数）は 1e-5、5 列目（0〜255 の尺度）は 1e-3。モノクロの倍率が Math.pow を通るのでビット一致にはしない
            val matches = actual.size == expected.size && expected.indices.all { i ->
                val tolerance = if (i % 5 == 4) 1e-3f else 1e-5f
                abs(actual[i] - expected[i]) <= tolerance
            }
            if (!matches) {
                failures += "${filter.raw}（要素数 ${actual.size}）: FilterId.${filter.name} to floatArrayOf(" +
                    actual.joinToString(", ") { "${it}f" } + ")"
            }
        }
        // 6 種を全部比べてから、ずれたフィルターをまとめて 1 回だけ失敗させる（そのまま表に貼れる形）
        assertTrue(failures.isEmpty(), "表とずれたフィルター ${failures.size} 個:\n" + failures.joinToString("\n"))
    }
}
