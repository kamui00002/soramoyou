// ⭐️ ブロック中のユーザーの画面の状態の単体テスト（タスク 29.2・要件 11.5・11.6・16.2・16.3）
package com.yoshidometoru.soramoyou.feature.settings

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.BlockedUserView
import com.yoshidometoru.soramoyou.data.repository.ModerationRepository
import com.yoshidometoru.soramoyou.feature.immediateScope
import com.yoshidometoru.soramoyou.feature.moderation.FakeModerationRepository
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * 一覧の取得（読み込み中・一覧・空・失敗と再試行）と、解除（成功で一覧から除く・失敗で残して出す）を確かめる。
 * 一覧の取得の失敗は BlockListRepository が、解除の失敗は ModerationRepository が記録済みなので、この ViewModel は記録の窓口を持たない。
 */
class BlockListViewModelTest {

    private val repository = FakeModerationRepository()
    private val online = MutableStateFlow(true)

    private fun viewModel() = BlockListViewModel(repository, online, immediateScope())

    private val alice = BlockedUserView(Uid("alice"), AuthorDisplay.Named("アリス", "https://example.com/a.jpg"))
    private val bob = BlockedUserView(Uid("bob"), AuthorDisplay.Fallback(null))

    /** 2 人をブロック中の一覧を読めた状態。 */
    private fun loaded(): BlockListViewModel = viewModel().also {
        repository.profilesPending.last().complete(AppResult.Ok(listOf(alice, bob)))
    }

    // ── 一覧の取得 ──

    @Test
    fun `作った時点でブロック中のユーザーを読み、読めたらブロックした順の一覧を出す`() {
        val vm = viewModel()
        assertEquals(BlockListContent.Loading, vm.state.value.content)
        assertEquals(1, repository.profilesPending.size)

        repository.profilesPending.last().complete(AppResult.Ok(listOf(alice, bob)))

        assertEquals(BlockListContent.Loaded(listOf(alice, bob)), vm.state.value.content)
    }

    @Test
    fun `ブロック中のユーザーがいなければ、空の一覧にする`() {
        val vm = viewModel()
        repository.profilesPending.last().complete(AppResult.Ok(emptyList()))

        assertEquals(BlockListContent.Loaded(emptyList()), vm.state.value.content)
    }

    @Test
    fun `読めなければ、失敗した時点の接続とともに失敗を出し、再試行で読み直す`() {
        val vm = viewModel()
        online.value = false
        repository.profilesPending.last().complete(AppResult.Err(AppError.Network))
        assertEquals(BlockListContent.Failed(AppError.Network, failedWhileOffline = true), vm.state.value.content)

        online.value = true
        vm.retry()
        assertEquals(BlockListContent.Loading, vm.state.value.content)
        assertEquals(2, repository.profilesPending.size)

        repository.profilesPending.last().complete(AppResult.Ok(listOf(bob)))
        assertEquals(BlockListContent.Loaded(listOf(bob)), vm.state.value.content)
    }

    @Test
    fun `読み込み中の再試行は、二重に読まない`() {
        val vm = viewModel()
        vm.retry()
        assertEquals(1, repository.profilesPending.size)
    }

    // ── 解除（要件 11.5・11.6）──

    @Test
    fun `解除を押すと、そのユーザーの解除を送り、届いたら一覧から除く`() {
        val vm = loaded()
        vm.unblock(Uid("alice"))
        assertEquals(listOf(Uid("alice")), repository.unblockCalls)
        assertEquals(setOf(Uid("alice")), vm.state.value.unblocking)

        repository.completeLast(AppResult.Ok(Unit))

        assertEquals(BlockListContent.Loaded(listOf(bob)), vm.state.value.content)
        assertEquals(emptySet(), vm.state.value.unblocking)
        assertNull(vm.state.value.unblockError)
    }

    @Test
    fun `解除の送信中は、同じユーザーの解除を二重に送らない`() {
        val vm = loaded()
        vm.unblock(Uid("alice"))
        vm.unblock(Uid("alice"))

        assertEquals(listOf(Uid("alice")), repository.unblockCalls)
    }

    @Test
    fun `解除に失敗したら一覧に残して失敗を出し、閉じたら消す`() {
        val vm = loaded()
        vm.unblock(Uid("bob"))
        repository.completeLast(AppResult.Err(AppError.Network))

        assertEquals(BlockListContent.Loaded(listOf(alice, bob)), vm.state.value.content)
        assertEquals(emptySet(), vm.state.value.unblocking)
        assertEquals(AppError.Network, vm.state.value.unblockError)

        vm.dismissUnblockError()
        assertNull(vm.state.value.unblockError)
    }

    @Test
    fun `解除の送信中に画面を離れて取り消されても、解除は最後まで待ち、ModerationRepositoryの失敗の記録が走る`() {
        // 解除を押した直後に戻る操作で画面を離れると、この ViewModel の scope は取り消される。本物の ModerationRepository は失敗を
        // unblock の中で（書き込みの await の後に）記録するので、偽物を包んで同じ位置で記録させる（DefaultLikeStateStoreTest の R16 と同じ）。
        // 取り消し済みの scope に戻った後の状態（一覧・unblockError）は捨てられうるので、見るのは記録と送った相手だけ
        val recorded = mutableListOf<AppError>()
        val recording = object : ModerationRepository by repository {
            override suspend fun unblock(uid: Uid): AppResult<Unit> =
                repository.unblock(uid).also { if (it is AppResult.Err) recorded += it.error }
        }
        val owner = immediateScope()
        val vm = BlockListViewModel(recording, online, owner)
        repository.profilesPending.last().complete(AppResult.Ok(listOf(alice, bob)))
        vm.unblock(Uid("alice"))
        try {
            owner.cancel()
            repository.completeLast(AppResult.Err(AppError.PermissionDenied))

            assertEquals(listOf(Uid("alice")), repository.unblockCalls)
            assertEquals(listOf<AppError>(AppError.PermissionDenied), recorded)
        } finally {
            // 取り消さない待ちを残さない（この scope はテストが待たないので止まりにはならないが、待つ形のテストと同じ書き方にそろえる）
            repository.pending.forEach { it.complete(AppResult.Err(AppError.Network)) }
        }
    }

    @Test
    fun `オフラインの間は、解除を送らない`() {
        val vm = loaded()
        online.value = false
        vm.unblock(Uid("alice"))

        assertEquals(emptyList(), repository.unblockCalls)
        assertEquals(emptySet(), vm.state.value.unblocking)
    }

    @Test
    fun `一覧に無いユーザーの解除は送らない`() {
        val vm = loaded()
        vm.unblock(Uid("carol"))

        assertEquals(emptyList(), repository.unblockCalls)
    }
}
