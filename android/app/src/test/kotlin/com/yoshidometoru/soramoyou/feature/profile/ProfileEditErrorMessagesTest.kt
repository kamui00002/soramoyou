// ⭐️ プロフィール編集の保存の失敗から、画面に出す文言への対応の単体テスト（タスク 16.3・要件 10.8・10.10）
package com.yoshidometoru.soramoyou.feature.profile

import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.feature.feed.feedErrorMessageRes
import kotlin.test.Test
import kotlin.test.assertEquals

/** 編集だけの文言（上限・大きすぎる画像・読めない写真）を引き当て、それ以外はフィードと同じ文言にすることを確かめる。 */
class ProfileEditErrorMessagesTest {

    @Test
    fun `入力の上限の超過は表示名・自己紹介の上限の文言`() {
        assertEquals(R.string.profile_edit_too_long, profileEditErrorMessageRes(AppError.Validation(ValidationReason.DISPLAY_NAME_TOO_LONG)))
        assertEquals(R.string.profile_edit_too_long, profileEditErrorMessageRes(AppError.Validation(ValidationReason.BIO_TOO_LONG)))
    }

    @Test
    fun `大きすぎる画像と読めない写真は、それぞれの文言`() {
        assertEquals(R.string.profile_edit_image_too_large, profileEditErrorMessageRes(AppError.ImageTooLarge(0, 5_242_880)))
        assertEquals(R.string.profile_edit_image_unreadable, profileEditErrorMessageRes(AppError.ImageUnreadable(0)))
    }

    @Test
    fun `それ以外はフィードの取得の失敗と同じ文言`() {
        listOf(
            AppError.Network,
            AppError.PermissionDenied,
            AppError.NotFound,
            AppError.Auth(AuthErrorKind.UNKNOWN),
            AppError.WriteBlocked(WriteCapability.PROFILE_EDIT),
            AppError.ShapeViolation(emptyList()),
            AppError.StageFailed(DeletionStage.USER, AppError.Network),
            AppError.Unknown("x"),
        ).forEach { error ->
            assertEquals(feedErrorMessageRes(error), profileEditErrorMessageRes(error), "$error の文言")
        }
    }
}
