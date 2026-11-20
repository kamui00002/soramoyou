// ⭐️ 分析イベントの単一の送信窓口の型（タスク 4.1・要件 15.1・15.2・15.4・15.5）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.Uid

/**
 * 分析イベントの名前。iOS 版の実際の文字列をそのまま使う（設計書「分析イベント一覧」）。
 *
 * コンストラクタを private にして、下の 4 つの定数しか作れないようにしている。
 * 「iOS 版に無いイベントを新設しない」（タスク 4.1・要件 15.2）をコンパイルで守るためである。
 * 増やすときは、iOS 版と同時に名前を決めてから、ここと [entries] に足す。
 */
@JvmInline
value class EventName private constructor(val value: String) {
    companion object {
        /** 投稿の成功時に 1 回（iOS: PostViewModel.swift:653）。 */
        val POST_COMPLETED = EventName("post_completed")

        /** 記録の対象となるエラーの発生時（iOS: LoggingService.swift:149）。送るのはタスク 4.2 の logError。 */
        val ERROR_OCCURRED = EventName("error_occurred")

        /** 自動の再試行を行ったとき（iOS: LoggingService.swift:166）。 */
        val RETRY_OPERATION = EventName("retry_operation")

        /** 読み込んだ投稿を 1 件変換できず飛ばしたとき（iOS: origin/main の PostDocumentDecoder.swift:83・PR #150）。 */
        val POST_DECODE_FAILED = EventName("post_decode_failed")

        /** 送ってよいイベント名の全て。 */
        val entries: List<EventName> = listOf(POST_COMPLETED, ERROR_OCCURRED, RETRY_OPERATION, POST_DECODE_FAILED)
    }
}

/**
 * PostHog に送る画面名。iOS 版が計測している 4 つの画面だけ（設計書「画面名」・Q10）。
 * [EventName] と同じく、コンストラクタを private にして集合を閉じている。
 */
@JvmInline
value class ScreenName private constructor(val value: String) {
    companion object {
        /** フィード（iOS: MainTabView.swift:29 の Tab.home.title）。 */
        val HOME = ScreenName("ホーム")

        /** 写真の選択（iOS: MainTabView.swift:30 の Tab.post.title）。 */
        val POST = ScreenName("投稿")

        /** フィルター画面（iOS: EditView.swift:347）。 */
        val EDIT = ScreenName("編集")

        /** 自分のプロフィール（iOS: MainTabView.swift:33 の Tab.profile.title）。 */
        val PROFILE = ScreenName("プロフィール")

        /** 送ってよい画面名の全て。 */
        val entries: List<ScreenName> = listOf(HOME, POST, EDIT, PROFILE)
    }
}

/**
 * イベントのパラメータの値。PostHog と Firebase Analytics の両方へ載せられる型だけを持つ。
 * 送信先ごとの型への変換は [toPostHogValue]・[toFirebaseValue] が行う。
 */
sealed interface ParamValue {
    data class S(val v: String) : ParamValue
    data class L(val v: Long) : ParamValue
    data class B(val v: Boolean) : ParamValue
    data class D(val v: Double) : ParamValue
}

/**
 * 分析イベントの単一の送信窓口（要件 15.1）。画面・ViewModel は PostHog や Firebase Analytics を直接呼ばず、ここだけを使う。
 * どのメソッドも例外を投げない。送信の失敗は窓口の中で握りつぶす（要件 15.9）。
 */
interface AnalyticsFacade {
    /** イベントを、浄化してから PostHog と Firebase Analytics の両方へ送る。 */
    fun logEvent(name: EventName, params: Map<String, ParamValue> = emptyMap())

    /** 画面表示を PostHog にだけ送る（iOS と同じ。LoggingService.swift:47-50）。 */
    fun logScreen(name: ScreenName)

    /**
     * クラッシュせずに失敗した処理を、発生箇所つきで記録する（要件 15.8・タスク 4.2）。
     * - 分析イベント `error_occurred`（`error_category`・`error_description`・`error_context`）を両方へ送る
     * - 分類が `system_error`・`business_error` なら、Crashlytics にも非致命エラーとして記録する
     *
     * [context] は発生箇所で、`クラス名.メソッド名[.段階]`（例：`HomeViewModel.fetchPosts`）の形にする。
     * 投稿の変換の失敗（1 件飛ばし）はここへ渡さず、[logPostDecodeFailed] を使う（Crashlytics へ送らないため）。
     */
    fun logError(error: AppError, context: String)

    /** 分析上のユーザーを uid だけで識別する（要件 15.5）。null（または空の uid）で識別を解除する（要件 15.7）。 */
    fun setUserId(uid: Uid?)
}
