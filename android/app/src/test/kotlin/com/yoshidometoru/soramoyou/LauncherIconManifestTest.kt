// ⭐️ ランチャーのアイコンが宣言され、参照先の XML と画像が揃っていることの検査（レビュー R08）
package com.yoshidometoru.soramoyou

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.w3c.dom.Element

/**
 * ランチャーのアイコンの宣言（`<application>` の icon・roundIcon）と、その参照先（適応アイコンの XML・背景の PNG）を
 * ソースとして読んで固定する（MainActivityManifestTest と同じやり方）。作業ディレクトリはモジュール直下（android/app）。
 * 属性だけを見ると、参照先の XML や画像を消しても緑のままなので、参照先まで見る。
 */
class LauncherIconManifestTest {

    private val res = File("src/main/res")

    private fun parse(file: File): Element {
        assertTrue(file.isFile, "ファイルが見つからない: ${file.path}")
        return DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file).documentElement
    }

    private fun application(): Element {
        val applications = parse(File("src/main/AndroidManifest.xml")).getElementsByTagName("application")
        assertEquals(1, applications.length, "<application> がちょうど 1 つでない")
        return applications.item(0) as Element
    }

    @Test
    fun `applicationのiconはmipmapのic_launcherを指す`() {
        assertEquals("@mipmap/ic_launcher", application().getAttribute("android:icon"))
    }

    @Test
    fun `applicationのroundIconはmipmapのic_launcher_roundを指す`() {
        assertEquals("@mipmap/ic_launcher_round", application().getAttribute("android:roundIcon"))
    }

    @Test
    fun `適応アイコンのXMLは背景にic_launcher_backgroundを指し、前景の要素を持つ`() {
        for (name in listOf("ic_launcher.xml", "ic_launcher_round.xml")) {
            val root = parse(File(res, "mipmap-anydpi-v26/$name"))
            assertEquals("adaptive-icon", root.tagName, "$name の根が adaptive-icon でない")
            val backgrounds = root.getElementsByTagName("background")
            assertEquals(1, backgrounds.length, "$name の background がちょうど 1 つでない")
            assertEquals(
                "@mipmap/ic_launcher_background",
                (backgrounds.item(0) as Element).getAttribute("android:drawable"),
                "$name の background の参照先が違う",
            )
            assertEquals(1, root.getElementsByTagName("foreground").length, "$name の foreground がちょうど 1 つでない")
        }
    }

    @Test
    fun `背景のPNGが5つの密度にあり、適応アイコンの大きさの正方形である`() {
        // 適応アイコンの 108dp を各密度の px にしたもの
        val sizes = mapOf("mdpi" to 108, "hdpi" to 162, "xhdpi" to 216, "xxhdpi" to 324, "xxxhdpi" to 432)
        for ((density, size) in sizes) {
            val png = File(res, "mipmap-$density/ic_launcher_background.png")
            assertTrue(png.isFile, "背景の PNG が無い: ${png.path}")
            val bytes = png.readBytes()
            assertTrue(bytes.size >= 24, "PNG として短すぎる: ${png.path}")
            // IHDR の幅（バイト 16〜19）・高さ（20〜23）はビッグエンディアン
            fun int32(offset: Int) =
                ((bytes[offset].toInt() and 0xFF) shl 24) or ((bytes[offset + 1].toInt() and 0xFF) shl 16) or
                    ((bytes[offset + 2].toInt() and 0xFF) shl 8) or (bytes[offset + 3].toInt() and 0xFF)
            assertEquals(size, int32(16), "${png.path} の幅が違う")
            assertEquals(size, int32(20), "${png.path} の高さが違う")
        }
    }
}
