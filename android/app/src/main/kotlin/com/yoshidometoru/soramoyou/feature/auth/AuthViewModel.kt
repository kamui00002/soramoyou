// ⭐️ ログイン前の画面（ログイン・新規登録）の状態と操作（タスク 8.3・14.4・要件 2.1・2.3・2.5〜2.7・2.11・16.2）
package com.yoshidometoru.soramoyou.feature.auth

import androidx.lifecycle.ViewModel
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.data.remote.write.WriteGate
import com.yoshidometoru.soramoyou.data.repository.AccountBootstrapper
import com.yoshidometoru.soramoyou.data.repository.AuthRepository
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * ログイン画面の状態。
 *
 * @property error 直前のログインの失敗の種類。文言は [authErrorMessageRes] で引く。
 * @property canCreateAccount 新規登録の導線を出すか。アカウントの作成（[WriteCapability.ACCOUNT_CREATE]）の
 *   書き込みが有効なビルドだけ true（M1 は false）。「匿名で始める」はタスク 12 で外したので置かない。
 */
data class LoginUiState(
    val email: String = "",
    val password: String = "",
    val isSubmitting: Boolean = false,
    val error: AuthErrorKind? = null,
    val canCreateAccount: Boolean = false,
) {
    /** ログインのボタンを押せるか。iOS と同じく、両方が入るまで押せない（LoginView.swift:192-194・:161）。 */
    val canSubmit: Boolean get() = email.isNotEmpty() && password.isNotEmpty() && !isSubmitting
}

/** ログイン前の画面のどちらを出すか（iOS はシートで出し分ける。Android は 1 つの画面の中で切り替える）。 */
enum class AuthMode { SIGN_IN, SIGN_UP }

/**
 * 新規登録の画面の状態（タスク 14.4・要件 2.3・2.5〜2.7・2.11）。
 *
 * @property error 直前のアカウントの作成の失敗の種類。文言は [authErrorMessageRes] で引く。
 * @property bootstrapFailed アカウントは作れたが、アカウント文書の作成に失敗した。セッションは保ったまま、失敗と「続ける」を出す。
 */
data class SignUpUiState(
    val email: String = "",
    val password: String = "",
    val confirmPassword: String = "",
    val isSubmitting: Boolean = false,
    val error: AuthErrorKind? = null,
    val bootstrapFailed: Boolean = false,
) {
    /** 確認が入っていて、パスワードと一致する（iOS の `passwordsMatch`：SignUpView.swift:229-231）。 */
    val passwordsMatch: Boolean get() = confirmPassword.isNotEmpty() && password == confirmPassword

    /** 6 文字に足りないパスワードを入れている間だけ true。理由を欄の下に出す（要件 2.6）。未入力の間は出さない。 */
    val passwordTooShort: Boolean get() = password.isNotEmpty() && !TextLimits.isPasswordLongEnough(password)

    /**
     * 送れるか。iOS の `isFormValid`（SignUpView.swift:225-227）と同じく、メールアドレス・6 文字以上のパスワード・一致する確認が揃うまで送れない
     * （6 文字は iOS と同じく見た目の 1 文字で数える：TextLimits）。送信中と、文書の作成の失敗を見せている間も送れない。
     */
    val canSubmit: Boolean
        get() = email.isNotEmpty() && TextLimits.isPasswordLongEnough(password) && passwordsMatch && !isSubmitting && !bootstrapFailed
}

