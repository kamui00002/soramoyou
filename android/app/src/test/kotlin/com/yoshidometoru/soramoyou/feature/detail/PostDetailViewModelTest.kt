// ⭐️ 投稿詳細の画面の状態の単体テスト（タスク 10.2・24・29.2・要件 5.1・5.2・5.4・5.5・10.11・11.1・11.4・11.7・16.2・16.3）
package com.yoshidometoru.soramoyou.feature.detail

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.repository.BlockedUsers
import com.yoshidometoru.soramoyou.data.repository.PostDeleter
import com.yoshidometoru.soramoyou.data.repository.PostLookup
import com.yoshidometoru.soramoyou.data.repository.PostReadRepository
import com.yoshidometoru.soramoyou.feature.FakeWriteGate
import com.yoshidometoru.soramoyou.feature.RecordingFeatureAnalytics
import com.yoshidometoru.soramoyou.feature.feed.FakeAuthorProfileCache
import com.yoshidometoru.soramoyou.feature.feed.FakeLikeStateStore
import com.yoshidometoru.soramoyou.feature.feed.post
import com.yoshidometoru.soramoyou.feature.immediateScope
import com.yoshidometoru.soramoyou.feature.moderation.FakeModerationRepository
import com.yoshidometoru.soramoyou.feature.moderation.ModerationAction
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** 結果を外から渡すまで待つ、投稿 1 件の取得の偽物。 */
class FakePostReadRepository : PostReadRepository {
    val calls = mutableListOf<PostId>()
    val pending = mutableListOf<CompletableDeferred<AppResult<PostLookup>>>()
    override suspend fun fetch(postId: PostId): AppResult<PostLookup> {
        calls += postId
        return CompletableDeferred<AppResult<PostLookup>>().also { pending += it }.await()
    }
}

/** 結果を外から渡すまで待つ、自分の投稿の削除の偽物。 */
class FakePostDeleter : PostDeleter {
    val calls = mutableListOf<PostId>()
    val pending = mutableListOf<CompletableDeferred<AppResult<Unit>>>()
    override suspend fun delete(postId: PostId): AppResult<Unit> {
        calls += postId
        return CompletableDeferred<AppResult<Unit>>().also { pending += it }.await()
    }
}

class PostDetailViewModelTest {

    private val repository = FakePostReadRepository()
    private val authors = FakeAuthorProfileCache()
    private val analytics = RecordingFeatureAnalytics()
    private val online = MutableStateFlow(true)

    private val likes = FakeLikeStateStore()
    private var gate = FakeWriteGate(setOf(WriteCapability.LIKE, WriteCapability.POST_DELETE))
    private val deleter = FakePostDeleter()
    private var signedIn: Uid? = Uid("me")
    private val moderationRepository = FakeModerationRepository()
    private val blockedUsers = BlockedUsers()

    private fun viewModel() =
        PostDetailViewModel(
            PostId("P1"),
            repository,
            authors,
            likes,
            deleter,
            gate,
            analytics,
            online,
            { signedIn },
            immediateScope(),
            moderationRepository,
            blockedUsers,
        )

    /** 自分の投稿（P1）を読めた状態の ViewModel。 */
    private fun loadedOwnPost(): PostDetailViewModel = viewModel().also {
        repository.pending.last().complete(AppResult.Ok(PostLookup.Found(post("P1", "me"))))
    }

