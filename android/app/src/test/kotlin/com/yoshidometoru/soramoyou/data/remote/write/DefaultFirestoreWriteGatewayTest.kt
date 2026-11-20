// ⭐️ Firestore への書き込みの唯一の入口の単体テスト（タスク 6.2・6.4・要件 2.2・2.10）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.AllowListShapeValidator
import com.yoshidometoru.soramoyou.contract.document.Basis
import com.yoshidometoru.soramoyou.contract.document.ContractId
import com.yoshidometoru.soramoyou.contract.document.FieldRule
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.contract.document.FsValue
import com.yoshidometoru.soramoyou.contract.document.ShapeContract
import com.yoshidometoru.soramoyou.contract.document.ValueConstraint
import com.yoshidometoru.soramoyou.contract.document.ValueKind
import com.yoshidometoru.soramoyou.contract.document.Violation
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import java.util.concurrent.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * 書き込みの入口が、可否 → 書き手 → 形の検証 → 実行 → 記録 の順で進み、どこかで断ったら Firebase（の継ぎ目の偽物）に
 * 到達しないことを確かめる（設計書「M1の書き込みゼロ保証」3・5、:1128）。
 * 形の検証は本物（:contract の AllowListShapeValidator）を使い、テスト用の小さな契約を当てる。
 */
class DefaultFirestoreWriteGatewayTest {

    private val writer = Uid("writer-uid")
    private val postRef = DocRef.post(PostId("POST-1"))

    /** id はドキュメント ID と、userId は書き手の uid と一致しなければならない。count は任意。それ以外のキーは違反。 */
    private val contract = ShapeContract(
        id = ContractId.POST_CREATE,
        fields = listOf(
            FieldRule("id", setOf(ValueKind.STR), required = true, basis = Basis.RULES_HAS_ALL, constraint = ValueConstraint.EqualsDocumentId),
            FieldRule("userId", setOf(ValueKind.STR), required = true, basis = Basis.RULES_HAS_ALL, constraint = ValueConstraint.EqualsAuthUid),
            FieldRule("count", setOf(ValueKind.INT64), required = false, basis = Basis.OPTIONAL),
        ),
    )
    /** 部分更新用：count だけを書ける（必須のキーは無い）。 */
    private val countUpdate = ShapeContract(
        id = ContractId.POST_LIKE_COUNTER,
        fields = listOf(FieldRule("count", setOf(ValueKind.INT64), required = false, basis = Basis.COUNT_ONLY_UPDATE)),
    )
    private val validDoc: FsDocument = mapOf("id" to FsValue.Str("POST-1"), "userId" to FsValue.Str("writer-uid"))

    private val client = FakeFirestoreWriteClient(
        documents = mapOf("posts/POST-1" to RawDocument("POST-1", mapOf("count" to 3L))),
    )
    private val analytics = RecordingAnalytics()

    private fun gateway(
        enabled: Set<WriteCapability> = setOf(WriteCapability.POST_CREATE),
        uid: Uid? = writer,
    ) = DefaultFirestoreWriteGateway(FixedWriteGate(enabled), AllowListShapeValidator, client, analytics) { uid }

    // ── 陽性対照：有効なときは、偽物が呼ばれる（この偽物で「呼ばれない」を確かめることに意味があることを先に示す）──

    @Test
    fun `有効なら、createは偽物のsetをパスと文書そのままで呼び、成功を返す`() = runBlocking {
        val result = gateway().create(WriteCapability.POST_CREATE, postRef, contract, validDoc)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf(FakeFirestoreWriteClient.Call("set", listOf("posts/POST-1"), validDoc)), client.calls)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `有効なら、update・delete・transactionも偽物に到達する`() = runBlocking {
        val gateway = gateway()
        val fields: FsDocument = mapOf("count" to FsValue.Int64(4))

        assertEquals(AppResult.Ok(Unit), gateway.update(WriteCapability.POST_CREATE, postRef, countUpdate, fields))
        assertEquals(AppResult.Ok(Unit), gateway.delete(WriteCapability.POST_CREATE, postRef))
        val read = gateway.transaction(WriteCapability.POST_CREATE) {
            val current = get(postRef)
            update(postRef, countUpdate, fields)
            current
        }

        assertEquals(AppResult.Ok(RawDocument("POST-1", mapOf("count" to 3L))), read)
        assertEquals(
            listOf("update", "delete", "runTransaction", "tx.get", "tx.update"),
            client.calls.map { it.operation },
        )
    }

    // ── 可否が無効なら、どの書き込みも偽物に到達せず WriteBlocked を返して記録する（M1 の保証）──

