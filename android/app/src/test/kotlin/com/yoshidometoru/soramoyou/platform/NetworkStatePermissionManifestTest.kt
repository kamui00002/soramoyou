// ⭐️ 接続状態の監視に要る権限をアプリ自身のマニフェストで宣言していることの検査（タスク 4.3・要件 16.3）
package com.yoshidometoru.soramoyou.platform

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.w3c.dom.Element

/**
 * [ConnectivityManagerNetworkSource] は `ConnectivityManager.registerDefaultNetworkCallback`・`getActiveNetwork` を呼ぶ。
 * どちらも `ACCESS_NETWORK_STATE` が無いと SecurityException になる。
 *
 * この権限は今も firebase-auth・firebase-firestore のマニフェストから合流して入っている（2026-10-03 の
 * manifest-merger-debug-report.txt で確認）。ただ、それはライブラリの都合で、版を上げたときに消えても気付けない。
 * 自分のコードが直接使う権限なので、アプリのマニフェストに明示して、このテストで固定する。
 *
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/AndroidManifest.xml` を直接読む
 * （[AutomaticScreenReportingManifestTest] と同じやり方）。
 */
class NetworkStatePermissionManifestTest {

    private val manifest = File("src/main/AndroidManifest.xml")

    @Test
    fun `マニフェストでACCESS_NETWORK_STATEの権限を宣言している`() {
        assertTrue(manifest.isFile, "マニフェストが見つからない: ${manifest.absolutePath}")

        val root = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(manifest).documentElement
        val permissions = root.getElementsByTagName("uses-permission")
        val matches = (0 until permissions.length)
            .map { permissions.item(it) as Element }
            .filter { it.getAttribute("android:name") == "android.permission.ACCESS_NETWORK_STATE" }

        assertEquals(1, matches.size, "android.permission.ACCESS_NETWORK_STATE の uses-permission が 1 つではない")
        // <application> の中ではなく、<manifest> の直下に置かれていること（中に書くと権限として扱われない）
        assertEquals("manifest", (matches.single().parentNode as Element).tagName)
    }
}
