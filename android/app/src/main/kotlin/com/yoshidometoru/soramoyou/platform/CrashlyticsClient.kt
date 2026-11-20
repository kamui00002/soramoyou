// ☁️ Crashlytics の SDK の差し替え口（タスク 4.2）
package com.yoshidometoru.soramoyou.platform

/**
 * Firebase Crashlytics の SDK を呼ぶ薄い窓口。判断は [DefaultCrashReporter] に集め、ここは SDK を呼ぶだけにする。
 * JVM の単体テストでは、記録用の偽物に差し替える。本物は [CrashlyticsSdkClient]。
 */
interface CrashlyticsClient {
    /**
     * [throwable] を非致命エラーとして記録する。[keys] は、このイベントにだけ付くカスタムキー
     * （同じ名前のアプリ全体のキーより優先される。SDK の `recordException(Throwable, CustomKeysAndValues)`）。
     */
    fun recordException(throwable: Throwable, keys: Map<String, String>)

    /** 以後の記録に付くユーザーの識別子。空文字で識別を解除する（Crashlytics の仕様）。 */
    fun setUserId(id: String)
}
