// ⭐️ フィードバックの送信の失敗から、画面に出す文言への対応の単体テスト（タスク 30・要件 13.3・13.6）
package com.yoshidometoru.soramoyou.feature.feedback

import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.feature.feed.feedErrorMessageRes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** 本文の範囲の案内（空白だけ・1000 文字超過）を引き当て、それ以外はフィードと同じ文言にすることを確かめる。 */
class FeedbackErrorMessagesTest {

    @Test
    fun `空白だけも1000文字超過も、1〜1000文字で入力する案内の文言`() {
        assertEquals(R.string.feedback_message_range, feedbackErrorMessageRes(AppError.Validation(ValidationReason.FEEDBACK_BLANK)))
        assertEquals(R.string.feedback_message_range, feedbackErrorMessageRes(AppError.Validation(ValidationReason.FEEDBACK_TOO_LONG)))
    }

    @Test
    fun `フィードバックでは起きない入力の不備は、汎用の失敗の文言`() {
        listOf(
            ValidationReason.NO_IMAGES,
            ValidationReason.TOO_MANY_IMAGES,
            ValidationReason.CAPTION_TOO_LONG,
            ValidationReason.TOO_MANY_HASHTAGS,
            ValidationReason.PUBLISH_IN_PROGRESS,
            ValidationReason.DISPLAY_NAME_TOO_LONG,
            ValidationReason.BIO_TOO_LONG,
        ).forEach { reason ->
            assertEquals(R.string.state_error_title, feedbackErrorMessageRes(AppError.Validation(reason)), "$reason")
        }
    }

    @Test
    fun `それ以外はフィードの取得の失敗と同じ文言`() {
        listOf(
            AppError.Network,
            AppError.PermissionDenied,
            AppError.NotFound,
            AppError.Auth(AuthErrorKind.UNKNOWN),
            AppError.WriteBlocked(WriteCapability.FEEDBACK),
            AppError.ShapeViolation(emptyList()),
            AppError.ImageUnreadable(0),
            AppError.ImageTooLarge(0, 5_242_880),
            AppError.StageFailed(DeletionStage.USER, AppError.Network),
            AppError.Unknown("x"),
        ).forEach { error ->
            assertEquals(feedErrorMessageRes(error), feedbackErrorMessageRes(error), "$error の文言")
        }
    }

    @Test
    fun `本文の入力の不備だけが「失敗」の見出しを付けない`() {
        assertTrue(isFeedbackInputProblem(AppError.Validation(ValidationReason.FEEDBACK_BLANK)))
        assertTrue(isFeedbackInputProblem(AppError.Validation(ValidationReason.FEEDBACK_TOO_LONG)))
        listOf(
            AppError.Network,
            AppError.PermissionDenied,
            AppError.WriteBlocked(WriteCapability.FEEDBACK),
            AppError.Validation(ValidationReason.CAPTION_TOO_LONG),
            AppError.Unknown("x"),
        ).forEach { error ->
            assertFalse(isFeedbackInputProblem(error), "$error")
        }
    }
}
