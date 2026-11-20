// ⭐️ 同意の取得と広告 SDK の初期化の、順序と失敗の扱いの単体テスト（タスク 32.1・要件 14.1〜14.4）
package com.yoshidometoru.soramoyou.platform

import java.util.Collections
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield

/**
 * [DefaultAdsController] の単体テスト。UMP と広告 SDK は偽物で、呼ばれた順を 1 本の記録 [log] に残す。
 *
 * 順序の約束（設計書の部品 AdsController・UMP の公式の手順 developers.google.com/admob/android/next-gen/privacy）:
 * 同意の情報の更新 →（更新に成功したら）必要なら同意のフォーム → 広告を要求してよいかの確認 → 広告 SDK の初期化（背景のスレッド）。
 * 更新に失敗しても、前回の起動で得た同意で広告を要求してよいなら初期化する（公式の手順「If an error occurs …」）。
 *
 * start を受け付ける状態の約束（[AdsController.start]・レビュー R22）:
 * 受け付けるのは、未開始（初回）と、前回が「広告を要求してよいと答えなかった」（CANNOT_REQUEST_ADS）で終わったときだけで、
 * そのときは渡された新しい同意の窓口で、同意の情報の更新からやり直す。取得中・初期化中・準備完了・設定の誤り・初期化の失敗・
 * 無効なビルドで来た start は何もしない（画面の作り直しで、同意の取得と広告 SDK の初期化を繰り返さない）。状態ごとに 1 本ずつ確かめる。
 *
 * 同意の段は、渡したスコープ（本番は main）で呼ぶ。テストでは runBlocking のスレッドを main の代わりにし、
 * 初期化だけが別のスレッド（[Dispatchers.Default]）で動くことを確かめる。
 */
class DefaultAdsControllerTest {

    /** 呼ばれた順の記録。初期化は別スレッドから書かれるので、同期した一覧にする。 */
    private val log: MutableList<String> = Collections.synchronizedList(mutableListOf())

    /** 握りつぶした失敗の記録（reportFailure に渡された「どこで」の名前）。 */
    private val failures: MutableList<String> = Collections.synchronizedList(mutableListOf())

    private val developmentConfig =
        AdsConfig(AdsBuildKind.DEVELOPMENT, GoogleTestAdIds.APP_ID, GoogleTestAdIds.BANNER_UNIT_ID)

    /** UMP の偽物。各段の結果を差し替えられる。 */
    private inner class FakeConsent(
        private val update: suspend () -> ConsentStepResult = { ConsentStepResult.Completed },
        private val form: suspend () -> ConsentStepResult = { ConsentStepResult.Completed },
        private val canRequest: () -> Boolean = { true },
    ) : ConsentGateway {
        /** 同意の情報の更新を呼んだスレッド。 */
        @Volatile var updateThread: Thread? = null

        /** 同意の情報の更新を呼んだ回数（どの偽物が呼ばれたかを見分ける）。 */
        @Volatile var updateCalls = 0

        override suspend fun requestConsentInfoUpdate(): ConsentStepResult {
            updateThread = Thread.currentThread()
            updateCalls++
            log += "update"
            return update()
        }

        override suspend fun loadAndShowConsentFormIfRequired(): ConsentStepResult {
            log += "form"
            return form()
        }

        override fun canRequestAds(): Boolean {
            log += "canRequestAds"
            return canRequest()
        }
    }

    /** 広告 SDK の偽物。初期化を呼んだスレッドとアプリ ID を残す。 */
    private inner class FakeSdk(private val block: (String) -> Unit = {}) : MobileAdsInitializer {
        @Volatile var thread: Thread? = null
        @Volatile var appId: String? = null

        override fun initialize(appId: String) {
            thread = Thread.currentThread()
            this.appId = appId
            log += "initialize"
            block(appId)
        }
    }

    /**
     * runBlocking のスレッドで動く、テストごとのスコープで [body] を行う。runBlocking の子にしないので、
     * 偽物が止まったままでもテストが終わらなくなることは無い（最後に取り消す）。
     */
    private fun withControllerScope(body: suspend CoroutineScope.(scope: CoroutineScope) -> Unit) = runBlocking {
        val scope = CoroutineScope(coroutineContext + Job())
        try {
            body(scope)
        } finally {
            scope.cancel()
        }
    }

