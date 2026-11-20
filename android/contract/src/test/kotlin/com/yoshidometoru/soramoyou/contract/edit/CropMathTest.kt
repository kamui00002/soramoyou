// ⭐️ 切り抜きの範囲の計算と、回転と範囲の連動の単体テスト（Kiro android-edit-tools タスク 5・C2・要件 4.3・4.4・6.3）
package com.yoshidometoru.soramoyou.contract.edit

import com.yoshidometoru.soramoyou.contract.edit.CropMath.Edge
import com.yoshidometoru.soramoyou.contract.edit.CropMath.Handle
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * [CropMath] と [EditGeometry] の回転を確かめる。期待値は手で計算してテストに書いた数（本体の式を写していない）。
 * 取っ手の動きの元：iOS CropOverlayView.swift:131-213（縦横比の固定は除く）。
 *
 * 陽性対照（メインが流す）：
 * - 下限を 0.01 にする（`MIN_SIDE`）→「下限」「最小」を含むテストが赤
 * - 回転で範囲を回さない（`rotatedClockwise` の crop をそのままにする）→ 回転のテストが赤
 */
class CropMathTest {

    private val delta = 1e-9

    private fun assertRect(expected: NormalizedRect, actual: NormalizedRect, message: String = "") {
        assertEquals(expected.left, actual.left, delta, "$message left $actual")
        assertEquals(expected.top, actual.top, delta, "$message top $actual")
        assertEquals(expected.right, actual.right, delta, "$message right $actual")
        assertEquals(expected.bottom, actual.bottom, delta, "$message bottom $actual")
    }

    private fun rect(l: Double, t: Double, r: Double, b: Double) = NormalizedRect(l, t, r, b)

    // ---- 定数 ----

    @Test
    fun `各辺の下限は iOS と同じ 0,15`() {
        assertEquals(0.15, CropMath.MIN_SIDE)
    }

    // ---- dragged：取っ手ごとの動き ----

    private val base = rect(0.2, 0.2, 0.8, 0.8)

    @Test
    fun `左上の取っ手は左辺と上辺だけが動く`() {
        assertRect(rect(0.3, 0.25, 0.8, 0.8), CropMath.dragged(base, Handle.TOP_LEFT, 0.1, 0.05))
    }

    @Test
    fun `右上の取っ手は右辺と上辺だけが動く`() {
        assertRect(rect(0.2, 0.3, 0.7, 0.8), CropMath.dragged(base, Handle.TOP_RIGHT, -0.1, 0.1))
    }

    @Test
    fun `左下の取っ手は左辺と下辺だけが動く`() {
        assertRect(rect(0.3, 0.2, 0.8, 0.7), CropMath.dragged(base, Handle.BOTTOM_LEFT, 0.1, -0.1))
    }

    @Test
    fun `右下の取っ手は右辺と下辺だけが動く`() {
        assertRect(rect(0.2, 0.2, 0.9, 0.85), CropMath.dragged(base, Handle.BOTTOM_RIGHT, 0.1, 0.05))
    }

    @Test
    fun `動かさなければ範囲は変わらない`() {
        for (h in Handle.entries) assertRect(base, CropMath.dragged(base, h, 0.0, 0.0), h.name)
    }

    // ---- dragged：内側に限る ----

    @Test
    fun `取っ手を絵の外へ引いても絵の内側で止まる`() {
        assertRect(rect(0.0, 0.0, 0.8, 0.8), CropMath.dragged(base, Handle.TOP_LEFT, -5.0, -5.0))
        assertRect(rect(0.2, 0.0, 1.0, 0.8), CropMath.dragged(base, Handle.TOP_RIGHT, 5.0, -5.0))
        assertRect(rect(0.0, 0.2, 0.8, 1.0), CropMath.dragged(base, Handle.BOTTOM_LEFT, -5.0, 5.0))
        assertRect(rect(0.2, 0.2, 1.0, 1.0), CropMath.dragged(base, Handle.BOTTOM_RIGHT, 5.0, 5.0))
    }

    // ---- dragged：各辺 0.15 以上 ----

    @Test
    fun `下限より小さくなる向きに引くと各辺がちょうど 0,15 で止まる`() {
        assertRect(rect(0.65, 0.65, 0.8, 0.8), CropMath.dragged(base, Handle.TOP_LEFT, 5.0, 5.0))
        assertRect(rect(0.2, 0.65, 0.35, 0.8), CropMath.dragged(base, Handle.TOP_RIGHT, -5.0, 5.0))
        assertRect(rect(0.65, 0.2, 0.8, 0.35), CropMath.dragged(base, Handle.BOTTOM_LEFT, 5.0, -5.0))
        assertRect(rect(0.2, 0.2, 0.35, 0.35), CropMath.dragged(base, Handle.BOTTOM_RIGHT, -5.0, -5.0))
    }

