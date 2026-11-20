// ⭐️ Firestore からの読み取りの唯一の入口の単体テスト（タスク 7.1・23.1・31.1・要件 1.4・4.1・4.2・7.19・12.3）
package com.yoshidometoru.soramoyou.data.remote.read

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import java.util.concurrent.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking

/**
 * 読み取りの入口が、[QuerySpec] を定めた形のクエリだけに展開し、結果を「生のドキュメントの列＋最後の 1 件のカーソル」で返し、
 * SDK の失敗を [AppResult.Err] に写すことを確かめる（設計書 :678-708）。SDK は継ぎ目の偽物に差し替える。
 */
class DefaultFirestoreReaderTest {

    private fun snapshot(id: String) = RawSnapshot(RawDocument(id, mapOf("userId" to "u-$id")), token = "token-$id")

    @Test
    fun `公開投稿のフィードは、postsの公開範囲が公開のものを作成日時の新しい順に20件取る形に展開する`() {
        assertEquals(
            QueryPlan(
                collection = "posts",
                equalTo = listOf("visibility" to "public"),
                orderByDescending = listOf("createdAt"),
                limit = 20,
                after = null,
            ),
            DefaultFirestoreReader.planOf(QuerySpec.PublicFeed(after = null)),
        )
    }

    @Test
    fun `続きの起点を指定すると、そのカーソルをそのまま起点にする`() {
        val cursor = RawCursor("前のページの最後の1件")
        assertSame(cursor, DefaultFirestoreReader.planOf(QuerySpec.PublicFeed(after = cursor)).after)
        assertSame(cursor, DefaultFirestoreReader.planOf(QuerySpec.OwnPosts(Uid("u1"), after = cursor)).after)
        assertSame(cursor, DefaultFirestoreReader.planOf(QuerySpec.UserPublicPosts(Uid("u1"), after = cursor)).after)
    }

    @Test
    fun `自分の投稿は、postsの投稿者が自分のものを公開範囲で絞らずに作成日時の新しい順に50件取る形に展開する`() {
        assertEquals(
            QueryPlan(
                collection = "posts",
                equalTo = listOf("userId" to "u1"),
                orderByDescending = listOf("createdAt"),
                limit = 50,
                after = null,
            ),
            DefaultFirestoreReader.planOf(QuerySpec.OwnPosts(Uid("u1"), after = null)),
        )
    }

    @Test
    fun `他人の公開投稿は、公開範囲が公開である条件と投稿者の条件を必ず含め、作成日時の新しい順に50件取る形に展開する`() {
        // 公開範囲の条件が無いと、rules が非公開の投稿を含みうるクエリとしてクエリ全体を拒否する（要件 10.5）
        assertEquals(
            QueryPlan(
                collection = "posts",
                equalTo = listOf("visibility" to "public", "userId" to "u2"),
                orderByDescending = listOf("createdAt"),
                limit = 50,
                after = null,
            ),
            DefaultFirestoreReader.planOf(QuerySpec.UserPublicPosts(Uid("u2"), after = null)),
        )
    }

    @Test
    fun `自分の全投稿数の集計は、postsの投稿者が自分のものを公開範囲で絞らずに数える形に展開する`() {
        assertEquals(
            CountPlan(collection = "posts", equalTo = listOf("userId" to "u1")),
            DefaultFirestoreReader.countPlanOf(CountSpec.OwnPosts(Uid("u1"))),
        )
    }

    @Test
    fun `自分の公開投稿数の集計は、投稿者の条件と公開範囲が公開である条件の両方で数える形に展開する`() {
        // 公開範囲の条件が無いと、他人に見せる公開プロフィールの投稿数に、非公開・フォロワー限定の投稿の件数が混ざる
        assertEquals(
            CountPlan(collection = "posts", equalTo = listOf("userId" to "u1", "visibility" to "public")),
            DefaultFirestoreReader.countPlanOf(CountSpec.OwnPublicPosts(Uid("u1"))),
        )
    }

    @Test
    fun `退会の取得のうち、自分がフォローした側は、followsのfollowerIdが自分のものを並び順なしで50件取る形に展開する`() {
        // 並び順を付けない：付けると複合インデックスが要り、deploy 漏れで退会が丸ごと失敗する経路が増える（iOS FirestoreService.swift:956-958）。
        // 件数を付ける：follows の rules は list に limit <= 50 を課し、上限なしの取得は PERMISSION_DENIED になる（firestore.rules:237）
        assertEquals(
            QueryPlan(
                collection = "follows",
                equalTo = listOf("followerId" to "u1"),
                orderByDescending = emptyList(),
                limit = 50,
                after = null,
            ),
            DefaultFirestoreReader.planOf(QuerySpec.DrainByField(DrainTarget.FOLLOWS_AS_FOLLOWER, Uid("u1"))),
        )
    }

