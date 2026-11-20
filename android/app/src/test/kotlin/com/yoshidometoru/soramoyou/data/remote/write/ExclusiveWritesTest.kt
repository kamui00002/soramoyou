// ⭐️ 書き込みの入口の「1 種類だけを通す区間」の単体テスト（タスク 31.2 の確かめる係の指摘の直し・要件 12.3）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.AllowListShapeValidator
import com.yoshidometoru.soramoyou.contract.document.Basis
import com.yoshidometoru.soramoyou.contract.document.ContractId
import com.yoshidometoru.soramoyou.contract.document.FieldRule
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.contract.document.FsValue
import com.yoshidometoru.soramoyou.contract.document.ShapeContract
import com.yoshidometoru.soramoyou.contract.document.ValueKind
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlinx.coroutines.runBlocking

/**
 * 退会（ACCOUNT_DELETE）が消している間に、他の画面の書き込みが消したばかりの文書や画像を作り直さないための、入口の区間
 * （[FirestoreWriteGateway.exclusively]・[StorageGateway.exclusively]・[ExclusiveWrites]）を確かめる。
 * 入口は本物で、Firebase の継ぎ目だけを偽物（[FakeFirestoreWriteClient]・[FakeStorageWriteClient]）にする。
 * 退会の手順の中で使ったときの確かめ（補完が作り直さないこと）は DefaultAccountDeletionServiceTest にある。
 */
class ExclusiveWritesTest {

    private val writer = Uid("writer-uid")
    private val postRef = DocRef.post(PostId("POST-1"))

    /** 部分更新用：count だけを書ける。 */
    private val countUpdate = ShapeContract(
        id = ContractId.POST_LIKE_COUNTER,
        fields = listOf(FieldRule("count", setOf(ValueKind.INT64), required = false, basis = Basis.COUNT_ONLY_UPDATE)),
    )
    private val count: FsDocument = mapOf("count" to FsValue.Int64(4))

    private val firestoreClient = FakeFirestoreWriteClient()
    private val storageClient = FakeStorageWriteClient()
    private val analytics = RecordingAnalytics()

    private fun firestore(enabled: Set<WriteCapability> = WriteCapability.entries.toSet()) =
        DefaultFirestoreWriteGateway(FixedWriteGate(enabled), AllowListShapeValidator, firestoreClient, analytics) { writer }

    private fun storage() = DefaultStorageGateway(FixedWriteGate(WriteCapability.entries.toSet()), storageClient, analytics) {}

    private val path = StoragePath("posts/writer-uid/public/IMG-1.jpg")

    // ── Firestore ──

    @Test
    fun `区間の中では、別の種類の作る・書き換える書き込みをFirebaseに届けずにPermissionDeniedで断り、区間の種類つきで記録する`() = runBlocking {
        val gateway = firestore()
        var blockRan = false

        val results = gateway.exclusively(WriteCapability.ACCOUNT_DELETE) {
            listOf(
                gateway.update(WriteCapability.PROFILE_EDIT, postRef, countUpdate, count),
                gateway.transaction(WriteCapability.ACCOUNT_REPAIR) { blockRan = true },
                gateway.create(WriteCapability.POST_CREATE, postRef, countUpdate, count),
            )
        }

        assertEquals(List(3) { AppResult.Err(AppError.PermissionDenied) }, results)
        assertEquals(emptyList(), firestoreClient.calls, "断ったのに偽物に届いた")
        assertEquals(false, blockRan, "断ったのにトランザクションの中身を実行した")
        assertEquals(
            listOf("update", "transaction", "create").map {
                RecordingAnalytics.LoggedError(AppError.PermissionDenied, "FirestoreWriteGateway.$it.during_account_delete")
            },
            analytics.errors,
        )
    }

