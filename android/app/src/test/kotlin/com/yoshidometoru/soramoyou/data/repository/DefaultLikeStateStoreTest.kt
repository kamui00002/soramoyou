// ⭐️ いいねの表示状態の規則（iOS の LikeManager を写したもの）を表にした単体テスト（タスク 18.3・要件 2.9・9.1・9.7・9.8・9.9）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics
import com.yoshidometoru.soramoyou.platform.SessionManager
import com.yoshidometoru.soramoyou.platform.SessionScopedState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/**
 * LikeStateStore が iOS の `LikeManager`（LikeManager.swift:29-156）と同じ規則で動くことを確かめる。
 * 書き込みと確認の終わる時刻を [FakeLikeRepository] で止めておき、「書き込み中」「確認中」の状態を作る。
 */
class DefaultLikeStateStoreTest {

    private val p = PostId("P")
    private val analytics = RecordingAnalytics()
    private val sessionManager = CapturingSessionManager()
    private val repository = FakeLikeRepository()
    private var signedIn: Uid? = Uid("UID-1")

    private fun store() = DefaultLikeStateStore(repository, analytics, { signedIn }, sessionManager)

    /** 登録された状態を受け取るだけの SessionManager の偽物。 */
    private class CapturingSessionManager : SessionManager {
        val states = mutableListOf<SessionScopedState>()
        override fun register(state: SessionScopedState) {
            states += state
        }
        override suspend fun clearLocalUserData() = states.forEach { it.clearOnSignOut() }
    }

    /**
     * 呼ばれた操作を記録する LikeRepository の偽物。結果は、呼ばれるたびに [setLikeResults]・[likedAmongResults] の先頭から取る。
     * 先頭が無ければ、[pendingSetLike] に止めて、テストが complete するまで待つ。記録はしない（本物は setLike の失敗を自分で記録する）。
     */
    private class FakeLikeRepository : LikeRepository {
        val setLikeCalls = mutableListOf<Pair<PostId, Boolean>>()
        val likedAmongCalls = mutableListOf<List<PostId>>()
        val setLikeResults = ArrayDeque<AppResult<Long>>()
        val likedAmongResults = ArrayDeque<AppResult<Set<PostId>>>()
        val pendingSetLike = ArrayDeque<CompletableDeferred<AppResult<Long>>>()
        val pendingLikedAmong = ArrayDeque<CompletableDeferred<AppResult<Set<PostId>>>>()

        override suspend fun setLike(postId: PostId, desired: Boolean): AppResult<Long> {
            setLikeCalls += postId to desired
            setLikeResults.removeFirstOrNull()?.let { return it }
            return CompletableDeferred<AppResult<Long>>().also { pendingSetLike += it }.await()
        }

        override suspend fun likedAmong(postIds: List<PostId>): AppResult<Set<PostId>> {
            likedAmongCalls += postIds
            likedAmongResults.removeFirstOrNull()?.let { return it }
            return CompletableDeferred<AppResult<Set<PostId>>>().also { pendingLikedAmong += it }.await()
        }
    }

    /** [block] を、最初に中断するところまで今すぐ進める（書き込み中・確認中の状態を作るため）。 */
    private fun kotlinx.coroutines.CoroutineScope.start(block: suspend () -> Unit): Job =
        launch(start = CoroutineStart.UNDISPATCHED) { block() }

    /** サーバーでいいね済みの投稿を、確認で状態に入れる。 */
    private suspend fun DefaultLikeStateStore.seedLiked(ids: List<PostId>) {
        repository.likedAmongResults += AppResult.Ok(ids.toSet())
        refresh(ids)
    }

    // ── 表示する数：押した結果の数字は、押したときと同じ基準のときだけ使う（0 未満は 0） ──

    @Test
    fun `押した結果の数字は同じ基準のときだけ出し、基準が変われば投稿の値を出し、0未満は0にする`() = runBlocking {
        val store = store()
        repository.setLikeResults += AppResult.Ok(9L)
        store.toggle(p, baseCount = 5)

        // (画面が持っている likesCount, 出す数)
        val rows = listOf(
            5L to 9L, // 押したときと同じ基準：押した結果（サーバーの値）
            6L to 6L, // 読み直して最新値が届いた：投稿の値
            -3L to 0L, // 投稿の値が 0 未満：0
        )
        for ((base, expected) in rows) assertEquals(expected, store.displayedCount(p, base), "baseCount=$base")
        assertEquals(0L, store.displayedCount(PostId("NONE"), -1), "押していない投稿の 0 未満")
    }

    // ── 押す：サーバーの応答を待たずに切り替え、成功したらサーバーの数にそろえる ──

