// ⭐️ フィードの画面の状態の単体テスト（タスク 9.4・29.2・要件 4.1〜4.3・4.6・4.9・4.12・4.13・11.1・11.4・11.7・15.4・16.2・16.3）
package com.yoshidometoru.soramoyou.feature.feed

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.data.repository.BlockedUsers
import com.yoshidometoru.soramoyou.data.remote.read.RawCursor
import com.yoshidometoru.soramoyou.data.repository.CreatedPosts
import com.yoshidometoru.soramoyou.data.repository.DeletedPosts
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.feature.FakeWriteGate
import com.yoshidometoru.soramoyou.feature.RecordingFeatureAnalytics
import com.yoshidometoru.soramoyou.feature.immediateScope
import com.yoshidometoru.soramoyou.feature.moderation.FakeModerationRepository
import com.yoshidometoru.soramoyou.feature.moderation.ModerationAction
import com.yoshidometoru.soramoyou.platform.ScreenName
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * Compose の画面テストの仕組みは無い（9.5 は任意で未着手）ので、画面の振る舞いはこの ViewModel と [feedContentOf] で確かめる。
 * 偽物の取得は、テストが結果を渡すまで待つ（[FakeFeedRepository]）。スコープは Unconfined なので、結果を渡すとその場で続きが進む。
 */
class FeedViewModelTest {

    private val repository = FakeFeedRepository()
    private val blockList = FakeBlockListRepository()
    private val authors = FakeAuthorProfileCache()
    private val analytics = RecordingFeatureAnalytics()
    private val online = MutableStateFlow(true)
    private val session = MutableStateFlow<SessionState>(SessionState.SignedIn(Uid("me"), "me@example.com", isAnonymous = false))

    private val likes = FakeLikeStateStore()
    private var gate = FakeWriteGate(setOf(WriteCapability.LIKE))
    private val moderationRepository = FakeModerationRepository()
    private val blockedUsers = BlockedUsers()

    private fun viewModel(created: CreatedPosts = CreatedPosts(), deleted: DeletedPosts = DeletedPosts()) =
        FeedViewModel(
            repository,
            blockList,
            authors,
            likes,
            gate,
            analytics,
            online,
            session,
            immediateScope(),
            moderationRepository,
            blockedUsers,
            created.events,
            deleted.events,
        )

    // ── 先頭からの取得（要件 4.1・4.3・16.2）──

    @Test
    fun `作った時点で先頭のページを読み、読み終えたら投稿を出して読み込み中を外す`() {
        val vm = viewModel()
        assertEquals(listOf<RawCursor?>(null), repository.calls)
        assertTrue(vm.state.value.isRefreshing)
        assertEquals(FeedContent.LOADING, feedContentOf(vm.state.value))

        repository.completeLast(page(posts("a", 2)))

        assertEquals(posts("a", 2), vm.state.value.posts)
        assertFalse(vm.state.value.isRefreshing)
        assertEquals(FeedContent.LIST, feedContentOf(vm.state.value))
    }

    @Test
    fun `引っ張って更新すると先頭から読み直して置き換える`() {
        val vm = viewModel()
        repository.completeLast(page(posts("a", 20)))
        vm.loadMore()
        repository.completeLast(page(posts("b", 20)))

        vm.refresh()
        repository.completeLast(page(posts("c", 3)))

        assertNull(repository.calls.last())
        assertEquals(posts("c", 3), vm.state.value.posts)
    }

    // ── 続きの取得（要件 4.2）──

    @Test
    fun `続きは前のページの生の起点から読んで末尾に足す`() {
        val vm = viewModel()
        val first = cursor("first")
        repository.completeLast(page(posts("a", 20), next = first))

        vm.loadMore()
        repository.completeLast(page(posts("b", 5), reachedEnd = true))

        assertSame(first, repository.calls[1])
        assertEquals(posts("a", 20) + posts("b", 5), vm.state.value.posts)
    }

