// ⭐️ Storage の失敗の種類の写し方のテスト（タスク 6.3）
package com.yoshidometoru.soramoyou.data.remote.write

import com.google.firebase.storage.StorageException
import com.yoshidometoru.soramoyou.contract.AppError
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * SDK の定数（`StorageException.ERROR_*`）をそのまま使って写し方を確かめる。
 * 定数はコンパイル時に値が埋め込まれるので、JVM の単体テストでも StorageException のクラスは初期化されない。
 */
class StorageErrorsTest {

    @Test
    fun `未認証と権限の拒否はPermissionDeniedに写す`() {
        assertEquals(AppError.PermissionDenied, storageErrorOf(StorageException.ERROR_NOT_AUTHENTICATED))
        assertEquals(AppError.PermissionDenied, storageErrorOf(StorageException.ERROR_NOT_AUTHORIZED))
    }

    @Test
    fun `不在はNotFoundに、SDKの再試行の上限はNetworkに写す`() {
        assertEquals(AppError.NotFound, storageErrorOf(StorageException.ERROR_OBJECT_NOT_FOUND))
        assertEquals(AppError.Network, storageErrorOf(StorageException.ERROR_RETRY_LIMIT_EXCEEDED))
    }

    @Test
    fun `それ以外は種類の値だけを載せたUnknownにする`() {
        assertEquals(AppError.Unknown("StorageException(-13013)"), storageErrorOf(StorageException.ERROR_QUOTA_EXCEEDED))
        assertEquals(AppError.Unknown("StorageException(-13000)"), storageErrorOf(StorageException.ERROR_UNKNOWN))
    }
}
