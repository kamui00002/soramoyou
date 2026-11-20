// ⭐️ フィードバック送信の画面の状態の単体テスト（タスク 30・要件 13.2・13.3・13.5・13.6・16.2）
package com.yoshidometoru.soramoyou.feature.feedback

import androidx.lifecycle.SavedStateHandle
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.document.FeedbackInput
import com.yoshidometoru.soramoyou.contract.model.FeedbackCategory
import com.yoshidometoru.soramoyou.data.repository.FeedbackRepository
import com.yoshidometoru.soramoyou.feature.RecordingFeatureAnalytics
import com.yoshidometoru.soramoyou.feature.afterProcessDeath
import com.yoshidometoru.soramoyou.feature.immediateScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 偽物の送信は、テストが結果を渡すまで待つ。スコープは Unconfined なので、結果を渡すとその場で続きが進む。
 * 検査は FeedbackRepository の側でも行うので（DefaultFeedbackRepositoryTest）、ここでは「画面の側が先に止めて、偽物に届かない」ことを見る。
 */
class FeedbackViewModelTest {

    private val repository = FakeFeedbackRepository()
    private val analytics = RecordingFeatureAnalytics()
    private val online = MutableStateFlow(true)
    private var uid: Uid? = Uid("UID-1")
    private val savedState = SavedStateHandle()

    private fun viewModel(savedState: SavedStateHandle = this.savedState) = FeedbackViewModel(
        repository = repository,
        currentUid = { uid },
        appVersion = APP_VERSION,
        deviceInfo = DEVICE_INFO,
        analytics = analytics,
        isOnline = online,
        savedState = savedState,
        scope = immediateScope(),
    )

    /** プロセスが落ちて、この画面を作り直した ViewModel（[savedState] の中身だけが戻る）。 */
    private fun recreated() = viewModel(savedState.afterProcessDeath())

    /** 本文を入れた ViewModel。 */
    private fun typed(message: String): FeedbackViewModel = viewModel().also { it.onMessageChange(message) }

    // ── 入力 ──

    @Test
    fun `作った直後は、種別は不具合で、本文は空で、送信中でも送信済みでもない`() {
        val state = viewModel().state.value

        assertEquals(FeedbackCategory.BUG, state.category)
        assertEquals("", state.message)
        assertFalse(state.isSending)
        assertFalse(state.submitted)
        assertNull(state.error)
        assertEquals(0, state.trimmedLength)
    }

    @Test
    fun `本文と種別を入力できる`() {
        val vm = viewModel()

        vm.onMessageChange("ここが変です")
        vm.onCategoryChange(FeedbackCategory.OTHER)

        assertEquals("ここが変です", vm.state.value.message)
        assertEquals(FeedbackCategory.OTHER, vm.state.value.category)
    }

    @Test
    fun `文字数は送る本文（前後の空白を除いたもの）のUTF-16の長さで数え、1000を超えたら超過`() {
        assertFalse(typed("あ".repeat(1000)).state.value.isOverLimit)
        assertTrue(typed("あ".repeat(1001)).state.value.isOverLimit)
        // 前後の空白は数えない
        val padded = typed("　 " + "あ".repeat(1000) + "\n")
        assertEquals(1000, padded.state.value.trimmedLength)
        assertFalse(padded.state.value.isOverLimit)
        // 絵文字は 1 つで 2（rules の size() と同じ）
        assertEquals(1002, typed("😀".repeat(501)).state.value.trimmedLength)
        assertTrue(typed("😀".repeat(501)).state.value.isOverLimit)
    }

    // ── 送れない本文（要件 13.3） ──

