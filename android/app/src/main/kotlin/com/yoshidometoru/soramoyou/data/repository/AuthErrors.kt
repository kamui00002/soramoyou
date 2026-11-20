// ⭐️ 認証の失敗の種類の判別と、ログイン前の入力の検査（タスク 8.1・要件 2.7）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AuthErrorKind

/**
 * FirebaseAuthException の `errorCode` を [AuthErrorKind] に写す（設計書 :751-759。iOS の `mapFirebaseError`：AuthService.swift:143-172）。
 *
 * - 通信の断絶（FirebaseNetworkException）と試行回数の超過（FirebaseTooManyRequestsException）は FirebaseAuthException の子でなく、
 *   エラーコードを持たないので、ここでなく例外の型で [FirebaseAuthClient] が写す。
 * - 列挙でなく文字列で受けるのは、SDK の例外を JVM の単体テストで作れないため（FirebaseException のコンストラクタが
 *   Android の部品を呼ぶ）。下の 7 つのコードは、firebase-auth 24.2.0 の classes.jar に文字列として実在することを確認した（2026-10-05）。
 *   iOS の `tooManyRequests`・`networkError` にあたるコード（ERROR_TOO_MANY_REQUESTS など）は、同じ jar に無かったので表に入れない。
 */
internal fun authErrorKindOf(errorCode: String): AuthErrorKind = when (errorCode) {
    "ERROR_INVALID_EMAIL" -> AuthErrorKind.INVALID_EMAIL
    // iOS 17 以降の SDK は誤ったパスワードと存在しないユーザーを invalidCredential に統合しており、iOS も wrongPassword にしている（:164-166）
    "ERROR_WRONG_PASSWORD", "ERROR_INVALID_CREDENTIAL" -> AuthErrorKind.WRONG_PASSWORD
    "ERROR_USER_NOT_FOUND" -> AuthErrorKind.USER_NOT_FOUND
    "ERROR_EMAIL_ALREADY_IN_USE" -> AuthErrorKind.EMAIL_ALREADY_IN_USE
    "ERROR_WEAK_PASSWORD" -> AuthErrorKind.WEAK_PASSWORD
    "ERROR_REQUIRES_RECENT_LOGIN" -> AuthErrorKind.REQUIRES_RECENT_LOGIN
    // 表に無いもの（無効化されたアカウントなど）は、iOS と同じく「その他」（:169-170）
    else -> AuthErrorKind.UNKNOWN
}

/**
 * ログインの前に行うメールアドレスの形式の検査。iOS の `isValidEmail`（AuthService.swift:137-141）と同じ正規表現で、文字列全体の一致を見る
 * （NSPredicate の MATCHES は全体の一致。Kotlin では [Regex.matches]）。前後の空白を削るなどの加工はしない（iOS もしない）。
 *
 * ⚠️ 新規登録の検査（:contract の EmailValidator。長さ 254 の上限などを足したもの・要件 2.5）とは別物。
 *    ログインは既存のアカウントに入るだけなので、iOS で通る入力を Android だけで拒まないよう、iOS と同じ規則にそろえる。
 */
internal fun isValidSignInEmail(email: String): Boolean = IOS_EMAIL_PATTERN.matches(email)

/** iOS の `emailRegex`（AuthService.swift:138）をそのまま写したもの。 */
private val IOS_EMAIL_PATTERN = Regex("""[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}""")
