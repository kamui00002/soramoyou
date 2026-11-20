// ⭐️ 認証の失敗の文言を iOS 版と 1 文字も違えないことの単体テスト（タスク 8.1・要件 2.7）
package com.yoshidometoru.soramoyou.feature.auth

import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.ui.UiTextSources
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * 失敗の文言は、iOS 版の `AuthError.errorDescription`（Services/AuthService.swift:208-231）をそのまま使う（設計書 :751）。
 * 「その他」だけは、設計書 :759 の決定どおり ErrorHandler.swift:129 の既定の文言にする
 * （iOS の AuthService は Firebase の localizedDescription をそのまま出すが、Android は SDK の英語の文言を画面に出さない）。
 *
 * 期待値はテストに直書きせず、iOS 版のソースを毎回読んで突き合わせる（UiStringsTest と同じやり方）。
 */
class AuthErrorMessagesTest {

    private val strings = UiTextSources.readStrings()

    /** [AuthErrorKind] と、iOS の `AuthError` の case 名の対応（AuthService.swift:177-187。unknown は別扱い）。 */
    private val iosCaseOf = mapOf(
        AuthErrorKind.INVALID_INPUT to "invalidInput",
        AuthErrorKind.INVALID_EMAIL to "invalidEmail",
        AuthErrorKind.WEAK_PASSWORD to "weakPassword",
        AuthErrorKind.EMAIL_ALREADY_IN_USE to "emailAlreadyInUse",
        AuthErrorKind.WRONG_PASSWORD to "wrongPassword",
        AuthErrorKind.USER_NOT_FOUND to "userNotFound",
        AuthErrorKind.NETWORK to "networkError",
        AuthErrorKind.TOO_MANY_REQUESTS to "tooManyRequests",
        AuthErrorKind.REQUIRES_RECENT_LOGIN to "requiresRecentLogin",
    )

    private fun resourceNameOf(kind: AuthErrorKind) = "auth_error_${kind.name.lowercase()}"

    @Test
    fun `失敗の文言はiOSのAuthErrorのerrorDescriptionと一致する`() {
        val ios = UiTextSources.switchReturns(UiTextSources.iosSource("Services/AuthService.swift"), "errorDescription")
        // 読み落としを「一致した」と誤らないよう、iOS の文字列を返す case が過不足なく読めたことを先に確かめる
        assertEquals(iosCaseOf.values.toSet(), ios.keys, "iOS の errorDescription の case を読み違えている")

        iosCaseOf.forEach { (kind, case) ->
            assertEquals(ios[case], strings[resourceNameOf(kind)], "strings.xml の ${resourceNameOf(kind)} が iOS の .$case と一致しない")
        }
    }

    @Test
    fun `その他の失敗の文言はiOSのErrorHandlerの既定の文言と一致する`() {
        val source = UiTextSources.iosSource("Utils/ErrorHandler.swift")
        val fallback = assertNotNull(
            Regex("""//\s*デフォルトメッセージ\s*\n\s*return\s+"([^"]*)"""").find(source)?.groupValues?.get(1),
            "iOS の ErrorHandler.getUserFriendlyMessage の既定の文言が見つからない（書き方が変わった可能性）",
        )

        assertEquals(fallback, strings[resourceNameOf(AuthErrorKind.UNKNOWN)])
    }

    @Test
    fun `全ての種類が、名前の決まったリソースに対応する`() {
        // when の対応を書き写して比べると同じ誤りを 2 回書くだけなので、生成された R の名前から引いて比べる
        AuthErrorKind.entries.forEach { kind ->
            val expected = R.string::class.java.getField(resourceNameOf(kind)).getInt(null)
            assertEquals(expected, authErrorMessageRes(kind), "$kind の文言のリソースが ${resourceNameOf(kind)} でない")
        }
    }
}
