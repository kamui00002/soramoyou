// ⭐️ フィードバックの画面の単体テストで共有する偽物（タスク 30）
package com.yoshidometoru.soramoyou.feature.feedback

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.document.FeedbackInput
import com.yoshidometoru.soramoyou.data.repository.FeedbackRepository
import kotlinx.coroutines.CompletableDeferred

/**
 * 結果を外から渡すまで待つ FeedbackRepository の偽物。呼ばれた順に入力を残し、[pending] へ待ちを足す。
 * テストが [completeLast] で結果を渡すまで待つ。記録（分析）はしない（本物の記録は DefaultFeedbackRepositoryTest が確かめる）。
 */
class FakeFeedbackRepository : FeedbackRepository {
    val submitCalls = mutableListOf<FeedbackInput>()
    val pending = mutableListOf<CompletableDeferred<AppResult<Unit>>>()

    override suspend fun submit(input: FeedbackInput): AppResult<Unit> {
        submitCalls += input
        return CompletableDeferred<AppResult<Unit>>().also { pending += it }.await()
    }

    /** 待っている最後の送信に [result] を渡す。 */
    fun completeLast(result: AppResult<Unit>) {
        pending.last().complete(result)
    }
}
