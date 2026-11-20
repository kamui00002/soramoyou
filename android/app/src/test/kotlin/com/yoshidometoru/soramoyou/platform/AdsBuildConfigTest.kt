// ⭐️ ビルドに焼き込んだ広告の ID と、gradle.properties の広告の設定の単体テスト（タスク 32.1・要件 14.2・14.3）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.BuildConfig
import java.io.File
import java.util.Properties
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * app/build.gradle.kts → `BuildConfig.ADS_BUILD_KIND`・`ADMOB_APP_ID`・`ADMOB_BANNER_UNIT_ID` の流れと、gradle.properties の広告の設定を確かめる。
 *
 * ⚠️ JVM の単体テストは debug ビルド（prodDebug）でしか動かさないので、ここで観測できるのは「開発用のビルドがテスト用の ID を焼き込む」ことだけ。
 * リリースビルドの切り替え（CLOSED_TEST はテスト用・PRODUCTION_TRACK は本番の ID・本番の ID が未設定ならビルドを止める）は、
 * Gradle で release の BuildConfig とマニフェストを作って確かめる（タスク 32.1 の記録）。切り替えの表そのものは [AdsConfigTest] が確かめる。
 *
 * iOS 版の ID と同じでないこと（要件 14.2）は、[PostHogSetupTest] と同じく iOS のソースを読んで確かめる。値はメッセージに出さない。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）。
 */
class AdsBuildConfigTest {

    private val gradleProperties = File("../gradle.properties")

    private fun properties(): Properties {
        assertTrue(gradleProperties.isFile, "gradle.properties が見つからない: ${gradleProperties.absolutePath}")
        return Properties().apply { gradleProperties.reader(Charsets.UTF_8).use { load(it) } }
    }

    /**
     * gradle.properties の本番のアプリ ID と広告ユニット ID（前後の空白を除いた値。未設定・キーが無いなら空）。
     * 3 つのテストで同じ読み方をするので、ここ 1 か所にまとめる（キーの名前を変えたときに、直す場所を 1 つにするため）。
     */
    private fun productionIds(properties: Properties): Pair<String, String> =
        properties.getProperty("soramoyou.admobProductionAppId").orEmpty().trim() to
            properties.getProperty("soramoyou.admobProductionBannerUnitId").orEmpty().trim()

    /** iOS 版のアプリ ID（Info.plist の GADApplicationIdentifier）とバナーの広告ユニット ID（AdService.swift の bannerAdUnitID）。 */
    private fun iosIds(): List<String> {
        val ios = File(System.getProperty("user.dir"), "../../Soramoyou/Soramoyou")
        val plist = File(ios, "Info.plist")
        val adService = File(ios, "Services/AdService.swift")
        assertTrue(plist.isFile, "iOS 版の Info.plist が見つからない: ${plist.canonicalPath}")
        assertTrue(adService.isFile, "iOS 版の AdService.swift が見つからない: ${adService.canonicalPath}")
        val appId = assertNotNull(
            Regex("""<key>GADApplicationIdentifier</key>\s*<string>([^<]+)</string>""").find(plist.readText())?.groupValues?.get(1),
            "iOS 版の GADApplicationIdentifier が見つからない（書き方が変わった可能性）",
        )
        val bannerUnitId = assertNotNull(
            Regex("""bannerAdUnitID\s*=\s*"([^"]+)"""").find(adService.readText())?.groupValues?.get(1),
            "iOS 版の bannerAdUnitID の定義が見つからない（書き方が変わった可能性）",
        )
        return listOf(appId, bannerUnitId)
    }

    @Test
    fun `単体テストの変種はdebugで、開発用の種類とGoogleのテスト用のIDを焼き込んでいる`() {
        assertEquals("debug", BuildConfig.BUILD_TYPE, "単体テストの変種が debug でない（このテストの前提が崩れた）")
        assertEquals("DEVELOPMENT", BuildConfig.ADS_BUILD_KIND)
        // 公表されている値を書き下す（Gradle とアプリの定数の両方が変わっても気づけるように）
        assertEquals("ca-app-pub-3940256099942544~3347511713", BuildConfig.ADMOB_APP_ID)
        assertEquals("ca-app-pub-3940256099942544/6300978111", BuildConfig.ADMOB_BANNER_UNIT_ID)
    }

    @Test
    fun `焼き込んだ設定は、このビルドの種類に合っている`() {
        val config = AdsConfig.fromBuildConfig(BuildConfig.ADS_BUILD_KIND, BuildConfig.ADMOB_APP_ID, BuildConfig.ADMOB_BANNER_UNIT_ID)
        assertNull(adsConfigProblem(config))
    }

    @Test
    fun `gradle_propertiesのリリースビルドの広告の種類は、クローズドテストか本番トラックで、本番トラックなら本番のIDがある`() {
        val properties = properties()
        val track = assertNotNull(properties.getProperty("soramoyou.adsTrack"), "gradle.properties に soramoyou.adsTrack が無い")
        assertTrue(track == "CLOSED_TEST" || track == "PRODUCTION_TRACK", "soramoyou.adsTrack の値が想定外: $track")
        val (appId, bannerUnitId) = productionIds(properties)
        if (track == "PRODUCTION_TRACK") {
            assertNull(
                adsConfigProblem(AdsConfig(AdsBuildKind.PRODUCTION_TRACK, appId, bannerUnitId)),
                "本番トラックなのに、本番の ID が未設定か誤っている",
            )
        }
    }

    @Test
    fun `本番のIDを入れたら、形が正しくテスト用でない（未設定の間は空のまま）`() {
        // タスク 27（ユーザー作業）で Android 用に発行するまでは空。入れたら、本番トラックの検査に通る値であること
        val (appId, bannerUnitId) = productionIds(properties())
        if (appId.isNotEmpty() || bannerUnitId.isNotEmpty()) {
            assertNull(adsConfigProblem(AdsConfig(AdsBuildKind.PRODUCTION_TRACK, appId, bannerUnitId)), "本番の ID が誤っている")
        }
    }

    @Test
    fun `AndroidのIDはiOS版のIDと同じでない`() {
        val ios = iosIds()
        val (productionAppId, productionBannerUnitId) = productionIds(properties())
        val android = listOf(
            BuildConfig.ADMOB_APP_ID,
            BuildConfig.ADMOB_BANNER_UNIT_ID,
            productionAppId,
            productionBannerUnitId,
        )
        // 値そのものはメッセージに出さない（何番目が一致したかだけ）
        android.forEachIndexed { index, id ->
            assertTrue(id !in ios, "Android の ID（${index + 1} 番目）が iOS 版の ID と同じ（要件 14.2：iOS と共用しない）")
        }
    }
}
