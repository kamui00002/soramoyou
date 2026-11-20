// ⭐️ UMP が読む AdMob のアプリ ID を、ビルドが差し込む値でマニフェストに置いていることの検査（タスク 32.1・要件 14.2・14.3）
package com.yoshidometoru.soramoyou.platform

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.w3c.dom.Element

/**
 * UMP（同意の取得）は、マニフェストの `com.google.android.gms.ads.APPLICATION_ID` のアプリ ID に結びついた同意のメッセージを出す
 * （developers.google.com/admob/android/next-gen/privacy「Add the application ID」）。広告 SDK（Next-Gen）は同じ ID を初期化の引数で受け取る。
 *
 * 2 か所の値が食い違わないよう、マニフェストには値を直書きせず、app/build.gradle.kts がビルドの種類で選んだ値（`admobAppId`）を差し込む。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/AndroidManifest.xml` を直接読む
 * （[NetworkStatePermissionManifestTest] と同じやり方）。
 */
class AdMobAppIdManifestTest {

    private val manifest = File("src/main/AndroidManifest.xml")

    @Test
    fun `applicationの直下に、ビルドが差し込むアプリIDのmeta-dataが1つある`() {
        assertTrue(manifest.isFile, "マニフェストが見つからない: ${manifest.absolutePath}")
        val root = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(manifest).documentElement
        val application = assertNotNull(root.getElementsByTagName("application").item(0) as Element?, "<application> が無い")

        val metaData = application.getElementsByTagName("meta-data")
        val matches = (0 until metaData.length)
            .map { metaData.item(it) as Element }
            .filter { it.getAttribute("android:name") == "com.google.android.gms.ads.APPLICATION_ID" }

        assertEquals(1, matches.size, "com.google.android.gms.ads.APPLICATION_ID の meta-data が 1 つではない")
        val entry = matches.single()
        // <service> などの中ではなく、<application> の直下に置く（入れ子の meta-data はアプリの値として読まれない）
        assertEquals("application", (entry.parentNode as Element).tagName)
        assertEquals("\${admobAppId}", entry.getAttribute("android:value"), "アプリ ID を直書きしている（ビルドの種類で切り替わらない）")
    }
}
