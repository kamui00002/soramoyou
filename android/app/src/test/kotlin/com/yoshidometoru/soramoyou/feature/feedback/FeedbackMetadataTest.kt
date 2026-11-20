// ⭐️ フィードバックに付けるアプリのバージョンと端末情報の形の単体テスト（タスク 30・要件 13.2・13.4）
package com.yoshidometoru.soramoyou.feature.feedback

import com.yoshidometoru.soramoyou.BuildConfig
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * iOS は「1.7.4 (57)」「iOS 18.5 / iPhone」の形で送る（FeedbackViewModel.swift:75-84）。Android は同じ形で、
 * 「バージョン名 (バージョンコード)」「Android {OSの版} / {機種名}」にする（設計書の ModerationRepository・FeedbackRepository の節）。
 * 端末の OS の版・機種名（`Build.VERSION.RELEASE`・`Build.MODEL`）は JVM の単体テストでは値が入らない（Android の部品）ので、
 * 形そのものを純関数で確かめる。実機の値は 33.x で本番の `feedback` を見て確かめる。
 *
 * 値が入らない（どの項目を読んでも「?」になる）ので、個人の情報を含みうる項目を読まないことは、値では確かめられない
 * （レビュー 4 回目 Q27）。そこで FeedbackMetadata.kt が読む `Build` の項目を、ソースの文字列で固定する（コメントの中の項目も数える）。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class FeedbackMetadataTest {

    private val metadataSource = File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/feedback/FeedbackMetadata.kt")

    /** [source] が読む `Build` の項目（`Build.VERSION.RELEASE` は `VERSION.RELEASE`、`Build.MODEL.trim()` は `MODEL`）。`BuildConfig` は含めない。 */
    private fun buildFieldsRead(source: String): Set<String> =
        Regex("""\bBuild\.(VERSION\.\w+|\w+)""").findAll(source).map { it.groupValues[1] }.toSet()

    @Test
    fun `アプリのバージョンは「バージョン名 (バージョンコード)」の形`() {
        assertEquals("1.0.0 (1)", FeedbackMetadata.appVersion("1.0.0", 1))
        assertEquals("2.13.4 (207)", FeedbackMetadata.appVersion("2.13.4", 207))
    }

    @Test
    fun `端末情報は、Androidと OSの版と機種名を、この順に並べた形`() {
        assertEquals("Android 14 / Pixel 8", FeedbackMetadata.deviceInfo("14", "Pixel 8"))
        assertEquals("Android 16 / SM-S931Q", FeedbackMetadata.deviceInfo("16", "SM-S931Q"))
    }

    @Test
    fun `分からない項目は疑問符にする（iOS のバージョンが読めないときと同じ）`() {
        assertEquals("? (3)", FeedbackMetadata.appVersion(null, 3))
        assertEquals("? (3)", FeedbackMetadata.appVersion("  ", 3))
        assertEquals("Android ? / Pixel 8", FeedbackMetadata.deviceInfo(null, "Pixel 8"))
        assertEquals("Android 14 / ?", FeedbackMetadata.deviceInfo("14", ""))
    }

    @Test
    fun `いまのアプリのバージョンは、ビルドの版数から作る`() {
        // ReleaseBuildSettingsTest が、BuildConfig の版数が build.gradle.kts の値と一致することを固定している
        assertEquals("${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", FeedbackMetadata.currentAppVersion())
    }

    @Test
    fun `いまの端末情報は、Androidで始まりOSの版と機種名を区切った形で作る`() {
        // JVM では「Android ? / ?」になるので、ここで見るのは形だけ。読む項目は下のソースの検査で見る
        val info = FeedbackMetadata.currentDeviceInfo()

        assertTrue(info.startsWith("Android "), info)
        assertTrue(" / " in info, info)
    }

    @Test
    fun `いまの端末情報が読む端末の項目は、OSの版と機種名の2つだけ`() {
        assertTrue(metadataSource.isFile, "FeedbackMetadata.kt が見つからない: ${metadataSource.absolutePath}")
        val source = metadataSource.readText()
        val current = source.substringAfter("fun currentDeviceInfo()", missingDelimiterValue = "").substringBefore("\n\n")

        assertTrue(
            "deviceInfo(" in current && "Build.VERSION.RELEASE" in current && "Build.MODEL" in current,
            "いまの端末情報を OS の版と機種名から作っていない: $current",
        )
        assertEquals(
            setOf("VERSION.RELEASE", "MODEL"),
            buildFieldsRead(source),
            "OS の版と機種名のほかに Build の項目を読んでいる（持ち主の名前や端末の識別子を含みうる）",
        )
    }

    @Test
    fun `陽性対照：読むBuildの項目は、取り込み・続けて呼ぶ形でも拾い、BuildConfigは数えない`() {
        val source = """
            import android.os.Build
            import android.os.Build.USER
            fun a() = deviceInfo(Build.VERSION.RELEASE, Build.MODEL.trim())
            fun b() = Build.SERIAL + Build.VERSION.SDK_INT + BuildConfig.VERSION_NAME
        """.trimIndent()

        assertEquals(setOf("USER", "VERSION.RELEASE", "MODEL", "SERIAL", "VERSION.SDK_INT"), buildFieldsRead(source))
    }
}
