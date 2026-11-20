// ⭐️ 通報・ブロックの画面の単体テストで共有する偽物（タスク 29.2）
package com.yoshidometoru.soramoyou.feature.moderation

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.model.ReportReason
import com.yoshidometoru.soramoyou.data.model.BlockedUserView
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.repository.ModerationRepository
import kotlinx.coroutines.CompletableDeferred

/**
 * 結果を外から渡すまで待つ ModerationRepository の偽物。呼ばれた順に入力を残す。
 * 書き込み（通報・ブロック・解除）は呼ばれた順に [pending] へ待ちを足し、テストが [completeLast] で結果を渡すまで待つ。
 * 一覧の取得（blockedProfiles）は [profilesPending] へ足す。記録（分析）はしない（本物の記録は DefaultModerationRepositoryTest が確かめる）。
 */
class FakeModerationRepository : ModerationRepository {
    val reportCalls = mutableListOf<Pair<PostView, ReportReason>>()
    val blockCalls = mutableListOf<Uid>()
    val unblockCalls = mutableListOf<Uid>()
    val pending = mutableListOf<CompletableDeferred<AppResult<Unit>>>()
    val profilesPending = mutableListOf<CompletableDeferred<AppResult<List<BlockedUserView>>>>()

    override suspend fun report(post: PostView, reason: ReportReason): AppResult<Unit> {
        reportCalls += post to reason
        return waitForResult()
    }

    override suspend fun block(uid: Uid): AppResult<Unit> {
        blockCalls += uid
        return waitForResult()
    }

    override suspend fun unblock(uid: Uid): AppResult<Unit> {
        unblockCalls += uid
        return waitForResult()
    }

    override suspend fun blockedProfiles(): AppResult<List<BlockedUserView>> =
        CompletableDeferred<AppResult<List<BlockedUserView>>>().also { profilesPending += it }.await()

    /** 待っている最後の書き込みに [result] を渡す。 */
    fun completeLast(result: AppResult<Unit>) {
        pending.last().complete(result)
    }

    private suspend fun waitForResult(): AppResult<Unit> = CompletableDeferred<AppResult<Unit>>().also { pending += it }.await()
}
