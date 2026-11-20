// ☁️ 同意の取得（UMP）を呼ぶ薄い窓口（タスク 32.1・要件 14.1）
package com.yoshidometoru.soramoyou.platform

import android.app.Activity
import com.google.android.ump.ConsentInformation
import com.google.android.ump.ConsentRequestParameters
import com.google.android.ump.FormError
import com.google.android.ump.UserMessagingPlatform
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * [ConsentGateway] の本物。UMP の API をそのまま呼ぶだけで、順序や失敗の扱いは持たない（それは [DefaultAdsController]）。
 * UMP は同意の情報の更新とフォームの表示に Activity を要るので、画面（MainActivity）の起動のときに作って渡す。
 * Activity を持つのは、UMP が結果を返すまで（[DefaultAdsController] は結果を受け取った後にこの窓口を使わない）。
 *
 * 手順の出典：developers.google.com/admob/android/next-gen/privacy（2026-10-13 に確認）。
 * - 同意の情報の更新は起動のたびに呼ぶ（「at every app launch」）
 * - 公開国は日本だけで始めるので、同意のメッセージ（GDPR など）は AdMob にまだ作っていない（タスク 27）。作っていなければ、
 *   フォームは出ずに終わり、広告を要求してよいと答える（UMP 3.0.0 のリリースノート「canRequestAds … no privacy messages configured」）
 * - テスト端末の ID や地域の上書き（ConsentDebugSettings）は入れない（公式が「リリース前に消す」とするもの。エミュレータは自動でテスト端末になる）
 *
 * 単体テストの対象外（JVM では UMP を動かせない）。同意のフォームの表示は端末で確かめる。
 */
class UmpConsentGateway(private val activity: Activity) : ConsentGateway {

    private val consentInformation: ConsentInformation = UserMessagingPlatform.getConsentInformation(activity)

    override suspend fun requestConsentInfoUpdate(): ConsentStepResult = suspendCancellableCoroutine { continuation ->
        consentInformation.requestConsentInfoUpdate(
            activity,
            ConsentRequestParameters.Builder().build(),
            { continuation.resume(ConsentStepResult.Completed) },
            { error -> continuation.resume(error.toResult()) },
        )
    }

    override suspend fun loadAndShowConsentFormIfRequired(): ConsentStepResult = suspendCancellableCoroutine { continuation ->
        // 閉じられた（または不要だった）ときに 1 回だけ呼ばれる。error は失敗のときだけ入る
        UserMessagingPlatform.loadAndShowConsentFormIfRequired(activity) { error ->
            continuation.resume(error?.toResult() ?: ConsentStepResult.Completed)
        }
    }

    override fun canRequestAds(): Boolean = consentInformation.canRequestAds()

    private fun FormError.toResult(): ConsentStepResult = ConsentStepResult.Failed(errorCode, message)
}
