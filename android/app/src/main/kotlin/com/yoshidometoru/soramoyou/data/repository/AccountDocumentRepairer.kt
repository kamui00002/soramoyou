// ⭐️ 欠けているアカウント文書を、後から補う（タスク 14.3・要件 2.2・2.11・3.7）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.DocumentBuilders
import com.yoshidometoru.soramoyou.contract.document.ShapeContracts
import com.yoshidometoru.soramoyou.contract.document.UserProfileFields
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import java.time.Clock
import java.time.Instant
import kotlin.coroutines.cancellation.CancellationException

/** 補完の結果（設計書 :743）。何も作らなかった場合も含めて、4 通りのどれかになる。 */
enum class RepairOutcome {
    /** `users`・`publicProfiles` の両方が既にあった（何も書いていない）。 */
    ALREADY_PRESENT,

    /** `users` だけが無かったので作った。 */
    CREATED_USER,

    /** `publicProfiles` だけが無かったので作った（`users` の値を写した）。 */
    CREATED_PUBLIC_PROFILE,

    /** どちらも無かったので両方作った。 */
    CREATED_BOTH,
}

/**
 * 自分のアカウント文書（`users/{uid}`・`publicProfiles/{uid}`）のうち、欠けているものを後から補う
 * （設計書の部品 AccountDocumentRepairer。:750・:752）。アカウントの作成直後に失敗した文書の回復（要件 2.11）と、
 * 公開プロフィールが無い旧アカウントの補完（要件 3.7）を受け持つ。
 *
 * **ログインの処理とは独立に**呼ぶ（要件 2.2。[AuthRepository] は書き込みの入口に依存せず、ログインの中からこれを呼ばない）。
 * 呼ぶのは、自分のプロフィール画面を表示したとき（`ProfileViewModel`）と、プロフィールの保存で `publicProfiles` が無いと分かったとき
 * （[ProfileEditor]。補ってから更新を 1 回だけやり直す）の 2 か所だけ。それ以外の書き込みの前には呼ばない（`users` が無い間のブロックなどは
 * NotFound で失敗し、プロフィールを開くと直る。設計書の AccountDocumentRepairer の節・2026-11-05 全体レビュー R15・ユーザー判断）。
 */
interface AccountDocumentRepairer {

    /**
     * ログイン中のユーザーのアカウント文書を調べ、**欠けているものだけ**を「無ければ作る」方法で作る。既にある文書は書き換えない
     * （要件 3.7）。何度呼んでも、2 回目以降は何も書かない。
     *
     * - `users` と `publicProfiles` を 1 つのトランザクションで読み、そこで欠けていたものだけを同じトランザクションで作る。
     *   読んだ時点と作る時点の間に別の端末が作った文書を、上書きしない。`publicProfiles` に写す `users` の値も同じトランザクションの中で読む
     *   （読み取りの入口で先に読むと、写す値と「無ければ作る」の判定が別の時点のものになる）
     * - `publicProfiles` を補うときは、`users` の表示名・アイコン・自己紹介・カウンタを写す（iOS の `PublicProfile(from: user)`：
     *   PublicProfile.swift:61-75。iOS は補完の前に `users` を読む：RecommendationManager.swift:246-257）。`users` も無ければ新規の形
     * - `users` を作るときの `email` は、ログイン中の認証の状態から取る。`fcmToken`・`fcmTokenUpdatedAt` には触れない（要件 2.10）
     * - 可否は [WriteCapability.ACCOUNT_REPAIR]。無効なビルド（M1）では、Firebase に届かずに `WriteBlocked` を返す
     * - 両方とも無いときだけ、作る前に認証のアカウントがサーバーに残っているかを確かめる。確かめられなければ、どちらも作らず
     *   `PermissionDenied` を返す（下の [DefaultAccountDocumentRepairer] の `verifyAccount`。レビュー R10）
     *
     * 成功したら、結果（[RepairOutcome]）を返し、記録の口へ渡す（下の [DefaultAccountDocumentRepairer]）。
     * 失敗は [AppResult.Err] で返す。例外は投げない（コルーチンの取り消しを除く）。ログインしていなければ `PermissionDenied`。
     *
     * 失敗の**記録**はこの部品が行う（発生箇所は `AccountDocumentRepairer.ensureAccountDocuments`）。[AccountBootstrapper] と同じ取り決めで、
     * 入口が断った `WriteBlocked`・`ShapeViolation` は入口が記録済みなので記録しない。呼び出し側は表示するだけで、記録し直さない。
     */
    suspend fun ensureAccountDocuments(): AppResult<RepairOutcome>
}

