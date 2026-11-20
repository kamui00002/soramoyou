// ⭐️ フィードの画面の状態：先頭から・続きの取得、ブロックの除外、0 件のページの先読み、失敗の表示と記録、通報・ブロック（タスク 9.4・29.2）
package com.yoshidometoru.soramoyou.feature.feed

import androidx.lifecycle.ViewModel
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.remote.read.RawCursor
import com.yoshidometoru.soramoyou.data.remote.write.WriteGate
import com.yoshidometoru.soramoyou.data.repository.AuthorProfileCache
import com.yoshidometoru.soramoyou.data.repository.BlockListRepository
import com.yoshidometoru.soramoyou.data.repository.BlockedUsers
import com.yoshidometoru.soramoyou.data.repository.FeedRepository
import com.yoshidometoru.soramoyou.data.repository.LikeCountOverride
import com.yoshidometoru.soramoyou.data.repository.LikeStateStore
import com.yoshidometoru.soramoyou.data.repository.ModerationRepository
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.feature.moderation.ModerationUiState
import com.yoshidometoru.soramoyou.feature.moderation.PostModeration
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.ScreenName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * フィードの画面の状態（設計書の FeedUiState）。どの表示を出すかは [feedContentOf] で決める。
 *
 * @property posts 表示する投稿（ブロック中のユーザーの投稿と、変換できない投稿は除いてある）。新しい順。
 * @property isRefreshing 先頭からの取得中（最初の表示・引っ張って更新・全面の再試行）。
 * @property isLoadingMore 続きの取得中。
 * @property reachedEnd 続きが無いと分かったか。取得したページの「続きなし」（変換前の件数で決まる）だけで決め、表示した件数では決めない。
 * @property error 直前の取得の失敗。次の取得を始めたら消す。
 * @property failedWhileOffline [error] が起きた時点でオフラインだったか（OfflineContent を出すのはこのときだけ：StateContents.kt の契約）。
 * @property next 続きの起点（直前に読んだページの、変換前の生の最後の 1 件）。
 */
data class FeedUiState(
    val posts: List<PostView> = emptyList(),
    val isRefreshing: Boolean = false,
    val isLoadingMore: Boolean = false,
    val reachedEnd: Boolean = false,
    val error: AppError? = null,
    val failedWhileOffline: Boolean = false,
    internal val next: RawCursor? = null,
)

/** フィードの画面に出す表示。投稿が 1 件でもあれば一覧を出す（続きの失敗・読み込み中は一覧の末尾に出す）。 */
enum class FeedContent { LOADING, ERROR, OFFLINE, EMPTY, LIST }

/**
 * [state] のときに出す表示（要件 4.12・4.13・16.2・16.3）。
 * 「投稿がありません」は続きが無いと分かったときだけ出す。0 件のページの先読みを上限で止めた（まだ続きがある）ときは
 * 空の一覧を出し、一覧の末尾が見えたことで続きを読む（FeedScreen）。
 */
fun feedContentOf(state: FeedUiState): FeedContent = when {
    state.posts.isNotEmpty() -> FeedContent.LIST
    state.isRefreshing -> FeedContent.LOADING
    state.error != null -> if (state.failedWhileOffline) FeedContent.OFFLINE else FeedContent.ERROR
    state.reachedEnd -> FeedContent.EMPTY
    else -> FeedContent.LIST
}