    @Test
    fun `可否が無効なら、全ての書き込みがWriteBlockedを返し、偽物は一度も呼ばれない`() = runBlocking {
        val gateway = gateway(enabled = emptySet())
        val cap = WriteCapability.POST_CREATE
        val blocked = AppResult.Err(AppError.WriteBlocked(cap))
        var blockRan = false

        assertEquals(blocked, gateway.create(cap, postRef, contract, validDoc))
        assertEquals(blocked, gateway.update(cap, postRef, contract, validDoc))
        assertEquals(blocked, gateway.delete(cap, postRef))
        assertEquals(blocked, gateway.batchDelete(cap, listOf(postRef)))
        assertEquals(blocked, gateway.transaction(cap) { blockRan = true })

        assertEquals(emptyList(), client.calls, "可否が無効なのに偽物に到達した")
        assertEquals(false, blockRan, "可否が無効なのにトランザクションの中身を実行した")
        assertEquals(
            listOf("create", "update", "delete", "batchDelete", "transaction").map {
                RecordingAnalytics.LoggedError(AppError.WriteBlocked(cap), "FirestoreWriteGateway.$it")
            },
            analytics.errors,
        )
    }

    @Test
    fun `可否は書き込みごとの種類で判定する（別の種類が有効でも通さない）`() = runBlocking {
        val result = gateway(enabled = setOf(WriteCapability.LIKE)).create(WriteCapability.POST_CREATE, postRef, contract, validDoc)

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.POST_CREATE)), result)
        assertEquals(emptyList(), client.calls)
    }

    @Test
    fun `可否の判定は書き手と形の検証より先に行う（無効なら、ログインしていなくても形に違反していてもWriteBlocked）`() = runBlocking {
        // 上の「全ての書き込みが WriteBlocked」はログイン中・形に合う文書で確かめているので、判定の順を入れ替えても通ってしまう。
        // ここでは書き手も形も断る理由がある状態で、可否の遮断だけが返り、記録されることを確かめる
        val gateway = gateway(enabled = emptySet(), uid = null)
        val cap = WriteCapability.POST_CREATE
        val blocked = AppResult.Err(AppError.WriteBlocked(cap))
        val badDoc = validDoc + mapOf("fcmToken" to FsValue.Str("t"))

        assertEquals(blocked, gateway.create(cap, postRef, contract, badDoc))
        assertEquals(blocked, gateway.update(cap, postRef, countUpdate, badDoc))
        assertEquals(blocked, gateway.transaction(cap) { create(postRef, contract, badDoc) })

        assertEquals(emptyList(), client.calls)
        assertEquals(
            listOf("create", "update", "transaction").map {
                RecordingAnalytics.LoggedError(AppError.WriteBlocked(cap), "FirestoreWriteGateway.$it")
            },
            analytics.errors,
            "書き手や形の検証で断った記録が混ざった",
        )
    }

    // ── 書き手（ログインしていない）──

    @Test
    fun `ログインしていなければ、形の検証の前にPermissionDeniedで断り、記録する`() = runBlocking {
        val result = gateway(uid = null).create(WriteCapability.POST_CREATE, postRef, contract, validDoc)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(emptyList(), client.calls)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "FirestoreWriteGateway.create")), analytics.errors)
    }

    // ── 形の検証（fail-closed）──

    @Test
    fun `形に違反した文書は書かずにShapeViolationを返し、違反の中身ごと記録する`() = runBlocking {
        // 契約に無いキー（fcmToken）・書き手と違う userId
        val doc = validDoc + mapOf("userId" to FsValue.Str("someone-else"), "fcmToken" to FsValue.Str("t"))

        val result = gateway().create(WriteCapability.POST_CREATE, postRef, contract, doc)

        val expected = AppError.ShapeViolation(
            listOf(
                Violation.OutOfRange("userId", "value does not match the authenticated uid"),
                Violation.UnexpectedKey("fcmToken"),
            ),
        )
        assertEquals(AppResult.Err(expected), result)
        assertEquals(emptyList(), client.calls, "形に違反したのに書き込んだ")
        assertEquals(listOf(RecordingAnalytics.LoggedError(expected, "FirestoreWriteGateway.create")), analytics.errors)
    }

    @Test
    fun `形の検証は書き込み先のドキュメントIDで行う`() = runBlocking {
        // 文書の id は POST-1 だが、書き込み先は POST-2
        val result = gateway().create(WriteCapability.POST_CREATE, DocRef.post(PostId("POST-2")), contract, validDoc)

        assertEquals(
            AppResult.Err(AppError.ShapeViolation(listOf(Violation.OutOfRange("id", "value does not match the document id")))),
            result,
        )
        assertEquals(emptyList(), client.calls)
    }

    @Test
    fun `updateも形の検証を通す`() = runBlocking {
        val result = gateway().update(WriteCapability.POST_CREATE, postRef, countUpdate, mapOf("count" to FsValue.Str("4")))

        assertEquals(AppResult.Err(AppError.ShapeViolation(listOf(Violation.WrongKind("count", ValueKind.STR)))), result)
        assertEquals(emptyList(), client.calls)
    }

    @Test
    fun `トランザクションの中の書き込みが形に違反したら、その書き込みをせずに全体をShapeViolationで取りやめる`() = runBlocking {
        val result = gateway().transaction(WriteCapability.POST_CREATE) {
            get(postRef)
            create(postRef, contract, mapOf("id" to FsValue.Str("POST-1")))
            delete(postRef)
        }

        val expected = AppError.ShapeViolation(listOf(Violation.MissingKey("userId")))
        assertEquals(AppResult.Err(expected), result)
        // 違反した create とそれより後の delete は、偽物に届いていない
        assertEquals(listOf("runTransaction", "tx.get"), client.calls.map { it.operation })
        assertEquals(listOf(RecordingAnalytics.LoggedError(expected, "FirestoreWriteGateway.transaction")), analytics.errors)
    }

    @Test
    fun `トランザクションの中のupdateが形に違反したら、それより前の書き込みごとコミットさせない`() = runBlocking {
        val gateway = gateway()
        val good: FsDocument = mapOf("count" to FsValue.Int64(4))
        val bad: FsDocument = mapOf("count" to FsValue.Str("5"))

        // 偽物の陽性対照：形に合う書き込みだけのトランザクションは、コミットされたと記録される
        assertEquals(AppResult.Ok(Unit), gateway.transaction(WriteCapability.POST_CREATE) { update(postRef, countUpdate, good) })

        val result = gateway.transaction(WriteCapability.POST_CREATE) {
            get(postRef)
            update(postRef, countUpdate, good)
            update(postRef, countUpdate, bad)
        }

        assertEquals(AppResult.Err(AppError.ShapeViolation(listOf(Violation.WrongKind("count", ValueKind.STR)))), result)
        // 違反した update は偽物に届いていない（届いたのは形に合う方だけ）
        assertEquals(
            listOf("runTransaction", "tx.update", "runTransaction", "tx.get", "tx.update"),
            client.calls.map { it.operation },
        )
        assertEquals(good, client.calls.last().data)
        // 形の違反は例外のまま runTransaction の外へ抜ける。SDK はそれでトランザクションを取りやめ、前の update も反映しない
        assertEquals(
            listOf(FakeFirestoreWriteClient.TxOutcome.COMMITTED, FakeFirestoreWriteClient.TxOutcome.ABORTED),
            client.transactionOutcomes,
            "形に違反したトランザクションがコミットされた",
        )
    }

    // ── 実行の失敗 ──

    @Test
    fun `Firestoreの失敗は写した種類のまま返し、入口では記録しない（呼び出し側が記録する）`() = runBlocking {
        client.failOn = "set"
        client.failure = FirestoreWriteFailure(AppError.PermissionDenied, IllegalStateException("権限"))

        val result = gateway().create(WriteCapability.POST_CREATE, postRef, contract, validDoc)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `写せない例外はUnknownにし、例外の型名だけを載せる`() = runBlocking {
        client.failOn = "delete"
        client.failure = IllegalArgumentException("users/秘密の値 を含む文言")

        val result = gateway().delete(WriteCapability.POST_CREATE, postRef)

        assertEquals(AppResult.Err(AppError.Unknown("IllegalArgumentException")), result)
    }

    @Test
    fun `コルーチンの取り消しは失敗に写さず、そのまま伝える`() {
        client.failOn = "set"
        client.failure = CancellationException("取り消し")

        assertFailsWith<CancellationException> {
            runBlocking { gateway().create(WriteCapability.POST_CREATE, postRef, contract, validDoc) }
        }
    }

    // ── 一括削除 ──

    @Test
    fun `batchDeleteは500件ずつに分けて送る`() = runBlocking {
        val refs = (1..1001).map { DocRef.post(PostId("P$it")) }

        assertEquals(AppResult.Ok(Unit), gateway().batchDelete(WriteCapability.POST_CREATE, refs))

        assertEquals(listOf(500, 500, 1), client.calls.map { it.paths.size })
        assertEquals(refs.map { it.path }, client.calls.flatMap { it.paths }, "全ての文書を、渡された順に 1 回ずつ送る")
    }

    @Test
    fun `batchDeleteは途中の束が失敗したら、それより後の束を送らずに失敗を返す`() = runBlocking {
        client.failOn = "deleteAll"
        client.failAfter = 1
        client.failure = FirestoreWriteFailure(AppError.Network, IllegalStateException("通信"))
        val refs = (1..1200).map { DocRef.post(PostId("P$it")) }

        val result = gateway().batchDelete(WriteCapability.POST_CREATE, refs)

        assertEquals(AppResult.Err(AppError.Network), result)
        // 失敗させた呼び出しも数える（calls は成功した 1 つ目しか持たないので、後の束を送り続けても増えない）
        assertEquals(listOf(500, 500), client.attempts.map { it.paths.size }, "失敗した 2 つ目より後の束を送った")
    }

    @Test
    fun `batchDeleteは0件なら何も送らずに成功する`() = runBlocking {
        assertEquals(AppResult.Ok(Unit), gateway().batchDelete(WriteCapability.POST_CREATE, emptyList()))
        assertTrue(client.calls.isEmpty())
    }
}
