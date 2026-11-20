// ⭐️ 自分のプロフィールの画面の状態の単体テスト（タスク 15.2・要件 3.7・10.1〜10.3・15.4・16.2）
package com.yoshidometoru.soramoyou.feature.profile

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.OwnProfile
import com.yoshidometoru.soramoyou.data.remote.read.RawCursor
import com.yoshidometoru.soramoyou.data.remote.write.Milestone
import com.yoshidometoru.soramoyou.data.remote.write.writeCapabilitiesOf
import com.yoshidometoru.soramoyou.data.repository.CreatedPosts
import com.yoshidometoru.soramoyou.data.repository.DeletedPosts
import com.yoshidometoru.soramoyou.data.repository.ProfileRepository
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.feature.RecordingFeatureAnalytics
import com.yoshidometoru.soramoyou.feature.feed.page
import com.yoshidometoru.soramoyou.feature.feed.post
import com.yoshidometoru.soramoyou.feature.feed.posts
import com.yoshidometoru.soramoyou.feature.immediateScope
import com.yoshidometoru.soramoyou.platform.ScreenName
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * 偽物の取得は、テストが結果を渡すまで待つ。スコープは Unconfined なので、結果を渡すとその場で続きが進む。
 * 監視は [FakeProfileRepository.ownFlows] に 1 本ずつ残るので、張り直した回数と、止めたか（`subscriptionCount`）を見られる。
 */
class ProfileViewModelTest {

    private val repository = FakeProfileRepository()
    private val repairer = FakeAccountDocumentRepairer()
    private val analytics = RecordingFeatureAnalytics()
    private val online = MutableStateFlow(true)
    private val session = MutableStateFlow<SessionState>(signedIn("me"))

    private fun signedIn(uid: String, email: String = "$uid@example.com") = SessionState.SignedIn(Uid(uid), email, isAnonymous = false)

    private fun viewModel(
        enabled: Set<WriteCapability> = setOf(WriteCapability.ACCOUNT_REPAIR),
        created: CreatedPosts = CreatedPosts(),
        deleted: DeletedPosts = DeletedPosts(),
        profileRepository: ProfileRepository = repository,
    ) = ProfileViewModel(profileRepository, repairer, FakeWriteGate(enabled), analytics, online, session, immediateScope(), created.events, deleted.events)

    // ── 作った時点（要件 10.1・10.2・3.7・16.2）──

    @Test
    fun `作った時点で自分のユーザー文書の監視と補完と投稿の先頭の取得を1回ずつ始め、見出しは読み込み中`() {
        val vm = viewModel()

        assertEquals(1, repository.ownFlows.size)
        assertEquals(1, repairer.calls)
        assertEquals(listOf<RawCursor?>(null), repository.ownPages.calls)
        assertEquals(ProfileHeaderState.Loading, vm.header.value)
        assertTrue(vm.posts.value.isRefreshing)
    }

    @Test
    fun `補完が無効なビルドでは補完を呼ばない（監視と投稿の取得はする）`() {
        viewModel(enabled = emptySet())

        assertEquals(0, repairer.calls)
        assertEquals(1, repository.ownFlows.size)
        assertEquals(1, repository.ownPages.calls.size)
    }

    @Test
    fun `プロフィール編集の導線は、編集の書き込みが有効なビルドでだけ出す`() {
        assertFalse(viewModel(enabled = writeCapabilitiesOf(Milestone.M1)).canEdit)
        assertFalse(viewModel(enabled = setOf(WriteCapability.ACCOUNT_REPAIR)).canEdit)
        assertTrue(viewModel(enabled = setOf(WriteCapability.PROFILE_EDIT)).canEdit)
    }

    @Test
    fun `未ログインで作ったら監視も補完も取得もしない`() {
        session.value = SessionState.SignedOut
        val vm = viewModel()

        assertEquals(0, repository.ownFlows.size)
        assertEquals(0, repairer.calls)
        assertEquals(0, repository.ownPages.calls.size)
        assertEquals(ProfileHeaderState.Loading, vm.header.value)
    }

    // ── 見出し（要件 10.1・10.3）──

    @Test
    fun `ユーザー文書が届いたら名前・アイコン・自己紹介・投稿数を出す`() {
        val vm = viewModel()
        repository.emitOwn(AppResult.Ok(ownProfile(name = "そら", bio = "空が好き", postsCount = 7)))

        val header = assertIs<ProfileHeaderState.Shown>(vm.header.value)
        assertEquals(AuthorDisplay.Named("そら", "https://example.com/me.jpg"), header.author)
        assertEquals("空が好き", header.bio)
        assertEquals(7L, header.postsCount)
    }