/**
 * フィードの画面の ViewModel（設計書の FeedViewModel・フロー図「フィード読み込み」）。iOS の `HomeViewModel`＋`PaginatedPostsViewModel`
 * （origin/main `266d428`）の振る舞いを写し、次の点だけ変える。
 *
 * - 続きの有無は、ページの [com.yoshidometoru.soramoyou.data.repository.FeedPage.reachedEnd]（変換前に読んだ件数で決まる）だけで決める。
 *   iOS の origin/main は表示できる件数で決めていて、壊れた投稿やブロック中のユーザーの投稿を含む満杯のページで止まる
 *   （iOS の修正は PR #154・#156 で、2026-10-05 時点で未マージ）。
 * - ブロック中のユーザーの投稿は、取得したページごとに除く（`excludingAuthors`）。除いて表示が 0 件になったページで、まだ続きがあれば、
 *   続けて次のページを読む（最大 [MAX_EMPTY_PAGE_FOLLOW_UPS] ページ。iOS の PR #154 の先読みと同じ上限）。
 *   一覧の末尾が画面に見えないと続きを読む合図が来ないので、0 件のままだと続きを読めなくなるため。
 * - ブロック中の一覧は先頭から読むときだけ読み、続きではそれを使い回す（iOS の fetchPosts／loadMorePosts と同じ）。
 *   取得できたら、サーバーの一覧に、その読み直しを始めた後に知らせで足した uid を加えて置き換える（[refresh]。サーバーの一覧は
 *   ブロックの書き込みより前の状態で返りうるため）。取得の失敗では空にせず、直前のブロック中の集合をそのまま使う（表示は続ける）。
 *   iOS は失敗で空にする（HomeViewModel.loadBlockedUsers）が、それではこの画面で知らせを受けてブロックした人の投稿まで戻るので、
 *   ブロックを保つ側に倒す（BlockListRepository の uidsOf と同じ考え。レビュー F16）。
 *   記録は BlockListRepository が済ませているので、ここでは記録し直さない。
 * - 取得自体の失敗は、ここで記録して表示する（要件 4.12。FeedRepository は記録しない）。
 * - 投稿者の名前とアイコンは、ブロックを除いた後の投稿の投稿者だけを [AuthorProfileCache.ensure] に渡す（要件 4.6）。
 *   取得を待たずに一覧を出し、名前は取れたものから出る（iOS は待ってから出す）。
 * - 読んだページごとに、表示する投稿（ブロックを除いた後）のいいね済みを [LikeStateStore.refresh] で確かめる（要件 9.2。iOS も
 *   先頭からの読み込み・続きの読み込みの後に、その投稿だけを checkLikeStatus に渡す）。取得を待たずに一覧を出す。
 * - 先頭から読み直すたびに世代を 1 進め、古い世代の結果は捨てる（iOS の fetchGeneration と同じ）。
 * - ログアウトしたら（[session] が未ログインになったら）、状態を捨てて取得中の結果も書き戻さない。
 *   SessionManager には登録しない。登録を外す手段が無く、画面ごとに作られるこの ViewModel を登録すると参照が溜まり続けるため
 *   （設計書の SessionManager は「登録された状態（フィード…）」を捨てる、と書いているが、この ViewModel は自分で捨てる）。
 * - 自分が作った投稿は、知らせ（[createdPosts]）を受けて一覧の先頭に差し込む（要件 7.22・タスク 23.3。読み直さない）。
 *   フィードは公開の投稿だけなので、公開でない投稿と、既に一覧にある投稿は差し込まない。投稿者の表示も読み込む。
 *   先頭からの読み直しの途中で差し込むと、読み直しの結果で一覧が置き換わる（その結果に新しい投稿が入っていなければ消えるが、
 *   投稿はできているので次の読み直しで出る）。
 * - 自分が消した投稿は、知らせ（[deletedPosts]）を受けて一覧から除く（要件 10.11・タスク 24。読み直さない）。
 * - 他人の投稿にだけ、通報とブロックの操作を出す（[moderation]。要件 11.1・11.7。判定は moderationActionsFor の 1 か所）。
 *   ブロックできたら（この画面でも投稿詳細でも）、知らせ（[blockedUsers]）を受けて、その投稿者の投稿を表示中の一覧から
 *   読み直さずに除き、ブロック中の集合にも足して、この後に読む続きのページからも除く（要件 11.4。iOS も配列に足してから
 *   除き直す：HomeViewModel.swift:143-155）。解除は知らせないので、解除した人の投稿は次の先頭からの読み直しで戻る。
 *
 * @param likeStateStore いいねの表示状態（アプリ全体で 1 つ。ログアウトでは自分で捨てるので、この ViewModel は捨てない）。
 * @param writeGate 書き込みの可否。いいねの書き込みが無効なビルドでは、いいねのボタンを押せなくする（[canLike]）。
 *   投稿の書き込みが無効なビルドでは、投稿の導線を出さない（[canPost]）。
 * @param isOnline 接続の有無（NetworkMonitor.isOnline）。失敗した時点の値を [FeedUiState.failedWhileOffline] に残し、画面の OfflineContent にも渡す。
 * @param session 認証状態。未ログインになったら状態を捨てる。
 * @param scope この ViewModel の viewModelScope（RootViewModel と同じ理由で外から渡す）。
 * @param createdPosts 自分が作った投稿の知らせ（CreatedPosts.events）。
 * @param deletedPosts 自分が消した投稿の知らせ（DeletedPosts.events）。
 * @param moderationRepository 通報・ブロックの書き込み（[moderation] が使う。失敗の記録も行う）。
 * @param blockedUsers ブロックできたことの知らせ（アプリ全体で 1 つ）。[moderation] が流し、この ViewModel が集める。
 */
