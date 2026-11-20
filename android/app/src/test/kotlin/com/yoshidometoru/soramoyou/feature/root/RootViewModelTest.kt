// ⭐️ セッションに応じた画面の切り替えと、分析のユーザー識別の単体テスト（タスク 8.3・要件 2.1・2.8・15.5・16.2）
package com.yoshidometoru.soramoyou.feature.root

import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.feature.RecordingFeatureAnalytics
import com.yoshidometoru.soramoyou.feature.immediateScope
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.flow.MutableStateFlow

class RootViewModelTest {

    private val analytics = RecordingFeatureAnalytics()
    private fun signedIn(uid: String) = SessionState.SignedIn(Uid(uid), "a@example.com", isAnonymous = false)

    @Test
    fun `セッションの種類ごとに表示する画面が決まる`() {
        assertEquals(RootScreen.LOADING, rootScreenOf(SessionState.Loading))
        assertEquals(RootScreen.SIGNED_OUT, rootScreenOf(SessionState.SignedOut))
        assertEquals(RootScreen.SIGNED_IN, rootScreenOf(signedIn("u1")))
    }

    @Test
    fun `確認中のあいだはログイン画面を出さず、復元されたらログイン画面を経ずにフィードへ進む`() {
        val session = MutableStateFlow<SessionState>(SessionState.Loading)
        val viewModel = RootViewModel(session, analytics, immediateScope())
        val seen = mutableListOf(viewModel.screen.value)

        session.value = signedIn("u1")
        seen += viewModel.screen.value

        assertEquals(listOf(RootScreen.LOADING, RootScreen.SIGNED_IN), seen)
    }

    @Test
    fun `ログアウトするとログイン画面に戻る`() {
        val session = MutableStateFlow<SessionState>(signedIn("u1"))
        val viewModel = RootViewModel(session, analytics, immediateScope())

        session.value = SessionState.SignedOut

        assertEquals(RootScreen.SIGNED_OUT, viewModel.screen.value)
    }

    @Test
    fun `ログイン済みを見たら、分析のユーザー識別をuidで設定する（復元時も）`() {
        val session = MutableStateFlow<SessionState>(signedIn("u1"))

        RootViewModel(session, analytics, immediateScope())
        session.value = SessionState.SignedOut
        session.value = signedIn("u2")

        // 解除（null）はログアウトの SessionManager が行うので、ここでは設定だけ
        assertEquals(listOf<Uid?>(Uid("u1"), Uid("u2")), analytics.userIds)
    }

    @Test
    fun `同じuidのまま状態が変わっても、識別を設定し直さない`() {
        val session = MutableStateFlow<SessionState>(signedIn("u1"))

        RootViewModel(session, analytics, immediateScope())
        session.value = SessionState.SignedIn(Uid("u1"), "changed@example.com", isAnonymous = false)

        assertEquals(listOf<Uid?>(Uid("u1")), analytics.userIds)
    }

    // ── 新規登録の途中（タスク 14.4）──

    @Test
    fun `新規登録の途中は、ログイン済みになってもログイン前の画面のままにする`() {
        // iOS も、Firebase の認証状態でなく、文書を書き終えてから自前の印で切り替える（AuthViewModel.swift:107-108）
        assertEquals(RootScreen.SIGNED_OUT, rootScreenOf(signedIn("u1"), signUpInProgress = true))
        assertEquals(RootScreen.SIGNED_IN, rootScreenOf(signedIn("u1"), signUpInProgress = false))
        assertEquals(RootScreen.SIGNED_OUT, rootScreenOf(SessionState.SignedOut, signUpInProgress = true))
    }

    @Test
    fun `新規登録の途中が終わったら、ログイン後の画面へ切り替える`() {
        val session = MutableStateFlow<SessionState>(SessionState.SignedOut)
        val inProgress = MutableStateFlow(true)
        val viewModel = RootViewModel(session, analytics, immediateScope(), inProgress)

        session.value = signedIn("u1")
        assertEquals(RootScreen.SIGNED_OUT, viewModel.screen.value)

        inProgress.value = false
        assertEquals(RootScreen.SIGNED_IN, viewModel.screen.value)
    }
}
