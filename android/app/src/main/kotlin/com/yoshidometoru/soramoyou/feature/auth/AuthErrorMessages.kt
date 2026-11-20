// ⭐️ 認証の失敗の種類から、画面に出す日本語の文言への対応（タスク 8.1・要件 2.7）
package com.yoshidometoru.soramoyou.feature.auth

import androidx.annotation.StringRes
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AuthErrorKind

/**
 * [kind] の失敗のときに画面に出す文言のリソース。文言そのものは strings.xml の `auth_error_<種類の小文字>` にあり、
 * iOS の `AuthError.errorDescription`（AuthService.swift:208-231）と 1 文字も違えない（AuthErrorMessagesTest が iOS のソースと突き合わせる）。
 * 「その他」は iOS の ErrorHandler.swift:129 の既定の文言（設計書 :759）。
 *
 * else を書かない網羅の when にしている。[AuthErrorKind] に種類を足したら、文言を決めるまでコンパイルが通らない。
 */
@StringRes
fun authErrorMessageRes(kind: AuthErrorKind): Int = when (kind) {
    AuthErrorKind.INVALID_INPUT -> R.string.auth_error_invalid_input
    AuthErrorKind.INVALID_EMAIL -> R.string.auth_error_invalid_email
    AuthErrorKind.WEAK_PASSWORD -> R.string.auth_error_weak_password
    AuthErrorKind.EMAIL_ALREADY_IN_USE -> R.string.auth_error_email_already_in_use
    AuthErrorKind.WRONG_PASSWORD -> R.string.auth_error_wrong_password
    AuthErrorKind.USER_NOT_FOUND -> R.string.auth_error_user_not_found
    AuthErrorKind.NETWORK -> R.string.auth_error_network
    AuthErrorKind.TOO_MANY_REQUESTS -> R.string.auth_error_too_many_requests
    AuthErrorKind.REQUIRES_RECENT_LOGIN -> R.string.auth_error_requires_recent_login
    AuthErrorKind.UNKNOWN -> R.string.auth_error_unknown
}