    private fun controller(
        scope: CoroutineScope,
        sdk: MobileAdsInitializer,
        config: AdsConfig = developmentConfig,
        enabled: Boolean = true,
    ) = DefaultAdsController(
        config = config,
        enabled = enabled,
        sdk = sdk,
        scope = scope,
        background = Dispatchers.Default,
        reportFailure = { where, _ -> failures += where },
    )

    /** 終わりの状態（Ready・Unavailable）になるまで待つ。 */
    private suspend fun AdsController.awaitSettled(): AdsState =
        withTimeout(5_000) { state.first { it is AdsState.Ready || it is AdsState.Unavailable } }

    /** 記録に [entry] が現れるまで、ほかのコルーチンに順番を譲りながら待つ。 */
    private suspend fun awaitLogged(entry: String) = withTimeout(5_000) {
        while (entry !in log) yield()
    }

    @Test
    fun `同意の情報の更新、同意のフォーム、要求の可否の確認、初期化の順に行い、バナーのIDで準備を終える`() = withControllerScope { scope ->
        val sdk = FakeSdk()
        val controller = controller(scope, sdk)

        controller.start(FakeConsent())

        assertEquals(AdsState.Ready(GoogleTestAdIds.BANNER_UNIT_ID), controller.awaitSettled())
        assertEquals(listOf("update", "form", "canRequestAds", "initialize"), log.toList())
        assertEquals(GoogleTestAdIds.APP_ID, sdk.appId, "初期化に渡したアプリ ID が設定の値でない")
        assertTrue(failures.isEmpty(), "失敗が無いのに記録した: $failures")
    }

    @Test
    fun `同意のフォームが閉じられるまで、初期化しない`() = withControllerScope { scope ->
        val formClosed = CompletableDeferred<ConsentStepResult>()
        val sdk = FakeSdk()
        val controller = controller(scope, sdk)

        controller.start(FakeConsent(form = { formClosed.await() }))
        awaitLogged("form")
        // フォームを表示している間は、要求の可否の確認にも初期化にも進まない
        repeat(10) { yield() }
        assertEquals(listOf("update", "form"), log.toList())
        assertNull(sdk.thread, "フォームが閉じられる前に初期化した")
        assertEquals(AdsState.GatheringConsent, controller.state.value)

        formClosed.complete(ConsentStepResult.Completed)

        assertEquals(AdsState.Ready(GoogleTestAdIds.BANNER_UNIT_ID), controller.awaitSettled())
        assertEquals(listOf("update", "form", "canRequestAds", "initialize"), log.toList())
    }

    @Test
    fun `初期化している間は初期化中の状態で、初期化は呼び出し側と別のスレッドで行う`() = withControllerScope { scope ->
        val testThread = Thread.currentThread()
        val release = CompletableDeferred<Unit>()
        val entered = CompletableDeferred<Unit>()
        val sdk = FakeSdk {
            entered.complete(Unit)
            // 終わるまで戻らない SDK の呼び出しの代わり。テストが詰まらないよう、待つのは最大 5 秒
            runBlocking { withTimeout(5_000) { release.await() } }
        }
        val consent = FakeConsent()
        val controller = controller(scope, sdk)

        controller.start(consent)
        withTimeout(5_000) { entered.await() }
        assertEquals(AdsState.Initializing, controller.state.value)
        release.complete(Unit)

        assertEquals(AdsState.Ready(GoogleTestAdIds.BANNER_UNIT_ID), controller.awaitSettled())
        // 同意の段は渡したスコープ（本番は main）のスレッド、初期化はそれ以外のスレッド（main で呼ぶと ANR になりうる）
        assertSame(testThread, consent.updateThread, "同意の情報の更新を、渡したスコープのスレッドで呼んでいない")
        val initThread = assertNotNull(sdk.thread)
        assertNotEquals(testThread, initThread, "初期化を呼び出し側のスレッド（本番は main）で行った")
    }

