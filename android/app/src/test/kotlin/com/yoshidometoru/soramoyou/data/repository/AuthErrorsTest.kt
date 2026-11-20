// ⭐️ 認証の失敗の種類の判別と、ログイン前のメールアドレスの検査の単体テスト（タスク 8.1・要件 2.7）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AuthErrorsTest {

    @Test
    fun `FirebaseAuthExceptionのエラーコードを種類に写す（設計書の表と1対1）`() {
        val table = mapOf(
            "ERROR_INVALID_EMAIL" to AuthErrorKind.INVALID_EMAIL,
            "ERROR_WRONG_PASSWORD" to AuthErrorKind.WRONG_PASSWORD,
            // iOS も invalidCredential を wrongPassword に統合している（AuthService.swift:164-166）
            "ERROR_INVALID_CREDENTIAL" to AuthErrorKind.WRONG_PASSWORD,
            "ERROR_USER_NOT_FOUND" to AuthErrorKind.USER_NOT_FOUND,
            "ERROR_EMAIL_ALREADY_IN_USE" to AuthErrorKind.EMAIL_ALREADY_IN_USE,
            "ERROR_WEAK_PASSWORD" to AuthErrorKind.WEAK_PASSWORD,
            "ERROR_REQUIRES_RECENT_LOGIN" to AuthErrorKind.REQUIRES_RECENT_LOGIN,
        )

        table.forEach { (code, kind) -> assertEquals(kind, authErrorKindOf(code), code) }
    }

    @Test
    fun `表に無いエラーコードはその他にする`() {
        // iOS も、表に無いコードは unknown にしている（AuthService.swift:169-170）
        listOf("ERROR_USER_DISABLED", "ERROR_OPERATION_NOT_ALLOWED", "").forEach { code ->
            assertEquals(AuthErrorKind.UNKNOWN, authErrorKindOf(code), code)
        }
    }

    @Test
    fun `メールアドレスの検査はiOSのisValidEmailの正規表現と同じ（文字列全体の一致）`() {
        // iOS: AuthService.swift:137-141（NSPredicate の MATCHES は文字列全体の一致）
        listOf("a@b.co", "taro.yamada+sky@example.co.jp", "A_B%C-D@x-y.Z9.museum").forEach {
            assertTrue(isValidSignInEmail(it), it)
        }
        listOf(
            "a@b.c", // TLD が 1 文字
            "a@b", // TLD が無い
            "a b@example.com", // 空白
            " a@example.com", // 前後の空白は削らない（iOS も削らない）
            "a@example.com\n", // 末尾の改行（部分一致なら通ってしまう）
            "a@example.c0m", // TLD に数字
            "@example.com",
        ).forEach { assertFalse(isValidSignInEmail(it), it) }
    }

    @Test
    fun `TLDは2文字以上64文字以下`() {
        assertTrue(isValidSignInEmail("a@b." + "x".repeat(64)))
        assertFalse(isValidSignInEmail("a@b." + "x".repeat(65)))
    }
}
