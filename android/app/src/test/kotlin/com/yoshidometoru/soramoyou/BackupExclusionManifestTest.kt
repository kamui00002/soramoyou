// ⭐️ アプリのデータを、クラウドのバックアップにも機種変更の引き継ぎ（端末間の移行）にも載せないことの検査（レビュー R13）
package com.yoshidometoru.soramoyou

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.w3c.dom.Element

/**
 * アプリのデータを、クラウドのバックアップにも端末間の移行にも載せない（2026-11-05 の利用者の決定・設計書の Security Considerations）。
 *
 * マニフェストの `<application>` の `android:allowBackup="false"`（Android 11 以下）と、`android:dataExtractionRules` が指す規則
 * （Android 12 以降。機種によっては allowBackup="false" でも端末間の移行が止まらない）を、ソースとして読んで固定する
 * （LauncherIconManifestTest と同じやり方）。作業ディレクトリはモジュール直下（android/app）。
 * aapt2 は規則の XML の要素名を確かめない（綴りを間違えても組み立てが通る）ので、要素名と領域を文書どおりに固定する。
 * 出典：developer.android.com の「Back up user data with Auto Backup」の「XML config syntax」。
 */
class BackupExclusionManifestTest {

    /** 文書の文法にある領域の全部。root だけで他の領域まで覆えるかは文書から言い切れないので、全部を除く */
    private val allDomains = setOf(
        "root", "file", "database", "sharedpref", "external",
        "device_root", "device_file", "device_database", "device_sharedpref",
    )

    private fun parse(file: File): Element {
        assertTrue(file.isFile, "ファイルが見つからない: ${file.path}")
        return DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file).documentElement
    }

    private fun application(): Element {
        val applications = parse(File("src/main/AndroidManifest.xml")).getElementsByTagName("application")
        assertEquals(1, applications.length, "<application> がちょうど 1 つでない")
        return applications.item(0) as Element
    }

    private fun rules(): Element = parse(File("src/main/res/xml/data_extraction_rules.xml"))

    @Test
    fun `applicationのallowBackupはfalseである`() {
        assertEquals("false", application().getAttribute("android:allowBackup"))
    }

    @Test
    fun `applicationのdataExtractionRulesはxmlのdata_extraction_rulesを指し、その根はdata-extraction-rulesである`() {
        assertEquals("@xml/data_extraction_rules", application().getAttribute("android:dataExtractionRules"))
        assertEquals("data-extraction-rules", rules().tagName, "規則の根が Android 12 以降の書式でない")
    }

    @Test
    fun `クラウドのバックアップと端末間の移行の両方で、含める規則を持たず、文書の9つの領域を全部除く`() {
        val root = rules()
        for (section in listOf("cloud-backup", "device-transfer")) {
            val nodes = root.getElementsByTagName(section)
            // 節が無いと、その経路は全部有効になる（文書）
            assertEquals(1, nodes.length, "<$section> がちょうど 1 つでない")
            val element = nodes.item(0) as Element
            assertEquals(root, element.parentNode, "<$section> が根の直下にない")
            // include を 1 つでも書くと「書いたものだけを含める」に意味が変わる
            assertEquals(0, element.getElementsByTagName("include").length, "<$section> に include がある")
            val excludes = element.getElementsByTagName("exclude").let { list ->
                (0 until list.length).map { list.item(it) as Element }
            }
            assertEquals(allDomains, excludes.map { it.getAttribute("domain") }.toSet(), "<$section> が除く領域が文書の 9 種と一致しない")
            for (exclude in excludes) {
                assertEquals(".", exclude.getAttribute("path"), "<$section> の ${exclude.getAttribute("domain")} が領域の全体（.）を除いていない")
            }
        }
    }
}