class FeedViewModel(
    private val feedRepository: FeedRepository,
    private val blockListRepository: BlockListRepository,
    private val authorProfileCache: AuthorProfileCache,
    private val likeStateStore: LikeStateStore,
    writeGate: WriteGate,
    private val analytics: AnalyticsFacade,
    val isOnline: StateFlow<Boolean>,
    session: StateFlow<SessionState>,
    private val scope: CoroutineScope,
    moderationRepository: ModerationRepository,
    blockedUsers: BlockedUsers,
    createdPosts: Flow<PostView> = emptyFlow(),
    deletedPosts: Flow<PostId> = emptyFlow(),
) : ViewModel(scope) {

    private val mutableState = MutableStateFlow(FeedUiState())

    val state: StateFlow<FeedUiState> = mutableState.asStateFlow()

    /** 投稿者の表示（uid → 名前とアイコン）。まだ入っていない uid は読み込み中。 */
    val authors: StateFlow<Map<Uid, AuthorDisplay>> = authorProfileCache.authors

    /** いいね済みの投稿（全画面で共有）。 */
    val liked: StateFlow<Set<PostId>> = likeStateStore.liked

    /** 押した結果のいいね数（全画面で共有）。画面は displayedLikeCount で数を出す。 */
    val likeCountOverrides: StateFlow<Map<PostId, LikeCountOverride>> = likeStateStore.countOverrides

    /** いいねのボタンを押せるか（このビルドでいいねの書き込みが有効か。要件 9.1 の表示は可否によらず出す）。 */
    val canLike: Boolean = writeGate.isEnabled(WriteCapability.LIKE)

    /** 投稿の導線を出すか（このビルドで投稿の書き込みが有効か。M4 から：タスク 21.1・要件 6.1）。 */
    val canPost: Boolean = writeGate.isEnabled(WriteCapability.POST_CREATE)

    /**
     * 通報・ブロックの操作（要件 11.1〜11.4・11.6・11.7）。画面は [PostModeration.actionsFor] で投稿ごとに出す操作を決め、
     * [PostModeration.state]（[ModerationUiState]）でダイアログを出し、[PostModeration.handlers] で操作を呼ぶ。
     * 自分の投稿かは、いまの認証状態（`session`）から呼ぶたびに読む。
     */
    val moderation: PostModeration = PostModeration(
        moderationRepository,
        writeGate,
        isOnline,
        { (session.value as? SessionState.SignedIn)?.uid },
        blockedUsers,
        scope,
    )

    /** 先頭から読み直すたび（とログアウト）に 1 進める。取得を始めたときの値と違えば、その結果は捨てる。 */
    private var generation = 0L

    /**
     * ブロック中の uid（先頭から読んだときに得た一覧と、この画面で知らせを受けた uid）。続きの取得でも使い回す。
     * 先頭からの読み直しで一覧を読めたら置き換え、読めなければ残す（[refresh]）。
     */
    private var blocked: Set<Uid> = emptySet()

    /**
     * いまの世代の読み直し（[refresh]）を始めた後に、知らせで足したブロックの uid。読み直しの結果で [blocked] を置き換えるときに足す。
     * サーバーの一覧はブロックの書き込みより前の状態で返りうるので、置き換えるだけだとこの間の知らせが消え、
     * ブロックした人の投稿が読み直した一覧に戻るため（レビュー F16）。読み直しを始めるたびに空にする
     * （前の世代の知らせまで足し続けると、ブロック中のユーザーの画面で解除した人が、読み直しても戻らなくなるため）。
     */
    private var blockedSinceRefresh: Set<Uid> = emptySet()

    init {
        session
            .filter { it == SessionState.SignedOut }
            .onEach {
                generation++
                blocked = emptySet()
                blockedSinceRefresh = emptySet()
                mutableState.value = FeedUiState()
            }
            .launchIn(scope)
        createdPosts.onEach(::insertCreated).launchIn(scope)
        deletedPosts.onEach(::removeDeleted).launchIn(scope)
        blockedUsers.events.onEach(::excludeBlocked).launchIn(scope)
        refresh()
    }

    /** 呼ぶたびに画面名「ホーム」を送る（要件 15.4）。画面が呼ぶのは戻る履歴の 1 枚ごとに 1 回（回転・戻りでは呼ばない：SoramoyouApp）。 */
    fun onScreenShown() {
        analytics.logScreen(ScreenName.HOME)
    }

    /** 投稿 [post] のいいねを押す（要件 9.7〜9.9）。基準の数は、画面が持っているその投稿の likesCount。 */
    fun toggleLike(post: PostView) {
        scope.launch { likeStateStore.toggle(post.postId, post.likesCount) }
    }

    /**
     * 先頭から読み直して置き換える（最初の表示・引っ張って更新・全面の再試行：要件 4.1・4.3）。取得中の続きの結果は捨てる。
     * ブロック中の一覧を読めたら、それに読み直しを始めた後の知らせの分（[blockedSinceRefresh]）を足して置き換える。
     * 読めなければ、直前の [blocked]（知らせの分も入っている）をそのまま使う。
     */
    fun refresh() {
        val gen = ++generation
        // 一覧の取得を待つ間に知らせが届くので、空にするのは待つ前（launch の外）で行う
        blockedSinceRefresh = emptySet()
        mutableState.update { it.copy(isRefreshing = true, isLoadingMore = false, error = null, failedWhileOffline = false) }
        scope.launch {
            val result = blockListRepository.blockedIds()
            if (gen != generation) return@launch
            if (result is AppResult.Ok) blocked = result.value + blockedSinceRefresh
            load(after = null, gen = gen, context = "FeedViewModel.refresh")
        }
    }

    /** 続きを読んで末尾に足す（要件 4.2）。取得中・続きなし・先頭から読み直している間は何もしない。続きの失敗の再試行もこれ。 */
    fun loadMore() {
        val current = mutableState.value
        if (current.isLoadingMore || current.isRefreshing || current.reachedEnd) return
        val gen = generation
        mutableState.update { it.copy(isLoadingMore = true, error = null, failedWhileOffline = false) }
        scope.launch { load(after = current.next, gen = gen, context = "FeedViewModel.loadMore") }
    }

    /** 自分が作った投稿 [post] を一覧の先頭に差し込む。公開でない投稿と、既に一覧にある投稿は差し込まない。 */
    private fun insertCreated(post: PostView) {
        if (post.visibility != Visibility.PUBLIC) return
        var inserted = false
        mutableState.update { state ->
            inserted = state.posts.none { it.postId == post.postId }
            if (inserted) state.copy(posts = listOf(post) + state.posts) else state
        }
        if (inserted) scope.launch { authorProfileCache.ensure(setOf(post.userId)) }
    }

    /** 自分が消した投稿 [postId] を一覧から除く。一覧に無ければ何もしない。 */
    private fun removeDeleted(postId: PostId) {
        mutableState.update { state -> state.copy(posts = state.posts.filterNot { it.postId == postId }) }
    }

    /**
     * ブロックした [uid] の投稿を、表示中の一覧から除き、続きのページでも除くようにブロック中の集合に足す（要件 11.4。読み直さない）。
     * 除いて一覧が空になっても、まだ続きがあれば、一覧の末尾が見えたことで画面が続きを読む（0 件の先読みと同じ経路）。
     * 先頭からの読み直しの途中に届いても消えないように、その世代の知らせの分（[blockedSinceRefresh]）にも足す。
     */
    private fun excludeBlocked(uid: Uid) {
        blocked = blocked + uid
        blockedSinceRefresh = blockedSinceRefresh + uid
        mutableState.update { state -> state.copy(posts = state.posts.filterNot { it.userId == uid }) }
    }

    /**
     * [after] から 1 ページ読み、表示が 0 件で続きがあれば上限まで続けて読む。1 ページ読むごとに状態へ反映する。
     * [after] が null なら先頭からで、最初のページで一覧を置き換える。
     */
    private suspend fun load(after: RawCursor?, gen: Long, context: String) {
        var cursor = after
        var followUps = 0
        while (true) {
            val result = feedRepository.loadPage(cursor)
            if (gen != generation) return
            when (result) {
                is AppResult.Err -> {
                    analytics.logError(result.error, context)
                    val offline = !isOnline.value
                    mutableState.update {
                        it.copy(
                            // 先頭からの取得の失敗では古い一覧を残さない（iOS も読み直しの前に空にする）
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
                    val page = result.value.excludingAuthors(blocked)
                    val replace = cursor == null
                    mutableState.update {
                        it.copy(
                            posts = if (replace) page.posts else it.posts + page.posts,
                            next = page.next,
                            reachedEnd = page.reachedEnd,
                        )
                    }
                    if (page.posts.isNotEmpty()) {
                        val uids = page.posts.mapTo(mutableSetOf()) { it.userId }
                        scope.launch { authorProfileCache.ensure(uids) }
                        val postIds = page.posts.map { it.postId }
                        scope.launch { likeStateStore.refresh(postIds) }
                    }
                    // 表示が 0 件で続きがあるページだけ、上限まで続けて読む（続きの有無はページの reachedEnd だけで決める）
                    if (page.posts.isNotEmpty() || page.reachedEnd || followUps >= MAX_EMPTY_PAGE_FOLLOW_UPS) break
                    followUps++
                    cursor = page.next
                }
            }
        }
        mutableState.update { it.copy(isRefreshing = false, isLoadingMore = false) }
    }

    internal companion object {
        /** 表示が 0 件のページの後に、続けて読むページの上限（iOS の PR #154 と同じ 3。未マージ）。 */
        const val MAX_EMPTY_PAGE_FOLLOW_UPS = 3
    }
}
