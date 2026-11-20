// ☁️ OS の既定のネットワークの通知元の差し替え口（タスク 4.3）
package com.yoshidometoru.soramoyou.platform

/**
 * OS の「既定のネットワーク」（アプリの通信が通るネットワーク）の変化を知らせる薄い窓口。
 * 判断は [DefaultNetworkMonitor] に集め、ここは OS を呼ぶだけにする。
 * JVM の単体テストでは偽物に差し替える。本物は [ConnectivityManagerNetworkSource]。
 *
 * ネットワークは OS の `Network` ではなく、その識別子（`Network.getNetworkHandle()` の Long）で表す。
 * 判断の側から Android の型を消し、JVM の単体テストで扱えるようにするため。
 */
interface DefaultNetworkSource {
    /**
     * 既定のネットワークの変化の通知を始める。[listener] は OS のスレッドから呼ばれうる。
     * 登録の時点で既定のネットワークがあれば、その onAvailable も届く。無ければ何も届かない。
     * 失敗したら例外を投げる（権限が無い SecurityException・登録数の上限など）。
     */
    fun register(listener: DefaultNetworkListener)

    /** いまの既定のネットワークの識別子。無ければ null。失敗したら例外を投げる。 */
    fun currentDefaultNetwork(): Long?
}

/** [DefaultNetworkSource] からの通知の受け手。 */
interface DefaultNetworkListener {
    /** [network] が既定のネットワークになった（切り替えのとき、古いネットワークの onLost との順序は保証されていないものとして扱う）。 */
    fun onAvailable(network: Long)

    /** [network] を失った。いまの既定のネットワークとは限らないものとして扱う（切り替えの後に、古いネットワークについて届く場合）。 */
    fun onLost(network: Long)
}
