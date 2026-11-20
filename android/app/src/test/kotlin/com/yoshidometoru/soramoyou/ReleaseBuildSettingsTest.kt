// ⭐️ リリースビルドの版数・ターゲット API・難読化・署名鍵の置き場の設定の検査（タスク 34.1・要件 1.6・18.2・18.7・18.8）
package com.yoshidometoru.soramoyou

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * リリースビルドの設定を、ファイルの中身と `BuildConfig` で固定する（BuildConfigWriteGateTest と同じやり方）。
 * 単体テストは本番向けの debug（prodDebug）で走り、作業ディレクトリはモジュール直下（android/app）。
 *
 * - 版数（versionCode・versionName）は app/build.gradle.kts に実際の値で 1 回だけ書き（Gradle の設定や環境変数から読む形にしない）、
 *   ビルドの `BuildConfig` がその値と一致する（変種や接尾辞で別の値にしていない）。iOS で、コマンドラインで版数を上げて台帳とずれた教訓
 *   （設計書「リリース手順の設計」）。なお、AGP 9.4.1 はコマンドラインの `-Pandroid.injected.version.code=…`・`…version.name=…` を
 *   APK にも `BuildConfig` にも反映しない（2026-10-13 に、付けて組み立てた prodDebug の APK が versionCode='1'・versionName='1.0.0' の
 *   ままであることを aapt2 で確認）。残る経路（値を設定から読む形・変種や接尾辞で別の値にする形）を下の 2 つのテストで止める
 * - ターゲット API は 36（要件 18.2・設計書 Q11）
 * - release は R8 で難読化し、Crashlytics へ対応表を上げる（設計書 Security Considerations）
 * - 実行時に型の名前を記録に使う所があるので、R8 の規則が例外のクラスの名前を残す
 * - R8 の規則が Log.v・d・i の呼び出しを消し、端末の確認で数える自前の 2 行はそれで消えない Log.w で出す（レビュー R12）
 * - 署名鍵とその場所の設定は Git の管理外（要件 1.6・18.8）
 *
 * 鍵が無いときに release の組み立てだけが止まること・鍵があれば署名されることは、Gradle で実際に組み立てて確かめる
 * （単体テストからは AGP の組み立てを動かせないため。tasks.md の 34.1 の記録を参照）。
 */
class ReleaseBuildSettingsTest {

    private val buildFile = File("build.gradle.kts")
    private val proguardRules = File("proguard-rules.pro")
    private val gitignore = File("../../.gitignore")
    private val mainSources = File("src/main/kotlin")

    /** app/build.gradle.kts の本文。 */
    private fun buildScript(): String {
        assertTrue(buildFile.isFile, "app/build.gradle.kts が見つからない: ${buildFile.absolutePath}")
        return buildFile.readText()
    }

    /** [name] に代入している右辺を全て返す（行頭の `name = 右辺` の形。versionNameSuffix などの別の名前は拾わない）。 */
    private fun assignments(name: String): List<String> =
        Regex("""^\s*$name\s*=\s*(.+?)\s*$""", RegexOption.MULTILINE)
            .findAll(buildScript())
            .map { it.groupValues[1] }
            .toList()

    @Test
    fun `versionCodeはbuild_gradle_ktsに整数の値で1回だけ書かれ、BuildConfigがその値と一致する`() {
        val values = assignments("versionCode")
        assertEquals(1, values.size, "versionCode の代入が 1 か所ではない: $values")
        val literal = values.single()
        // 値を Gradle の設定や環境変数から読む形にすると、コマンドラインで上書きできてしまうので、整数の値だけを認める
        assertTrue(literal.matches(Regex("""[1-9]\d*""")), "versionCode が整数の値で書かれていない: $literal")
        assertEquals(literal.toInt(), BuildConfig.VERSION_CODE, "ビルドの versionCode が build.gradle.kts の値と違う（変種などで別の値にしている）")
    }

