// ⭐️ ログイン・新規登録（Auth のアカウント作成）とセッションの監視の単体テスト（タスク 8.1・14.1・要件 2.1〜2.3・2.5〜2.8）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.edit.SessionEndReason
import com.yoshidometoru.soramoyou.data.edit.UserEditDataPurger
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.data.remote.write.StorageGateway
import com.yoshidometoru.soramoyou.data.remote.write.WriteGate
import com.yoshidometoru.soramoyou.platform.SessionManager
import com.yoshidometoru.soramoyou.platform.SessionScopedState
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/**
 * [DefaultAuthRepository] の単体テスト。Firebase Authentication の代わりに [FakeAuthClient] を使う。
 * 偽物は、本物の AuthStateListener と同じく「登録した直後に、端末に保持されたセッションの状態で 1 回呼ぶ」。
 */
class DefaultAuthRepositoryTest {

    /** 本物の Firebase Authentication の代わり。登録した直後に、いまの状態で 1 回知らせる。 */
    private class FakeAuthClient(
        private val restored: AuthUser? = null,
        private val notifyOnRegister: Boolean = true,
    ) : AuthClient {
        val signInCalls = mutableListOf<Pair<String, String>>()
        var failure: Exception? = null

        /** アカウントの作成を頼まれた入力（SDK を呼んだ＝アカウントが作られた、ことの記録）。 */
        val createCalls = mutableListOf<Pair<String, String>>()
        var createdUser = AuthUser(uid = "new-uid", email = "new@example.com", isAnonymous = false)
        var createFailure: Exception? = null
        private val listeners = mutableListOf<(AuthUser?) -> Unit>()

        override fun addAuthStateListener(onChange: (AuthUser?) -> Unit) {
            listeners += onChange
            if (notifyOnRegister) onChange(restored)
        }

        override suspend fun signIn(email: String, password: String) {
            signInCalls += email to password
            failure?.let { throw it }
        }

        override suspend fun createEmailAccount(email: String, password: String): AuthUser {
            createCalls += email to password
            createFailure?.let { throw it }
            return createdUser
        }

        /** 呼ばれた順の記録（セッションの消去との順序を見るため、偽物の SessionManager と共有する）。 */
        var log: MutableList<String> = mutableListOf()
        var signOutFailure: Exception? = null

        override fun signOut() {
            signOutFailure?.let { throw it }
            log += "auth.signOut"
            // 本物の SDK も、破棄すると currentUser() が null になり、未ログインを知らせる（破棄の後に uid を読む実装を、テストが赤にするため）
            current = null
            emit(null)
        }

        /** 認証状態の変化を、登録された全員に知らせる（ログインの成功・ログアウトを SDK が知らせるのをまねる）。 */
        fun emit(user: AuthUser?) = listeners.forEach { it(user) }

        /** SDK のいまのユーザー（タスク 31.2）。認証状態の通知とは別に、呼んだ時点の値を返す。 */
        var current: AuthUser? = restored

        override fun currentUser(): AuthUser? = current

        /** 再認証を頼まれた入力（タスク 31.2）。 */
        val reauthCalls = mutableListOf<Pair<String, String>>()
        var reauthFailure: Exception? = null

        override suspend fun reauthenticate(email: String, password: String) {
            reauthCalls += email to password
            reauthFailure?.let { throw it }
        }

        /** 認証のアカウントの削除を頼まれた回数（タスク 31.2）。順序は [log] にも残す。 */
        var deleteCalls = 0
        var deleteFailure: Exception? = null

        override suspend fun deleteCurrentUser() {
            deleteCalls++
            deleteFailure?.let { throw it }
            log += "auth.delete"
            // 本物の SDK も、アカウントを消すとログアウトした状態になり、未ログインを知らせる
            current = null
            emit(null)
        }
    }

    /** 消去を頼まれた回数と順を、client と同じ記録に残す SessionManager の偽物。 */
    private class FakeSessionManager(private val log: MutableList<String>) : SessionManager {
        override fun register(state: SessionScopedState) = Unit
        override suspend fun clearLocalUserData() {
            log += "clearLocalUserData"
        }
    }

    /** 端末の編集のデータの後始末の偽物。呼ばれた uid と理由を、client と同じ記録に残す（順序を見るため）。 */
    private class RecordingPurger(private val log: MutableList<String>) : UserEditDataPurger {
        val calls = mutableListOf<Pair<Uid, SessionEndReason>>()

