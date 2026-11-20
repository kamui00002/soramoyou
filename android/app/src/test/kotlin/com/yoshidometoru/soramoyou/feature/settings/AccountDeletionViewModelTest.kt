// ⭐️ アカウントの削除の画面の状態の単体テスト（タスク 31.5・要件 12.2・12.4・12.5・12.7・16.2）
package com.yoshidometoru.soramoyou.feature.settings

import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.feature.RecordingFeatureAnalytics
import com.yoshidometoru.soramoyou.feature.immediateScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 偽物の削除は、テストが結果を渡すまで待つ。スコープは Unconfined なので、結果を渡すとその場で続きが進む。
 * 削除の手順そのもの（段階の順・記録）は DefaultAccountDeletionServiceTest が確かめるので、ここでは「画面の側が、いつ部品を呼び、
 * 結果をどう表示の状態にするか」を見る。
 */
class AccountDeletionViewModelTest {

    private val service = FakeAccountDeletionService()
    private val analytics = RecordingFeatureAnalytics()
    private val online = MutableStateFlow(true)

    private fun viewModel() = AccountDeletionViewModel(
        service = service,
        analytics = analytics,
        isOnline = online,
        scope = immediateScope(),
    )

    /** パスワードを入れて、確認のダイアログで「削除する」まで押した ViewModel（部品の結果を待っている）。 */
    private fun deleting(password: String = PASSWORD): AccountDeletionViewModel = viewModel().also {
        it.onPasswordChange(password)
        it.requestDelete()
        it.confirmDelete()
    }

    /** [error] で止まった ViewModel。 */
    private fun failedWith(error: AppError): AccountDeletionViewModel = deleting().also { service.completeLast(AppResult.Err(error)) }

    // ── 始める前 ──

    @Test
    fun `作った直後は、入力も失敗も無く、削除中でも完了でもない`() {
        val state = viewModel().state.value

        assertEquals("", state.password)
        assertFalse(state.passwordMissing)
        assertFalse(state.confirming)
        assertFalse(state.isDeleting)
        assertNull(state.failure)
        assertFalse(state.completed)
        assertFalse(state.canRetry)
    }

