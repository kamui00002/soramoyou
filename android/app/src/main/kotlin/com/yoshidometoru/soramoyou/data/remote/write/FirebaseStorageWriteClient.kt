// ☁️ Storage の継ぎ目の本番の実装：Storage の SDK を呼ぶ（タスク 6.3）
package com.yoshidometoru.soramoyou.data.remote.write

import com.google.firebase.storage.FirebaseStorage
import com.google.firebase.storage.StorageException
import com.google.firebase.storage.StorageMetadata
import kotlinx.coroutines.tasks.await

/**
 * [StorageWriteClient] の本番の実装。SDK の失敗（StorageException）は [storageErrorOf] で写して投げる。
 *
 * コルーチンが取り消されても、始まったアップロード自体は SDK の中で続く（Task の await は待つのをやめるだけ）。
 *
 * @param storage Storage のインスタンスを得る（AppContainer の `storage`）。インスタンスを得るのは AppContainer だけにするため、
 *   ここでは受け取ったものを使う。
 */
internal class FirebaseStorageWriteClient(private val storage: () -> FirebaseStorage) : StorageWriteClient {

    override suspend fun put(path: String, bytes: ByteArray, contentType: String) {
        sdk {
            val metadata = StorageMetadata.Builder().setContentType(contentType).build()
            it.getReference(path).putBytes(bytes, metadata).await()
        }
    }

    override suspend fun downloadUrl(path: String): String =
        sdk { it.getReference(path).downloadUrl.await().toString() }

    override suspend fun delete(path: String) {
        sdk { it.getReference(path).delete().await() }
    }

    // listAll は続きのページを SDK の中で読み切ってから返す（退会で消す数百件の規模なら、全てを手元に持ってよい）。
    // 参照の path は先頭に `/` が付くことがあるので外して、アップロード・削除と同じ形のパスにそろえる
    override suspend fun list(path: String): List<String> =
        sdk { storage -> storage.getReference(path).listAll().await().items.map { it.path.removePrefix("/") } }

    /** SDK を呼び、Storage の失敗を [StorageWriteFailure] に写す。それ以外の例外はそのまま伝える。 */
    private suspend inline fun <T> sdk(block: (FirebaseStorage) -> T): T =
        try {
            block(storage())
        } catch (e: StorageException) {
            throw StorageWriteFailure(storageErrorOf(e.errorCode), e)
        }
}
