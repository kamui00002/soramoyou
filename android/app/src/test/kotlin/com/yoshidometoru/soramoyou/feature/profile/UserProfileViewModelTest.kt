// ⭐️ 他人のプロフィールの画面の状態と、投稿者のプロフィールの行き先の単体テスト（タスク 15.2・要件 5.3・10.3〜10.5）
package com.yoshidometoru.soramoyou.feature.profile

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.PublicProfileView
import com.yoshidometoru.soramoyou.data.remote.read.RawCursor
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.feature.RecordingFeatureAnalytics
import com.yoshidometoru.soramoyou.feature.feed.page
import com.yoshidometoru.soramoyou.feature.feed.posts
import com.yoshidometoru.soramoyou.feature.immediateScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

class UserProfileViewModelTest {

    private val repository = FakeProfileRepository()
    private val analytics = RecordingFeatureAnalytics()
    private val online = MutableStateFlow(true)
    private val target = Uid("someone")

    private fun viewModel() = UserProfileViewModel(target, repository, analytics, online, immediateScope())

    private fun profile(name: String? = "くも") = PublicProfileView(
        uid = target,
        author = name?.let { AuthorDisplay.Named(it, "https://example.com/a.jpg") } ?: AuthorDisplay.Fallback(null),
        bio = "雲を集めています",
        postsCount = 12,
    )

    @Test
    fun `作った時点でその人の公開プロフィールと公開投稿の先頭を読む`() {
        val vm = viewModel()

        assertEquals(listOf(target), repository.publicProfiles.calls)
        assertEquals(listOf<Pair<Uid, RawCursor?>>(target to null), repository.publicPages.calls)
        assertEquals(ProfileHeaderState.Loading, vm.header.value)
    }

    @Test
    fun `公開プロフィールの名前・アイコン・自己紹介・投稿数と、公開投稿の一覧を出す`() {
        val vm = viewModel()
        repository.publicProfiles.completeLast(AppResult.Ok(profile()))
        repository.publicPages.completeLast(page(posts("p", 3), reachedEnd = true))

        assertEquals(ProfileHeaderState.Shown(AuthorDisplay.Named("くも", "https://example.com/a.jpg"), "雲を集めています", 12), vm.header.value)
        assertEquals(posts("p", 3), vm.posts.value.posts)
    }

    @Test
    fun `公開プロフィールが無い（代替表示）ときは「ユーザー」を出し、失敗として記録しない`() {
        val vm = viewModel()
        repository.publicProfiles.completeLast(AppResult.Ok(PublicProfileView.fallback(target)))

        assertEquals("ユーザー", assertIs<ProfileHeaderState.Shown>(vm.header.value).author.name)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `公開プロフィールの取得の失敗は記録して再試行付きの失敗にし、再試行で読み直す`() {
        val vm = viewModel()
        repository.publicProfiles.completeLast(AppResult.Err(AppError.Network))

        assertEquals(ProfileHeaderState.Failed(AppError.Network, failedWhileOffline = false), vm.header.value)
        assertEquals(listOf<Pair<AppError, String>>(AppError.Network to "UserProfileViewModel.fetchPublic"), analytics.errors)

        vm.retryHeader()
        assertEquals(ProfileHeaderState.Loading, vm.header.value)
        repository.publicProfiles.completeLast(AppResult.Ok(profile()))
        assertIs<ProfileHeaderState.Shown>(vm.header.value)
        assertEquals(2, repository.publicProfiles.calls.size)
    }

    @Test
    fun `見出しの取得中の再試行は二重に読まない`() {
        val vm = viewModel()
        vm.retryHeader()

        assertEquals(1, repository.publicProfiles.calls.size)
    }

    @Test
    fun `引っ張って更新では見出しを残したまま、見出しと一覧を読み直す`() {
        val vm = viewModel()
        repository.publicProfiles.completeLast(AppResult.Ok(profile(name = "くも")))
        repository.publicPages.completeLast(page(posts("p", 3), reachedEnd = true))

        vm.refresh()

        assertEquals("くも", assertIs<ProfileHeaderState.Shown>(vm.header.value).author.name)
        assertEquals(2, repository.publicProfiles.calls.size)
        assertEquals(target to null, repository.publicPages.calls.last())
    }

    @Test
    fun `画面名は送らない`() {
        val vm = viewModel()
        repository.publicProfiles.completeLast(AppResult.Ok(profile()))

        assertEquals(emptyList(), analytics.screens)
        assertIs<ProfileHeaderState.Shown>(vm.header.value)
    }

    // ── 投稿者のプロフィールの行き先（要件 5.3・2026-10-06 ユーザー判断）──

    @Test
    fun `投稿者がログイン中の本人なら自分のプロフィール、それ以外は他人のプロフィールへ行く`() {
        val me = SessionState.SignedIn(Uid("me"), "me@example.com", isAnonymous = false)

        assertEquals(ProfileDestination.Own, profileDestinationOf(Uid("me"), me))
        assertEquals(ProfileDestination.Other(Uid("you")), profileDestinationOf(Uid("you"), me))
        assertEquals(ProfileDestination.Other(Uid("me")), profileDestinationOf(Uid("me"), SessionState.SignedOut))
    }
}
