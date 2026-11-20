// ⭐️ 自分のプロフィールの画面の状態：ユーザー文書の監視・アカウント文書の補完・自分の投稿の一覧・画面名（タスク 15.2・要件 10.1〜10.3・15.4・16.2）
package com.yoshidometoru.soramoyou.feature.profile

import androidx.lifecycle.ViewModel
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.OwnProfile
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.model.PublicProfileView
import com.yoshidometoru.soramoyou.data.remote.write.WriteGate
import com.yoshidometoru.soramoyou.data.repository.AccountDocumentRepairer
import com.yoshidometoru.soramoyou.data.repository.ProfileRepository
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.feature.feed.FeedUiState
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.ScreenName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

/** プロフィールの見出し（名前・アイコン・自己紹介・投稿数）の状態。自分と他人で同じ形にして、画面を 1 つにする。 */
sealed interface ProfileHeaderState {

    /** 読み込み中（要件 16.2）。 */
    data object Loading : ProfileHeaderState

    /**
     * 表示する見出し。名前が無いときは [AuthorDisplay.Fallback]（「ユーザー」）で、uid などを名前に使わない（要件 10.3）。
     * @property bio 自己紹介。無いか空白だけなら画面は出さない。
     */
    data class Shown(val author: AuthorDisplay, val bio: String?, val postsCount: Long) : ProfileHeaderState

    /**
     * 取得自体の失敗（通信断・権限など）。再試行を出す。
     * @property failedWhileOffline 失敗した時点でオフラインだったか（OfflineContent を出すのはこのときだけ：StateContents.kt の契約）。
     */
    data class Failed(val error: AppError, val failedWhileOffline: Boolean) : ProfileHeaderState
}

/** 自分のユーザー文書の見出し。表示名の代替表示は [OwnProfile.display] に任せる。 */
internal fun headerOf(profile: OwnProfile): ProfileHeaderState.Shown =
    ProfileHeaderState.Shown(profile.display, profile.bio, profile.postsCount)

/** 他人の公開プロフィールの見出し（無い・id 不一致の代替表示も、ProfileRepository が作った形のまま出す）。 */
internal fun headerOf(profile: PublicProfileView): ProfileHeaderState.Shown =
    ProfileHeaderState.Shown(profile.author, profile.bio, profile.postsCount)

/** 自分のユーザー文書が無いときの見出し（補完で作られるまで・補完できないビルド）。名前は「ユーザー」、投稿数は 0。 */
internal val MISSING_OWN_HEADER = ProfileHeaderState.Shown(AuthorDisplay.Fallback(null), bio = null, postsCount = 0L)

/**
 * 自分のプロフィールの画面の ViewModel（設計書の部品 ProfileRepository の使い手。iOS の `ProfileView`）。
 *
 * - ログイン中のユーザーが変わるたび（[session] の uid が変わるたび）に、前の監視・補完・投稿の取得を止めて状態を捨て、集め直す。
 *   ログアウトでも、監視の `Err` を待たずにその場で捨てる（FeedViewModel と同じく SessionManager には登録せず、自分で捨てる）。
 * - ユーザー文書は [ProfileRepository.observeOwn] で監視し続ける。文書が無い（`Err(NotFound)`）ときは [MISSING_OWN_HEADER] を出す。
 *   補完が文書を作れば、監視が次に `Ok` を流して見出しが変わる。それ以外の `Err` は記録して、再試行付きの失敗にする。
 *   オフラインでキャッシュに無いときは、監視が `Err(Network)` を流して終わるので失敗になる（「ユーザー・投稿数 0」に化けない。レビュー R17）。
 *   接続が戻っても自動では張り直さず、再試行を押したときだけ張り直す（offlineRetryState・UserProfileViewModel と同じ）。
 * - 欠けているアカウント文書の補完（タスク 14.3）は、ログインしたユーザーごとに 1 回だけ、監視と並べて呼ぶ（要件 3.7：`users` があっても
 *   `publicProfiles` が無い旧アカウントを補うため、文書の有無にかかわらず呼ぶ）。結果は表示しない（失敗の記録は補完の部品が済ませる）。
 *   補完が無効なビルド（M1）では呼ばない。呼んでも Firebase には届かないが、書き込みの入口が `WriteBlocked` を毎回記録するため。
 * - 画面名「プロフィール」は [onScreenShown] で送る（要件 15.4。画面が呼ぶのは戻る履歴の 1 枚ごとに 1 回。iOS はタブの切り替えのたびに送る）。
 * - 自分が作った投稿は、知らせ（[createdPosts]）を受けて投稿の一覧の先頭に差し込む（要件 7.22・タスク 23.3。公開範囲によらない）。
 *   iOS は知らせを受けて見出しと一覧を読み直すが、Android は差し込むだけにする（2026-10-10 ユーザー判断）。
 *   見出しの投稿数は、投稿数の数え直しがユーザー文書を書き換えるので、監視が届けて変わる。
 *   いまのユーザーの投稿でなければ差し込まない（ログアウトの直後や、別のアカウントへ切り替えた直後に届いた知らせ）。
 * - 自分が消した投稿は、知らせ（[deletedPosts]）を受けて投稿の一覧から除く（要件 10.11・タスク 24。読み直さない）。
 *   見出しの投稿数は、作ったときと同じく監視が届けて変わる。
 *
 * @param isOnline 接続の有無（NetworkMonitor.isOnline）。
 * @param session 認証状態。uid が変わったら集め直し、未ログインになったら捨てる。
 * @param scope この ViewModel の viewModelScope（RootViewModel と同じ理由で外から渡す）。
 * @param createdPosts 自分が作った投稿の知らせ（CreatedPosts.events）。
 * @param deletedPosts 自分が消した投稿の知らせ（DeletedPosts.events）。
 */
