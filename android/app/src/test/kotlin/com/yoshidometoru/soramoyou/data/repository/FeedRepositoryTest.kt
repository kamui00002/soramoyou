// ⭐️ 公開投稿のフィードのページ取得の単体テスト（タスク 9.1・要件 4.1・4.2・4.3・4.10）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.DefaultPostDocumentReader
import com.yoshidometoru.soramoyou.data.remote.read.QuerySpec
import com.yoshidometoru.soramoyou.data.remote.read.RawCursor
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.read.RemoteImageUrlPolicy
import com.yoshidometoru.soramoyou.platform.EventName
import com.yoshidometoru.soramoyou.platform.ParamValue
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * フィードのページ取得が、公開投稿のフィードの形（[QuerySpec.PublicFeed]）だけで読み、1 件ずつ変換して壊れた投稿だけを除き、
 * 次の起点・「続きなし」・除外件数を変換前に読んだドキュメントで決めることを確かめる（設計書「フィード読み込み（M1）」）。
 * 壊れた投稿やブロック中のユーザーを含む満杯のページで続きを読みに行くことは、FeedPagingTest（タスク 9.3）で確かめる。
 */
class FeedRepositoryTest {

    private val analytics = RecordingRepositoryAnalytics()

    private fun repository(reader: FakeFirestoreReader) =
        DefaultFeedRepository(reader, DefaultPostDocumentReader(RemoteImageUrlPolicy.PRODUCTION), analytics)

    private fun fullPage(): List<RawDocument> = (1..QuerySpec.PublicFeed.PAGE_SIZE).map { postDocument("P$it") }

    @Test
    fun `起点なしでは先頭から公開投稿のフィードの形で読み、満杯のページは表示用に変換して続きありで返す`() = runBlocking {
        val raw = rawPage(fullPage())
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Ok(raw)))

        val page = assertIs<AppResult.Ok<FeedPage>>(repository(reader).loadPage(after = null)).value

        assertEquals(listOf<Pair<QuerySpec, ReadSource>>(QuerySpec.PublicFeed(after = null) to ReadSource.SERVER), reader.queries)
        assertEquals((1..20).map { PostId("P$it") }, page.posts.map { it.postId })
        assertSame(raw.cursor, page.next)
        assertEquals(0, page.skippedCount)
        assertFalse(page.reachedEnd)
    }

    @Test
    fun `続きは渡された起点をそのまま形に載せて読む`() = runBlocking {
        val after = RawCursor("前のページの最後の1件")
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Ok(rawPage(fullPage()))))

        repository(reader).loadPage(after)

        assertSame(after, (reader.queries.single().first as QuerySpec.PublicFeed).after)
    }

    @Test
    fun `20件に満たないページは続きなしで、壊れた投稿だけを除いて件数を数え、home_feedで記録する`() = runBlocking {
        val raw = rawPage(listOf(postDocument("A"), brokenPostDocument("BROKEN"), postDocument("C")))
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Ok(raw)))

        val page = assertIs<AppResult.Ok<FeedPage>>(repository(reader).loadPage(after = null)).value

        assertEquals(listOf(PostId("A"), PostId("C")), page.posts.map { it.postId })
        assertEquals(1, page.skippedCount)
        assertTrue(page.reachedEnd)
        assertEquals(
            listOf<Pair<EventName, ParamValue?>>(EventName.POST_DECODE_FAILED to ParamValue.S("posts/BROKEN")),
            analytics.events.map { (name, params) -> name to params["path"] },
        )
        assertEquals(ParamValue.S("home_feed"), analytics.events.single().second["source"])
    }

    @Test
    fun `0件のページは投稿なし・起点なし・続きなしで返す`() = runBlocking {
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Ok(rawPage(emptyList()))))

        val page = assertIs<AppResult.Ok<FeedPage>>(repository(reader).loadPage(after = null)).value

        assertEquals(emptyList(), page.posts)
        assertNull(page.next)
        assertEquals(0, page.skippedCount)
        assertTrue(page.reachedEnd)
    }

    @Test
    fun `取得自体の失敗は同じ種類のErrで返し、ここでは記録しない`() = runBlocking {
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Err(AppError.Network)))

        assertEquals(AppResult.Err(AppError.Network), repository(reader).loadPage(after = null))
        assertEquals(emptyList(), analytics.errors)
        assertEquals(emptyList(), analytics.events)
    }

    @Test
    fun `ブロック中の投稿者の投稿だけを、元の順のまま除ける`() = runBlocking {
        val raw = rawPage(listOf(postDocument("A", "u-1"), postDocument("B", "u-2"), postDocument("C", "u-1"), postDocument("D", "u-3")))
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Ok(raw)))
        val page = assertIs<AppResult.Ok<FeedPage>>(repository(reader).loadPage(after = null)).value

        val visible = page.excludingAuthors(setOf(Uid("u-1"), Uid("u-9")))

        assertEquals(listOf(PostId("B"), PostId("D")), visible.posts.map { it.postId })
        assertEquals(page.posts, page.excludingAuthors(emptySet()).posts)
    }
}
