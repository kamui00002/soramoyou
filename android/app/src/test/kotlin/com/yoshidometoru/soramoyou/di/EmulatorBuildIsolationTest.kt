// ⭐️ 検証用ビルド（emulator）が本番へ届かない構成であることの単体テスト（タスク 11.1・要件 1.3）
package com.yoshidometoru.soramoyou.di

import com.yoshidometoru.soramoyou.BuildConfig
import com.yoshidometoru.soramoyou.contract.rules.StorageDownloadUrl
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.w3c.dom.Element

/**
 * 「エミュレータにだけ接続し、本番へ到達できないことが構成上明らか」（タスク 11.1）を、ファイルの中身で固定する。
 * 単体テストは本番向けの変種（prodDebug）で走るので、本番側の値もここで確かめる。
 *
 * - 検証用の google-services.json は `demo-` で始まるプロジェクト ID を持つ。`demo-` は Firebase が本物のプロジェクトに
 *   割り当てない予約の接頭辞で、エミュレータ以外へは繋がらない
 * - 本番向けの変種では、エミュレータへ向ける旗が立っていない
 * - エミュレータへ向ける呼び出し（useEmulator）は、依存を組み立てる 1 か所（AppContainer）にしかない
 * - 検証用の変種では、Firebase Analytics と Crashlytics の収集を切っている（PostHog は AppContainer が初期化しない）
 * - リポジトリの firebase.json は Android の作業では変えない。`android/tools/start-firebase-emulators.sh` は、一時ディレクトリに
 *   firebase.json と rules の写しを置いて起動する（リポジトリの firebase.json に emulators の設定が無く、
 *   Auth のエミュレータが起動しなかったので作った。CLI は設定のディレクトリより上の rules を読まない：2026-10-05 に実測。タスク 17.1）。
 *   スクリプトのポートとアプリの宛先を一致させる
 * - rules の写しは `android/tools/make-emulator-rules.sh` が作る（レビュー R14）。storage.rules は原本のまま、firestore.rules は
 *   画像の URL の形に、Android のエミュレータの Storage の URL の形（契約の `StorageDownloadUrl.EMULATOR_PATTERN`）を 1 行だけ足す。
 *   ここでは、その形の宛先（住所・ポート・バケット）がアプリの宛先と検証用の google-services.json に合うことと、起動スクリプトが
 *   起動の前に写しの台本を呼ぶことを確かめる（写しの中身は EmulatorRulesCopyTest が確かめる）
 * - その後、iOS 版の作業（main の ec3428f6・2026-10-06）がリポジトリの firebase.json に emulators の設定（auth・firestore・storage の
 *   ポート）を足した。リポジトリの firebase.json で起動しても黙って食い違わないよう、そのポートもアプリの宛先と一致させる
 *   （2026-11-06 に main を取り込んで気づいた。それまでは「emulators の設定が無い」ことを確かめ、足されたら考え直す仕掛けにしていた）
 */
class EmulatorBuildIsolationTest {

    /** :app のディレクトリ（単体テストの作業ディレクトリ）。 */
    private val appDir = File(requireNotNull(System.getProperty("user.dir")))

    private val emulatorGoogleServices = File(appDir, "src/emulator/google-services.json")
    private val emulatorManifest = File(appDir, "src/emulator/AndroidManifest.xml")
    private val firebaseJson = File(appDir, "../../firebase.json")
    private val startScript = File(appDir, "../tools/start-firebase-emulators.sh")
    private val mainSources = File(appDir, "src/main/kotlin")

