// ☁️ Firebase Analytics の SDK を呼ぶ薄い窓口（タスク 4.1）
package com.yoshidometoru.soramoyou.platform

import android.os.Bundle
import com.google.firebase.analytics.FirebaseAnalytics

/**
 * [FirebaseAnalyticsClient] の本物。受け取った値を Bundle に詰めて SDK に渡すだけで、判断は持たない。
 * 値は [toFirebaseValue] で String・Long・Double に変換済みのものだけが来る。それ以外の型が来たら例外にし、
 * 窓口（[DefaultAnalyticsFacade]）が握りつぶして報告する（黙って文字列にすると、型の取り違えに気づけない）。
 * 単体テストの対象外（本番の送信はタスク 11.3 で GA4 の実データを見て確かめる）。
 */
class FirebaseAnalyticsSdkClient(private val analytics: FirebaseAnalytics) : FirebaseAnalyticsClient {
    override fun logEvent(name: String, params: Map<String, Any>) {
        val bundle = Bundle()
        params.forEach { (key, value) ->
            when (value) {
                is String -> bundle.putString(key, value)
                is Long -> bundle.putLong(key, value)
                is Double -> bundle.putDouble(key, value)
                else -> throw IllegalArgumentException(
                    "Firebase Analytics に載せられない値の型: key=$key type=${value::class.java.simpleName}",
                )
            }
        }
        analytics.logEvent(name, bundle)
    }

    override fun setUserId(id: String?) {
        analytics.setUserId(id)
    }
}