    @Test
    fun `versionNameはbuild_gradle_ktsに文字列の値で1回だけ書かれ、BuildConfigがその値と一致する`() {
        val values = assignments("versionName")
        assertEquals(1, values.size, "versionName の代入が 1 か所ではない: $values")
        val literal = values.single()
        val name = Regex(""""(\d+\.\d+\.\d+)"""").matchEntire(literal)?.groupValues?.get(1)
        assertTrue(name != null, "versionName が「数.数.数」の文字列の値で書かれていない: $literal")
        // 本番向けの変種（prod）には接尾辞を付けない（検証用の emulator だけが -emulator を付ける）
        assertEquals(name, BuildConfig.VERSION_NAME, "ビルドの versionName が build.gradle.kts の値と違う（接尾辞などで別の値にしている）")
    }

    @Test
    fun `ターゲットAPIは36`() {
        assertEquals(listOf("36"), assignments("targetSdk"), "targetSdk が 36 の 1 か所ではない")
    }

    @Test
    fun `releaseはR8で難読化し、Crashlyticsへ対応表を上げる`() {
        val script = buildScript()
        assertEquals(listOf("true"), assignments("isMinifyEnabled"), "isMinifyEnabled = true が 1 か所ではない")
        // 既定の規則は最適化つきのもの（AGP 9 は最適化なしの proguard-android.txt を受け付けない）と、アプリの規則のファイル
        assertTrue(
            Regex("""proguardFiles\(\s*getDefaultProguardFile\("proguard-android-optimize\.txt"\)\s*,\s*"proguard-rules\.pro"\s*\)""")
                .containsMatchIn(script),
            "release が既定の規則（proguard-android-optimize.txt）とアプリの規則（proguard-rules.pro）を読んでいない",
        )
        assertTrue(proguardRules.isFile, "アプリの R8 の規則のファイルが無い: ${proguardRules.absolutePath}")
        assertEquals(listOf("true"), assignments("mappingFileUploadEnabled"), "Crashlytics への対応表のアップロードが有効になっていない")
    }

    @Test
    fun `例外の型名を記録に使う所があり、R8の規則が例外のクラスの名前を残す`() {
        // AppError.Unknown に例外の型名（javaClass.simpleName）を載せ、error_occurred の説明として送る。
        // Crashlytics の対応表はスタックトレースしか元に戻さないので、名前が難読化されると「a」などが届いて読めない
        val hits = mainSources.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { TYPE_NAME_IN_ERROR.containsMatchIn(it.readText()) }
            .map { it.relativeTo(mainSources).invariantSeparatorsPath }
            .toList()
        // 走査が何も拾わないときは、走査の形が古くなったか、型名を使う所が無くなった（規則が要るかを見直す）
        assertTrue(hits.isNotEmpty(), "例外の型名を記録に使う所が見つからない（規則が要るかを見直す）")
        assertTrue(KEEP_THROWABLE_NAMES in ruleLines(), "proguard-rules.pro が例外のクラスの名前を残していない（使う所: $hits）")
    }

    @Test
    fun `R8の規則がCrashlyticsのスタックトレースの行番号を残す`() {
        assertTrue(KEEP_LINE_NUMBERS in ruleLines(), "proguard-rules.pro がファイル名と行番号を残していない")
    }

    @Test
    fun `R8の規則が、リリースでLogのv・d・iの呼び出しを消す`() {
        // リリースの Logcat に Log.v・d・i を出さない（レビュー R12）
        assertTrue(STRIP_VERBOSE_LOGS in ruleLines(), "proguard-rules.pro に Log.v・d・i の呼び出しを消す規則が無い")
    }

    @Test
    fun `端末の確認で数える自前の2行は、R8の規則で消えないLogのwで出す`() {
        // 規則で消える Log.i のままだと、release の Logcat で数える「0 件」が「消したから 0」の空の緑になる
        val signals = listOf(
            File(mainSources, "com/yoshidometoru/soramoyou/di/AppContainer.kt") to "\"アカウント文書を補った: \$outcome\"",
            File(mainSources, "com/yoshidometoru/soramoyou/SoramoyouApplication.kt") to "\"Firebase の接続先: \$projectId（本番）\"",
        )
        for ((file, message) in signals) {
            assertTrue(file.isFile, "ソースが見つからない: ${file.absolutePath}")
            val source = file.readText()
            assertTrue("Log.w(LOG_TAG, $message)" in source, "${file.name} の $message が Log.w で出ていない")
            for (level in listOf("v", "d", "i")) {
                assertFalse("Log.$level(LOG_TAG, $message)" in source, "${file.name} の $message が規則で消える Log.$level で出ている")
            }
        }
    }

    @Test
    fun `署名鍵とその場所の設定はGitの管理外`() {
        assertTrue(gitignore.isFile, "リポジトリの .gitignore が見つからない: ${gitignore.absolutePath}")
        val lines = gitignore.readLines().map { it.trim() }
        for (entry in listOf("android/keystore.properties", "*.jks", "*.keystore")) {
            assertTrue(entry in lines, ".gitignore に $entry が無い")
        }
    }

    /**
     * 広い写真の権限の検査（verifyNoBroadMediaPermission）が、assemble と AAB の前段（package…Bundle）の両方に配線されている（レビュー R24）。
     * 同じ文字列は別の検査（verifyReleaseBuildInputs）にもあるので、ファイル全体ではなく、この検査を登録した所から
     * 配線の行（dependsOn(task) の行）までだけを切り出して見る。
     */
    @Test
    fun `広い写真の権限の検査はassembleとpackageBundleの両方に配線されている`() {
        val script = buildScript()
        val start = script.indexOf("tasks.register(\"verifyNoBroadMediaPermission")
        assertTrue(start >= 0, "verifyNoBroadMediaPermission の登録が見つからない")
        val wiringEnd = script.indexOf("configureEach { dependsOn(task) }", start)
        assertTrue(wiringEnd >= 0, "verifyNoBroadMediaPermission の配線（configureEach { dependsOn(task) }）が見つからない")
        // 登録から配線の行の終わりまで。その最後の行が配線の行（tasks.matching { … }.configureEach { dependsOn(task) }）
        val wiringLine = script.substring(start, wiringEnd).lines().last()
        assertTrue(wiringLine.contains("tasks.matching"), "配線の行が tasks.matching で始まっていない: $wiringLine")
        assertTrue(wiringLine.contains("it.name == \"assemble\$variantName\""), "配線に assemble が無い: $wiringLine")
        assertTrue(wiringLine.contains("it.name == \"package\${variantName}Bundle\""), "配線に package…Bundle（AAB の前段）が無い: $wiringLine")
    }

    /** proguard-rules.pro の、コメントと空行を除いた行（前後の空白を除く）。 */
    private fun ruleLines(): List<String> {
        assertTrue(proguardRules.isFile, "アプリの R8 の規則のファイルが無い: ${proguardRules.absolutePath}")
        return proguardRules.readLines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }
    }

    private companion object {
        /** 記録に例外の型名を載せる書き方（`AppError.Unknown(e.javaClass.simpleName)` と `AppError.Unknown(javaClass.simpleName)`）。 */
        val TYPE_NAME_IN_ERROR = Regex("""AppError\.Unknown\(\s*(?:\w+\.)?javaClass\.simpleName\s*\)""")

        /** 例外のクラスの名前だけを残す規則（使われないクラスの削除と最適化は止めない）。 */
        const val KEEP_THROWABLE_NAMES = "-keepnames class * extends java.lang.Throwable"

        /** スタックトレースのファイル名と行番号を残す規則（Firebase の公式の手順）。 */
        const val KEEP_LINE_NUMBERS = "-keepattributes SourceFile,LineNumberTable"

        /** Log.v・d・i の呼び出しを消す規則（副作用なしとして、戻り値を使わない呼び出しを R8 が取り除く）。1 行で書く。 */
        const val STRIP_VERBOSE_LOGS =
            "-assumenosideeffects class android.util.Log { public static int v(...); public static int d(...); public static int i(...); }"
    }
}
