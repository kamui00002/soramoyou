// ☁️ 書き込みの継ぎ目の本番の実装：Firestore の SDK を呼ぶ（タスク 6.2）
package com.yoshidometoru.soramoyou.data.remote.write

import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreException
import com.google.firebase.firestore.Transaction
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.tasks.await

/**
 * [FirestoreWriteClient] の本番の実装。値は [toSdkData] で SDK の値に変え、SDK の失敗は [firestoreErrorOf] で写して投げる。
 *
 * @param firestore 操作のたびに Firestore のインスタンスを得る（AppContainer の `firestore.current()`）。
 *   ログアウトでインスタンスが作り直されるので（タスク 5.1）、得たものを持ち続けない。
 */
internal class FirebaseFirestoreWriteClient(private val firestore: () -> FirebaseFirestore) : FirestoreWriteClient {

    override suspend fun set(path: String, data: FsDocument) {
        sdk { it.document(path).set(data.toSdkData()).await() }
    }

    override suspend fun update(path: String, data: FsDocument) {
        sdk { it.document(path).update(data.toSdkData()).await() }
    }

    override suspend fun delete(path: String) {
        sdk { it.document(path).delete().await() }
    }

    override suspend fun deleteAll(paths: List<String>) {
        sdk { db ->
            val batch = db.batch()
            paths.forEach { batch.delete(db.document(it)) }
            batch.commit().await()
        }
    }

    /**
     * SDK のトランザクションは、同期の関数を SDK の実行器のスレッドで動かす（`Transaction.getDefaultExecutor()`。
     * javap で確認）。[block] は中断関数なので、そのスレッドの上で runBlocking で動かす。
     * トランザクションの中の読み取り（`Transaction.get`）は同期なので、そのスレッドを待たせるだけで済む。
     */
    override suspend fun <T> runTransaction(block: suspend TxClient.() -> T): T = sdk { db ->
        db.runTransaction { transaction -> runBlocking { SdkTxClient(db, transaction).block() } }.await()
    }

    /** SDK を呼び、Firestore の失敗を [FirestoreWriteFailure] に写す。それ以外の例外はそのまま伝える。 */
    private suspend inline fun <T> sdk(block: (FirebaseFirestore) -> T): T =
        try {
            block(firestore())
        } catch (e: FirebaseFirestoreException) {
            throw FirestoreWriteFailure(firestoreErrorOf(e.code.name), e)
        }

    /** トランザクションの中の操作。 */
    private class SdkTxClient(private val db: FirebaseFirestore, private val transaction: Transaction) : TxClient {
        override suspend fun get(path: String): RawDocument? =
            transaction.get(db.document(path)).toRawDocument()

        override fun set(path: String, data: FsDocument) {
            transaction.set(db.document(path), data.toSdkData())
        }

        override fun update(path: String, data: FsDocument) {
            transaction.update(db.document(path), data.toSdkData())
        }

        override fun delete(path: String) {
            transaction.delete(db.document(path))
        }

        /** 無ければ null。あれば ID と、SDK が返したままのフィールドの値。 */
        private fun DocumentSnapshot.toRawDocument(): RawDocument? =
            if (exists()) RawDocument(id = id, data = data.orEmpty()) else null
    }
}
