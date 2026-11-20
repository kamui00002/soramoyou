// ⭐️ Storage への書き込みの唯一の入口の実装：可否 → 大きさ → 実行（ダウンロード URL は再試行）→ 記録（タスク 6.3・要件 2.2・7.3・7.5・15.2）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.EventName
import com.yoshidometoru.soramoyou.platform.ParamValue
import com.yoshidometoru.soramoyou.platform.toErrorDescription
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.delay

/**
 * [StorageGateway] の実装。どの呼び出しも、次の順で進め、どこかで断ったら Storage には到達しない。
 *
 * 1. 可否：[gate] で [WriteCapability] が無効なら `WriteBlocked`（大きさの検査より先。タスク 6.3「全ての呼び出しの先頭で」）
 * 1'. 区間（アップロードだけ）：[exclusively] の区間の中で、区間と別の種類なら `PermissionDenied`
 *    （発生箇所は `StorageGateway.uploadJpeg.during_<区間の種類の小文字>`。削除は通す。タスク 31.2 の確かめる係の指摘の直し）
 * 2. 大きさ（アップロードだけ）：5MB 以上なら `ImageTooLarge`
 * 3. 実行：[client] を呼ぶ。失敗は [StorageWriteFailure] の写しを返す。写せない例外は `Unknown`（例外の型名だけを載せる）
 * 4. 記録：1・1'・2 で断ったものだけを [AnalyticsFacade.logError] に渡す（発生箇所は `StorageGateway.<操作名>`）
 *
 * 書き手の uid は見ない。Firestore の入口が uid を要るのは形の検証のためで、Storage には形の検証が無い。
 * ログインしていなければ Storage が `ERROR_NOT_AUTHENTICATED` で断り、`PermissionDenied` に写して返る。
 *
 * コルーチンの取り消し（CancellationException）は失敗に写さず、そのまま伝える。
 *
 * @param wait 再試行の前に待つ処理（ミリ秒）。単体テストでは、実際に待たずに待った長さを記録するものに差し替える。
 */
