// ⭐️ ログアウトで破棄して作り直せる入れ物の単体テスト（タスク 5.1・要件 2.9）
package com.yoshidometoru.soramoyou.di

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNotSame
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking

/**
 * [ResettableInstance] の単体テスト。本物の FirebaseFirestore は JVM の単体テストでは作れないので、
 * Firestore の「インスタンスの登録簿」の振る舞いをまねた偽物で確かめる。
 *
 * 偽物がまねる本物の振る舞い（firebase-firestore 26.6.0 のバイトコードを javap で確認。2026-10-04）:
 * - `getInstance()` は、登録簿にあるインスタンスを返す。無ければ新しく作って登録する（FirestoreMultiDbComponent.get）
 * - `terminate()` は、まず登録簿から外し（同期）、それから停止の Task を返す（FirebaseFirestore.terminate）
 * - 新しく作ったインスタンスの設定は SDK の既定（FirebaseFirestoreSettings.Builder の persistenceEnabled = true）。
 *   つまり作り直したものには、設定を当て直さないとディスクのキャッシュが有効になる
 */
class ResettableInstanceTest {

    /** 本物の FirebaseFirestore の代わり。何番目に作られたかと、設定・停止の記録を持つ。 */
    private class FakeClient(val serial: Int) {
        @Volatile var configuredCount = 0
        @Volatile var releaseStarted = false
        @Volatile var releaseFinished = false
    }

    /** Firestore の登録簿をまねた工場。登録中のものがあればそれを返し、無ければ作って登録する。 */
    private class FakeRegistry {
        private val lock = Any()
        private var registered: FakeClient? = null
        private var created = 0
        private var removed = 0

        fun getInstance(): FakeClient = synchronized(lock) {
            registered ?: FakeClient(++created).also { registered = it }
        }

        fun remove(client: FakeClient) = synchronized(lock) {
            removed++
            if (registered === client) registered = null
        }

        fun createdCount(): Int = synchronized(lock) { created }
        fun removedCount(): Int = synchronized(lock) { removed }
    }

    /**
     * 検査する入れ物を作る。停止は本物の terminate と同じ順にする：
     * 同期の部分で登録簿から外し（[beforeRemove]・[afterRemove] はその前後の差し込み口）、待つ部分（[awaitShutdown]）で停止の完了を待つ。
     */
    private fun holderOf(
        registry: FakeRegistry,
        beforeRemove: (FakeClient) -> Unit = {},
        afterRemove: (FakeClient) -> Unit = {},
        awaitShutdown: suspend (FakeClient) -> Unit = {},
    ) = ResettableInstance(
        create = registry::getInstance,
        configure = { it.configuredCount++ },
        release = { old ->
            beforeRemove(old)
            registry.remove(old)
            old.releaseStarted = true
            afterRemove(old)
            suspend {
                awaitShutdown(old)
                old.releaseFinished = true
            }
        },
    )

    @Test
    fun `currentを呼ぶまではインスタンスを作らない`() {
        val registry = FakeRegistry()
        holderOf(registry)

        assertEquals(0, registry.createdCount())
    }

    @Test
    fun `currentは同じインスタンスを返し、設定は作った直後に1回だけ当てる`() {
        val registry = FakeRegistry()
        val holder = holderOf(registry)

        val first = holder.current()
        val second = holder.current()

        assertSame(first, second)
        assertEquals(1, registry.createdCount())
        assertEquals(1, first.configuredCount)
    }

    @Test
    fun `resetの後のcurrentは新しいインスタンスを返し、それにも設定を当てる`() {
        // 本物では、terminate の後の getInstance は SDK の既定の設定（ディスクに永続化する）で新しく作られる。
        // 作り直したものに設定を当て忘れると、最初のログアウトから黙ってディスクのキャッシュが有効になる
        val registry = FakeRegistry()
        val holder = holderOf(registry)
        val first = holder.current()

        runBlocking { holder.reset() }
        val second = holder.current()

        assertNotSame(first, second)
        assertEquals(2, second.serial)
        assertEquals(1, second.configuredCount, "作り直したインスタンスに設定が当たっていない")
        assertEquals(1, first.configuredCount)
    }

    @Test
    fun `resetは古いインスタンスを停止し、停止の完了を待ってから戻る`() {
        val registry = FakeRegistry()
        val holder = holderOf(registry)
        val first = holder.current()

        runBlocking { holder.reset() }

        assertTrue(first.releaseStarted, "停止を始めていない")
        assertTrue(first.releaseFinished, "停止の完了を待たずに戻った")
        assertEquals(1, registry.removedCount())
    }

