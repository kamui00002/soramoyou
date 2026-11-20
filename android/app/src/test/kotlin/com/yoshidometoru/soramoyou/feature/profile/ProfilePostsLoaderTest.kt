// ⭐️ プロフィールの投稿一覧の読み込みの単体テスト（タスク 15.2・要件 10.2・10.4・16.3）
package com.yoshidometoru.soramoyou.feature.profile

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.data.remote.read.RawCursor
import com.yoshidometoru.soramoyou.data.repository.FeedPage
import com.yoshidometoru.soramoyou.feature.RecordingFeatureAnalytics
import com.yoshidometoru.soramoyou.feature.feed.FeedContent
import com.yoshidometoru.soramoyou.feature.feed.FeedViewModel
import com.yoshidometoru.soramoyou.feature.feed.cursor
import com.yoshidometoru.soramoyou.feature.feed.feedContentOf
import com.yoshidometoru.soramoyou.feature.feed.page
import com.yoshidometoru.soramoyou.feature.feed.posts
import com.yoshidometoru.soramoyou.feature.immediateScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

class ProfilePostsLoaderTest {

    private val pages = PendingCalls<RawCursor?, AppResult<FeedPage>>()
    private val analytics = RecordingFeatureAnalytics()
    private val online = MutableStateFlow(true)

    private fun loader() = ProfilePostsLoader({ pages.call(it) }, analytics, online, immediateScope(), "Owner")

    @Test
    fun `続きは前のページの生の起点から読んで末尾に足し、続きの有無はページの印だけで決める`() {
        val loader = loader()
        val first = cursor("first")
        loader.refresh()
        // 満杯でない（変換で 3 件落ちた）ページでも、ページが続きありと言えば続きを読める
        pages.completeLast(page(posts("a", 47), next = first, skipped = 3))
        assertFalse(loader.state.value.reachedEnd)

        loader.loadMore()
        pages.completeLast(page(posts("b", 5), reachedEnd = true))

        assertSame(first, pages.calls[1])
        assertEquals(posts("a", 47) + posts("b", 5), loader.state.value.posts)
        assertTrue(loader.state.value.reachedEnd)
        loader.loadMore()
        assertEquals(2, pages.calls.size)
    }

    @Test
    fun `表示が0件で続きがあるページの後は、上限まで続けて読む`() {
        val loader = loader()
        loader.refresh()
        repeat(FeedViewModel.MAX_EMPTY_PAGE_FOLLOW_UPS + 1) { pages.completeLast(page(emptyList(), skipped = 50)) }

        assertEquals(FeedViewModel.MAX_EMPTY_PAGE_FOLLOW_UPS + 1, pages.calls.size)
        assertFalse(loader.state.value.isRefreshing)
        assertFalse(loader.state.value.reachedEnd)
        assertEquals(FeedContent.LIST, feedContentOf(loader.state.value))
    }

    @Test
    fun `表示が0件で続きが無いページなら「投稿がありません」になる`() {
        val loader = loader()
        loader.refresh()
        pages.completeLast(page(emptyList(), reachedEnd = true))

        assertEquals(1, pages.calls.size)
        assertEquals(FeedContent.EMPTY, feedContentOf(loader.state.value))
    }

    @Test
    fun `先頭の取得の失敗は記録し、オフラインで失敗したらオフラインの表示にする`() {
        val loader = loader()
        online.value = false
        loader.refresh()
        pages.completeLast(AppResult.Err(AppError.Network))

        assertEquals(FeedContent.OFFLINE, feedContentOf(loader.state.value))
        assertEquals(listOf<Pair<AppError, String>>(AppError.Network to "Owner.refresh"), analytics.errors)
    }

    @Test
    fun `続きの失敗は一覧を残して記録し、続きの再試行で同じ起点から読み直す`() {
        val loader = loader()
        val first = cursor("first")
        loader.refresh()
        pages.completeLast(page(posts("a", 50), next = first))
        loader.loadMore()
        pages.completeLast(AppResult.Err(AppError.Network))

        assertEquals(posts("a", 50), loader.state.value.posts)
        assertEquals(AppError.Network to "Owner.loadMore", analytics.errors.single())

        loader.loadMore()
        assertSame(first, pages.calls[2])
    }

    @Test
    fun `空にしたら、取得中の結果を書き戻さない`() {
        val loader = loader()
        loader.refresh()
        loader.reset()
        pages.completeLast(page(posts("a", 2)))

        assertEquals(emptyList(), loader.state.value.posts)
        assertFalse(loader.state.value.isRefreshing)
    }
}