    @Test
    fun `下限は縦と横それぞれで効く`() {
        // 横だけ最小にし、縦は動かした分だけ
        assertRect(rect(0.2, 0.3, 0.35, 0.8), CropMath.dragged(base, Handle.TOP_RIGHT, -5.0, 0.1))
    }

    @Test
    fun `取っ手を反対側の辺を越えて引いても逆向きにならない`() {
        val r = CropMath.dragged(base, Handle.TOP_LEFT, 0.9, 0.9)
        assertTrue(r.width >= CropMath.MIN_SIDE - delta, "$r")
        assertTrue(r.height >= CropMath.MIN_SIDE - delta, "$r")
    }

    // ---- dragged：中の移動 ----

    @Test
    fun `中の移動は大きさを保って動く`() {
        val r = rect(0.2, 0.2, 0.6, 0.5)
        assertRect(rect(0.3, 0.25, 0.7, 0.55), CropMath.dragged(r, Handle.MOVE, 0.1, 0.05))
    }

    @Test
    fun `中の移動は絵の端で止まり大きさは変わらない`() {
        val r = rect(0.2, 0.2, 0.6, 0.5)
        assertRect(rect(0.6, 0.7, 1.0, 1.0), CropMath.dragged(r, Handle.MOVE, 5.0, 5.0))
        assertRect(rect(0.0, 0.0, 0.4, 0.3), CropMath.dragged(r, Handle.MOVE, -5.0, -5.0))
    }

    @Test
    fun `全体の範囲は動かせない`() {
        assertRect(NormalizedRect.FULL, CropMath.dragged(NormalizedRect.FULL, Handle.MOVE, 0.3, -0.3))
    }

    @Test
    fun `どの取っ手をどれだけ引いても内側かつ各辺 0,15 以上`() {
        val starts = listOf(NormalizedRect.FULL, base, rect(0.0, 0.0, 0.15, 0.15), rect(0.85, 0.85, 1.0, 1.0), rect(0.1, 0.3, 0.9, 0.5))
        val steps = (-30..30).map { it * 0.05 }
        for (s in starts) for (h in Handle.entries) for (dx in steps) for (dy in steps) {
            val r = CropMath.dragged(s, h, dx, dy)
            val tag = "$s $h dx=$dx dy=$dy -> $r"
            assertTrue(r.left >= -delta && r.top >= -delta && r.right <= 1.0 + delta && r.bottom <= 1.0 + delta, tag)
            assertTrue(r.width >= CropMath.MIN_SIDE - delta, tag)
            assertTrue(r.height >= CropMath.MIN_SIDE - delta, tag)
        }
    }

    // ---- nudged：5% 刻み ----

    @Test
    fun `辺を内側へ 5 パーセント動かす`() {
        val f = NormalizedRect.FULL
        assertRect(rect(0.05, 0.0, 1.0, 1.0), CropMath.nudged(f, Edge.LEFT, inward = true))
        assertRect(rect(0.0, 0.05, 1.0, 1.0), CropMath.nudged(f, Edge.TOP, inward = true))
        assertRect(rect(0.0, 0.0, 0.95, 1.0), CropMath.nudged(f, Edge.RIGHT, inward = true))
        assertRect(rect(0.0, 0.0, 1.0, 0.95), CropMath.nudged(f, Edge.BOTTOM, inward = true))
    }

    @Test
    fun `辺を外側へ 5 パーセント動かす`() {
        assertRect(rect(0.15, 0.2, 0.8, 0.8), CropMath.nudged(base, Edge.LEFT, inward = false))
        assertRect(rect(0.2, 0.15, 0.8, 0.8), CropMath.nudged(base, Edge.TOP, inward = false))
        assertRect(rect(0.2, 0.2, 0.85, 0.8), CropMath.nudged(base, Edge.RIGHT, inward = false))
        assertRect(rect(0.2, 0.2, 0.8, 0.85), CropMath.nudged(base, Edge.BOTTOM, inward = false))
    }

    @Test
    fun `外側へは絵の端で止まる`() {
        val f = NormalizedRect.FULL
        for (e in Edge.entries) assertRect(f, CropMath.nudged(f, e, inward = false), e.name)
        assertRect(rect(0.0, 0.2, 0.8, 0.8), CropMath.nudged(rect(0.03, 0.2, 0.8, 0.8), Edge.LEFT, inward = false))
    }