    /** 1 行 = 押す前にいいね済みか・画面の likesCount・サーバーが返す数・押した直後と成功後の（いいね済みか, 出す数）。 */
    private data class ToggleRow(
        val name: String,
        val startLiked: Boolean,
        val base: Long,
        val server: Long,
        val optimistic: Pair<Boolean, Long>,
        val settled: Pair<Boolean, Long>,
    )

    @Test
    fun `押した直後は楽観的な値を出し、成功したらサーバーの値にそろえる`() = runBlocking {
        val rows = listOf(
            ToggleRow("いいねする", startLiked = false, base = 5, server = 6, optimistic = true to 6L, settled = true to 6L),
            ToggleRow("その間にほかの人もいいねした", false, 5, 9, true to 6L, true to 9L),
            ToggleRow("取り消す", true, 5, 4, false to 4L, false to 4L),
            ToggleRow("0 から取り消す（楽観的な -1 は 0 と出す）", true, 0, 0, false to 0L, false to 0L),
            ToggleRow("サーバーでは既にいいね済み（何も書かずに今の数）", false, 5, 5, true to 6L, true to 5L),
        )
        for (row in rows) {
            val repository = FakeLikeRepository()
            val store = DefaultLikeStateStore(repository, analytics, { signedIn }, CapturingSessionManager())
            if (row.startLiked) {
                repository.likedAmongResults += AppResult.Ok(setOf(p))
                store.refresh(listOf(p))
            }

            coroutineScope {
                start { store.toggle(p, row.base) }
                assertEquals(listOf(p to !row.startLiked), repository.setLikeCalls, row.name)
                assertEquals(row.optimistic, (p in store.liked.value) to store.displayedCount(p, row.base), "${row.name}：押した直後")
                repository.pendingSetLike.single().complete(AppResult.Ok(row.server))
            }

            assertEquals(row.settled, (p in store.liked.value) to store.displayedCount(p, row.base), "${row.name}：成功後")
            assertEquals(LikeCountOverride(row.base, row.server, !row.startLiked), store.countOverrides.value[p], row.name)
        }
        assertTrue(analytics.errors.isEmpty())
    }

    // ── 書き込み中の投稿への操作は受け付けない ──

    @Test
    fun `書き込み中の投稿への連打は無視し、ほかの投稿と、書き込みが終わった後の操作は受け付ける`() = runBlocking {
        val store = store()
        val other = PostId("OTHER")
        coroutineScope {
            start { store.toggle(p, 5) }
            start { store.toggle(p, 5) } // 書き込み中なので無視
            start { store.toggle(p, 5) } // 何度押しても無視
            assertEquals(listOf(p to true), repository.setLikeCalls)
            assertEquals(true to 6L, (p in store.liked.value) to store.displayedCount(p, 5), "無視した操作は表示も変えない")

            start { store.toggle(other, 1) } // ほかの投稿は書ける
            assertEquals(listOf(p to true, other to true), repository.setLikeCalls)

            repository.pendingSetLike.forEach { it.complete(AppResult.Ok(6L)) }
        }
        // 書き込みが終われば、同じ投稿を（取り消しとして）また押せる
        repository.setLikeResults += AppResult.Ok(5L)
        store.toggle(p, 5)
        assertEquals(p to false, repository.setLikeCalls.last())
    }

    // ── 失敗したら押す前の状態と数に戻す ──

    @Test
    fun `失敗したら押す前の状態と数字に戻し、記録し直さない`() = runBlocking {
        // (1) 押した結果の数字が無い投稿：いいね済みでない・数字なしに戻る
        val store = store()
        repository.setLikeResults += AppResult.Err(AppError.PermissionDenied)
        store.toggle(p, 5)
        assertEquals(false, p in store.liked.value)
        assertNull(store.countOverrides.value[p])
        assertEquals(5L, store.displayedCount(p, 5))

        // (2) 前に成功していた投稿：その時の組（5 で押して 6）に戻る
        repository.setLikeResults += AppResult.Ok(6L)
        store.toggle(p, 5)
        repository.setLikeResults += AppResult.Err(AppError.Network)
        store.toggle(p, 5)
        assertEquals(true, p in store.liked.value)
        assertEquals(LikeCountOverride(5, 6, true), store.countOverrides.value[p])
        assertEquals(6L, store.displayedCount(p, 5))

        // 記録は LikeRepository が済ませている（発生箇所 LikeRepository.setLike）ので、ここでは記録しない
        assertTrue(analytics.errors.isEmpty(), "記録し直している: ${analytics.errors}")
    }

    // ── 呼び出し側が取り消されても、書き込みの結果は最後まで反映する（レビュー R16） ──

