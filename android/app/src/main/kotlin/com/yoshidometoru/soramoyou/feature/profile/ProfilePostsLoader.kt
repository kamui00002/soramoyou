// ⭐️ プロフィールの投稿一覧の読み込み：先頭から・続き・0 件のページの先読み・失敗の表示と記録（タスク 15.2・要件 10.2・10.4・16.2・16.3）
package com.yoshidometoru.soramoyou.feature.profile

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.remote.read.RawCursor
import com.yoshidometoru.soramoyou.data.repository.FeedPage
import com.yoshidometoru.soramoyou.feature.feed.FeedUiState
import com.yoshidometoru.soramoyou.feature.feed.FeedViewModel
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * 自分・他人のプロフィールの投稿一覧の読み込み。状態はフィードと同じ [FeedUiState] で持ち、表示も同じ
 * [com.yoshidometoru.soramoyou.feature.feed.feedContentOf] で決める（一覧の規則をフィードと揃えるため）。
 *
 * 規則は FeedViewModel と同じで、ブロックの除外だけが無い（プロフィールの投稿は 1 人のものなので）。
 * - 続きの有無は、ページの [FeedPage.reachedEnd]（変換前に読んだ件数で決まる）だけで決める。
 * - 壊れた投稿だけで表示が 0 件になったページで、まだ続きがあれば、続けて次のページを読む（最大 [FeedViewModel.MAX_EMPTY_PAGE_FOLLOW_UPS]）。
 * - 取得の失敗は、ここで記録して表示する（ProfileRepository は記録しない）。
 * - 先頭から読み直すたび（と [reset]）に世代を 1 進め、古い世代の結果は捨てる。
 *
 * @param loadPage 1 ページの取得（ProfileRepository の ownPostsPage か userPublicPostsPage）。
 * @param isOnline 接続の有無。失敗した時点の値を [FeedUiState.failedWhileOffline] に残す。
 * @param scope 持ち主の ViewModel の viewModelScope。
 * @param context 記録の発生箇所の前置き（`クラス名`）。`.refresh`・`.loadMore` を付けて記録する。
 */
internal class ProfilePostsLoader(
    private val loadPage: suspend (RawCursor?) -> AppResult<FeedPage>,
    private val analytics: AnalyticsFacade,
    private val isOnline: StateFlow<Boolean>,
    private val scope: CoroutineScope,
    private val context: String,
) {

    private val mutableState = MutableStateFlow(FeedUiState())

    val state: StateFlow<FeedUiState> = mutableState.asStateFlow()

    /** 先頭から読み直すたび（と [reset]）に 1 進める。取得を始めたときの値と違えば、その結果は捨てる。 */
    private var generation = 0L

    /** 一覧を空にし、取得中の結果も書き戻さない（ログアウト・別のアカウントへの切り替え）。 */
    fun reset() {
        generation++
        mutableState.value = FeedUiState()
    }

    /**
     * 自分が作った投稿 [post] を一覧の先頭に差し込む（要件 7.22・タスク 23.3。読み直さない）。既に一覧にあれば何もしない。
     * 誰の投稿かは確かめない（自分のプロフィールの ViewModel が、いまのユーザーの投稿のときだけ呼ぶ）。
     */
    fun insertFirst(post: PostView) {
        mutableState.update { state ->
            if (state.posts.any { it.postId == post.postId }) state else state.copy(posts = listOf(post) + state.posts)
        }
    }

    /**
     * 自分が消した投稿 [postId] を一覧から除く（要件 10.11・タスク 24。読み直さない）。一覧に無ければ何もしない。
     * 誰の投稿かは確かめない（消せるのは自分の投稿だけで、他人のプロフィールの一覧には、もともと入っていない）。
     */
    fun remove(postId: PostId) {
        mutableState.update { state -> state.copy(posts = state.posts.filterNot { it.postId == postId }) }
    }

    /** 先頭から読み直して置き換える（最初の表示・引っ張って更新・全面の再試行）。取得中の続きの結果は捨てる。 */
    fun refresh() {
        val gen = ++generation
        mutableState.update { it.copy(isRefreshing = true, isLoadingMore = false, error = null, failedWhileOffline = false) }
        scope.launch { load(after = null, gen = gen, where = "$context.refresh") }
    }

    /** 続きを読んで末尾に足す。取得中・続きなし・先頭から読み直している間は何もしない。続きの失敗の再試行もこれ。 */
    fun loadMore() {
        val current = mutableState.value
        if (current.isLoadingMore || current.isRefreshing || current.reachedEnd) return
        val gen = generation
        mutableState.update { it.copy(isLoadingMore = true, error = null, failedWhileOffline = false) }
        scope.launch { load(after = current.next, gen = gen, where = "$context.loadMore") }
    }

    /** [after] から 1 ページ読み、表示が 0 件で続きがあれば上限まで続けて読む（FeedViewModel.load と同じ流れ）。 */
    private suspend fun load(after: RawCursor?, gen: Long, where: String) {
        var cursor = after
        var followUps = 0
        while (true) {
            val result = loadPage(cursor)
            if (gen != generation) return
            when (result) {
                is AppResult.Err -> {
                    analytics.logError(result.error, where)
                    val offline = !isOnline.value
                    mutableState.update {
                        it.copy(
                            // 先頭からの取得の失敗では古い一覧を残さない（フィードと同じ）
                            posts = if (cursor == null) emptyList() else it.posts,
                            next = if (cursor == null) null else it.next,
                            reachedEnd = if (cursor == null) false else it.reachedEnd,
                            isRefreshing = false,
                            isLoadingMore = false,
                            error = result.error,
                            failedWhileOffline = offline,
                        )
                    }
                    return
                }
                is AppResult.Ok -> {
                    val page = result.value
                    val replace = cursor == null
                    mutableState.update {
                        it.copy(
                            posts = if (replace) page.posts else it.posts + page.posts,
                            next = page.next,
                            reachedEnd = page.reachedEnd,
                        )
                    }
                    // 表示が 0 件で続きがあるページだけ、上限まで続けて読む（続きの有無はページの reachedEnd だけで決める）
                    if (page.posts.isNotEmpty() || page.reachedEnd || followUps >= FeedViewModel.MAX_EMPTY_PAGE_FOLLOW_UPS) break
                    followUps++
                    cursor = page.next
                }
            }
        }
        mutableState.update { it.copy(isRefreshing = false, isLoadingMore = false) }
    }
}
