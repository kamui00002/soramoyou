// ⭐️ 写真の変換の計算（間引きの倍率・EXIF の向き・縮小後の大きさ）の単体テスト（タスク 16.1・要件 7.1）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 間引きの倍率・EXIF の向き・縮小後の大きさを、Android の API なしで確かめる。
 *
 * 向きは、[OrientationFix] の「時計回りに回してから左右に反転」を小さな格子に当てた結果が、
 * EXIF の定義（各向きで、保存された画素の 0 行目・0 列目が、正しく表示したときにどこへ来るか）から**独立に**書いた
 * 期待の格子と一致することで確かめる。期待の格子は回転の関数を使わず、座標の式で直接作る。
 */
class ImageGeometryTest {

    // ── 間引きの倍率：長辺 / 倍率 が目標を下回らない最大の 2 の冪 ──

    @Test
    fun `長辺4000を1024へは2で間引く（4だと1000で目標を下回る）`() {
        assertEquals(2, sampleSizeFor(4000, 3000, 1024))
    }

    @Test
    fun `縦長でも長辺で決める`() {
        assertEquals(2, sampleSizeFor(3000, 4000, 1024))
    }

    @Test
    fun `ちょうど目標の2倍なら2で間引く（間引いた後がちょうど目標になる）`() {
        assertEquals(2, sampleSizeFor(2048, 1536, 1024))
    }

    @Test
    fun `目標の2倍に1足りなければ間引かない`() {
        assertEquals(1, sampleSizeFor(2047, 1536, 1024))
    }

    @Test
    fun `目標以下の写真は間引かない`() {
        assertEquals(1, sampleSizeFor(1024, 768, 1024))
        assertEquals(1, sampleSizeFor(500, 400, 1024))
    }

    @Test
    fun `大きい写真は何段でも間引く`() {
        assertEquals(8, sampleSizeFor(8192, 6144, 1024))
    }

    // ── 縮小後の大きさ：長辺を上限に合わせ、比率を保つ。拡大しない ──

    @Test
    fun `横長は長辺を上限にし、短辺は比率で決める`() {
        assertEquals(ImageSize(1024, 768), fittedSize(2000, 1500, 1024))
    }

    @Test
    fun `縦長も長辺を上限にする`() {
        assertEquals(ImageSize(768, 1024), fittedSize(1500, 2000, 1024))
    }

    @Test
    fun `上限以下の写真は拡大しない`() {
        assertEquals(ImageSize(500, 400), fittedSize(500, 400, 1024))
        assertEquals(ImageSize(1024, 1024), fittedSize(1024, 1024, 1024))
    }

    @Test
    fun `短辺は四捨五入し、0にはしない`() {
        // 1500 × 1024 / 2001 = 767.6… → 768
        assertEquals(ImageSize(1024, 768), fittedSize(2001, 1500, 1024))
        assertEquals(ImageSize(1024, 1), fittedSize(3000, 1, 1024))
    }

    // ── EXIF の向き：各値ごとに、直した結果が定義どおりの正立になる ──

    /** 2 行 × 3 列の、どの画素も区別できる格子（保存されたままの画素）。 */
    private val stored = listOf(listOf(1, 2, 3), listOf(4, 5, 6))
    private val h = stored.size
    private val w = stored[0].size

    /** EXIF の各向きで、正しく表示したときの格子。e[r][c] を保存された画素 g の座標の式で書く（回転の関数は使わない）。 */
    private fun expected(orientation: Int): List<List<Int>> = when (orientation) {
        1 -> grid(h, w) { r, c -> stored[r][c] }
        2 -> grid(h, w) { r, c -> stored[r][w - 1 - c] } // 左右反転
        3 -> grid(h, w) { r, c -> stored[h - 1 - r][w - 1 - c] } // 180 度
        4 -> grid(h, w) { r, c -> stored[h - 1 - r][c] } // 上下反転
        5 -> grid(w, h) { r, c -> stored[c][r] } // 主対角線で折り返す（transpose）
        6 -> grid(w, h) { r, c -> stored[h - 1 - c][r] } // 時計回りに 90 度
        7 -> grid(w, h) { r, c -> stored[h - 1 - c][w - 1 - r] } // 反対の対角線で折り返す（transverse）
        8 -> grid(w, h) { r, c -> stored[c][w - 1 - r] } // 反時計回りに 90 度
        else -> error("未定義の向き: $orientation")
    }

