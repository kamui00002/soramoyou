// ⭐️ 設定画面のログアウトと項目の出し分けの単体テスト（タスク 8.3・29.2・31.5・要件 2.9・11.5・12.1・16.2）
package com.yoshidometoru.soramoyou.feature.settings

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.feature.FakeAuthRepository
import com.yoshidometoru.soramoyou.feature.FakeWriteGate
import com.yoshidometoru.soramoyou.feature.RecordingFeatureAnalytics
import com.yoshidometoru.soramoyou.feature.immediateScope
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SettingsViewModelTest {

    private val repository = FakeAuthRepository()
    private val analytics = RecordingFeatureAnalytics()
    private val viewModel = SettingsViewModel(repository, FakeWriteGate(setOf(WriteCapability.BLOCK)), analytics, immediateScope())

    @Test
    fun `ログアウトの間は処理中にして、二重に呼ばない`() {
        viewModel.signOut()
        assertTrue(viewModel.state.value.isSigningOut)
        viewModel.signOut()

        repository.signOutResult.complete(AppResult.Ok(Unit))

        assertEquals(1, repository.signOutCalls)
        assertFalse(viewModel.state.value.isSigningOut)
        assertNull(viewModel.state.value.error)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `失敗したら文言の種類を出して記録する`() {
        viewModel.signOut()
        repository.signOutResult.complete(AppResult.Err(AppError.Auth(AuthErrorKind.UNKNOWN)))

        assertEquals(AuthErrorKind.UNKNOWN, viewModel.state.value.error)
        assertFalse(viewModel.state.value.isSigningOut)
        assertEquals(listOf<Pair<AppError, String>>(AppError.Auth(AuthErrorKind.UNKNOWN) to "SettingsViewModel.signOut"), analytics.errors)
    }

    @Test
    fun `ブロックの書き込みが有効なビルドだけ、ブロック中のユーザーの項目を出す`() {
        // 解除（arrayRemove）は BLOCK の書き込み。M4 以前のビルドでは項目ごと出さない（ほかの導線の切り替えと同じ）
        assertTrue(viewModel.canManageBlocks)
        assertFalse(SettingsViewModel(repository, FakeWriteGate(setOf(WriteCapability.REPORT)), analytics, immediateScope()).canManageBlocks)
        assertFalse(SettingsViewModel(repository, FakeWriteGate(emptySet()), analytics, immediateScope()).canManageBlocks)
    }

    @Test
    fun `フィードバックの書き込みが有効なビルドだけ、ご意見・ご要望の項目を出す`() {
        // 送信（feedback の作成）は FEEDBACK の書き込み。M4 以前のビルドでは項目ごと出さない（ブロック中のユーザーと同じ切り替え）
        val withFeedback = SettingsViewModel(repository, FakeWriteGate(setOf(WriteCapability.FEEDBACK)), analytics, immediateScope())
        assertTrue(withFeedback.canSendFeedback)
        assertFalse(withFeedback.canManageBlocks, "ブロックの可否とは別に決まる")
        assertFalse(viewModel.canSendFeedback, "BLOCK だけが有効なビルドでは出さない")
        assertFalse(SettingsViewModel(repository, FakeWriteGate(emptySet()), analytics, immediateScope()).canSendFeedback)
    }

    @Test
    fun `退会の書き込みが有効なビルドだけ、アカウントを削除の項目を出す`() {
        // 退会（データの削除）は ACCOUNT_DELETE の書き込み。M4 以前のビルドでは項目ごと出さない（ほかの項目と同じ切り替え。タスク 31.5）
        val withDelete = SettingsViewModel(repository, FakeWriteGate(setOf(WriteCapability.ACCOUNT_DELETE)), analytics, immediateScope())
        assertTrue(withDelete.canDeleteAccount)
        assertFalse(withDelete.canSendFeedback, "ほかの項目の可否とは別に決まる")
        assertFalse(viewModel.canDeleteAccount, "BLOCK だけが有効なビルドでは出さない")
        assertFalse(SettingsViewModel(repository, FakeWriteGate(emptySet()), analytics, immediateScope()).canDeleteAccount)
    }
}
