// ⭐️ 画面の ViewModel の単体テストで共有する偽物（タスク 8.3）
package com.yoshidometoru.soramoyou.feature

import androidx.lifecycle.SavedStateHandle
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.remote.write.WriteGate
import com.yoshidometoru.soramoyou.data.repository.AccountBootstrapper
import com.yoshidometoru.soramoyou.data.repository.AuthRepository
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.EventName
import com.yoshidometoru.soramoyou.platform.ParamValue
import com.yoshidometoru.soramoyou.platform.ScreenName
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * ViewModel に渡すスコープ。Unconfined なので、launch は最初の中断までその場で進み、
 * 中断していた処理は [CompletableDeferred.complete] を呼んだスレッドで続きを進める（テストの中で順に確かめられる）。
 */
fun immediateScope(): CoroutineScope = CoroutineScope(Dispatchers.Unconfined)

/**
 * プロセスが落ちて作り直されたときに、画面の保存の箱（SavedStateHandle）が戻す中身の写し（全体レビュー 4 回目 Q09・Q10）。
 * 本物は Bundle を通して戻すが、JVM の単体テストでは Bundle を作れないので、鍵と値を写した新しい箱にする。
 * 写す前に、Bundle に入れられる型だけを残していることも確かめる（このアプリの画面が残すのは文字列と真偽値だけ）。
 */
fun SavedStateHandle.afterProcessDeath(): SavedStateHandle {
    val values = keys().associateWith { get<Any?>(it) }
    values.forEach { (key, value) -> check(value is String || value is Boolean) { "文字列・真偽値でない値を残している: $key=$value" } }
    return SavedStateHandle(values)
}

/** 結果を外から渡すまで待つ AuthRepository の偽物。呼ばれた回数と入力を記録する。 */
class FakeAuthRepository(initial: SessionState = SessionState.SignedOut) : AuthRepository {
    val sessionFlow = MutableStateFlow(initial)
    override val session: StateFlow<SessionState> = sessionFlow

    val signInCalls = mutableListOf<Pair<String, String>>()
    var signInResult = CompletableDeferred<AppResult<Unit>>()
    val createEmailAccountCalls = mutableListOf<Pair<String, String>>()
    var createEmailAccountResult = CompletableDeferred<AppResult<Uid>>()
    var signOutCalls = 0
    var signOutResult = CompletableDeferred<AppResult<Unit>>()

    override suspend fun signIn(email: String, password: String): AppResult<Unit> {
        signInCalls += email to password
        return signInResult.await()
    }

    override suspend fun createEmailAccount(email: String, password: String): AppResult<Uid> {
        createEmailAccountCalls += email to password
        return createEmailAccountResult.await()
    }

    override suspend fun signOut(): AppResult<Unit> {
        signOutCalls++
        return signOutResult.await()
    }

    // 再認証と認証のアカウントの削除（タスク 31.2 で AuthRepository に足した）は、AuthRepository の約束を満たすためだけに置く。
    // この偽物を使う画面（設定・認証）のテストは呼ばず、31.5 の退会の画面のテストは FakeAccountDeletionService を使う。
    // 呼ばれたらその場で失敗させる（結果を待つ作りだと、うっかり呼んだテストが失敗せずに止まるため。退会の手順の偽物
    // DeletionAuthRepository も、使わないメソッドは同じく error で失敗させている）
    override suspend fun reauthenticate(password: String): AppResult<Unit> = error("この偽物を使うテストでは再認証を使わない")

    override suspend fun deleteAuthAccount(): AppResult<Unit> = error("この偽物を使うテストでは認証のアカウントの削除を使わない")
}

/** 結果を外から渡すまで待つ、アカウント文書の作成の偽物。呼ばれた uid とメールアドレスを記録する。記録（分析）はしない。 */
class FakeAccountBootstrapper : AccountBootstrapper {
    val calls = mutableListOf<Pair<Uid, String?>>()
    var result = CompletableDeferred<AppResult<Unit>>()

    override suspend fun bootstrap(uid: Uid, email: String?): AppResult<Unit> {
        calls += uid to email
        return result.await()
    }
}

/** 有効な書き込みを決めて渡す WriteGate の偽物。 */
class FakeWriteGate(override val enabled: Set<WriteCapability>) : WriteGate

/** 分析の窓口の偽物。識別の設定・画面名・失敗の記録を順に残す。 */
class RecordingFeatureAnalytics : AnalyticsFacade {
    val userIds = mutableListOf<Uid?>()
    val screens = mutableListOf<ScreenName>()
    val errors = mutableListOf<Pair<AppError, String>>()
    override fun logEvent(name: EventName, params: Map<String, ParamValue>) = Unit
    override fun logScreen(name: ScreenName) {
        screens += name
    }
    override fun logError(error: AppError, context: String) {
        errors += error to context
    }
    override fun setUserId(uid: Uid?) {
        userIds += uid
    }
}
