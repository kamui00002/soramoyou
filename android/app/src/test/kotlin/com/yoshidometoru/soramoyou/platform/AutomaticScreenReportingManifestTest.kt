// ⭐️ Firebase Analytics の自動の画面計測を無効にしていることの検査（タスク 4.1・要件 15.4）
package com.yoshidometoru.soramoyou.platform

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.w3c.dom.Element

/**
 * 画面表示は、iOS 版と同じく PostHog に 4 つの画面名だけを手動で送る（LoggingService.swift:47-50）。
 * Firebase Analytics が Activity 単位で画面を自動計測すると、iOS に無い `screen_view` が Android からだけ届き、
 * 両 OS を同じ物差しで比べられなくなる。そこで、マニフェストの meta-data で自動計測を切る（設計書 Q10）。
 *
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/AndroidManifest.xml` を直接読む。
 * 陽性対照：マニフェストから meta-data を消すと、このテストが「1 つではない（0 件）」で落ちることを確かめた（2026-10-03）。
 * meta-data を <service> の中へ動かすと、親の検査で落ちることも確かめた（2026-11-05）。
 */
class AutomaticScreenReportingManifestTest {

    private val manifest = File("src/main/AndroidManifest.xml")

    @Test
    fun `マニフェストのapplicationでFirebaseの自動の画面計測をfalseにしている`() {
        assertTrue(manifest.isFile, "マニフェストが見つからない: ${manifest.absolutePath}")

        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(manifest)
        val application = assertNotNull(
            document.documentElement.getElementsByTagName("application").item(0) as Element?,
            "<application> が無い",
        )

        val metaData = application.getElementsByTagName("meta-data")
        val matches = (0 until metaData.length)
            .map { metaData.item(it) as Element }
            .filter { it.getAttribute("android:name") == "google_analytics_automatic_screen_reporting_enabled" }

        assertEquals(1, matches.size, "google_analytics_automatic_screen_reporting_enabled の meta-data が 1 つではない")
        val entry = matches.single()
        // <service> などの中ではなく、<application> の直下に置く（入れ子の meta-data はアプリの値として読まれない）
        assertEquals("application", (entry.parentNode as Element).tagName)
        assertEquals("false", entry.getAttribute("android:value"))
    }
}
