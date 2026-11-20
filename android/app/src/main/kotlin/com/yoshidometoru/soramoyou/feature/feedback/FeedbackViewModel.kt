// ⭐️ フィードバック送信の画面の状態：種別・本文の入力、送信、完了と失敗（タスク 30・要件 13.1〜13.6・16.2）
package com.yoshidometoru.soramoyou.feature.feedback

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.document.FeedbackInput
import com.yoshidometoru.soramoyou.contract.model.FeedbackCategory
import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.data.repository.FeedbackRepository
import com.yoshidometoru.soramoyou.data.repository.feedbackMessageProblem
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * フィードバック送信の画面の状態。
 *
 * @property message 本文の入力欄の値（前後の空白も含む入力のまま。送るときに取り除く）。
 * @property category 選んでいる種別（最初は不具合：iOS の `category = .bug`）。
 * @property isSending 送っているところ（入力とボタンを止める）。
 * @property error 直前の送信の失敗か、送らなかった理由（空白だけ・1000 文字超過）。文言は [feedbackErrorMessageRes] で引く。
 *   本文を直すか、送り直すと消える。
 * @property submitted 送れた。画面は完了の表示に切り替える（要件 13.5）。
 */
data class FeedbackUiState(
    val message: String = "",
    val category: FeedbackCategory = FeedbackCategory.BUG,
    val isSending: Boolean = false,
    val error: AppError? = null,
    val submitted: Boolean = false,
) {
    /**
     * 送る本文（前後の空白を除いたもの）の長さ。文字数の表示に使う。数えるのは rules と同じ UTF-16 の単位で、送る可否の判定
     * （[feedbackMessageProblem]）と同じ値なので、「1000 と出ているのに断られる」食い違いが起きない。
     */
    val trimmedLength: Int get() = TextLimits.trimWhitespace(message).length

    /** 送る本文が上限（[TextLimits.FEEDBACK_MAX]）を超えているか。文字数の表示を赤くするのに使う。 */
    val isOverLimit: Boolean get() = trimmedLength > TextLimits.FEEDBACK_MAX
}

/**
 * フィードバック送信の画面の ViewModel（iOS の `FeedbackView` ＋ `FeedbackViewModel`）。
 *
 * - 送る前に本文を確かめる（[feedbackMessageProblem]）。空白だけ・1000 文字超過なら送らずに [FeedbackUiState.error] に理由を入れる
 *   （要件 13.3。入力の不備は記録しない）。ボタンは先に止めず、押した後に理由を出す（理由が見えないまま押せない状態を作らない）
 * - 送れたら [FeedbackUiState.submitted] にする（要件 13.5）。送れなかったら、本文と種別をそのまま残して [FeedbackUiState.error] に失敗を入れる
 *   （要件 13.6）。失敗の記録は FeedbackRepository が済ませるので、ここでは記録しない（書き込みの待ちの後に記録するので、
 *   送った後に画面を離れても待ちは取り消さない）
 * - 送るのは、ユーザーID・前後の空白を除いた本文・種別・アプリのバージョン・端末情報だけ。メールアドレスと表示名は渡さない（要件 13.4）
 * - オフラインの間は送らない（画面は送信を押せなくして案内を出す）。Firestore の書き込みはオフラインでは失敗せずに接続を待つので、
 *   押せると止まって見える（通報・ブロックと同じ扱い）。送り始めた後にオフラインになったときは止めずに待つ（接続が戻ると届く）
 * - 画面名は送らない（iOS の FeedbackView も送らない。設計書 Q10）
 * - ログアウトで状態を捨てる仕組みは持たない。ログアウトするとログイン後のナビゲーションごと捨てられ、この画面には戻れないため
 * - プロセスが落ちて作り直されたとき（裏に回っている間にメモリの不足で殺され、戻る履歴と一緒にこの画面が戻ったとき）のために、
 *   打った本文と選んだ種別を [savedState] に残し、作るときに読み戻す（全体レビュー 4 回目 Q09）。送れたら捨てる
 *   （作り直した画面に送った本文を戻して、同じご意見を 2 回送らせない）
 *
 * @param currentUid いまログインしているユーザーの uid（いなければ null）。送るたびに読む。
 * @param appVersion 送るアプリのバージョン（[FeedbackMetadata.currentAppVersion]）。
 * @param deviceInfo 送る端末情報（[FeedbackMetadata.currentDeviceInfo]）。
 * @param isOnline 接続の有無（NetworkMonitor.isOnline）。
 * @param savedState この画面（戻る履歴の 1 枚）の保存の箱（`createSavedStateHandle()`）。プロセスが落ちても残る。
 * @param scope この ViewModel の viewModelScope（RootViewModel と同じ理由で外から渡す）。
 */