    private fun grid(rows: Int, cols: Int, at: (Int, Int) -> Int) = List(rows) { r -> List(cols) { c -> at(r, c) } }

    /** 時計回りに 90 度回す（新しい格子の r 行 c 列 = 元の (高さ-1-c) 行 r 列）。 */
    private fun rotateClockwise(g: List<List<Int>>) = grid(g[0].size, g.size) { r, c -> g[g.size - 1 - c][r] }

    /** [fix] を「時計回りに回してから左右に反転」の順で当てる（AndroidImageCodec の Matrix と同じ順序）。 */
    private fun applied(fix: OrientationFix): List<List<Int>> {
        require(fix.rotationDegrees in setOf(0, 90, 180, 270)) { "回転は 90 度刻み: ${fix.rotationDegrees}" }
        var g = stored
        repeat(fix.rotationDegrees / 90) { g = rotateClockwise(g) }
        return if (fix.mirror) g.map { it.reversed() } else g
    }

    private fun assertUpright(orientation: Int) {
        val fix = orientationFixOf(orientation)
        assertEquals(expected(orientation), applied(fix), "向き $orientation の直し方 $fix")
        // 幅と高さが入れ替わるかどうかも、直した結果の格子の形と一致する
        assertEquals(expected(orientation).size != h, fix.swapsAxes, "向き $orientation の swapsAxes")
    }

    @Test fun `向き1（そのまま）`() = assertUpright(1)

    @Test fun `向き2（左右反転）`() = assertUpright(2)

    @Test fun `向き3（180度）`() = assertUpright(3)

    @Test fun `向き4（上下反転）`() = assertUpright(4)

    @Test fun `向き5（transpose）`() = assertUpright(5)

    @Test fun `向き6（時計回りに90度）`() = assertUpright(6)

    @Test fun `向き7（transverse）`() = assertUpright(7)

    @Test fun `向き8（反時計回りに90度）`() = assertUpright(8)

    @Test
    fun `向きが無い・未知の値は、そのままにする（エラーにしない）`() {
        for (value in listOf(0, 9, -1, 100)) {
            assertEquals(OrientationFix.NONE, orientationFixOf(value), "向き $value")
        }
        assertFalse(OrientationFix.NONE.swapsAxes)
    }

    @Test
    fun `90度と270度だけが幅と高さを入れ替える`() {
        assertTrue(OrientationFix(90, mirror = false).swapsAxes)
        assertTrue(OrientationFix(270, mirror = true).swapsAxes)
        assertFalse(OrientationFix(180, mirror = true).swapsAxes)
    }

    // ── EXIF の直しのあとに利用者の回転を足す（Kiro android-edit-tools タスク 2.4・K0・design.md:587・1133）──

    /**
     * 正しく表示した格子 [upright] を、利用者が時計回りに [quarterTurns]×90 度回した格子。
     * 回した後の r 行 c 列が、回す前のどこの画素かを、回転の回数ごとに座標の式で直接書く（[rotateClockwise] を重ねない。
     * 本体の角度の足し引きの式も使わない）。
     */
    private fun turnedClockwise(upright: List<List<Int>>, quarterTurns: Int): List<List<Int>> {
        val rows = upright.size
        val cols = upright[0].size
        return when (quarterTurns) {
            0 -> grid(rows, cols) { r, c -> upright[r][c] }
            1 -> grid(cols, rows) { r, c -> upright[rows - 1 - c][r] } // 時計回りに 90 度
            2 -> grid(rows, cols) { r, c -> upright[rows - 1 - r][cols - 1 - c] } // 180 度
            3 -> grid(cols, rows) { r, c -> upright[c][cols - 1 - r] } // 時計回りに 270 度（反時計回りに 90 度）
            else -> error("回転は 0〜3: $quarterTurns")
        }
    }

