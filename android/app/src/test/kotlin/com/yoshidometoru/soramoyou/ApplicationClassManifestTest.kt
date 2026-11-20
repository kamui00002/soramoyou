// ⭐️ マニフェストがアプリの Application クラスを指していることの検査（タスク 5.1・要件 1.2）
package com.yoshidometoru.soramoyou

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.w3c.dom.Element

/**
 * 依存の組み立て（AppContainer）と Firebase・PostHog の初期化は、[SoramoyouApplication] の起動時に 1 回だけ行う。
 * マニフェストの `<application android:name>` がこのクラスを指していないと、OS は既定の Application を作り、
 * 組み立ても初期化も行われない（ビルドは通るので気付けない）。クラス名の変更にも追従するよう、名前は実際のクラスから取る。
 *
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/AndroidManifest.xml` を直接読む
 * （AutomaticScreenReportingManifestTest と同じやり方）。
 */
class ApplicationClassManifestTest {

    private val manifest = File("src/main/AndroidManifest.xml")

    /** build.gradle.kts の namespace。マニフェストの「.」で始まる名前は、これを前に付けて解釈される。 */
    private val namespace = "com.yoshidometoru.soramoyou"

    @Test
    fun `マニフェストのapplicationはSoramoyouApplicationを指す`() {
        assertTrue(manifest.isFile, "マニフェストが見つからない: ${manifest.absolutePath}")

        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(manifest)
        val application = assertNotNull(
            document.documentElement.getElementsByTagName("application").item(0) as Element?,
            "<application> が無い",
        )

        val name = application.getAttribute("android:name")
        val resolved = if (name.startsWith(".")) "$namespace$name" else name
        assertEquals(SoramoyouApplication::class.java.name, resolved, "<application android:name> が SoramoyouApplication を指していない")
    }
}