        override suspend fun purge(uid: Uid, reason: SessionEndReason) {
            calls += uid to reason
            log += "purge ${uid.value} $reason"
        }
    }

    /** 走っている取り消さない書き込みの数（本物）。ログアウトのテストが、書き込みのまねをここで数える。 */
    private val inFlight = InFlightWrites()

    /** 偽物の SessionManager を添えて作る（記録は client と共有）。 */
    private fun repositoryOf(
        client: FakeAuthClient,
        inFlightWaitLimit: Duration = 10.seconds,
        purger: UserEditDataPurger = UserEditDataPurger.NONE,
    ) = DefaultAuthRepository(client, FakeSessionManager(client.log), inFlight, inFlightWaitLimit, purger)

    private val user = AuthUser(uid = "uid-1", email = "a@example.com", isAnonymous = false)

    @Test
    fun `セッションの確認が終わるまでは確認中`() {
        val repository = repositoryOf(FakeAuthClient(notifyOnRegister = false))

        assertEquals(SessionState.Loading, repository.session.value)
    }

    @Test
    fun `端末に保持されたセッションがあれば、ログインせずにログイン済みになる（再起動時の復元）`() {
        val client = FakeAuthClient(restored = user)

        val repository = repositoryOf(client)

        assertEquals(SessionState.SignedIn(Uid("uid-1"), "a@example.com", isAnonymous = false), repository.session.value)
        assertEquals(emptyList(), client.signInCalls)
    }

    @Test
    fun `保持されたセッションが無ければ未ログインになる`() {
        val repository = repositoryOf(FakeAuthClient(restored = null))

        assertEquals(SessionState.SignedOut, repository.session.value)
    }

    @Test
    fun `認証状態の変化に追従する`() {
        val client = FakeAuthClient(restored = null)
        val repository = repositoryOf(client)

        client.emit(user.copy(uid = "uid-2", email = null, isAnonymous = true))
        assertEquals(SessionState.SignedIn(Uid("uid-2"), null, isAnonymous = true), repository.session.value)

        client.emit(null)
        assertEquals(SessionState.SignedOut, repository.session.value)
    }

    @Test
    fun `入力をそのままSDKに渡してログインする`() = runBlocking {
        val client = FakeAuthClient()
        val repository = repositoryOf(client)

        val result = repository.signIn("a@example.com", "pass word")

        assertEquals(AppResult.Ok(Unit), result)
        // iOS と同じく、前後の空白を削るなどの加工をしない（AuthService.swift:34）
        assertEquals(listOf("a@example.com" to "pass word"), client.signInCalls)
    }