    /**
     * 書き込み（[result] で終わる）を待っている間に、押したコルーチンを取り消し、その後で書き込みを終わらせて、store を返す。
     * 本物の LikeRepository は失敗を setLike の中で（await の後に）記録するので、偽物にも同じ位置で記録させる。
     */
    private fun toggleCancelledWhileWriting(result: AppResult<Long>): DefaultLikeStateStore {
        val recording = object : LikeRepository by repository {
            override suspend fun setLike(postId: PostId, desired: Boolean): AppResult<Long> =
                repository.setLike(postId, desired).also { if (it is AppResult.Err) analytics.logError(it.error, "LikeRepository.setLike") }
        }
        val store = DefaultLikeStateStore(recording, analytics, { signedIn }, sessionManager)
        runBlocking {
            val job = start { store.toggle(p, 5) }
            assertEquals(listOf(p to true), repository.setLikeCalls, "書き込み中のはず")
            // 見張り：取り消しの後も待ちを続ける作りが壊れても、5 秒で書き込みを終わらせてテストを赤で終わらせる
            // （NonCancellable の中の待ちは外から止められないので、終わらせないと runBlocking ごと止まる）
            val watchdog = launch {
                delay(5.seconds)
                repository.pendingSetLike.forEach { it.complete(result) }
            }
            try {
                job.cancel() // 投稿詳細を閉じて、持ち主の scope が取り消された
                repository.pendingSetLike.single().complete(result)
                job.join()
            } finally {
                watchdog.cancel()
                repository.pendingSetLike.forEach { it.complete(result) }
            }
        }
        return store
    }

