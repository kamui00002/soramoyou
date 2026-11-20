// ⭐️ 端末の下書き（LocalDraftRepository）の偽物。メモリの中だけで、呼ばれた引数を控え、結果をテストが決める（Kiro android-edit-tools タスク 2.4・K0・design.md:777）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.edit.EditWorkDocument
import kotlinx.coroutines.CompletableDeferred

/**
 * 端末のファイルに触らない偽物。件数の上限や上書きの決まりは持たない（[save] の結果は [saveResult] でテストが決める）。
 *
 * - 呼ばれた順と引数を [calls] に控える
 * - [list] は [summaries] の、渡された uid の一覧を返す（無ければ空。利用者ごとに分かれることを見るため uid で引く）
 * - [save] は [saveResult]（既定は `Saved(DraftId("DRAFT-1"))`）、[open] は [openResults] の、渡された ID の値（無ければ
 *   [DraftOpenResult.Broken]）、[delete] は [deleteResult]（既定は成功）を返す
 * - [saveGate]・[openGate] を置くと、その呼び出しは記録した後、ゲートが完了するまで戻らない（保存中・読み込み中の状態を見るため）。
 *   ゲートは 1 回きりで、完了させると後の呼び出しも待たずに通る
 * - [Call.Save] の見本の JPEG（`thumbnailJpeg`）は配列なので、記録どうしの等しさは中身でなく同じ配列かで決まる。中身は
 *   `assertContentEquals` で比べる
 */
class FakeLocalDraftRepository : LocalDraftRepository {

    /** 呼ばれた 1 回分。 */
    sealed interface Call {
        data class ListDrafts(val uid: Uid) : Call
        data class Save(val uid: Uid, val document: EditWorkDocument, val thumbnailJpeg: ByteArray?) : Call
        data class Open(val uid: Uid, val id: DraftId) : Call
        data class Delete(val uid: Uid, val id: DraftId) : Call
    }

    val calls = mutableListOf<Call>()
    /** uid ごとの [list] の結果（保存した日時の新しい順に並べて入れる）。無い uid は空。 */
    val summaries = mutableMapOf<Uid, List<LocalDraftSummary>>()
    var saveResult: DraftSaveResult = DraftSaveResult.Saved(DraftId("DRAFT-1"))
    /** 下書きの ID ごとの [open] の結果。無い ID は [DraftOpenResult.Broken]。 */
    val openResults = mutableMapOf<DraftId, DraftOpenResult>()
    var deleteResult: AppResult<Unit> = AppResult.Ok(Unit)
    var saveGate: CompletableDeferred<Unit>? = null
    var openGate: CompletableDeferred<Unit>? = null

    override suspend fun list(uid: Uid): List<LocalDraftSummary> {
        calls += Call.ListDrafts(uid)
        return summaries[uid] ?: emptyList()
    }

    override suspend fun save(uid: Uid, document: EditWorkDocument, thumbnailJpeg: ByteArray?): DraftSaveResult {
        calls += Call.Save(uid, document, thumbnailJpeg)
        saveGate?.await()
        return saveResult
    }

    override suspend fun open(uid: Uid, id: DraftId): DraftOpenResult {
        calls += Call.Open(uid, id)
        openGate?.await()
        return openResults[id] ?: DraftOpenResult.Broken
    }

    override suspend fun delete(uid: Uid, id: DraftId): AppResult<Unit> {
        calls += Call.Delete(uid, id)
        return deleteResult
    }
}
