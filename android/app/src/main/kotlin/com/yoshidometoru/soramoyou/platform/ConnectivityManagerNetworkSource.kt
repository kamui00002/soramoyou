// ☁️ ConnectivityManager で既定のネットワークの変化を受け取る薄い窓口（タスク 4.3）
package com.yoshidometoru.soramoyou.platform

import android.net.ConnectivityManager
import android.net.Network

/**
 * [DefaultNetworkSource] の本物。ConnectivityManager を呼ぶだけで、判断は持たない（判断は [DefaultNetworkMonitor]）。
 *
 * - 通知は `registerDefaultNetworkCallback`（API 24 以上。minSdk は 26）で受ける。アプリの通信が通る既定のネットワークだけを追い、
 *   既定のネットワークが無いときは何も通知されない。通知は ConnectivityManager の内部のスレッドから届く。
 * - 起動時の読み出しは `getActiveNetwork`（API 23 以上）。どちらも ACCESS_NETWORK_STATE が要る（アプリのマニフェストで宣言している）。
 * - ネットワークの識別子は `Network.getNetworkHandle()`（API 23 以上）。同じネットワークなら同じ値になる。
 *
 * 単体テストの対象外（JVM の単体テストでは android.jar の本体が無いため）。端末での確認はタスク 11.3 の手動の確認で行う。
 */
class ConnectivityManagerNetworkSource(private val connectivityManager: ConnectivityManager) : DefaultNetworkSource {

    override fun register(listener: DefaultNetworkListener) {
        connectivityManager.registerDefaultNetworkCallback(
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    listener.onAvailable(network.networkHandle)
                }

                override fun onLost(network: Network) {
                    listener.onLost(network.networkHandle)
                }
            },
        )
    }

    override fun currentDefaultNetwork(): Long? = connectivityManager.activeNetwork?.networkHandle
}
