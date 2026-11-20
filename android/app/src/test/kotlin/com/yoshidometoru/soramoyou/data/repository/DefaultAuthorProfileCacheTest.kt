// ⭐️ 投稿者の名前とアイコンの取得の単体テスト（タスク 9.2・要件 4.4・4.5・4.6）
package com.yoshidometoru.soramoyou.data.repository

import com.google.firebase.auth.FirebaseAuth
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.CountSpec
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.QuerySpec
import com.yoshidometoru.soramoyou.data.remote.read.RawPage
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.read.RemoteImageUrlPolicy
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.platform.SessionManager
import com.yoshidometoru.soramoyou.platform.SessionScopedState
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield

/**
 * [DefaultAuthorProfileCache] の単体テスト。読み取りの入口は偽物 [FakeReader] で、パスごとの結果を返し、呼ばれたパスを記録する。
 * 並列の検査は、[FakeReader.gate] で取得を止めておき、同時に取得中の件数の最大を数える。
 * 取得を止めるテストは、仮実装や壊した実装で永久に止まらないよう [withTimeout] で包む。
 */
class DefaultAuthorProfileCacheTest {

    /** 読み取りの入口の偽物。[profiles] はパスごとのドキュメント（無ければ「ドキュメントが無い」）、[failing] は失敗を返すパス。 */
    private class FakeReader(
        private val profiles: Map<String, RawDocument> = emptyMap(),
        val failing: MutableSet<String> = Collections.synchronizedSet(mutableSetOf()),
    ) : FirestoreReader {

        /** 呼ばれたパス（呼ばれた順）。 */
        val gets: MutableList<String> = Collections.synchronizedList(mutableListOf())

        /** 入れると、取得がこれの完了まで止まる。 */
        @Volatile
        var gate: CompletableDeferred<Unit>? = null

        /** いま取得中の件数と、その最大。 */
        val active = AtomicInteger()
        val peak = AtomicInteger()

        override suspend fun get(ref: DocRef, source: ReadSource): AppResult<RawDocument?> {
            gets += ref.path
            peak.accumulateAndGet(active.incrementAndGet(), ::maxOf)
            try {
                gate?.await()
            } finally {
                active.decrementAndGet()
            }
            return if (ref.path in failing) AppResult.Err(AppError.Network) else AppResult.Ok(profiles[ref.path])
        }

        override suspend fun query(spec: QuerySpec, source: ReadSource): AppResult<RawPage> = error("このテストでは使わない")

        override suspend fun count(spec: CountSpec): AppResult<Long> = error("このテストでは使わない")

        override fun observe(ref: DocRef): Flow<AppResult<RawDocument?>> = error("このテストでは使わない")
    }

    /** 登録された状態を受け取るだけの SessionManager の偽物。 */
    private class CapturingSessionManager : SessionManager {
        val states = mutableListOf<SessionScopedState>()
        override fun register(state: SessionScopedState) {
            states += state
        }
        override suspend fun clearLocalUserData() = states.forEach { it.clearOnSignOut() }
    }

    /** `publicProfiles/{uid}` の正しい形のドキュメント。[fields] で中身を足す・上書きする。 */
    private fun profile(uid: String, vararg fields: Pair<String, Any?>): Pair<String, RawDocument> =
        "publicProfiles/$uid" to RawDocument(uid, mapOf<String, Any?>("id" to uid) + fields)

    private val sessionManager = CapturingSessionManager()

    private fun cache(reader: FakeReader) = DefaultAuthorProfileCache(reader, sessionManager, RemoteImageUrlPolicy.PRODUCTION)

    /** 取得中の件数が [count] に届くまで待つ。 */
    private suspend fun FakeReader.awaitGets(count: Int) {
        while (gets.size < count) yield()
    }

    // ── 表示の作り方（要件 4.4・4.5）──

