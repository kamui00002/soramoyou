// ⭐️ ログイン画面の状態の単体テスト（タスク 8.3・要件 2.1・2.7・16.2）
package com.yoshidometoru.soramoyou.feature.auth

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.remote.write.Milestone
import com.yoshidometoru.soramoyou.data.remote.write.writeCapabilitiesOf
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.feature.FakeAccountBootstrapper
import com.yoshidometoru.soramoyou.feature.FakeAuthRepository
import com.yoshidometoru.soramoyou.feature.FakeWriteGate
import com.yoshidometoru.soramoyou.feature.RecordingFeatureAnalytics
import com.yoshidometoru.soramoyou.feature.immediateScope
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AuthViewModelTest {

    private val repository = FakeAuthRepository()
    private val bootstrapper = FakeAccountBootstrapper()
    private val analytics = RecordingFeatureAnalytics()

    private fun viewModel(enabled: Set<WriteCapability> = emptySet()) =
        AuthViewModel(repository, bootstrapper, FakeWriteGate(enabled), analytics, immediateScope())

    @Test
    fun `M1では新規登録と匿名の導線を出さない（書き込みの可否で隠す）`() {
        // M1 の有効な書き込みは空集合（WriteGate.kt の対応表）。その集合で作ったときに隠れることを確かめる
        assertFalse(viewModel(writeCapabilitiesOf(Milestone.M1)).state.value.canCreateAccount)
        assertTrue(viewModel(setOf(WriteCapability.ACCOUNT_CREATE)).state.value.canCreateAccount)
    }

    @Test
    fun `メールアドレスとパスワードの両方が入るまでログインできない（iOSのisFormValidと同じ）`() {
        val viewModel = viewModel()
        assertFalse(viewModel.state.value.canSubmit)

        viewModel.onEmailChange("a@example.com")
        assertFalse(viewModel.state.value.canSubmit)

        viewModel.onPasswordChange("password")
        assertTrue(viewModel.state.value.canSubmit)
    }

    @Test
    fun `入力をそのまま渡してログインし、終わるまで送信中にして二重に送らない`() {
        val viewModel = viewModel()
        viewModel.onEmailChange("a@example.com")
        viewModel.onPasswordChange("pass word")

        viewModel.signIn()
        assertTrue(viewModel.state.value.isSubmitting)
        assertFalse(viewModel.state.value.canSubmit)
        viewModel.signIn()

        repository.signInResult.complete(AppResult.Ok(Unit))

        assertEquals(listOf("a@example.com" to "pass word"), repository.signInCalls)
        assertFalse(viewModel.state.value.isSubmitting)
        assertNull(viewModel.state.value.error)
        assertEquals(emptyList(), analytics.errors)
        // ログインできたらパスワードを手元に残さない（ログインしている間もメモリに持たない）。メールアドレスはログアウトで消す（下のテスト）
        assertEquals("", viewModel.state.value.password)
    }

    @Test
    fun `ログイン済みから未ログインに移ったら（ログアウト・退会）、前の人のメールアドレスも含めてログインの入力を作り直す`() {
        val viewModel = viewModel(setOf(WriteCapability.ACCOUNT_CREATE))
        viewModel.onEmailChange("a@example.com")
        viewModel.onPasswordChange("password")
        viewModel.signIn()
        repository.signInResult.complete(AppResult.Ok(Unit))
        repository.sessionFlow.value = signedIn("A")
        // ログインしている間は消さない（画面が切り替わるまで、欄を空にしない）
        assertEquals("a@example.com", viewModel.state.value.email)

        repository.sessionFlow.value = SessionState.SignedOut

        // 新規登録の導線を出すかはビルドで決まるので残す（ログアウトの後に新規登録の導線が消えない）
        assertEquals(LoginUiState(canCreateAccount = true), viewModel.state.value)
    }

    @Test
    fun `新規登録を途中まで打ってからログインした人がログアウトしたら、新規登録の入力も作り直す`() {
        val vm = viewModel(setOf(WriteCapability.ACCOUNT_CREATE))
        vm.showSignUp()
        vm.onSignUpEmailChange("a@example.com")
        vm.onSignUpPasswordChange("abcdef")
        vm.showSignIn()
        vm.onEmailChange("a@example.com")
        vm.onPasswordChange("password")
        vm.signIn()
        repository.signInResult.complete(AppResult.Ok(Unit))
        repository.sessionFlow.value = signedIn("A")
        assertEquals("a@example.com", vm.signUpState.value.email, "前提：ログインしている間は残っている")

        repository.sessionFlow.value = SessionState.SignedOut

        // 次の人が新規登録を開いても、前の人のメールアドレスが見えない
        assertEquals(SignUpUiState(), vm.signUpState.value)
    }

    @Test
    fun `新規登録の途中で未ログインに移っても、新規登録の画面の状態は消さない（文書の作成の結果を見せる途中）`() {
        val vm = signUpReady()
        vm.signUp()
        repository.createEmailAccountResult.complete(AppResult.Ok(Uid("NEW-UID")))
        repository.sessionFlow.value = signedIn("NEW-UID")

        repository.sessionFlow.value = SessionState.SignedOut

        assertTrue(vm.signUpInProgress.value)
        assertEquals("sora@example.com", vm.signUpState.value.email)
        assertTrue(vm.signUpState.value.isSubmitting, "文書の作成を待っている表示が消えた")
    }

    @Test
    fun `起動時の確認が終わって未ログインになっただけでは、入力を作り直さない`() {
        repository.sessionFlow.value = SessionState.Loading
        val vm = viewModel()
        vm.onEmailChange("a@example.com")

        repository.sessionFlow.value = SessionState.SignedOut

        assertEquals("a@example.com", vm.state.value.email)
    }

    @Test
    fun `失敗したら種類を出し、iOSと同じ発生箇所で記録する`() {
        val viewModel = viewModel()
        viewModel.onEmailChange("a@example.com")
        viewModel.onPasswordChange("x")

        viewModel.signIn()
        repository.signInResult.complete(AppResult.Err(AppError.Auth(AuthErrorKind.WRONG_PASSWORD)))

        assertEquals(AuthErrorKind.WRONG_PASSWORD, viewModel.state.value.error)
        assertFalse(viewModel.state.value.isSubmitting)
        // iOS: AuthViewModel.swift:87 の ErrorHandler.logError(error, context: "AuthViewModel.signIn")
        assertEquals(listOf<Pair<AppError, String>>(AppError.Auth(AuthErrorKind.WRONG_PASSWORD) to "AuthViewModel.signIn"), analytics.errors)
    }

    @Test
    fun `認証以外の失敗は「その他」の文言にし、元の失敗を記録する`() {
        val viewModel = viewModel()
        viewModel.onEmailChange("a@example.com")
        viewModel.onPasswordChange("x")

        viewModel.signIn()
        repository.signInResult.complete(AppResult.Err(AppError.Network))

        assertEquals(AuthErrorKind.UNKNOWN, viewModel.state.value.error)
        assertEquals(listOf<Pair<AppError, String>>(AppError.Network to "AuthViewModel.signIn"), analytics.errors)
    }

    @Test
    fun `次のログインを始めたら前の失敗の表示を消す`() {
        val viewModel = viewModel()
        viewModel.onEmailChange("a@example.com")
        viewModel.onPasswordChange("x")
        viewModel.signIn()
        repository.signInResult.complete(AppResult.Err(AppError.Auth(AuthErrorKind.WRONG_PASSWORD)))
        repository.signInResult = kotlinx.coroutines.CompletableDeferred()

        viewModel.signIn()

        // iOS も試行の最初に errorMessage を消す（AuthViewModel.swift:76）
        assertNull(viewModel.state.value.error)
    }

    // ── 新規登録（タスク 14.4・要件 2.3・2.5〜2.7・2.11）──

    /** 新規登録の画面にして、送れる入力を入れた ViewModel（アカウントの作成が有効なビルド）。 */
    private fun signUpReady(): AuthViewModel = viewModel(setOf(WriteCapability.ACCOUNT_CREATE)).apply {
        showSignUp()
        onSignUpEmailChange("sora@example.com")
        onSignUpPasswordChange("abcdef")
        onConfirmPasswordChange("abcdef")
    }

    @Test
    fun `新規登録の画面へ切り替えて、ログインの画面へ戻れる`() {
        val vm = viewModel(setOf(WriteCapability.ACCOUNT_CREATE))
        assertEquals(AuthMode.SIGN_IN, vm.mode.value)
        vm.showSignUp()
        assertEquals(AuthMode.SIGN_UP, vm.mode.value)
        vm.showSignIn()
        assertEquals(AuthMode.SIGN_IN, vm.mode.value)
    }

    @Test
    fun `新規登録の途中はログインの画面へ戻らない`() {
        val vm = signUpReady()
        vm.signUp()
        vm.showSignIn()
        assertEquals(AuthMode.SIGN_UP, vm.mode.value, "アカウントの作成中に戻れる")

        repository.createEmailAccountResult.complete(AppResult.Ok(Uid("NEW-UID")))
        bootstrapper.result.complete(AppResult.Err(AppError.Network))
        vm.showSignIn()
        // ログイン済みのまま戻ると、切り替えの停止を解く「続ける」が見えなくなり、フィードへ進めない
        assertEquals(AuthMode.SIGN_UP, vm.mode.value, "文書の作成の失敗を見せている間に戻れる")
    }

    @Test
    fun `アカウントの作成が無効なビルドでは新規登録の画面へ切り替えない`() {
        val vm = viewModel(writeCapabilitiesOf(Milestone.M1))
        vm.showSignUp()
        assertEquals(AuthMode.SIGN_IN, vm.mode.value)
    }

    @Test
    fun `iOSと同じく、メールアドレス・6文字以上のパスワード・一致する確認が揃うまで送れない`() {
        val vm = viewModel(setOf(WriteCapability.ACCOUNT_CREATE)).apply { showSignUp() }
        vm.onSignUpEmailChange("sora@example.com")
        vm.onSignUpPasswordChange("abcde")
        vm.onConfirmPasswordChange("abcde")
        assertFalse(vm.signUpState.value.canSubmit, "5 文字で送れる")
        vm.onSignUpPasswordChange("abcdef")
        assertFalse(vm.signUpState.value.passwordsMatch)
        assertFalse(vm.signUpState.value.canSubmit, "確認が一致しないのに送れる")
        vm.onConfirmPasswordChange("abcdef")
        assertTrue(vm.signUpState.value.passwordsMatch)
        assertTrue(vm.signUpState.value.canSubmit)

        vm.signUp()
        vm.onConfirmPasswordChange("x")
        assertEquals(1, repository.createEmailAccountCalls.size)
    }

    @Test
    fun `6文字に足りないパスワードを入れている間だけ、理由を出す`() {
        val vm = viewModel(setOf(WriteCapability.ACCOUNT_CREATE)).apply { showSignUp() }
        assertFalse(vm.signUpState.value.passwordTooShort, "未入力の間に出す")
        vm.onSignUpPasswordChange("abcde")
        assertTrue(vm.signUpState.value.passwordTooShort)
        // 見た目の 5 文字（UTF-16 では 10）。iOS と同じく見た目の 1 文字で数える
        vm.onSignUpPasswordChange("🌅🌅🌅🌅🌅")
        assertTrue(vm.signUpState.value.passwordTooShort, "UTF-16 の長さで数えている")
        vm.onSignUpPasswordChange("abcdef")
        assertFalse(vm.signUpState.value.passwordTooShort)
    }

    @Test
    fun `確認が一致しなければ送らない`() {
        val vm = signUpReady()
        vm.onConfirmPasswordChange("abcdeg")
        vm.signUp()
        assertEquals(emptyList(), repository.createEmailAccountCalls)
    }

    @Test
    fun `作成と文書の作成が成功するまで画面を切り替えさせず、成功したら切り替えさせる`() {
        val vm = signUpReady()
        vm.signUp()
        assertTrue(vm.signUpInProgress.value, "アカウントを作る前から切り替えを止める")
        assertEquals(listOf("sora@example.com" to "abcdef"), repository.createEmailAccountCalls)

        repository.createEmailAccountResult.complete(AppResult.Ok(Uid("NEW-UID")))
        assertTrue(vm.signUpInProgress.value, "文書の作成中は切り替えさせない")

        bootstrapper.result.complete(AppResult.Ok(Unit))
        assertFalse(vm.signUpInProgress.value)
        assertEquals(SignUpUiState(), vm.signUpState.value, "成功したら入力（パスワード）を手元に残さない")
        assertEquals(AuthMode.SIGN_IN, vm.mode.value, "ログアウトして戻ったときはログインの画面にする")
    }

    @Test
    fun `文書の作成には、作成で返ったuidと入力のメールアドレスを渡す`() {
        repository.sessionFlow.value = signedIn("SESSION-UID")
        val vm = signUpReady()
        vm.signUp()
        repository.createEmailAccountResult.complete(AppResult.Ok(Uid("NEW-UID")))

        assertEquals(listOf<Pair<Uid, String?>>(Uid("NEW-UID") to "sora@example.com"), bootstrapper.calls)
    }

    @Test
    fun `アカウントの作成に失敗したら、文書を作らず、切り替えの停止を解いて種類を出し、記録する`() {
        val vm = signUpReady()
        vm.signUp()
        repository.createEmailAccountResult.complete(AppResult.Err(AppError.Auth(AuthErrorKind.EMAIL_ALREADY_IN_USE)))

        assertEquals(emptyList(), bootstrapper.calls)
        assertFalse(vm.signUpInProgress.value)
        assertEquals(AuthErrorKind.EMAIL_ALREADY_IN_USE, vm.signUpState.value.error)
        assertFalse(vm.signUpState.value.isSubmitting)
        assertEquals(listOf<Pair<AppError, String>>(AppError.Auth(AuthErrorKind.EMAIL_ALREADY_IN_USE) to "AuthViewModel.signUp"), analytics.errors)
    }

    @Test
    fun `文書の作成に失敗したら、セッションを保ったまま切り替えを止め、失敗を出して、ここでは記録し直さない`() {
        val vm = signUpReady()
        vm.signUp()
        repository.createEmailAccountResult.complete(AppResult.Ok(Uid("NEW-UID")))
        bootstrapper.result.complete(AppResult.Err(AppError.Network))

        assertTrue(vm.signUpInProgress.value, "失敗を見せる前にフィードへ切り替えない")
        assertTrue(vm.signUpState.value.bootstrapFailed)
        assertFalse(vm.signUpState.value.isSubmitting)
        assertEquals(0, repository.signOutCalls, "セッションは保つ（ログアウトしない）")
        assertEquals(emptyList(), analytics.errors, "記録は AccountBootstrapper が済ませている")
    }

    @Test
    fun `文書の作成の失敗の後に続けるを押したら、切り替えの停止を解く`() {
        val vm = signUpReady()
        vm.signUp()
        repository.createEmailAccountResult.complete(AppResult.Ok(Uid("NEW-UID")))
        bootstrapper.result.complete(AppResult.Err(AppError.Network))

        vm.continueAfterBootstrapFailure()

        assertFalse(vm.signUpInProgress.value)
        assertEquals(SignUpUiState(), vm.signUpState.value)
    }

    private fun signedIn(uid: String) = com.yoshidometoru.soramoyou.data.repository.SessionState.SignedIn(Uid(uid), "x@example.com", isAnonymous = false)
}
