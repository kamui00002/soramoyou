// ☁️ 広告 SDK（GMA Next-Gen）の初期化を呼ぶ薄い窓口（タスク 32.1・要件 14.1）
package com.yoshidometoru.soramoyou.platform

import android.content.Context
import com.google.android.libraries.ads.mobile.sdk.MobileAds
import com.google.android.libraries.ads.mobile.sdk.initialization.InitializationConfig

/**
 * [MobileAdsInitializer] の本物。GMA Next-Gen SDK の初期化をそのまま呼ぶ。
 *
 * 出典：developers.google.com/admob/android/next-gen/quick-start（2026-10-13 に確認）。
 * - アプリ ID はマニフェストでなく、初期化の引数（InitializationConfig）で渡す（next-gen/migration「Set the AdMob app ID」）
 * - 背景のスレッドで呼ぶ（main で呼ぶと ANR になりうる）。呼び出しは SDK の初期化が終わるまで戻らない。
 *   メディエーションは使わないので、アダプタの初期化の完了（3 つ目の引数）は待たない
 *
 * 単体テストの対象外（JVM では SDK を動かせない）。初期化が終わることは端末で確かめる。
 */
class GmaMobileAdsInitializer(private val context: Context) : MobileAdsInitializer {
    override fun initialize(appId: String) {
        MobileAds.initialize(context, InitializationConfig.Builder(appId).build())
    }
}