    @Test
    fun `公開プロフィールの表示名とアイコンを出す`() = runBlocking {
        val reader = FakeReader(mapOf(profile("a", "displayName" to "そら", "photoURL" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg")))
        val cache = cache(reader)

        cache.ensure(setOf(Uid("a")))

        assertEquals(listOf("publicProfiles/a"), reader.gets)
        assertEquals(AuthorDisplay.Named("そら", "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg"), cache.authors.value[Uid("a")])
    }

    @Test
    fun `アイコンのURLが本番のStorageの形でなければアイコンを使わない`() = runBlocking {
        val reader = FakeReader(
            mapOf(
                profile("a", "displayName" to "そら", "photoURL" to "file:///data/data/com.yoshidometoru.soramoyou/files/a.jpg"),
                profile("b", "photoURL" to "http://example.com/b.jpg"),
                profile("c", "displayName" to "くも", "photoURL" to "https://example.com/c.jpg"),
                profile("d", "displayName" to "あめ", "photoURL" to "http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/d.jpg"),
            ),
        )
        val cache = cache(reader)

        cache.ensure(setOf(Uid("a"), Uid("b"), Uid("c"), Uid("d")))

        assertEquals(AuthorDisplay.Named("そら", null), cache.authors.value[Uid("a")])
        assertEquals(AuthorDisplay.Fallback(null), cache.authors.value[Uid("b")])
        assertEquals(AuthorDisplay.Named("くも", null), cache.authors.value[Uid("c")])
        assertEquals(AuthorDisplay.Named("あめ", null), cache.authors.value[Uid("d")])
    }

    @Test
    fun `検証用の形を渡すと、エミュレータのStorageのアイコンだけを使う`() = runBlocking {
        val emu = "http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/users%2Fa%2Fprofile.jpg?alt=media&token=t"
        val reader = FakeReader(
            mapOf(
                profile("a", "displayName" to "そら", "photoURL" to emu),
                profile("b", "displayName" to "くも", "photoURL" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/b.jpg"),
            ),
        )
        val cache = DefaultAuthorProfileCache(reader, sessionManager, RemoteImageUrlPolicy.EMULATOR)

        cache.ensure(setOf(Uid("a"), Uid("b")))

        assertEquals(AuthorDisplay.Named("そら", emu), cache.authors.value[Uid("a")])
        assertEquals(AuthorDisplay.Named("くも", null), cache.authors.value[Uid("b")])
    }

    @Test
    fun `公開プロフィールが無ければ代替表示にする`() = runBlocking {
        val cache = cache(FakeReader())

        cache.ensure(setOf(Uid("a")))

        assertEquals(AuthorDisplay.Fallback(null), cache.authors.value[Uid("a")])
    }

    @Test
    fun `取得に失敗したら代替表示にする`() = runBlocking {
        val reader = FakeReader(mapOf(profile("a", "displayName" to "そら")))
        reader.failing += "publicProfiles/a"
        val cache = cache(reader)

        cache.ensure(setOf(Uid("a")))

        assertEquals(AuthorDisplay.Fallback(null), cache.authors.value[Uid("a")])
    }

    @Test
    fun `中のidがドキュメントIDと違えば、名前もアイコンも使わずに代替表示にする`() = runBlocking {
        // 中の id が要求した uid と違う公開プロフィール（iOS issue #133）
        val reader = FakeReader(
            mapOf(profile("a", "id" to "b", "displayName" to "なりすまし", "photoURL" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/b.jpg")),
        )
        val cache = cache(reader)

        cache.ensure(setOf(Uid("a")))

        assertEquals(AuthorDisplay.Fallback(null), cache.authors.value[Uid("a")])
    }

    @Test
    fun `中のidが無ければ代替表示にする`() = runBlocking {
        val reader = FakeReader(mapOf("publicProfiles/a" to RawDocument("a", mapOf("displayName" to "そら"))))
        val cache = cache(reader)

        cache.ensure(setOf(Uid("a")))

        assertEquals(AuthorDisplay.Fallback(null), cache.authors.value[Uid("a")])
    }

    @Test
    fun `表示名が無いか空なら代替表示にし、アイコンは出す`() = runBlocking {
        val reader = FakeReader(
            mapOf(
                profile("a", "photoURL" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg"),
                profile("b", "displayName" to "", "photoURL" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/b.jpg"),
                profile("c", "displayName" to 12L),
            ),
        )
        val cache = cache(reader)

        cache.ensure(setOf(Uid("a"), Uid("b"), Uid("c")))

        assertEquals(AuthorDisplay.Fallback("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg"), cache.authors.value[Uid("a")])
        assertEquals(AuthorDisplay.Fallback("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/b.jpg"), cache.authors.value[Uid("b")])
        assertEquals(AuthorDisplay.Fallback(null), cache.authors.value[Uid("c")])
    }

    @Test
    fun `ドキュメントIDに使えないuidは取得せず代替表示にする`() = runBlocking {
        // 投稿の userId が空文字でも、変換（タスク 7.2）は文字列として通す。DocRef が止める値で落とさない
        val reader = FakeReader()
        val cache = cache(reader)

        cache.ensure(setOf(Uid(""), Uid("a/b")))

        assertEquals(emptyList(), reader.gets)
        assertEquals(AuthorDisplay.Fallback(null), cache.authors.value[Uid("")])
        assertEquals(AuthorDisplay.Fallback(null), cache.authors.value[Uid("a/b")])
    }

    @Test
    fun `代替表示の名前はiOSと同じ「ユーザー」で、uidを含まない`() {
        assertEquals("ユーザー", AuthorDisplay.FALLBACK_NAME)
        assertEquals("ユーザー", AuthorDisplay.Fallback(null).name)
        assertEquals("ユーザー", AuthorDisplay.Fallback("https://example.com/a.jpg").name)
    }

    // ── 取得の回数と並列（要件 4.6）──

    @Test
    fun `取得済みのuidと、無いと分かったuidは取り直さない`() = runBlocking {
        val reader = FakeReader(mapOf(profile("a", "displayName" to "そら")))
        val cache = cache(reader)

        cache.ensure(setOf(Uid("a"), Uid("missing")))
        cache.ensure(setOf(Uid("a"), Uid("missing"), Uid("b")))

        // 並列に取るので、順は問わない
        assertEquals(listOf("publicProfiles/a", "publicProfiles/b", "publicProfiles/missing"), reader.gets.sorted())
    }

    @Test
    fun `取得に失敗したuidは、次の要求で取り直す`() = runBlocking {
        // iOS も失敗を覚えず、次のページの読み込みで取り直す（HomeViewModel.swift の fetchAuthorsForCurrentPosts）
        val reader = FakeReader(mapOf(profile("a", "displayName" to "そら")))
        reader.failing += "publicProfiles/a"
        val cache = cache(reader)

        cache.ensure(setOf(Uid("a")))
        reader.failing.clear()
        cache.ensure(setOf(Uid("a")))

        assertEquals(2, reader.gets.size)
        assertEquals(AuthorDisplay.Named("そら", null), cache.authors.value[Uid("a")])
    }

    @Test
    fun `同時に取得するのは、要求が重なっても最大8件`() = runBlocking {
        withTimeout(5_000) {
            val reader = FakeReader().apply { gate = CompletableDeferred() }
            val cache = cache(reader)

            // 2 つの要求が重なっても、合わせて 8 件まで（要求ごとの上限ではない）
            val first = launch { cache.ensure((1..10).map { Uid("first$it") }.toSet()) }
            val second = launch { cache.ensure((1..10).map { Uid("second$it") }.toSet()) }
            reader.awaitGets(8)
            // 上限が効いていなければ、ここで残りも取得を始める
            repeat(100) { yield() }
            val started = reader.gets.size
            reader.gate?.complete(Unit)
            first.join()
            second.join()

            assertEquals(8, started, "止めている間に取得を始めた件数")
            assertEquals(8, reader.peak.get(), "同時に取得中だった件数の最大")
            assertEquals(20, reader.gets.size)
        }
    }

    @Test
    fun `取得中のuidをもう一度要求しても取得は1回で、後の要求も結果が入るまで待つ`() = runBlocking {
        withTimeout(5_000) {
            val reader = FakeReader(mapOf(profile("a", "displayName" to "そら"))).apply { gate = CompletableDeferred() }
            val cache = cache(reader)

            val first = launch { cache.ensure(setOf(Uid("a"))) }
            reader.awaitGets(1)
            var secondDone = false
            val second = launch {
                cache.ensure(setOf(Uid("a")))
                secondDone = true
            }
            repeat(100) { yield() }
            val doneWhileFetching = secondDone
            reader.gate?.complete(Unit)
            second.join()
            val shownWhenSecondReturned = cache.authors.value[Uid("a")]
            first.join()

            assertEquals(1, reader.gets.size, "取得の回数")
            assertEquals(false, doneWhileFetching, "取得中なのに後の要求が先に戻った")
            assertEquals(AuthorDisplay.Named("そら", null), shownWhenSecondReturned)
        }
    }

    // ── ログアウト（要件 2.9）──

    @Test
    fun `作られたときにSessionManagerへ登録し、ログアウトで捨てて次は取り直す`() = runBlocking {
        val reader = FakeReader(mapOf(profile("a", "displayName" to "そら")))
        val cache = cache(reader)
        cache.ensure(setOf(Uid("a")))

        sessionManager.clearLocalUserData()

        assertEquals(1, sessionManager.states.size, "登録した状態の数")
        assertEquals(emptyMap(), cache.authors.value)
        cache.ensure(setOf(Uid("a")))
        assertEquals(2, reader.gets.size, "ログアウトの後に取り直していない")
    }

    @Test
    fun `ログアウトの前に始めた取得の結果は、ログアウトの後に書き戻さない`() = runBlocking {
        withTimeout(5_000) {
            val reader = FakeReader(mapOf(profile("a", "displayName" to "そら"))).apply { gate = CompletableDeferred() }
            val cache = cache(reader)

            val job = launch { cache.ensure(setOf(Uid("a"))) }
            reader.awaitGets(1)
            cache.clearOnSignOut()
            reader.gate?.complete(Unit)
            job.join()

            assertEquals(emptyMap(), cache.authors.value)
        }
    }

    @Test
    fun `Firebase Authenticationのプロフィールを受け取らない`() {
        // 要件 4.4。コンストラクタで受け取れないものは表示に使えない
        val forbidden = setOf(FirebaseAuth::class.java, AuthRepository::class.java, AuthClient::class.java)

        val parameterTypes = DefaultAuthorProfileCache::class.java.constructors.flatMap { it.parameterTypes.toList() }

        assertTrue(parameterTypes.isNotEmpty(), "コンストラクタの引数を読めていない")
        assertTrue(parameterTypes.none { type -> forbidden.any { it.isAssignableFrom(type) } }, "認証の部品を受け取っている: $parameterTypes")
    }
}
