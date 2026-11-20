// ⭐️ AuthRepository の実装：ログイン・新規登録（Auth のアカウント作成）・認証状態の監視・ログアウト・再認証・認証のアカウントの削除（タスク 8.1・8.2・14.1・31.2・要件 2.1〜2.3・2.5〜2.9・12.5）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.rules.EmailValidator
import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.data.edit.SessionEndReason
import com.yoshidometoru.soramoyou.data.edit.UserEditDataPurger
import com.yoshidometoru.soramoyou.platform.SessionManager
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * [AuthRepository] の実装。アプリの寿命と同じだけ生きる（AppContainer で 1 つだけ作る）。
 *
 * - 作った時点で認証状態の監視を始める。最初の通知（端末に保持されたセッションの状態）までは [SessionState.Loading]。
 *   監視は解除しない（アプリが終わるまで使う）。
 * - 依存は Firebase Authentication の継ぎ目（[AuthClient]）と、ログアウト時の消去（[SessionManager]）と、ログアウトが終わりを待つ
 *   走っている書き込みの数（[InFlightWrites]。数えるだけで書き込みはしない）だけで、書き込みの入口を持たない（要件 2.2・2.10）。
 * - 記録（分析の error_occurred など）はしない。iOS も記録は AuthViewModel 側で行っている（AuthViewModel.swift:87）。
 *
 * @param inFlightWrites 走っている取り消さない書き込み（プロフィールの保存・投稿の削除）の数。ログアウトがその終わりを待つ
 * @param inFlightWaitLimit ログアウトが [inFlightWrites] の終わりを待つ上限（2026-11-05 ユーザー判断で 10 秒）。単体テストでは短くする
 * @param purger ログアウトのときに端末の編集の途中（と、匿名なら下書き）を消す部品（タスク 17・design.md:962）。既定の NONE は何もしない
 */
