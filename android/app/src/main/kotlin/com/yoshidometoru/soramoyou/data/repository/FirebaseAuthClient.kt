// ☁️ 認証の継ぎ目の本番の実装：Firebase Authentication の SDK を呼ぶ（タスク 8.1・14.1・31.2）
package com.yoshidometoru.soramoyou.data.repository

import com.google.firebase.FirebaseNetworkException
import com.google.firebase.FirebaseTooManyRequestsException
import com.google.firebase.auth.EmailAuthProvider
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseAuthException
import com.google.firebase.auth.FirebaseUser
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import kotlinx.coroutines.tasks.await

/**
 * [AuthClient] の本番の実装。SDK の失敗を種類に写して [AuthClientFailure] で投げるだけで、判断はしない。
 * 単体テストはしない（SDK の例外を JVM で作れない。読み取りの FirebaseFirestoreReadClient と同じ扱い）。
 * 写し方の表は [authErrorKindOf] にあり、そちらを単体テストする。
 *
 * セッションの保持（再起動をまたいだ復元）は SDK が端末に保存して行う。ここでは何もしない。
 *
 * @param auth AppContainer で得た FirebaseAuth のインスタンス。
 */
internal class FirebaseAuthClient(private val auth: FirebaseAuth) : AuthClient {

    override fun addAuthStateListener(onChange: (AuthUser?) -> Unit) {
        // SDK は登録の直後に、いまの状態で 1 回呼ぶ（AuthClient の約束）
        auth.addAuthStateListener { firebaseAuth -> onChange(firebaseAuth.currentUser?.toAuthUser()) }
    }

    override suspend fun signIn(email: String, password: String) {
        mappingFailures { auth.signInWithEmailAndPassword(email, password).await() }
    }

    override suspend fun createEmailAccount(email: String, password: String): AuthUser {
        // 使用済みのメールアドレス（FirebaseAuthUserCollisionException）・弱いパスワード（FirebaseAuthWeakPasswordException）・
        // 形式の誤り（FirebaseAuthInvalidCredentialsException）は、どれも FirebaseAuthException の子で、errorCode が authErrorKindOf の表に載っている
        val created = mappingFailures { auth.createUserWithEmailAndPassword(email, password).await() }
        // 成功した作成の結果にユーザーが無いことは無い。万一のときは、写せない失敗（その他）として投げる
        val user = created.user ?: throw IllegalStateException("アカウントの作成に成功したが、ユーザーが返らなかった")
        return user.toAuthUser()
    }

    override fun signOut() {
        auth.signOut()
    }

    override fun currentUser(): AuthUser? = auth.currentUser?.toAuthUser()

    override suspend fun reauthenticate(email: String, password: String) {
        // iOS と同じく、ログインしていなければ USER_NOT_FOUND（AuthService.swift:100-102）
        val user = auth.currentUser ?: throw AuthClientFailure(AuthErrorKind.USER_NOT_FOUND)
        // 別のアカウントの資格情報（ERROR_USER_MISMATCH）は表に無いので「その他」になる
        mappingFailures { user.reauthenticate(EmailAuthProvider.getCredential(email, password)).await() }
    }

    override suspend fun deleteCurrentUser() {
        val user = auth.currentUser ?: throw AuthClientFailure(AuthErrorKind.USER_NOT_FOUND)
        // 最後のログインが古い（FirebaseAuthRecentLoginRequiredException）は errorCode が ERROR_REQUIRES_RECENT_LOGIN で、
        // authErrorKindOf の表で REQUIRES_RECENT_LOGIN に写る（iOS AuthService.swift:89-93 と同じ種類）
        mappingFailures { user.delete().await() }
    }

    /** SDK の失敗を、種類に写した [AuthClientFailure] にして投げ直す（ログインと新規登録で同じ写し方にするため、1 か所にまとめる）。 */
    private inline fun <T> mappingFailures(call: () -> T): T {
        try {
            return call()
        } catch (e: FirebaseNetworkException) {
            throw AuthClientFailure(AuthErrorKind.NETWORK, e)
        } catch (e: FirebaseTooManyRequestsException) {
            throw AuthClientFailure(AuthErrorKind.TOO_MANY_REQUESTS, e)
        } catch (e: FirebaseAuthException) {
            throw AuthClientFailure(authErrorKindOf(e.errorCode), e)
        }
    }

    private fun FirebaseUser.toAuthUser() = AuthUser(uid = uid, email = email, isAnonymous = isAnonymous)
}
