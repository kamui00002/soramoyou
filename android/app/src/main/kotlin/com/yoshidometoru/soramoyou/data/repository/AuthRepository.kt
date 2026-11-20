// ⭐️ ログイン・新規登録（Auth のアカウント作成）・認証状態（セッション）の監視（タスク 8.1・14.1・31.2・要件 2.1〜2.3・2.5〜2.8・12.5）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import kotlinx.coroutines.flow.StateFlow

/** 認証状態。画面の切り替え（タスク 8.3）はこれだけを根拠にする（設計書 :728-732）。 */
sealed interface SessionState {
    /** 端末に保持されたセッションの確認がまだ終わっていない（起動直後）。 */
    data object Loading : SessionState

    /** ログインしていない。 */
    data object SignedOut : SessionState

    /** ログインしている。 */
    data class SignedIn(val uid: Uid, val email: String?, val isAnonymous: Boolean) : SessionState
}

/**
 * 認証とセッション（設計書の部品 AuthRepository）。
 *
 * 使うものだけを持つ。設計書 :734-742 のうち、新規登録は M2 のタスク 14.1 で、再認証・Auth アカウントの削除は M5 の退会（タスク 31.2）で足した。
 * 匿名ログイン（設計書の `signInAnonymously`）は作らない（2026-10-05 ユーザー判断：Android の MVP から匿名を外す。タスク 12）。
 *
 * 書き込みの入口（FirestoreWriteGateway・StorageGateway・WriteGate）には依存しない（要件 2.2。
 * ログインの処理の中で Firestore・Storage へ書き込まない。DefaultAuthRepositoryTest がコンストラクタの引数で確かめる）。
 */
interface AuthRepository {
    /** いまの認証状態。初めは [SessionState.Loading] で、端末に保持されたセッションの確認が済むと切り替わる。 */
    val session: StateFlow<SessionState>

    /**
     * 既存アカウントにメールアドレスとパスワードでログインする。
     * 失敗は [AppResult.Err] の [com.yoshidometoru.soramoyou.contract.AppError.Auth] で返し、例外は投げない（取り消しを除く）。
     * 成功しても [session] の切り替えは認証状態の通知で起きる（呼び出し側は戻り値で画面を切り替えない）。
     */
    suspend fun signIn(email: String, password: String): AppResult<Unit>

    /**
     * メールアドレスとパスワードで Firebase Authentication のアカウントを作り、作ったアカウントの uid を返す（タスク 14.1・要件 2.3）。
     * **認証のアカウントを作るだけで、Firestore の文書（users・publicProfiles）は書かない**。文書の作成は、呼び出し側が
     * この後に AccountBootstrapper（タスク 14.2）で行う（設計書 :317-340）。
     *
     * 検証はここで行い、通らなければ SDK を呼ばず（＝アカウントを作らず）に失敗を返す（要件 2.5・2.6）。どの画面から呼んでも同じ。
     * 順は iOS と同じ（AuthService.swift:41-52）。
     * 1. どちらかが空 → [com.yoshidometoru.soramoyou.contract.AuthErrorKind.INVALID_INPUT]
     * 2. メールアドレスの形式が新規登録の規則（`EmailValidator.isValidForSignUp`）を通らない → INVALID_EMAIL
     * 3. パスワードが 6 文字（書記素）未満 → WEAK_PASSWORD
     * 前後の空白は取り除かない（[signIn] と同じ。iOS もしない）。
     *
     * SDK の失敗は種類に写して [AppResult.Err] で返し、例外は投げない（取り消しを除く）。使用済みのメールアドレスは EMAIL_ALREADY_IN_USE、
     * サーバーが弱いと判断したパスワードは WEAK_PASSWORD。
     * 作成に成功すると SDK がそのままログイン状態にするので、[session] は認証状態の通知で SignedIn に切り替わる（戻り値で切り替えない）。
     */
    suspend fun createEmailAccount(email: String, password: String): AppResult<Uid>

    /**
     * ログアウトする（タスク 8.2・要件 2.9）。セッションを破棄してから、端末内のそのユーザーのデータを消す
     * （[com.yoshidometoru.soramoyou.platform.SessionManager.clearLocalUserData]）。
     * セッションの破棄に失敗したら、データは消さずに [AppResult.Err] を返す（ログイン中のまま画面だけが空になるのを避ける）。
     * 破棄の前に、走っている取り消さない書き込み（プロフィールの保存・投稿の削除）の終わりを上限まで待つ（全体レビュー 4 回目 Q03）。
     * 呼び出し側が取り消されても、始めたログアウトは最後まで行う。
     */
    suspend fun signOut(): AppResult<Unit>

    /**
     * いまログインしているメールアカウントを、パスワード [password] で再認証する（タスク 31.2・要件 12.5）。
     * 退会（AccountDeletionService）が、**データを消し始める前に**呼ぶ（iOS SettingsViewModel.swift:241-243 と同じ順）。
     * メールアドレスは、呼んだ時点の SDK のいまのユーザーから取る（設計書の口 `reauthenticate(password)` のとおり、画面にはパスワードだけを入力させる。
     * iOS はメールアドレスも入力させる〔SettingsView.swift:129・235〕＝差。打ち間違えた別のアドレスで失敗する経路を作らないため）。
     *
     * 1. ログインしていない → [com.yoshidometoru.soramoyou.contract.AuthErrorKind.USER_NOT_FOUND]（iOS AuthService.swift:100-102）
     * 2. メールアドレスの無いアカウント（匿名。Android の MVP には無い：タスク 12）→ UNKNOWN。パスワードで再認証できないため
     * 3. パスワードが空 → INVALID_INPUT（SDK を呼ばない。ログインの入力の検査と同じ扱い）
     * 4. SDK の失敗は種類に写す（誤ったパスワード → WRONG_PASSWORD、通信 → NETWORK など）
     *
     * 失敗は [AppResult.Err] の [com.yoshidometoru.soramoyou.contract.AppError.Auth] で返し、例外は投げない（取り消しを除く）。記録はしない（呼び出し側が行う）。
     */
    suspend fun reauthenticate(password: String): AppResult<Unit>

    /**
     * いまログインしているユーザーの Firebase Authentication のアカウントを削除する（タスク 31.2。退会の最後の段階）。
     * 端末内のデータは**消さない**（退会の手順 AccountDeletionService が、この後に SessionManager で消す。[signOut] と違う点）。
     * 成功すると SDK はログアウトした状態になり、[session] は認証状態の通知で SignedOut に切り替わる。
     *
     * ログインしていなければ USER_NOT_FOUND、最後のログインが古ければ REQUIRES_RECENT_LOGIN。
     * 失敗は [AppResult.Err] の [com.yoshidometoru.soramoyou.contract.AppError.Auth] で返し、例外は投げない（取り消しを除く）。記録はしない。
     */
    suspend fun deleteAuthAccount(): AppResult<Unit>
}