    @Test
    fun `同意の情報の更新に失敗しても、前回の同意で広告を要求できるならフォームを出さずに初期化し、失敗を記録する`() =
        withControllerScope { scope ->
            val sdk = FakeSdk()
            val controller = controller(scope, sdk)

            controller.start(FakeConsent(update = { ConsentStepResult.Failed(1, "network") }))

            assertEquals(AdsState.Ready(GoogleTestAdIds.BANNER_UNIT_ID), controller.awaitSettled())
            assertEquals(listOf("update", "canRequestAds", "initialize"), log.toList())
            assertEquals(listOf("UMP.requestConsentInfoUpdate"), failures.toList())
        }

    @Test
    fun `同意のフォームの表示に失敗しても、広告を要求できるなら初期化し、失敗を記録する`() = withControllerScope { scope ->
        val sdk = FakeSdk()
        val controller = controller(scope, sdk)

        controller.start(FakeConsent(form = { ConsentStepResult.Failed(2, "form") }))

        assertEquals(AdsState.Ready(GoogleTestAdIds.BANNER_UNIT_ID), controller.awaitSettled())
        assertEquals(listOf("update", "form", "canRequestAds", "initialize"), log.toList())
        assertEquals(listOf("UMP.loadAndShowConsentFormIfRequired"), failures.toList())
    }

    @Test
    fun `同意の段が例外を投げても外へ出さず、失敗を記録して要求の可否で判断する`() = withControllerScope { scope ->
        // 本番のスコープの例外は、外へ出すとアプリが落ちる（広告の失敗で他の操作を妨げない：要件 14.4）
        val sdk = FakeSdk()
        val controller = controller(scope, sdk)

        controller.start(FakeConsent(update = { throw IllegalStateException("UMP の例外の代わり") }))

        assertEquals(AdsState.Ready(GoogleTestAdIds.BANNER_UNIT_ID), controller.awaitSettled())
        assertEquals(listOf("update", "canRequestAds", "initialize"), log.toList())
        assertEquals(listOf("UMP.requestConsentInfoUpdate"), failures.toList())
    }

    @Test
    fun `要求の可否の確認が例外を投げたら、初期化せず広告を出さない状態にする`() = withControllerScope { scope ->
        val sdk = FakeSdk()
        val controller = controller(scope, sdk)

        controller.start(FakeConsent(canRequest = { throw IllegalStateException("UMP の例外の代わり") }))

        assertEquals(AdsState.Unavailable(AdsUnavailableReason.CANNOT_REQUEST_ADS), controller.awaitSettled())
        assertNull(sdk.thread, "要求の可否が分からないのに初期化した")
        assertEquals(listOf("UMP.canRequestAds"), failures.toList())
    }

    @Test
    fun `広告を要求できないなら初期化せず、広告を出さない状態になる`() = withControllerScope { scope ->
        val sdk = FakeSdk()
        val controller = controller(scope, sdk)

        controller.start(FakeConsent(canRequest = { false }))

        assertEquals(AdsState.Unavailable(AdsUnavailableReason.CANNOT_REQUEST_ADS), controller.awaitSettled())
        assertEquals(listOf("update", "form", "canRequestAds"), log.toList())
        assertNull(sdk.thread, "広告を要求できないのに初期化した")
    }

    @Test
    fun `初期化が例外を投げても外へ出さず、広告を出さない状態にして失敗を記録する`() = withControllerScope { scope ->
        val sdk = FakeSdk { throw IllegalStateException("初期化の失敗の代わり") }
        val controller = controller(scope, sdk)

        controller.start(FakeConsent())

        assertEquals(AdsState.Unavailable(AdsUnavailableReason.INITIALIZATION_FAILED), controller.awaitSettled())
        assertEquals(listOf("MobileAds.initialize"), failures.toList())
    }

    @Test
    fun `すぐ続けて呼んだstartは、1本目が走り出す前でも2本目を始めない（受け付けは呼んだその場で決める）`() = withControllerScope { scope ->
        val sdk = FakeSdk()
        val controller = controller(scope, sdk)

        controller.start(FakeConsent())
        controller.start(FakeConsent())
        controller.awaitSettled()
        // 2 回目の start の分が走る余地を与えてから数える
        repeat(10) { yield() }

        assertEquals(1, log.count { it == "update" }, "同意の情報の更新を 2 回行った: $log")
        assertEquals(1, log.count { it == "initialize" }, "初期化を 2 回行った: $log")
    }

