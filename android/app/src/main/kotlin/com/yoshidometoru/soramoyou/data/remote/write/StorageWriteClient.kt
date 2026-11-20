// ⭐️ Storage の入口と Storage の SDK の間の継ぎ目（タスク 6.3。単体テストで偽物に差し替える）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.AppError

/**
 * Storage の SDK を呼ぶ部分だけを切り出した継ぎ目。可否・大きさの検査・再試行・記録は持たない（それは [DefaultStorageGateway]）。
 * 本番の実装は [FirebaseStorageWriteClient]、単体テストでは呼ばれたかを記録する偽物を使う。
 *
 * パスは Storage のオブジェクトのパス（`StoragePath.value`）で受ける。
 * 失敗は、写せるものは [StorageWriteFailure] で、それ以外は元の例外のまま投げる。
 * この package の外から使わせないため internal にしている。
 */
internal interface StorageWriteClient {

    /** [path] に [bytes] を、メタデータの contentType を [contentType] にしてアップロードする。 */
    suspend fun put(path: String, bytes: ByteArray, contentType: String)

    /** [path] のダウンロード URL を得る。 */
    suspend fun downloadUrl(path: String): String

    /** [path] のオブジェクトを消す。 */
    suspend fun delete(path: String)

    /** フォルダ [path] の直下のオブジェクトのパス（先頭に `/` を付けない形）を全て返す。下のフォルダは含めない（タスク 31.6）。 */
    suspend fun list(path: String): List<String>
}

/** SDK の失敗を [AppError] に写したもの。[StorageWriteClient] の実装が投げ、入口が `AppResult.Err` にして返す。 */
internal class StorageWriteFailure(val error: AppError, cause: Throwable) : Exception(cause)
