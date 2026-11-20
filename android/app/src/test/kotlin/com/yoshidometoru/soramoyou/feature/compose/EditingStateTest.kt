// ⭐️ 編集の状態の操作（EditingState）の単体テスト（Kiro android-edit-tools タスク 15・部品 U1・design.md:1139）
package com.yoshidometoru.soramoyou.feature.compose

import com.yoshidometoru.soramoyou.contract.edit.CropMath
import com.yoshidometoru.soramoyou.contract.edit.EditGeometry
import com.yoshidometoru.soramoyou.contract.edit.EditHistory
import com.yoshidometoru.soramoyou.contract.edit.EditTool
import com.yoshidometoru.soramoyou.contract.edit.Loadout
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.model.FilterId
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.data.edit.WorkingPhoto
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

class EditingStateTest {

    private fun photo(n: Int, edit: PhotoEdit = PhotoEdit.NONE) = EditingPhoto(WorkingPhoto("content://p/$n", null, null), edit)

    private fun three() = listOf(photo(0), photo(1), photo(2))

    private fun withTool(tool: EditTool, value: Int) = PhotoEdit.NONE.copy(tools = PhotoEdit.NONE.tools.with(tool, value))

    /** 今の枠の左上の取っ手を dx 動かす（start は今の枠。CropPanel が差分を渡す形） */
    private fun drag(session: CropSession, dx: Double): CropSession =
        EditingState.dragCrop(session, session.pending.crop, CropMath.Handle.TOP_LEFT, dx, dx)

    private fun confirmed(photo: EditingPhoto, session: CropSession): EditingPhoto =
        EditingState.confirmCrop(listOf(photo), 0, session)[0]

    // ---- 表示中の写真だけを変える ----

    @Test
    fun `selectFilter は index の写真だけを変え、ほかの写真は同じ物のまま`() {
        val before = three()
        val after = EditingState.selectFilter(before, 1, FilterId.WARM)
        assertEquals(FilterId.WARM, after[1].edit.filter)
        assertSame(before[0], after[0])
        assertSame(before[2], after[2])
        assertEquals(listOf(PhotoEdit.NONE), after[1].history.undo)
    }

    @Test
    fun `selectFilter は前のフィルターを置き換え、ツール・切り抜き・回転は変えない`() {
        val geometry = EditGeometry(1, NormalizedRect(0.1, 0.1, 0.9, 0.9))
        val edit = withTool(EditTool.EXPOSURE, 30).copy(filter = FilterId.COOL, geometry = geometry)
        val after = EditingState.selectFilter(listOf(photo(0, edit)), 0, FilterId.DRAMA)[0].edit
        assertEquals(FilterId.DRAMA, after.filter)
        assertEquals(edit.tools, after.tools)
        assertEquals(geometry, after.geometry)
    }

    @Test
    fun `selectFilter で同じフィルターを選んでも積まない`() {
        val photos = EditingState.selectFilter(three(), 0, FilterId.WARM)
        val again = EditingState.selectFilter(photos, 0, FilterId.WARM)
        assertEquals(photos[0].history, again[0].history)
    }

    @Test
    fun `slide は index の写真の値だけを変える`() {
        val before = three()
        val after = EditingState.slide(before, 2, EditTool.CONTRAST, 40)
        assertEquals(40, after[2].edit.tools[EditTool.CONTRAST])
        assertSame(before[0], after[0])
        assertSame(before[1], after[1])
    }

    @Test
    fun `undo と redo は index の写真だけを動かす`() {
        var photos = three()
        photos = EditingState.selectFilter(photos, 0, FilterId.WARM)
        photos = EditingState.selectFilter(photos, 1, FilterId.COOL)
        val undone = EditingState.undo(photos, 1)
        assertEquals(null, undone[1].edit.filter)
        assertSame(photos[0], undone[0])
        val redone = EditingState.redo(undone, 1)
        assertEquals(FilterId.COOL, redone[1].edit.filter)
        assertSame(photos[0], redone[0])
    }

