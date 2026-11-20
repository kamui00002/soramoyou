// ⭐️ スライダーの値の単体テスト（Kiro android-edit-tools タスク 5・C2・要件 3.1・3.3・4.1）
package com.yoshidometoru.soramoyou.contract.edit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * [ToolValues] を確かめる。百分の 1 の整数で持ち、0 は持たず、範囲外は切り詰める。
 *
 * 陽性対照（メインが流す）：`with` の `if (clamped == 0) next.remove(tool) else …` の 0 を消す処理を外すと、
 * 「0 にすると持たなくなる」「0 に戻すと何も掛けていない状態と等しい」が赤になる。
 */
class ToolValuesTest {

    @Test
    fun `何も設定していないツールは 0`() {
        for (t in EditTool.entries) assertEquals(0, ToolValues.NONE[t], t.raw)
        assertTrue(ToolValues.NONE.adjusted.isEmpty())
    }

    @Test
    fun `値を設定すると取れ、他のツールは変わらない`() {
        val v = ToolValues.NONE.with(EditTool.EXPOSURE, 30).with(EditTool.FADE, -45)
        assertEquals(30, v[EditTool.EXPOSURE])
        assertEquals(-45, v[EditTool.FADE])
        assertEquals(0, v[EditTool.CONTRAST])
        assertEquals(setOf(EditTool.EXPOSURE, EditTool.FADE), v.adjusted)
    }

    @Test
    fun `範囲の端はそのまま通る`() {
        assertEquals(100, ToolValues.NONE.with(EditTool.EXPOSURE, 100)[EditTool.EXPOSURE])
        assertEquals(-100, ToolValues.NONE.with(EditTool.EXPOSURE, -100)[EditTool.EXPOSURE])
    }

    @Test
    fun `範囲外は −100 から 100 に切り詰める`() {
        assertEquals(100, ToolValues.NONE.with(EditTool.BRIGHTNESS, 101)[EditTool.BRIGHTNESS])
        assertEquals(100, ToolValues.NONE.with(EditTool.BRIGHTNESS, 100000)[EditTool.BRIGHTNESS])
        assertEquals(100, ToolValues.NONE.with(EditTool.BRIGHTNESS, Int.MAX_VALUE)[EditTool.BRIGHTNESS])
        assertEquals(-100, ToolValues.NONE.with(EditTool.BRIGHTNESS, -101)[EditTool.BRIGHTNESS])
        assertEquals(-100, ToolValues.NONE.with(EditTool.BRIGHTNESS, Int.MIN_VALUE)[EditTool.BRIGHTNESS])
    }

    @Test
    fun `0 にすると持たなくなる`() {
        val v = ToolValues.NONE.with(EditTool.EXPOSURE, 50).with(EditTool.EXPOSURE, 0)
        assertEquals(0, v[EditTool.EXPOSURE])
        assertFalse(EditTool.EXPOSURE in v.adjusted)
        assertTrue(v.adjusted.isEmpty())
    }

    @Test
    fun `0 に戻すと何も掛けていない状態と等しい`() {
        val v = ToolValues.NONE.with(EditTool.TINT, 12).with(EditTool.TINT, 0)
        assertEquals(ToolValues.NONE, v)
        assertEquals(ToolValues.NONE.hashCode(), v.hashCode())
        // 0 を直接設定しても同じ
        assertEquals(ToolValues.NONE, ToolValues.NONE.with(EditTool.TINT, 0))
    }

    @Test
    fun `範囲外から切り詰めた結果が 0 になることはない`() {
        // 切り詰めの後に 0 判定をするので、大きな値が 0 扱いで消えることはない
        assertEquals(setOf(EditTool.FADE), ToolValues.NONE.with(EditTool.FADE, 1000).adjusted)
    }

    @Test
    fun `0 でないツールの一覧は設定した順に依らない`() {
        val v = ToolValues.NONE.with(EditTool.SATURATION, 1).with(EditTool.WARMTH, 2).with(EditTool.TINT, 3).with(EditTool.TINT, 0)
        assertEquals(setOf(EditTool.SATURATION, EditTool.WARMTH), v.adjusted)
    }

    @Test
    fun `正規化は百分の 1 を −1 から 1 にする`() {
        val v = ToolValues.NONE.with(EditTool.EXPOSURE, 50).with(EditTool.CONTRAST, -100).with(EditTool.FADE, 100).with(EditTool.TINT, 7)
        assertEquals(0.5, v.normalized(EditTool.EXPOSURE), 1e-12)
        assertEquals(-1.0, v.normalized(EditTool.CONTRAST), 1e-12)
        assertEquals(1.0, v.normalized(EditTool.FADE), 1e-12)
        assertEquals(0.07, v.normalized(EditTool.TINT), 1e-12)
        assertEquals(0.0, v.normalized(EditTool.BLACK_POINT), 0.0)
    }

    @Test
    fun `元の値は変わらない`() {
        val a = ToolValues.NONE.with(EditTool.EXPOSURE, 10)
        val b = a.with(EditTool.EXPOSURE, 20)
        assertEquals(10, a[EditTool.EXPOSURE])
        assertEquals(20, b[EditTool.EXPOSURE])
        assertEquals(0, ToolValues.NONE[EditTool.EXPOSURE])
    }

    @Test
    fun `等しさは中身で決まり、設定の順に依らない`() {
        val a = ToolValues.NONE.with(EditTool.EXPOSURE, 10).with(EditTool.FADE, 20)
        val b = ToolValues.NONE.with(EditTool.FADE, 20).with(EditTool.EXPOSURE, 10)
        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
        assertNotEquals(a, ToolValues.NONE.with(EditTool.EXPOSURE, 10))
        assertNotEquals(a, ToolValues.NONE.with(EditTool.EXPOSURE, 10).with(EditTool.FADE, 21))
        assertNotEquals<Any?>(a, "ToolValues")
        assertNotEquals<Any?>(a, null)
    }

    @Test
    fun `スライダーでないツールは例外`() {
        assertFailsWith<IllegalArgumentException> { ToolValues.NONE.with(EditTool.CROP_AND_ROTATE, 10) }
        // 0 を渡しても、100 を超えていても、スライダーでなければ例外（値で通り抜けない）
        assertFailsWith<IllegalArgumentException> { ToolValues.NONE.with(EditTool.CROP_AND_ROTATE, 0) }
        assertFailsWith<IllegalArgumentException> { ToolValues.NONE.with(EditTool.CROP_AND_ROTATE, 1000) }
    }

    @Test
    fun `PhotoEdit は NONE と等しいときだけ何も掛けていない`() {
        assertTrue(PhotoEdit.NONE.isNeutral)
        assertTrue(PhotoEdit(tools = ToolValues.NONE.with(EditTool.EXPOSURE, 5).with(EditTool.EXPOSURE, 0)).isNeutral)
        assertFalse(PhotoEdit(tools = ToolValues.NONE.with(EditTool.EXPOSURE, 5)).isNeutral)
        assertFalse(PhotoEdit(geometry = EditGeometry(quarterTurns = 1)).isNeutral)
        assertFalse(PhotoEdit(geometry = EditGeometry(crop = NormalizedRect(0.1, 0.0, 1.0, 1.0))).isNeutral)
    }
}