    @Test
    fun `空白だけの本文は、送らずに理由を出す（半角・全角の空白・改行・タブ・空）`() {
        for (message in listOf("", " ", "　", "\n\t ", "  　\n　  ")) {
            val vm = typed(message)

            vm.submit()

            assertEquals(AppError.Validation(ValidationReason.FEEDBACK_BLANK), vm.state.value.error, "「$message」")
            assertFalse(vm.state.value.isSending, "「$message」")
            assertFalse(vm.state.value.submitted, "「$message」")
            assertEquals(message, vm.state.value.message, "入力は残す")
        }
        assertTrue(repository.submitCalls.isEmpty(), "送っている: ${repository.submitCalls}")
        // 画面が先に止める入力の不備は記録しない
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `1000文字を超える本文は、送らずに理由を出す。1000文字ちょうどは送る`() {
        val tooLong = typed("あ".repeat(1001))
        tooLong.submit()

        assertEquals(AppError.Validation(ValidationReason.FEEDBACK_TOO_LONG), tooLong.state.value.error)
        assertFalse(tooLong.state.value.isSending)
        assertTrue(repository.submitCalls.isEmpty(), "送っている: ${repository.submitCalls}")

        val ok = typed("あ".repeat(1000))
        ok.submit()

        assertNull(ok.state.value.error)
        assertTrue(ok.state.value.isSending)
        assertEquals(1, repository.submitCalls.size)
    }

    @Test
    fun `絵文字で1000を超える本文も、送らずに理由を出す`() {
        val vm = typed("😀".repeat(501))

        vm.submit()

        assertEquals(AppError.Validation(ValidationReason.FEEDBACK_TOO_LONG), vm.state.value.error)
        assertTrue(repository.submitCalls.isEmpty())
    }

    @Test
    fun `理由を出した後に本文を直すと理由は消え、そのまま送れる`() {
        val vm = typed("　")
        vm.submit()
        assertEquals(AppError.Validation(ValidationReason.FEEDBACK_BLANK), vm.state.value.error)

        vm.onMessageChange("空")
        assertNull(vm.state.value.error)
        vm.submit()

        assertEquals(1, repository.submitCalls.size)
    }

    // ── 送る（要件 13.2・13.4） ──

    @Test
    fun `送る内容は、ユーザーID・前後の空白を除いた本文・選んだ種別・バージョン・端末情報だけ`() {
        val vm = typed("\n 空がきれい　")
        vm.onCategoryChange(FeedbackCategory.REQUEST)

        vm.submit()

        assertEquals(
            listOf(FeedbackInput(Uid("UID-1"), "空がきれい", FeedbackCategory.REQUEST, APP_VERSION, DEVICE_INFO)),
            repository.submitCalls,
        )
    }

    @Test
    fun `種別を選ばなければ不具合として送る`() {
        val vm = typed("空")

        vm.submit()

        assertEquals(FeedbackCategory.BUG, repository.submitCalls.single().category)
    }

    @Test
    fun `送っている間は送信中で、もう一度押しても二重に送らない`() {
        val vm = typed("空")

        vm.submit()
        assertTrue(vm.state.value.isSending)
        vm.submit()

        assertEquals(1, repository.submitCalls.size)
    }

    // ── 成功（要件 13.5） ──

    @Test
    fun `送れたら送信済みにして、送信中を終える`() {
        val vm = typed("空")
        vm.submit()

        repository.completeLast(AppResult.Ok(Unit))

        val state = vm.state.value
        assertTrue(state.submitted)
        assertFalse(state.isSending)
        assertNull(state.error)
    }

    @Test
    fun `送信済みの後は、もう送らない`() {
        val vm = typed("空")
        vm.submit()
        repository.completeLast(AppResult.Ok(Unit))

        vm.submit()

        assertEquals(1, repository.submitCalls.size)
    }

    // ── 失敗（要件 13.6） ──

    @Test
    fun `送れなかったら、入力した本文と種別を残したまま、失敗を出す`() {
        val vm = typed("書いた長い文章")
        vm.onCategoryChange(FeedbackCategory.REQUEST)
        vm.submit()

        repository.completeLast(AppResult.Err(AppError.Network))

        val state = vm.state.value
        assertEquals("書いた長い文章", state.message)
        assertEquals(FeedbackCategory.REQUEST, state.category)
        assertEquals(AppError.Network, state.error)
        assertFalse(state.isSending)
        assertFalse(state.submitted)
    }

    @Test
    fun `失敗の後は、そのまま送り直せる`() {
        val vm = typed("空")
        vm.submit()
        repository.completeLast(AppResult.Err(AppError.PermissionDenied))

        vm.submit()
        assertNull(vm.state.value.error, "送り直す間は前の失敗を消す")
        assertTrue(vm.state.value.isSending)
        repository.completeLast(AppResult.Ok(Unit))

        assertEquals(2, repository.submitCalls.size)
        assertTrue(vm.state.value.submitted)
    }

    @Test
    fun `失敗の後に本文を直すと、失敗の表示は消える`() {
        val vm = typed("空")
        vm.submit()
        repository.completeLast(AppResult.Err(AppError.Network))

        vm.onMessageChange("空だよ")

        assertNull(vm.state.value.error)
        assertEquals("空だよ", vm.state.value.message)
    }

    @Test
    fun `送信の失敗はこの画面では記録しない（FeedbackRepositoryが記録済み）`() {
        val vm = typed("空")
        vm.submit()

        repository.completeLast(AppResult.Err(AppError.Network))

        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `送信中に画面を離れて取り消されても、送信は最後まで待ち、FeedbackRepositoryの失敗の記録が走る`() {
        // 送った直後に戻る操作で画面を離れると、この ViewModel の scope は取り消される。本物の FeedbackRepository は失敗を
        // submit の中で（書き込みの await の後に）記録するので、偽物を包んで同じ位置で記録させる（DefaultLikeStateStoreTest の R16 と同じ）。
        // 取り消し済みの scope に戻った後の状態（error・isSending）は捨てられうるので、見るのは記録と送った回数だけ
        val recorded = mutableListOf<AppError>()
        val recording = object : FeedbackRepository by repository {
            override suspend fun submit(input: FeedbackInput): AppResult<Unit> =
                repository.submit(input).also { if (it is AppResult.Err) recorded += it.error }
        }
        val owner = immediateScope()
        val vm = FeedbackViewModel(
            repository = recording,
            currentUid = { uid },
            appVersion = APP_VERSION,
            deviceInfo = DEVICE_INFO,
            analytics = analytics,
            isOnline = online,
            savedState = SavedStateHandle(),
            scope = owner,
        )
        vm.onMessageChange("空")
        vm.submit()
        try {
            owner.cancel()
            repository.completeLast(AppResult.Err(AppError.PermissionDenied))

            assertEquals(1, repository.submitCalls.size)
            assertEquals(listOf<AppError>(AppError.PermissionDenied), recorded)
        } finally {
            // 取り消さない待ちを残さない（この scope はテストが待たないので止まりにはならないが、待つ形のテストと同じ書き方にそろえる）
            repository.pending.forEach { it.complete(AppResult.Err(AppError.Network)) }
        }
    }

    // ── プロセスが落ちて作り直したとき（全体レビュー 4 回目 Q09）──

    @Test
    fun `プロセスが落ちて作り直しても、打った本文と選んだ種別を残す`() {
        // 裏に回っている間にメモリの不足で殺されると、戻る履歴は戻るが ViewModel は作り直される。残さないと本文が黙って消える
        val vm = viewModel()
        vm.onMessageChange("ここが変です")
        vm.onCategoryChange(FeedbackCategory.OTHER)

        val restored = recreated().state.value

        assertEquals("ここが変です", restored.message)
        assertEquals(FeedbackCategory.OTHER, restored.category)
    }

    @Test
    fun `送れたら、残した入力を捨てる（作り直した画面から同じご意見を2回送らせない）`() {
        val vm = viewModel()
        vm.onMessageChange("空")
        vm.onCategoryChange(FeedbackCategory.REQUEST)
        vm.submit()
        repository.completeLast(AppResult.Ok(Unit))

        assertEquals(FeedbackUiState(), recreated().state.value)
    }

    @Test
    fun `送れなかったら、残した入力はそのまま`() {
        val vm = viewModel()
        vm.onMessageChange("送り直す文")
        vm.onCategoryChange(FeedbackCategory.REQUEST)
        vm.submit()
        repository.completeLast(AppResult.Err(AppError.Network))

        val restored = recreated().state.value
        assertEquals("送り直す文", restored.message)
        assertEquals(FeedbackCategory.REQUEST, restored.category)
    }

    // ── ログイン・接続 ──

    @Test
    fun `ログインしていなければ、送らずにPermissionDeniedを出して記録する`() {
        uid = null
        val vm = typed("空")

        vm.submit()

        assertEquals(AppError.PermissionDenied, vm.state.value.error)
        assertFalse(vm.state.value.isSending)
        assertTrue(repository.submitCalls.isEmpty())
        assertEquals(listOf<Pair<AppError, String>>(AppError.PermissionDenied to "FeedbackViewModel.submit"), analytics.errors)
    }

    @Test
    fun `オフラインの間は、何もせずに送らない。接続が戻れば送れる`() {
        online.value = false
        val vm = typed("空")

        vm.submit()

        assertTrue(repository.submitCalls.isEmpty())
        assertFalse(vm.state.value.isSending)
        assertNull(vm.state.value.error)

        online.value = true
        vm.submit()

        assertEquals(1, repository.submitCalls.size)
    }

    private companion object {
        const val APP_VERSION = "1.0.0 (1)"
        const val DEVICE_INFO = "Android 14 / Pixel 8"
    }
}