    @Test
    fun `confirmCrop は index の写真だけを変える`() {
        val photos = three()
        val session = EditingState.rotateCrop(EditingState.beginCrop(photos[1].edit), clockwise = true)
        val after = EditingState.confirmCrop(photos, 1, session)
        assertEquals(1, after[1].edit.geometry.quarterTurns)
        assertSame(photos[0], after[0])
        assertSame(photos[2], after[2])
    }

    @Test
    fun `index が範囲外なら一覧は変わらない`() {
        val photos = three()
        assertSame(photos, EditingState.selectFilter(photos, 3, FilterId.WARM))
        assertSame(photos, EditingState.slide(photos, -1, EditTool.EXPOSURE, 5))
        assertSame(photos, EditingState.undo(photos, 9))
    }

    // ---- スライダー ----

    @Test
    fun `slide は履歴に積まない`() {
        var photos = three()
        photos = EditingState.slide(photos, 0, EditTool.EXPOSURE, 10)
        photos = EditingState.slide(photos, 0, EditTool.EXPOSURE, 20)
        assertEquals(EditHistory.EMPTY, photos[0].history)
        assertEquals(20, photos[0].edit.tools[EditTool.EXPOSURE])
    }

    @Test
    fun `スライダーは離した時に 1 手になり、触れた時の内容へ 1 回で戻る`() {
        val start = EditingState.selectFilter(three(), 0, FilterId.WARM)
        val touched = start[0].edit
        var photos = EditingState.slide(start, 0, EditTool.EXPOSURE, 10)
        photos = EditingState.slide(photos, 0, EditTool.EXPOSURE, 55)
        photos = EditingState.endSlider(photos, 0, touched)
        assertEquals(2, photos[0].history.undo.size)
        assertEquals(touched, photos[0].history.undo.last())
        photos = EditingState.undo(photos, 0)
        assertEquals(touched, photos[0].edit)
        assertEquals(0, photos[0].edit.tools[EditTool.EXPOSURE])
    }

    @Test
    fun `値が変わらなかったスライダーは積まない`() {
        var photos = three()
        val touched = photos[0].edit
        photos = EditingState.slide(photos, 0, EditTool.EXPOSURE, 10)
        photos = EditingState.slide(photos, 0, EditTool.EXPOSURE, 0)
        photos = EditingState.endSlider(photos, 0, touched)
        assertEquals(EditHistory.EMPTY, photos[0].history)
    }

    @Test
    fun `endSlider は index の写真だけを変える`() {
        val before = three()
        val touched = before[1].edit
        var photos = EditingState.slide(before, 1, EditTool.FADE, 30)
        photos = EditingState.endSlider(photos, 1, touched)
        assertSame(before[0], photos[0])
        assertSame(before[2], photos[2])
        assertTrue(photos[1].history.canUndo)
    }

    @Test
    fun `スライダーでないツールを slide すると例外`() {
        assertFailsWith<IllegalArgumentException> { EditingState.slide(three(), 0, EditTool.CROP_AND_ROTATE, 10) }
    }

    @Test
    fun `undo と redo は戻せない・やり直せないときは何もしない`() {
        val photos = three()
        assertSame(photos[0], EditingState.undo(photos, 0)[0])
        assertSame(photos[0], EditingState.redo(photos, 0)[0])
    }

    // ---- 切り抜き・回転の確定の手の数 ----

    @Test
    fun `beginCrop は original と pending が edit の向きと枠で、手は空`() {
        val g = EditGeometry(2, NormalizedRect(0.1, 0.1, 0.9, 0.9))
        val s = EditingState.beginCrop(PhotoEdit.NONE.copy(geometry = g))
        assertEquals(CropSession(g, g, emptyList()), s)
    }

