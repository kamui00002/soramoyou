// ⭐️ 自分がブロック中のユーザーの一覧の取得の単体テスト（タスク 9.1・要件 4.9）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.runBlocking

/**
 * ブロック中のユーザーの一覧を、自分のユーザー文書の `blockedUserIds` から読むこと、無いときは空にすること、
 * 読み取りの失敗は記録してから Err で返すこと（表示を続けるかは呼び出し側）を確かめる（iOS：`fetchBlockedUserIds`）。
 */
class BlockListRepositoryTest {

    private val me = Uid("me")
    private val analytics = RecordingRepositoryAnalytics()

    private fun repository(reader: FakeFirestoreReader, uid: Uid? = me) =
        DefaultBlockListRepository(reader, { uid }, analytics)

    private fun userDocument(data: Map<String, Any?>): Map<String, AppResult<RawDocument?>> =
        mapOf(DocRef.user(me).path to AppResult.Ok(RawDocument(me.value, data)))

    @Test
    fun `自分のユーザー文書のblockedUserIdsをuidの集合で返す`() = runBlocking {
        val reader = FakeFirestoreReader(documents = userDocument(mapOf("blockedUserIds" to listOf("b-1", "b-2"))))

        assertEquals(AppResult.Ok(setOf(Uid("b-1"), Uid("b-2"))), repository(reader).blockedIds())
        assertEquals(listOf(DocRef.user(me) to ReadSource.DEFAULT), reader.gets)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `ログインしていなければ読まずに空を返す`() = runBlocking {
        val reader = FakeFirestoreReader()

        assertEquals(AppResult.Ok(emptySet()), repository(reader, uid = null).blockedIds())
        assertEquals(emptyList(), reader.gets)
    }

    @Test
    fun `ユーザー文書や項目が無ければ空を返す`() = runBlocking {
        assertEquals(AppResult.Ok(emptySet()), repository(FakeFirestoreReader()).blockedIds())
        assertEquals(
            AppResult.Ok(emptySet()),
            repository(FakeFirestoreReader(documents = userDocument(mapOf("displayName" to "そら")))).blockedIds(),
        )
        assertEquals(
            AppResult.Ok(emptySet()),
            repository(FakeFirestoreReader(documents = userDocument(mapOf("blockedUserIds" to "b-1")))).blockedIds(),
        )
    }

    @Test
    fun `配列に文字列でない要素が混ざっても、文字列のuidだけはブロック中として残す`() = runBlocking {
        val reader = FakeFirestoreReader(documents = userDocument(mapOf("blockedUserIds" to listOf("b-1", 42L, null, "b-2"))))

        assertEquals(AppResult.Ok(setOf(Uid("b-1"), Uid("b-2"))), repository(reader).blockedIds())
    }

    @Test
    fun `読み取りの失敗は発生箇所つきで記録してから、同じ種類のErrで返す`() = runBlocking {
        val reader = FakeFirestoreReader(documents = mapOf(DocRef.user(me).path to AppResult.Err(AppError.PermissionDenied)))

        assertEquals(AppResult.Err(AppError.PermissionDenied), repository(reader).blockedIds())
        assertEquals(listOf<Pair<AppError, String>>(AppError.PermissionDenied to "BlockListRepository.blockedIds"), analytics.errors)
    }
}
