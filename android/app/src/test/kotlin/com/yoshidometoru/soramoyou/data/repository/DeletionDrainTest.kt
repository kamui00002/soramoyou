// ⭐️ 退会の「50 件取って消す」を空になるまで繰り返す部品の単体テスト（iOS BatchDrainerTests に相当。タスク 31.2）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.CountSpec
import com.yoshidometoru.soramoyou.data.remote.read.DrainTarget
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.QuerySpec
import com.yoshidometoru.soramoyou.data.remote.read.RawPage
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.runBlocking

/**
 * [drainOwnDocuments] の単体テスト。取得は、決めた件数のページを順に返す偽物（ScriptedReader）で行う。
 * いいね・コメントの段階（タスク 31.3）も同じ部品を使うので、終わり方と打ち切りはここで固定する。
 */
class DeletionDrainTest {

    private val uid = Uid("UID-1")

    /** [sizes] の件数のページを順に返す取得の偽物（足りなくなったら最後の件数を返し続ける）。[failAt] 回目は Network を返す。取得の形と取得元を記録する。 */
    private class ScriptedReader(private val sizes: List<Int>, private val failAt: Int? = null) : FirestoreReader {
        val queries = mutableListOf<Pair<QuerySpec, ReadSource>>()

        override suspend fun query(spec: QuerySpec, source: ReadSource): AppResult<RawPage> {
            queries += spec to source
            if (queries.size == failAt) return AppResult.Err(AppError.Network)
            val size = sizes[minOf(queries.size - 1, sizes.lastIndex)]
            return AppResult.Ok(RawPage(List(size) { RawDocument("D${queries.size}-$it", emptyMap()) }, cursor = null))
        }

        override suspend fun get(ref: DocRef, source: ReadSource): AppResult<RawDocument?> = error("使わない")

        override suspend fun count(spec: CountSpec): AppResult<Long> = error("使わない")

        override fun observe(ref: DocRef): Flow<AppResult<RawDocument?>> = error("使わない")
    }

    /** 渡されたページの件数を記録し、[failAt] 回目だけ PermissionDenied を返す削除。 */
    private class RecordingDelete(private val failAt: Int? = null) {
        val pageSizes = mutableListOf<Int>()
        val delete: suspend (List<RawDocument>) -> AppResult<Unit> = { page ->
            pageSizes += page.size
            if (pageSizes.size == failAt) AppResult.Err(AppError.PermissionDenied) else AppResult.Ok(Unit)
        }
    }

    @Test
    fun `空になるまで先頭から取り直して消し、取得はサーバーから行う`() = runBlocking {
        val scripted = ScriptedReader(listOf(50, 50, 0))
        val deleted = RecordingDelete()

        val result = drainOwnDocuments(scripted, DrainTarget.FOLLOWS_AS_FOLLOWEE, uid, deleted.delete)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf(50, 50), deleted.pageSizes)
        // 毎回同じ形（続きの起点を持たない）で、サーバーから
        val expected: List<Pair<QuerySpec, ReadSource>> = List(3) { QuerySpec.DrainByField(DrainTarget.FOLLOWS_AS_FOLLOWEE, uid) to ReadSource.SERVER }
        assertEquals(expected, scripted.queries)
    }

    @Test
    fun `上限未満のページは最後のページなので、空を確かめる取得を撃たずに終える`() = runBlocking {
        val scripted = ScriptedReader(listOf(50, 49))
        val deleted = RecordingDelete()

        val result = drainOwnDocuments(scripted, DrainTarget.LIKES, uid, deleted.delete)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf(50, 49), deleted.pageSizes)
        assertEquals(2, scripted.queries.size)
    }

    @Test
    fun `最初から空なら何も消さずに終える`() = runBlocking {
        val scripted = ScriptedReader(listOf(0))
        val deleted = RecordingDelete()

        assertEquals(AppResult.Ok(Unit), drainOwnDocuments(scripted, DrainTarget.COMMENTS, uid, deleted.delete))
        assertEquals(emptyList(), deleted.pageSizes)
        assertEquals(1, scripted.queries.size)
    }

    @Test
    fun `200ページ目が上限未満なら、打ち切らずに終える`() = runBlocking {
        val scripted = ScriptedReader(List(MAX_DRAIN_PAGES - 1) { 50 } + 10)
        val deleted = RecordingDelete()

        assertEquals(AppResult.Ok(Unit), drainOwnDocuments(scripted, DrainTarget.FOLLOWS_AS_FOLLOWER, uid, deleted.delete))
        assertEquals(200, scripted.queries.size)
    }

    @Test
    fun `200ページ取っても毎回上限ちょうど返り続けたら、黙って終えずに失敗にする`() = runBlocking {
        // 201 回目があれば空になる、という状態でも 200 回で止める（削除が黙って効いていない疑いのほうを怖がる。iOS と同じ）
        val scripted = ScriptedReader(List(MAX_DRAIN_PAGES) { 50 } + 0)
        val deleted = RecordingDelete()

        val result = drainOwnDocuments(scripted, DrainTarget.FOLLOWS_AS_FOLLOWER, uid, deleted.delete)

        assertEquals(AppResult.Err(DRAIN_EXCEEDED), result)
        assertEquals(AppError.Unknown("DrainExceededMaxPages(200)"), DRAIN_EXCEEDED)
        assertEquals(200, scripted.queries.size)
        assertEquals(200, deleted.pageSizes.size)
    }

    @Test
    fun `取得に失敗したら、その失敗を返して止める`() = runBlocking {
        val scripted = ScriptedReader(listOf(50), failAt = 2)
        val deleted = RecordingDelete()

        assertEquals(AppResult.Err(AppError.Network), drainOwnDocuments(scripted, DrainTarget.FOLLOWS_AS_FOLLOWER, uid, deleted.delete))
        assertEquals(listOf(50), deleted.pageSizes)
        assertEquals(2, scripted.queries.size)
    }

    @Test
    fun `削除に失敗したら、その失敗を返して次のページを取らない`() = runBlocking {
        val scripted = ScriptedReader(listOf(50))
        val deleted = RecordingDelete(failAt = 1)

        assertEquals(AppResult.Err(AppError.PermissionDenied), drainOwnDocuments(scripted, DrainTarget.FOLLOWS_AS_FOLLOWER, uid, deleted.delete))
        assertEquals(1, scripted.queries.size)
    }
}
