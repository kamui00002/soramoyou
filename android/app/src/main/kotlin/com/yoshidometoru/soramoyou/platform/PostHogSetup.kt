// ☁️ PostHog の初期化の設定（タスク 4.1・要件 15.1・15.4）
package com.yoshidometoru.soramoyou.platform

import android.content.Context
import com.posthog.android.PostHogAndroid
import com.posthog.android.PostHogAndroidConfig

/**
 * iOS 版と同じ PostHog のプロジェクトへ送るための設定。
 * 画面の自動計測（captureScreenViews）を切る（iOS も captureScreenViews 以外は既定）。
 * Android だけの設定として、プッシュ通知の購読トークンの送信（capturePushNotificationSubscriptions）も切る。それ以外は SDK の既定のまま。
 * 画面表示は [AnalyticsFacade.logScreen] で 4 つの画面名だけを手動で送る。
 *
 * 根拠（読んだ現物）: Soramoyou/Soramoyou/Services/LoggingService.swift:28-31（キーとホスト）、:36-43（captureScreenViews = false）
 * iOS 側の値と一致していることは PostHogSetupTest が iOS のソースを読んで確かめる（iOS がキーを替えたら落ちる）。
 */
object PostHogSetup {

    /**
     * PostHog の Project API key（iOS 版と同じ値）。これは「クライアント公開キー」であり、
     * アプリのバイナリに埋め込まれる前提の値。秘匿キーではないのでリポジトリに置いてよい（iOS: LoggingService.swift:28-29 の注記と同じ）。
     */
    internal const val API_KEY = "phc_ygTnSrCc4AEp6G9m4hD8VLadRGjPPF7w4nYDBMMjX8LL"

    /** PostHog の送信先（US リージョン。iOS 版と同じ）。 */
    internal const val HOST = "https://us.i.posthog.com"

    /** 初期化に使う設定を作る。画面の自動計測と、プッシュ通知の購読トークンの送信は無効にする。 */
    fun createConfig(): PostHogAndroidConfig =
        PostHogAndroidConfig(API_KEY, HOST).apply {
            // Activity 単位の自動計測では iOS と同じ画面名にならないため、無効にして手動で送る（iOS: LoggingService.swift:38-41）
            captureScreenViews = false
            // 既定の true だと、FCM の SDK があるとき端末のプッシュ通知トークンを PostHog へ送る（posthog-android 3.71）。
            // Android 版は FCM を入れない（要件 2.10）ので今は送られないが、混入したときにも送らないよう明示で切る
            capturePushNotificationSubscriptions = false
        }

    /** PostHog の SDK を初期化する。アプリの起動時に 1 回だけ、依存を組み立てる所（タスク 5.1）から呼ぶ。 */
    fun setUp(context: Context) {
        PostHogAndroid.setup(context, createConfig())
    }
}
