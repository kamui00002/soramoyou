// ⭐️ Firestore への書き込みの唯一の入口の実装：可否 → 書き手 → 形の検証 → 実行 → 記録（タスク 6.2・要件 2.2・2.10）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.DocumentShapeValidator
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.contract.document.ShapeContract
import com.yoshidometoru.soramoyou.contract.document.Violation
import com.yoshidometoru.soramoyou.contract.document.WriteTarget
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import kotlin.coroutines.cancellation.CancellationException

/**
 * [FirestoreWriteGateway] の実装。どの書き込みも、次の順で進め、どこかで断ったら Firebase には到達しない。
 *
 * 1. 可否：[gate] で [WriteCapability] が無効なら `WriteBlocked`
 * 1'. 区間：[exclusively] の区間の中で、区間と別の種類の「作る・書き換える」書き込み（create・update・transaction）なら `PermissionDenied`
 *    （発生箇所は `FirestoreWriteGateway.<操作名>.during_<区間の種類の小文字>`。消す書き込みは通す。タスク 31.2 の確かめる係の指摘の直し）
 * 2. 書き手：[currentUid] が null（ログインしていない）なら `PermissionDenied`。
 *    形の検証で「`userId` が書き手の uid と一致すること」を見るのに要るため、検証より前に断る
 *    （設計書に定めが無い。Firestore も未認証の書き込みを権限の拒否で返すので、それに合わせた）
 * 3. 形の検証：[validator] が違反を返したら `ShapeViolation`（書き込み先は [WriteTarget]（ドキュメント ID と書き手の uid））
 * 4. 実行：[client] を呼ぶ。失敗は [FirestoreWriteFailure] の写しを返す。写せない例外は `Unknown`（例外の型名だけを載せる）
 * 5. 記録：1〜3（1' を含む）で断ったものだけを [AnalyticsFacade.logError] に渡す（発生箇所は `FirestoreWriteGateway.<操作名>`）。
 *    Crashlytics に送るかどうかは logError が分類で決める（タスク 4.2。ここでは CrashReporter を直接呼ばない）
 *
 * コルーチンの取り消し（CancellationException）は失敗に写さず、そのまま伝える。
 *
 * @param currentUid いまログインしているユーザーの uid（いなければ null）。書き込みのたびに呼ぶ。
 */
