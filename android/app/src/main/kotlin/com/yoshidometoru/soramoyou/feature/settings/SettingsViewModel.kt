// ⭐️ 設定画面の状態とログアウト・項目の出し分け（タスク 8.3・29.2・30・31.5・要件 2.9・11.5・12.1・13.1・16.2）
package com.yoshidometoru.soramoyou.feature.settings

import androidx.lifecycle.ViewModel
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.remote.write.WriteGate
import com.yoshidometoru.soramoyou.data.repository.AuthRepository
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * 設定画面の状態。ログアウトの処理中と失敗だけを持つ（項目を出すかどうかはビルドで決まるので、ViewModel の値で持つ：[SettingsViewModel.canManageBlocks]・[SettingsViewModel.canSendFeedback]・[SettingsViewModel.canDeleteAccount]）。
 *
 * @property error 直前のログアウトの失敗の種類。文言は [com.yoshidometoru.soramoyou.feature.auth.authErrorMessageRes] で引く。
 */
data class SettingsUiState(val isSigningOut: Boolean = false, val error: AuthErrorKind? = null)

/**
 * 設定画面の ViewModel。ログアウトが成功すると認証状態が未ログインになり、RootViewModel がログイン画面へ切り替える。
 *
 * @param writeGate 書き込みの可否。書き込みを伴う項目は、その書き込みが有効なビルドだけに出す（ほかの導線の切り替えと同じ）。
 * @param scope この ViewModel の viewModelScope（RootViewModel と同じ理由で外から渡す）。
 *   ログアウト中に画面が閉じても、ログアウトは AuthRepository の中で最後まで行われる（走っている書き込みの終わりの待ち〔上限 10 秒・
 *   全体レビュー 4 回目 Q03〕・セッションの破棄・端末のデータの消去。タスク 8.2）。待ちの間は処理中（[SettingsUiState.isSigningOut]）のまま。
 */
class SettingsViewModel(
    private val repository: AuthRepository,
    writeGate: WriteGate,
    private val analytics: AnalyticsFacade,
    private val scope: CoroutineScope,
) : ViewModel(scope) {

    private val mutableState = MutableStateFlow(SettingsUiState())

    val state: StateFlow<SettingsUiState> = mutableState.asStateFlow()

    /**
     * 「ブロック中のユーザー」の項目を出すか（タスク 29.2・要件 11.5）。その画面の解除が BLOCK の書き込みなので、
     * BLOCK が有効なビルド（M5 から）だけに出す。ビルド時に決まるので、作った時点で 1 回だけ読む。
     */
    val canManageBlocks: Boolean = writeGate.isEnabled(WriteCapability.BLOCK)

    /**
     * 「ご意見・ご要望」の項目を出すか（タスク 30・要件 13.1）。その画面の送信が FEEDBACK の書き込みなので、
     * FEEDBACK が有効なビルド（M5 から）だけに出す。ビルド時に決まるので、作った時点で 1 回だけ読む。
     */
    val canSendFeedback: Boolean = writeGate.isEnabled(WriteCapability.FEEDBACK)

    /**
     * 「アカウントを削除」の項目を出すか（タスク 31.5・要件 12.1）。その画面の削除が ACCOUNT_DELETE の書き込みなので、
     * ACCOUNT_DELETE が有効なビルド（M5 から）だけに出す。ビルド時に決まるので、作った時点で 1 回だけ読む。
     */
    val canDeleteAccount: Boolean = writeGate.isEnabled(WriteCapability.ACCOUNT_DELETE)

    /** ログアウトする。処理中は何もしない（二重に呼ばない）。 */
    fun signOut() {
        if (mutableState.value.isSigningOut) return
        mutableState.update { it.copy(isSigningOut = true, error = null) }
        scope.launch {
            val error = (repository.signOut() as? AppResult.Err)?.error
            if (error != null) analytics.logError(error, "SettingsViewModel.signOut")
            mutableState.update {
                it.copy(isSigningOut = false, error = error?.let { e -> (e as? AppError.Auth)?.kind ?: AuthErrorKind.UNKNOWN })
            }
        }
    }
}
