// ⭐️ Storage への書き込みの唯一の入口の単体テスト（タスク 6.3・要件 2.2・7.3・7.5・15.2）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.platform.EventName
import com.yoshidometoru.soramoyou.platform.ParamValue
import java.util.concurrent.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlinx.coroutines.runBlocking

/**
 * Storage の入口が、可否 → 大きさ → 実行（ダウンロード URL は再試行）→ 記録 の順で進み、断ったら Storage（の継ぎ目の偽物）に
 * 到達しないことを確かめる（設計書 :665-674、「M1の書き込みゼロ保証」3）。
 * 再試行の待ちは実際には待たず、待った長さを [waits] に記録する。
 */
class DefaultStorageGatewayTest {

    private val path = StoragePath("posts/writer-uid/public/IMG-1.jpg")
    private val jpeg = ByteArray(1024)
    private val fiveMb = 5 * 1024 * 1024

    private val client = FakeStorageWriteClient()
    private val analytics = RecordingAnalytics()
    private val waits = mutableListOf<Long>()

    private fun gateway(enabled: Set<WriteCapability> = setOf(WriteCapability.POST_CREATE, WriteCapability.POST_DELETE)) =
        DefaultStorageGateway(FixedWriteGate(enabled), client, analytics) { waits += it }

    /** 期待する `retry_operation`（キーは iOS の logRetryEvent と同じ。成功のときは error_description を持たない）。 */
    private fun retryEvent(attempt: Long, success: Boolean, errorDescription: String? = null) = RecordingAnalytics.LoggedEvent(
        EventName.RETRY_OPERATION,
        buildMap {
            put("operation", ParamValue.S("StorageGateway.uploadJpeg.downloadUrl"))
            put("attempt", ParamValue.L(attempt))
            put("success", ParamValue.B(success))
            if (errorDescription != null) put("error_description", ParamValue.S(errorDescription))
        },
    )

    private fun operations() = client.calls.map { it.operation }

    // ── 陽性対照：有効なときは、偽物が呼ばれる（この偽物で「呼ばれない」を確かめることに意味があることを先に示す）──

    @Test
    fun `有効なら、uploadJpegは偽物にputしてからダウンロードURLを得て、そのURLを返す`() = runBlocking {
        val result = gateway().uploadJpeg(WriteCapability.POST_CREATE, path, jpeg, index = 0)

        assertEquals(AppResult.Ok(FakeStorageWriteClient.urlOf(path.value)), result)
        assertEquals(listOf("put", "downloadUrl"), operations())
        assertEquals(listOf(path.value, path.value), client.calls.map { it.path })
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `有効なら、deleteは偽物のdeleteをパスそのままで呼び、成功を返す`() = runBlocking {
        val result = gateway().delete(WriteCapability.POST_DELETE, path)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf(FakeStorageWriteClient.Call("delete", path.value)), client.calls)
        assertEquals(emptyList(), analytics.errors)
    }

    // ── 可否が無効なら、アップロードも削除も偽物に到達せず WriteBlocked を返して記録する（M1 の保証）──

