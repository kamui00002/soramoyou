// ⭐️ エラーの説明（error_description）と、形の契約違反の説明の単体テスト（タスク 4.2・要件 15.8）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.ValueKind
import com.yoshidometoru.soramoyou.contract.document.Violation
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * iOS は `error_description` に `error.localizedDescription`（多くは画面に出す日本語の文言）を載せる
 * （LoggingService.swift:137・:141）。Android の [AppError] は文言を持たない（文言は画面側の担当）ので、
 * 値は iOS と揃えられない。代わりに、種類と判別に効く項目だけを決まった形の短い文字列にする。
 * 値（キャプション・ID など）は載せない。
 */
class AppErrorDescriptionTest {

    @Test
    fun `AppErrorの全ての種類を、種類名と判別の項目だけの決まった形で説明する`() {
        val expected = listOf(
            AppError.Auth(AuthErrorKind.WRONG_PASSWORD) to "Auth.WRONG_PASSWORD",
            AppError.Network to "Network",
            AppError.PermissionDenied to "PermissionDenied",
            AppError.NotFound to "NotFound",
            AppError.WriteBlocked(WriteCapability.POST_CREATE) to "WriteBlocked.POST_CREATE",
            AppError.ShapeViolation(
                listOf(Violation.MissingKey("likesCount"), Violation.UnexpectedKey("fcmToken")),
            ) to "ShapeViolation(count=2)",
            AppError.Validation(ValidationReason.CAPTION_TOO_LONG) to "Validation.CAPTION_TOO_LONG",
            AppError.ImageUnreadable(index = 2) to "ImageUnreadable(index=2)",
            AppError.ImageTooLarge(index = 0, bytes = 5_300_000L) to "ImageTooLarge(index=0, bytes=5300000)",
            AppError.StageFailed(DeletionStage.LIKES, AppError.Network) to "StageFailed.LIKES(Network)",
            AppError.Unknown("想定外") to "Unknown(想定外)",
        )

        expected.forEach { (error, description) ->
            assertEquals(description, error.toErrorDescription(), "対象: $error")
        }
    }

    @Test
    fun `段階で止まった失敗は、原因の説明を入れ子で含む`() {
        val nested = AppError.StageFailed(
            DeletionStage.USER,
            AppError.StageFailed(DeletionStage.LIKES, AppError.WriteBlocked(WriteCapability.ACCOUNT_DELETE)),
        )

        assertEquals("StageFailed.USER(StageFailed.LIKES(WriteBlocked.ACCOUNT_DELETE))", nested.toErrorDescription())
    }

    @Test
    fun `形の契約違反は、違反の種類とキーを並べて説明する（値は含めない）`() {
        val violations = listOf(
            Violation.MissingKey("likesCount"),
            Violation.UnexpectedKey("fcmToken"),
            Violation.WrongKind("images[0].width", ValueKind.STR),
            Violation.OutOfRange("caption", "2000文字を超える"),
        )

        assertEquals(
            "missing:likesCount, unexpected:fcmToken, wrong_kind:images[0].width=STR, out_of_range:caption(2000文字を超える)",
            violations.toViolationsDescription(),
        )
    }
}
