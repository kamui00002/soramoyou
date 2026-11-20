// ⭐️ バナー広告の読み込みの結果を受け取る部品の単体テスト（タスク 32.2・要件 14.4）
package com.yoshidometoru.soramoyou.feature.ads

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * [BannerLoadTracker] の単体テスト。広告 SDK の View の代わりに文字列を持たせ、読み込みの結果を自分で届ける。
 * 約束は、失敗は畳むだけで外へ投げないこと、最初の結果だけを採ること、画面から外れたら View を 1 回だけ破棄し、
 * 外れた後に届いた結果は無視すること。
 */
class BannerLoadTrackerTest {

    /** 破棄した View の記録。 */
    private val destroyed = mutableListOf<String>()

    /** 記録に残した失敗の理由。 */
    private val failures = mutableListOf<String>()

    private fun tracker() = BannerLoadTracker(view = "view", destroy = { destroyed += it }, reportFailure = { failures += it })

    @Test
    fun `読み込みの結果が届くまでは待機中`() {
        assertEquals(BannerLoad.Pending, tracker().load.value)
    }

    @Test
    fun `広告が読み込めたら、読み込み済みになる`() {
        val tracker = tracker()

        tracker.onLoaded()

        assertEquals(BannerLoad.Loaded, tracker.load.value)
        assertTrue(destroyed.isEmpty(), "表示する View を破棄した: $destroyed")
        assertTrue(failures.isEmpty())
    }

    @Test
    fun `読み込みに失敗したら失敗になり、理由を記録する`() {
        val tracker = tracker()

        tracker.onFailed("no fill")

        assertEquals(BannerLoad.Failed("no fill"), tracker.load.value)
        assertEquals(listOf("no fill"), failures)
    }

    @Test
    fun `最初の結果だけを採る（成功の後の失敗も、失敗の後の成功も無視する）`() {
        val loaded = tracker().also { it.onLoaded(); it.onFailed("late failure") }
        assertEquals(BannerLoad.Loaded, loaded.load.value)

        val failed = tracker().also { it.onFailed("first failure"); it.onLoaded() }
        assertEquals(BannerLoad.Failed("first failure"), failed.load.value)

        // 採らなかった失敗は記録しない（畳む理由は、最初の失敗の 1 件だけ）
        assertEquals(listOf("first failure"), failures)
    }

    @Test
    fun `読み込みの要求が例外を投げても、外へ出さず失敗として畳む`() {
        val tracker = tracker()

        tracker.start { _, _, _ -> throw IllegalStateException("SDK is not initialized") }

        assertEquals(BannerLoad.Failed("読み込みの要求が例外を投げた: IllegalStateException"), tracker.load.value)
        assertEquals(1, failures.size)
    }

    @Test
    fun `startはViewと結果の受け口を渡し、届いた結果を反映する`() {
        var passedView: String? = null
        val ok = tracker().also { it.start { view, onLoaded, _ -> passedView = view; onLoaded() } }
        assertEquals("view", passedView)
        assertEquals(BannerLoad.Loaded, ok.load.value)

        val ng = tracker().also { it.start { _, _, onFailed -> onFailed("network error") } }
        assertEquals(BannerLoad.Failed("network error"), ng.load.value)
    }

    @Test
    fun `画面から外れたら、Viewを1回だけ破棄する`() {
        val tracker = tracker()
        tracker.onLoaded()

        tracker.dispose()
        tracker.dispose()

        assertEquals(listOf("view"), destroyed)
        // 破棄した View を表示し続けない
        assertTrue(tracker.load.value !is BannerLoad.Loaded, "破棄した後も Loaded のまま: ${tracker.load.value}")
    }

    @Test
    fun `画面から外れた後に届いた結果は、無視する`() {
        val tracker = tracker()
        tracker.dispose()

        tracker.onLoaded()
        tracker.onFailed("late failure")

        assertTrue(tracker.load.value !is BannerLoad.Loaded, "外れた後に届いた成功で表示しようとした: ${tracker.load.value}")
        assertTrue(failures.isEmpty(), "外れた後の失敗を記録した: $failures")
    }

    @Test
    fun `Viewの破棄が例外を投げても、外へ出さず記録する`() {
        val tracker = BannerLoadTracker(view = "view", destroy = { throw IllegalStateException("already destroyed") }, reportFailure = { failures += it })

        tracker.dispose()

        assertEquals(1, failures.size, "破棄の失敗を記録していない")
    }

    @Test
    fun `失敗の記録が例外を投げても、外へ出さない`() {
        val tracker = BannerLoadTracker(view = "view", destroy = { destroyed += it }, reportFailure = { throw IllegalStateException("log is broken") })

        tracker.onFailed("no fill")

        assertEquals(BannerLoad.Failed("no fill"), tracker.load.value)
    }
}
