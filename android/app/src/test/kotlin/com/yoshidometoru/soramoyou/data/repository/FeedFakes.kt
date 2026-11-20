// ⭐️ フィードのリポジトリの単体テストで共有する偽物と、投稿ドキュメントの組み立て（タスク 9.1・9.3）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.CountSpec
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.QuerySpec
import com.yoshidometoru.soramoyou.data.remote.read.RawCursor
import com.yoshidometoru.soramoyou.data.remote.read.RawPage
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.EventName
import com.yoshidometoru.soramoyou.platform.ParamValue
import com.yoshidometoru.soramoyou.platform.ScreenName
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

/**
 * 呼ばれた内容を記録する読み取りの入口の偽物。
 * [pages] はクエリが順に返す結果（足りなくなったら最後のものを返し続ける）、[documents] はパスごとの単一取得の結果、
 * [streams] はパスごとの監視の流れ（無ければ何も流さずに終わる）、[countResults] は集計の形ごとの結果（無い形を数えたらテストの誤りとして止める）。
 */
internal class FakeFirestoreReader(
    private val pages: List<AppResult<RawPage>> = emptyList(),
    private val documents: Map<String, AppResult<RawDocument?>> = emptyMap(),
    private val streams: Map<String, Flow<AppResult<RawDocument?>>> = emptyMap(),
    private val countResults: Map<CountSpec, AppResult<Long>> = emptyMap(),
) : FirestoreReader {

    val queries = mutableListOf<Pair<QuerySpec, ReadSource>>()
    val gets = mutableListOf<Pair<DocRef, ReadSource>>()
    val observed = mutableListOf<DocRef>()
    val counts = mutableListOf<CountSpec>()

    override suspend fun get(ref: DocRef, source: ReadSource): AppResult<RawDocument?> {
        gets += ref to source
        return documents[ref.path] ?: AppResult.Ok(null)
    }

    override suspend fun query(spec: QuerySpec, source: ReadSource): AppResult<RawPage> {
        queries += spec to source
        return pages[minOf(queries.size - 1, pages.lastIndex)]
    }

    override suspend fun count(spec: CountSpec): AppResult<Long> {
        counts += spec
        return countResults[spec] ?: error("集計の結果を用意していない形: $spec")
    }

    override fun observe(ref: DocRef): Flow<AppResult<RawDocument?>> {
        observed += ref
        return streams[ref.path] ?: emptyFlow()
    }
}

/** 分析の窓口の偽物。送ったイベントと失敗の記録を順に残す。 */
internal class RecordingRepositoryAnalytics : AnalyticsFacade {
    val events = mutableListOf<Pair<EventName, Map<String, ParamValue>>>()
    val errors = mutableListOf<Pair<AppError, String>>()
    override fun logEvent(name: EventName, params: Map<String, ParamValue>) { events += name to params }
    override fun logScreen(name: ScreenName) = Unit
    override fun logError(error: AppError, context: String) { errors += error to context }
    override fun setUserId(uid: Uid?) = Unit
}

/** 表示できる投稿のドキュメント（投稿者は [author]）。 */
internal fun postDocument(id: String, author: String = "u-$id"): RawDocument =
    RawDocument(id, mapOf("userId" to author, "images" to listOf(mapOf("url" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$id.jpg"))))

/** 変換できない投稿のドキュメント（`userId` が無い）。 */
internal fun brokenPostDocument(id: String): RawDocument =
    RawDocument(id, mapOf("images" to listOf(mapOf("url" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$id.jpg"))))

/** [documents] を読んだ結果のページ。カーソルは生の最後の 1 件を指す値（0 件なら null）。 */
internal fun rawPage(documents: List<RawDocument>): RawPage =
    RawPage(documents, documents.lastOrNull()?.let { RawCursor("cursor-${it.id}") })
