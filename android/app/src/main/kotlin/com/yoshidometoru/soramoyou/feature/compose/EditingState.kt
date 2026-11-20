// ⭐️ 編集の画面の状態の型と、編集の操作の純粋な関数の形（Kiro android-edit-tools タスク 2.3・K0・design.md:685-724）
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

/*
 * K0 は型と関数の形だけを置く（design.md:353。形は K0 の後で変えない）。[EditingState] の関数の中身は部品 U1（タスク 15）が入れた
 * （K0 では未実装でよいもの：design.md:359）。K0 の時点の ViewModel は [EditingState] の関数を呼ばない
 * （フィルターの選択は、今と同じく全ての写真の [PhotoEdit.filter] を直接書き換える。写真ごとの編集と履歴は I1）。
 */

/** 編集の段の 1 枚の写真：写真・その写真の編集の内容・その写真の履歴 */
data class EditingPhoto(val photo: WorkingPhoto, val edit: PhotoEdit = PhotoEdit.NONE, val history: EditHistory = EditHistory.EMPTY)

/** トリミング・回転の画面の中の 1 手。after はその手の後の内容 */
data class CropStep(val after: EditGeometry, val isRotation: Boolean)

/**
 * トリミング・回転の画面を開いている間の仮の状態。steps は確定の時に履歴へ積む手を、操作の順に並べたもの。
 * - 回転 1 回ごとに、回した後の内容を新しい手として足す（isRotation = true）
 * - 枠の変更（dragCrop・nudgeCrop）は、最後の手が枠の変更ならその手の after を置き換え、そうでなければ新しい手として足す
 *   （続けて枠を動かした分はまとめて 1 手。間に回転が入れば別の手）
 * - pending はいつも「最後の手の after」（手が無ければ original）と等しい
 */
data class CropSession(val original: EditGeometry, val pending: EditGeometry, val steps: List<CropStep> = emptyList())

/** 画面を離れる・選び直すときの確かめの種類 */
enum class LeaveQuestion { DISCARD_OR_DRAFT, REPICK }

/** 確かめへの答え。DISCARD_OR_DRAFT には SAVE_DRAFT・DISCARD・CONTINUE、REPICK には DISCARD（選び直す）・CONTINUE（やめる）だけを渡す */
enum class LeaveChoice { SAVE_DRAFT, DISCARD, CONTINUE }

/** 下書きと編集の途中についての案内（画面は 1 つだけ出し、OK で消す） */
enum class DraftNotice { LIMIT_REACHED, SAVE_FAILED, DRAFT_BROKEN }

/** 編集の操作（純粋な関数）。どれも index の写真だけを変えた新しい一覧を返す。index が範囲外なら一覧をそのまま返す */
object EditingState {
    /** index の写真だけを [transform] で変える。ほかの写真は同じ物のまま */
    private fun updated(photos: List<EditingPhoto>, index: Int, transform: (EditingPhoto) -> EditingPhoto): List<EditingPhoto> {
        if (index !in photos.indices) return photos
        return photos.mapIndexed { i, photo -> if (i == index) transform(photo) else photo }
    }

    /** 1 手。前のフィルターを置き換え、ツール・切り抜き・回転は変えない（2.3・2.4）。同じフィルターなら積まない（6.9） */
    fun selectFilter(photos: List<EditingPhoto>, index: Int, filter: FilterId?): List<EditingPhoto> = updated(photos, index) { p ->
        val after = p.edit.copy(filter = filter)
        p.copy(edit = after, history = p.history.committed(p.edit, after))
    }

    /** 履歴に積まない（積むのは [endSlider]） */
    fun slide(photos: List<EditingPhoto>, index: Int, tool: EditTool, value: Int): List<EditingPhoto> = updated(photos, index) { p ->
        p.copy(edit = p.edit.copy(tools = p.edit.tools.with(tool, value)))
    }

