// ⭐️ Storage の失敗の種類を AppError に写す（タスク 6.3）
package com.yoshidometoru.soramoyou.data.remote.write

import com.google.firebase.storage.StorageException
import com.yoshidometoru.soramoyou.contract.AppError

/**
 * Storage の失敗の種類（`StorageException.getErrorCode()` の値）を [AppError] に写す。
 * - `ERROR_NOT_AUTHENTICATED`・`ERROR_NOT_AUTHORIZED` → [AppError.PermissionDenied]（未ログイン・`storage.rules` の拒否）
 * - `ERROR_OBJECT_NOT_FOUND` → [AppError.NotFound]（無いオブジェクトの削除・ダウンロード URL の取得など）
 * - `ERROR_RETRY_LIMIT_EXCEEDED` → [AppError.Network]（SDK が再試行の時間の上限まで送れなかった）
 * - それ以外 → [AppError.Unknown]（種類の値だけを載せる）
 *
 * 例外そのものでなく値で受けるのは、Firestore の側（[firestoreErrorOf]）と同じく、純関数にして JVM の単体テストで確かめるため。
 * `ERROR_*` は SDK の `static final int` の定数で、コンパイル時に値が埋め込まれる（javap の `-constants` で確認）。
 */
internal fun storageErrorOf(errorCode: Int): AppError = when (errorCode) {
    StorageException.ERROR_NOT_AUTHENTICATED, StorageException.ERROR_NOT_AUTHORIZED -> AppError.PermissionDenied
    StorageException.ERROR_OBJECT_NOT_FOUND -> AppError.NotFound
    StorageException.ERROR_RETRY_LIMIT_EXCEEDED -> AppError.Network
    else -> AppError.Unknown("StorageException($errorCode)")
}