    @Test
    fun `退会の取得のうち、自分がフォローされた側は、followsのfolloweeIdが自分のものを並び順なしで50件取る形に展開する`() {
        assertEquals(
            QueryPlan(
                collection = "follows",
                equalTo = listOf("followeeId" to "u1"),
                orderByDescending = emptyList(),
                limit = 50,
                after = null,
            ),
            DefaultFirestoreReader.planOf(QuerySpec.DrainByField(DrainTarget.FOLLOWS_AS_FOLLOWEE, Uid("u1"))),
        )
    }

    @Test
    fun `退会の取得のうち、自分のいいねとコメントは、userIdが自分のものを並び順なしで50件取る形に展開する`() {
        assertEquals(
            QueryPlan(
                collection = "likes",
                equalTo = listOf("userId" to "u1"),
                orderByDescending = emptyList(),
                limit = 50,
                after = null,
            ),
            DefaultFirestoreReader.planOf(QuerySpec.DrainByField(DrainTarget.LIKES, Uid("u1"))),
        )
        assertEquals(
            QueryPlan(
                collection = "comments",
                equalTo = listOf("userId" to "u1"),
                orderByDescending = emptyList(),
                limit = 50,
                after = null,
            ),
            DefaultFirestoreReader.planOf(QuerySpec.DrainByField(DrainTarget.COMMENTS, Uid("u1"))),
        )
    }

    @Test
    fun `空になるまで取る形は、続きの起点を持たない（消してから先頭を取り直す）`() {
        // 起点を受け取る引数が無いので、どの形も after は常に null。消した分は先頭から消えるので、次の取得はまた先頭から読む
        DrainTarget.entries.forEach { target ->
            assertNull(DefaultFirestoreReader.planOf(QuerySpec.DrainByField(target, Uid("u1"))).after, "$target")
        }
    }

    @Test
    fun `退会の全件取得のうち、自分の投稿と下書きは、userIdが自分のものを件数の上限も並び順もなしで取る形に展開する`() {
        // 上限なし：iOS も postsCollection / draftsCollection の getDocuments(source: .server) で全件を取る（FirestoreService.swift:925-933）
        assertEquals(
            QueryPlan(
                collection = "posts",
                equalTo = listOf("userId" to "u1"),
                orderByDescending = emptyList(),
                limit = null,
                after = null,
            ),
            DefaultFirestoreReader.planOf(QuerySpec.AllOwned(OwnedCollection.POSTS, Uid("u1"))),
        )
        assertEquals(
            QueryPlan(
                collection = "drafts",
                equalTo = listOf("userId" to "u1"),
                orderByDescending = emptyList(),
                limit = null,
                after = null,
            ),
            DefaultFirestoreReader.planOf(QuerySpec.AllOwned(OwnedCollection.DRAFTS, Uid("u1"))),
        )
    }

    @Test
    fun `退会の全件取得のうち、お気に入りは、users配下のfavoritesを条件なしで全件取る形に展開する`() {
        assertEquals(
            QueryPlan(
                collection = "users/u1/favorites",
                equalTo = emptyList(),
                orderByDescending = emptyList(),
                limit = null,
                after = null,
            ),
            DefaultFirestoreReader.planOf(QuerySpec.AllOwned(OwnedCollection.FAVORITES, Uid("u1"))),
        )
    }

    @Test
    fun `お気に入りのパスは、区切りを含むuidでは作らない`() {
        // 区切りを含む uid は DocRef.user の検査で止める
        assertFailsWith<IllegalArgumentException> {
            DefaultFirestoreReader.planOf(QuerySpec.AllOwned(OwnedCollection.FAVORITES, Uid("a/favorites/b")))
        }
        assertFailsWith<IllegalArgumentException> {
            DefaultFirestoreReader.planOf(QuerySpec.AllOwned(OwnedCollection.FAVORITES, Uid("")))
        }
    }