    @Test
    fun `広告を要求できないで終わった後のstartは、同意の情報の更新からやり直し、要求できるなら初期化して準備を終える`() = withControllerScope { scope ->
        val sdk = FakeSdk()
        val controller = controller(scope, sdk)
        // 1 回目：インストール直後にオフラインで開いた（更新に失敗し、要求してよいとも答えない）
        controller.start(FakeConsent(update = { ConsentStepResult.Failed(1, "offline") }, canRequest = { false }))
        assertEquals(AdsState.Unavailable(AdsUnavailableReason.CANNOT_REQUEST_ADS), controller.awaitSettled())
        assertNull(sdk.thread, "要求できないのに初期化した")

        // 2 回目：接続が戻って開き直した
        controller.start(FakeConsent())

        assertEquals(AdsState.Ready(GoogleTestAdIds.BANNER_UNIT_ID), controller.awaitSettled())
        assertEquals(2, log.count { it == "update" }, "同意の情報の更新が 2 回でない: $log")
        assertEquals(1, log.count { it == "initialize" }, "初期化が 1 回でない: $log")
    }

    @Test
    fun `やり直しのstartは、渡された新しい同意の窓口を使い、古い方を呼ばない`() = withControllerScope { scope ->
        val controller = controller(scope, FakeSdk())
        val first = FakeConsent(canRequest = { false })
        val second = FakeConsent()
        controller.start(first)
        assertEquals(AdsState.Unavailable(AdsUnavailableReason.CANNOT_REQUEST_ADS), controller.awaitSettled())
        assertEquals(1, first.updateCalls)

        controller.start(second)

        assertEquals(AdsState.Ready(GoogleTestAdIds.BANNER_UNIT_ID), controller.awaitSettled())
        assertEquals(1, second.updateCalls, "新しい窓口を使っていない")
        assertEquals(1, first.updateCalls, "古い窓口をもう一度呼んだ")
    }

    @Test
    fun `同意の取得の途中で来たstartは、2本目を始めない`() = withControllerScope { scope ->
        val release = CompletableDeferred<ConsentStepResult>()
        val controller = controller(scope, FakeSdk())
        val first = FakeConsent(update = { release.await() })
        val second = FakeConsent()
        controller.start(first)
        awaitLogged("update")
        assertEquals(AdsState.GatheringConsent, controller.state.value)

        controller.start(second)
        repeat(10) { yield() }

        assertEquals(1, log.count { it == "update" }, "取得の途中で 2 本目を始めた: $log")
        assertEquals(0, second.updateCalls, "取得の途中で来た窓口を使った")
        release.complete(ConsentStepResult.Completed)
        assertEquals(AdsState.Ready(GoogleTestAdIds.BANNER_UNIT_ID), controller.awaitSettled())
        assertEquals(1, log.count { it == "update" })
    }

    @Test
    fun `初期化中に来たstartは何もしない（初期化を2回呼ばない）`() = withControllerScope { scope ->
        val release = CompletableDeferred<Unit>()
        val entered = CompletableDeferred<Unit>()
        val controller = controller(
            scope,
            FakeSdk {
                entered.complete(Unit)
                // 終わるまで戻らない SDK の呼び出しの代わり。テストが詰まらないよう、待つのは最大 5 秒
                runBlocking { withTimeout(5_000) { release.await() } }
            },
        )
        val second = FakeConsent()
        // 途中の assert が失敗しても、背景のスレッドで止めた初期化を放す（放さないと、そのスレッドを最大 5 秒塞ぐ）
        try {
            controller.start(FakeConsent())
            withTimeout(5_000) { entered.await() }
            assertEquals(AdsState.Initializing, controller.state.value)

            controller.start(second)
            repeat(10) { yield() }

            assertEquals(0, second.updateCalls, "初期化の途中で来た窓口を使った")
            assertEquals(1, log.count { it == "update" }, "初期化の途中で同意の取得をやり直した: $log")
            assertEquals(AdsState.Initializing, controller.state.value, "初期化の途中で来たstartで状態が変わった")
            release.complete(Unit)
            assertEquals(AdsState.Ready(GoogleTestAdIds.BANNER_UNIT_ID), controller.awaitSettled())
            assertEquals(1, log.count { it == "initialize" }, "初期化を 2 回行った: $log")
        } finally {
            release.complete(Unit)
        }
    }

