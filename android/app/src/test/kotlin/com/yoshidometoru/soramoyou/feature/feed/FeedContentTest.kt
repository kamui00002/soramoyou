// ⭐️ フィードの画面にどの表示を出すかの単体テスト（タスク 9.4・要件 4.12・4.13・16.2・16.3）
package com.yoshidometoru.soramoyou.feature.feed

import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import kotlin.test.Test
import kotlin.test.assertEquals

class FeedContentTest {

    @Test
    fun `投稿が無く読み込み中なら、読み込み中を出す`() {
        assertEquals(FeedContent.LOADING, feedContentOf(FeedUiState(isRefreshing = true)))
    }

    @Test
    fun `投稿が無く、続きなしと分かったときだけ、投稿が無いことを出す`() {
        assertEquals(FeedContent.EMPTY, feedContentOf(FeedUiState(reachedEnd = true)))
        // 0 件のページの先読みを上限で止めた（まだ続きがある）ときは、0 件の表示にしない
        assertEquals(FeedContent.LIST, feedContentOf(FeedUiState(reachedEnd = false)))
    }

    @Test
    fun `投稿が無いときの失敗は、失敗した時点の接続でエラーかオフラインを出す`() {
        assertEquals(FeedContent.ERROR, feedContentOf(FeedUiState(error = AppError.Network)))
        assertEquals(FeedContent.OFFLINE, feedContentOf(FeedUiState(error = AppError.Network, failedWhileOffline = true)))
    }

    @Test
    fun `投稿があるときは、失敗しても一覧を出す（失敗は一覧の末尾に出す）`() {
        assertEquals(FeedContent.LIST, feedContentOf(FeedUiState(posts = posts("a", 1), error = AppError.Network)))
        assertEquals(FeedContent.LIST, feedContentOf(FeedUiState(posts = posts("a", 1), isRefreshing = true)))
    }

    @Test
    fun `失敗の見出しは、通信・権限・それ以外で iOS の ErrorStateView の見出しを使う`() {
        assertEquals(R.string.offline_title, feedErrorMessageRes(AppError.Network))
        assertEquals(R.string.state_error_permission, feedErrorMessageRes(AppError.PermissionDenied))
        assertEquals(R.string.state_error_title, feedErrorMessageRes(AppError.Unknown("x")))
        assertEquals(R.string.state_error_title, feedErrorMessageRes(AppError.NotFound))
    }
}
