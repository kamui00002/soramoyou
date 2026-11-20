// ⭐️ アカウントの作成直後に、アカウント文書（users・publicProfiles）を作る（タスク 14.2・要件 2.3・2.4・2.10・2.11・3.1〜3.4）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.DocumentBuilders
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.contract.document.ShapeContract
import com.yoshidometoru.soramoyou.contract.document.ShapeContracts
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import java.time.Clock
import java.time.Instant

/**
 * Firebase Authentication でアカウントを作った直後に、そのアカウントの文書（`users/{uid}`・`publicProfiles/{uid}`）を作る
 * （設計書の部品 AccountBootstrapper。:749）。認証のアカウントを作る部分は [AuthRepository] の担当で、この部品はそれを呼ばない
 * （呼び出す順序を決めるのは ViewModel。設計書 :317-340）。
 */
interface AccountBootstrapper {

    /**
     * [uid] のアカウント文書を、`users`、`publicProfiles` の順に作る。それぞれ「無ければ作る」トランザクションなので、
     * 同じ [uid] で何度呼んでも既にある文書は上書きしない（再試行してよい）。
     *
     * - [email] があれば `users.email` に書く。`null`（匿名など）なら `email` のキー自体を書かない（要件 3.3）
     * - `fcmToken`・`fcmTokenUpdatedAt` には触れない（要件 2.10。契約に無いので書けない）
     * - `users` の作成に失敗したら `publicProfiles` には進まない（要件 3.4「`users` を作れたとき」）
     *
     * 失敗は [AppResult.Err] で返す。例外は投げない（コルーチンの取り消しを除く）。ここはセッションに触れないので、失敗してもログイン状態は維持される
     * （要件 2.11）。失敗の**表示**は呼び出し側の画面（タスク 14.4）、後からの回復は [AccountDocumentRepairer]（要件 3.7）の担当。
     *
     * 失敗の**記録**はこの部品が行う（書き込みの入口の取り決め：FirestoreWriteGateway の KDoc「写して返した Firebase の失敗は、
     * 呼び出し側が自分の発生箇所で記録する」）。発生箇所は `AccountBootstrapper.bootstrap.users`・`AccountBootstrapper.bootstrap.publicProfiles`。
     * 入口が自分で断ったもの（可否の無効 `WriteBlocked`・形の違反 `ShapeViolation`）は入口が記録済みなので、ここでは記録しない
     * （監視する件数が二重になる）。呼び出し側は、返った失敗を表示するだけで、記録し直さない。
     *
     * @throws IllegalArgumentException [uid] がドキュメント ID に使えない（空か `/` を含む）とき。Firebase Authentication の uid では起きない。
     */
    suspend fun bootstrap(uid: Uid, email: String?): AppResult<Unit>
}

/**
 * [AccountBootstrapper] の実装。書き込みは必ず [gateway] を通し、可否は [WriteCapability.ACCOUNT_CREATE] で判定される。
 *
 * iOS の新規登録は、`users` を `setData(merge: true)`、`publicProfiles` を丸ごと上書きの `setData` で書く
 * （AuthViewModel.swift:99-105・FirestoreService.swift:594-605・:1510-1518）。Android は、既に有れば書かない方式にそろえる
 * （iOS の `createPublicProfileIfMissing`：FirestoreService.swift:1489-1506 と同じトランザクションの形。`users` にも同じ形を使う）。
 *
 * `publicProfiles` は新規のアカウントなので、`users` から値を写さずに新規の形（任意項目なし・カウンタは 0）で作る。
 * `users` から写すのは、後から補う [AccountDocumentRepairer] の役目。
 *
 * @param clock 端末の時刻（設計書 QC：`createdAt`・`updatedAt` は端末の時刻）。1 回の [bootstrap] で 1 度だけ読み、2 つの文書で同じ値を使う。
 */
class DefaultAccountBootstrapper(
    private val gateway: FirestoreWriteGateway,
    private val analytics: AnalyticsFacade,
    private val clock: Clock = Clock.systemUTC(),
) : AccountBootstrapper {

    override suspend fun bootstrap(uid: Uid, email: String?): AppResult<Unit> {
        val now = Instant.now(clock)
        val users = createIfMissing(
            stage = "users",
            ref = DocRef.user(uid),
            contract = ShapeContracts.USER_CREATE,
            doc = DocumentBuilders.userCreate(uid, email, now),
        )
        // users を作れなかったら、publicProfiles には進まない（要件 3.4）
        if (users is AppResult.Err) return users
        return createIfMissing(
            stage = "publicProfiles",
            ref = DocRef.publicProfile(uid),
            contract = ShapeContracts.PUBLIC_PROFILE_CREATE,
            doc = DocumentBuilders.publicProfileCreate(uid, source = null, now = now),
        )
    }

    /**
     * [ref] を、無いときだけ [doc] で作る（1 つのトランザクションで、読む→無ければ書く）。失敗は記録して返す。
     * トランザクションの中身は、SDK にやり直されても同じ結果になる（外の変数を書き換えない）。
     */
    private suspend fun createIfMissing(stage: String, ref: DocRef, contract: ShapeContract, doc: FsDocument): AppResult<Unit> {
        val result = gateway.transaction(WriteCapability.ACCOUNT_CREATE) {
            if (get(ref) == null) create(ref, contract, doc)
            Unit
        }
        if (result is AppResult.Err) analytics.recordForwardedWriteFailure(result.error, "$ERROR_CONTEXT.$stage")
        return result
    }

    private companion object {
        /** 記録の発生箇所の前半（`クラス名.メソッド名`。段階を後ろに足す）。 */
        const val ERROR_CONTEXT = "AccountBootstrapper.bootstrap"
    }
}
