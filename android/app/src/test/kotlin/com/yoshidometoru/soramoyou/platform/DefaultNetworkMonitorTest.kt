// ⭐️ ネットワークの接続状態の監視（DefaultNetworkMonitor）の単体テスト（タスク 4.3・要件 16.3）
package com.yoshidometoru.soramoyou.platform

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * OS の既定のネットワークの通知元を偽物（[FakeDefaultNetworkSource]）に差し替え、接続の有無の判断だけを確かめる。
 *
 * iOS 版には、接続の有無を常時監視する部品が無い（`NWPathMonitor`・`import Network` は 0 件。
 * iOS は失敗した後のエラーを ErrorStateView.swift `ErrorType.from`（:63-72）で「ネットワーク」に分類するだけ）。
 * そのため、ここで確かめる振る舞いは iOS から写したものではなく、設計書の NetworkMonitor（`isOnline: StateFlow<Boolean>`）と
 * Android の `ConnectivityManager.registerDefaultNetworkCallback` の通知の仕方から決めたもの。
 *
 * 判断の方針は「迷ったらオンライン」（fail-open）。オフラインの間は再試行を無効にする設計なので（設計書 NetworkMonitor・共通UI）、
 * 誤ってオフラインと判断するとユーザーが操作できなくなる。誤ってオンラインと判断しても、通信が失敗してエラーと再試行が出るだけで済む。
 */
class DefaultNetworkMonitorTest {

    /**
     * [DefaultNetworkSource] の偽物。登録された受け手を持ち、テストから OS の通知を模して呼ぶ。
     *
     * @param snapshot 起動時の「いまの既定のネットワーク」を返す。中で通知を送れば、読み出し中に通知が届く競合を再現できる
     * @param registerFailure 登録で投げる例外（null なら登録は成功する）
     */
    private class FakeDefaultNetworkSource(
        private val snapshot: () -> Long? = { null },
        private val registerFailure: Exception? = null,
    ) : DefaultNetworkSource {
        var listener: DefaultNetworkListener? = null

        override fun register(listener: DefaultNetworkListener) {
            registerFailure?.let { throw it }
            this.listener = listener
        }

        override fun currentDefaultNetwork(): Long? = snapshot()

        fun available(network: Long) = checkNotNull(listener) { "受け手が登録されていない" }.onAvailable(network)
        fun lost(network: Long) = checkNotNull(listener) { "受け手が登録されていない" }.onLost(network)
    }

    private class FailureLog {
        val entries = mutableListOf<Pair<String, Exception>>()
        val report: (String, Exception) -> Unit = { where, e -> entries += where to e }
    }

    // ---- 起動時の状態 ----

    @Test
    fun `起動時に既定のネットワークがあればオンライン`() {
        val monitor = DefaultNetworkMonitor(FakeDefaultNetworkSource(snapshot = { 1L }))

        assertTrue(monitor.isOnline.value)
    }

    @Test
    fun `起動時に既定のネットワークが無ければオフライン`() {
        // 既定のネットワークが無いと、registerDefaultNetworkCallback は何も通知しない。起動時の読み出しだけが頼りになる
        val monitor = DefaultNetworkMonitor(FakeDefaultNetworkSource(snapshot = { null }))

        assertFalse(monitor.isOnline.value, "既定のネットワークが無いのにオンラインになっている")
    }

    // ---- 接続が切れる・戻る ----

    @Test
    fun `既定のネットワークを失うとオフラインになり、新しい既定のネットワークが来るとオンラインに戻る`() {
        val source = FakeDefaultNetworkSource(snapshot = { 1L })
        val monitor = DefaultNetworkMonitor(source)
        source.available(1L)

        source.lost(1L)
        assertFalse(monitor.isOnline.value, "既定のネットワークを失ったのにオンラインのまま")

        source.available(2L)
        assertTrue(monitor.isOnline.value, "新しい既定のネットワークが来たのにオフラインのまま")
    }

    @Test
    fun `既定のネットワークが切り替わり、古いネットワークのonLostが後から届いてもオンラインのまま`() {
        // Wi-Fi（1）からモバイル通信（2）への切り替えで、2 の onAvailable の後に 1 の onLost が届く順序。
        // 通知の順序は保証されていないものとして扱い、逆順は次のテストで確かめる
        val source = FakeDefaultNetworkSource(snapshot = { 1L })
        val monitor = DefaultNetworkMonitor(source)
        val seen = mutableListOf<Boolean>()

        source.available(1L)
        seen += monitor.isOnline.value
        source.available(2L)
        seen += monitor.isOnline.value
        source.lost(1L)
        seen += monitor.isOnline.value

        assertEquals(listOf(true, true, true), seen, "いまの既定ではないネットワークの onLost でオフラインになった")
    }

