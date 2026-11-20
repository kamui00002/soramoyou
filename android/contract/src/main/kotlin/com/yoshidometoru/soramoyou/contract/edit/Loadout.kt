// ⭐️ 編集ツールの装備（並びと選択）（Kiro android-edit-tools タスク 2.2・K0・design.md:518-524）
package com.yoshidometoru.soramoyou.contract.edit

data class Loadout(val tools: List<EditTool>) {
    /** 1 個以上 */
    val canSave: Boolean get() = tools.isNotEmpty()

    companion object {
        val DEFAULT = Loadout(EditTool.entries)

        /**
         * 知らない名前と重複を捨てる。空なら DEFAULT。
         *
         * 並びは渡された順（利用者が決めた装備の順）を保つ。重複は先に出たものを残す。
         * 名前は完全一致（[EditTool.fromRaw]）。前後の空白は取らない（空白つきは知らない名前として捨てる）。
         * 捨てた結果が空になる（全部知らない名前だった）ときも DEFAULT に戻す。
         */
        fun sanitized(raws: List<String>): Loadout {
            val tools = raws.mapNotNull { EditTool.fromRaw(it) }.distinct()
            return if (tools.isEmpty()) DEFAULT else Loadout(tools)
        }
    }
}