class FeedbackViewModel(
    private val repository: FeedbackRepository,
    private val currentUid: () -> Uid?,
    private val appVersion: String,
    private val deviceInfo: String,
    private val analytics: AnalyticsFacade,
    val isOnline: StateFlow<Boolean>,
    private val savedState: SavedStateHandle,
    private val scope: CoroutineScope,
) : ViewModel(scope) {

    // プロセスが落ちて作り直したときは、残した入力から始める（初めて開いたときは、どの鍵も無いので既定の値になる）
    private val mutableState = MutableStateFlow(
        FeedbackUiState(
            message = savedState.get<String>(KEY_MESSAGE) ?: "",
            category = savedState.get<String>(KEY_CATEGORY)
                ?.let { raw -> FeedbackCategory.entries.firstOrNull { it.raw == raw } }
                ?: FeedbackCategory.BUG,
        ),
    )

    val state: StateFlow<FeedbackUiState> = mutableState.asStateFlow()

    /** 本文を直した。出ていた理由や失敗は、いまの本文のことではなくなるので消す。 */
    fun onMessageChange(value: String) {
        mutableState.update { it.copy(message = value, error = null) }
        savedState[KEY_MESSAGE] = value
    }

    /** 種別を選んだ。 */
    fun onCategoryChange(category: FeedbackCategory) {
        mutableState.update { it.copy(category = category) }
        savedState[KEY_CATEGORY] = category.raw
    }

    /**
     * 送る。送っている間・送った後・オフラインのときは何もしない（二重に送らない）。
     * 本文に送れない理由があれば、送らずに理由を入れる。
     */
    fun submit() {
        val state = mutableState.value
        if (state.isSending || state.submitted || !isOnline.value) return

        val problem = feedbackMessageProblem(state.message)
        if (problem != null) {
            mutableState.update { it.copy(error = AppError.Validation(problem)) }
            return
        }
        // ログイン後の画面なので、通常は起きない。起きたら送れないので失敗として出し、記録する
        val uid = currentUid()
        if (uid == null) {
            analytics.logError(AppError.PermissionDenied, "$CONTEXT.submit")
            mutableState.update { it.copy(error = AppError.PermissionDenied) }
            return
        }

        val input = FeedbackInput(uid, TextLimits.trimWhitespace(state.message), state.category, appVersion, deviceInfo)
        mutableState.update { it.copy(isSending = true, error = null) }
        scope.launch {
            // 書き込みの待ちは取り消さない。送った後に戻る操作で画面を離れると scope は取り消され、待ちが取り消しで抜けると、
            // FeedbackRepository が待ちの後に行う失敗の記録が走らない。通報・ブロック（PostModeration）と同じく NonCancellable で
            // 最後まで待つ。状態の更新はその後（取り消し済みなら捨てられるが、見る画面はもう無い）
            val result = withContext(NonCancellable) { repository.submit(input) }
            when (result) {
                is AppResult.Ok -> {
                    mutableState.update { it.copy(isSending = false, submitted = true) }
                    savedState.remove<String>(KEY_MESSAGE)
                    savedState.remove<String>(KEY_CATEGORY)
                }
                is AppResult.Err -> mutableState.update { it.copy(isSending = false, error = result.error) }
            }
        }
    }

    private companion object {
        /** 記録の発生箇所の前置き。 */
        const val CONTEXT = "FeedbackViewModel"

        /** [savedState] の鍵（打った本文・選んだ種別の raw）。 */
        const val KEY_MESSAGE = "message"
        const val KEY_CATEGORY = "category"
    }
}
