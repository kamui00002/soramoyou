// ⭐️ プロフィールの画面の状態の単体テストで共有する偽物（タスク 15.2）
package com.yoshidometoru.soramoyou.feature.profile

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.model.OwnProfile
import com.yoshidometoru.soramoyou.data.model.PublicProfileView
import com.yoshidometoru.soramoyou.data.remote.read.RawCursor
import com.yoshidometoru.soramoyou.data.remote.write.WriteGate
import com.yoshidometoru.soramoyou.data.repository.AccountDocumentRepairer
import com.yoshidometoru.soramoyou.data.repository.FeedPage
import com.yoshidometoru.soramoyou.data.repository.ProfileEdit
import com.yoshidometoru.soramoyou.data.repository.ProfileEditor
import com.yoshidometoru.soramoyou.data.repository.ProfileRepository
import com.yoshidometoru.soramoyou.data.repository.ProfileSaveStage
import com.yoshidometoru.soramoyou.data.repository.RepairOutcome
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow

/** 結果を外から渡すまで待つ取得の偽物。呼ばれた入力を [calls] に残す（FakeFeedRepository と同じ作り）。 */
class PendingCalls<I, R> {
    val calls = mutableListOf<I>()
    val queued = ArrayDeque<R>()
    val pending = mutableListOf<CompletableDeferred<R>>()

    suspend fun call(input: I): R {
        calls += input
        queued.removeFirstOrNull()?.let { return it }
        val waiting = CompletableDeferred<R>()
        pending += waiting
        return waiting.await()
    }

    /** 待っている最後の取得に [result] を渡す。 */
    fun completeLast(result: R) {
        pending.last().complete(result)
    }
}

/**
 * ProfileRepository の偽物。
 * [observeOwn] は集め始めるたびに新しい流れを [ownFlows] に足す。テストはそこへ結果を流し、`subscriptionCount` で監視が続いているかを見る。
 */
class FakeProfileRepository : ProfileRepository {
    val ownFlows = mutableListOf<MutableSharedFlow<AppResult<OwnProfile>>>()
    val ownPages = PendingCalls<RawCursor?, AppResult<FeedPage>>()
    val publicPages = PendingCalls<Pair<Uid, RawCursor?>, AppResult<FeedPage>>()
    val publicProfiles = PendingCalls<Uid, AppResult<PublicProfileView>>()

    override fun observeOwn(): Flow<AppResult<OwnProfile>> = flow {
        val source = MutableSharedFlow<AppResult<OwnProfile>>(extraBufferCapacity = 16)
        ownFlows += source
        emitAll(source)
    }

    /** いちばん新しい監視に [result] を流す。 */
    fun emitOwn(result: AppResult<OwnProfile>) {
        check(ownFlows.last().tryEmit(result))
    }

    override suspend fun fetchPublic(uid: Uid): AppResult<PublicProfileView> = publicProfiles.call(uid)

    override suspend fun ownPostsPage(after: RawCursor?): AppResult<FeedPage> = ownPages.call(after)

    override suspend fun userPublicPostsPage(uid: Uid, after: RawCursor?): AppResult<FeedPage> = publicPages.call(uid to after)
}

/** 補完の偽物。呼ばれた回数を残し、[result] を返す。 */
class FakeAccountDocumentRepairer(var result: AppResult<RepairOutcome> = AppResult.Ok(RepairOutcome.ALREADY_PRESENT)) : AccountDocumentRepairer {
    var calls = 0
    override suspend fun ensureAccountDocuments(): AppResult<RepairOutcome> {
        calls++
        return result
    }
}

/**
 * 保存の偽物。呼ばれた入力といまのプロフィールを [saves] の calls に残し、テストが結果を渡すまで待つ（タスク 16.3）。
 * 保存の段は [state] にテストが入れる（前に開いた画面で始めた保存を模す。全体レビュー 4 回目 Q04）。save は段を変えない。
 */
class FakeProfileEditor : ProfileEditor {
    override val state = MutableStateFlow(ProfileSaveStage.IDLE)
    val saves = PendingCalls<Pair<ProfileEdit, OwnProfile>, AppResult<Unit>>()
    override suspend fun save(edit: ProfileEdit, current: OwnProfile): AppResult<Unit> = saves.call(edit to current)
}

/** 有効な書き込みを決めて渡す WriteGate の偽物。 */
class FakeWriteGate(override val enabled: Set<WriteCapability>) : WriteGate

/** uid が [uid] の自分のプロフィール。 */
fun ownProfile(uid: String = "me", name: String? = "そら", bio: String? = "空が好き", postsCount: Long = 3): OwnProfile =
    OwnProfile(uid = Uid(uid), displayName = name, photoUrl = "https://example.com/$uid.jpg", bio = bio, postsCount = postsCount)
