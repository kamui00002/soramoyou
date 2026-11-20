// ⭐️ 編集の途中の保存（EditSessionStore）の偽物。メモリの中だけで、呼ばれた引数を控え、結果をテストが決める（Kiro android-edit-tools タスク 2.4・K0・design.md:777）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.edit.EditWorkDocument
import kotlinx.coroutines.CompletableDeferred

/**
 * 端末のファイルに触らない偽物。保存した文書を読み戻す仕組みは持たない（[load] が返すものは [loadResults] でテストが決める）。
 *
 * - 呼ばれた順と引数を [calls] に控える。[clear]（丸ごと）と [clearSession]（印つき）は別の記録になる（後始末の取り違えを見分けるため）
 * - [save] は [saveResult] を返す（既定は成功）。[load] は [loadResults] の、渡された uid の値を返す（無ければ [SessionLoad.None]）
 * - [saveGate]・[loadGate] を置くと、その呼び出しは記録した後、ゲートが完了するまで戻らない（途中の状態を見るため）。
 *   ゲートは 1 回きりで、完了させると後の呼び出しも待たずに通る
 */
class FakeEditSessionStore : EditSessionStore {

    /** 呼ばれた 1 回分。 */
    sealed interface Call {
        data class Save(val uid: Uid, val document: EditWorkDocument) : Call
        data class Load(val uid: Uid) : Call
        data class Clear(val uid: Uid) : Call
        data class ClearSession(val uid: Uid, val sessionId: String) : Call
    }

    val calls = mutableListOf<Call>()
    var saveResult: AppResult<Unit> = AppResult.Ok(Unit)
    /** uid ごとの [load] の結果。無い uid は [SessionLoad.None]。 */
    val loadResults = mutableMapOf<Uid, SessionLoad>()
    var saveGate: CompletableDeferred<Unit>? = null
    var loadGate: CompletableDeferred<Unit>? = null

    override suspend fun save(uid: Uid, document: EditWorkDocument): AppResult<Unit> {
        calls += Call.Save(uid, document)
        saveGate?.await()
        return saveResult
    }

    override suspend fun load(uid: Uid): SessionLoad {
        calls += Call.Load(uid)
        loadGate?.await()
        return loadResults[uid] ?: SessionLoad.None
    }

    override suspend fun clear(uid: Uid) {
        calls += Call.Clear(uid)
    }

    override suspend fun clearSession(uid: Uid, sessionId: String) {
        calls += Call.ClearSession(uid, sessionId)
    }
}
