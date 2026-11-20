// ⭐️ 分析の送信先（PostHog・Firebase Analytics）の薄い窓口と、値の変換（タスク 4.1）
package com.yoshidometoru.soramoyou.platform

/**
 * PostHog の SDK を呼ぶ薄い窓口。判断は [DefaultAnalyticsFacade] に集め、ここは SDK を呼ぶだけにする。
 * JVM の単体テストでは、記録用の偽物に差し替える。本物は [PostHogSdkClient]。
 */
interface PostHogClient {
    fun capture(event: String, properties: Map<String, Any>)
    fun screen(title: String)
    fun identify(distinctId: String)
    fun reset()
}

/**
 * Firebase Analytics の SDK を呼ぶ薄い窓口。本物は [FirebaseAnalyticsSdkClient]。
 * [params] の値は [toFirebaseValue] で変換済みの String・Long・Double だけが来る。
 */
interface FirebaseAnalyticsClient {
    fun logEvent(name: String, params: Map<String, Any>)
    fun setUserId(id: String?)
}

/**
 * PostHog へ載せる値。4 種類ともそのままの型で渡す。
 * iOS も Bool は JSON の true/false として PostHog に届く（LoggingService.swift:126 で辞書をそのまま渡している）。
 */
fun ParamValue.toPostHogValue(): Any = when (this) {
    is ParamValue.S -> v
    is ParamValue.L -> v
    is ParamValue.B -> v
    is ParamValue.D -> v
}

/**
 * Firebase Analytics へ載せる値。Firebase Analytics（Android）の Bundle の値として公式に挙がっているのは
 * String・long・double なので、真偽値は 1／0 の Long にする。
 * iOS は Swift の Bool が NSNumber として渡るため、数値で記録されているはず
 * （要確認：11.3 で GA4 の実データを見て確かめる。iOS 側の型が違えば、ここを揃え直す）。
 */
fun ParamValue.toFirebaseValue(): Any = when (this) {
    is ParamValue.S -> v
    is ParamValue.L -> v
    is ParamValue.B -> if (v) 1L else 0L
    is ParamValue.D -> v
}