    @Test
    fun `区間の中でも、区間の種類の書き込みと、別の種類の消す書き込みは通す`() = runBlocking {
        val gateway = firestore()

        val results = gateway.exclusively(WriteCapability.ACCOUNT_DELETE) {
            listOf(
                gateway.update(WriteCapability.ACCOUNT_DELETE, postRef, countUpdate, count),
                gateway.transaction(WriteCapability.ACCOUNT_DELETE) { delete(postRef) },
                // 投稿の後片付けや自分の投稿の削除のような、別の種類の削除（消すだけなので何も残らない）
                gateway.delete(WriteCapability.POST_CREATE, postRef),
                gateway.batchDelete(WriteCapability.POST_DELETE, listOf(postRef)),
            )
        }

        assertEquals(List(4) { AppResult.Ok(Unit) }, results)
        assertEquals(listOf("update", "runTransaction", "tx.delete", "delete", "deleteAll"), firestoreClient.calls.map { it.operation })
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `区間を出たら（例外で抜けても）、別の種類の書き込みがまた通る`() = runBlocking {
        val gateway = firestore()
        gateway.exclusively(WriteCapability.ACCOUNT_DELETE) { }
        assertFailsWith<IllegalStateException> {
            gateway.exclusively(WriteCapability.ACCOUNT_DELETE) { throw IllegalStateException("区間の中の失敗") }
        }

        val result = gateway.update(WriteCapability.PROFILE_EDIT, postRef, countUpdate, count)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf("update"), firestoreClient.calls.map { it.operation })
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `可否の判定は区間より先（無効な書き込みは区間の中でもWriteBlocked）`() = runBlocking {
        val gateway = firestore(enabled = setOf(WriteCapability.ACCOUNT_DELETE))

        val result = gateway.exclusively(WriteCapability.ACCOUNT_DELETE) {
            gateway.update(WriteCapability.PROFILE_EDIT, postRef, countUpdate, count)
        }

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.PROFILE_EDIT)), result)
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.WriteBlocked(WriteCapability.PROFILE_EDIT), "FirestoreWriteGateway.update")),
            analytics.errors,
        )
    }

    // ── Storage ──

    @Test
    fun `Storageの区間の中では、別の種類のアップロードを届けずに断って記録し、削除と区間の種類は通す`() = runBlocking {
        val gateway = storage()

        val upload = gateway.exclusively(WriteCapability.ACCOUNT_DELETE) {
            listOf(
                gateway.uploadJpeg(WriteCapability.POST_CREATE, path, ByteArray(16), index = 0),
                gateway.uploadJpeg(WriteCapability.PROFILE_EDIT, path, ByteArray(16), index = 0),
            )
        }
        val deletes = gateway.exclusively(WriteCapability.ACCOUNT_DELETE) {
            listOf(gateway.delete(WriteCapability.POST_CREATE, path), gateway.delete(WriteCapability.ACCOUNT_DELETE, path))
        }

        assertEquals(List(2) { AppResult.Err(AppError.PermissionDenied) }, upload)
        assertEquals(List(2) { AppResult.Ok(Unit) }, deletes)
        assertEquals(listOf("delete", "delete"), storageClient.calls.map { it.operation }, "断ったアップロードが偽物に届いた")
        assertEquals(
            List(2) { RecordingAnalytics.LoggedError(AppError.PermissionDenied, "StorageGateway.uploadJpeg.during_account_delete") },
            analytics.errors,
        )
    }

    @Test
    fun `Storageの区間を出たら、アップロードがまた通る`() = runBlocking {
        val gateway = storage()
        gateway.exclusively(WriteCapability.ACCOUNT_DELETE) { }

        val result = gateway.uploadJpeg(WriteCapability.POST_CREATE, path, ByteArray(16), index = 0)

        assertEquals(AppResult.Ok(FakeStorageWriteClient.urlOf(path.value)), result)
        assertEquals(emptyList(), analytics.errors)
    }

    // ── 区間の数え方（入れ子・同時・別の種類）──

    @Test
    fun `同じ種類の区間が重なったら、最後の区間が終わるまで断り続ける`() = runBlocking {
        val writes = ExclusiveWrites()

        writes.run(WriteCapability.ACCOUNT_DELETE) {
            writes.run(WriteCapability.ACCOUNT_DELETE) {
                assertEquals(WriteCapability.ACCOUNT_DELETE, writes.refusing(WriteCapability.LIKE))
            }
            // 内側が終わっても、外側の区間はまだ続いている（同時に 2 回呼ばれた退会の、先に終わった方が印を外さない）
            assertEquals(WriteCapability.ACCOUNT_DELETE, writes.refusing(WriteCapability.LIKE))
            assertNull(writes.refusing(WriteCapability.ACCOUNT_DELETE))
        }

        assertNull(writes.refusing(WriteCapability.LIKE))
    }

    @Test
    fun `別の種類の区間の中で区間に入ろうとしたら、呼び出しの誤りとして止め、元の区間は保つ`() = runBlocking {
        val writes = ExclusiveWrites()

        writes.run(WriteCapability.ACCOUNT_DELETE) {
            assertFailsWith<IllegalStateException> { writes.run(WriteCapability.LIKE) { } }
            assertEquals(WriteCapability.ACCOUNT_DELETE, writes.refusing(WriteCapability.LIKE))
        }

        assertNull(writes.refusing(WriteCapability.LIKE))
    }
}
