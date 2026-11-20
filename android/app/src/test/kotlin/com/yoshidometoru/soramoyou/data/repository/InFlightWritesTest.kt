// ⭐️ 走っている取り消さない書き込みの数（ログアウトが終わりを待つ）の単体テスト（全体レビュー 4 回目 Q03）
package com.yoshidometoru.soramoyou.data.repository

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/**
 * 走っている書き込みが残っているか。無ければ [InFlightWrites.awaitIdle] は待たずに戻り、残っていれば短い上限で打ち切られる
 * （残っているときに 50 ミリ秒待つだけなので、端末の負荷で答えが変わらない）。プロフィールの保存・投稿の削除・ログアウトのテストも使う。
 */
internal suspend fun InFlightWrites.isBusy(): Boolean = withTimeoutOrNull(50.milliseconds) { awaitIdle() } == null

/**
 * [InFlightWrites] の単体テスト。数える・待つ・外すを確かめる。
 * 取り消さない書き込みのまねは、テストが完了させるまで終わらない待ち（CompletableDeferred）で作る。確かめが失敗しても待ちを外すよう、
 * 待ちは finally で完了させる（外さないと runBlocking が子を待ち続けて、赤でなく止まりになる）。
 */
class InFlightWritesTest {

    private val inFlight = InFlightWrites()

    @Test
    fun `走っている書き込みが無ければ、待たずに戻る`() = runBlocking {
        assertFalse(inFlight.isBusy())
    }

    @Test
    fun `書き込みが走っている間は待ち、終わったら戻る`() = runBlocking {
        val release = CompletableDeferred<Unit>()
        var idle = false
        val writing = launch(Dispatchers.Unconfined) { inFlight.track { release.await() } }
        val waiting = launch(Dispatchers.Unconfined) {
            inFlight.awaitIdle()
            idle = true
        }
        try {
            assertTrue(inFlight.isBusy())
            assertFalse(idle)
        } finally {
            release.complete(Unit)
        }
        writing.join()
        waiting.join()
        assertTrue(idle)
        assertFalse(inFlight.isBusy())
    }

    @Test
    fun `2つ走っていれば、両方が終わるまで待つ`() = runBlocking {
        val first = CompletableDeferred<Unit>()
        val second = CompletableDeferred<Unit>()
        val writings = listOf(
            launch(Dispatchers.Unconfined) { inFlight.track { first.await() } },
            launch(Dispatchers.Unconfined) { inFlight.track { second.await() } },
        )
        try {
            first.complete(Unit)
            // 1 つ終わっても、もう 1 つが走っている
            assertTrue(inFlight.isBusy())
        } finally {
            first.complete(Unit)
            second.complete(Unit)
        }
        writings.forEach { it.join() }
        assertFalse(inFlight.isBusy())
    }

    @Test
    fun `書き込みの結果をそのまま返し、終わったら数から外す`() = runBlocking {
        assertEquals(42, inFlight.track { 42 })
        assertFalse(inFlight.isBusy())
    }

    @Test
    fun `例外で終わっても数から外し、例外はそのまま伝える`() = runBlocking {
        assertFailsWith<IllegalStateException> { inFlight.track { throw IllegalStateException("偽物の失敗") } }
        assertFalse(inFlight.isBusy())
    }

    @Test
    fun `取り消されても数から外す`() = runBlocking {
        val writing = launch(Dispatchers.Unconfined) { inFlight.track { awaitCancellation() } }
        try {
            assertTrue(inFlight.isBusy())
        } finally {
            // 上の確かめが失敗しても取り消す（取り消さないと runBlocking が子を待ち続けて止まる）
            writing.cancel()
        }
        writing.join()
        assertFalse(inFlight.isBusy())
    }
}
