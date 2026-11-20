// ⭐️ マニフェストが MainActivity を起動の入口として宣言していることの検査（タスク 8.3）
package com.yoshidometoru.soramoyou

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.w3c.dom.Element

/**
 * ランチャーから起動される Activity が [MainActivity] であること（ApplicationClassManifestTest と同じやり方で、名前は実際のクラスから取る）。
 * 起動の入口は exported="true" でないと、Android 12 以降ではインストールに失敗する。
 */
class MainActivityManifestTest {

    private val namespace = "com.yoshidometoru.soramoyou"

    @Test
    fun `ランチャーの入口はMainActivityでexportedがtrue`() {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(File("src/main/AndroidManifest.xml"))
        val activities = document.documentElement.getElementsByTagName("activity")
        val launchers = (0 until activities.length).map { activities.item(it) as Element }.filter { activity ->
            val actions = activity.getElementsByTagName("action")
            val categories = activity.getElementsByTagName("category")
            (0 until actions.length).any { (actions.item(it) as Element).getAttribute("android:name") == "android.intent.action.MAIN" } &&
                (0 until categories.length).any { (categories.item(it) as Element).getAttribute("android:name") == "android.intent.category.LAUNCHER" }
        }

        assertEquals(1, launchers.size, "ランチャーの入口がちょうど 1 つでない")
        val name = launchers.single().getAttribute("android:name")
        assertEquals(MainActivity::class.java.name, if (name.startsWith(".")) "$namespace$name" else name)
        assertTrue(launchers.single().getAttribute("android:exported") == "true", "入口の exported が true でない")
    }
}
