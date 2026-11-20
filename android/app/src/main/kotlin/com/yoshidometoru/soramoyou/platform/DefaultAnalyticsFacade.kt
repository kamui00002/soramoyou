// ⭐️ 分析イベントの単一の送信窓口の実装（タスク 4.1・4.2・要件 15.1・15.5・15.7・15.8・15.9）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.ErrorCategory
import com.yoshidometoru.soramoyou.contract.Uid

/**
 * [AnalyticsFacade] の実装。iOS の LoggingService と同じ振る舞いにする。
 *
 * 根拠（読んだ現物。Soramoyou/Soramoyou/Services/LoggingService.swift）:
 * - `logEvent`（:118-130）：浄化したパラメータを Firebase → PostHog の順に送る
 * - `logScreen`（:47-50）：PostHog の `screen` だけ
 * - `setUserID`（:200-225）：nil か空文字なら未識別。Firebase の解除は毎回、PostHog の `reset()` は
 *   「identify 済み → 未識別」の実遷移でだけ呼ぶ（元から匿名で呼ぶと distinct_id が作り直され、同じ人が別人として数えられる）。
 *   Crashlytics の識別も同じ所で切り替える（:204・:217。タスク 4.2）
 * - `logError`（タスク 4.2）：iOS の ErrorHandler.swift `logError`（:133-161）と LoggingService.swift `logErrorEvent`（:133-150）
 *
 * 失敗の握りつぶし（要件 15.9）：送信先ごとに個別に `try`／`catch (e: Exception)` で囲む。片方が投げても、もう片方には必ず送り、
 * 例外は呼び出し元へ伝えない。握りつぶした失敗は [reportFailure] に「送信先.操作」の名前（例：`PostHog.capture`）と例外を渡す。
 * 名前にはパラメータの値を含めない。
 *
 * @param crashReporter Crashlytics への記録とユーザー識別の窓口（タスク 4.2）。既定値は置かない（渡し忘れて Crashlytics が黙って止まるのを防ぐ）。
 * @param reportFailure 握りつぶした失敗を Logcat などへ出すための差し込み口。依存を組み立てる所（タスク 5.1）で `Log.w` を渡す。
 *   android.util.Log は JVM の単体テストでは使えないので、既定は何もしない。
 */
class DefaultAnalyticsFacade(
    private val postHog: PostHogClient,
    private val firebase: FirebaseAnalyticsClient,
    private val crashReporter: CrashReporter,
    private val reportFailure: (String, Exception) -> Unit = { _, _ -> },
) : AnalyticsFacade {

    /**
     * 直前に PostHog へ identify 済みかどうか（iOS の `lastIdentifiedUserID != nil` に当たる）。
     * 認証の監視は別スレッドから来うるので、読み書きは [setUserId] の同期の中だけで行う。
     */
    private var identified = false

    override fun logEvent(name: EventName, params: Map<String, ParamValue>) {
        // 1 回だけ浄化し、同じ値を両方へ送る（送信先ごとの違いは値の型の変換だけ）
        val sanitized = AnalyticsSanitizer.sanitizeParams(params)
        guarded("Firebase.logEvent") {
            firebase.logEvent(name.value, sanitized.mapValues { it.value.toFirebaseValue() })
        }
        guarded("PostHog.capture") {
            postHog.capture(name.value, sanitized.mapValues { it.value.toPostHogValue() })
        }
    }

    override fun logScreen(name: ScreenName) {
        guarded("PostHog.screen") { postHog.screen(name.value) }
    }

    override fun logError(error: AppError, context: String) {
        // iOS の ErrorHandler.logError（:133-161）と同じ順で、Crashlytics → error_occurred の順に送る。
        // Crashlytics に送るかどうかの判断はここだけで行う（CrashReporter は受け取ったものを記録するだけ）。
        // else を書かない網羅の when にして、分類を足したらここで扱いを決めるまでコンパイルが通らないようにしている
        when (error.category) {
            // iOS は userError をログに出すだけ（:147-148）
            ErrorCategory.USER -> Unit
            // iOS は systemError を recordError（:149-152）、businessError を recordNonFatalError（:153-156）で記録する。
            // どちらも Crashlytics では非致命エラーなので、Android は 1 つの recordNonFatal にまとめる
            ErrorCategory.SYSTEM, ErrorCategory.BUSINESS -> guarded("Crashlytics.recordNonFatal") {
                crashReporter.recordNonFatal(error, context, crashExtraOf(error))
            }
        }

        // パラメータのキーと分類の値は iOS の logErrorEvent（LoggingService.swift:139-146）と同じ。
        // 説明と発生箇所の浄化は logEvent の中で行う（iOS も :134・:137 で浄化している）
        logEvent(
            EventName.ERROR_OCCURRED,
            mapOf(
                "error_category" to ParamValue.S(error.category.raw),
                "error_description" to ParamValue.S(error.toErrorDescription()),
                CrashReporter.ERROR_CONTEXT_KEY to ParamValue.S(context),
            ),
        )
    }

    /**
     * Crashlytics の同じイベントにだけ付ける追加のキー。形の契約違反は、違反したキーを載せる（設計書 Error Handling の表）。
     * 段階で止まった失敗（退会）は、原因が形の契約違反ならそのキーを載せる。
     */
    private fun crashExtraOf(error: AppError): Map<String, String> = when (error) {
        is AppError.ShapeViolation -> mapOf(CrashReporter.SHAPE_VIOLATIONS_KEY to error.violations.toViolationsDescription())
        is AppError.StageFailed -> crashExtraOf(error.cause)
        else -> emptyMap()
    }

    @Synchronized
    override fun setUserId(uid: Uid?) {
        val id = uid?.value
        if (id.isNullOrEmpty()) {
            guarded("Firebase.setUserId") { firebase.setUserId(null) }
            // Crashlytics の識別も毎回解除する（iOS :204。タスク 4.2）
            guarded("Crashlytics.setUserId") { crashReporter.setUserId(null) }
            if (identified) {
                guarded("PostHog.reset") { postHog.reset() }
                // reset が失敗しても未識別に戻す。iOS も reset() の後で無条件に nil にしている（:209-212）。
                // 失敗のたびに reset を呼び直すと、distinct_id が作り直されて同じ人が別人として数えられる
                identified = false
            }
            return
        }

        guarded("Firebase.setUserId") { firebase.setUserId(id) }
        // Crashlytics の記録も uid だけで識別する（iOS :217。タスク 4.2）
        guarded("Crashlytics.setUserId") { crashReporter.setUserId(uid) }
        guarded("PostHog.identify") { postHog.identify(id) }
        // identify が失敗しても識別済みとして扱う。identify が途中まで効いていた場合に、後のログアウトで reset が確実に走る方を優先する
        identified = true
    }

    /** [block] の失敗（Exception）を握りつぶし、[reportFailure] に渡す。差し込み口自体の失敗も外へ出さない。 */
    private inline fun guarded(where: String, block: () -> Unit) {
        try {
            block()
        } catch (e: Exception) {
            try {
                reportFailure(where, e)
            } catch (ignored: Exception) {
                // 失敗の報告の失敗は、どこにも出しようがないので捨てる（ユーザーの操作を止めないことを優先する）
            }
        }
    }
}