    @Test
    fun `表示名が空白だけなら名前は代替表示「ユーザー」にし、uidを名前に使わない`() {
        val vm = viewModel()
        repository.emitOwn(AppResult.Ok(ownProfile(name = "  ")))

        val header = assertIs<ProfileHeaderState.Shown>(vm.header.value)
        assertEquals("ユーザー", header.author.name)
    }

    @Test
    fun `文書が無いときは代替の見出しを出して記録せず、補完で作られて届いたら見出しを差し替える`() {
        val vm = viewModel()
        repository.emitOwn(AppResult.Err(AppError.NotFound))

        assertEquals(MISSING_OWN_HEADER, vm.header.value)
        assertEquals(emptyList(), analytics.errors)

        repository.emitOwn(AppResult.Ok(ownProfile(name = "そら")))
        assertEquals("そら", assertIs<ProfileHeaderState.Shown>(vm.header.value).author.name)
    }

    @Test
    fun `文書が無い以外の監視の失敗は記録して再試行付きの失敗にし、再試行で監視だけを張り直す`() {
        val vm = viewModel()
        online.value = false
        repository.emitOwn(AppResult.Err(AppError.Network))

        assertEquals(ProfileHeaderState.Failed(AppError.Network, failedWhileOffline = true), vm.header.value)
        assertEquals(listOf<Pair<AppError, String>>(AppError.Network to "ProfileViewModel.observeOwn"), analytics.errors)

        vm.retryHeader()
        assertEquals(2, repository.ownFlows.size)
        assertEquals(ProfileHeaderState.Loading, vm.header.value)
        assertEquals(1, repairer.calls)
        repository.emitOwn(AppResult.Ok(ownProfile(name = "そら")))
        assertIs<ProfileHeaderState.Shown>(vm.header.value)
    }

    @Test
    fun `監視がNetworkを流して終わっても失敗のまま残り、接続が戻っても自動では張り直さず、再試行で張り直す`() {
        // レビュー R17：オフラインでキャッシュに無い自分の文書は、監視が Err(Network) を 1 回流して終わる（FirebaseFirestoreReadClient と
        // DefaultFirestoreReader の observe）。FakeProfileRepository の監視は終わらないので、終わる形を EndsAfterFirstObserve で作る。
        // 再試行は押したときだけ（offlineRetryState・UserProfileViewModel と同じ。設計書は自動の再試行を決めていない）
        val ending = EndsAfterFirstObserve(repository, AppResult.Err(AppError.Network))
        online.value = false
        val vm = viewModel(profileRepository = ending)

        assertEquals(ProfileHeaderState.Failed(AppError.Network, failedWhileOffline = true), vm.header.value)
        assertEquals(1, ending.observeCalls)

        online.value = true
        assertEquals(ProfileHeaderState.Failed(AppError.Network, failedWhileOffline = true), vm.header.value)
        assertEquals(1, ending.observeCalls, "接続が戻っただけでは張り直さない")

        vm.retryHeader()
        assertEquals(2, ending.observeCalls)
        assertEquals(ProfileHeaderState.Loading, vm.header.value)
        repository.emitOwn(AppResult.Ok(ownProfile(name = "そら")))
        assertEquals("そら", assertIs<ProfileHeaderState.Shown>(vm.header.value).author.name)
    }

    @Test
    fun `失敗していないときの再試行は何もしない`() {
        val vm = viewModel()
        repository.emitOwn(AppResult.Ok(ownProfile()))

        vm.retryHeader()

        assertEquals(1, repository.ownFlows.size)
    }

    // ── 画面名（要件 15.4）──

    @Test
    fun `画面の表示のたびに画面名「プロフィール」を送る`() {
        val vm = viewModel()
        vm.onScreenShown()
        vm.onScreenShown()

        assertEquals(listOf(ScreenName.PROFILE, ScreenName.PROFILE), analytics.screens)
    }

    // ── ログアウト・アカウントの切り替え ──

    @Test
    fun `ログアウトしたら監視を止めて状態を捨て、古い監視や取得の結果を書き戻さない`() {
        val vm = viewModel()
        repository.emitOwn(AppResult.Ok(ownProfile()))
        val oldFlow = repository.ownFlows.last()

        session.value = SessionState.SignedOut

        assertEquals(0, oldFlow.subscriptionCount.value)
        assertEquals(ProfileHeaderState.Loading, vm.header.value)
        oldFlow.tryEmit(AppResult.Ok(ownProfile(name = "古い")))
        repository.ownPages.completeLast(page(posts("old", 2)))
        assertEquals(ProfileHeaderState.Loading, vm.header.value)
        assertEquals(emptyList(), vm.posts.value.posts)
        assertEquals(1, repository.ownFlows.size)
    }