/**
 * [AccountDocumentRepairer] の実装。書き込みは必ず [gateway] を通す。
 *
 * @param currentUser ログイン中のユーザー（いなければ null）。uid と、`users` を作るときの `email` を得る。呼ぶたびに読む。
 * @param clock 端末の時刻（設計書 QC）。1 回の補完で 1 度だけ読み、作る文書の `createdAt`・`updatedAt` に使う。
 * @param recordOutcome 成功した補完の結果の記録先（既定は何もしない）。分析のイベントの名前は iOS 版にあるものだけに閉じている
 *   （要件 15.2。タスク 4.1 の `EventName`）ので、結果のために新しいイベントは足さない。AppContainer が Logcat に出す。
 *   トランザクションが成功した後に、1 回だけ呼ぶ（トランザクションの中身は SDK にやり直されることがあるため、中では呼ばない）。
 * @param verifyAccount 認証のアカウントがサーバーにまだ残っているかを確かめる（残っていれば true。既定は確かめずに true）。
 *   `users`・`publicProfiles` が**両方とも無い**ときだけ、トランザクションの中で 2 つを読んだ後・作る前に呼ぶ（片方だけ無いときは呼ばない）。
 *   false なら何も作らず、ログインしていないときと同じ `PermissionDenied` を返して記録する。AppContainer が認証の SDK の `reload()` を渡す。
 *   トランザクションの中で呼ぶので、SDK がトランザクションをやり直したときは、もう一度呼ばれる（レビュー R10）。
 */