    @Test
    fun `検証用のgoogle-servicesはdemo-のプロジェクトだけを指し、本番のプロジェクトIDを含まない`() {
        assertTrue(emulatorGoogleServices.isFile, "検証用の google-services.json が無い: ${emulatorGoogleServices.path}")
        val text = emulatorGoogleServices.readText()
        val projectId = Regex(""""project_id"\s*:\s*"([^"]*)"""").find(text)?.groupValues?.get(1)
        assertEquals(FirebaseEmulator.PROJECT_ID, projectId)
        assertTrue(FirebaseEmulator.PROJECT_ID.startsWith("demo-"), "検証用のプロジェクト ID が demo- で始まらない")
        assertFalse(FirebaseProjectCheck.PRODUCTION_PROJECT_ID in text, "検証用の google-services.json に本番のプロジェクト ID がある")
    }

    @Test
    fun `本番向けの変種ではエミュレータへ向けない`() {
        assertFalse(BuildConfig.USE_FIREBASE_EMULATOR)
    }

    @Test
    fun `useEmulatorを呼ぶのはAppContainerだけ`() {
        val hits = mainSources.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { USE_EMULATOR.containsMatchIn(it.readText()) }
            .map { it.relativeTo(mainSources).invariantSeparatorsPath }
            .toList()
        assertEquals(listOf(FirebaseInstanceCreationScanner.ALLOWED_PATH), hits)
    }

    @Test
    fun `検証用の変種ではFirebase AnalyticsとCrashlyticsの収集を切る`() {
        assertTrue(emulatorManifest.isFile, "検証用の AndroidManifest.xml が無い: ${emulatorManifest.path}")
        val metaData = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(emulatorManifest)
            .getElementsByTagName("meta-data")
        // <application> の直下の meta-data だけを読む（<service> などの中の meta-data はアプリの値として読まれない）
        val values = (0 until metaData.length)
            .map { metaData.item(it) as Element }
            .filter { (it.parentNode as Element).tagName == "application" }
            .associate { it.getAttribute("android:name") to it.getAttribute("android:value") }
        assertEquals("true", values["firebase_analytics_collection_deactivated"])
        assertEquals("false", values["firebase_crashlytics_collection_enabled"])
    }

    @Test
    fun `リポジトリのfirebase_jsonのemulatorsのポートはCLIの既定と同じで、アプリの宛先と一致する`() {
        assertTrue(firebaseJson.isFile, "リポジトリの firebase.json が無い: ${firebaseJson.path}")
        val text = firebaseJson.readText()
        // 最上位にも "firestore" があるので、emulators の設定の塊だけを切り出してからポートを読む
        val emulators = jsonObjectOf(text, "emulators")
        assertEquals(APP_PORTS, emulatorPorts(emulators), "firebase.json の emulators のポートがアプリの宛先と一致しない")
        assertEquals(CLI_DEFAULT_PORTS, APP_PORTS)
        assertTrue(""""rules": "firestore.rules"""" in text, "firebase.json の Firestore の rules がリポジトリのファイルを指していない")
        assertTrue(""""rules": "storage.rules"""" in text, "firebase.json の Storage の rules がリポジトリのファイルを指していない")
    }

    @Test
    fun `起動スクリプトは検証用のプロジェクトIDで起動し、ポートがアプリの宛先と一致する`() {
        assertTrue(startScript.isFile, "起動スクリプトが無い: ${startScript.path}")
        val text = startScript.readText()
        assertEquals(APP_PORTS, emulatorPorts(jsonObjectOf(text, "emulators")), "起動スクリプトの emulators のポートがアプリの宛先と一致しない")
        assertTrue("--project ${FirebaseEmulator.PROJECT_ID}" in text, "起動スクリプトが検証用のプロジェクト ID で起動していない")
    }

    @Test
    fun `起動スクリプトはWORKを作った後、エミュレータの起動より前にrulesの写しの台本を呼ぶ`() {
        val lines = startScriptCodeLines()
        val copy = lines.indexOf(MAKE_RULES_CALL)
        assertTrue(copy >= 0, "起動スクリプトが rules の写しの台本を呼んでいない")
        val mktemp = lines.indexOfFirst { it.startsWith("WORK=\$(mktemp") }
        val start = lines.indexOfFirst { it.startsWith("firebase emulators:start") }
        assertTrue(mktemp >= 0, "WORK を作る行が無い")
        assertTrue(start >= 0, "エミュレータを起動する行が無い")
        assertTrue(mktemp < copy, "rules の写しの台本を WORK の作成より前に呼んでいる")
        assertTrue(copy < start, "rules の写しの台本をエミュレータの起動より後に呼んでいる")
    }

    @Test
    fun `写しに足すエミュレータのURLの形は、アプリの宛先と検証用のバケットを指す`() {
        val text = emulatorGoogleServices.readText()
        val bucket = assertNotNull(Regex(""""storage_bucket"\s*:\s*"([^"]*)"""").find(text)?.groupValues?.get(1), "検証用の google-services.json に storage_bucket が無い")
        // 正規表現の中の . は [.] と書く（rules の書き方に合わせる）
        fun literal(s: String) = s.replace(".", "[.]")
        val prefix = "http://${literal(FirebaseEmulator.HOST)}:${FirebaseEmulator.STORAGE_PORT}/v0/b/${literal(bucket)}/o/"
        assertTrue(StorageDownloadUrl.EMULATOR_PATTERN.startsWith(prefix), "エミュレータの URL の形が宛先と合わない: $prefix")
        // 宛先より後ろ（名前とクエリ）は本番の形と同じ
        assertEquals(prefix + StorageDownloadUrl.NAME_AND_QUERY, StorageDownloadUrl.EMULATOR_PATTERN)
    }

    /**
     * [json] の中の `"[key]": { … }` の塊（対応する閉じ括弧まで）。無ければ失敗させる。
     * 文字列の中の括弧も数える（firebase.json と起動スクリプトの JSON の文字列には括弧が無い）。
     */
    private fun jsonObjectOf(json: String, key: String): String {
        val start = assertNotNull(Regex(""""$key"\s*:\s*\{""").find(json), "$key の設定が無い（アプリの宛先と突き合わせ直す）")
        var depth = 0
        for (i in start.range.last until json.length) {
            when (json[i]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return json.substring(start.range.last, i + 1)
            }
        }
        error("$key の設定の閉じ括弧が無い")
    }

    /** [emulators]（emulators の設定の塊）の中の、auth・firestore・storage の `"port"` の値（無ければ null）。 */
    private fun emulatorPorts(emulators: String): Triple<Int?, Int?, Int?> {
        fun port(name: String): Int? =
            Regex(""""$name"\s*:\s*\{[^{}]*?"port"\s*:\s*(\d+)""").find(emulators)?.groupValues?.get(1)?.toInt()
        return Triple(port("auth"), port("firestore"), port("storage"))
    }

    /** 起動スクリプトの、コメント行（# で始まる行）と空行を除いた行。コメントに書いた文字列で緑にならないようにする。 */
    private fun startScriptCodeLines(): List<String> {
        assertTrue(startScript.isFile, "起動スクリプトが無い: ${startScript.path}")
        return startScript.readLines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }
    }

    @Test
    fun `起動スクリプトはStorageの置き場を専用にするためTMPDIRをWORKの下へ向ける`() {
        val lines = startScriptCodeLines()
        assertTrue("export TMPDIR=\"\$WORK/tmp\"" in lines, "起動スクリプトが TMPDIR を WORK の下へ向けていない")
    }

    @Test
    fun `起動スクリプトのTMPDIRの切り替えはWORKの作成より後でエミュレータの起動より前にある`() {
        val lines = startScriptCodeLines()
        val export = lines.indexOf("export TMPDIR=\"\$WORK/tmp\"")
        // export が無い場合は別のテストが赤になるので、ここでは順番だけを見る
        if (export < 0) return
        val mktemp = lines.indexOfFirst { it.startsWith("WORK=\$(mktemp") }
        val start = lines.indexOfFirst { it.startsWith("firebase emulators:start") }
        assertTrue(mktemp >= 0, "WORK を作る行が無い")
        assertTrue(start >= 0, "エミュレータを起動する行が無い")
        assertTrue(mktemp < export, "TMPDIR の切り替えが WORK の作成より前にある")
        assertTrue(export < start, "TMPDIR の切り替えがエミュレータの起動より後にある")
    }

    @Test
    fun `起動スクリプトは専用のTMPDIRを切り替える前にそのディレクトリを作る`() {
        val lines = startScriptCodeLines()
        val mkdir = lines.indexOf("mkdir \"\$WORK/tmp\"")
        assertTrue(mkdir >= 0, "専用の TMPDIR のディレクトリを作る行が無い")
        val export = lines.indexOf("export TMPDIR=\"\$WORK/tmp\"")
        if (export >= 0) assertTrue(mkdir < export, "ディレクトリを作る前に TMPDIR を切り替えている")
    }

    private companion object {
        /** エミュレータへ向ける呼び出し。 */
        val USE_EMULATOR = Regex("""\.\s*useEmulator\s*\(""")

        /** 起動スクリプトが rules の写しを作る台本を呼ぶ行（リポジトリの根と一時ディレクトリを渡す）。 */
        const val MAKE_RULES_CALL = "zsh \"\$ROOT/android/tools/make-emulator-rules.sh\" \"\$ROOT\" \"\$WORK\""

        /**
         * Firebase CLI の既定のポート（auth・firestore・storage）。firestore の 8080 は firebase-tools 15.0.0 で起動して REST で確かめた。
         * auth の 9099・storage の 9199 は Firebase の公式の既定値（2026-10-08 に起動スクリプトの設定で起動し、auth の登録を REST で確かめた）。
         */
        val CLI_DEFAULT_PORTS = Triple(9099, 8080, 9199)

        /** アプリの宛先（auth・firestore・storage）。 */
        val APP_PORTS = Triple<Int?, Int?, Int?>(FirebaseEmulator.AUTH_PORT, FirebaseEmulator.FIRESTORE_PORT, FirebaseEmulator.STORAGE_PORT)
    }
}
