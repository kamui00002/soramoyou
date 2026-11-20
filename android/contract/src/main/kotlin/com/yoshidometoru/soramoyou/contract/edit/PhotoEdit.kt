// ⭐️ 1 枚の写真に掛かっている編集の内容（Kiro android-edit-tools タスク 2.2・K0・design.md:419-427）
package com.yoshidometoru.soramoyou.contract.edit

import com.yoshidometoru.soramoyou.contract.model.FilterId

/** 1 枚の写真に掛かっている編集の内容 */
data class PhotoEdit(
    val filter: FilterId? = null,
    val tools: ToolValues = ToolValues.NONE,
    val geometry: EditGeometry = EditGeometry.NONE,
) {
    /** NONE と等しい */
    val isNeutral: Boolean get() = this == NONE

    companion object {
        val NONE = PhotoEdit()
    }
}
