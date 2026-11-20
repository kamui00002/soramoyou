// ⭐️ 読み取りの入口の単体テストで使う偽物（タスク 7.1・23.1）
package com.yoshidometoru.soramoyou.data.remote.read

import com.yoshidometoru.soramoyou.data.remote.RawDocument
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

/**
 * 呼ばれた内容を記録する Firestore の読み取りの継ぎ目の偽物。
 * [documents] はパスごとのドキュメント、[results] はクエリが返す結果、[streams] はパスごとの監視の流れ（無ければ何も流さずに終わる）、
 * [countResult] は集計が返す件数。[failure] を入れると、取得・クエリ・集計はそれを投げる。
 */
internal class FakeFirestoreReadClient(
    private val documents: Map<String, RawDocument> = emptyMap(),
    private val results: List<RawSnapshot> = emptyList(),
    private val streams: Map<String, Flow<RawDocument?>> = emptyMap(),
    private val countResult: Long = 0L,
) : FirestoreReadClient {

    val gets = mutableListOf<Pair<String, ReadSource>>()
    val queries = mutableListOf<Pair<QueryPlan, ReadSource>>()
    val observed = mutableListOf<String>()
    val counts = mutableListOf<CountPlan>()
    var failure: Exception? = null

    override suspend fun get(path: String, source: ReadSource): RawDocument? {
        gets += path to source
        failure?.let { throw it }
        return documents[path]
    }

    override suspend fun query(plan: QueryPlan, source: ReadSource): List<RawSnapshot> {
        queries += plan to source
        failure?.let { throw it }
        return results
    }

    override suspend fun count(plan: CountPlan): Long {
        counts += plan
        failure?.let { throw it }
        return countResult
    }

    override fun observe(path: String): Flow<RawDocument?> {
        observed += path
        return streams[path] ?: emptyFlow()
    }
}