    @Test
    fun `枠を動かす→回す→確定 は 2 手で、元に戻す 1 回で回転だけが戻り、もう 1 回で枠が戻る`() {
        val base = photo(0)
        var s = EditingState.beginCrop(base.edit)
        s = drag(s, 0.1)
        val framed = s.pending
        s = EditingState.rotateCrop(s, clockwise = true)
        val p = confirmed(base, s)
        assertEquals(2, p.history.undo.size)
        assertEquals(s.pending, p.edit.geometry)

        val once = EditingState.undo(listOf(p), 0)[0]
        assertEquals(framed.crop, once.edit.geometry.crop)
        assertEquals(0, once.edit.geometry.quarterTurns)
        assertEquals(framed, once.edit.geometry)
        assertTrue(once.history.canUndo)

        val twice = EditingState.undo(listOf(once), 0)[0]
        assertEquals(EditGeometry.NONE, twice.edit.geometry)
        assertFalse(twice.history.canUndo)
    }

    @Test
    fun `回す→枠を動かす→確定 は 2 手`() {
        val base = photo(0)
        var s = EditingState.beginCrop(base.edit)
        s = EditingState.rotateCrop(s, clockwise = true)
        val rotated = s.pending
        s = drag(s, 0.1)
        val p = confirmed(base, s)
        assertEquals(2, p.history.undo.size)
        // 1 回戻すと、枠の変更だけが戻って回した後の状態になる
        assertEquals(rotated, EditingState.undo(listOf(p), 0)[0].edit.geometry)
    }

    @Test
    fun `回すだけ→確定 は 1 手`() {
        val base = photo(0)
        val s = EditingState.rotateCrop(EditingState.beginCrop(base.edit), clockwise = false)
        val p = confirmed(base, s)
        assertEquals(1, p.history.undo.size)
        assertEquals(3, p.edit.geometry.quarterTurns)
    }

    @Test
    fun `枠を続けて 3 回動かす→確定 は 1 手`() {
        val base = photo(0)
        var s = EditingState.beginCrop(base.edit)
        s = drag(s, 0.05)
        s = drag(s, 0.05)
        s = drag(s, 0.05)
        assertEquals(1, s.steps.size)
        val p = confirmed(base, s)
        assertEquals(1, p.history.undo.size)
        assertEquals(0.15, p.edit.geometry.crop.left, 1e-9)
        assertEquals(EditGeometry.NONE, EditingState.undo(listOf(p), 0)[0].edit.geometry)
    }

    @Test
    fun `枠の nudge も続けて動かせば 1 手にまとまる`() {
        val base = photo(0)
        var s = EditingState.beginCrop(base.edit)
        s = EditingState.nudgeCrop(s, CropMath.Edge.LEFT, inward = true)
        s = EditingState.nudgeCrop(s, CropMath.Edge.TOP, inward = true)
        assertEquals(1, s.steps.size)
        assertEquals(1, confirmed(base, s).history.undo.size)
    }

    @Test
    fun `枠を動かす→回す→枠を動かす→確定 は 3 手`() {
        val base = photo(0)
        var s = EditingState.beginCrop(base.edit)
        s = drag(s, 0.1)
        s = EditingState.rotateCrop(s, clockwise = true)
        s = drag(s, 0.1)
        assertEquals(3, s.steps.size)
        val p = confirmed(base, s)
        assertEquals(3, p.history.undo.size)
        assertEquals(s.pending, p.edit.geometry)
    }

    @Test
    fun `何も変えずに確定 は 0 手`() {
        val base = photo(0, withTool(EditTool.EXPOSURE, 10))
        val p = confirmed(base, EditingState.beginCrop(base.edit))
        assertEquals(base, p)
    }

    @Test
    fun `4 回回す→確定 は向きが元に戻っても、途中の回転は 4 手とも積まれる`() {
        val base = photo(0)
        var s = EditingState.beginCrop(base.edit)
        repeat(4) { s = EditingState.rotateCrop(s, clockwise = true) }
        assertEquals(4, s.steps.size)
        assertEquals(EditGeometry.NONE, s.pending)
        // 手ごとの前後はどれも違う（向きが 1 つずつ変わる）ので 4 手。original と最終が同じでも途中の手は積まれる
        assertEquals(4, confirmed(base, s).history.undo.size)
    }