    @Test
    fun `別のユーザーでログインし直したら監視・補完・投稿の取得を集め直す`() {
        val vm = viewModel()
        repository.emitOwn(AppResult.Ok(ownProfile(uid = "me")))
        repository.ownPages.completeLast(page(posts("me", 2)))

        session.value = SessionState.SignedOut
        session.value = signedIn("other")

        assertEquals(2, repository.ownFlows.size)
        assertEquals(2, repairer.calls)
        assertEquals(listOf<RawCursor?>(null, null), repository.ownPages.calls)
        assertEquals(emptyList(), vm.posts.value.posts)
        repository.emitOwn(AppResult.Ok(ownProfile(uid = "other", name = "べつ")))
        assertEquals("べつ", assertIs<ProfileHeaderState.Shown>(vm.header.value).author.name)
    }

    @Test
    fun `同じユーザーのままの認証状態の通知では集め直さない`() {
        viewModel()
        session.value = signedIn("me", email = "changed@example.com")

        assertEquals(1, repository.ownFlows.size)
        assertEquals(1, repairer.calls)
        assertEquals(1, repository.ownPages.calls.size)
    }

    // ── 投稿の一覧（要件 10.2・16.3）──

    @Test
    fun `投稿の一覧は自分の投稿のページを読み、引っ張って更新で先頭から読み直す`() {
        val vm = viewModel()
        repository.ownPages.completeLast(page(posts("a", 2), reachedEnd = true))
        assertEquals(posts("a", 2), vm.posts.value.posts)

        vm.refresh()
        repository.ownPages.completeLast(page(posts("b", 1), reachedEnd = true))

        assertEquals(listOf<RawCursor?>(null, null), repository.ownPages.calls)
        assertEquals(posts("b", 1), vm.posts.value.posts)
        assertEquals(1, repository.ownFlows.size)
    }

    @Test
    fun `投稿の取得の失敗は発生箇所つきで記録する`() {
        val vm = viewModel()
        repository.ownPages.completeLast(AppResult.Err(AppError.PermissionDenied))

        assertEquals(AppError.PermissionDenied, vm.posts.value.error)
        assertEquals(listOf<Pair<AppError, String>>(AppError.PermissionDenied to "ProfileViewModel.refresh"), analytics.errors)
    }

    // ── 自分が作った投稿の差し込み（要件 7.22・タスク 23.3）──

    @Test
    fun `自分が作った投稿は公開範囲によらず、読み直さずに投稿の一覧の先頭に差し込む`() {
        val created = CreatedPosts()
        val vm = viewModel(created = created)
        repository.ownPages.completeLast(page(posts("a", 2), reachedEnd = true))
        val mine = post("new", "me").copy(visibility = Visibility.PRIVATE)

        created.notify(mine)

        assertEquals(listOf(mine) + posts("a", 2), vm.posts.value.posts)
        assertEquals(1, repository.ownPages.calls.size, "読み直さない")
        assertEquals(1, repository.ownFlows.size, "見出しの監視も張り直さない")
    }

    @Test
    fun `いまのユーザーの投稿でなければ差し込まず、既に一覧にある投稿も差し込まない`() {
        val created = CreatedPosts()
        val vm = viewModel(created = created)
        val shown = post("shown", "me")
        repository.ownPages.completeLast(page(listOf(shown), reachedEnd = true))

        created.notify(post("other", "someone"))
        created.notify(shown.copy(caption = "同じ投稿"))
        assertEquals(listOf(shown), vm.posts.value.posts)

        session.value = SessionState.SignedOut
        created.notify(post("late", "me"))
        assertEquals(emptyList(), vm.posts.value.posts)
    }

    // ── 自分が消した投稿の除去（要件 10.11・タスク 24）──

    @Test
    fun `自分が消した投稿は、読み直さずに投稿の一覧から除き、一覧に無い投稿の知らせでは何も変えない`() {
        val deleted = DeletedPosts()
        val vm = viewModel(deleted = deleted)
        repository.ownPages.completeLast(page(posts("a", 3), reachedEnd = true))

        deleted.notify(PostId("a-0"))
        assertEquals(posts("a", 3).drop(1), vm.posts.value.posts)

        deleted.notify(PostId("not-shown"))
        assertEquals(posts("a", 3).drop(1), vm.posts.value.posts)
        assertEquals(1, repository.ownPages.calls.size, "読み直さない")
        assertEquals(1, repository.ownFlows.size, "見出しの監視も張り直さない")
    }
}

/**
 * 自分の監視の 1 回目だけ、本物の読み取りの入口と同じく [first] を 1 回流して終わる流れにする（レビュー R17）。
 * 2 回目からの監視と、ほかの取得は [inner] に任せる。
 */
private class EndsAfterFirstObserve(
    private val inner: FakeProfileRepository,
    private val first: AppResult<OwnProfile>,
) : ProfileRepository by inner {
    var observeCalls = 0

    override fun observeOwn(): Flow<AppResult<OwnProfile>> {
        observeCalls++
        return if (observeCalls == 1) flowOf(first) else inner.observeOwn()
    }
}