    @Test
    fun `可否が無効なら、アップロードも削除もWriteBlockedを返し、偽物は一度も呼ばれず、記録する`() = runBlocking {
        val gateway = gateway(enabled = emptySet())

        assertEquals(
            AppResult.Err(AppError.WriteBlocked(WriteCapability.POST_CREATE)),
            gateway.uploadJpeg(WriteCapability.POST_CREATE, path, jpeg, index = 0),
        )
        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.POST_DELETE)), gateway.delete(WriteCapability.POST_DELETE, path))

        assertEquals(emptyList(), client.calls, "可否が無効なのに偽物に到達した")
        assertEquals(
            listOf(
                RecordingAnalytics.LoggedError(AppError.WriteBlocked(WriteCapability.POST_CREATE), "StorageGateway.uploadJpeg"),
                RecordingAnalytics.LoggedError(AppError.WriteBlocked(WriteCapability.POST_DELETE), "StorageGateway.delete"),
            ),
            analytics.errors,
        )
    }

    @Test
    fun `可否は呼び出しごとの種類で判定する（別の種類が有効でも通さない）`() = runBlocking {
        val result = gateway(enabled = setOf(WriteCapability.LIKE)).uploadJpeg(WriteCapability.POST_CREATE, path, jpeg, index = 0)

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.POST_CREATE)), result)
        assertEquals(emptyList(), client.calls)
    }

    @Test
    fun `可否の判定は大きさの検査より先に行う（無効なら大きすぎる画像でもWriteBlocked）`() = runBlocking {
        val result = gateway(enabled = emptySet()).uploadJpeg(WriteCapability.POST_CREATE, path, ByteArray(fiveMb), index = 0)

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.POST_CREATE)), result)
        assertEquals(emptyList(), client.calls)
    }

    // ── 大きさ（storage.rules は 5MB 未満だけを受け付ける）──

    @Test
    fun `ちょうど5MBの画像は送らずにImageTooLargeを返し、何枚目かとバイト数を載せて記録する`() = runBlocking {
        val result = gateway().uploadJpeg(WriteCapability.POST_CREATE, path, ByteArray(fiveMb), index = 2)

        val tooLarge = AppError.ImageTooLarge(index = 2, bytes = fiveMb.toLong())
        assertEquals(AppResult.Err(tooLarge), result)
        assertEquals(emptyList(), client.calls, "大きすぎる画像を送った")
        assertEquals(listOf(RecordingAnalytics.LoggedError(tooLarge, "StorageGateway.uploadJpeg")), analytics.errors)
    }

    @Test
    fun `5MBより1バイト小さい画像は送る`() = runBlocking {
        val result = gateway().uploadJpeg(WriteCapability.POST_CREATE, path, ByteArray(fiveMb - 1), index = 0)

        assertEquals(AppResult.Ok(FakeStorageWriteClient.urlOf(path.value)), result)
        assertEquals(fiveMb - 1, client.calls.first().size)
    }

    // ── contentType ──

    @Test
    fun `アップロードのcontentTypeはJPEGに固定する`() = runBlocking {
        gateway().uploadJpeg(WriteCapability.POST_CREATE, path, jpeg, index = 0)

        assertEquals(FakeStorageWriteClient.Call("put", path.value, jpeg.size, "image/jpeg"), client.calls.first())
    }

    // ── ダウンロード URL の再試行（iOS StorageService.swift:93-120：合わせて 3 回・0.5 秒と 1 秒の間隔）──

    @Test
    fun `1回目でダウンロードURLが取れたら、待たずにやり直しの記録もしない`() = runBlocking {
        gateway().uploadJpeg(WriteCapability.POST_CREATE, path, jpeg, index = 0)

        assertEquals(emptyList(), waits)
        assertEquals(emptyList(), analytics.events)
    }

    @Test
    fun `ダウンロードURLの取得が2回失敗しても3回目で成功すれば、URLを返し、やり直しを記録する`() = runBlocking {
        client.failOn = "downloadUrl"
        client.failTimes = 2
        client.failure = StorageWriteFailure(AppError.NotFound, RuntimeException("偽物の失敗"))

        val result = gateway().uploadJpeg(WriteCapability.POST_CREATE, path, jpeg, index = 0)

        assertEquals(AppResult.Ok(FakeStorageWriteClient.urlOf(path.value)), result)
        assertEquals(listOf("put", "downloadUrl", "downloadUrl", "downloadUrl"), operations())
        assertEquals(listOf(500L, 1000L), waits)
        assertEquals(
            listOf(retryEvent(1, success = false, "NotFound"), retryEvent(2, success = false, "NotFound"), retryEvent(3, success = true)),
            analytics.events,
        )
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `ダウンロードURLの取得が3回とも失敗したら、4回目は試さずにその失敗を返し、記録はやり直しの2回分だけ`() = runBlocking {
        client.failOn = "downloadUrl"
        client.failure = StorageWriteFailure(AppError.Network, RuntimeException("偽物の失敗"))

        val result = gateway().uploadJpeg(WriteCapability.POST_CREATE, path, jpeg, index = 0)

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(listOf("put", "downloadUrl", "downloadUrl", "downloadUrl"), operations())
        assertEquals(listOf(500L, 1000L), waits)
        assertEquals(listOf(retryEvent(1, success = false, "Network"), retryEvent(2, success = false, "Network")), analytics.events)
        assertEquals(emptyList(), analytics.errors, "写した Storage の失敗は入口では記録しない")
    }

    @Test
    fun `やり直しの記録に例外の文言を載せない（写せない例外は型名だけ）`() = runBlocking {
        client.failOn = "downloadUrl"
        client.failTimes = 1
        client.failure = IllegalStateException("posts/secret-uid/public/IMG-1.jpg が無い")

        gateway().uploadJpeg(WriteCapability.POST_CREATE, path, jpeg, index = 0)

        assertEquals(retryEvent(1, success = false, "Unknown(IllegalStateException)"), analytics.events.first())
        assertFalse(analytics.events.toString().contains("secret-uid"), "例外の文言（パスの uid）が記録に載った")
    }

    // ── Storage の失敗 ──

    @Test
    fun `アップロードの失敗は写して返し、ダウンロードURLは取りに行かず、記録しない`() = runBlocking {
        client.failOn = "put"
        client.failure = StorageWriteFailure(AppError.PermissionDenied, RuntimeException("偽物の失敗"))

        val result = gateway().uploadJpeg(WriteCapability.POST_CREATE, path, jpeg, index = 0)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(listOf("put"), operations())
        assertEquals(emptyList(), analytics.errors)
        assertEquals(emptyList(), analytics.events)
    }

    @Test
    fun `無いオブジェクトの削除はNotFoundを返し、記録しない`() = runBlocking {
        client.failOn = "delete"
        client.failure = StorageWriteFailure(AppError.NotFound, RuntimeException("偽物の失敗"))

        val result = gateway().delete(WriteCapability.POST_DELETE, path)

        assertEquals(AppResult.Err(AppError.NotFound), result)
        assertEquals(emptyList(), analytics.errors)
    }

    // ── フォルダの一覧（タスク 31.6。退会が残っている画像を探す）──

    private val folder = StoragePath("posts/writer-uid/followers")

    @Test
    fun `有効なら、listは偽物のlistをフォルダのパスそのままで呼び、返ったパスをStoragePathにして返す`() = runBlocking {
        client.listed = mapOf(folder.value to listOf("posts/writer-uid/followers/A.jpg", "posts/writer-uid/followers/B.jpg"))

        val result = gateway(enabled = setOf(WriteCapability.ACCOUNT_DELETE)).list(WriteCapability.ACCOUNT_DELETE, folder)

        assertEquals(
            AppResult.Ok(listOf(StoragePath("posts/writer-uid/followers/A.jpg"), StoragePath("posts/writer-uid/followers/B.jpg"))),
            result,
        )
        assertEquals(listOf(FakeStorageWriteClient.Call("list", folder.value)), client.calls)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `可否が無効なら、listはWriteBlockedを返し、偽物は呼ばれず、記録する`() = runBlocking {
        val result = gateway(enabled = setOf(WriteCapability.POST_DELETE)).list(WriteCapability.ACCOUNT_DELETE, folder)

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.ACCOUNT_DELETE)), result)
        assertEquals(emptyList(), client.calls)
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.WriteBlocked(WriteCapability.ACCOUNT_DELETE), "StorageGateway.list")),
            analytics.errors,
        )
    }

    @Test
    fun `listの失敗は写して返し、記録しない`() = runBlocking {
        client.failOn = "list"
        client.failure = StorageWriteFailure(AppError.PermissionDenied, RuntimeException("偽物の失敗"))

        val result = gateway(enabled = setOf(WriteCapability.ACCOUNT_DELETE)).list(WriteCapability.ACCOUNT_DELETE, folder)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `退会の区間の中でも、listは断らない（区間が断るのはアップロードだけ）`() = runBlocking {
        val gateway = gateway(enabled = setOf(WriteCapability.ACCOUNT_DELETE, WriteCapability.POST_DELETE))

        // 区間と別の種類で呼ぶ（区間はもともと同じ種類を断らないので、同じ種類では list が区間を見る形に変わっても気づけない）
        val result = gateway.exclusively(WriteCapability.ACCOUNT_DELETE) { gateway.list(WriteCapability.POST_DELETE, folder) }

        assertEquals(AppResult.Ok(emptyList()), result)
        assertEquals(listOf(FakeStorageWriteClient.Call("list", folder.value)), client.calls)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `写せない例外は、文言を載せずに型名だけのUnknownにする`() = runBlocking {
        client.failOn = "put"
        client.failure = IllegalStateException("秘密の文言")

        val result = gateway().uploadJpeg(WriteCapability.POST_CREATE, path, jpeg, index = 0)

        assertEquals(AppResult.Err(AppError.Unknown("IllegalStateException")), result)
    }

    @Test
    fun `取り消しは失敗に写さず、やり直さずにそのまま伝える`() = runBlocking {
        client.failOn = "downloadUrl"
        client.failure = CancellationException("取り消し")

        assertFailsWith<CancellationException> { gateway().uploadJpeg(WriteCapability.POST_CREATE, path, jpeg, index = 0) }
        assertEquals(listOf("put", "downloadUrl"), operations())
        assertEquals(emptyList(), waits)
    }
}
