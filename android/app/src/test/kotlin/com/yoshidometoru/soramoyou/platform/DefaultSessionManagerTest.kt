// ⭐️ ログアウト時に端末内のユーザーのデータを消す処理の単体テスト（タスク 8.2・要件 2.9・2.10・15.7）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.data.remote.write.StorageGateway
import com.yoshidometoru.soramoyou.data.remote.write.WriteGate
import java.util.Collections
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/**
 * [DefaultSessionManager] の単体テスト。各段は偽物で、呼ばれた順を 1 本の記録 [log] に残す。
 */
class DefaultSessionManagerTest {

    /** 呼ばれた順の記録。段の中から別スレッドで書かれても壊れないよう同期した一覧にする。 */
    private val log: MutableList<String> = Collections.synchronizedList(mutableListOf())

    /** 分析の窓口の偽物。識別の設定と、失敗の記録を [log] にも残す。 */
    private inner class OrderedAnalytics : AnalyticsFacade {
        val errors = mutableListOf<Pair<AppError, String>>()
        override fun logEvent(name: EventName, params: Map<String, ParamValue>) = Unit
        override fun logScreen(name: ScreenName) = Unit
        override fun logError(error: AppError, context: String) {
            errors += error to context
            log += "logError:$context"
        }
        override fun setUserId(uid: Uid?) {
            log += "setUserId:${uid?.value}"
        }
    }

    private val analytics = OrderedAnalytics()

    private fun manager(
        imageCache: ImageCacheCleaner = ImageCacheCleaner { log += "imageCache" },
        resetFirestore: suspend () -> Unit = { log += "firestore" },
    ) = DefaultSessionManager(imageCache, resetFirestore, analytics)

    @Test
    fun `登録された状態を全て捨てる`() = runBlocking {
        val manager = manager()
        manager.register { log += "feed" }
        manager.register { log += "likes" }

        manager.clearLocalUserData()

        assertTrue(log.containsAll(listOf("feed", "likes")), "捨てていない状態がある: $log")
    }

    @Test
    fun `画像のキャッシュを消す`() = runBlocking {
        manager().clearLocalUserData()

        assertTrue("imageCache" in log, "画像のキャッシュを消していない: $log")
    }

    @Test
    fun `Firestoreのインスタンスを停止して作り直す`() = runBlocking {
        manager().clearLocalUserData()

        assertTrue("firestore" in log, "Firestore を作り直していない: $log")
    }

    @Test
    fun `分析とCrashlyticsのユーザーの識別を解除する`() = runBlocking {
        manager().clearLocalUserData()

        // Crashlytics の解除は AnalyticsFacade.setUserId(null) が行う（DefaultAnalyticsFacadeTest が確かめている）
        assertTrue("setUserId:null" in log, "識別を解除していない: $log")
    }

    @Test
    fun `状態・画像・Firestoreの順に消し、識別の解除は最後に行う`() = runBlocking {
        val manager = manager()
        manager.register { log += "feed" }

        manager.clearLocalUserData()

        assertEquals(listOf("feed", "imageCache", "firestore", "setUserId:null"), log)
    }

    @Test
    fun `1つの状態の失敗でほかの状態を捨て損ねず、失敗を記録する`() = runBlocking {
        val manager = manager()
        manager.register { throw IllegalStateException("壊れた状態") }
        manager.register { log += "likes" }

        manager.clearLocalUserData()

        assertTrue("likes" in log, "後ろの状態を捨てていない: $log")
        assertEquals(
            listOf<Pair<AppError, String>>(AppError.Unknown("IllegalStateException") to "SessionManager.clearLocalUserData.states"),
            analytics.errors,
        )
    }

    @Test
    fun `画像のキャッシュの消去に失敗しても、Firestoreの作り直しと識別の解除を行い、失敗を記録する`() = runBlocking {
        val manager = manager(imageCache = { throw java.io.IOException("消せない") })

        manager.clearLocalUserData()

        assertEquals(listOf("logError:SessionManager.clearLocalUserData.image_cache", "firestore", "setUserId:null"), log)
        assertEquals(AppError.Unknown("IOException"), analytics.errors.single().first)
    }

    @Test
    fun `Firestoreの作り直しに失敗しても識別を解除し、失敗は識別の解除より前に記録する`() = runBlocking {
        val manager = manager(resetFirestore = { throw IllegalStateException("停止に失敗") })

        manager.clearLocalUserData()

        // 失敗の記録に uid がまだ付くよう、識別の解除より前に記録する
        assertEquals(listOf("imageCache", "logError:SessionManager.clearLocalUserData.firestore", "setUserId:null"), log)
    }

    @Test
    fun `呼び出し元が取り消されても最後まで消す`() = runBlocking {
        val firestoreStarted = CompletableDeferred<Unit>()
        val releaseFirestore = CompletableDeferred<Unit>()
        val manager = manager(
            resetFirestore = {
                firestoreStarted.complete(Unit)
                releaseFirestore.await()
                log += "firestore"
            },
        )

        val job = launch(start = CoroutineStart.UNDISPATCHED) { manager.clearLocalUserData() }
        // 仮実装が Firestore の段を呼ばないとき、ここで永久に止まらないよう時間を区切る（共有のロックを握ったままにしない）
        withTimeout(5_000) { firestoreStarted.await() }
        // Firestore の停止を待っている間に、ログアウトを押した画面が閉じたなどで取り消される
        job.cancel()
        releaseFirestore.complete(Unit)
        withTimeout(5_000) { job.cancelAndJoin() }

        assertEquals(listOf("imageCache", "firestore", "setUserId:null"), log)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `書き込みの入口に依存しない`() {
        // 要件 2.10（プッシュ通知のトークンを含め、ログアウトで users へ書き込まない）。コンストラクタで受け取れないものは呼べない
        val forbidden = setOf(FirestoreWriteGateway::class.java, StorageGateway::class.java, WriteGate::class.java)

        val parameterTypes = DefaultSessionManager::class.java.constructors.flatMap { it.parameterTypes.toList() }

        assertTrue(parameterTypes.isNotEmpty(), "コンストラクタの引数を読めていない")
        assertTrue(parameterTypes.none { type -> forbidden.any { it.isAssignableFrom(type) } }, "書き込みの入口を受け取っている: $parameterTypes")
    }
}
