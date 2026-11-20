// ⭐️ エラーの記録に載せる説明（error_description・Crashlytics の例外の本文・形の契約違反の一覧）（タスク 4.2・要件 15.8）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.document.Violation

/**
 * `error_occurred` の `error_description` と、Crashlytics に載せる例外の本文に使う説明。
 *
 * ⚠️ iOS とは値を揃えられない。iOS は `error.localizedDescription`（多くは画面に出す日本語の文言）を浄化して載せる
 *    （LoggingService.swift:137・:141）が、Android の [AppError] は文言を持たない（文言は画面側の担当。AppError.kt の冒頭）。
 *    そこで、種類名と、種類を見分けるのに効く項目（列挙値・番号・件数）だけを決まった形の短い文字列にする。
 *    Firebase Analytics のパラメータの値は 100 文字までなので、可変の長い一覧（形の契約違反のキー）はここに入れず、
 *    Crashlytics のカスタムキー（[toViolationsDescription]）にだけ載せる。
 *
 * キャプション・ID などの値そのものは載せない。ただし [AppError.Unknown] の文言は外から来るので、送る前に必ず浄化する
 * （分析は [AnalyticsSanitizer.sanitizeParams]、Crashlytics は [DefaultCrashReporter] が浄化する）。
 *
 * else を書かない網羅の when にしている。[AppError] に種類を足したら、ここで説明の形を決めるまでコンパイルが通らない。
 */
fun AppError.toErrorDescription(): String = when (this) {
    is AppError.Auth -> "Auth.${kind.name}"
    AppError.Network -> "Network"
    AppError.PermissionDenied -> "PermissionDenied"
    AppError.NotFound -> "NotFound"
    is AppError.WriteBlocked -> "WriteBlocked.${capability.name}"
    is AppError.ShapeViolation -> "ShapeViolation(count=${violations.size})"
    is AppError.Validation -> "Validation.${reason.name}"
    is AppError.ImageUnreadable -> "ImageUnreadable(index=$index)"
    is AppError.ImageTooLarge -> "ImageTooLarge(index=$index, bytes=$bytes)"
    is AppError.StageFailed -> "StageFailed.${stage.name}(${cause.toErrorDescription()})"
    is AppError.Unknown -> "Unknown($message)"
}

/**
 * 形の契約違反の一覧を、違反の種類とキーを並べた文字列にする（Crashlytics のカスタムキー `shape_violations` の値）。
 * 設計書の Error Handling の表（business_error の「記録」欄：契約違反は違反したキーを含める）に対応する。
 * [Violation] は値そのものを持たない（タスク 3.3 の定め）ので、ここにも値は入らない。
 */
fun List<Violation>.toViolationsDescription(): String = joinToString(", ") { violation ->
    when (violation) {
        is Violation.MissingKey -> "missing:${violation.key}"
        is Violation.UnexpectedKey -> "unexpected:${violation.key}"
        is Violation.WrongKind -> "wrong_kind:${violation.key}=${violation.actual.name}"
        is Violation.OutOfRange -> "out_of_range:${violation.key}(${violation.detail})"
    }
}