    @Test
    fun `退会の取得は、呼び出し側が既定の取得元を指定しても、必ずサーバーで取る`() = runBlocking {
        // 既定の取得元は通信が切れるとキャッシュへ落ち、キャッシュにある一部だけを「全件」と誤認して、残りを消さずに退会を終えてしまう
        // （iOS FirestoreService.swift:960-965）
        val specs = listOf(
            QuerySpec.DrainByField(DrainTarget.FOLLOWS_AS_FOLLOWER, Uid("u1")),
            QuerySpec.DrainByField(DrainTarget.FOLLOWS_AS_FOLLOWEE, Uid("u1")),
            QuerySpec.DrainByField(DrainTarget.LIKES, Uid("u1")),
            QuerySpec.DrainByField(DrainTarget.COMMENTS, Uid("u1")),
            QuerySpec.AllOwned(OwnedCollection.POSTS, Uid("u1")),
            QuerySpec.AllOwned(OwnedCollection.DRAFTS, Uid("u1")),
            QuerySpec.AllOwned(OwnedCollection.FAVORITES, Uid("u1")),
        )
        specs.forEach { spec ->
            val client = FakeFirestoreReadClient()
            val reader = DefaultFirestoreReader(client)

            assertOk(reader.query(spec, ReadSource.DEFAULT))
            assertOk(reader.query(spec))

            assertEquals(
                listOf(ReadSource.SERVER, ReadSource.SERVER),
                client.queries.map { it.second },
                "取得元が SERVER でない形: $spec",
            )
        }
    }

    @Test
    fun `退会の取得を強制するのは退会の形だけで、フィードなどの取得元は呼び出し側の指定のまま`() = runBlocking {
        val client = FakeFirestoreReadClient()
        val reader = DefaultFirestoreReader(client)

        reader.query(QuerySpec.PublicFeed(after = null), ReadSource.DEFAULT)
        reader.query(QuerySpec.OwnPosts(Uid("u1"), after = null), ReadSource.DEFAULT)
        reader.query(QuerySpec.UserPublicPosts(Uid("u2"), after = null), ReadSource.DEFAULT)

        assertEquals(List(3) { ReadSource.DEFAULT }, client.queries.map { it.second })
    }

    @Test
    fun `退会の取得は、通信が切れたら空のOkではなくErrで返す（取れなかったものを0件と誤認しない）`() = runBlocking {
        val client = FakeFirestoreReadClient().apply {
            failure = FirestoreReadFailure(AppError.Network, IllegalStateException("SDK"))
        }
        val reader = DefaultFirestoreReader(client)

        assertEquals(AppResult.Err(AppError.Network), reader.query(QuerySpec.DrainByField(DrainTarget.LIKES, Uid("u1"))))
        assertEquals(AppResult.Err(AppError.Network), reader.query(QuerySpec.AllOwned(OwnedCollection.POSTS, Uid("u1"))))
        assertEquals(AppResult.Err(AppError.Network), reader.query(QuerySpec.AllOwned(OwnedCollection.FAVORITES, Uid("u1"))))
    }

    @Test
    fun `お気に入りの取得は、uidが区切りを含むときもErrで返し、例外を外に出さない`() = runBlocking {
        val client = FakeFirestoreReadClient()

        val result = DefaultFirestoreReader(client).query(QuerySpec.AllOwned(OwnedCollection.FAVORITES, Uid("a/b")))

        assertEquals(AppResult.Err(AppError.Unknown("IllegalArgumentException")), result)
        assertEquals(emptyList(), client.queries)
    }

    @Test
    fun `クエリは展開した形と取得元で継ぎ目を呼び、生のドキュメントの列と最後の1件を起点とするカーソルを返す`() = runBlocking {
        val results = listOf(snapshot("A"), snapshot("B"), snapshot("C"))
        val client = FakeFirestoreReadClient(results = results)
        val spec = QuerySpec.PublicFeed(after = null)

        val page = assertOk(DefaultFirestoreReader(client).query(spec, ReadSource.SERVER))

        assertEquals(listOf(DefaultFirestoreReader.planOf(spec) to ReadSource.SERVER), client.queries)
        assertEquals(results.map { it.document }, page.documents)
        assertSame(results.last().token, page.cursor?.token)
    }

    @Test
    fun `クエリの結果が0件ならカーソルはnull`() = runBlocking {
        val page = assertOk(DefaultFirestoreReader(FakeFirestoreReadClient()).query(QuerySpec.PublicFeed(after = null)))

        assertEquals(emptyList(), page.documents)
        assertNull(page.cursor)
    }

    @Test
    fun `集計は展開した形で継ぎ目を呼び、数えた件数をそのまま返す`() = runBlocking {
        val client = FakeFirestoreReadClient(countResult = 7L)
        val spec = CountSpec.OwnPublicPosts(Uid("u1"))

        assertEquals(AppResult.Ok(7L), DefaultFirestoreReader(client).count(spec))
        assertEquals(listOf(DefaultFirestoreReader.countPlanOf(spec)), client.counts)
    }

    @Test
    fun `単一ドキュメントの取得は、DocRefのパスと取得元で継ぎ目を呼び、無ければOk(null)を返す`() = runBlocking {
        val post = RawDocument("P1", mapOf("userId" to "u1"))
        val client = FakeFirestoreReadClient(documents = mapOf("posts/P1" to post))
        val reader = DefaultFirestoreReader(client)

        assertEquals(AppResult.Ok(post), reader.get(DocRef.post(PostId("P1")), ReadSource.SERVER))
        assertEquals(AppResult.Ok(null), reader.get(DocRef.post(PostId("P2"))))
        assertEquals(listOf("posts/P1" to ReadSource.SERVER, "posts/P2" to ReadSource.DEFAULT), client.gets)
    }