    @Test
    fun `内側へは各辺 0,15 で止まる`() {
        val narrow = rect(0.0, 0.0, 0.2, 0.2)
        assertRect(rect(0.0, 0.0, 0.15, 0.2), CropMath.nudged(narrow, Edge.RIGHT, inward = true))
        assertRect(rect(0.0, 0.0, 0.2, 0.15), CropMath.nudged(narrow, Edge.BOTTOM, inward = true))
        val tight = rect(0.0, 0.0, 0.15, 0.15)
        for (e in Edge.entries) assertRect(tight, CropMath.nudged(tight, e, inward = true), e.name)
        val tightRight = rect(0.85, 0.85, 1.0, 1.0)
        assertRect(tightRight, CropMath.nudged(tightRight, Edge.LEFT, inward = true))
        assertRect(tightRight, CropMath.nudged(tightRight, Edge.TOP, inward = true))
    }

    @Test
    fun `刻みの幅を渡せる`() {
        assertRect(rect(0.1, 0.0, 1.0, 1.0), CropMath.nudged(NormalizedRect.FULL, Edge.LEFT, inward = true, step = 0.1))
    }

    @Test
    fun `辺を動かしても他の 3 辺は変わらない`() {
        val r = CropMath.nudged(base, Edge.LEFT, inward = true)
        assertEquals(base.top, r.top)
        assertEquals(base.right, r.right)
        assertEquals(base.bottom, r.bottom)
    }

    // ---- sanitized ----

    @Test
    fun `正しい範囲はそのまま`() {
        assertRect(NormalizedRect.FULL, CropMath.sanitized(NormalizedRect.FULL))
        assertRect(base, CropMath.sanitized(base))
    }

    @Test
    fun `ちょうど 0,15 の幅は壊れていない`() {
        // 0.35 − 0.2 は浮動小数で 0.15 よりわずかに小さくなるが、正しい範囲として残す
        val r = rect(0.2, 0.2, 0.35, 0.9)
        assertRect(r, CropMath.sanitized(r))
    }

    @Test
    fun `数でない値や無限大は全体にする`() {
        assertRect(NormalizedRect.FULL, CropMath.sanitized(rect(Double.NaN, 0.0, 1.0, 1.0)))
        assertRect(NormalizedRect.FULL, CropMath.sanitized(rect(0.0, Double.NaN, 1.0, 1.0)))
        assertRect(NormalizedRect.FULL, CropMath.sanitized(rect(0.0, 0.0, Double.POSITIVE_INFINITY, 1.0)))
        assertRect(NormalizedRect.FULL, CropMath.sanitized(rect(0.0, 0.0, 1.0, Double.NEGATIVE_INFINITY)))
    }

    @Test
    fun `逆向きや空の範囲は全体にする`() {
        assertRect(NormalizedRect.FULL, CropMath.sanitized(rect(0.8, 0.2, 0.2, 0.8)))
        assertRect(NormalizedRect.FULL, CropMath.sanitized(rect(0.2, 0.8, 0.8, 0.2)))
        assertRect(NormalizedRect.FULL, CropMath.sanitized(rect(0.5, 0.5, 0.5, 0.5)))
    }

    @Test
    fun `下限より小さい範囲は全体にする`() {
        assertRect(NormalizedRect.FULL, CropMath.sanitized(rect(0.2, 0.2, 0.3, 0.9)))
        assertRect(NormalizedRect.FULL, CropMath.sanitized(rect(0.2, 0.2, 0.9, 0.3)))
    }

    @Test
    fun `絵からはみ出した範囲は内側に収める`() {
        assertRect(rect(0.0, 0.0, 0.5, 1.0), CropMath.sanitized(rect(-0.2, -1.0, 0.5, 1.4)))
        // 収めた後に下限を割るなら全体
        assertRect(NormalizedRect.FULL, CropMath.sanitized(rect(1.5, 0.0, 2.0, 1.0)))
    }

    // ---- 回転と範囲の連動 ----

    /** 絵の中の点 (x, y) を時計回りに 90 度回した後の位置（手で決めた式：左上原点の 0〜1 の絵で (1−y, x)） */
    private fun rotatePointClockwise(x: Double, y: Double) = (1.0 - y) to x

    private val sample = rect(0.1, 0.2, 0.5, 0.7)

    @Test
    fun `時計回りに回すと範囲も絵と一緒に回る`() {
        val g = EditGeometry(quarterTurns = 0, crop = sample).rotatedClockwise()
        assertEquals(1, g.quarterTurns)
        assertRect(rect(0.3, 0.1, 0.8, 0.5), g.crop)
    }

