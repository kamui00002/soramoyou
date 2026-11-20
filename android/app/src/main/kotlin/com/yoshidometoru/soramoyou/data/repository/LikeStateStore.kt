// ⭐️ いいねの表示状態を、全画面で共有する（タスク 18.3・要件 2.9・9.1・9.7・9.8・9.9）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.SessionManager
import com.yoshidometoru.soramoyou.platform.SessionScopedState
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

/**
 * 押した結果の数字を「どの `likesCount` の投稿で押したか」と組で覚えておく（iOS の `LikeManager.LikeCountOverride`）。
 *
 * 画面が持っている投稿の `likesCount` は、一覧を読んだ時点の値のまま更新されない。そこで押したときの値（基準）と押した結果の数字を
 * 組で持ち、投稿の `likesCount` が基準のままなら押した結果を、変わっていれば（読み直して最新値が届いた）投稿の値を出す。
 * ⚠️ 数が一度動いて元に戻ると（5→6→5）基準と一致して押した結果が出続ける。自分の状態の食い違いは [LikeStateStore.refresh] が捨てる。
 *
 * @property baseCount 押したときに画面が持っていた `likesCount`。
 * @property count 表示する数字（押した直後は楽観的な値、書き込みの成功後はサーバーの値）。
 * @property isLiked 押した結果のいいね状態。サーバーの状態と食い違ったら、この数字はもう古い。
 */
data class LikeCountOverride(val baseCount: Long, val count: Long, val isLiked: Boolean)

/**
 * 画面に出すいいね数（要件 9.1）。押した結果の数字 [override] があり、いま画面が持っている [baseCount] で押したものならそれを、
 * そうでなければ [baseCount] を出す。どちらも 0 未満なら 0。画面は [LikeStateStore.countOverrides] を集めて、この関数で数を出す。
 */
fun displayedLikeCount(override: LikeCountOverride?, baseCount: Long): Long =
    maxOf(0L, if (override != null && override.baseCount == baseCount) override.count else baseCount)

/**
 * いいね済みの投稿と押した結果の数字を、アプリ全体で 1 つ持つ（設計書の部品 LikeStateStore。:796-818）。
 * iOS の `LikeManager`（LikeManager.swift:29-156）の状態の規則を写す。
 *
 * 設計書の型からの差：[countOverrides] も観測できる形で公開する。[displayedCount] は呼んだ時点の値を読むだけなので、
 * 画面はサーバーの数字が届いたときに描き直せるよう、[liked] と [countOverrides] の両方を集め、数は [displayedLikeCount] で出す（タスク 18.4）。
 */
interface LikeStateStore {

    /** いいね済みの投稿。 */
    val liked: StateFlow<Set<PostId>>

    /** 押した結果の数字（投稿 ID → 基準と数字）。 */
    val countOverrides: StateFlow<Map<PostId, LikeCountOverride>>

    /**
     * 画面に出すいいね数。押した結果の数字が、いま画面が持っている [baseCount] で押したものなら、それを出す。
     * そうでなければ [baseCount] を出す。どちらも 0 未満なら 0（要件 9.1）。
     */
    fun displayedCount(postId: PostId, baseCount: Long): Long

    /**
     * いいねを押す（要件 9.7〜9.9）。押した結果（いまいいね済みでなければ「いいね済み」）を先に決め、サーバーの応答を待たずに表示を切り替える。
     * 成功したらサーバーのいいね数にそろえ、失敗したら押す前の状態と数に戻す。
     *
     * - 書き込みが終わっていない投稿への操作は無視する（2 つの書き込みがサーバーで逆順に確定すると、画面とサーバーが食い違うため）
     * - ログインしていなければ何もしない（ログアウト中はルートの画面がフィードを出さない）
     * - 失敗の記録は LikeRepository が済ませている（発生箇所 `LikeRepository.setLike`）ので、ここでは記録し直さない
     *
     * @param baseCount いま画面が持っている投稿の `likesCount`。
     */
    suspend fun toggle(postId: PostId, baseCount: Long)

    /**
     * 表示中の投稿 [postIds] のいいね済みの状態を、サーバーから確かめて反映する（要件 9.2）。
     * 上書きするのは問い合わせた範囲だけ。押した結果の数字は、押した向きとサーバーの状態が食い違うものだけを捨てる
     * （書き込み中の投稿の数字は触らない。読んだ値が書き込み前のことがあるため）。
     * 失敗したら状態を変えずに、`LikeStateStore.refresh` として記録する。ログインしていなければ何もしない。
     */
    suspend fun refresh(postIds: List<PostId>)
}

/**
 * [LikeStateStore] の実装。作られたときに [SessionManager] へ登録し、ログアウトで全てを捨てる（要件 2.9）。
 * ログアウトの前に始めた書き込み・確認の結果は、終わっても書き戻さない（世代で見分ける。DefaultAuthorProfileCache と同じ）。
 *
 * @param repository いいねの書き込みと確認。
 * @param analytics 確認の失敗の記録先。
 * @param currentUid いまログインしているユーザーの uid（いなければ null）。呼ぶたびに読む。
 * @param sessionManager ログアウトで捨てる状態の登録先。
 */
