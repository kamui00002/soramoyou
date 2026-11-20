// ⭐️ 編集ツールの装備の保存（LoadoutStore）の偽物。メモリの中だけで、呼ばれた引数を控え、結果をテストが決める（Kiro android-edit-tools タスク 2.4・K0・design.md:777）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.edit.Loadout
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * 端末のファイルに触らない偽物。今の装備は [loadoutFlow] にあり、テストが直接動かせる（読み込みが終わった、などを表す）。
 *
 * - [save] は渡された装備を [saveCalls] に控え、[saveResult] を返す（既定は成功）。成功を返すときだけ [loadoutFlow] を渡された装備にする
 *   （本物も保存できた装備を流す）。失敗を返すときは [loadoutFlow] を変えない
 * - `canSave` で止めるのは呼ぶ側の役目なので、この偽物は空の装備でもそのまま受け取る（呼ぶ側が止めたかは [saveCalls] で見る）
 */
class FakeLoadoutStore(initial: Loadout = Loadout.DEFAULT) : LoadoutStore {
    val loadoutFlow = MutableStateFlow(initial)
    override val loadout: StateFlow<Loadout> = loadoutFlow

    val saveCalls = mutableListOf<Loadout>()
    var saveResult: AppResult<Unit> = AppResult.Ok(Unit)

    override suspend fun save(loadout: Loadout): AppResult<Unit> {
        saveCalls += loadout
        val result = saveResult
        if (result is AppResult.Ok) loadoutFlow.value = loadout
        return result
    }
}