    @Test
    fun `作った時点で投稿を読み、読めたら表示して投稿者の名前を取りに行く`() {
        val vm = viewModel()
        assertEquals(listOf(PostId("P1")), repository.calls)
        assertEquals(PostDetailUiState.Loading, vm.state.value)

        repository.pending.last().complete(AppResult.Ok(PostLookup.Found(post("P1", "alice"))))

        assertEquals(PostDetailUiState.Loaded(post("P1", "alice")), vm.state.value)
        assertEquals(listOf(setOf(Uid("alice"))), authors.ensureCalls)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `削除済み・権限なしは、表示できない旨にして記録しない`() {
        listOf(PostLookup.Deleted, PostLookup.NoPermission).forEach { lookup ->
            val vm = viewModel()
            repository.pending.last().complete(AppResult.Ok(lookup))
            assertEquals(PostDetailUiState.Unavailable, vm.state.value, lookup.toString())
        }
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `変換できない投稿は、表示できない旨にして、投稿IDを含めずに理由だけを記録する`() {
        val vm = viewModel()
        repository.pending.last().complete(AppResult.Ok(PostLookup.Unreadable("missingRequiredFields")))

        assertEquals(PostDetailUiState.Unavailable, vm.state.value)
        val (error, context) = analytics.errors.single()
        assertEquals(AppError.Unknown("PostDecode.missingRequiredFields"), error)
        assertEquals("PostDetailViewModel.load", context)
        assertFalse("P1" in error.toString())
    }

    @Test
    fun `取得に失敗したら、失敗した時点の接続とともに出して記録し、再試行で読み直す`() {
        val vm = viewModel()
        online.value = false
        repository.pending.last().complete(AppResult.Err(AppError.Network))

        assertEquals(PostDetailUiState.Failed(AppError.Network, failedWhileOffline = true), vm.state.value)
        assertEquals(listOf<Pair<AppError, String>>(AppError.Network to "PostDetailViewModel.load"), analytics.errors)

        vm.retry()
        assertEquals(PostDetailUiState.Loading, vm.state.value)
        assertEquals(2, repository.calls.size)
        repository.pending.last().complete(AppResult.Ok(PostLookup.Found(post("P1"))))
        assertTrue(vm.state.value is PostDetailUiState.Loaded)
    }

    @Test
    fun `読み込み中の再試行は、二重に読まない`() {
        val vm = viewModel()
        vm.retry()
        assertEquals(1, repository.calls.size)
    }

    @Test
    fun `日時はiOSの日本語の短い書式と同じ形で、指定のタイムゾーンで出す`() {
        val instant = Instant.parse("2026-10-04T23:42:00Z")
        assertEquals("2026年10月5日 8:42", detailDateText(instant, ZoneId.of("Asia/Tokyo")))
        assertEquals("2026年10月4日 23:42", detailDateText(instant, ZoneId.of("UTC")))
    }

    // ── いいね（タスク 18.4・要件 9.2・9.7）──

    @Test
    fun `読めた投稿だけ、その1件のいいね済みを確かめる`() {
        val found = viewModel()
        repository.pending.last().complete(AppResult.Ok(PostLookup.Found(post("P1"))))
        assertEquals(listOf(listOf(PostId("P1"))), likes.refreshCalls)

        // 表示できない・読めなかった投稿では確かめない
        viewModel()
        repository.pending.last().complete(AppResult.Ok(PostLookup.Deleted))
        viewModel()
        repository.pending.last().complete(AppResult.Err(AppError.Network))
        assertEquals(1, likes.refreshCalls.size)
        assertTrue(found.state.value is PostDetailUiState.Loaded)
    }

    @Test
    fun `いいねを押すと、表示している投稿と、その投稿のいいね数を渡す。表示できる投稿が無ければ何もしない`() {
        val vm = viewModel()
        vm.toggleLike()
        assertTrue(likes.toggleCalls.isEmpty(), "読み込み中に押せている")

        repository.pending.last().complete(AppResult.Ok(PostLookup.Found(post("P1").copy(likesCount = 7))))
        vm.toggleLike()
        assertEquals(listOf(PostId("P1") to 7L), likes.toggleCalls)
    }

    @Test
    fun `いいねの書き込みが有効なビルドでだけ、いいねのボタンを押せる`() {
        assertTrue(viewModel().canLike)
        gate = FakeWriteGate(WriteCapability.entries.toSet() - WriteCapability.LIKE)
        assertFalse(viewModel().canLike)
    }

    // ── 自分の投稿の削除（要件 10.11・タスク 24）──

    @Test
    fun `自分の投稿で削除が有効なビルドだけ削除を出し、他人の投稿・無効なビルド・未ログイン・読めない投稿では出さない`() {
        assertTrue(loadedOwnPost().deleteState.value.available)

        val others = viewModel()
        assertFalse(others.deleteState.value.available, "読み込み中は出さない")
        repository.pending.last().complete(AppResult.Ok(PostLookup.Found(post("P1", "alice"))))
        assertFalse(others.deleteState.value.available, "他人の投稿")

        val unavailable = viewModel()
        repository.pending.last().complete(AppResult.Ok(PostLookup.NoPermission))
        assertFalse(unavailable.deleteState.value.available, "表示できない投稿")

        gate = FakeWriteGate(setOf(WriteCapability.LIKE))
        assertFalse(loadedOwnPost().deleteState.value.available, "削除の書き込みが無効なビルド")

        gate = FakeWriteGate(setOf(WriteCapability.LIKE, WriteCapability.POST_DELETE))
        signedIn = null
        assertFalse(loadedOwnPost().deleteState.value.available, "未ログイン")
    }

    @Test
    fun `削除を押すと確認を出し、キャンセルで閉じて何も消さない`() {
        val vm = loadedOwnPost()

        vm.requestDelete()
        assertTrue(vm.deleteState.value.confirming)

        vm.cancelDelete()
        assertFalse(vm.deleteState.value.confirming)
        assertEquals(emptyList(), deleter.calls)
    }

    @Test
    fun `オフラインの間と、削除を出していない投稿では、押しても確認を出さない`() {
        val vm = loadedOwnPost()
        online.value = false
        vm.requestDelete()
        assertFalse(vm.deleteState.value.confirming)

        online.value = true
        val others = viewModel()
        repository.pending.last().complete(AppResult.Ok(PostLookup.Found(post("P1", "alice"))))
        others.requestDelete()
        assertFalse(others.deleteState.value.confirming)
    }

    @Test
    fun `確認で削除を押すと閉じて削除中にし、成功したら削除済みにする。二度押しは1回だけ消す`() {
        val vm = loadedOwnPost()
        vm.requestDelete()

        vm.confirmDelete()
        vm.confirmDelete()

        assertEquals(PostDeleteUiState(available = true, deleting = true), vm.deleteState.value)
        assertEquals(listOf(PostId("P1")), deleter.calls)
        vm.requestDelete()
        assertFalse(vm.deleteState.value.confirming, "削除中は確認を出し直さない")

        deleter.pending.single().complete(AppResult.Ok(Unit))

        assertEquals(PostDeleteUiState(available = true, deleted = true), vm.deleteState.value)
        vm.requestDelete()
        assertFalse(vm.deleteState.value.confirming, "削除の後は確認を出さない")
    }

    @Test
    fun `確認を出していなければ、削除を始めない`() {
        val vm = loadedOwnPost()
        vm.confirmDelete()
        assertEquals(emptyList(), deleter.calls)
        assertFalse(vm.deleteState.value.deleting)
    }

    @Test
    fun `失敗したら理由を持ち、記録し直さず、閉じたら消え、もう一度押せる`() {
        val vm = loadedOwnPost()
        vm.requestDelete()
        vm.confirmDelete()

        deleter.pending.single().complete(AppResult.Err(AppError.Network))

        assertEquals(PostDeleteUiState(available = true, error = AppError.Network), vm.deleteState.value)
        assertEquals(emptyList(), analytics.errors, "記録は PostDeleter が済ませる")

        vm.dismissDeleteError()
        assertEquals(PostDeleteUiState(available = true), vm.deleteState.value)
        vm.requestDelete()
        assertTrue(vm.deleteState.value.confirming)
    }

    // ── 通報・ブロック（タスク 29.2・要件 11.1・11.4・11.7）──

    @Test
    fun `読めた投稿が他人の投稿なら通報とブロックを出し、自分の投稿なら出さない`() {
        gate = FakeWriteGate(setOf(WriteCapability.REPORT, WriteCapability.BLOCK, WriteCapability.POST_DELETE))
        val others = viewModel()
        assertEquals(emptySet(), others.moderationActions.value, "読み込み中は出さない")
        repository.pending.last().complete(AppResult.Ok(PostLookup.Found(post("P1", "alice"))))
        assertEquals(setOf(ModerationAction.REPORT, ModerationAction.BLOCK), others.moderationActions.value)

        val own = loadedOwnPost()
        assertEquals(emptySet(), own.moderationActions.value)
        assertTrue(own.deleteState.value.available, "自分の投稿には削除を出す")
    }

    @Test
    fun `表示できない・読めなかった投稿には、通報もブロックも出さない`() {
        gate = FakeWriteGate(setOf(WriteCapability.REPORT, WriteCapability.BLOCK))
        val unavailable = viewModel()
        repository.pending.last().complete(AppResult.Ok(PostLookup.Deleted))
        val failed = viewModel()
        repository.pending.last().complete(AppResult.Err(AppError.Network))

        assertEquals(emptySet(), unavailable.moderationActions.value)
        assertEquals(emptySet(), failed.moderationActions.value)
    }

    @Test
    fun `ブロックできたら投稿者を知らせ、詳細を閉じる合図を出す`() {
        gate = FakeWriteGate(setOf(WriteCapability.REPORT, WriteCapability.BLOCK))
        val notified = mutableListOf<Uid>()
        blockedUsers.events.onEach { notified += it }.launchIn(immediateScope())
        val vm = viewModel()
        val alice = post("P1", "alice")
        repository.pending.last().complete(AppResult.Ok(PostLookup.Found(alice)))

        vm.moderation.requestBlock(alice)
        vm.moderation.confirmBlock()
        moderationRepository.completeLast(AppResult.Ok(Unit))

        assertEquals(Uid("alice"), vm.moderation.state.value.blockedAuthor)
        assertEquals(listOf(Uid("alice")), notified)
        assertEquals(emptyList(), analytics.errors)
    }
}
