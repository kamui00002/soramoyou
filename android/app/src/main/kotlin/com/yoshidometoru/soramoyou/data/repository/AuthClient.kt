// ⭐️ 認証の継ぎ目：Firebase Authentication を呼ぶ部分を差し替えられるようにする（タスク 8.1・14.1・31.2・要件 2.1・2.3・2.8・12.5）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AuthErrorKind

/**
 * [DefaultAuthRepository] が使う、Firebase Authentication への継ぎ目（読み取りの FirestoreReadClient と同じ考え方）。
 * 本番は [FirebaseAuthClient]、単体テストは偽物。SDK の型（FirebaseUser など）はこの外へ出さない。
 */
internal interface AuthClient {

    /**
     * 認証状態の変化を [onChange] で知らせ始める。登録した時点の状態も 1 回知らせる
     * （Firebase の AuthStateListener は、登録の直後に端末に保持されたセッションの状態で 1 回呼ばれる）。
     * 端末に保持されたセッションの復元（要件 2.8）は、この最初の 1 回で行う。
     */
    fun addAuthStateListener(onChange: (AuthUser?) -> Unit)

    /**
     * メールアドレスとパスワードでログインする。失敗は [AuthClientFailure]（種類に写したもの）で投げる。
     * 写せない失敗は、それ以外の例外のまま投げてよい（受け取る側が「その他」として扱う）。
     */
    suspend fun signIn(email: String, password: String)

    /**
     * メールアドレスとパスワードでアカウントを作り、作ったユーザーを返す（Firebase は作成と同時にそのユーザーでログイン状態にする。タスク 14.1）。
     * 失敗は [signIn] と同じく [AuthClientFailure]（種類に写したもの）で投げる。入力の検査はここではしない（呼び出し側 [DefaultAuthRepository] の責任）。
     */
    suspend fun createEmailAccount(email: String, password: String): AuthUser

    /** 端末のセッションを破棄する（タスク 8.2）。認証状態の通知で未ログインが知らされる。失敗は例外のまま投げてよい。 */
    fun signOut()

    /**
     * いまログインしているユーザー（いなければ null。タスク 31.2）。呼んだ時点の SDK の値で、認証状態の通知を待たない。
     * 退会の再認証で、メールアドレスを取るのに使う。
     */
    fun currentUser(): AuthUser?

    /**
     * いまログインしているユーザーを、メールアドレス [email] とパスワード [password] で再認証する（タスク 31.2。iOS の `reauthenticate`：
     * AuthService.swift:99-110）。ログインしていなければ [AuthClientFailure]（USER_NOT_FOUND）を投げる。
     * SDK の失敗は [signIn] と同じく種類に写して投げる（誤ったパスワード → WRONG_PASSWORD など）。
     */
    suspend fun reauthenticate(email: String, password: String)

    /**
     * いまログインしているユーザーの認証のアカウントを削除する（タスク 31.2。iOS の `deleteAccount`：AuthService.swift:81-96）。
     * ログインしていなければ [AuthClientFailure]（USER_NOT_FOUND）を投げる。最後のログインが古いと REQUIRES_RECENT_LOGIN で失敗する。
     * 成功すると SDK はログアウトした状態になり、認証状態の通知で未ログインが知らされる。
     */
    suspend fun deleteCurrentUser()
}

/** 認証済みのユーザーのうち、アプリが使う項目だけ。 */
internal data class AuthUser(val uid: String, val email: String?, val isAnonymous: Boolean)

/** [AuthClient] の失敗を、種類に写したもの。[kind] の決め方は [authErrorKindOf] と [FirebaseAuthClient] を参照。 */
internal class AuthClientFailure(val kind: AuthErrorKind, cause: Throwable? = null) :
    Exception("AuthClientFailure.${kind.name}", cause)
