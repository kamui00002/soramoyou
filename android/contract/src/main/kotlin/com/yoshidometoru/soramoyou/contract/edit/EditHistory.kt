// ⭐️ 編集の履歴（元に戻す・やり直し）（Kiro android-edit-tools タスク 2.2・K0・design.md:429-437）
package com.yoshidometoru.soramoyou.contract.edit

/**
 * 履歴。積むのは「変える前の内容」。上限は iOS と同じ 50（EditHistoryManager.swift:45）。
 * 関数の中身はタスク 5（C2）で入れた。canUndo・canRedo は一覧が空かを見るだけの値で、K0 から本物。
 */
data class EditHistory(val undo: List<PhotoEdit> = emptyList(), val redo: List<PhotoEdit> = emptyList()) {
    val canUndo: Boolean get() = undo.isNotEmpty()
    val canRedo: Boolean get() = redo.isNotEmpty()

    /**
     * before == after なら this（要件 6.9。何も変わらない操作は 1 手にしない）。
     * 違えば before（変える前）を undo の末尾に積み、redo を空にする（分岐履歴は持たない）。
     * 積んで [MAX_STEPS] を超えたら、古いものから捨てる。
     * 写した元：iOS EditHistoryManager.swift:push（54-61 行付近。append → 超えたら removeFirst → redo 全消去）。
     * iOS の push は同じ内容でも積むが、本仕様は 6.9 で積まない。
     */
    fun committed(before: PhotoEdit, after: PhotoEdit): EditHistory {
        if (before == after) return this
        return EditHistory(undo = (undo + before).takeLast(MAX_STEPS), redo = emptyList())
    }

    /**
     * 1 手戻す。戻せなければ null。undo の末尾を取り出して戻り先とし、current を redo の末尾に積む。
     * 写した元：iOS EditHistoryManager.swift:undo(current:)（popLast → redo に current を append）。
     */
    fun undone(current: PhotoEdit): Pair<EditHistory, PhotoEdit>? {
        val previous = undo.lastOrNull() ?: return null
        return EditHistory(undo = undo.dropLast(1), redo = redo + current) to previous
    }

    /**
     * 1 手やり直す。やり直せなければ null。redo の末尾を取り出し、current を undo の末尾に積む。
     * 写した元：iOS EditHistoryManager.swift:redo(current:)（popLast → undo に current を append）。
     */
    fun redone(current: PhotoEdit): Pair<EditHistory, PhotoEdit>? {
        val next = redo.lastOrNull() ?: return null
        return EditHistory(undo = undo + current, redo = redo.dropLast(1)) to next
    }

    companion object {
        const val MAX_STEPS = 50
        val EMPTY = EditHistory()
    }
}
