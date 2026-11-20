// ⭐️ アカウントの削除の画面の状態：パスワードの入力・確認・削除中の段階・失敗と再試行・完了（タスク 31.5・要件 2.9・12.1〜12.7・16.2）
package com.yoshidometoru.soramoyou.feature.settings

import androidx.lifecycle.ViewModel
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.data.repository.AccountDeletionService
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Web の削除の受付ページ（タスク 26.1 で公開。hosting/delete-account/index.html。2026-10-13 に公開中の中身が main と一致することを確認済み）。
 * アプリを使えない人の申し込みと、アプリからの削除では残るデータ（ご意見・ご要望など）も消したい人の申し込みの方法が書いてある（要件 12.6）。
 */
const val DELETION_REQUEST_PAGE_URL = "https://soramoyou-ios.web.app/delete-account/"

/**
 * アカウントの削除の画面の状態。
 *
 * @property password 再認証に使うパスワードの入力欄の値（前後の空白も削らない。ログインと同じ）。
 * @property passwordMissing パスワードが空のまま削除を押した（理由を出す）。入力すると消える。
 * @property confirming 「取り消せません」の確認のダイアログを出している。
 * @property isDeleting 削除しているところ（入力とボタンを止め、戻る操作を受け止める）。
 * @property failure 直前の削除の失敗（`StageFailed` か、未ログインの `PermissionDenied`）。文言は [deletionFailureText] で引く。
 *   次に削除を始めると消える。
 * @property completed 削除し終えた。認証状態が未ログインになり、ログイン後の画面ごと捨てられるので、この状態が見えるのは一瞬だけ。
 * @property requestPageOpenFailed 削除の受付ページを開こうとして、ブラウザを開けなかった（アドレスを文字で出す）。
 */
data class AccountDeletionUiState(
    val password: String = "",
    val passwordMissing: Boolean = false,
    val confirming: Boolean = false,
    val isDeleting: Boolean = false,
    val failure: AppError? = null,
    val completed: Boolean = false,
    val requestPageOpenFailed: Boolean = false,
) {
    /** 失敗の後に「再試行」を出すか。部品は、もう一度呼べば再認証からやり直して残りを消す（AccountDeletionService.delete）。 */
    val canRetry: Boolean get() = failure != null && !isDeleting && !completed

    /** パスワードを文字列に出さない（テストの失敗の表示や、状態を書き出したログに載せないため）。 */
    override fun toString(): String =
        "AccountDeletionUiState(password=${if (password.isEmpty()) "" else "***"}, passwordMissing=$passwordMissing, " +
            "confirming=$confirming, isDeleting=$isDeleting, failure=$failure, completed=$completed, " +
            "requestPageOpenFailed=$requestPageOpenFailed)"
}

/**
 * アカウントの削除の画面の ViewModel（iOS の SettingsView の退会のアラート 2 つと削除中の覆い ＋ SettingsViewModel.performReauthAndDelete）。
 * 削除の手順そのもの（再認証・各段階・端末内のデータの消去・失敗の記録）は [AccountDeletionService] が行う。ここは入力と表示だけ。
 *
 * - パスワードが空なら始めない（理由を出す。入力の不備なので記録しない）。Android の MVP には匿名が無いので、パスワードは必ず要る
 *   （タスク 12＝B）。メールアドレスは部品がいまのユーザーから取るので、入力させない（iOS は入力させる）
 * - 「確認して削除」→「取り消せません」の確認→削除、の順（iOS は確認→パスワード→削除の順のアラート。Android は説明とパスワードを
 *   1 つの画面に並べ、最後に iOS の確認のアラートと同じ見出しと「削除する」で確かめる）
 * - 削除中は二重に始めない（部品に同時呼び出しの排他が無いため）。段階は [stage] で出す
 * - 失敗したら [AccountDeletionUiState.failure] に入れて「再試行」を出す。再試行は確認のダイアログを出し直さない（この画面で確認済み）。
 *   パスワードそのものが原因の失敗（誤り・最近のログインが必要）は入力欄を空にして入れ直してもらい、通信の断絶などでは残す（[needsPasswordAgain]）
 * - 失敗も成功も、ここでは記録しない（部品が段階名つきで記録済み：AccountDeletionService の記録の取り決め）
 * - 成功したら [AccountDeletionUiState.completed] にするだけ。端末内のデータは部品が消し済みで、認証状態が未ログインになると
 *   RootViewModel がログイン前の画面へ切り替える（ここから SessionManager もナビゲーションも呼ばない。要件 12.7）
 * - オフラインの間は始めない（画面は押せなくして案内を出す）。再認証は通信できないと失敗し、その失敗も記録に積もるため
 *   （通報・ブロック・ご意見の送信と同じ扱い）
 * - 画面名は送らない（iOS は退会を設定の中のアラートで行い、画面名を送らない。設計書 Q10）
 *
 * @param isOnline 接続の有無（NetworkMonitor.isOnline）。
 * @param scope この ViewModel の viewModelScope（RootViewModel と同じ理由で外から渡す）。画面が捨てられてスコープが取り消されても、
 *   再認証の後の削除は部品が最後まで行う（AccountDeletionService の NonCancellable）。再認証の間に取り消されたら、何も消さずに止まる。
 */