    @Test
    fun `表示できる投稿が19件でも、ページが続きありなら続きを読みに行く`() {
        // 20 件中 1 件が壊れていたページ。続きの有無を表示できる件数で決めると、ここで止まる
        val vm = viewModel()
        repository.completeLast(page(posts("a", 19), skipped = 1, reachedEnd = false))
        assertFalse(vm.state.value.reachedEnd)

        vm.loadMore()

        assertEquals(2, repository.calls.size)
    }

    @Test
    fun `ページが続きなしなら、表示できる件数によらず続きを読まない`() {
        val vm = viewModel()
        repository.completeLast(page(posts("a", 20), reachedEnd = true))

        vm.loadMore()

        assertEquals(1, repository.calls.size)
        assertTrue(vm.state.value.reachedEnd)
    }

    @Test
    fun `続きの取得中にもう一度呼んでも、二重には読まない`() {
        val vm = viewModel()
        repository.completeLast(page(posts("a", 20)))

        vm.loadMore()
        vm.loadMore()

        assertEquals(2, repository.calls.size)
        assertTrue(vm.state.value.isLoadingMore)
    }

    @Test
    fun `続きの取得中に先頭から読み直したら、古い続きの結果は捨てる`() {
        val vm = viewModel()
        repository.completeLast(page(posts("a", 20)))
        vm.loadMore()
        val staleMore = repository.pending.last()

        vm.refresh()
        repository.completeLast(page(posts("c", 2)))
        staleMore.complete(page(posts("b", 20)))

        assertEquals(posts("c", 2), vm.state.value.posts)
        assertFalse(vm.state.value.isLoadingMore)
    }

    // ── ブロックの除外と投稿者（要件 4.6・4.9）──

    @Test
    fun `ブロック中のユーザーの投稿を出さず、投稿者の取得にも渡さない`() {
        blockList.result = AppResult.Ok(setOf(Uid("blocked")))
        val vm = viewModel()

        repository.completeLast(page(listOf(post("1", "alice"), post("2", "blocked"), post("3", "bob"))))

        assertEquals(listOf(post("1", "alice"), post("3", "bob")), vm.state.value.posts)
        assertEquals(listOf(setOf(Uid("alice"), Uid("bob"))), authors.ensureCalls)
    }

