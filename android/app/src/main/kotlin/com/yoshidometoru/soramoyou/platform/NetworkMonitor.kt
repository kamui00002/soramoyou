// ⭐️ ネットワークの接続状態の監視（タスク 4.3・要件 16.3）
package com.yoshidometoru.soramoyou.platform

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * 接続の有無を常に公開する窓口（設計書の部品 NetworkMonitor）。
 *
 * 画面は [isOnline] を集め、false のあいだは「接続できない」旨と再試行を表示し、true に戻ったら再試行を有効にする（要件 16.3）。
 * 「オフラインになった」は true→false、「接続が戻った」は false→true の変化として届く。
 * StateFlow は同じ値を続けて流さないので、ネットワークの切り替えなどで同じ状態が重なっても画面への通知は増えない。
 */
interface NetworkMonitor {
    /** 既定のネットワークがあれば true。判断できないときも true（[DefaultNetworkMonitor] の fail-open を参照）。 */
    val isOnline: StateFlow<Boolean>
}

/**
 * [NetworkMonitor] の実装。OS の既定のネットワークの通知（[DefaultNetworkSource]）から、接続の有無を判断する。
 *
 * iOS 版に、接続の有無を常時監視する部品は無い（`NWPathMonitor`・`import Network` は 0 件。iOS は失敗した後のエラーを
 * ErrorStateView.swift `ErrorType.from`（:63-72）で「ネットワーク」に分類するだけ）。ここでの判断は設計書と Android の通知の仕方から決めた。
 *
 * 判断の規則:
 * - 「既定のネットワーク」があればオンライン。既定のネットワークは常に INTERNET の能力を持つ。インターネットへの到達を
 *   OS が確かめ終えたこと（NET_CAPABILITY_VALIDATED）までは求めない（下の fail-open と同じ理由）。
 * - onLost は、いまの既定のネットワークについてのものだけを受け取る。既定のネットワークの切り替え（Wi-Fi→モバイル通信など）で、
 *   古いネットワークの onLost が新しいネットワークの onAvailable の後に届いても、オフラインにしないため
 *   （通知の順序や、古いネットワークの onLost が届くかどうかは、保証されていないものとして扱う）。
 * - 既定のネットワークが無いと、OS は登録しても何も通知しない。そこで登録の後に、いまの既定のネットワークを 1 回読み出して初期値にする。
 *   ただし読み出しの最中に通知が届いていたら、読み出した値の方が古いので当てない（通知は別のスレッドから届く）。
 *
 * 迷ったらオンラインにする（fail-open）。オフラインのあいだは再試行を無効にする設計なので、誤ってオフラインと判断すると
 * ユーザーが操作できなくなる。誤ってオンラインと判断しても、通信が失敗してエラーと再試行が出るだけで済む。
 * - 通知の登録に失敗したら、オンラインのまま動かさない。以後の通知が来ないので、読み出した「無し」を当てると二度と戻れない。
 * - 読み出しに失敗したら、オンラインから始めて以後の通知で判断する。
 * 失敗は外へ出さず、[DefaultCrashReporter] と同じ形で「通知元.操作」の名前と例外を [reportFailure] に渡す。
 *
 * 通知の登録は、作った時点で行う（アプリの寿命と同じだけ生きる部品として、依存の組み立てで 1 回だけ作る想定。登録の解除は持たない）。
 * 作った後で始める形にすると、始め忘れたときにずっとオンラインのまま気付けないため。
 *
 * @param reportFailure 握りつぶした失敗を Logcat などへ出すための差し込み口。既定は何もしない（JVM の単体テストでは Log を使えないため）。
 */
class DefaultNetworkMonitor(
    source: DefaultNetworkSource,
    private val reportFailure: (String, Exception) -> Unit = { _, _ -> },
) : NetworkMonitor {

    /** 下の 2 つの状態を、OS の通知のスレッドと作った側のスレッドの間で守る。 */
    private val lock = Any()

    /** いまの既定のネットワークの識別子。無ければ null。 */
    private var current: Long? = null

    /** 登録の後に通知を 1 件でも受けたか。受けていたら、起動時に読み出した値は古いので当てない。 */
    private var notified = false

    private val online = MutableStateFlow(true)
    override val isOnline: StateFlow<Boolean> = online.asStateFlow()

    private val listener = object : DefaultNetworkListener {
        override fun onAvailable(network: Long) = synchronized(lock) {
            notified = true
            current = network
            publish()
        }

        override fun onLost(network: Long) = synchronized(lock) {
            notified = true
            // いまの既定ではないネットワークの onLost（切り替えの後で届く古いもの）は無視する
            if (current == network) current = null
            publish()
        }
    }

    init {
        // 状態と受け手を全て用意してから登録する（登録した直後から、別のスレッドで通知が届きうる）
        val registered = guarded("DefaultNetworkSource.register") { source.register(listener) }
        if (registered) {
            var snapshot: Long? = null
            val read = guarded("DefaultNetworkSource.currentDefaultNetwork") { snapshot = source.currentDefaultNetwork() }
            if (read) {
                synchronized(lock) {
                    if (!notified) {
                        current = snapshot
                        publish()
                    }
                }
            }
        }
    }

    /** いまの状態を公開する。lock を持った状態で呼ぶ。 */
    private fun publish() {
        online.value = current != null
    }

    /** [block] の失敗（Exception）を握りつぶして [reportFailure] に渡し、成功したかを返す。差し込み口自体の失敗も外へ出さない。 */
    private inline fun guarded(where: String, block: () -> Unit): Boolean =
        try {
            block()
            true
        } catch (e: Exception) {
            try {
                reportFailure(where, e)
            } catch (ignored: Exception) {
                // 失敗の報告の失敗は、どこにも出しようがないので捨てる（判断はオンラインのままにする）
            }
            false
        }
}