class ProfileViewModel(
    private val profileRepository: ProfileRepository,
    private val repairer: AccountDocumentRepairer,
    private val writeGate: WriteGate,
    private val analytics: AnalyticsFacade,
    val isOnline: StateFlow<Boolean>,
    session: StateFlow<SessionState>,
    private val scope: CoroutineScope,
    createdPosts: Flow<PostView> = emptyFlow(),
    deletedPosts: Flow<PostId> = emptyFlow(),
) : ViewModel(scope) {

    /**
     * プロフィール編集の導線を出すか。編集の書き込み（[WriteCapability.PROFILE_EDIT]）が有効なビルドだけ true（M1 は false）。
     * ビルド時に決まるので、作った時点で 1 回だけ読む（AuthViewModel の `canCreateAccount` と同じ）。
     */
    val canEdit: Boolean = writeGate.isEnabled(WriteCapability.PROFILE_EDIT)

    private val mutableHeader = MutableStateFlow<ProfileHeaderState>(ProfileHeaderState.Loading)

    /** 見出しの状態。 */
    val header: StateFlow<ProfileHeaderState> = mutableHeader.asStateFlow()

    private val loader = ProfilePostsLoader({ profileRepository.ownPostsPage(it) }, analytics, isOnline, scope, CONTEXT)

    /** 自分の投稿の一覧（公開範囲によらない：要件 10.2）。 */
    val posts: StateFlow<FeedUiState> = loader.state

    /** いまのユーザーの、補完と監視（ユーザーが変わったら止める）。 */
    private var userJob: Job? = null

    /** 監視だけ（見出しの再試行で張り直す）。[userJob] の子なので、ユーザーが変わると一緒に止まる。 */
    private var observation: Job? = null

    /** いまのユーザーの uid。未ログインなら null。 */
    private var uid: Uid? = null

    init {
        session
            .map { (it as? SessionState.SignedIn)?.uid }
            .distinctUntilChanged()
            .onEach { switchTo(it) }
            .launchIn(scope)
        createdPosts.onEach(::insertCreated).launchIn(scope)
        deletedPosts.onEach(loader::remove).launchIn(scope)
    }

    /** 呼ぶたびに画面名「プロフィール」を送る（要件 15.4）。画面が呼ぶのは戻る履歴の 1 枚ごとに 1 回（回転・戻りでは呼ばない：SoramoyouApp）。 */
    fun onScreenShown() {
        analytics.logScreen(ScreenName.PROFILE)
    }

    /** 投稿の一覧を先頭から読み直す（引っ張って更新・一覧の全面の再試行）。見出しは監視しているので読み直さない。 */
    fun refresh() {
        if (uid != null) loader.refresh()
    }

    /** 投稿の続きを読む。 */
    fun loadMore() {
        if (uid != null) loader.loadMore()
    }

    /** 見出しの失敗の後に、監視を張り直す（補完は呼び直さない）。 */
    fun retryHeader() {
        val parent = userJob ?: return
        if (mutableHeader.value !is ProfileHeaderState.Failed) return
        observe(parent)
    }

    /** 自分が作った投稿 [post] を一覧の先頭に差し込む。いまのユーザーの投稿でなければ何もしない。 */
    private fun insertCreated(post: PostView) {
        if (uid != null && post.userId == uid) loader.insertFirst(post)
    }

    private fun switchTo(next: Uid?) {
        userJob?.cancel()
        userJob = null
        observation = null
        uid = next
        loader.reset()
        mutableHeader.value = ProfileHeaderState.Loading
        if (next == null) return
        val parent = Job(scope.coroutineContext[Job])
        userJob = parent
        if (writeGate.isEnabled(WriteCapability.ACCOUNT_REPAIR)) {
            scope.launch(parent) { repairer.ensureAccountDocuments() }
        }
        observe(parent)
        loader.refresh()
    }

    private fun observe(parent: Job) {
        observation?.cancel()
        mutableHeader.value = ProfileHeaderState.Loading
        observation = scope.launch(parent) {
            profileRepository.observeOwn().collect { result ->
                mutableHeader.value = when (result) {
                    is AppResult.Ok -> headerOf(result.value)
                    is AppResult.Err -> when (result.error) {
                        AppError.NotFound -> MISSING_OWN_HEADER
                        else -> {
                            analytics.logError(result.error, "$CONTEXT.observeOwn")
                            ProfileHeaderState.Failed(result.error, failedWhileOffline = !isOnline.value)
                        }
                    }
                }
            }
        }
    }

    private companion object {
        /** 記録の発生箇所の前置き。 */
        const val CONTEXT = "ProfileViewModel"
    }
}