internal class DefaultAuthRepository(
    private val client: AuthClient,
    private val sessionManager: SessionManager,
    private val inFlightWrites: InFlightWrites,
    private val inFlightWaitLimit: Duration = IN_FLIGHT_WAIT_LIMIT,
    private val purger: UserEditDataPurger = UserEditDataPurger.NONE,
) : AuthRepository {

    private val state = MutableStateFlow<SessionState>(SessionState.Loading)

    override val session: StateFlow<SessionState> = state.asStateFlow()

    init {
        // 通知は SDK のスレッドから来うる。MutableStateFlow の value の代入はスレッドをまたいでも安全
        client.addAuthStateListener { user -> state.value = user?.toSessionState() ?: SessionState.SignedOut }
    }

    override suspend fun signIn(email: String, password: String): AppResult<Unit> {
        // 入力の検査は、iOS と同じ順で SDK を呼ぶ前に行う（AuthService.swift:25-31）
        if (email.isEmpty() || password.isEmpty()) return failure(AuthErrorKind.INVALID_INPUT)
        if (!isValidSignInEmail(email)) return failure(AuthErrorKind.INVALID_EMAIL)

        return authCall { client.signIn(email, password) }
    }

    override suspend fun createEmailAccount(email: String, password: String): AppResult<Uid> {
        // 検査は iOS と同じ順で、SDK（＝アカウントの作成）を呼ぶ前に行う（AuthService.swift:41-52）。
        // ここに置くのは、どの画面から呼んでも、通らない入力で Firebase のアカウントを作らないため（要件 2.5・2.6）
        if (email.isEmpty() || password.isEmpty()) return failure(AuthErrorKind.INVALID_INPUT)
        // 形式は signIn の検査（iOS の isValidEmail と同じ）でなく、新規登録の規則（rules の isValidEmail と iOS の両方を満たす）で見る
        if (!EmailValidator.isValidForSignUp(email)) return failure(AuthErrorKind.INVALID_EMAIL)
        if (!TextLimits.isPasswordLongEnough(password)) return failure(AuthErrorKind.WEAK_PASSWORD)

        // 前後の空白は削らない（signIn と同じ。iOS の SignUpView.swift:255・AuthService.swift:51 も削らない）
        return authCall { Uid(client.createEmailAccount(email, password).uid) }
    }

    override suspend fun signOut(): AppResult<Unit> = withContext(NonCancellable) {
        // 全体を取り消さない。下の待ちの間にログアウトを押した画面が閉じても、ログアウトは最後まで行う（待ちを足す前と同じ約束）
        // 1. 走っている取り消さない書き込み（プロフィールの保存・投稿の削除）の終わりを、セッションを破棄する前に待つ（全体レビュー 4 回目 Q03）。
        //    破棄すると書き込みの入口が残りを未ログインとして断り、途中までの書き込みだけが残るため。上限を過ぎたら待たずに進む（2026-11-05 ユーザー判断）
        withTimeoutOrNull(inFlightWaitLimit) { inFlightWrites.awaitIdle() }
        // 破棄すると uid が読めなくなるので、破棄の前に控える（編集の途中を消す相手の uid と、匿名かどうか）
        val ending = client.currentUser()
        try {
            client.signOut()
        } catch (e: Exception) {
            // セッションが残ったまま端末のデータだけ消すと、ログイン中なのに何も出ない画面になる。消さずに失敗を返す
            return@withContext failure(AuthErrorKind.UNKNOWN)
        }
        // 2. 破棄を先にする。先に消すと、まだフィードを表示している画面が読み直して、前のユーザーのデータでキャッシュを埋め直す。
        //    破棄すると認証状態の通知で session が SignedOut になり、画面はログイン前に戻る（タスク 8.3）
        sessionManager.clearLocalUserData()
        // 3. 端末の編集の途中を消す。破棄に失敗したときは上で返っているので、ここには来ない。例外は投げない約束
        ending?.let { purger.purge(Uid(it.uid), if (it.isAnonymous) SessionEndReason.SIGN_OUT_ANONYMOUS else SessionEndReason.SIGN_OUT) }
        AppResult.Ok(Unit)
    }

    override suspend fun reauthenticate(password: String): AppResult<Unit> {
        // メールアドレスは認証状態の通知（[state]）でなく、呼んだ時点の SDK の値から取る（通知は非同期で、遅れて届くことがあるため）
        val user = client.currentUser() ?: return failure(AuthErrorKind.USER_NOT_FOUND)
        // メールアドレスの無いアカウント（匿名）はパスワードで再認証できない。Android の MVP には匿名が無いので、起きれば想定外＝その他
        val email = user.email?.takeIf { it.isNotEmpty() } ?: return failure(AuthErrorKind.UNKNOWN)
        // 空のパスワードは SDK に渡さない（ログインの検査と同じ。前後の空白は削らない）
        if (password.isEmpty()) return failure(AuthErrorKind.INVALID_INPUT)

        return authCall { client.reauthenticate(email, password) }
    }

    override suspend fun deleteAuthAccount(): AppResult<Unit> =
        // 端末内のデータは消さない（signOut と違う。退会の手順が、全ての段階の後に SessionManager で消す）
        authCall { client.deleteCurrentUser() }

    /**
     * [client] の呼び出しを、成功なら [AppResult.Ok]、失敗なら種類に写した [AppResult.Err] にする（ログインと新規登録で共通）。
     * 取り消しは失敗に変えずに伝える。
     */
    private inline fun <T> authCall(call: () -> T): AppResult<T> = try {
        AppResult.Ok(call())
    } catch (e: CancellationException) {
        // 画面を離れたなどの取り消しは、失敗として表示しない
        throw e
    } catch (e: AuthClientFailure) {
        failure(e.kind)
    } catch (e: Exception) {
        // 写せない失敗は「その他」。iOS も、認証のドメインでない失敗は unknown にしている（AuthService.swift:146-149）
        failure(AuthErrorKind.UNKNOWN)
    }

    private fun failure(kind: AuthErrorKind): AppResult.Err = AppResult.Err(AppError.Auth(kind))

    private fun AuthUser.toSessionState() = SessionState.SignedIn(Uid(uid), email, isAnonymous)

    private companion object {
        /**
         * ログアウトが走っている書き込みの終わりを待つ上限（2026-11-05 ユーザー判断）。電波が切れていると、書き込みは Storage の再試行の
         * 上限（60 秒）や Firestore の返事まで終わらないことがあるので、待ち続けずに打ち切ってログアウトする（待ちを足す前と同じ振る舞いに戻る）
         */
        val IN_FLIGHT_WAIT_LIMIT: Duration = 10.seconds
    }
}
