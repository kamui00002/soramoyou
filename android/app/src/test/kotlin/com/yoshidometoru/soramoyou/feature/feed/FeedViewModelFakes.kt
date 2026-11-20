// ⭐️ フィードの画面の状態の単体テストで共有する偽物と、ページの組み立て（タスク 9.4）
package com.yoshidometoru.soramoyou.feature.feed

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.PostImageView
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.remote.read.RawCursor
import com.yoshidometoru.soramoyou.data.repository.AuthorProfileCache
import com.yoshidometoru.soramoyou.data.repository.BlockListRepository
import com.yoshidometoru.soramoyou.data.repository.FeedPage
import com.yoshidometoru.soramoyou.data.repository.FeedRepository
import com.yoshidometoru.soramoyou.data.repository.LikeCountOverride
import com.yoshidometoru.soramoyou.data.repository.LikeStateStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * フィードのページ取得の偽物。呼ばれた起点を [calls] に残す。
 * [queued] に結果があればそれを先頭から返し、無ければ [pending] に待ちを足して、テストが complete するまで待つ
 * （結果を渡さないままにすれば、そこで止まり続ける。先読みの上限のテストで無限に読まないことを確かめるのに使う）。
 */
class FakeFeedRepository : FeedRepository {
    val calls = mutableListOf<RawCursor?>()
    val queued = ArrayDeque<AppResult<FeedPage>>()
    val pending = mutableListOf<CompletableDeferred<AppResult<FeedPage>>>()

    override suspend fun loadPage(after: RawCursor?): AppResult<FeedPage> {
        calls += after
        queued.removeFirstOrNull()?.let { return it }
        val waiting = CompletableDeferred<AppResult<FeedPage>>()
        pending += waiting
        return waiting.await()
    }

    /** 待っている最後の取得に [result] を渡す。 */
    fun completeLast(result: AppResult<FeedPage>) {
        pending.last().complete(result)
    }
}

/**
 * ブロック中のユーザーの一覧の偽物。呼ばれた回数を残す。
 * ふだんは [result] をすぐに返す。[holds] を true にすると、それ以降の呼び出しは [pending] に待ちを足して、
 * テストが [completeLast] で結果を渡すまで待つ（読み直しでこの一覧を待っている間にブロックの知らせが届く、という順序を作るため。
 * すぐに返す形では、その間が無いので作れない。レビュー F16）。
 */
class FakeBlockListRepository(var result: AppResult<Set<Uid>> = AppResult.Ok(emptySet())) : BlockListRepository {
    var calls = 0
    var holds = false
    val pending = mutableListOf<CompletableDeferred<AppResult<Set<Uid>>>>()
    override suspend fun blockedIds(): AppResult<Set<Uid>> {
        calls++
        if (!holds) return result
        val waiting = CompletableDeferred<AppResult<Set<Uid>>>()
        pending += waiting
        return waiting.await()
    }

    /** 待っている最後の取得に [result] を渡す。 */
    fun completeLast(result: AppResult<Set<Uid>>) {
        pending.last().complete(result)
    }
}

/** 投稿者の表示の偽物。ensure に渡された uid の集合を順に残す（取得はしない）。 */
class FakeAuthorProfileCache : AuthorProfileCache {
    override val authors: StateFlow<Map<Uid, AuthorDisplay>> = MutableStateFlow(emptyMap())
    val ensureCalls = mutableListOf<Set<Uid>>()
    override suspend fun ensure(uids: Set<Uid>) {
        ensureCalls += uids
    }
}

/** いいねの表示状態の偽物。押した・確かめた投稿を順に残す（状態は変えない。規則は DefaultLikeStateStoreTest が確かめる）。 */
class FakeLikeStateStore : LikeStateStore {
    override val liked = MutableStateFlow<Set<PostId>>(emptySet())
    override val countOverrides = MutableStateFlow<Map<PostId, LikeCountOverride>>(emptyMap())
    val toggleCalls = mutableListOf<Pair<PostId, Long>>()
    val refreshCalls = mutableListOf<List<PostId>>()
    override fun displayedCount(postId: PostId, baseCount: Long): Long = error("このテストでは使わない")
    override suspend fun toggle(postId: PostId, baseCount: Long) {
        toggleCalls += postId to baseCount
    }
    override suspend fun refresh(postIds: List<PostId>) {
        refreshCalls += postIds
    }
}

/** 投稿者 [author] の、画像 1 枚の投稿。 */
fun post(id: String, author: String = "u-$id"): PostView = PostView(
    postId = PostId(id),
    userId = Uid(author),
    images = listOf(PostImageView(url = "https://example.com/$id.jpg", thumbnail = null, width = null, height = null, order = 0)),
    caption = null,
    hashtags = null,
    visibility = null,
    likesCount = 0,
    createdAt = null,
    capturedAt = null,
    timeOfDay = null,
    skyType = null,
)

/** 起点の名前を持つカーソル（同じものかは参照で比べる）。 */
fun cursor(name: String): RawCursor = RawCursor(name)

/** 次の起点が [next] のページ。続きの有無は [reachedEnd] でだけ決める（表示できる件数とは別）。 */
fun page(posts: List<PostView>, next: RawCursor = cursor("c"), reachedEnd: Boolean = false, skipped: Int = 0): AppResult<FeedPage> =
    AppResult.Ok(FeedPage(posts = posts, next = next, skippedCount = skipped, reachedEnd = reachedEnd))

/** [count] 件の投稿（id は `prefix-0` から）。 */
fun posts(prefix: String, count: Int): List<PostView> = List(count) { post("$prefix-$it") }