    /** 触れた時の内容 before を 1 手として積む。今の内容と同じなら積まない（6.9） */
    fun endSlider(photos: List<EditingPhoto>, index: Int, before: PhotoEdit): List<EditingPhoto> = updated(photos, index) { p ->
        p.copy(history = p.history.committed(before, p.edit))
    }

    fun undo(photos: List<EditingPhoto>, index: Int): List<EditingPhoto> = updated(photos, index) { p ->
        val (history, previous) = p.history.undone(p.edit) ?: return@updated p
        p.copy(edit = previous, history = history)
    }

    fun redo(photos: List<EditingPhoto>, index: Int): List<EditingPhoto> = updated(photos, index) { p ->
        val (history, next) = p.history.redone(p.edit) ?: return@updated p
        p.copy(edit = next, history = history)
    }

    // トリミング・回転の画面の中（仮の状態 CropSession を作って返す。photos は確定まで変えない）

    /** original = pending = edit.geometry */
    fun beginCrop(edit: PhotoEdit): CropSession = CropSession(original = edit.geometry, pending = edit.geometry)

    /** 枠を動かす。最後の手が枠の変更ならその手を置き換え、そうでなければ（手が無い・回転の後）新しい手として足す */
    fun dragCrop(session: CropSession, start: NormalizedRect, handle: CropMath.Handle, dx: Double, dy: Double): CropSession =
        withCropChange(session, session.pending.copy(crop = CropMath.dragged(start, handle, dx, dy)))

    fun nudgeCrop(session: CropSession, edge: CropMath.Edge, inward: Boolean): CropSession =
        withCropChange(session, session.pending.copy(crop = CropMath.nudged(session.pending.crop, edge, inward)))

    /** pending を回し、回した後の内容を回転の 1 手として steps に足す */
    fun rotateCrop(session: CropSession, clockwise: Boolean): CropSession {
        val after = if (clockwise) session.pending.rotatedClockwise() else session.pending.rotatedCounterClockwise()
        return session.copy(pending = after, steps = session.steps + CropStep(after, isRotation = true))
    }

    private fun withCropChange(session: CropSession, after: EditGeometry): CropSession {
        val last = session.steps.lastOrNull()
        val steps = if (last != null && !last.isRotation) {
            session.steps.dropLast(1) + CropStep(after, isRotation = false)
        } else {
            session.steps + CropStep(after, isRotation = false)
        }
        return session.copy(pending = after, steps = steps)
    }

    /**
     * steps を順に、original→steps[0].after→steps[1].after…と EditHistory.committed で積む（前後が同じ手は積まれない）。
     * 最後に edit.geometry を pending にする
     */
    fun confirmCrop(photos: List<EditingPhoto>, index: Int, session: CropSession): List<EditingPhoto> = updated(photos, index) { p ->
        var history = p.history
        var before = p.edit.copy(geometry = session.original)
        for (step in session.steps) {
            val after = p.edit.copy(geometry = step.after)
            history = history.committed(before, after)
            before = after
        }
        p.copy(edit = p.edit.copy(geometry = session.pending), history = history)
    }

    // 取りやめは関数を持たない：ViewModel が cropSession を null にするだけで、photos は変わっていない（4.5）

    /**
     * 装備のツールだけを装備の順で（1.2・7.2）。edit は使わない（利用者の判断 U9 で「並びに出さない」と決まった。
     * 後で「末尾に出す」に変えるときに、形を変えずに足すための引数）
     */
    fun toolsToShow(loadout: Loadout, edit: PhotoEdit): List<EditTool> = loadout.tools

    /** 1.7 の「変更あり」：どれかの写真に編集が掛かっている・キャプションに文字がある・公開範囲が既定（公開）でない */
    fun hasWork(photos: List<EditingPhoto>, caption: String, visibility: Visibility): Boolean =
        photos.any { !it.edit.isNeutral } || caption.isNotBlank() || visibility != Visibility.PUBLIC
}
