// ⭐️ PostHog の初期化の設定を iOS 版に揃える単体テスト（タスク 4.1・要件 15.1・15.4）
package com.yoshidometoru.soramoyou.platform

import com.posthog.android.PostHogAndroidConfig
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Android は iOS 版と同じ PostHog のプロジェクトへ送る（同じ物差しで両 OS を並べるため）。
 * 画面の自動計測は切り、4 つの画面名だけを手動で送る。プッシュ通知の購読トークンの送信も切る（Android だけの設定）。
 * それ以外の設定は SDK の既定のまま（iOS も captureScreenViews 以外は既定）。
 *
 * 根拠（読んだ現物）: Soramoyou/Soramoyou/Services/LoggingService.swift:28-31（キーとホスト）、:36-43（captureScreenViews = false）
 *
 * ⚠️ キーはクライアントに埋め込む前提の公開値だが、テストの失敗メッセージにもログにも値そのものは出さない（一致・不一致だけを書く）。
 */
class PostHogSetupTest {

    @Test
    fun `設定は画面の自動計測を無効にしている`() {
        assertFalse(PostHogSetup.createConfig().captureScreenViews)
    }

    @Test
    fun `設定はプッシュ通知の購読トークンをPostHogへ送らない`() {
        // SDK の既定は true（posthog-android 3.71.4 の PostHogAndroidConfig の既定値をバイトコードで確認）。
        // 今は FCM の SDK が無いので送られないが、FCM が混入しても fcmToken が PostHog へ出ないように明示で切る
        assertFalse(PostHogSetup.createConfig().capturePushNotificationSubscriptions)
    }

    @Test
    fun `設定のキーとホストは窓口が持つ値である`() {
        val config = PostHogSetup.createConfig()
        assertTrue(config.apiKey == PostHogSetup.API_KEY, "設定のキーが PostHogSetup.API_KEY と一致しない")
        assertEquals("https://us.i.posthog.com", config.host)
    }

    @Test
    fun `画面の自動計測とプッシュ購読以外のAndroid固有の自動計測はSDKの既定のまま`() {
        val config = PostHogSetup.createConfig()
        val defaults = PostHogAndroidConfig(PostHogSetup.API_KEY, PostHogSetup.HOST)

        assertEquals(defaults.captureApplicationLifecycleEvents, config.captureApplicationLifecycleEvents)
        assertEquals(defaults.captureDeepLinks, config.captureDeepLinks)
        assertEquals(defaults.captureElementInteractions, config.captureElementInteractions)
        assertEquals(defaults.sessionReplay, config.sessionReplay)
    }

    @Test
    fun `キーとホストはiOS版のLoggingServiceと同じである`() {
        // :app の単体テストの作業ディレクトリは android/app。iOS のソースはリポジトリの直下の Soramoyou/ にある
        val swift = File(System.getProperty("user.dir"), "../../Soramoyou/Soramoyou/Services/LoggingService.swift")
        assertTrue(swift.isFile, "iOS 版の LoggingService.swift が見つからない: ${swift.canonicalPath}")
        val source = swift.readText()

        val iosKey = assertNotNull(
            Regex("""postHogAPIKey\s*=\s*"([^"]+)"""").find(source)?.groupValues?.get(1),
            "iOS 版の postHogAPIKey の定義が見つからない（書き方が変わった可能性）",
        )
        val iosHost = assertNotNull(
            Regex("""postHogHost\s*=\s*"([^"]+)"""").find(source)?.groupValues?.get(1),
            "iOS 版の postHogHost の定義が見つからない（書き方が変わった可能性）",
        )

        assertTrue(iosKey == PostHogSetup.API_KEY, "PostHog のキーが iOS 版と一致しない（iOS 側でキーが変わった可能性）")
        assertEquals(iosHost, PostHogSetup.HOST)
    }
}