class DefaultAccountDocumentRepairer(
    private val gateway: FirestoreWriteGateway,
    private val analytics: AnalyticsFacade,
    private val currentUser: () -> SessionState.SignedIn?,
    private val clock: Clock = Clock.systemUTC(),
    private val recordOutcome: (RepairOutcome) -> Unit = {},
    private val verifyAccount: suspend () -> Boolean = { true },
) : AccountDocumentRepairer {

    override suspend fun ensureAccountDocuments(): AppResult<RepairOutcome> {
        // ログインしていなければ、補う相手がいない。呼び出しの誤りなので、入口の「未ログイン」の断りと同じ扱いで記録して返す
        val account = currentUser() ?: return refuseNotSignedIn()
        val uid = account.uid
        val userRef = DocRef.user(uid)
        val profileRef = DocRef.publicProfile(uid)
        val now = Instant.now(clock)

        val result = gateway.transaction(WriteCapability.ACCOUNT_REPAIR) {
            // 読み取りは、全ての書き込みより前に 2 つとも行う（トランザクションの規則）
            val userDoc = get(userRef)
            val profileDoc = get(profileRef)
            // 両方とも無いときだけ、作る前に認証のアカウントがサーバーに残っているかを確かめる（レビュー R10）。
            // 確かめられなければ、何も作らずに抜ける（null。外で PermissionDenied にする）
            if (userDoc == null && profileDoc == null && !verifyAccount()) return@transaction null
            if (userDoc == null) {
                create(userRef, ShapeContracts.USER_CREATE, DocumentBuilders.userCreate(uid, account.email, now))
            }
            if (profileDoc == null) {
                // users があればその値を写す。users も無いときは、いま作る users と同じ新規の形（任意項目なし・カウンタは 0）
                val source = userDoc?.let { profileFieldsOf(it) }
                create(profileRef, ShapeContracts.PUBLIC_PROFILE_CREATE, DocumentBuilders.publicProfileCreate(uid, source, now))
            }
            outcomeOf(userMissing = userDoc == null, profileMissing = profileDoc == null)
        }

        val outcome = when (result) {
            // null は確かめが通らなかった（何も作っていない）。サーバーで消えたアカウントは、ログインしていないのと同じ扱いで記録して返す
            is AppResult.Ok -> result.value ?: return refuseNotSignedIn()
            is AppResult.Err -> {
                analytics.recordForwardedWriteFailure(result.error, ERROR_CONTEXT)
                return result
            }
        }
        recordOutcome(outcome)
        return AppResult.Ok(outcome)
    }

    private fun refuseNotSignedIn(): AppResult.Err {
        analytics.logError(AppError.PermissionDenied, ERROR_CONTEXT)
        return AppResult.Err(AppError.PermissionDenied)
    }

    private fun outcomeOf(userMissing: Boolean, profileMissing: Boolean): RepairOutcome = when {
        userMissing && profileMissing -> RepairOutcome.CREATED_BOTH
        userMissing -> RepairOutcome.CREATED_USER
        profileMissing -> RepairOutcome.CREATED_PUBLIC_PROFILE
        else -> RepairOutcome.ALREADY_PRESENT
    }

    /**
     * `users` のドキュメントから、公開プロフィールへ写す値を取り出す（項目名は iOS の `User.toFirestoreData` と同じ綴り）。
     * 型の違う値は、無いものとして扱う（表示名・アイコン・自己紹介は null、カウンタは 0）。
     * カウンタは、負の値を 0 に直し、小数で保存された値は整数にする。公開プロフィールの契約はカウンタを 0 以上の整数に限るので、
     * 壊れた値をそのまま写すと、補完が契約の違反で止まり続ける（`users` の値は他の端末が書いたもので、ここでは直せない）。
     */
    private fun profileFieldsOf(userDoc: RawDocument): UserProfileFields = UserProfileFields(
        displayName = userDoc.data["displayName"] as? String,
        photoUrl = userDoc.data["photoURL"] as? String,
        bio = userDoc.data["bio"] as? String,
        followersCount = counterOf(userDoc.data["followersCount"]),
        followingCount = counterOf(userDoc.data["followingCount"]),
        postsCount = counterOf(userDoc.data["postsCount"]),
    )

    private fun counterOf(value: Any?): Long = (value as? Number)?.toLong()?.coerceAtLeast(0L) ?: 0L

    private companion object {
        /** 記録の発生箇所（`クラス名.メソッド名`）。 */
        const val ERROR_CONTEXT = "AccountDocumentRepairer.ensureAccountDocuments"
    }
}

/**
 * 認証のアカウントがサーバーにまだ残っているかを確かめる（[DefaultAccountDocumentRepairer] の `verifyAccount` の中身。レビュー R10）。
 * AppContainer が、認証の SDK の `currentUser` を [user] に、その `reload()` を待つ処理を [reload] に渡す。
 *
 * - [user] が null（ログインしていない）なら、[reload] を呼ばずに false
 * - [reload] が戻れば（サーバーにアカウントの記録がある）true
 * - [reload] が例外で失敗すれば（消されたアカウント・通信の失敗など）false。全て「通らない」に倒す
 * - コルーチンの取り消しだけは、そのまま伝える
 *
 * SDK を呼ばない形にして、この判断だけを JVM の単体テストで確かめる（全体レビュー 4 回目 Q14。前はこの判断が AppContainer のラムダの中にあり、
 * 本物の FirebaseAuth を作れない単体テストではソースの文字列しか見られなかった）。
 */
internal suspend fun <U : Any> accountExistsOnServer(user: U?, reload: suspend (U) -> Unit): Boolean {
    if (user == null) return false
    return try {
        reload(user)
        true
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        false
    }
}