/**
 * ログイン前の画面（ログイン・新規登録）の ViewModel。名前は iOS の AuthViewModel にそろえ、失敗の記録の発生箇所
 * （`AuthViewModel.signIn`・`AuthViewModel.signUp`）を iOS と同じにする。
 * 画面の切り替えはしない（ログインが成功すると認証状態が変わり、RootViewModel が切り替える。新規登録の途中は [signUpInProgress] で止める）。
 *
 * この ViewModel は Activity の寿命で生きる（RootViewModel が [signUpInProgress] を読むので根で作る）。そのため、ログイン済みから
 * 未ログインへ移ったとき（ログアウト・退会）に、ログインと新規登録の入力を作り直す（[clearInputs]。全体レビュー 4 回目 Q11）。
 * iOS はどちらの画面もシートの `@State` で入力を持ち、閉じると捨てる（LoginView.swift:13・SignUpView.swift:13-15）。
 * 未ログインのまま（起動時の確認の終わり）では作り直さない。
 *
 * @param scope この ViewModel の viewModelScope（RootViewModel と同じ理由で外から渡す）。
 */
class AuthViewModel(
    private val repository: AuthRepository,
    private val bootstrapper: AccountBootstrapper,
    writeGate: WriteGate,
    private val analytics: AnalyticsFacade,
    private val scope: CoroutineScope,
) : ViewModel(scope) {

    private val mutableState = MutableStateFlow(LoginUiState(canCreateAccount = writeGate.isEnabled(WriteCapability.ACCOUNT_CREATE)))

    val state: StateFlow<LoginUiState> = mutableState.asStateFlow()

    private val mutableMode = MutableStateFlow(AuthMode.SIGN_IN)

    /** ログインと新規登録のどちらの画面を出すか。 */
    val mode: StateFlow<AuthMode> = mutableMode.asStateFlow()

    private val mutableSignUp = MutableStateFlow(SignUpUiState())

    /** 新規登録の画面の状態。 */
    val signUpState: StateFlow<SignUpUiState> = mutableSignUp.asStateFlow()

    private val mutableSignUpInProgress = MutableStateFlow(false)

    /**
     * 新規登録の途中か（アカウントを作る直前から、アカウント文書を書き終えるか、文書の失敗の後に「続ける」を押すまで）。
     * RootViewModel に渡し、途中はログイン済みになってもフィードへ切り替えさせない（[com.yoshidometoru.soramoyou.feature.root.rootScreenOf]）。
     */
    val signUpInProgress: StateFlow<Boolean> = mutableSignUpInProgress.asStateFlow()

    init {
        // ログイン済みを見た後に未ログインが来たら、入力を作り直す。確認中（Loading）は、どちらとも数えない
        var signedInSeen = false
        repository.session
            .onEach { session ->
                when (session) {
                    is SessionState.SignedIn -> signedInSeen = true
                    SessionState.SignedOut -> if (signedInSeen) {
                        signedInSeen = false
                        clearInputs()
                    }
                    SessionState.Loading -> Unit
                }
            }
            .launchIn(scope)
    }

    /**
     * ログイン前の画面の入力を作り直す（ログアウト・退会の後）。新規登録の導線を出すか（[LoginUiState.canCreateAccount]）は
     * ビルドで決まるので残す。新規登録の途中（[signUpInProgress]）は、新規登録の画面の状態に触らない（文書の作成の結果を見せる途中のため）。
     */
    private fun clearInputs() {
        mutableState.update { LoginUiState(canCreateAccount = it.canCreateAccount) }
        if (!mutableSignUpInProgress.value) mutableSignUp.value = SignUpUiState()
    }

    /** 新規登録の画面へ。アカウントの作成が無効なビルド（M1）では切り替えない（導線も出さない）。 */
    fun showSignUp() {
        if (mutableState.value.canCreateAccount) mutableMode.value = AuthMode.SIGN_UP
    }

    /** ログインの画面へ。新規登録の途中は戻らない（途中で離れると、文書の作成の結果を見せられない）。 */
    fun showSignIn() {
        if (!mutableSignUpInProgress.value) mutableMode.value = AuthMode.SIGN_IN
    }

    fun onSignUpEmailChange(value: String) = mutableSignUp.update { it.copy(email = value) }

    fun onSignUpPasswordChange(value: String) = mutableSignUp.update { it.copy(password = value) }

    fun onConfirmPasswordChange(value: String) = mutableSignUp.update { it.copy(confirmPassword = value) }

    /**
     * アカウントを作り、続けてアカウント文書を作る（設計書「新規登録・匿名（M2）」のフロー）。
     * - 送れない入力では何もしない。入力の検証は AuthRepository.createEmailAccount の中でも行う（どの画面から呼んでも、通らない入力でアカウントを作らない）
     * - アカウントの作成に失敗したら、種類を出して iOS と同じ発生箇所で記録し、切り替えの停止を解く
     * - 文書には、作成で返った uid を渡す（認証状態の通知は非同期で、まだ切り替わっていないことがあるため）
     * - 文書の作成に失敗したら、セッションは保ったまま失敗を出し、切り替えの停止は「続ける」を押すまで解かない（要件 2.11）。
     *   記録は AccountBootstrapper が済ませているので、ここでは記録し直さない。欠けた文書は後で AccountDocumentRepairer が補う
     */
    fun signUp() {
        val current = mutableSignUp.value
        if (!current.canSubmit) return
        // アカウントを作る前に止める（作った瞬間に認証状態がログイン済みになるため）
        mutableSignUpInProgress.value = true
        mutableSignUp.update { it.copy(isSubmitting = true, error = null) }
        scope.launch {
            when (val created = repository.createEmailAccount(current.email, current.password)) {
                is AppResult.Err -> {
                    // iOS と同じ発生箇所で記録する（AuthViewModel.swift:114）
                    analytics.logError(created.error, "AuthViewModel.signUp")
                    mutableSignUp.update { it.copy(isSubmitting = false, error = authErrorKindOf(created.error)) }
                    mutableSignUpInProgress.value = false
                }
                is AppResult.Ok -> when (bootstrapper.bootstrap(created.value, current.email)) {
                    is AppResult.Ok -> finishSignUp()
                    is AppResult.Err -> mutableSignUp.update { it.copy(isSubmitting = false, bootstrapFailed = true) }
                }
            }
        }
    }

    /** 文書の作成の失敗を見せた後に「続ける」を押した。セッションは保ったまま、フィードへ切り替えさせる。 */
    fun continueAfterBootstrapFailure() {
        if (mutableSignUp.value.bootstrapFailed) finishSignUp()
    }

    /** 新規登録を終える。入力（パスワード）を手元に残さず、ログアウトして戻ったときはログインの画面にする。 */
    private fun finishSignUp() {
        mutableSignUp.value = SignUpUiState()
        mutableMode.value = AuthMode.SIGN_IN
        mutableSignUpInProgress.value = false
    }

    fun onEmailChange(value: String) = mutableState.update { it.copy(email = value) }

    fun onPasswordChange(value: String) = mutableState.update { it.copy(password = value) }

    /** 入力のままログインする。送信中は何もしない（二重に送らない）。 */
    fun signIn() {
        val current = mutableState.value
        if (!current.canSubmit) return
        // iOS も試行の最初に前の失敗の表示を消す（AuthViewModel.swift:76）
        mutableState.update { it.copy(isSubmitting = true, error = null) }
        scope.launch {
            val result = repository.signIn(current.email, current.password)
            val error = (result as? AppResult.Err)?.error
            if (error != null) {
                // iOS と同じ発生箇所で記録する（AuthViewModel.swift:87）。認証の失敗は user_error なので Crashlytics には残らない
                analytics.logError(error, "AuthViewModel.signIn")
            }
            mutableState.update {
                // 成功したらパスワードを手元に残さない（ログインしている間もメモリに持たない）。メールアドレスを含めた入力は、
                // ログアウト・退会で未ログインに移ったときに作り直す（init）
                it.copy(isSubmitting = false, error = error?.let(::authErrorKindOf), password = if (error == null) "" else it.password)
            }
        }
    }

    /** 画面に出す種類。認証以外の失敗（リポジトリは返さない想定）は「その他」の文言にする。 */
    private fun authErrorKindOf(error: AppError): AuthErrorKind = (error as? AppError.Auth)?.kind ?: AuthErrorKind.UNKNOWN
}