class DefaultFirestoreWriteGateway internal constructor(
    private val gate: WriteGate,
    private val validator: DocumentShapeValidator,
    private val client: FirestoreWriteClient,
    private val analytics: AnalyticsFacade,
    private val currentUid: () -> Uid?,
) : FirestoreWriteGateway {

    /** [exclusively] の区間の印（区間と別の種類の、作る・書き換える書き込みを断る）。 */
    private val exclusive = ExclusiveWrites()

    override suspend fun create(cap: WriteCapability, ref: DocRef, contract: ShapeContract, doc: FsDocument): AppResult<Unit> =
        guarded("create", cap) { uid ->
            requireShape(contract, doc, ref, uid)
            client.set(ref.path, doc)
        }

    override suspend fun update(cap: WriteCapability, ref: DocRef, contract: ShapeContract, fields: FsDocument): AppResult<Unit> =
        guarded("update", cap) { uid ->
            requireShape(contract, fields, ref, uid)
            client.update(ref.path, fields)
        }

    override suspend fun delete(cap: WriteCapability, ref: DocRef): AppResult<Unit> =
        guarded("delete", cap, removesOnly = true) { client.delete(ref.path) }

    override suspend fun batchDelete(cap: WriteCapability, refs: List<DocRef>): AppResult<Unit> =
        guarded("batchDelete", cap, removesOnly = true) {
            // 束ごとに別のコミット。途中の束が失敗したら例外で抜け、それより後の束は送らない
            for (chunk in refs.chunked(BATCH_LIMIT)) {
                client.deleteAll(chunk.map { it.path })
            }
        }

    override suspend fun <T> transaction(cap: WriteCapability, block: suspend TxScope.() -> T): AppResult<T> =
        guarded("transaction", cap) { uid ->
            client.runTransaction { ValidatingTxScope(this, uid).block() }
        }

    override suspend fun <T> exclusively(cap: WriteCapability, block: suspend () -> T): T = exclusive.run(cap, block)

    /**
     * 可否・区間・書き手を確かめてから [block] を実行し、結果を [AppResult] にする。断ったものはここで記録する。
     * [block] の中の形の違反は [ShapeViolationAbort] で抜けてくる（トランザクションでは SDK が包むことがあるので、原因の連鎖から探す）。
     *
     * @param removesOnly 消すだけの書き込み（delete・batchDelete）なら true。[exclusively] の区間でも断らない
     *   （トランザクションは中で作れるので false。消すだけでも断る）
     */
    private suspend fun <T> guarded(
        operation: String,
        cap: WriteCapability,
        removesOnly: Boolean = false,
        block: suspend (Uid) -> T,
    ): AppResult<T> {
        val context = "$CONTEXT_PREFIX.$operation"
        if (!gate.isEnabled(cap)) return refuse(AppError.WriteBlocked(cap), context)
        if (!removesOnly) {
            exclusive.refusing(cap)?.let { holder -> return refuse(AppError.PermissionDenied, "$context.during_${holder.name.lowercase()}") }
        }
        val uid = currentUid() ?: return refuse(AppError.PermissionDenied, context)
        return try {
            AppResult.Ok(block(uid))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val abort = e.causes().filterIsInstance<ShapeViolationAbort>().firstOrNull()
            when {
                abort != null -> refuse(AppError.ShapeViolation(abort.violations), context)
                e is FirestoreWriteFailure -> AppResult.Err(e.error)
                else -> AppResult.Err(AppError.Unknown(e.javaClass.simpleName))
            }
        }
    }

    /** 断ったことを記録して、その失敗を返す。 */
    private fun refuse(error: AppError, context: String): AppResult.Err {
        analytics.logError(error, context)
        return AppResult.Err(error)
    }

    /** [doc] が [contract] に合わなければ [ShapeViolationAbort] を投げる（書き込みの前に呼ぶ）。 */
    private fun requireShape(contract: ShapeContract, doc: FsDocument, ref: DocRef, uid: Uid) {
        val violations = validator.validate(contract, doc, WriteTarget(documentId = ref.documentId, authUid = uid))
        if (violations.isNotEmpty()) throw ShapeViolationAbort(violations)
    }

    /** トランザクションの中の書き込みにも、外と同じ形の検証を通す [TxScope]。 */
    private inner class ValidatingTxScope(private val tx: TxClient, private val uid: Uid) : TxScope {
        override suspend fun get(ref: DocRef): RawDocument? = tx.get(ref.path)

        override fun create(ref: DocRef, contract: ShapeContract, doc: FsDocument) {
            requireShape(contract, doc, ref, uid)
            tx.set(ref.path, doc)
        }

        override fun update(ref: DocRef, contract: ShapeContract, fields: FsDocument) {
            requireShape(contract, fields, ref, uid)
            tx.update(ref.path, fields)
        }

        override fun delete(ref: DocRef) = tx.delete(ref.path)
    }

    /** 形の違反で書き込みを取りやめるための例外。この入口の外へは出さない（[guarded] が ShapeViolation に変える）。 */
    private class ShapeViolationAbort(val violations: List<Violation>) : Exception()

    private companion object {
        /** Firestore の一括書き込み 1 回あたりの書き込みの上限。 */
        const val BATCH_LIMIT = 500

        /** 記録の発生箇所の前半（`クラス名.メソッド名` の形。設計書の部品名にそろえる）。 */
        const val CONTEXT_PREFIX = "FirestoreWriteGateway"

        /** この例外から始めて、原因（cause）を順にたどる。同じ例外が輪になっていても止まる。 */
        fun Throwable.causes(): Sequence<Throwable> {
            val seen = mutableSetOf<Throwable>()
            return generateSequence(this) { it.cause }.takeWhile { seen.add(it) }
        }
    }
}