    @Test
    fun `切り替えでonLostが先に届いた場合は、いったんオフラインになり新しい既定のネットワークでオンラインに戻る`() {
        val source = FakeDefaultNetworkSource(snapshot = { 1L })
        val monitor = DefaultNetworkMonitor(source)
        val seen = mutableListOf<Boolean>()

        source.available(1L)
        seen += monitor.isOnline.value
        source.lost(1L)
        seen += monitor.isOnline.value
        source.available(2L)
        seen += monitor.isOnline.value

        assertEquals(listOf(true, false, true), seen)
    }

    // ---- 起動時の読み出しと通知の競合 ----

    @Test
    fun `起動時の読み出し中に接続の通知が届いたら、読み出した古い「無し」で上書きしない`() {
        // 読み出しが「無し」を返した直後に、別スレッドで onAvailable が届いた場合を再現する
        lateinit var source: FakeDefaultNetworkSource
        source = FakeDefaultNetworkSource(snapshot = {
            source.available(1L)
            null
        })

        val monitor = DefaultNetworkMonitor(source)

        assertTrue(monitor.isOnline.value, "通知より古い起動時の読み出しで、オフラインに上書きされた")
    }

    @Test
    fun `起動時の読み出し中に切断の通知が届いたら、読み出した古い「有り」で上書きしない`() {
        // 読み出しが 1 を返す間に、1 の onAvailable と onLost が届いた（読み出した値はもう古い）場合を再現する
        lateinit var source: FakeDefaultNetworkSource
        source = FakeDefaultNetworkSource(snapshot = {
            source.available(1L)
            source.lost(1L)
            1L
        })

        val monitor = DefaultNetworkMonitor(source)

        assertFalse(monitor.isOnline.value, "通知より古い起動時の読み出しで、オンラインに上書きされた")
    }

    // ---- 失敗の握りつぶし（fail-open） ----

    @Test
    fun `通知の登録に失敗したら、例外を外へ出さずオンラインのままにし、失敗を報告する`() {
        // 登録の失敗（権限が無い・登録数の上限など）では以後の通知が来ない。起動時の読み出しで「無し」にすると、
        // 接続が戻っても二度とオンラインに戻れず再試行できなくなるので、読み出しは当てずにオンラインのままにする
        val failure = SecurityException("ACCESS_NETWORK_STATE が無い")
        val log = FailureLog()

        val monitor = DefaultNetworkMonitor(
            FakeDefaultNetworkSource(snapshot = { null }, registerFailure = failure),
            reportFailure = log.report,
        )

        assertTrue(monitor.isOnline.value, "登録に失敗したのにオフラインになった（以後、戻る手段が無い）")
        assertEquals(listOf<Pair<String, Exception>>("DefaultNetworkSource.register" to failure), log.entries)
    }

    @Test
    fun `起動時の読み出しに失敗しても例外を外へ出さず、オンラインから始めて以後の通知で判断する`() {
        val failure = IllegalStateException("読み出しの失敗")
        val log = FailureLog()
        val source = FakeDefaultNetworkSource(snapshot = { throw failure })

        val monitor = DefaultNetworkMonitor(source, reportFailure = log.report)

        assertTrue(monitor.isOnline.value)
        assertEquals(listOf<Pair<String, Exception>>("DefaultNetworkSource.currentDefaultNetwork" to failure), log.entries)

        source.available(1L)
        source.lost(1L)
        assertFalse(monitor.isOnline.value, "登録は成功しているので、以後の通知で判断できるはず")
    }

    @Test
    fun `失敗の報告の差し込み口自体が失敗しても、例外を外へ出さない`() {
        val monitor = DefaultNetworkMonitor(
            FakeDefaultNetworkSource(registerFailure = IllegalStateException("登録の失敗")),
            reportFailure = { _, _ -> throw IllegalStateException("報告の失敗") },
        )

        assertTrue(monitor.isOnline.value)
    }

    @Test
    fun `isOnlineは読み取り専用で、外から書き換えられない`() {
        val monitor = DefaultNetworkMonitor(FakeDefaultNetworkSource(snapshot = { 1L }))

        // MutableStateFlow をそのまま公開すると、画面側から接続状態を書き換えられてしまう
        assertFalse(monitor.isOnline is MutableStateFlow<*>, "isOnline が MutableStateFlow のまま公開されている")
    }
}