    @Test
    fun `準備を終えた後のstartは何もしない`() = withControllerScope { scope ->
        val controller = controller(scope, FakeSdk())
        controller.start(FakeConsent())
        assertEquals(AdsState.Ready(GoogleTestAdIds.BANNER_UNIT_ID), controller.awaitSettled())

        controller.start(FakeConsent())
        repeat(10) { yield() }

        assertEquals(AdsState.Ready(GoogleTestAdIds.BANNER_UNIT_ID), controller.state.value)
        assertEquals(1, log.count { it == "update" }, "準備を終えた後に同意の情報の更新をした: $log")
        assertEquals(1, log.count { it == "initialize" }, "準備を終えた後に初期化した: $log")
    }

    @Test
    fun `設定の誤りで終わった後のstartは何もしない`() = withControllerScope { scope ->
        val controller = controller(scope, FakeSdk(), config = AdsConfig(AdsBuildKind.PRODUCTION_TRACK, "", ""))
        controller.start(FakeConsent())
        assertEquals(AdsState.Unavailable(AdsUnavailableReason.MISCONFIGURED), controller.awaitSettled())

        controller.start(FakeConsent())
        repeat(10) { yield() }

        assertEquals(AdsState.Unavailable(AdsUnavailableReason.MISCONFIGURED), controller.state.value)
        assertTrue(log.isEmpty(), "設定が誤っているのに同意の取得か初期化を行った: $log")
        assertEquals(listOf("AdsConfig"), failures.toList(), "設定の誤りの記録が 1 回でない")
    }

    @Test
    fun `初期化の失敗で終わった後のstartは何もしない`() = withControllerScope { scope ->
        val controller = controller(scope, FakeSdk { throw IllegalStateException("初期化の失敗の代わり") })
        controller.start(FakeConsent())
        assertEquals(AdsState.Unavailable(AdsUnavailableReason.INITIALIZATION_FAILED), controller.awaitSettled())

        controller.start(FakeConsent())
        repeat(10) { yield() }

        assertEquals(AdsState.Unavailable(AdsUnavailableReason.INITIALIZATION_FAILED), controller.state.value)
        assertEquals(1, log.count { it == "initialize" }, "初期化の失敗の後に初期化をやり直した: $log")
        assertEquals(1, log.count { it == "update" }, "初期化の失敗の後に同意の取得をやり直した: $log")
    }

    @Test
    fun `IDがビルドの種類に合わないなら、同意の取得も初期化も行わず、失敗を記録する`() = withControllerScope { scope ->
        // 本番トラック用のビルドで本番の ID が未設定（空）のとき
        val sdk = FakeSdk()
        val controller = controller(scope, sdk, config = AdsConfig(AdsBuildKind.PRODUCTION_TRACK, "", ""))

        controller.start(FakeConsent())

        assertEquals(AdsState.Unavailable(AdsUnavailableReason.MISCONFIGURED), controller.awaitSettled())
        repeat(10) { yield() }
        assertTrue(log.isEmpty(), "設定が誤っているのに同意の取得か初期化を行った: $log")
        assertEquals(listOf("AdsConfig"), failures.toList())
    }

    @Test
    fun `広告を出さないマイルストーンのビルドでは、最初から無効で、startしても何もしない`() = withControllerScope { scope ->
        val sdk = FakeSdk()
        val controller = controller(scope, sdk, enabled = false)
        assertEquals(AdsState.Disabled, controller.state.value)

        controller.start(FakeConsent())
        repeat(10) { yield() }

        assertEquals(AdsState.Disabled, controller.state.value)
        assertTrue(log.isEmpty(), "無効なビルドで同意の取得か初期化を行った: $log")
        assertTrue(failures.isEmpty(), "無効なのは失敗ではないのに記録した: $failures")
    }

    @Test
    fun `startの前は未開始の状態`() = withControllerScope { scope ->
        assertEquals(AdsState.NotStarted, controller(scope, FakeSdk()).state.value)
    }
}