    @Test
    fun `一度も作っていなければresetは何も作らず何も停止しない`() {
        val registry = FakeRegistry()
        val holder = holderOf(registry)

        runBlocking { holder.reset() }

        assertEquals(0, registry.createdCount())
        assertEquals(0, registry.removedCount())
    }

    @Test
    fun `停止の完了を待っている間のcurrentは、古いインスタンスではなく新しいものを返す`() {
        val registry = FakeRegistry()
        val gate = CompletableDeferred<Unit>()
        val holder = holderOf(registry, awaitShutdown = { gate.await() })
        val first = holder.current()

        runBlocking {
            // reset を、最初の中断（停止の完了待ち）まで同じスレッドで進める
            val resetting = async(start = CoroutineStart.UNDISPATCHED) { holder.reset() }
            assertTrue(first.releaseStarted)
            assertFalse(first.releaseFinished)

            val during = holder.current()
            assertNotSame(first, during, "停止中のインスタンスを current が返した")
            assertEquals(1, during.configuredCount)

            gate.complete(Unit)
            resetting.await()
            assertTrue(first.releaseFinished)
            // 待ちの間に作ったものは、reset が終わった後もそのまま使われる（reset が後から捨てない）
            assertSame(during, holder.current())
        }
    }

    @Test
    fun `登録簿から外す前に別のスレッドがcurrentを呼んでも、停止するインスタンスを掴まない`() {
        // 本物の terminate は「登録簿から外す」を同期で行う。古いものを手放してから terminate を呼ぶまでの間に
        // ロックを放すと、その間の current が getInstance で古いもの（まだ登録簿にある）を拾い、停止済みのものを持ち続ける
        val registry = FakeRegistry()
        val entered = CountDownLatch(1)
        val proceed = CountDownLatch(1)
        val holder = holderOf(
            registry,
            beforeRemove = {
                entered.countDown()
                proceed.await(5, TimeUnit.SECONDS)
            },
        )
        val first = holder.current()

        val resetter = thread { runBlocking { holder.reset() } }
        assertTrue(entered.await(5, TimeUnit.SECONDS), "reset が停止の同期の部分に入らない")

        val seen = AtomicReference<FakeClient>()
        val readerStarted = CountDownLatch(1)
        val reader = thread {
            readerStarted.countDown()
            seen.set(holder.current())
        }
        assertTrue(readerStarted.await(5, TimeUnit.SECONDS), "別のスレッドが始まらない")
        // reader が current を呼び終える（誤った実装）か、ロックで待たされる（正しい実装）まで待ってから、reset を先へ進める。
        // 決まった長さの待ち（前は 300ms）に頼らない：負荷でスレッドの始まりが遅れると、reader が current に入る前に reset が登録簿から外し、
        // 誤った実装でも新しいものを拾って緑になる
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (reader.state.let { it != Thread.State.BLOCKED && it != Thread.State.TERMINATED }) {
            assertTrue(System.nanoTime() < deadline, "別のスレッドの current が、終わりもロックで待ちもしない")
            Thread.sleep(1)
        }
        proceed.countDown()
        reader.join(5_000)
        resetter.join(5_000)

        val got = assertNotNull(seen.get(), "別のスレッドの current が戻らない")
        assertNotSame(first, got, "停止するインスタンスを current が返した")
        assertSame(got, holder.current())
    }

    @Test
    fun `停止の同期の部分が失敗しても古いインスタンスは手放し、例外はresetの呼び出し元へ伝える`() {
        val registry = FakeRegistry()
        val holder = holderOf(registry, afterRemove = { throw IllegalStateException("停止の開始に失敗") })
        val first = holder.current()

        runBlocking { assertFailsWith<IllegalStateException> { holder.reset() } }
        val second = holder.current()

        assertNotSame(first, second)
        assertEquals(1, second.configuredCount)
    }

    @Test
    fun `停止の完了待ちが失敗しても古いインスタンスは手放し、例外はresetの呼び出し元へ伝える`() {
        val registry = FakeRegistry()
        val holder = holderOf(registry, awaitShutdown = { throw IllegalStateException("停止に失敗") })
        val first = holder.current()

        runBlocking { assertFailsWith<IllegalStateException> { holder.reset() } }
        val second = holder.current()

        assertNotSame(first, second)
        assertEquals(1, second.configuredCount)
    }
}
