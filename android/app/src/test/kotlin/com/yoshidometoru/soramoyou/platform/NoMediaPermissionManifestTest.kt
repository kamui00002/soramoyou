// ⭐️ 写真を選ぶために、端末内の画像全体への読み取り権限を求めていないことの単体テスト（タスク 16.3・要件 6.2）
package com.yoshidometoru.soramoyou.platform

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.w3c.dom.Element

/**
 * アイコン（と後の投稿）の写真は、システムの写真選択画面（フォトピッカー）で選ぶので、画像を読む権限は要らない。
 * 権限の宣言を足すと、Google Play の写真と動画の権限のポリシーの審査の対象になるうえ、要件 6.2 に反する。
 *
 * 見るのは :app の `src/main/AndroidManifest.xml`（ライブラリが足す宣言は含まない。端末での最終の確認は 11 の手動の確認で行う）。
 */
class NoMediaPermissionManifestTest {

    private val manifest = File("src/main/AndroidManifest.xml")

    /** 陽性対照のための一時的な Manifest の置き場。 */
    private val fixtureRoot: File = createTempDirectory("media-permission").toFile()

    @AfterTest
    fun deleteFixtures() {
        fixtureRoot.deleteRecursively()
    }

    /** [file] が宣言している権限のうち、画像の読み取りに当たるもの。 */
    private fun mediaPermissionsIn(file: File): List<String> {
        val root = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file).documentElement
        val permissions = root.getElementsByTagName("uses-permission")
        return (0 until permissions.length)
            .map { (permissions.item(it) as Element).getAttribute("android:name") }
            .filter { it in MEDIA_PERMISSIONS }
    }

    @Test
    fun `画像の読み取りの権限を宣言していない`() {
        assertTrue(manifest.isFile, "Manifest が見つからない: ${manifest.absolutePath}")

        assertEquals(emptyList(), mediaPermissionsIn(manifest))
    }

    @Test
    fun `陽性対照：画像の読み取りの権限を宣言すると検出する`() {
        val bad = File(fixtureRoot, "AndroidManifest.xml").apply {
            writeText(
                """
                <manifest xmlns:android="http://schemas.android.com/apk/res/android">
                    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
                    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
                    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
                    <uses-permission android:name="android.permission.READ_MEDIA_VISUAL_USER_SELECTED" />
                </manifest>
                """.trimIndent(),
            )
        }

        assertEquals(MEDIA_PERMISSIONS, mediaPermissionsIn(bad))
    }

    private companion object {
        /** 画像の読み取りに当たる権限（全部の画像・旧来のストレージ・Android 14 の「選んだ写真だけ」）。 */
        val MEDIA_PERMISSIONS = listOf(
            "android.permission.READ_MEDIA_IMAGES",
            "android.permission.READ_EXTERNAL_STORAGE",
            "android.permission.READ_MEDIA_VISUAL_USER_SELECTED",
        )
    }
}
