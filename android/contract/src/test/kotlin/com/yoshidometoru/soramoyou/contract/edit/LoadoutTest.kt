// ⭐️ 装備（Loadout）の単体テスト（Kiro android-edit-tools タスク 6・C3・design.md:518-524）
package com.yoshidometoru.soramoyou.contract.edit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 既定の装備・[Loadout.sanitized]・[Loadout.canSave] を確かめる。
 *
 * 陽性対照：`sanitized` が知らない名前（や重複）を通すようにすると、
 * 「知らない名前と重複を捨てる」の 2 本が赤になる（壊す場所は Loadout.kt の `sanitized` の `mapNotNull` / `distinct`）。
 */
class LoadoutTest {

    @Test
    fun `既定は11個で EditTool の並びと同じ`() {
        assertEquals(11, Loadout.DEFAULT.tools.size)
        assertEquals(EditTool.entries.toList(), Loadout.DEFAULT.tools)
    }

    @Test
    fun `知らない名前を捨てる`() {
        val loadout = Loadout.sanitized(listOf("exposure", "bogus", "contrast", "", " exposure", "Exposure"))
        // 完全一致だけ残る（空・前後に空白・大文字違いは知らない名前）
        assertEquals(listOf(EditTool.EXPOSURE, EditTool.CONTRAST), loadout.tools)
    }

    @Test
    fun `重複を捨てて先に出たものを残す`() {
        val loadout = Loadout.sanitized(listOf("saturation", "exposure", "saturation", "exposure", "fade"))
        assertEquals(listOf(EditTool.SATURATION, EditTool.EXPOSURE, EditTool.FADE), loadout.tools)
    }

    @Test
    fun `渡された順を保つ`() {
        val raws = listOf("fade", "exposure", "cropAndRotate")
        assertEquals(
            listOf(EditTool.FADE, EditTool.EXPOSURE, EditTool.CROP_AND_ROTATE),
            Loadout.sanitized(raws).tools,
        )
    }

    @Test
    fun `空なら既定`() {
        assertEquals(Loadout.DEFAULT, Loadout.sanitized(emptyList()))
    }

    @Test
    fun `全部知らない名前でも既定`() {
        assertEquals(Loadout.DEFAULT, Loadout.sanitized(listOf("x", "y", "x")))
    }

    @Test
    fun `canSave は1個以上`() {
        assertFalse(Loadout(emptyList()).canSave)
        assertTrue(Loadout(listOf(EditTool.TINT)).canSave)
        assertTrue(Loadout.DEFAULT.canSave)
    }
}
