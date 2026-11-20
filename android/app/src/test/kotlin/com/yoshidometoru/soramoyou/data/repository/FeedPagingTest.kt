// ⭐️ フィードのページングの単体テスト：表示から除いた投稿があっても続きを読み、起点は生の最後の 1 件（タスク 9.3・要件 4.2・4.9・4.10）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.DefaultPostDocumentReader
import com.yoshidometoru.soramoyou.data.remote.read.QuerySpec
import com.yoshidometoru.soramoyou.data.remote.read.RawPage
import com.yoshidometoru.soramoyou.data.remote.read.RemoteImageUrlPolicy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertSame
import kotlinx.coroutines.runBlocking

/**
 * 「続きなし」と次の起点が、表示する投稿の件数でなく変換前に読んだドキュメントで決まることを、
 * 表示から除く投稿（変換できない投稿・ブロック中のユーザーの投稿）を含む満杯のページで確かめる（iOS PR #154・#156 の再発防止）。
 *
 * 陽性対照（2026-10-05）：次の 3 か所を壊すと、それぞれ対応する 1 本だけが失敗することを先に確かめてから、正しい実装に戻した。
 * - 取得の終了の判定を変換後の件数（`posts.size < 20`）にする → 壊れた投稿を含むページのテスト
 * - ブロックの除外のあとで終了の判定を除外後の件数で決め直す → ブロック中のユーザーの投稿を含むページのテスト
 * - 生の最後の 1 件が変換できなければ起点を作らない → 末尾が壊れたページのテスト
 */
class FeedPagingTest {

    private val analytics = RecordingRepositoryAnalytics()
    private val pageSize = QuerySpec.PublicFeed.PAGE_SIZE

    private fun repository(reader: FakeFirestoreReader) =
        DefaultFeedRepository(reader, DefaultPostDocumentReader(RemoteImageUrlPolicy.PRODUCTION), analytics)

    /** 1 ページ目に [first]、2 ページ目に空のページを返す読み取り口。 */
    private fun readerOf(first: RawPage) =
        FakeFirestoreReader(pages = listOf(AppResult.Ok(first), AppResult.Ok(rawPage(emptyList()))))

    /** 画面の状態と同じ規則で、続きがあれば前のページの起点で次を読む。 */
    private suspend fun FeedRepository.loadNextIfAny(page: FeedPage) {
        if (!page.reachedEnd) loadPage(page.next)
    }

    @Test
    fun `20件中1件が壊れたページ（表示できるのは19件）でも、続きありとして次のページを読みに行く`() = runBlocking {
        val documents: List<RawDocument> = (1..pageSize).map { if (it == 7) brokenPostDocument("P$it") else postDocument("P$it") }
        val raw = rawPage(documents)
        val reader = readerOf(raw)
        val repository = repository(reader)

        val page = assertIs<AppResult.Ok<FeedPage>>(repository.loadPage(after = null)).value
        repository.loadNextIfAny(page)

        assertEquals(19, page.posts.size)
        assertEquals(1, page.skippedCount)
        assertFalse(page.reachedEnd)
        assertEquals(2, reader.queries.size)
        assertSame(raw.cursor, (reader.queries[1].first as QuerySpec.PublicFeed).after)
    }

    @Test
    fun `ブロック中のユーザーの投稿を含むページでも、除いたあとも続きありのままで、生の最後の1件から次のページを読みに行く`() = runBlocking {
        val blocked = Uid("blocked")
        // 末尾を含む 7 件がブロック中のユーザーの投稿
        val documents = (1..pageSize).map { postDocument("P$it", author = if (it % 3 == 2) blocked.value else "u-$it") }
        val raw = rawPage(documents)
        val reader = readerOf(raw)
        val repository = repository(reader)

        val page = assertIs<AppResult.Ok<FeedPage>>(repository.loadPage(after = null)).value
        val visible = page.excludingAuthors(setOf(blocked))
        repository.loadNextIfAny(visible)

        assertEquals(13, visible.posts.size)
        assertEquals(page.posts.filterNot { it.userId == blocked }, visible.posts)
        assertFalse(visible.reachedEnd)
        assertSame(raw.cursor, visible.next)
        assertEquals(0, visible.skippedCount)
        assertEquals(2, reader.queries.size)
        assertSame(raw.cursor, (reader.queries[1].first as QuerySpec.PublicFeed).after)
    }

    @Test
    fun `末尾の1件が壊れたページの次の起点は、表示できる最後の1件でなく、生の最後の1件（壊れた投稿）を指す`() = runBlocking {
        val documents = (1 until pageSize).map { postDocument("P$it") } + brokenPostDocument("LAST")
        val raw = rawPage(documents)
        val reader = readerOf(raw)
        val repository = repository(reader)

        val page = assertIs<AppResult.Ok<FeedPage>>(repository.loadPage(after = null)).value

        assertEquals(PostId("P19"), page.posts.last().postId)
        assertSame(raw.cursor, page.next)
    }
}