    @Test
    fun `パスワードが空なら始めない（確認も出さず、部品も呼ばず、理由を出す）`() {
        val vm = viewModel()

        vm.requestDelete()
        vm.confirmDelete()

        assertTrue(vm.state.value.passwordMissing)
        assertFalse(vm.state.value.confirming)
        assertFalse(vm.state.value.isDeleting)
        assertEquals(emptyList(), service.deleteCalls)
        // 入力の不備なので記録しない（ご意見・ご要望の空の本文と同じ）
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `パスワードを入れると、空のまま押した理由は消える`() {
        val vm = viewModel()
        vm.requestDelete()

        vm.onPasswordChange("a")

        assertEquals("a", vm.state.value.password)
        assertFalse(vm.state.value.passwordMissing)
    }

    @Test
    fun `空白だけのパスワードも削らずにそのまま渡す（ログインと同じ）`() {
        deleting(password = " pass ")

        assertEquals(listOf(" pass "), service.deleteCalls)
    }

    // ── 確認 ──

    @Test
    fun `確認のダイアログで削除するを押すまで始めない`() {
        val vm = viewModel()
        vm.onPasswordChange(PASSWORD)

        vm.requestDelete()
        assertTrue(vm.state.value.confirming)
        assertEquals(emptyList(), service.deleteCalls)

        vm.cancelDelete()
        assertFalse(vm.state.value.confirming)
        assertEquals(emptyList(), service.deleteCalls)

        // ダイアログを出していないのに「削除する」が届いても始めない
        vm.confirmDelete()
        assertEquals(emptyList(), service.deleteCalls)

        vm.requestDelete()
        vm.confirmDelete()
        assertEquals(listOf(PASSWORD), service.deleteCalls)
        assertFalse(vm.state.value.confirming)
        assertTrue(vm.state.value.isDeleting)
    }

    @Test
    fun `オフラインの間は始めない`() {
        online.value = false
        val vm = viewModel()
        vm.onPasswordChange(PASSWORD)

        vm.requestDelete()

        assertFalse(vm.state.value.confirming)
        assertEquals(emptyList(), service.deleteCalls)
    }

    @Test
    fun `確認のダイアログを出した後にオフラインになったら、削除するを押しても始めずにダイアログを閉じる`() {
        val vm = viewModel()
        vm.onPasswordChange(PASSWORD)
        vm.requestDelete()
        assertTrue(vm.state.value.confirming)

        online.value = false
        vm.confirmDelete()

        // 部品を呼ばない（呼ぶと再認証が通信で失敗し、その失敗が記録に積もる）。画面は押せなくして案内を出している
        assertFalse(vm.state.value.confirming, "ダイアログは閉じる")
        assertFalse(vm.state.value.isDeleting)
        assertEquals(emptyList(), service.deleteCalls)
        assertEquals(emptyList(), analytics.errors)

        // 接続が戻れば「確認して削除」からやり直せる
        online.value = true
        vm.requestDelete()
        vm.confirmDelete()
        assertEquals(listOf(PASSWORD), service.deleteCalls)
    }

    // ── 削除中 ──

    @Test
    fun `削除中に何度押しても、部品の削除は1回だけ`() {
        val vm = deleting()

        vm.confirmDelete()
        vm.requestDelete()
        vm.confirmDelete()
        vm.retry()

        assertEquals(1, service.deleteCalls.size)
        assertTrue(vm.state.value.isDeleting)
        assertFalse(vm.state.value.confirming, "削除中に確認のダイアログを出し直さない")
        assertFalse(vm.state.value.canRetry, "削除中は再試行を出さない")
    }

    @Test
    fun `段階の表示は部品の段階に従う`() {
        val vm = deleting()

        // 部品が最初の段階を立てる前は「アカウントを削除中...」
        assertNull(vm.stage.value)
        assertEquals(DeletionText(R.string.account_deleting), deletionProgressText(vm.stage.value))

        service.stageFlow.value = DeletionStage.REAUTH
        assertEquals(DeletionStage.REAUTH, vm.stage.value)
        assertEquals(DeletionText(R.string.account_delete_progress_reauth), deletionProgressText(vm.stage.value))

        service.stageFlow.value = DeletionStage.LIKES
        assertEquals(DeletionStage.LIKES, vm.stage.value)
        assertEquals(
            DeletionText(R.string.account_delete_progress, R.string.account_delete_stage_likes),
            deletionProgressText(vm.stage.value),
        )
    }

    // ── 成功 ──

    @Test
    fun `成功したら完了の状態にし、記録し直さず、もう始めない`() {
        val vm = deleting()

        service.completeLast(AppResult.Ok(Unit))

        val state = vm.state.value
        assertTrue(state.completed)
        assertFalse(state.isDeleting)
        assertNull(state.failure)
        assertFalse(state.canRetry)
        assertEquals("", state.password, "使い終わったパスワードは持ち続けない")
        assertEquals(emptyList(), analytics.errors)

        vm.onPasswordChange(PASSWORD)
        vm.requestDelete()
        vm.confirmDelete()
        vm.retry()
        assertEquals(1, service.deleteCalls.size)
    }

    // ── 失敗と再試行 ──

    @Test
    fun `パスワードの誤りは、本人確認の失敗として出し、入れ直してもらってから再試行できる`() {
        val error = AppError.StageFailed(DeletionStage.REAUTH, AppError.Auth(AuthErrorKind.WRONG_PASSWORD))
        val vm = failedWith(error)

        val state = vm.state.value
        assertEquals(error, state.failure)
        assertFalse(state.isDeleting)
        assertTrue(state.canRetry)
        assertEquals("", state.password, "誤ったパスワードは空にして入れ直してもらう")
        assertEquals(
            DeletionFailureText(DeletionText(R.string.account_delete_failed_reauth_title), R.string.account_delete_wrong_password, R.string.account_delete_failed_reauth_message),
            deletionFailureText(state.failure!!),
        )
        // 部品が記録済みなので、画面は記録し直さない
        assertEquals(emptyList(), analytics.errors)

        vm.onPasswordChange("correct")
        vm.retry()
        assertEquals(listOf(PASSWORD, "correct"), service.deleteCalls)
        assertTrue(vm.state.value.isDeleting)
        assertNull(vm.state.value.failure, "やり直したら前の失敗は消す")
        assertFalse(vm.state.value.confirming, "再試行は確認のダイアログを出し直さない")
    }

    @Test
    fun `途中の段階で止まったら、段階が分かる文言を出し、同じパスワードのまま再試行できる`() {
        val error = AppError.StageFailed(DeletionStage.LIKES, AppError.Network)
        val vm = failedWith(error)

        val state = vm.state.value
        assertEquals(error, state.failure)
        assertTrue(state.canRetry)
        assertEquals(PASSWORD, state.password, "通信の断絶ではパスワードを残す（1 回押すだけで再試行できる）")
        assertEquals(
            DeletionFailureText(
                DeletionText(R.string.account_delete_failed_stage_title, R.string.account_delete_stage_likes),
                R.string.offline_title,
                R.string.account_delete_failed_stage_message,
            ),
            deletionFailureText(state.failure!!),
        )
        assertEquals(emptyList(), analytics.errors)

        vm.retry()
        assertEquals(listOf(PASSWORD, PASSWORD), service.deleteCalls)
        assertTrue(vm.state.value.isDeleting)
    }

    @Test
    fun `アカウントの削除で最近のログインが必要と断られたら、パスワードを入れ直すと完了すると出す`() {
        val error = AppError.StageFailed(DeletionStage.AUTH, AppError.Auth(AuthErrorKind.REQUIRES_RECENT_LOGIN))
        val vm = failedWith(error)

        val state = vm.state.value
        assertTrue(state.canRetry)
        assertEquals("", state.password)
        assertEquals(
            DeletionFailureText(
                DeletionText(R.string.account_delete_failed_stage_title, R.string.account_delete_stage_auth),
                null,
                R.string.account_delete_requires_recent_login,
            ),
            deletionFailureText(state.failure!!),
        )
        assertEquals(emptyList(), analytics.errors)

        // 入れ直さずに再試行しても始めない（理由を出す）
        vm.retry()
        assertTrue(vm.state.value.passwordMissing)
        assertEquals(1, service.deleteCalls.size)
        assertTrue(vm.state.value.canRetry, "失敗は残して、再試行も出したまま")

        vm.onPasswordChange(PASSWORD)
        vm.retry()
        assertEquals(2, service.deleteCalls.size)
    }

    @Test
    fun `未ログインで断られても、記録し直さずに再試行を出す`() {
        val vm = failedWith(AppError.PermissionDenied)

        assertEquals(AppError.PermissionDenied, vm.state.value.failure)
        assertTrue(vm.state.value.canRetry)
        assertEquals(PASSWORD, vm.state.value.password)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `オフラインの間は再試行も始めない`() {
        val vm = failedWith(AppError.StageFailed(DeletionStage.POSTS, AppError.Network))
        online.value = false

        vm.retry()

        assertEquals(1, service.deleteCalls.size)
        assertTrue(vm.state.value.canRetry)
    }

    // ── 削除の受付ページ ──

    @Test
    fun `Webの削除の受付ページは、公開した窓口のアドレス`() {
        assertEquals("https://soramoyou-ios.web.app/delete-account/", viewModel().requestPageUrl)
        assertEquals(DELETION_REQUEST_PAGE_URL, viewModel().requestPageUrl)
    }

    @Test
    fun `受付ページを開けなかったら、記録して、アドレスを文字で出す`() {
        val vm = viewModel()

        vm.onRequestPageOpenFailed(IllegalArgumentException("Can't open"))

        assertTrue(vm.state.value.requestPageOpenFailed)
        assertEquals(
            listOf<Pair<AppError, String>>(AppError.Unknown("IllegalArgumentException") to "AccountDeletionViewModel.openRequestPage"),
            analytics.errors,
        )
    }

    // ── パスワードの扱い ──

    @Test
    fun `状態を文字列にしても、パスワードは出ない`() {
        val vm = viewModel()
        vm.onPasswordChange("secret-pass")

        assertFalse("secret-pass" in vm.state.value.toString())
    }

    private companion object {
        const val PASSWORD = "pass1234"
    }
}