class AccountDeletionViewModel(
    private val service: AccountDeletionService,
    private val analytics: AnalyticsFacade,
    val isOnline: StateFlow<Boolean>,
    private val scope: CoroutineScope,
) : ViewModel(scope) {

    private val mutableState = MutableStateFlow(AccountDeletionUiState())

    val state: StateFlow<AccountDeletionUiState> = mutableState.asStateFlow()

    /** いま削除している段階（部品の値をそのまま。削除していない間は null）。画面は [deletionProgressText] で文言にする。 */
    val stage: StateFlow<DeletionStage?> = service.stage

    /** Web の削除の受付ページ（[DELETION_REQUEST_PAGE_URL]）。 */
    val requestPageUrl: String = DELETION_REQUEST_PAGE_URL

    /** パスワードを入力した。空のまま押したときの理由は、いまの入力のことではなくなるので消す。 */
    fun onPasswordChange(value: String) {
        mutableState.update { it.copy(password = value, passwordMissing = false) }
    }

    /** 「確認して削除」を押した。始められるなら確認のダイアログを出す。 */
    fun requestDelete() {
        if (!canStart()) return
        mutableState.update { it.copy(confirming = true) }
    }

    /** 確認のダイアログで「キャンセル」を押した。 */
    fun cancelDelete() {
        mutableState.update { it.copy(confirming = false) }
    }

    /**
     * 確認のダイアログで「削除する」を押した。削除を始める。ダイアログを出していないとき（削除中を含む）は何もしない。
     * ダイアログを出した後にオフラインになっていたら、始めずにダイアログを閉じる（[requestDelete] で接続を見たのは出す前なので、
     * ここでも見る。呼べば再認証が通信で失敗し、その失敗も記録に積もる。閉じた後の画面は押せなくして案内を出している）。
     */
    fun confirmDelete() {
        if (!mutableState.value.confirming) return
        if (!isOnline.value) {
            cancelDelete()
            return
        }
        start()
    }

    /** 失敗の後の「再試行」を押した。確認のダイアログを出し直さずに（この画面で確認済み）、もう一度削除する。 */
    fun retry() {
        if (!mutableState.value.canRetry || !canStart()) return
        start()
    }

    /** 削除の受付ページを開こうとして、ブラウザを開けなかった（開ける画面が端末に無いなど）。記録して、アドレスを文字で出す。 */
    fun onRequestPageOpenFailed(error: Throwable) {
        // 端末の都合で起きる失敗なので、例外の型の名前だけを残す（メッセージにはアドレスが入るが、値は載せない）
        analytics.logError(AppError.Unknown(error.javaClass.simpleName), "$CONTEXT.openRequestPage")
        mutableState.update { it.copy(requestPageOpenFailed = true) }
    }

    /**
     * いま削除を始めてよいか。削除中・削除し終えた後・オフラインのときは始めない。パスワードが空なら始めずに理由を出す
     * （入力の不備なので記録しない）。部品にも空のパスワードは渡さない（渡すと再認証の失敗として記録に積もる）。
     */
    private fun canStart(): Boolean {
        val state = mutableState.value
        if (state.isDeleting || state.completed || !isOnline.value) return false
        if (state.password.isEmpty()) {
            mutableState.update { it.copy(passwordMissing = true) }
            return false
        }
        return true
    }

    /**
     * 削除を始める。削除中の印を先に立ててから部品を呼ぶので、結果を待つ間に押されても、もう一度は始まらない
     * （[confirmDelete] は確認のダイアログが閉じていれば、[retry] は [AccountDeletionUiState.canRetry] が偽になっていれば何もしない）。
     */
    private fun start() {
        val password = mutableState.value.password
        mutableState.update { it.copy(confirming = false, isDeleting = true, failure = null, passwordMissing = false) }
        scope.launch {
            val result = service.delete(password)
            mutableState.update { state ->
                when (result) {
                    // 使い終わったパスワードは持ち続けない
                    is AppResult.Ok -> state.copy(isDeleting = false, completed = true, password = "")
                    is AppResult.Err -> state.copy(
                        isDeleting = false,
                        failure = result.error,
                        password = if (needsPasswordAgain(result.error)) "" else state.password,
                    )
                }
            }
        }
    }

    private companion object {
        /** 記録の発生箇所の前置き。 */
        const val CONTEXT = "AccountDeletionViewModel"
    }
}
