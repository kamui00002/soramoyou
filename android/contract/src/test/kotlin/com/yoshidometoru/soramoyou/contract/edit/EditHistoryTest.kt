// ⭐️ 編集の履歴（元に戻す・やり直し）の単体テスト（Kiro android-edit-tools タスク 5・C2・要件 6.3〜6.5・6.9）
package com.yoshidometoru.soramoyou.contract.edit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * [EditHistory] の動きを確かめる。写した元：iOS EditHistoryManager.swift（push / undo / redo、上限 50）。
 *
 * 陽性対照（メインが流す）：`committed` の先頭の `if (before == after) return this` を外すと
 * 「同じ内容は積まない」の 2 本が赤になる。
 */
class EditHistoryTest {

    /** 露出の値だけが違う編集。n は 1〜100（0 は NONE と同じになるので使わない） */
    private fun edit(n: Int): PhotoEdit = PhotoEdit(tools = ToolValues.NONE.with(EditTool.EXPOSURE, n))

    @Test
    fun `上限は iOS と同じ 50`() {
        assertEquals(50, EditHistory.MAX_STEPS)
    }

    @Test
    fun `空の履歴は戻せずやり直せない`() {
        val h = EditHistory.EMPTY
        assertFalse(h.canUndo)
        assertFalse(h.canRedo)
        assertNull(h.undone(edit(1)))
        assertNull(h.redone(edit(1)))
    }

    @Test
    fun `変える前を積み、やり直しは空のまま`() {
        val h = EditHistory.EMPTY.committed(edit(1), edit(2))
        assertEquals(listOf(edit(1)), h.undo)
        assertTrue(h.redo.isEmpty())
        assertTrue(h.canUndo)
        assertFalse(h.canRedo)
    }

    @Test
    fun `1 手ずつ戻り、戻せなくなると null`() {
        // s1 → s2 → s3 → s4 と 3 回変えた
        var h = EditHistory.EMPTY
        h = h.committed(edit(1), edit(2))
        h = h.committed(edit(2), edit(3))
        h = h.committed(edit(3), edit(4))

        val (h1, back1) = assertNotNull(h.undone(edit(4)))
        assertEquals(edit(3), back1)
        val (h2, back2) = assertNotNull(h1.undone(back1))
        assertEquals(edit(2), back2)
        val (h3, back3) = assertNotNull(h2.undone(back2))
        assertEquals(edit(1), back3)
        assertFalse(h3.canUndo)
        assertNull(h3.undone(back3))
        // 戻した分だけやり直しに積まれている（直前の現在の内容が末尾）
        assertEquals(listOf(edit(4), edit(3), edit(2)), h3.redo)
    }

    @Test
    fun `戻した後は 1 手ずつやり直せ、やり直せなくなると null`() {
        var h = EditHistory.EMPTY
        h = h.committed(edit(1), edit(2))
        h = h.committed(edit(2), edit(3))
        val (u1, cur1) = assertNotNull(h.undone(edit(3)))
        val (u2, cur2) = assertNotNull(u1.undone(cur1))
        assertEquals(edit(1), cur2)

        val (r1, fwd1) = assertNotNull(u2.redone(cur2))
        assertEquals(edit(2), fwd1)
        val (r2, fwd2) = assertNotNull(r1.redone(fwd1))
        assertEquals(edit(3), fwd2)
        assertFalse(r2.canRedo)
        assertNull(r2.redone(fwd2))
        // 戻して全部やり直すと、履歴は元と同じ
        assertEquals(h, r2)
    }

    @Test
    fun `新しい操作でやり直しが消える`() {
        var h = EditHistory.EMPTY
        h = h.committed(edit(1), edit(2))
        h = h.committed(edit(2), edit(3))
        val (undone, cur) = assertNotNull(h.undone(edit(3)))
        assertTrue(undone.canRedo)

        // 戻った所（edit(2)）から別の操作をした
        val branched = undone.committed(cur, edit(50))
        assertFalse(branched.canRedo)
        assertTrue(branched.redo.isEmpty())
        assertEquals(listOf(edit(1), edit(2)), branched.undo)
    }

    @Test
    fun `同じ内容は積まず、同じ履歴をそのまま返す`() {
        val h = EditHistory.EMPTY.committed(edit(1), edit(2))
        // 同じインスタンス
        assertSame(h, h.committed(edit(2), edit(2)))
        // 等しい別のインスタンス
        assertSame(h, h.committed(edit(7), edit(7)))
        assertEquals(1, h.undo.size)
    }

    @Test
    fun `同じ内容の操作はやり直しも消さない`() {
        var h = EditHistory.EMPTY.committed(edit(1), edit(2))
        val (undone, cur) = assertNotNull(h.undone(edit(2)))
        h = undone.committed(cur, cur)
        assertTrue(h.canRedo)
    }

    @Test
    fun `50 手目までは全部残り、51 手目で最古が消える`() {
        // p[0] … p[51]。p[i] → p[i+1] を 50 回で 50 手、51 回で 51 手
        val p = List(52) { edit(it + 1) }

        var h = EditHistory.EMPTY
        for (i in 0 until 50) h = h.committed(p[i], p[i + 1])
        assertEquals(50, h.undo.size)
        assertEquals(p[0], h.undo.first())
        assertEquals(p[49], h.undo.last())

        h = h.committed(p[50], p[51])
        assertEquals(50, h.undo.size)
        assertEquals(p[1], h.undo.first())   // 最古の p[0] が捨てられた
        assertEquals(p[50], h.undo.last())

        // 50 回戻すと p[1] まで戻り、その先は無い
        var cur = p[51]
        repeat(50) {
            val (next, back) = assertNotNull(h.undone(cur))
            h = next
            cur = back
        }
        assertEquals(p[1], cur)
        assertNull(h.undone(cur))
    }
}