    @Test
    fun `EXIFの向き8通りに利用者の回転4通りを足した操作は、正しく表示した絵を時計回りに回した結果になる`() {
        // 期待は「EXIF の定義どおりに正しく表示した格子（expected）を、利用者の回転の分だけ回したもの」。
        // 反転のある向き（2・4・5・7）では、直しの回転と利用者の回転の向きが逆になるはずで、そうなっていなければ 1・3 回の回転で食い違う
        val mismatches = mutableListOf<String>()
        for (orientation in 1..8) {
            for (quarterTurns in 0..3) {
                val fix = orientationFixOf(orientation).thenQuarterTurns(quarterTurns)
                val want = turnedClockwise(expected(orientation), quarterTurns)
                val got = applied(fix)
                if (got != want) mismatches += "向き $orientation・時計回りに ${quarterTurns}×90 度：$fix の結果 $got、期待 $want"
                // 幅と高さが入れ替わるかどうかも、期待の格子の形と一致する（寸法の計算はこれを見る）
                if ((want.size != h) != fix.swapsAxes) mismatches += "向き $orientation・時計回りに ${quarterTurns}×90 度：$fix の swapsAxes"
            }
        }
        assertEquals(emptyList<String>(), mismatches)
    }

    // ── 切り抜いた範囲の画素の寸法（Kiro android-edit-tools タスク 2.4・K0・design.md:588）──
    // 割合は 2 進で正確に表せる値（0.25・0.5・0.75 など）だけを使う（丸めの境目が浮動小数の誤差に左右されないように）

    @Test
    fun `切り抜きが全体なら、回した後の寸法そのまま`() {
        assertEquals(ImageSize(4000, 3000), cropPixelSize(4000, 3000, NormalizedRect.FULL))
        assertEquals(ImageSize(1365, 2048), cropPixelSize(1365, 2048, NormalizedRect.FULL))
    }

    @Test
    fun `幅は回した後の幅×範囲の幅、高さは回した後の高さ×範囲の高さで決める`() {
        // 縦横を取り違えると (1000, 1500) になる
        assertEquals(ImageSize(2000, 750), cropPixelSize(4000, 3000, NormalizedRect(0.25, 0.5, 0.75, 0.75)))
    }

    @Test
    fun `端数は四捨五入する（ちょうど半分は切り上げ、半分未満は切り捨て）`() {
        // 1001 × 0.5 = 500.5 → 501、999 × 0.5 = 499.5 → 500
        assertEquals(ImageSize(501, 500), cropPixelSize(1001, 999, NormalizedRect(0.25, 0.5, 0.75, 1.0)))
        // 1001 × 0.25 = 250.25 → 250、999 × 0.75 = 749.25 → 749
        assertEquals(ImageSize(250, 749), cropPixelSize(1001, 999, NormalizedRect(0.0, 0.25, 0.25, 1.0)))
        // 7 × 0.375 = 2.625 → 3
        assertEquals(ImageSize(3, 3), cropPixelSize(7, 7, NormalizedRect(0.125, 0.125, 0.5, 0.5)))
    }

    @Test
    fun `どの辺も1画素より小さくはしない`() {
        // 10 × 1/64 = 0.15625 → 四捨五入で 0 になるが、1 にする
        val tiny = NormalizedRect(0.5, 0.5, 0.5 + 1.0 / 64, 0.5 + 1.0 / 64)
        assertEquals(ImageSize(1, 1), cropPixelSize(10, 10, tiny))
        // 片方の辺だけが小さいときも、その辺だけを 1 にする（4000 × 0.5 = 2000）
        assertEquals(ImageSize(2000, 1), cropPixelSize(4000, 10, NormalizedRect(0.0, 0.5, 0.5, 0.5 + 1.0 / 64)))
    }
}