    @Test
    fun `メールアドレスかパスワードが空なら、SDKを呼ばずに入力不足を返す`() = runBlocking {
        val client = FakeAuthClient()
        val repository = repositoryOf(client)

        listOf("" to "password", "a@example.com" to "", "" to "").forEach { (email, password) ->
            assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.INVALID_INPUT)), repository.signIn(email, password), "$email / $password")
        }
        assertEquals(emptyList(), client.signInCalls)
    }

    @Test
    fun `メールアドレスの形式が不正なら、SDKを呼ばずに形式の誤りを返す`() = runBlocking {
        val client = FakeAuthClient()
        val repository = repositoryOf(client)

        // 入力不足の検査が先（iOS: AuthService.swift:25-31）。形式の誤りでも、パスワードが空なら入力不足
        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.INVALID_INPUT)), repository.signIn("not-an-email", ""))
        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.INVALID_EMAIL)), repository.signIn("not-an-email", "password"))
        assertEquals(emptyList(), client.signInCalls)
    }

    @Test
    fun `SDKの失敗は写した種類で返す`() = runBlocking {
        val client = FakeAuthClient().apply { failure = AuthClientFailure(AuthErrorKind.WRONG_PASSWORD) }
        val repository = repositoryOf(client)

        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.WRONG_PASSWORD)), repository.signIn("a@example.com", "x"))
    }

    @Test
    fun `写せない失敗はその他として返し、例外を外へ出さない`() = runBlocking {
        val client = FakeAuthClient().apply { failure = IllegalStateException("内部の失敗") }
        val repository = repositoryOf(client)

        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.UNKNOWN)), repository.signIn("a@example.com", "x"))
    }

    @Test
    fun `取り消しは失敗に変えずにそのまま伝える`() {
        val client = FakeAuthClient().apply { failure = CancellationException("取り消し") }
        val repository = repositoryOf(client)

        assertFailsWith<CancellationException> { runBlocking { repository.signIn("a@example.com", "x") } }
    }

    // ---- 新規登録（Auth のアカウント作成だけ。タスク 14.1・要件 2.3・2.5・2.6・2.7）----

    @Test
    fun `アカウントを作り、作ったアカウントのuidを返す`() = runBlocking {
        val client = FakeAuthClient().apply { createdUser = AuthUser("created-uid", "taro@example.com", isAnonymous = false) }
        val repository = repositoryOf(client)

        val result = repository.createEmailAccount("taro@example.com", "secret1")

        assertEquals(AppResult.Ok(Uid("created-uid")), result)
        assertEquals(listOf("taro@example.com" to "secret1"), client.createCalls)
    }

    @Test
    fun `入力をそのままSDKに渡す（パスワードの前後の空白を削らない）`() = runBlocking {
        val client = FakeAuthClient()
        val repository = repositoryOf(client)

        // 6 文字のうち 4 文字が空白。削ると 2 文字になって弱いパスワードになるので、削らずに渡したことが分かる（iOS も削らない）
        val result = repository.createEmailAccount("a@example.com", "  ab  ")

        assertEquals(AppResult.Ok(Uid("new-uid")), result)
        assertEquals(listOf("a@example.com" to "  ab  "), client.createCalls)
    }

    @Test
    fun `メールアドレスかパスワードが空なら、アカウントを作らずに入力不足を返す`() = runBlocking {
        val client = FakeAuthClient()
        val repository = repositoryOf(client)

        listOf("" to "password", "a@example.com" to "", "" to "").forEach { (email, password) ->
            assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.INVALID_INPUT)), repository.createEmailAccount(email, password), "$email / $password")
        }
        assertEquals(emptyList(), client.createCalls)
    }

    @Test
    fun `メールアドレスの形式が不正なら、アカウントを作らずに形式の誤りを返す`() = runBlocking {
        val client = FakeAuthClient()
        val repository = repositoryOf(client)

        listOf(
            "not-an-email",
            "a@b", // TLD が無い
            "a@b.c", // TLD が 1 文字
            " a@example.com", // 前後の空白は削らない
            "a@example.com\n", // 末尾の改行（部分一致なら通ってしまう）
            "a@b." + "x".repeat(65), // iOS の TLD の上限（64）を超える
            "a".repeat(243) + "@example.com", // 255 文字。firestore.rules の上限（254）を超える
            "\uFF41@example.com", // 全角の a。iOS は通すが rules は通さない（EmailValidator の注記）
        ).forEach { email ->
            assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.INVALID_EMAIL)), repository.createEmailAccount(email, "password"), email)
        }
        assertEquals(emptyList(), client.createCalls)
    }

    @Test
    fun `パスワードが6文字未満なら、アカウントを作らずに弱いパスワードを返す`() = runBlocking {
        val client = FakeAuthClient()
        val repository = repositoryOf(client)

        // 家族の絵文字（ZWJ でつないだ 1 文字）。UTF-16 では 8 個だが、見た目の 1 文字として数える（iOS の String.count と同じ）
        val family = buildString {
            appendCodePoint(0x1F468)
            appendCodePoint(0x200D)
            appendCodePoint(0x1F469)
            appendCodePoint(0x200D)
            appendCodePoint(0x1F467)
        }
        listOf("12345", "\u3042\u3044\u3046\u3048\u304A", family.repeat(5)).forEach { password ->
            assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.WEAK_PASSWORD)), repository.createEmailAccount("a@example.com", password), password)
        }
        assertEquals(emptyList(), client.createCalls)

        // ちょうど 6 文字なら通る
        assertEquals(AppResult.Ok(Uid("new-uid")), repository.createEmailAccount("a@example.com", "123456"))
        assertEquals(listOf("a@example.com" to "123456"), client.createCalls)
    }

    @Test
    fun `検査は入力不足、メールアドレスの形式、パスワードの長さの順（iOSと同じ）`() = runBlocking {
        val client = FakeAuthClient()
        val repository = repositoryOf(client)

        // iOS: AuthService.swift:41-52
        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.INVALID_INPUT)), repository.createEmailAccount("not-an-email", ""))
        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.INVALID_EMAIL)), repository.createEmailAccount("not-an-email", "123"))
        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.WEAK_PASSWORD)), repository.createEmailAccount("a@example.com", "123"))
        assertEquals(emptyList(), client.createCalls)
    }

    @Test
    fun `アカウントの作成の失敗は写した種類で返す（使用済みのメールアドレス・弱いパスワードなど）`() = runBlocking {
        listOf(
            AuthErrorKind.EMAIL_ALREADY_IN_USE,
            // 6 文字以上でも、サーバーが弱いと判断することがある
            AuthErrorKind.WEAK_PASSWORD,
            AuthErrorKind.INVALID_EMAIL,
            AuthErrorKind.NETWORK,
            AuthErrorKind.TOO_MANY_REQUESTS,
        ).forEach { kind ->
            val client = FakeAuthClient().apply { createFailure = AuthClientFailure(kind) }
            val repository = repositoryOf(client)

            assertEquals(AppResult.Err(AppError.Auth(kind)), repository.createEmailAccount("a@example.com", "password"), "$kind")
            assertEquals(1, client.createCalls.size, "$kind")
        }
    }

    @Test
    fun `写せないアカウントの作成の失敗はその他として返し、例外を外へ出さない`() = runBlocking {
        val client = FakeAuthClient().apply { createFailure = IllegalStateException("内部の失敗") }
        val repository = repositoryOf(client)

        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.UNKNOWN)), repository.createEmailAccount("a@example.com", "password"))
    }

    @Test
    fun `アカウントの作成の取り消しは失敗に変えずにそのまま伝える`() {
        val client = FakeAuthClient().apply { createFailure = CancellationException("取り消し") }
        val repository = repositoryOf(client)

        assertFailsWith<CancellationException> { runBlocking { repository.createEmailAccount("a@example.com", "password") } }
    }

    @Test
    fun `ログアウトはセッションを破棄してから端末内のデータを消す`() = runBlocking {
        val client = FakeAuthClient(restored = user)
        val repository = repositoryOf(client)

        val result = repository.signOut()

        assertEquals(AppResult.Ok(Unit), result)
        // 先に消すと、まだフィードを表示している画面が読み直してキャッシュを埋め直すため、破棄が先
        assertEquals(listOf("auth.signOut", "clearLocalUserData"), client.log)
        assertEquals(SessionState.SignedOut, repository.session.value)
    }

    @Test
    fun `セッションの破棄に失敗したら、データを消さずに失敗を返す`() = runBlocking {
        val client = FakeAuthClient(restored = user).apply { signOutFailure = IllegalStateException("破棄できない") }
        val repository = repositoryOf(client)

        val result = repository.signOut()

        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.UNKNOWN)), result)
        assertEquals(emptyList(), client.log)
    }

    // ---- ログアウトでの端末の編集のデータの後始末（タスク 17・design.md:962）----

    @Test
    fun `ログアウトは、破棄の前に控えたuidで、端末のデータの消去の後に後始末を呼ぶ`() = runBlocking {
        val client = FakeAuthClient(restored = user)
        val purger = RecordingPurger(client.log)
        val repository = repositoryOf(client, purger = purger)

        val result = repository.signOut()

        assertEquals(AppResult.Ok(Unit), result)
        // 破棄の後は SDK が currentUser() を返さない。破棄の前に控えた uid が渡る（匿名でないので SIGN_OUT）
        assertEquals(listOf(Uid("uid-1") to SessionEndReason.SIGN_OUT), purger.calls)
        // 順序：セッションの破棄 → 端末内のデータの消去 → 編集のデータの後始末
        assertEquals(listOf("auth.signOut", "clearLocalUserData", "purge uid-1 SIGN_OUT"), client.log)
    }

    @Test
    fun `匿名のアカウントのログアウトは、匿名のログアウトとして後始末を呼ぶ`() = runBlocking {
        val client = FakeAuthClient(restored = user.copy(uid = "anon-1", email = null, isAnonymous = true))
        val purger = RecordingPurger(client.log)
        val repository = repositoryOf(client, purger = purger)

        repository.signOut()

        assertEquals(listOf(Uid("anon-1") to SessionEndReason.SIGN_OUT_ANONYMOUS), purger.calls)
    }

    @Test
    fun `セッションの破棄に失敗したら、後始末を呼ばない（下書きを消してログイン中のままにしない）`() = runBlocking {
        val client = FakeAuthClient(restored = user).apply { signOutFailure = IllegalStateException("破棄できない") }
        val purger = RecordingPurger(client.log)
        val repository = repositoryOf(client, purger = purger)

        val result = repository.signOut()

        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.UNKNOWN)), result)
        assertEquals(emptyList(), purger.calls)
        assertEquals(emptyList(), client.log)
    }

    @Test
    fun `ログインしているユーザーがいなければ、後始末の相手が分からないので呼ばない`() = runBlocking {
        val client = FakeAuthClient(restored = null)
        val purger = RecordingPurger(client.log)
        val repository = repositoryOf(client, purger = purger)

        val result = repository.signOut()

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(emptyList(), purger.calls)
    }

    // ---- ログアウトと、走っている取り消さない書き込み（全体レビュー 4 回目 Q03）----
    // 書き込みのまねは、テストが完了させるまで終わらない待ち。ログアウトは取り消さないので、確かめが失敗しても待ちを finally で外す
    // （外さないと runBlocking が子を待ち続けて、赤でなく止まりになる）

    @Test
    fun `ログアウトは、走っている書き込みが終わるまでセッションを破棄しない`() = runBlocking {
        // プロフィールの保存・投稿の削除の途中でセッションを破棄すると、書き込みの入口が残りを未ログインとして断り、途中までの書き込みだけが残る
        val client = FakeAuthClient(restored = user)
        val repository = repositoryOf(client)
        val release = CompletableDeferred<Unit>()
        val writing = launch(Dispatchers.Unconfined) { inFlight.track { release.await() } }
        val signingOut = launch(Dispatchers.Unconfined) { repository.signOut() }
        try {
            // 破棄も消去もまだ（破棄の後で待つのでは、残りの書き込みが断られる）
            assertEquals(emptyList(), client.log)
        } finally {
            release.complete(Unit)
        }
        writing.join()
        signingOut.join()

        assertEquals(listOf("auth.signOut", "clearLocalUserData"), client.log)
        assertEquals(SessionState.SignedOut, repository.session.value)
    }

    @Test
    fun `ログアウトは、待つ上限を過ぎたら書き込みの終わりを待たずに行う`() = runBlocking {
        // 電波が切れていると書き込みが終わらないことがある。上限（本番は 10 秒）を過ぎたら、待ちを足す前と同じくログアウトする
        val client = FakeAuthClient(restored = user)
        val repository = repositoryOf(client, inFlightWaitLimit = 100.milliseconds)
        val release = CompletableDeferred<Unit>()
        val writing = launch(Dispatchers.Unconfined) { inFlight.track { release.await() } }
        val signingOut = launch(Dispatchers.Unconfined) { repository.signOut() }
        try {
            // ログアウトは取り消さないので、上限が無いと終わらない。待つのは join の方で、テストの上限で赤にする（止まりにしない）
            withTimeout(5.seconds) { signingOut.join() }
            assertEquals(listOf("auth.signOut", "clearLocalUserData"), client.log)
            // 書き込みはまだ走っている（終わりを待たずに進んだ）
            assertTrue(inFlight.isBusy())
        } finally {
            release.complete(Unit)
        }
        writing.join()
        signingOut.join()
    }

    @Test
    fun `ログアウトの待ちの間に呼び出し側が取り消されても、書き込みが終わった後にログアウトを最後まで行う`() = runBlocking {
        // 待ちの間に設定の画面を閉じると、ログアウトを呼んだ viewModelScope が取り消される。待ちで取り消されると、押したのにログアウトしない
        val client = FakeAuthClient(restored = user)
        val repository = repositoryOf(client)
        val release = CompletableDeferred<Unit>()
        val writing = launch(Dispatchers.Unconfined) { inFlight.track { release.await() } }
        val signingOut = launch(Dispatchers.Unconfined) { repository.signOut() }
        try {
            assertEquals(emptyList(), client.log)
            signingOut.cancel()
        } finally {
            release.complete(Unit)
        }
        writing.join()
        signingOut.join()

        assertEquals(listOf("auth.signOut", "clearLocalUserData"), client.log)
    }

    // ---- 再認証・認証のアカウントの削除（退会。タスク 31.2・要件 12.5）----

    @Test
    fun `再認証は、SDKのいまのユーザーのメールアドレスと入力したパスワードで行う`() = runBlocking {
        val client = FakeAuthClient(restored = user)
        val repository = repositoryOf(client)

        val result = repository.reauthenticate(" pass word ")

        assertEquals(AppResult.Ok(Unit), result)
        // パスワードは加工しない（ログイン・新規登録と同じ）
        assertEquals(listOf("a@example.com" to " pass word "), client.reauthCalls)
    }

    @Test
    fun `再認証のメールアドレスは、認証状態の通知でなく呼んだ時点のSDKの値から取る`() = runBlocking {
        val client = FakeAuthClient(restored = user)
        val repository = repositoryOf(client)
        // 通知がまだ届いていない間に、SDK のいまのユーザーが変わった（通知を待たずに読むことの確かめ）
        client.current = user.copy(email = "b@example.com")

        repository.reauthenticate("password")

        assertEquals(listOf("b@example.com" to "password"), client.reauthCalls)
    }

    @Test
    fun `ログインしていなければ、SDKを呼ばずにユーザーが見つからないを返す`() = runBlocking {
        val client = FakeAuthClient(restored = null)
        val repository = repositoryOf(client)

        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.USER_NOT_FOUND)), repository.reauthenticate("password"))
        assertEquals(emptyList(), client.reauthCalls)
    }

    @Test
    fun `メールアドレスの無いアカウントは再認証できないので、SDKを呼ばずにその他を返す`() = runBlocking {
        // 匿名（Android の MVP には無い：タスク 12）。空のメールアドレスも同じ扱い
        listOf(user.copy(email = null, isAnonymous = true), user.copy(email = "")).forEach { current ->
            val client = FakeAuthClient(restored = current)
            val repository = repositoryOf(client)

            assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.UNKNOWN)), repository.reauthenticate("password"), "$current")
            assertEquals(emptyList(), client.reauthCalls)
        }
    }

    @Test
    fun `パスワードが空なら、SDKを呼ばずに入力不足を返す`() = runBlocking {
        val client = FakeAuthClient(restored = user)
        val repository = repositoryOf(client)

        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.INVALID_INPUT)), repository.reauthenticate(""))
        assertEquals(emptyList(), client.reauthCalls)
    }

    @Test
    fun `再認証のSDKの失敗は写した種類で返し、写せない失敗はその他にする`() = runBlocking {
        val client = FakeAuthClient(restored = user).apply { reauthFailure = AuthClientFailure(AuthErrorKind.WRONG_PASSWORD) }
        val repository = repositoryOf(client)
        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.WRONG_PASSWORD)), repository.reauthenticate("x"))

        client.reauthFailure = IllegalStateException("内部の失敗")
        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.UNKNOWN)), repository.reauthenticate("x"))
    }

    @Test
    fun `認証のアカウントを削除し、端末内のデータは消さない（退会の手順が消す）`() = runBlocking {
        val client = FakeAuthClient(restored = user)
        val repository = repositoryOf(client)

        val result = repository.deleteAuthAccount()

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(1, client.deleteCalls)
        // signOut と違い clearLocalUserData は呼ばない（AccountDeletionService が SessionManager で消す。二重に消さない）
        assertEquals(listOf("auth.delete"), client.log)
        assertEquals(SessionState.SignedOut, repository.session.value)
    }

    @Test
    fun `認証のアカウントの削除の失敗は写した種類で返す（最近のログインが必要など）`() = runBlocking {
        val client = FakeAuthClient(restored = user).apply { deleteFailure = AuthClientFailure(AuthErrorKind.REQUIRES_RECENT_LOGIN) }
        val repository = repositoryOf(client)

        assertEquals(AppResult.Err(AppError.Auth(AuthErrorKind.REQUIRES_RECENT_LOGIN)), repository.deleteAuthAccount())
        assertEquals(emptyList(), client.log)
    }

    @Test
    fun `書き込みの入口に依存しない（ログインの中で書き込めない）`() {
        // 要件 2.2。コンストラクタで受け取れないものは呼べない。書き込み API そのものの閉じ込めは WriteApiConfinementTest が見る
        val forbidden = setOf(FirestoreWriteGateway::class.java, StorageGateway::class.java, WriteGate::class.java)

        val parameterTypes = DefaultAuthRepository::class.java.constructors.flatMap { it.parameterTypes.toList() }

        assertTrue(parameterTypes.isNotEmpty(), "コンストラクタの引数を読めていない")
        assertTrue(parameterTypes.none { type -> forbidden.any { it.isAssignableFrom(type) } }, "書き込みの入口を受け取っている: $parameterTypes")
    }
}
