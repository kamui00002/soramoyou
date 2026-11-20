// ⭐️ 認証状態から、いちばん外側に表示する画面を決める（タスク 8.3・要件 2.1・2.8・16.2）
package com.yoshidometoru.soramoyou.feature.root

import com.yoshidometoru.soramoyou.data.repository.SessionState

/**
 * いちばん外側に表示する画面。画面の切り替えは認証状態を根拠にする（ログインの戻り値では切り替えない）。
 * ただし新規登録の途中（アカウントを作ってから、アカウント文書を書き終えるまで）は、ログイン済みになっても切り替えない（タスク 14.4）。
 */
enum class RootScreen {
    /** 端末に保持されたセッションの確認中。読み込み中の表示を出し、ログイン画面は一瞬も出さない（再起動時の復元・要件 2.8）。 */
    LOADING,

    /** 未ログイン。ログイン画面。 */
    SIGNED_OUT,

    /** ログイン済み。フィードと設定（ナビゲーションのグラフ）。 */
    SIGNED_IN,
}

/**
 * [session] のときに表示する画面。
 *
 * @param signUpInProgress 新規登録の途中か。Firebase はアカウントを作った時点でログイン済みにするので、認証状態だけで切り替えると、
 *   アカウント文書を書き終える前にフィードへ移り、文書の作成の失敗を見せられない（要件 2.11）。そこで、途中はログイン前の画面
 *   （新規登録の画面）のままにする。iOS も Firebase の認証状態でなく、文書を書き終えてから自前の印（`isAuthenticated`）で切り替える
 *   （AuthViewModel.swift:107-108）。
 */
fun rootScreenOf(session: SessionState, signUpInProgress: Boolean = false): RootScreen = when (session) {
    SessionState.Loading -> RootScreen.LOADING
    SessionState.SignedOut -> RootScreen.SIGNED_OUT
    is SessionState.SignedIn -> if (signUpInProgress) RootScreen.SIGNED_OUT else RootScreen.SIGNED_IN
}
