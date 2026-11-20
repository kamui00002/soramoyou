// ⭐️ 書き込みの入口と Firestore の SDK の間の継ぎ目（タスク 6.2。単体テストで偽物に差し替える）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.data.remote.RawDocument

/**
 * Firestore の SDK を呼ぶ部分だけを切り出した継ぎ目。可否・形の検証・記録は持たない（それは [DefaultFirestoreWriteGateway]）。
 * 本番の実装は [FirebaseFirestoreWriteClient]、単体テストでは呼ばれたかを記録する偽物を使う（設計書 :1128「フェイクが呼ばれること」）。
 *
 * パスはドキュメントのパス（[DocRef.path]）、値は SDK に依存しない [FsDocument] で受ける。
 * 失敗は、写せるものは [FirestoreWriteFailure] で、それ以外は元の例外のまま投げる。
 * この package の外から使わせないため internal にしている。
 */
internal interface FirestoreWriteClient {

    /** [path] に [data] を書く（set。merge の指定なし）。 */
    suspend fun set(path: String, data: FsDocument)

    /** [path] の [data] のフィールドだけを書き換える。 */
    suspend fun update(path: String, data: FsDocument)

    /** [path] を消す。 */
    suspend fun delete(path: String)

    /** [paths] を 1 回の一括書き込みで消す。件数は呼び出し側が上限（500）以下にする。 */
    suspend fun deleteAll(paths: List<String>)

    /** [block] を 1 つのトランザクションとして実行する。SDK は [block] をやり直すことがある。 */
    suspend fun <T> runTransaction(block: suspend TxClient.() -> T): T
}

/** トランザクションの中の操作（[FirestoreWriteClient.runTransaction]）。 */
internal interface TxClient {
    suspend fun get(path: String): RawDocument?
    fun set(path: String, data: FsDocument)
    fun update(path: String, data: FsDocument)
    fun delete(path: String)
}

/** SDK の失敗を [AppError] に写したもの。[FirestoreWriteClient] の実装が投げ、入口が `AppResult.Err` にして返す。 */
internal class FirestoreWriteFailure(val error: AppError, cause: Throwable) : Exception(cause)
