// ⭐️ 他人のプロフィールの画面の状態：公開プロフィール・公開投稿だけの一覧（タスク 15.2・要件 10.3〜10.5・16.2・16.3）
package com.yoshidometoru.soramoyou.feature.profile

import androidx.lifecycle.ViewModel
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.repository.ProfileRepository
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.feature.feed.FeedUiState
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** 投稿者のプロフィールを開くときの行き先。自分なら自分のプロフィール、他人なら他人のプロフィール（2026-10-06 ユーザー判断）。 */
sealed interface ProfileDestination {
    data object Own : ProfileDestination
    data class Other(val uid: Uid) : ProfileDestination
}

/** 投稿者 [author] のプロフィールを開くときの行き先。ログイン中のユーザー本人なら [ProfileDestination.Own]。 */
fun profileDestinationOf(author: Uid, session: SessionState): ProfileDestination =
    if ((session as? SessionState.SignedIn)?.uid == author) ProfileDestination.Own else ProfileDestination.Other(author)

/**
 * 他人のプロフィールの画面の ViewModel（iOS の `UserProfileViewModel`）。作った時点で、公開プロフィールと公開投稿の先頭を読む。
 *
 * - 公開プロフィールが無い・中の id が一致しないときは、ProfileRepository が返す代替表示をそのまま出す（失敗ではない）。
 *   取得自体の失敗だけを記録して、再試行付きの失敗にする。
 * - 投稿の一覧は公開投稿だけ（[ProfileRepository.userPublicPostsPage]。公開範囲の条件はクエリの形から外せない：要件 10.5）。
 * - 画面名は送らない（iOS が計測している 4 つの画面に他人のプロフィールは無い：ScreenName）。
 * - ログアウトで状態を捨てる仕組みは持たない。ログアウトするとログイン後のナビゲーションごと捨てられ、この画面には戻れないため
 *   （PostDetailViewModel と同じ）。
 *
 * @param uid 開いたプロフィールの持ち主。
 * @param isOnline 接続の有無（NetworkMonitor.isOnline）。
 * @param scope この ViewModel の viewModelScope。
 */
class UserProfileViewModel(
    private val uid: Uid,
    private val profileRepository: ProfileRepository,
    private val analytics: AnalyticsFacade,
    val isOnline: StateFlow<Boolean>,
    private val scope: CoroutineScope,
) : ViewModel(scope) {

    private val mutableHeader = MutableStateFlow<ProfileHeaderState>(ProfileHeaderState.Loading)

    /** 見出しの状態。 */
    val header: StateFlow<ProfileHeaderState> = mutableHeader.asStateFlow()

    private val loader = ProfilePostsLoader({ profileRepository.userPublicPostsPage(uid, it) }, analytics, isOnline, scope, CONTEXT)

    /** 公開投稿だけの一覧。 */
    val posts: StateFlow<FeedUiState> = loader.state

    /** 見出しを読み込み中か（二重の取得を防ぐ）。 */
    private var loadingHeader = false

    init {
        loadHeader()
        loader.refresh()
    }

    /** 引っ張って更新：見出しと投稿の一覧を読み直す。 */
    fun refresh() {
        loadHeader()
        loader.refresh()
    }

    /** 投稿の続きを読む。 */
    fun loadMore() {
        loader.loadMore()
    }

    /** 見出しの失敗の後に、見出しだけを読み直す。 */
    fun retryHeader() {
        loadHeader()
    }

    private fun loadHeader() {
        if (loadingHeader) return
        loadingHeader = true
        // 読み直しでは、表示中の見出しを残したまま読む（引っ張って更新で一瞬消えないように）。失敗の後だけ読み込み中に戻す
        if (mutableHeader.value is ProfileHeaderState.Failed) mutableHeader.value = ProfileHeaderState.Loading
        scope.launch {
            val next = when (val result = profileRepository.fetchPublic(uid)) {
                is AppResult.Ok -> headerOf(result.value)
                is AppResult.Err -> {
                    analytics.logError(result.error, "$CONTEXT.fetchPublic")
                    ProfileHeaderState.Failed(result.error, failedWhileOffline = !isOnline.value)
                }
            }
            loadingHeader = false
            mutableHeader.value = next
        }
    }

    private companion object {
        /** 記録の発生箇所の前置き。 */
        const val CONTEXT = "UserProfileViewModel"
    }
}
