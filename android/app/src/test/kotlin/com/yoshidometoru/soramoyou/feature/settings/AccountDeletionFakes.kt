// ⭐️ アカウントの削除の画面の単体テストで共有する偽物（タスク 31.5）
package com.yoshidometoru.soramoyou.feature.settings

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.data.repository.AccountDeletionService
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * 結果を外から渡すまで待つ AccountDeletionService の偽物（FakeFeedbackRepository と同じ形）。呼ばれた順にパスワードを残し、
 * [pending] へ待ちを足す。テストが [completeLast] で結果を渡すまで待つ。段階は [stageFlow] にテストが直接入れる。
 * 記録（分析）はしない（本物の記録は DefaultAccountDeletionServiceTest が確かめる）。
 */
class FakeAccountDeletionService : AccountDeletionService {
    val stageFlow = MutableStateFlow<DeletionStage?>(null)
    override val stage: StateFlow<DeletionStage?> = stageFlow

    val deleteCalls = mutableListOf<String>()
    val pending = mutableListOf<CompletableDeferred<AppResult<Unit>>>()

    override suspend fun delete(password: String): AppResult<Unit> {
        deleteCalls += password
        return CompletableDeferred<AppResult<Unit>>().also { pending += it }.await()
    }

    /** 待っている最後の削除に [result] を渡す。 */
    fun completeLast(result: AppResult<Unit>) {
        pending.last().complete(result)
    }
}
