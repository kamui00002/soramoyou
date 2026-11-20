// ☁️ Firebase Crashlytics の SDK を呼ぶ薄い窓口（タスク 4.2）
package com.yoshidometoru.soramoyou.platform

import com.google.firebase.crashlytics.CustomKeysAndValues
import com.google.firebase.crashlytics.FirebaseCrashlytics

/**
 * [CrashlyticsClient] の本物。受け取った値を SDK に渡すだけで、判断は持たない。
 * キーは `recordException(Throwable, CustomKeysAndValues)` で、このイベントにだけ付ける
 * （firebase-crashlytics 20.1.1 の公開 API を javap で確認。値が 1024 文字を超えると SDK が切り詰める）。
 * 単体テストの対象外（本番の記録はタスク 11.3 で Crashlytics のコンソールを見て確かめる）。
 */
class CrashlyticsSdkClient(private val crashlytics: FirebaseCrashlytics) : CrashlyticsClient {
    override fun recordException(throwable: Throwable, keys: Map<String, String>) {
        val builder = CustomKeysAndValues.Builder()
        keys.forEach { (key, value) -> builder.putString(key, value) }
        crashlytics.recordException(throwable, builder.build())
    }

    override fun setUserId(id: String) {
        crashlytics.setUserId(id)
    }
}