class DefaultStorageGateway internal constructor(
    private val gate: WriteGate,
    private val client: StorageWriteClient,
    private val analytics: AnalyticsFacade,
    private val wait: suspend (Long) -> Unit = { delay(it) },
) : StorageGateway {

    /** [exclusively] の区間の印（区間と別の種類のアップロードを断る）。 */
    private val exclusive = ExclusiveWrites()

    override suspend fun uploadJpeg(cap: WriteCapability, path: StoragePath, bytes: ByteArray, index: Int): AppResult<String> {
        val context = "$CONTEXT_PREFIX.uploadJpeg"
        if (!gate.isEnabled(cap)) return refuse(AppError.WriteBlocked(cap), context)
        exclusive.refusing(cap)?.let { holder -> return refuse(AppError.PermissionDenied, "$context.during_${holder.name.lowercase()}") }
        // storage.rules は「5MB 未満」（request.resource.size < 5 * 1024 * 1024）なので、ちょうど 5MB も断る。
        // iOS（StorageService.swift:57-58）は `>` で比べていて、ちょうど 5MB を送ってしまう。設計書 :673 の `>=` に従う
        if (bytes.size >= StorageGateway.MAX_UPLOAD_BYTES) return refuse(AppError.ImageTooLarge(index, bytes.size.toLong()), context)
        return sdk {
            client.put(path.value, bytes, JPEG_CONTENT_TYPE)
            downloadUrlWithRetry(path.value)
        }
    }

    override suspend fun delete(cap: WriteCapability, path: StoragePath): AppResult<Unit> {
        if (!gate.isEnabled(cap)) return refuse(AppError.WriteBlocked(cap), "$CONTEXT_PREFIX.delete")
        return sdk { client.delete(path.value) }
    }

    override suspend fun list(cap: WriteCapability, folder: StoragePath): AppResult<List<StoragePath>> {
        if (!gate.isEnabled(cap)) return refuse(AppError.WriteBlocked(cap), "$CONTEXT_PREFIX.list")
        return sdk { client.list(folder.value).map(::StoragePath) }
    }

    override suspend fun <T> exclusively(cap: WriteCapability, block: suspend () -> T): T = exclusive.run(cap, block)

    /**
     * ダウンロード URL を、iOS の `getDownloadURLWithRetry`（StorageService.swift:93-120）と同じく最大 3 回まで試して得る。
     * 試すのは合わせて 3 回（やり直しは 2 回）で、失敗した n 回目の後に n × 0.5 秒待つ（0.5 秒・1 秒。倍々ではない）。
     * どの失敗もやり直す（iOS と同じ。アップロードの直後は URL がまだ取れないことがあるため）。
     *
     * `retry_operation` の記録は、iOS の StorageService には無く（os.Logger に出すだけ）、タスク 6.3 で足したもの。
     * 中身は iOS で唯一これを送る `ErrorHandler.retry`（ErrorHandler.swift:191-263）にそろえる：
     * - やり直すことになった失敗（1・2 回目）ごとに、`attempt`（1 始まり）・`success`=false・`error_description`
     * - やり直した後に成功したら、その回の `attempt` と `success`=true（1 回目で成功したら送らない）
     * - 3 回目も失敗したら送らない（iOS はそこで `network_retry_stats` を送るが、Android の送ってよいイベントに無い）。
     *   その失敗は呼び出し側へ返り、呼び出し側が `error_occurred` で記録する
     *
     * `error_description` は写した [AppError] の説明にし、例外の文言は載せない（Storage の例外の文言には、uid を含む
     * オブジェクトのパスが入りうるため）。
     */
    private suspend fun downloadUrlWithRetry(path: String): String {
        var attempt = 1
        while (true) {
            try {
                val url = client.downloadUrl(path)
                if (attempt > 1) logRetry(attempt, success = true, error = null)
                return url
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (attempt >= DOWNLOAD_URL_ATTEMPTS) throw e
                logRetry(attempt, success = false, error = e.toAppError())
                wait(attempt * RETRY_SPACING_MILLIS)
                attempt++
            }
        }
    }

    /** `retry_operation` を送る（キーは iOS の logRetryEvent（LoggingService.swift:153-167）と同じ）。 */
    private fun logRetry(attempt: Int, success: Boolean, error: AppError?) {
        val params = buildMap {
            put("operation", ParamValue.S(DOWNLOAD_URL_OPERATION))
            put("attempt", ParamValue.L(attempt.toLong()))
            put("success", ParamValue.B(success))
            if (error != null) put("error_description", ParamValue.S(error.toErrorDescription()))
        }
        analytics.logEvent(EventName.RETRY_OPERATION, params)
    }

    /** [block] を実行し、結果を [AppResult] にする。取り消しはそのまま伝える。 */
    private suspend inline fun <T> sdk(block: () -> T): AppResult<T> =
        try {
            AppResult.Ok(block())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            AppResult.Err(e.toAppError())
        }

    /** 断ったことを記録して、その失敗を返す。 */
    private fun refuse(error: AppError, context: String): AppResult.Err {
        analytics.logError(error, context)
        return AppResult.Err(error)
    }

    private companion object {
        /** アップロードのメタデータの contentType（要件 7.3）。 */
        const val JPEG_CONTENT_TYPE = "image/jpeg"

        /** ダウンロード URL を試す回数の合計（iOS の `maxRetries: 3`。やり直しは 2 回）。 */
        const val DOWNLOAD_URL_ATTEMPTS = 3

        /** やり直しの間隔の単位。n 回目の失敗の後に n 倍だけ待つ（iOS の `attempt * 500_000_000` ナノ秒）。 */
        const val RETRY_SPACING_MILLIS = 500L

        /** 記録の発生箇所の前半（設計書の部品名にそろえる）。 */
        const val CONTEXT_PREFIX = "StorageGateway"

        /** `retry_operation` の `operation`（`クラス名.メソッド名.段階` の形）。 */
        const val DOWNLOAD_URL_OPERATION = "$CONTEXT_PREFIX.uploadJpeg.downloadUrl"

        /** 写した失敗はその種類に、写せない例外は型名だけの Unknown にする。 */
        fun Exception.toAppError(): AppError =
            if (this is StorageWriteFailure) error else AppError.Unknown(javaClass.simpleName)
    }
}