    @Test
    fun `ブロック中の一覧の取得に失敗しても表示を続け、ここでは記録し直さない`() {
        blockList.result = AppResult.Err(AppError.Network)
        val vm = viewModel()

        repository.completeLast(page(listOf(post("1", "alice"))))

        assertEquals(listOf(post("1", "alice")), vm.state.value.posts)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `ブロック中の一覧は先頭から読むときだけ読み、続きでは使い回す`() {
        blockList.result = AppResult.Ok(setOf(Uid("blocked")))
        val vm = viewModel()
        repository.completeLast(page(posts("a", 20)))

        vm.loadMore()
        repository.completeLast(page(listOf(post("x", "blocked"), post("y", "carol")), reachedEnd = true))

        assertEquals(1, blockList.calls)
        assertEquals(posts("a", 20) + post("y", "carol"), vm.state.value.posts)
    }

    // ── 表示が 0 件のページの先読み ──

    @Test
    fun `表示できる投稿が0件で続きがあるページは、続けて次のページを読む`() {
        blockList.result = AppResult.Ok(setOf(Uid("blocked")))
        val vm = viewModel()
        val afterBlocked = cursor("after-blocked")

        repository.completeLast(page(List(20) { post("b$it", "blocked") }, next = afterBlocked))

        assertEquals(2, repository.calls.size)
        assertSame(afterBlocked, repository.calls[1])
        repository.completeLast(page(listOf(post("1", "alice")), reachedEnd = true))
        assertEquals(listOf(post("1", "alice")), vm.state.value.posts)
    }

    @Test
    fun `0件のページの先読みは、続けて3ページまでで止める`() {
        repeat(10) { repository.queued += page(emptyList(), skipped = 20) }
        val vm = viewModel()

        assertEquals(1 + FeedViewModel.MAX_EMPTY_PAGE_FOLLOW_UPS, repository.calls.size)
        assertFalse(vm.state.value.isRefreshing)
        assertFalse(vm.state.value.reachedEnd)
    }

    // ── 取得の失敗（要件 4.12・16.3）──

    @Test
    fun `先頭からの取得に失敗したら、失敗を出して記録する`() {
        val vm = viewModel()
        repository.completeLast(AppResult.Err(AppError.PermissionDenied))

        assertEquals(AppError.PermissionDenied, vm.state.value.error)
        assertEquals(FeedContent.ERROR, feedContentOf(vm.state.value))
        assertEquals(listOf<Pair<AppError, String>>(AppError.PermissionDenied to "FeedViewModel.refresh"), analytics.errors)
    }

    @Test
    fun `失敗した時点でオフラインだったら、オフラインの表示にする`() {
        val vm = viewModel()
        online.value = false
        repository.completeLast(AppResult.Err(AppError.Network))

        assertTrue(vm.state.value.failedWhileOffline)
        assertEquals(FeedContent.OFFLINE, feedContentOf(vm.state.value))
    }

    @Test
    fun `続きの取得に失敗しても投稿は残し、再試行で同じ起点から読み直す`() {
        val vm = viewModel()
        val first = cursor("first")
        repository.completeLast(page(posts("a", 20), next = first))
        vm.loadMore()
        repository.completeLast(AppResult.Err(AppError.Network))

        assertEquals(posts("a", 20), vm.state.value.posts)
        assertEquals(AppError.Network, vm.state.value.error)
        assertEquals(AppError.Network to "FeedViewModel.loadMore", analytics.errors.single())

        vm.loadMore()
        assertSame(first, repository.calls[2])
        assertNull(vm.state.value.error)
    }

    // ── 画面名・ログアウト（要件 15.4・2.9）──

    @Test
    fun `画面の表示のたびに画面名「ホーム」を送る`() {
        val vm = viewModel()
        vm.onScreenShown()
        vm.onScreenShown()

        assertEquals(listOf(ScreenName.HOME, ScreenName.HOME), analytics.screens)
    }

    @Test
    fun `ログアウトしたら投稿を捨て、取得中だったものも書き戻さない`() {
        val vm = viewModel()
        repository.completeLast(page(posts("a", 20)))
        vm.loadMore()
        val inFlight = repository.pending.last()

        session.value = SessionState.SignedOut
        inFlight.complete(page(posts("b", 20)))

        assertEquals(FeedUiState(), vm.state.value)
    }

    // ── いいね（タスク 18.4・要件 9.1・9.2・9.7）──

    @Test
    fun `読んだページごとに、表示する投稿だけのいいね済みを確かめる（ブロック中の投稿と0件のページは確かめない）`() {
        blockList.result = AppResult.Ok(setOf(Uid("blocked")))
        val vm = viewModel()
        repository.completeLast(page(listOf(post("1", "alice"), post("2", "blocked"), post("3", "bob"))))
        assertEquals(listOf(listOf(PostId("1"), PostId("3"))), likes.refreshCalls, "先頭のページ")

        vm.loadMore()
        repository.completeLast(page(listOf(post("4", "blocked"))))
        // 表示が 0 件のページは確かめず、続けて読んだページの投稿だけを確かめる
        repository.completeLast(page(listOf(post("5", "carol")), reachedEnd = true))
        assertEquals(listOf(listOf(PostId("1"), PostId("3")), listOf(PostId("5"))), likes.refreshCalls, "続きは新しく読んだ投稿だけ")
    }

    @Test
    fun `いいねを押すと、その投稿と画面が持っているいいね数を渡す`() {
        val vm = viewModel()
        vm.toggleLike(post("1").copy(likesCount = 7))
        assertEquals(listOf(PostId("1") to 7L), likes.toggleCalls)
    }

    @Test
    fun `いいねの書き込みが有効なビルドでだけ、いいねのボタンを押せる`() {
        assertTrue(viewModel().canLike)
        gate = FakeWriteGate(ALL_BUT_LIKE)
        assertFalse(viewModel().canLike)
    }

    @Test
    fun `いいねの状態は全画面で共有のものをそのまま出す`() {
        val vm = viewModel()
        assertSame(likes.liked, vm.liked)
        assertSame(likes.countOverrides, vm.likeCountOverrides)
    }

    // ── 自分が作った投稿の差し込み（要件 7.22・タスク 23.3）──

    @Test
    fun `自分が作った公開の投稿は、読み直さずに一覧の先頭に差し込み、投稿者の表示を読み込む`() {
        val created = CreatedPosts()
        val vm = viewModel(created)
        repository.completeLast(page(posts("a", 2)))
        val mine = post("new", "me").copy(visibility = Visibility.PUBLIC)

        created.notify(mine)

        assertEquals(listOf(mine) + posts("a", 2), vm.state.value.posts)
        assertEquals(setOf(Uid("me")), authors.ensureCalls.last())
        assertEquals(1, repository.calls.size, "読み直さない")
    }

    @Test
    fun `公開でない投稿と、既に一覧にある投稿は差し込まない`() {
        val created = CreatedPosts()
        val vm = viewModel(created)
        val shown = post("shown", "me").copy(visibility = Visibility.PUBLIC)
        repository.completeLast(page(listOf(shown)))
        val ensuredBefore = authors.ensureCalls.size

        created.notify(post("f", "me").copy(visibility = Visibility.FOLLOWERS))
        created.notify(post("p", "me").copy(visibility = Visibility.PRIVATE))
        created.notify(post("unknown", "me"))
        created.notify(shown.copy(caption = "同じ投稿"))

        assertEquals(listOf(shown), vm.state.value.posts)
        assertEquals(ensuredBefore, authors.ensureCalls.size)
    }

    // ── 自分が消した投稿の除去（要件 10.11・タスク 24）──

    @Test
    fun `自分が消した投稿は、読み直さずに一覧から除き、一覧に無い投稿の知らせでは何も変えない`() {
        val deleted = DeletedPosts()
        val vm = viewModel(deleted = deleted)
        repository.completeLast(page(posts("a", 3)))

        deleted.notify(PostId("a-1"))
        assertEquals(listOf(post("a-0"), post("a-2")), vm.state.value.posts)

        deleted.notify(PostId("not-shown"))
        assertEquals(listOf(post("a-0"), post("a-2")), vm.state.value.posts)
        assertEquals(1, repository.calls.size, "読み直さない")
    }

    // ── 通報・ブロック（要件 11.1・11.4・11.7・タスク 29.2）──

    @Test
    fun `フィードでは、自分の投稿には通報もブロックも出さず、他人の投稿にだけ出す`() {
        gate = FakeWriteGate(setOf(WriteCapability.LIKE, WriteCapability.REPORT, WriteCapability.BLOCK))
        val vm = viewModel()

        assertEquals(emptySet(), vm.moderation.actionsFor(post("1", "me")))
        assertEquals(setOf(ModerationAction.REPORT, ModerationAction.BLOCK), vm.moderation.actionsFor(post("2", "alice")))
    }

    @Test
    fun `ブロックしたら、表示中のフィードからその投稿者の投稿を読み直さずにすぐ除く`() {
        gate = FakeWriteGate(setOf(WriteCapability.REPORT, WriteCapability.BLOCK))
        val vm = viewModel()
        repository.completeLast(page(listOf(post("1", "alice"), post("2", "bob"), post("3", "alice"))))

        vm.moderation.requestBlock(post("1", "alice"))
        vm.moderation.confirmBlock()
        moderationRepository.completeLast(AppResult.Ok(Unit))

        assertEquals(listOf(Uid("alice")), moderationRepository.blockCalls)
        assertEquals(listOf(post("2", "bob")), vm.state.value.posts)
        assertEquals(1, repository.calls.size, "読み直さない")
    }

    @Test
    fun `投稿詳細でブロックした知らせでも、表示中のフィードからその投稿者の投稿を除く`() {
        val vm = viewModel()
        repository.completeLast(page(listOf(post("1", "alice"), post("2", "bob"))))

        blockedUsers.notify(Uid("bob"))

        assertEquals(listOf(post("1", "alice")), vm.state.value.posts)
        assertEquals(1, repository.calls.size, "読み直さない")
    }

    @Test
    fun `ブロックした後に読んだ続きのページでも、その投稿者の投稿を除く`() {
        val vm = viewModel()
        repository.completeLast(page(posts("a", 20)))

        blockedUsers.notify(Uid("bob"))
        vm.loadMore()
        repository.completeLast(page(listOf(post("x", "bob"), post("y", "carol")), reachedEnd = true))

        assertEquals(posts("a", 20) + post("y", "carol"), vm.state.value.posts)
    }

    // ── 先頭からの読み直しとブロックの知らせの合わせ方（レビュー F16）──

    @Test
    fun `読み直しでブロック中の一覧を待つ間に届いたブロックの知らせは、読み直しの後も除いたままにする`() {
        val vm = viewModel()
        repository.completeLast(page(listOf(post("1", "alice"), post("2", "bob"))))
        blockList.holds = true

        vm.refresh()
        blockedUsers.notify(Uid("bob"))
        // サーバーの一覧は、ブロックの書き込みより前の状態で返る（bob が入っていない）
        blockList.completeLast(AppResult.Ok(emptySet()))
        repository.completeLast(page(listOf(post("3", "alice"), post("4", "bob"))))

        assertEquals(listOf(post("3", "alice")), vm.state.value.posts)
    }

    @Test
    fun `読み直しでブロック中の一覧の取得に失敗しても、それまでに分かっていたブロックは除いたままにする`() {
        blockList.result = AppResult.Ok(setOf(Uid("carol")))
        val vm = viewModel()
        repository.completeLast(page(listOf(post("1", "alice"), post("2", "bob"))))
        blockedUsers.notify(Uid("bob"))

        blockList.result = AppResult.Err(AppError.Network)
        vm.refresh()
        repository.completeLast(page(listOf(post("3", "alice"), post("4", "bob"), post("5", "carol"))))

        // サーバーから読めていた carol も、この画面で知らせを受けた bob も、空にして戻さない
        assertEquals(listOf(post("3", "alice")), vm.state.value.posts)
        assertEquals(emptyList(), analytics.errors, "記録は BlockListRepository が済ませているので、ここでは記録し直さない")
    }

    @Test
    fun `前の読み直しの後に知らせで足したブロックは、次の読み直しでサーバーの一覧に無ければ外す（解除した人の投稿が戻る）`() {
        val vm = viewModel()
        repository.completeLast(page(listOf(post("1", "alice"), post("2", "bob"))))
        blockedUsers.notify(Uid("bob"))
        // この後、ブロック中のユーザーの画面で bob を解除した（解除は知らせない）。サーバーの一覧にはもう居ない

        vm.refresh()
        repository.completeLast(page(listOf(post("3", "alice"), post("4", "bob"))))

        assertEquals(listOf(post("3", "alice"), post("4", "bob")), vm.state.value.posts)
    }

    @Test
    fun `ブロックに失敗したら一覧を変えず、ここでは記録し直さない`() {
        gate = FakeWriteGate(setOf(WriteCapability.REPORT, WriteCapability.BLOCK))
        val vm = viewModel()
        repository.completeLast(page(listOf(post("1", "alice"), post("2", "bob"))))

        vm.moderation.requestBlock(post("1", "alice"))
        vm.moderation.confirmBlock()
        moderationRepository.completeLast(AppResult.Err(AppError.Network))

        assertEquals(listOf(post("1", "alice"), post("2", "bob")), vm.state.value.posts)
        assertEquals(emptyList(), analytics.errors)
    }

    private companion object {
        val ALL_BUT_LIKE: Set<WriteCapability> = WriteCapability.entries.toSet() - WriteCapability.LIKE
    }
}