    @Test
    fun `反時計回りに回すと範囲も絵と一緒に回る`() {
        val g = EditGeometry(quarterTurns = 0, crop = sample).rotatedCounterClockwise()
        assertEquals(3, g.quarterTurns)
        // 反時計回りの点の動き (x, y) → (y, 1−x) で四隅を手で計算：(0.2, 0.5)〜(0.7, 0.9)
        assertRect(rect(0.2, 0.5, 0.7, 0.9), g.crop)
    }

    @Test
    fun `向きは 4 で割った余りで回る`() {
        var g = EditGeometry.NONE
        val seen = mutableListOf<Int>()
        repeat(5) { g = g.rotatedClockwise(); seen += g.quarterTurns }
        assertEquals(listOf(1, 2, 3, 0, 1), seen)

        g = EditGeometry.NONE
        seen.clear()
        repeat(5) { g = g.rotatedCounterClockwise(); seen += g.quarterTurns }
        assertEquals(listOf(3, 2, 1, 0, 3), seen)
    }

    @Test
    fun `全体の範囲は回しても全体`() {
        assertRect(NormalizedRect.FULL, EditGeometry.NONE.rotatedClockwise().crop)
        assertRect(NormalizedRect.FULL, EditGeometry.NONE.rotatedCounterClockwise().crop)
    }

    @Test
    fun `4 回回すと元に戻る`() {
        val start = EditGeometry(quarterTurns = 2, crop = sample)
        var cw = start
        repeat(4) { cw = cw.rotatedClockwise() }
        assertEquals(start.quarterTurns, cw.quarterTurns)
        assertRect(start.crop, cw.crop, "時計回り")

        var ccw = start
        repeat(4) { ccw = ccw.rotatedCounterClockwise() }
        assertEquals(start.quarterTurns, ccw.quarterTurns)
        assertRect(start.crop, ccw.crop, "反時計回り")
    }

    @Test
    fun `時計回りと反時計回りは打ち消し合う`() {
        val start = EditGeometry(quarterTurns = 1, crop = sample)
        val a = start.rotatedClockwise().rotatedCounterClockwise()
        assertEquals(start.quarterTurns, a.quarterTurns)
        assertRect(start.crop, a.crop)
        val b = start.rotatedCounterClockwise().rotatedClockwise()
        assertEquals(start.quarterTurns, b.quarterTurns)
        assertRect(start.crop, b.crop)
    }

    @Test
    fun `回しても同じ中身を指す`() {
        // 範囲の四隅の点を絵と一緒に回した位置の外接の矩形が、回した後の範囲と一致する
        val crops = listOf(sample, rect(0.0, 0.0, 0.3, 0.9), rect(0.6, 0.1, 1.0, 0.4), NormalizedRect.FULL)
        for (c in crops) {
            val corners = listOf(c.left to c.top, c.right to c.top, c.left to c.bottom, c.right to c.bottom)
                .map { (x, y) -> rotatePointClockwise(x, y) }
            val expected = rect(
                corners.minOf { it.first }, corners.minOf { it.second },
                corners.maxOf { it.first }, corners.maxOf { it.second },
            )
            assertRect(expected, EditGeometry(0, c).rotatedClockwise().crop, "$c")
        }
    }

    @Test
    fun `回すと範囲の幅と高さが入れ替わる`() {
        val g = EditGeometry(0, sample).rotatedClockwise()
        assertEquals(sample.height, g.crop.width, delta)
        assertEquals(sample.width, g.crop.height, delta)
    }

    @Test
    fun `回した後の範囲も内側に収まる`() {
        for (c in listOf(sample, rect(0.0, 0.0, 0.15, 1.0), rect(0.85, 0.85, 1.0, 1.0))) {
            var g = EditGeometry(0, c)
            repeat(4) {
                g = g.rotatedClockwise()
                val r = g.crop
                assertTrue(min(min(r.left, r.top), min(r.right, r.bottom)) >= -delta, "$r")
                assertTrue(max(max(r.left, r.top), max(r.right, r.bottom)) <= 1.0 + delta, "$r")
                assertTrue(abs(r.width) >= CropMath.MIN_SIDE - delta && abs(r.height) >= CropMath.MIN_SIDE - delta, "$r")
            }
        }
    }

    @Test
    fun `向きが負や 4 以上の古い値からも 0〜3 に戻る`() {
        assertEquals(0, EditGeometry(quarterTurns = -1).rotatedClockwise().quarterTurns)
        assertEquals(2, EditGeometry(quarterTurns = -1).rotatedCounterClockwise().quarterTurns)
        assertEquals(2, EditGeometry(quarterTurns = 5).rotatedClockwise().quarterTurns)
        assertEquals(0, EditGeometry(quarterTurns = 5).rotatedCounterClockwise().quarterTurns)
    }
}
