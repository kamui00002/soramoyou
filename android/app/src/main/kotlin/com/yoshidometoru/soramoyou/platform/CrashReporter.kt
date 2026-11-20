// ⭐️ 非致命エラーを Crashlytics に記録する窓口（タスク 4.2・要件 15.8・15.9）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.Uid

/**
 * 非致命エラーを Crashlytics に記録する窓口（設計書の部品 CrashReporter）。
 *
 * どの分類のエラーを記録するかは、ここでは決めない。決めるのは [AnalyticsFacade.logError] だけである
 * （iOS も、分類の判断は ErrorHandler.swift の `logError`（:146-157）にあり、記録する側の
 * LoggingService.swift `recordError`・`recordNonFatalError`（:55-95）は受け取ったものをそのまま記録する）。
 * どのメソッドも例外を投げない（要件 15.9）。
 */
interface CrashReporter {
    /**
     * [error] を非致命エラーとして記録する。[context] は発生箇所（`クラス名.メソッド名[.段階]`）で、
     * iOS と同じカスタムキー名 [ERROR_CONTEXT_KEY] に載せる（要件 15.8）。[extra] は同じイベントにだけ付く追加のキー。
     */
    fun recordNonFatal(error: AppError, context: String, extra: Map<String, String> = emptyMap())

    /**
     * 以後の記録に付くユーザーの識別を uid だけで行う。null（または空の uid）で解除する。
     * 設計書の CrashReporter には無いメソッドで、iOS の `setUserID` が Crashlytics の識別も切り替えている
     * （LoggingService.swift:204・:217）のに合わせて足した。呼ぶのは [AnalyticsFacade.setUserId] だけにする。
     */
    fun setUserId(uid: Uid?)

    companion object {
        /** 発生箇所のカスタムキー名。iOS と同じ（LoggingService.swift:64・:86。分析イベントのパラメータ名も同じ :145）。 */
        const val ERROR_CONTEXT_KEY = "error_context"

        /** 形の契約違反の一覧のカスタムキー名（Android だけ。iOS に形の検証は無い）。値は [toViolationsDescription]。 */
        const val SHAPE_VIOLATIONS_KEY = "shape_violations"
    }
}

/**
 * Crashlytics に非致命エラーとして載せるための例外。投げるためではなく、記録するためだけに作る。
 * 本文は [toErrorDescription] を浄化したもので、スタックトレースは記録を頼んだ呼び出し元から始まる（[DefaultCrashReporter]）。
 */
class NonFatalAppError(message: String) : Exception(message)

/**
 * [CrashReporter] の実装。
 *
 * iOS（LoggingService.swift `recordError`:55-73・`recordNonFatalError`:76-95）との違いは 2 つで、どちらも意図したもの:
 * - iOS は `record(error:)` の後で `setCustomValue(_, forKey: "error_context")` を呼ぶ（:60→:64）。アプリ全体に残るキーなので、
 *   その記録に付くのは前回の発生箇所になりうる。Android は SDK の「このイベントにだけ付くキー」で渡し、記録と発生箇所を必ず一致させる
 *   （別スレッドから同時に記録されても混ざらない）。
 * - iOS は記録のたびに `setUserID(userId)` も呼ぶ（:67-69）。Android の記録は uid を受け取らず、識別は [setUserId] だけで行う。
 *
 * 失敗の握りつぶし（要件 15.9）は [DefaultAnalyticsFacade] と同じ形で、「Crashlytics.操作」の名前と例外を [reportFailure] に渡す。
 *
 * @param reportFailure 握りつぶした失敗を Logcat などへ出すための差し込み口。既定は何もしない（JVM の単体テストでは Log を使えないため）。
 */
class DefaultCrashReporter(
    private val client: CrashlyticsClient,
    private val reportFailure: (String, Exception) -> Unit = { _, _ -> },
) : CrashReporter {

    override fun recordNonFatal(error: AppError, context: String, extra: Map<String, String>) {
        guarded("Crashlytics.recordException") {
            // 値は全て浄化する。iOS が浄化するのは発生箇所だけ（:57・:78）だが、例外の本文と extra は
            // Android で組み立てる文字列で、AppError.Unknown の文言のように外から来たものを含みうる
            val keys = LinkedHashMap<String, String>()
            extra.forEach { (key, value) -> keys[key] = AnalyticsSanitizer.sanitizeText(value) }
            // 発生箇所は最後に入れ、extra に同じ名前があっても上書きされないようにする
            keys[CrashReporter.ERROR_CONTEXT_KEY] = AnalyticsSanitizer.sanitizeText(context)

            val throwable = NonFatalAppError(AnalyticsSanitizer.sanitizeText(error.toErrorDescription()))
            throwable.stackTrace = callerFrames(throwable.stackTrace)
            client.recordException(throwable, keys)
        }
    }

    override fun setUserId(uid: Uid?) {
        val id = uid?.value
        // Crashlytics の識別の解除は空文字を渡す（公式文書「ユーザー ID を設定する」。SDK の setUserId は null を受けない）
        guarded("Crashlytics.setUserId") { client.setUserId(if (id.isNullOrEmpty()) "" else id) }
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

    private companion object {
        /**
         * 記録の仕組みの中のクラス。例外の先頭からこれらのフレームを取り除き、記録を頼んだ呼び出し元から始める。
         * Crashlytics はスタックトレースで issue をまとめるので、取り除かないと全ての非致命エラーの先頭が
         * 同じフレームになり、1 つの issue に潰れる（発生箇所ごとに分かれない）。
         * 名前は実行時のクラスから取るので、R8 で難読化されても一致する。
         */
        val RECORDING_CLASSES: List<String> = listOf(
            CrashReporter::class.java.name,
            DefaultCrashReporter::class.java.name,
            AnalyticsFacade::class.java.name,
            DefaultAnalyticsFacade::class.java.name,
        )

        /** 先頭から続く「記録の仕組みの中のフレーム」を取り除く。全部が当てはまるときは、手掛かりを失わないよう元のまま返す。 */
        fun callerFrames(frames: Array<StackTraceElement>): Array<StackTraceElement> {
            val trimmed = frames.dropWhile { frame ->
                RECORDING_CLASSES.any { name -> frame.className == name || frame.className.startsWith("$name\$") }
            }
            return if (trimmed.isEmpty()) frames else trimmed.toTypedArray()
        }
    }
}