class DefaultLikeStateStore(
    private val repository: LikeRepository,
    private val analytics: AnalyticsFacade,
    private val currentUid: () -> Uid?,
    sessionManager: SessionManager,
) : LikeStateStore, SessionScopedState {

    private val likedState = MutableStateFlow<Set<PostId>>(emptySet())
    override val liked: StateFlow<Set<PostId>> = likedState.asStateFlow()

    private val overridesState = MutableStateFlow<Map<PostId, LikeCountOverride>>(emptyMap())
    override val countOverrides: StateFlow<Map<PostId, LikeCountOverride>> = overridesState.asStateFlow()

    /** 以下の 2 つと、2 つの状態の書き換えは [lock] の中でだけ行う（中で中断しないので synchronized で足りる）。 */
    private val lock = Any()

    /** 書き込み中の投稿（処理中の連打を受け付けないため）。 */
    private val inFlight = mutableSetOf<PostId>()

    /** ログアウトのたびに 1 増やす。始めたときの値と違えば、結果を書き戻さない。 */
    private var generation = 0L

    init {
        sessionManager.register(this)
    }

    override fun displayedCount(postId: PostId, baseCount: Long): Long =
        displayedLikeCount(overridesState.value[postId], baseCount)

    override suspend fun toggle(postId: PostId, baseCount: Long) {
        if (currentUid() == null) return

        // 書き込み中かの確認・登録と、押した結果の決定を 1 回のロックで行う（分けると、速い連打が 2 つとも通る）
        val desired: Boolean
        val previousOverride: LikeCountOverride?
        val startedAt: Long
        synchronized(lock) {
            if (postId in inFlight) return
            inFlight += postId
            startedAt = generation
            desired = postId !in likedState.value
            previousOverride = overridesState.value[postId]
            val shown = displayedLikeCount(previousOverride, baseCount)
            // 楽観的な更新（押したらすぐに表示を切り替える）
            setLiked(postId, desired)
            putOverride(postId, LikeCountOverride(baseCount, shown + if (desired) 1 else -1, desired))
        }

        try {
            // 書き込みの待ちと結果の反映は取り消さない。投稿詳細でいいねを押してすぐ戻ると、持ち主（PostDetailViewModel）の scope が閉じて
            // 待ちが取り消しで抜け、失敗でも表示が戻らず、LikeRepository が await の後に行う失敗の記録も走らない（この store はアプリ全体で
            // 共有なので、サーバーに無いいいねがフィードに出続ける）。PostDeleter・PostModeration.confirmBlock と同じく NonCancellable で最後まで行う
            withContext(NonCancellable) {
                val result = repository.setLike(postId, desired)
                synchronized(lock) {
                    // withContext のラムダは inline でないので、非局所の return でなくラベル付きで抜ける
                    if (generation != startedAt) return@withContext
                    when (result) {
                        is AppResult.Ok -> {
                            // 成功した時点でサーバーは押した意図どおり。途中で確認が挟まっても、ここでそろえる。
                            // 既にその状態だった（サーバーは書かなかった）場合も、ここで正しい数字にそろう
                            setLiked(postId, desired)
                            putOverride(postId, LikeCountOverride(baseCount, result.value, desired))
                        }
                        is AppResult.Err -> {
                            // 押す前に戻す。状態は押した向きの逆に、数字は押す前の組に（記録は LikeRepository が済ませている）
                            setLiked(postId, !desired)
                            putOverride(postId, previousOverride)
                        }
                    }
                }
            }
        } finally {
            // ログアウト後は、新しいセッションの書き込み中の印を消さないよう触らない（ログアウトで既に空にしている）
            synchronized(lock) { if (generation == startedAt) inFlight -= postId }
        }
    }

    override suspend fun refresh(postIds: List<PostId>) {
        if (currentUid() == null) return
        val queried = postIds.distinct()
        if (queried.isEmpty()) return
        val startedAt = synchronized(lock) { generation }

        val result = repository.likedAmong(queried)
        synchronized(lock) {
            if (generation != startedAt) return
            when (result) {
                is AppResult.Err -> analytics.logError(result.error, REFRESH_CONTEXT)
                is AppResult.Ok -> {
                    val likedIds = result.value
                    // 問い合わせた範囲だけをサーバーの値で置き換える（足すだけだと、別の端末で外したいいねが残る）
                    likedState.value = likedState.value - queried.toSet() + likedIds
                    // 数字は、押した向きとサーバーの状態が食い違うものだけを捨てる（書き込み中の投稿は触らない）
                    val stale = queried.filter { postId ->
                        postId !in inFlight && overridesState.value[postId]?.let { it.isLiked != (postId in likedIds) } == true
                    }
                    if (stale.isNotEmpty()) overridesState.value = overridesState.value - stale.toSet()
                }
            }
        }
    }

    override fun clearOnSignOut() {
        synchronized(lock) {
            generation++
            // 書き込み中のものは、終わったときに世代の違いで捨てられる
            inFlight.clear()
            likedState.value = emptySet()
            overridesState.value = emptyMap()
        }
    }

    private fun setLiked(postId: PostId, isLiked: Boolean) {
        likedState.value = if (isLiked) likedState.value + postId else likedState.value - postId
    }

    private fun putOverride(postId: PostId, override: LikeCountOverride?) {
        overridesState.value = if (override != null) overridesState.value + (postId to override) else overridesState.value - postId
    }

    private companion object {
        /** 確認の失敗を記録するときの発生箇所。 */
        const val REFRESH_CONTEXT = "LikeStateStore.refresh"
    }
}