    @Test
    fun `写せる失敗は、写した種類のErrで返す`() = runBlocking {
        val client = FakeFirestoreReadClient().apply {
            failure = FirestoreReadFailure(AppError.PermissionDenied, IllegalStateException("SDK"))
        }
        val reader = DefaultFirestoreReader(client)

        assertEquals(AppResult.Err(AppError.PermissionDenied), reader.get(DocRef.post(PostId("P1"))))
        assertEquals(AppResult.Err(AppError.PermissionDenied), reader.query(QuerySpec.PublicFeed(after = null)))
        assertEquals(AppResult.Err(AppError.PermissionDenied), reader.count(CountSpec.OwnPosts(Uid("u1"))))
    }

    @Test
    fun `写せない例外は、例外の型名だけを載せたUnknownで返す`() = runBlocking {
        val client = FakeFirestoreReadClient().apply { failure = IllegalStateException("中身は載せない") }
        val reader = DefaultFirestoreReader(client)

        assertEquals(AppResult.Err(AppError.Unknown("IllegalStateException")), reader.get(DocRef.post(PostId("P1"))))
        assertEquals(AppResult.Err(AppError.Unknown("IllegalStateException")), reader.query(QuerySpec.PublicFeed(after = null)))
        assertEquals(AppResult.Err(AppError.Unknown("IllegalStateException")), reader.count(CountSpec.OwnPosts(Uid("u1"))))
    }

    @Test
    fun `コルーチンの取り消しは失敗に写さず、そのまま伝える`() {
        val client = FakeFirestoreReadClient().apply { failure = CancellationException("取り消し") }
        val reader = DefaultFirestoreReader(client)

        assertFailsWith<CancellationException> { runBlocking { reader.get(DocRef.post(PostId("P1"))) } }
        assertFailsWith<CancellationException> { runBlocking { reader.query(QuerySpec.PublicFeed(after = null)) } }
        assertFailsWith<CancellationException> { runBlocking { reader.count(CountSpec.OwnPosts(Uid("u1"))) } }
    }

    @Test
    fun `監視は、DocRefのパスで継ぎ目を監視し、届いた中身を順にOkで流す（無ければOk(null)）`() = runBlocking {
        val first = RawDocument("u1", mapOf("displayName" to "そら"))
        val second = RawDocument("u1", mapOf("displayName" to "くも"))
        val client = FakeFirestoreReadClient(streams = mapOf("users/u1" to flowOf(first, null, second)))

        val emitted = DefaultFirestoreReader(client).observe(DocRef.user(Uid("u1"))).toList()

        assertEquals(listOf("users/u1"), client.observed)
        assertEquals(listOf(AppResult.Ok(first), AppResult.Ok(null), AppResult.Ok(second)), emitted)
    }

    @Test
    fun `監視の失敗は、写した種類のErrを1回流して終わる（写せない例外は型名だけのUnknown）`() = runBlocking {
        val doc = RawDocument("u1", emptyMap())
        val mapped = flow {
            emit(doc)
            throw FirestoreReadFailure(AppError.PermissionDenied, IllegalStateException("SDK"))
        }
        val unmapped = flow<RawDocument?> { throw IllegalStateException("中身は載せない") }
        val client = FakeFirestoreReadClient(streams = mapOf("users/u1" to mapped, "users/u2" to unmapped))
        val reader = DefaultFirestoreReader(client)

        assertEquals(
            listOf(AppResult.Ok(doc), AppResult.Err(AppError.PermissionDenied)),
            reader.observe(DocRef.user(Uid("u1"))).toList(),
        )
        assertEquals(
            listOf<AppResult<RawDocument?>>(AppResult.Err(AppError.Unknown("IllegalStateException"))),
            reader.observe(DocRef.user(Uid("u2"))).toList(),
        )
    }

    @Test
    fun `監視の中のコルーチンの取り消しは失敗に写さず、そのまま伝える`() {
        val client = FakeFirestoreReadClient(streams = mapOf("users/u1" to flow { throw CancellationException("取り消し") }))

        assertFailsWith<CancellationException> {
            runBlocking { DefaultFirestoreReader(client).observe(DocRef.user(Uid("u1"))).toList() }
        }
    }

    private fun <T> assertOk(result: AppResult<T>): T {
        if (result !is AppResult.Ok) throw AssertionError("Ok でない: $result")
        return result.value
    }
}
