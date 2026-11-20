// ⭐️ 写真の選択の受け付けの単体テスト（タスク 21.1・要件 6.3・6.4。画面の状態のテストは PostComposerViewModelTest）
package com.yoshidometoru.soramoyou.feature.compose

import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 写真選択画面の上限（10 枚）が効かなかった場合でも、受け取った側で 10 枚までに絞り、超えたことを案内させることを確かめる。
 * 陽性対照：上限の検査を外す（全部受け付ける）・超過の判定を外す、の 2 つの改変で赤になることを確かめた（手元の台本・git の外）。
 */
class PhotoSelectionTest {

    private fun uris(count: Int) = (0 until count).map { "content://media/picker/0/photo/$it" }

    @Test
    fun `1枚から10枚までは全部を選んだ順に受け付ける`() {
        for (count in listOf(1, 2, 10)) {
            val selection = PhotoSelection.accept(uris(count))
            assertEquals(uris(count).mapIndexed { index, uri -> PickedPhoto(uri, index) }, selection.photos, "$count 枚")
            assertFalse(selection.exceeded, "$count 枚")
        }
    }

    @Test
    fun `11枚以上は先頭の10枚だけを受け付け、超えたことを伝える`() {
        for (count in listOf(11, 30)) {
            val selection = PhotoSelection.accept(uris(count))
            assertEquals(uris(10).mapIndexed { index, uri -> PickedPhoto(uri, index) }, selection.photos, "$count 枚")
            assertTrue(selection.exceeded, "$count 枚")
        }
    }

    @Test
    fun `何も選ばなければ空で、超えてもいない`() {
        assertEquals(PhotoSelection.EMPTY, PhotoSelection.accept(emptyList()))
    }
}
