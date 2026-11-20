// ⭐️ 認証状態に応じた画面の切り替えと、分析のユーザー識別（タスク 8.3・要件 2.1・2.8・15.5）
package com.yoshidometoru.soramoyou.feature.root

import androidx.lifecycle.ViewModel
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.stateIn

/**
 * いちばん外側の画面を、認証状態（[session]）から決める。
 *
 * ログイン済みを見たら、分析のユーザー識別を uid で設定する（要件 15.5）。iOS もログインの成功時と、
 * 起動時のセッションの復元時の両方で設定している（AuthViewModel.swift:84・:191・:208）。同じ uid が続く間は設定し直さない。
 * 識別の解除はログアウトの SessionManager が行う（タスク 8.2）ので、ここでは設定だけをする。
 *
 * @param scope この ViewModel の viewModelScope。本番は Main、単体テストは Unconfined を渡す
 *   （viewModelScope の既定は Dispatchers.Main で、JVM の単体テストには無いため）。
 * @param signUpInProgress 新規登録の途中か（AuthViewModel.signUpInProgress）。途中はログイン済みでもログイン前の画面のままにする（[rootScreenOf]）。
 */
class RootViewModel(
    session: StateFlow<SessionState>,
    analytics: AnalyticsFacade,
    scope: CoroutineScope,
    signUpInProgress: StateFlow<Boolean> = MutableStateFlow(false),
) : ViewModel(scope) {

    /** いま表示する画面。最初の値は、作った時点の認証状態から決める（確認中なら読み込み中）。 */
    val screen: StateFlow<RootScreen> =
        combine(session, signUpInProgress, ::rootScreenOf)
            .stateIn(scope, SharingStarted.Eagerly, rootScreenOf(session.value, signUpInProgress.value))

    init {
        session
            .map { (it as? SessionState.SignedIn)?.uid }
            // ログアウト（null）をはさめば、同じ uid でも設定し直す（ログアウトで解除されているため）
            .distinctUntilChanged()
            .filterNotNull()
            .onEach(analytics::setUserId)
            .launchIn(scope)
    }
}