    @Test
    fun `右に回して左に回し直した確定は、最後の手だけ元と同じになり 2 手`() {
        val base = photo(0)
        var s = EditingState.beginCrop(base.edit)
        s = EditingState.rotateCrop(s, clockwise = true)
        s = EditingState.rotateCrop(s, clockwise = false)
        val p = confirmed(base, s)
        assertEquals(2, p.history.undo.size)
        assertEquals(EditGeometry.NONE, p.edit.geometry)
    }

    @Test
    fun `確定はツールとフィルターを変えず、やり直しを消す`() {
        val edit = withTool(EditTool.EXPOSURE, 10).copy(filter = FilterId.WARM)
        var photos = listOf(photo(0, edit))
        photos = EditingState.selectFilter(photos, 0, FilterId.COOL)
        photos = EditingState.undo(photos, 0)
        assertTrue(photos[0].history.canRedo)
        val s = EditingState.rotateCrop(EditingState.beginCrop(photos[0].edit), clockwise = true)
        val after = EditingState.confirmCrop(photos, 0, s)[0]
        assertEquals(FilterId.WARM, after.edit.filter)
        assertEquals(10, after.edit.tools[EditTool.EXPOSURE])
        assertFalse(after.history.canRedo)
    }

    @Test
    fun `取りやめは写真を変えない（session を使わなければ photos は同じ）`() {
        val photos = three()
        var s = EditingState.beginCrop(photos[0].edit)
        s = drag(s, 0.2)
        s = EditingState.rotateCrop(s, clockwise = true)
        // 取りやめ＝ViewModel が session を捨てるだけ。操作の関数は photos を受け取らないので、photos は元のまま
        assertEquals(three().map { it.edit }, photos.map { it.edit })
        assertEquals(EditHistory.EMPTY, photos[0].history)
    }

    // ---- toolsToShow ----

    @Test
    fun `toolsToShow は装備のツールだけを装備の順で返す`() {
        val loadout = Loadout(listOf(EditTool.FADE, EditTool.EXPOSURE, EditTool.CROP_AND_ROTATE))
        assertEquals(listOf(EditTool.FADE, EditTool.EXPOSURE, EditTool.CROP_AND_ROTATE), EditingState.toolsToShow(loadout, PhotoEdit.NONE))
    }

    @Test
    fun `装備から外れたツールは値が 0 でなくても返さず、値は edit に残る`() {
        val edit = withTool(EditTool.SATURATION, 40)
        val loadout = Loadout(listOf(EditTool.EXPOSURE, EditTool.BRIGHTNESS))
        val shown = EditingState.toolsToShow(loadout, edit)
        assertEquals(listOf(EditTool.EXPOSURE, EditTool.BRIGHTNESS), shown)
        assertFalse(EditTool.SATURATION in shown)
        assertEquals(40, edit.tools[EditTool.SATURATION])
        // 装備の画面で外れた後も、ほかの操作で値は消えない
        val photos = EditingState.slide(listOf(photo(0, edit)), 0, EditTool.EXPOSURE, 5)
        assertEquals(40, photos[0].edit.tools[EditTool.SATURATION])
    }

    // ---- hasWork ----

    @Test
    fun `hasWork は編集・キャプション・公開範囲のどれかがあれば真`() {
        assertFalse(EditingState.hasWork(three(), "", Visibility.PUBLIC))
        assertTrue(EditingState.hasWork(EditingState.selectFilter(three(), 2, FilterId.WARM), "", Visibility.PUBLIC))
        assertTrue(EditingState.hasWork(three(), "空", Visibility.PUBLIC))
        assertTrue(EditingState.hasWork(three(), "", Visibility.PRIVATE))
        assertFalse(EditingState.hasWork(three(), "   ", Visibility.PUBLIC))
    }
}
