// ⭐️ 書き込みの入口の単体テストで使う偽物（タスク 6.2・6.3・6.4）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.EventName
import com.yoshidometoru.soramoyou.platform.ParamValue
import com.yoshidometoru.soramoyou.platform.ScreenName

/** 可否を自由に決められるゲート（テスト用。製品のゲートは BuildConfigWriteGate だけ）。 */
class FixedWriteGate(override val enabled: Set<WriteCapability>) : WriteGate

/**
 * 呼ばれた操作を順に記録する Firestore の継ぎ目の偽物。
 * [failOn] に操作名（"set" など）を入れると、その操作で [failure] を投げる（[failAfter] 回目までは成功させる）。
 */
internal class FakeFirestoreWriteClient(
    private val documents: Map<String, RawDocument> = emptyMap(),
) : FirestoreWriteClient {

    /** 呼ばれた操作。トランザクションの中の操作は "tx." を前に付ける。 */
    val calls = mutableListOf<Call>()

    /**
     * 失敗させた呼び出しも含めて、試みた操作を順に記録する（[calls] は成功したものだけなので、失敗した後も送り続けていないかを数えるため）。
     * Storage の偽物と違って calls に足さないのは、[failAfter] を calls の数で数えているから（足すと、ほかのテストの失敗のさせ方が変わる）。
     */
    val attempts = mutableListOf<Call>()

    var failOn: String? = null
    var failAfter: Int = 0
    var failure: Exception = IllegalStateException("偽物の失敗")

    data class Call(val operation: String, val paths: List<String>, val data: FsDocument? = null)

    private fun record(call: Call) {
        attempts += call
        if (call.operation == failOn) {
            val sameBefore = calls.count { it.operation == call.operation }
            if (sameBefore >= failAfter) throw failure
        }
        calls += call
    }

    override suspend fun set(path: String, data: FsDocument) = record(Call("set", listOf(path), data))

    override suspend fun update(path: String, data: FsDocument) = record(Call("update", listOf(path), data))

    override suspend fun delete(path: String) = record(Call("delete", listOf(path)))

    override suspend fun deleteAll(paths: List<String>) = record(Call("deleteAll", paths))

    /**
     * トランザクションの結末を順に記録する（[calls] とは別に持つ）。SDK と同じく、block が値を返したらコミット、
     * 例外で抜けたら取りやめ（中で行った書き込みは反映されない）とみなす。
     */
    val transactionOutcomes = mutableListOf<TxOutcome>()

    enum class TxOutcome { COMMITTED, ABORTED }

    override suspend fun <T> runTransaction(block: suspend TxClient.() -> T): T {
        record(Call("runTransaction", emptyList()))
        val tx = object : TxClient {
            override suspend fun get(path: String): RawDocument? = documents[path].also { record(Call("tx.get", listOf(path))) }
            override fun set(path: String, data: FsDocument) = record(Call("tx.set", listOf(path), data))
            override fun update(path: String, data: FsDocument) = record(Call("tx.update", listOf(path), data))
            override fun delete(path: String) = record(Call("tx.delete", listOf(path)))
        }
        val result = try {
            tx.block()
        } catch (e: Throwable) {
            transactionOutcomes += TxOutcome.ABORTED
            throw e
        }
        transactionOutcomes += TxOutcome.COMMITTED
        return result
    }
}

/** logError と logEvent に渡されたものを記録する分析の窓口の偽物。 */
class RecordingAnalytics : AnalyticsFacade {

    data class LoggedError(val error: AppError, val context: String)

    data class LoggedEvent(val name: EventName, val params: Map<String, ParamValue>)

    val errors = mutableListOf<LoggedError>()

    /** logEvent に渡されたもの。logError が中で送る error_occurred は、この偽物では logEvent を通らないので入らない。 */
    val events = mutableListOf<LoggedEvent>()

    override fun logEvent(name: EventName, params: Map<String, ParamValue>) {
        events += LoggedEvent(name, params)
    }

    override fun logScreen(name: ScreenName) = Unit

    override fun logError(error: AppError, context: String) {
        errors += LoggedError(error, context)
    }

    override fun setUserId(uid: Uid?) = Unit
}

/**
 * 呼ばれた操作を順に記録する Storage の継ぎ目の偽物。失敗させた呼び出しも記録する（試した回数を数えるため）。
 * [failOn] に操作名（"put"・"downloadUrl"・"delete"・"list"）を入れると、その操作の最初の [failTimes] 回で [failure] を投げる。
 * 呼び出しを 1 つずつ選んで失敗させたいとき（何枚目の画像のパスだけなど）は [failWhen] を使う。
 */
internal class FakeStorageWriteClient : StorageWriteClient {

    /** 呼ばれた操作。put のときだけ送ったバイト数と contentType を持つ。 */
    val calls = mutableListOf<Call>()

    var failOn: String? = null
    var failTimes: Int = Int.MAX_VALUE
    var failure: Exception = IllegalStateException("偽物の失敗")

    /** 呼び出しごとに失敗させるかを決める（タスク 23.2）。例外を返したら、記録した後でそれを投げる。[failOn] より先に見る。 */
    var failWhen: (Call) -> Exception? = { null }

    data class Call(val operation: String, val path: String, val size: Int? = null, val contentType: String? = null)

    private fun record(call: Call) {
        val sameBefore = calls.count { it.operation == call.operation }
        calls += call
        failWhen(call)?.let { throw it }
        if (call.operation == failOn && sameBefore < failTimes) throw failure
    }

    override suspend fun put(path: String, bytes: ByteArray, contentType: String) =
        record(Call("put", path, bytes.size, contentType))

    override suspend fun downloadUrl(path: String): String {
        record(Call("downloadUrl", path))
        return urlOf(path)
    }

    override suspend fun delete(path: String) = record(Call("delete", path))

    /** [list] が返す、フォルダごとのオブジェクトのパス（タスク 31.6）。無いフォルダは空。 */
    var listed: Map<String, List<String>> = emptyMap()

    override suspend fun list(path: String): List<String> {
        record(Call("list", path))
        return listed[path].orEmpty()
    }

    companion object {
        /**
         * 偽物が返すダウンロード URL。本番の Storage の形（パスの `/` は `%2F` に符号化して `/o/` の後ろに入る）にして、
         * 書き込みの契約の画像 URL の形（StorageDownloadUrl.PRODUCTION_PATTERN）を通す。
         */
        fun urlOf(path: String) =
            "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/${path.replace("/", "%2F")}?alt=media&token=t"
    }
}