    @Test
    fun `書き込みを待つ間に押した側が取り消されても、失敗なら押す前の状態と数字に戻し、LikeRepositoryの記録も走り、次の操作を受け付ける`() {
        val store = toggleCancelledWhileWriting(AppResult.Err(AppError.Network))

        assertEquals(false, p in store.liked.value, "押す前に戻っていない")
        assertNull(store.countOverrides.value[p])
        assertEquals(5L, store.displayedCount(p, 5))
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.Network, "LikeRepository.setLike")), analytics.errors)
        // 書き込み中の印も外れている（確定の前に開き直して押したときに 2 本目が止まらない・永久に止まらない）
        repository.setLikeResults += AppResult.Ok(6L)
        runBlocking { store.toggle(p, 5) }
        assertEquals(2, repository.setLikeCalls.size, "取り消された後の操作が無視された")
    }

    @Test
    fun `書き込みを待つ間に押した側が取り消されても、成功ならサーバーの数字にそろう`() {
        val store = toggleCancelledWhileWriting(AppResult.Ok(9L))

        assertEquals(true to 9L, (p in store.liked.value) to store.displayedCount(p, 5))
        assertEquals(LikeCountOverride(5, 9, true), store.countOverrides.value[p])
        assertTrue(analytics.errors.isEmpty())
    }

    // ── 確認：問い合わせた範囲だけを置き換え、食い違う数字だけを捨てる ──

    @Test
    fun `確認は問い合わせた範囲のいいね済みだけを置き換える`() = runBlocking {
        val store = store()
        val (a, b, c) = listOf(PostId("A"), PostId("B"), PostId("C"))
        store.seedLiked(listOf(a, b))

        repository.likedAmongResults += AppResult.Ok(setOf(c))
        store.refresh(listOf(b, c, b))

        // A は問い合わせていないので残る。B は別の端末で外された。C は別の端末でいいねされた
        assertEquals(setOf(a, c), store.liked.value)
        assertEquals(listOf(b, c), repository.likedAmongCalls.last(), "重なった ID は 1 回だけ問い合わせる")
    }

    @Test
    fun `確認で捨てるのは押した向きとサーバーの状態が食い違う数字だけで、書き込み中と問い合わせていない投稿の数字は残す`() = runBlocking {
        val store = store()
        // 表：投稿・押した向き（いずれもいいね）・問い合わせるか・サーバーでいいね済みか・書き込み中か → 数字が残るか
        val kept = PostId("KEPT") // 向きとサーバーが一致：残す
        val stale = PostId("STALE") // 別の端末で外された：捨てる
        val notQueried = PostId("NOT_QUERIED") // 食い違っていても問い合わせていない：残す
        val inFlight = PostId("IN_FLIGHT") // 書き込み中：読んだ値が書き込み前のことがあるので残す
        for (id in listOf(kept, stale, notQueried)) {
            repository.setLikeResults += AppResult.Ok(1L)
            store.toggle(id, 0)
        }
        coroutineScope {
            start { store.toggle(inFlight, 0) }

            repository.likedAmongResults += AppResult.Ok(setOf(kept))
            store.refresh(listOf(kept, stale, inFlight))

            assertEquals(setOf(kept, notQueried, inFlight), store.countOverrides.value.keys)
            // いいね済みの集合は、iOS と同じく書き込み中の投稿も問い合わせの結果で置き換える（成功したときにそろえ直す）
            assertEquals(setOf(kept, notQueried), store.liked.value)

            repository.pendingSetLike.single().complete(AppResult.Ok(1L))
        }
        assertEquals(setOf(kept, notQueried, inFlight), store.liked.value, "書き込みの成功で、押した向きにそろえ直す")
    }

    @Test
    fun `確認に失敗したら状態を変えずに記録する`() = runBlocking {
        val store = store()
        store.seedLiked(listOf(p))

        repository.likedAmongResults += AppResult.Err(AppError.Network)
        store.refresh(listOf(p))

        assertEquals(setOf(p), store.liked.value)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.Network, "LikeStateStore.refresh")), analytics.errors)
    }

    @Test
    fun `確認する投稿が無ければ問い合わせない`() = runBlocking {
        store().refresh(emptyList())
        assertTrue(repository.likedAmongCalls.isEmpty())
    }

    // ── ログインしていない・ログアウト ──

    @Test
    fun `ログインしていなければ、押しても確かめても何もせず記録もしない`() = runBlocking {
        signedIn = null
        val store = store()

        store.toggle(p, 5)
        store.refresh(listOf(p))

        assertTrue(repository.setLikeCalls.isEmpty())
        assertTrue(repository.likedAmongCalls.isEmpty())
        assertTrue(store.liked.value.isEmpty())
        assertTrue(store.countOverrides.value.isEmpty())
        assertTrue(analytics.errors.isEmpty())
    }

    @Test
    fun `作られたときにSessionManagerへ登録し、ログアウトで全てを捨てる`() = runBlocking {
        val store = store()
        repository.setLikeResults += AppResult.Ok(6L)
        store.toggle(p, 5)

        sessionManager.clearLocalUserData()

        assertEquals(listOf<SessionScopedState>(store), sessionManager.states)
        assertTrue(store.liked.value.isEmpty())
        assertTrue(store.countOverrides.value.isEmpty())
        assertEquals(5L, store.displayedCount(p, 5))
    }

    @Test
    fun `ログアウトの前に始めた書き込みと確認は、終わっても書き戻さず記録もせず、次のユーザーの操作を妨げない`() = runBlocking {
        val store = store()
        coroutineScope {
            try {
                val oldToggle = start { store.toggle(p, 5) } // 前のユーザーの書き込み（止めておく）
                val oldRefresh = start { store.refresh(listOf(p)) } // 前のユーザーの確認（止めておく）
                sessionManager.clearLocalUserData()

                // 次のユーザーが同じ投稿を押せる（前の書き込み中の印に妨げられない）
                start { store.toggle(p, 5) }
                assertEquals(2, repository.setLikeCalls.size, "ログアウト後の操作が無視された")

                // 前のユーザーの書き込みと確認が、終わる
                repository.pendingSetLike.first().complete(AppResult.Err(AppError.Network))
                repository.pendingLikedAmong.single().complete(AppResult.Err(AppError.Network))
                // complete は再開を予約するだけなので、前のユーザーの書き込みと確認が最後まで終わる（Job が終わる）のを待ってから下を確かめる。
                // complete した Deferred の isCompleted はいつも真なので、終わったかの確かめにならない。yield の回数にも頼らない
                // （toggle・refresh に再開の段が 1 つ増えると、yield 1 回では終わる前に下を確かめてしまい、壊れていても緑になる）。
                // 終わらない改変で止まらないよう、待ちに上限を付ける
                withTimeout(5.seconds) {
                    oldToggle.join()
                    oldRefresh.join()
                }
                // 前の書き込みの終わりで、次のユーザーの書き込み中の印が消えていない（3 回目は無視される）
                start { store.toggle(p, 5) }
                assertEquals(2, repository.setLikeCalls.size, "前の書き込みの終わりで、次のユーザーの書き込み中の印が消えた")
                // 前の失敗で巻き戻されず、次のユーザーの楽観的な表示のまま
                assertEquals(true to 6L, (p in store.liked.value) to store.displayedCount(p, 5))
                assertTrue(analytics.errors.isEmpty(), "前のユーザーの確認の失敗を記録している: ${analytics.errors}")

                repository.pendingSetLike.last().complete(AppResult.Ok(6L))
            } finally {
                // 確かめが途中で失敗しても書き込みの待ちを外す（書き込みの待ちは取り消さない（NonCancellable）ので、外さないと
                // coroutineScope が子を待ち続け、赤でなく止まりになる。済んだものへの complete は何もしない）
                repository.pendingSetLike.forEach { it.complete(AppResult.Err(AppError.Network)) }
            }
        }
        assertEquals(LikeCountOverride(5, 6, true), store.countOverrides.value[p])
    }
}
