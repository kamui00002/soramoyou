// ⭐️ 投稿の失敗から、画面に出す文言への対応の単体テスト（タスク 23.5・要件 7.21・7.22）
package com.yoshidometoru.soramoyou.feature.compose

import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.feature.feed.feedErrorMessageRes
import kotlin.test.Test
import kotlin.test.assertEquals

/** 投稿だけの文言（前の投稿の処理中・上限・写真）を引き当て、それ以外はフィードと同じ文言にすることを確かめる。 */
class PostErrorMessagesTest {

    private fun validation(reason: ValidationReason) = AppError.Validation(reason)

    @Test
    fun `前の投稿の処理中は、保存が終わってから投稿し直す案内`() {
        assertEquals(R.string.compose_error_publish_in_progress, postErrorMessageRes(validation(ValidationReason.PUBLISH_IN_PROGRESS)))
    }

    @Test
    fun `キャプションとハッシュタグの上限の超過は、入力欄の下の案内と同じ文言`() {
        assertEquals(R.string.compose_caption_too_long, postErrorMessageRes(validation(ValidationReason.CAPTION_TOO_LONG)))
        assertEquals(R.string.compose_hashtags_too_many, postErrorMessageRes(validation(ValidationReason.TOO_MANY_HASHTAGS)))
    }

    @Test
    fun `写真の枚数の不備は、画像が選択されていない文言`() {
        assertEquals(R.string.compose_error_no_images, postErrorMessageRes(validation(ValidationReason.NO_IMAGES)))
        assertEquals(R.string.compose_error_no_images, postErrorMessageRes(validation(ValidationReason.TOO_MANY_IMAGES)))
    }

    @Test
    fun `大きすぎる画像と読めない写真は、プロフィール編集と同じ文言`() {
        assertEquals(R.string.profile_edit_image_too_large, postErrorMessageRes(AppError.ImageTooLarge(2, 6_000_000)))
        assertEquals(R.string.profile_edit_image_unreadable, postErrorMessageRes(AppError.ImageUnreadable(0)))
    }

    @Test
    fun `通信の失敗と権限の拒否は、それぞれの文言`() {
        assertEquals(R.string.offline_title, postErrorMessageRes(AppError.Network))
        assertEquals(R.string.state_error_permission, postErrorMessageRes(AppError.PermissionDenied))
    }

    @Test
    fun `それ以外はフィードの取得の失敗と同じ文言`() {
        listOf(
            AppError.NotFound,
            AppError.Auth(AuthErrorKind.UNKNOWN),
            AppError.WriteBlocked(WriteCapability.POST_CREATE),
            AppError.ShapeViolation(emptyList()),
            AppError.StageFailed(DeletionStage.USER, AppError.Network),
            AppError.Unknown("x"),
        ).forEach { error ->
            assertEquals(feedErrorMessageRes(error), postErrorMessageRes(error), "$error の文言")
        }
        // 投稿では起きない入力の不備は、汎用の文言
        listOf(
            ValidationReason.DISPLAY_NAME_TOO_LONG,
            ValidationReason.BIO_TOO_LONG,
            ValidationReason.FEEDBACK_BLANK,
            ValidationReason.FEEDBACK_TOO_LONG,
        ).forEach { reason ->
            assertEquals(R.string.state_error_title, postErrorMessageRes(validation(reason)), "$reason の文言")
        }
    }

    // ── postErrorText（Kiro android-edit-tools タスク 7・A2。上の postErrorMessageRes の確かめは変えない） ──

    @Test
    fun `postErrorText 読めない写真は何枚目かを入れた文言になる（番号は0から数えた値に1を足す）`() {
        assertEquals(
            PostErrorText(R.string.compose_error_image_unreadable_at, listOf(3)),
            postErrorText(AppError.ImageUnreadable(2)),
        )
        assertEquals(
            PostErrorText(R.string.compose_error_image_unreadable_at, listOf(1)),
            postErrorText(AppError.ImageUnreadable(0)),
        )
    }

    @Test
    fun `postErrorText 読めない写真以外は今の文言で、値は空`() {
        listOf(
            validation(ValidationReason.PUBLISH_IN_PROGRESS),
            validation(ValidationReason.CAPTION_TOO_LONG),
            validation(ValidationReason.TOO_MANY_HASHTAGS),
            validation(ValidationReason.NO_IMAGES),
            validation(ValidationReason.TOO_MANY_IMAGES),
            validation(ValidationReason.BIO_TOO_LONG),
            AppError.ImageTooLarge(2, 6_000_000),
            AppError.Network,
            AppError.PermissionDenied,
            AppError.NotFound,
            AppError.Auth(AuthErrorKind.UNKNOWN),
            AppError.WriteBlocked(WriteCapability.POST_CREATE),
            AppError.ShapeViolation(emptyList()),
            AppError.StageFailed(DeletionStage.USER, AppError.Network),
            AppError.Unknown("x"),
        ).forEach { error ->
            assertEquals(PostErrorText(postErrorMessageRes(error), emptyList()), postErrorText(error), "$error の文言")
        }
    }
}
