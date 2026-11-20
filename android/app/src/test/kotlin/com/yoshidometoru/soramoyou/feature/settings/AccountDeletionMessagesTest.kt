// ⭐️ アカウントの削除の段階と失敗から、画面に出す文言への対応の単体テスト（タスク 31.5・要件 12.4・12.5・16.2）
package com.yoshidometoru.soramoyou.feature.settings

import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.feature.auth.authErrorMessageRes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AccountDeletionMessagesTest {

    private fun stageFailed(stage: DeletionStage, cause: AppError) = AppError.StageFailed(stage, cause)

    // ── 段階の名前と、削除中の表示 ──

    @Test
    fun `段階ごとに別の名前を出す（どこで止まったかが分かる）`() {
        val names = DeletionStage.entries.map(::deletionStageNameRes)

        assertEquals(DeletionStage.entries.size, names.toSet().size, "同じ名前の段階がある: $names")
    }

    @Test
    fun `削除中の表示は、再認証は本人確認、それ以外は段階の名前を入れた文言`() {
        assertEquals(DeletionText(R.string.account_deleting), deletionProgressText(null))
        assertEquals(DeletionText(R.string.account_delete_progress_reauth), deletionProgressText(DeletionStage.REAUTH))
        DeletionStage.entries.filter { it != DeletionStage.REAUTH }.forEach { stage ->
            assertEquals(DeletionText(R.string.account_delete_progress, deletionStageNameRes(stage)), deletionProgressText(stage), "$stage")
        }
    }

    @Test
    fun `画像の2段階とユーザー文書と認証のアカウントは、利用者に分かる名前`() {
        assertEquals(R.string.account_delete_stage_post_images, deletionStageNameRes(DeletionStage.POST_IMAGES))
        assertEquals(R.string.account_delete_stage_profile_image, deletionStageNameRes(DeletionStage.PROFILE_IMAGE))
        assertEquals(R.string.account_delete_stage_user, deletionStageNameRes(DeletionStage.USER))
        assertEquals(R.string.account_delete_stage_auth, deletionStageNameRes(DeletionStage.AUTH))
    }

    // ── 失敗 ──

    @Test
    fun `再認証で止まったら、本人確認の失敗と、まだ何も削除していないことを出す`() {
        val wrong = deletionFailureText(stageFailed(DeletionStage.REAUTH, AppError.Auth(AuthErrorKind.WRONG_PASSWORD)))
        assertEquals(DeletionText(R.string.account_delete_failed_reauth_title), wrong.title)
        assertEquals(R.string.account_delete_wrong_password, wrong.reason)
        assertEquals(R.string.account_delete_failed_reauth_message, wrong.detail)

        // 空のパスワード（画面が先に止めるので届かないはず）は、入力の案内
        assertEquals(
            R.string.account_delete_password_required,
            deletionFailureText(stageFailed(DeletionStage.REAUTH, AppError.Auth(AuthErrorKind.INVALID_INPUT))).reason,
        )
        // ほかの認証の失敗は、ログインと同じ iOS の文言
        listOf(AuthErrorKind.NETWORK, AuthErrorKind.TOO_MANY_REQUESTS, AuthErrorKind.USER_NOT_FOUND, AuthErrorKind.UNKNOWN).forEach { kind ->
            val text = deletionFailureText(stageFailed(DeletionStage.REAUTH, AppError.Auth(kind)))
            assertEquals(authErrorMessageRes(kind), text.reason, "$kind")
            assertEquals(R.string.account_delete_failed_reauth_message, text.detail, "$kind")
        }
        // 認証でない原因（部品が例外を Unknown にしたとき）は、原因を言わない
        assertNull(deletionFailureText(stageFailed(DeletionStage.REAUTH, AppError.Unknown("IllegalStateException"))).reason)
    }

    @Test
    fun `途中の段階で止まったら、段階の名前と、それより前は削除済みで再試行で残りを消すことを出す`() {
        DeletionStage.entries.filter { it != DeletionStage.REAUTH }.forEach { stage ->
            val text = deletionFailureText(stageFailed(stage, AppError.Unknown("x")))
            assertEquals(DeletionText(R.string.account_delete_failed_stage_title, deletionStageNameRes(stage)), text.title, "$stage")
            assertNull(text.reason, "$stage")
            assertEquals(R.string.account_delete_failed_stage_message, text.detail, "$stage")
        }
    }

    @Test
    fun `通信の断絶なら、その原因も出す`() {
        assertEquals(R.string.offline_title, deletionFailureText(stageFailed(DeletionStage.POSTS, AppError.Network)).reason)
        assertEquals(
            R.string.offline_title,
            deletionFailureText(stageFailed(DeletionStage.AUTH, AppError.Auth(AuthErrorKind.NETWORK))).reason,
        )
    }

    @Test
    fun `途中の段階の権限の拒否と不在は、権限がないと言い切らない`() {
        // 取ってから消すまでの間に別の操作で消えた文書でも PermissionDenied になる（AccountDeletionService の注記）。再試行で取り直せば通る
        listOf(AppError.PermissionDenied, AppError.NotFound, AppError.WriteBlocked(WriteCapability.ACCOUNT_DELETE)).forEach { cause ->
            val text = deletionFailureText(stageFailed(DeletionStage.FOLLOWS_AS_FOLLOWEE, cause))
            assertNull(text.reason, "$cause")
            assertNotEquals(R.string.state_error_permission, text.detail, "$cause")
            assertEquals(R.string.account_delete_failed_stage_message, text.detail, "$cause")
        }
    }

    @Test
    fun `アカウントの削除で最近のログインが必要なら、データは済んでいてパスワードを入れ直すと完了すると出す`() {
        val text = deletionFailureText(stageFailed(DeletionStage.AUTH, AppError.Auth(AuthErrorKind.REQUIRES_RECENT_LOGIN)))

        assertEquals(DeletionText(R.string.account_delete_failed_stage_title, R.string.account_delete_stage_auth), text.title)
        assertNull(text.reason)
        assertEquals(R.string.account_delete_requires_recent_login, text.detail)
    }

    @Test
    fun `段階の無い失敗（未ログイン）は、削除できなかったことともう一度の案内`() {
        val text = deletionFailureText(AppError.PermissionDenied)

        assertEquals(DeletionText(R.string.account_delete_failed_title), text.title)
        assertNull(text.reason)
        assertEquals(R.string.auth_error_unknown, text.detail)
    }

    // ── パスワードを入れ直してもらうか ──

    @Test
    fun `パスワードが原因の失敗だけ、パスワードを入れ直してもらう`() {
        assertTrue(needsPasswordAgain(stageFailed(DeletionStage.REAUTH, AppError.Auth(AuthErrorKind.WRONG_PASSWORD))))
        assertTrue(needsPasswordAgain(stageFailed(DeletionStage.REAUTH, AppError.Auth(AuthErrorKind.INVALID_INPUT))))
        assertTrue(needsPasswordAgain(stageFailed(DeletionStage.AUTH, AppError.Auth(AuthErrorKind.REQUIRES_RECENT_LOGIN))))

        assertFalse(needsPasswordAgain(stageFailed(DeletionStage.REAUTH, AppError.Auth(AuthErrorKind.NETWORK))))
        assertFalse(needsPasswordAgain(stageFailed(DeletionStage.REAUTH, AppError.Auth(AuthErrorKind.TOO_MANY_REQUESTS))))
        assertFalse(needsPasswordAgain(stageFailed(DeletionStage.LIKES, AppError.Network)))
        assertFalse(needsPasswordAgain(stageFailed(DeletionStage.POSTS, AppError.PermissionDenied)))
        assertFalse(needsPasswordAgain(AppError.PermissionDenied))
    }
}
