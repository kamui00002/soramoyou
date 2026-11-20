// ⭐️ プロフィールと投稿一覧の読み取りの単体テスト（タスク 15.1・要件 10.1〜10.5・4.10）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.OwnProfile
import com.yoshidometoru.soramoyou.data.model.PublicProfileView
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.DefaultPostDocumentReader
import com.yoshidometoru.soramoyou.data.remote.read.QuerySpec
import com.yoshidometoru.soramoyou.data.remote.read.RawCursor
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.read.RemoteImageUrlPolicy
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.platform.ParamValue
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking

/**
 * プロフィールの読み取りが、自分の投稿・他人の公開投稿をそれぞれ決まった形（[QuerySpec.OwnPosts]・[QuerySpec.UserPublicPosts]）だけで読み、
 * フィードと同じ規則（1 件単位の変換・変換前に読んだ件数で決める続きと起点）でページにし、取得元を付けて変換の失敗を記録すること、
 * 公開プロフィールの `id` の一致を検査すること、自分のユーザー文書を監視することを確かめる（設計書 :865-876）。
 */
class ProfileRepositoryTest {

    private val analytics = RecordingRepositoryAnalytics()
    private val me = Uid("me")

    private fun repository(reader: FakeFirestoreReader, signedIn: Uid? = me, imageUrls: RemoteImageUrlPolicy = RemoteImageUrlPolicy.PRODUCTION) =
        DefaultProfileRepository(reader, DefaultPostDocumentReader(imageUrls), { signedIn }, analytics, imageUrls)

    private fun fullPage(): List<RawDocument> = (1..QuerySpec.OwnPosts.PAGE_SIZE).map { postDocument("P$it", "me") }

    private fun publicProfile(id: String?, vararg fields: Pair<String, Any?>): RawDocument =
        RawDocument("someone", buildMap { if (id != null) put("id", id); putAll(fields) })

    // --- 自分の投稿 ---

    @Test
    fun `自分の投稿は、ログイン中のuidで自分の投稿の形を読み、満杯のページは続きありで返す`() = runBlocking {
        val raw = rawPage(fullPage())
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Ok(raw)))

        val page = assertIs<AppResult.Ok<FeedPage>>(repository(reader).ownPostsPage(after = null)).value

        assertEquals(listOf<Pair<QuerySpec, ReadSource>>(QuerySpec.OwnPosts(me, after = null) to ReadSource.SERVER), reader.queries)
        assertEquals((1..50).map { PostId("P$it") }, page.posts.map { it.postId })
        assertSame(raw.cursor, page.next)
        assertFalse(page.reachedEnd)
    }

    @Test
    fun `自分の投稿の続きは、渡された起点をそのまま形に載せて読む`() = runBlocking {
        val after = RawCursor("前のページの最後の1件")
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Ok(rawPage(fullPage()))))

        repository(reader).ownPostsPage(after)

        assertSame(after, (reader.queries.single().first as QuerySpec.OwnPosts).after)
    }

    @Test
    fun `自分の投稿の壊れた1件は除いてuser_postsで記録し、続きと起点は変換前に読んだドキュメントで決める`() = runBlocking {
        // 末尾が壊れた満杯のページ：変換後は 49 件だが、読んだのは 50 件なので続きあり・起点は壊れた 1 件
        val documents = (1..49).map { postDocument("P$it", "me") } + brokenPostDocument("BROKEN")
        val raw = rawPage(documents)
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Ok(raw)))

        val page = assertIs<AppResult.Ok<FeedPage>>(repository(reader).ownPostsPage(after = null)).value

        assertEquals(49, page.posts.size)
        assertEquals(1, page.skippedCount)
        assertFalse(page.reachedEnd)
        assertSame(raw.cursor, page.next)
        assertEquals(ParamValue.S("user_posts"), analytics.events.single().second["source"])
        assertEquals(ParamValue.S("posts/BROKEN"), analytics.events.single().second["path"])
    }

    @Test
    fun `自分の投稿が50件に満たないページは続きなし`() = runBlocking {
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Ok(rawPage(listOf(postDocument("A", "me"))))))

        assertTrue(assertIs<AppResult.Ok<FeedPage>>(repository(reader).ownPostsPage(after = null)).value.reachedEnd)
    }

    @Test
    fun `ログインしていなければ、自分の投稿は読まずにPermissionDeniedを返す`() = runBlocking {
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Ok(rawPage(fullPage()))))

        assertEquals(AppResult.Err(AppError.PermissionDenied), repository(reader, signedIn = null).ownPostsPage(after = null))
        assertEquals(emptyList(), reader.queries)
    }

    @Test
    fun `投稿一覧の取得自体の失敗は同じ種類のErrで返し、ここでは記録しない`() = runBlocking {
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Err(AppError.Network)))

        assertEquals(AppResult.Err(AppError.Network), repository(reader).ownPostsPage(after = null))
        assertEquals(AppResult.Err(AppError.Network), repository(reader).userPublicPostsPage(Uid("u2"), after = null))
        assertEquals(emptyList(), analytics.errors)
        assertEquals(emptyList(), analytics.events)
    }

    // --- 他人の公開投稿 ---

    @Test
    fun `他人の公開投稿は、相手のuidで公開投稿の形を読み、壊れた1件はpublic_postsで記録する`() = runBlocking {
        val after = RawCursor("前のページの最後の1件")
        val raw = rawPage(listOf(postDocument("A", "u2"), brokenPostDocument("BROKEN")))
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Ok(raw)))

        val page = assertIs<AppResult.Ok<FeedPage>>(repository(reader).userPublicPostsPage(Uid("u2"), after)).value

        assertEquals(listOf<Pair<QuerySpec, ReadSource>>(QuerySpec.UserPublicPosts(Uid("u2"), after) to ReadSource.SERVER), reader.queries)
        assertEquals(listOf(PostId("A")), page.posts.map { it.postId })
        assertTrue(page.reachedEnd)
        assertEquals(ParamValue.S("public_posts"), analytics.events.single().second["source"])
    }

    @Test
    fun `他人の公開投稿は、ログインしていなくても読む（公開投稿はrulesが誰にでも許す）`() = runBlocking {
        val reader = FakeFirestoreReader(pages = listOf(AppResult.Ok(rawPage(emptyList()))))

        assertIs<AppResult.Ok<FeedPage>>(repository(reader, signedIn = null).userPublicPostsPage(Uid("u2"), after = null))
        assertEquals(1, reader.queries.size)
    }

    // --- 他人の公開プロフィール ---

    @Test
    fun `公開プロフィールは、中のidが要求したuidと一致すれば、表示名・アイコン・自己紹介・投稿数を返す`() = runBlocking {
        val doc = publicProfile(
            "u2",
            "displayName" to "そら",
            "photoURL" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg",
            "bio" to "空が好き",
            "postsCount" to 12L,
        )
        val reader = FakeFirestoreReader(documents = mapOf("publicProfiles/u2" to AppResult.Ok(doc)))

        assertEquals(
            AppResult.Ok(PublicProfileView(Uid("u2"), AuthorDisplay.Named("そら", "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg"), "空が好き", 12L)),
            repository(reader).fetchPublic(Uid("u2")),
        )
        assertEquals(listOf(DocRef.publicProfile(Uid("u2")) to ReadSource.DEFAULT), reader.gets)
    }

    @Test
    fun `公開プロフィールの中のidが一致しなければ、中身を使わず代替表示で返す`() = runBlocking {
        // 中の id が要求した uid と違う公開プロフィール（iOS の issue #133）
        val doc = publicProfile("someone-else", "displayName" to "なりすまし", "bio" to "偽物", "postsCount" to 99L)
        val reader = FakeFirestoreReader(documents = mapOf("publicProfiles/u2" to AppResult.Ok(doc)))

        assertEquals(AppResult.Ok(PublicProfileView.fallback(Uid("u2"))), repository(reader).fetchPublic(Uid("u2")))
    }

    @Test
    fun `公開プロフィールが無ければ、代替表示で返す（usersはrulesで本人しか読めないので代わりに読まない）`() = runBlocking {
        val reader = FakeFirestoreReader()

        assertEquals(AppResult.Ok(PublicProfileView.fallback(Uid("u2"))), repository(reader).fetchPublic(Uid("u2")))
        assertEquals(listOf("publicProfiles/u2"), reader.gets.map { it.first.path })
    }

    @Test
    fun `表示名が無いか空なら、名前は代替表示にし、アイコン・自己紹介・投稿数は使う`() = runBlocking {
        val doc = publicProfile("u2", "displayName" to "  ", "photoURL" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg", "bio" to "空", "postsCount" to 3L)
        val reader = FakeFirestoreReader(documents = mapOf("publicProfiles/u2" to AppResult.Ok(doc)))

        assertEquals(
            AppResult.Ok(PublicProfileView(Uid("u2"), AuthorDisplay.Fallback("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg"), "空", 3L)),
            repository(reader).fetchPublic(Uid("u2")),
        )
        assertEquals(AuthorDisplay.FALLBACK_NAME, assertIs<AppResult.Ok<PublicProfileView>>(repository(reader).fetchPublic(Uid("u2"))).value.author.name)
    }

    @Test
    fun `httpsでないアイコン・数でない投稿数・文字列でない自己紹介は使わない`() = runBlocking {
        val doc = publicProfile("u2", "displayName" to "そら", "photoURL" to "http://example.com/a.jpg", "bio" to 1L, "postsCount" to "12")
        val reader = FakeFirestoreReader(documents = mapOf("publicProfiles/u2" to AppResult.Ok(doc)))

        assertEquals(
            AppResult.Ok(PublicProfileView(Uid("u2"), AuthorDisplay.Named("そら", null), null, 0L)),
            repository(reader).fetchPublic(Uid("u2")),
        )
    }

    @Test
    fun `本番のStorageの形でないアイコンは、httpsでもエミュレータの形でも使わない`() = runBlocking {
        val reader = FakeFirestoreReader(
            documents = mapOf(
                "publicProfiles/u2" to AppResult.Ok(publicProfile("u2", "displayName" to "そら", "photoURL" to "https://example.com/a.jpg")),
                "publicProfiles/u3" to AppResult.Ok(publicProfile("u3", "displayName" to "くも", "photoURL" to "http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/b.jpg")),
            ),
        )

        assertEquals(AppResult.Ok(PublicProfileView(Uid("u2"), AuthorDisplay.Named("そら", null), null, 0L)), repository(reader).fetchPublic(Uid("u2")))
        assertEquals(AppResult.Ok(PublicProfileView(Uid("u3"), AuthorDisplay.Named("くも", null), null, 0L)), repository(reader).fetchPublic(Uid("u3")))
    }

    @Test
    fun `公開プロフィールの取得自体の失敗は、同じ種類のErrで返す（再試行で変わりうるので代替表示にしない）`() = runBlocking {
        val reader = FakeFirestoreReader(documents = mapOf("publicProfiles/u2" to AppResult.Err(AppError.Network)))

        assertEquals(AppResult.Err(AppError.Network), repository(reader).fetchPublic(Uid("u2")))
    }

    @Test
    fun `ドキュメントIDに使えないuidは、取得せずに代替表示で返す`() = runBlocking {
        val reader = FakeFirestoreReader()

        assertEquals(AppResult.Ok(PublicProfileView.fallback(Uid(""))), repository(reader).fetchPublic(Uid("")))
        assertEquals(emptyList(), reader.gets)
    }

    // --- 自分のユーザー文書の監視 ---

    @Test
    fun `自分のユーザー文書を監視し、届くたびに表示名・アイコン・自己紹介・投稿数をOkで流し、無いときはNotFoundを流す`() = runBlocking {
        val first = RawDocument("me", mapOf("displayName" to "そら", "photoURL" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/me.jpg", "bio" to "空", "postsCount" to 5L))
        val repaired = RawDocument("me", mapOf("id" to "me"))
        val reader = FakeFirestoreReader(
            streams = mapOf("users/me" to flowOf(AppResult.Ok(null), AppResult.Ok(repaired), AppResult.Ok(first))),
        )

        val emitted = repository(reader).observeOwn().toList()

        assertEquals(listOf(DocRef.user(me)), reader.observed)
        assertEquals(
            listOf(
                AppResult.Err(AppError.NotFound),
                AppResult.Ok(OwnProfile(me, displayName = null, photoUrl = null, bio = null, postsCount = 0L)),
                AppResult.Ok(OwnProfile(me, displayName = "そら", photoUrl = "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/me.jpg", bio = "空", postsCount = 5L)),
            ),
            emitted,
        )
    }

    @Test
    fun `自分のユーザー文書のアイコンも、本番のStorageの形でなければ使わない`() = runBlocking {
        val doc = RawDocument("me", mapOf("displayName" to "そら", "photoURL" to "https://example.com/me.jpg"))
        val reader = FakeFirestoreReader(streams = mapOf("users/me" to flowOf(AppResult.Ok(doc))))

        assertEquals(
            listOf(AppResult.Ok(OwnProfile(me, displayName = "そら", photoUrl = null, bio = null, postsCount = 0L))),
            repository(reader).observeOwn().toList(),
        )
    }

    @Test
    fun `検証用の形を渡すと、自分と他人のアイコンはエミュレータのStorageの形だけを使う`() = runBlocking {
        val emu = "http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/users%2Fme%2Fprofile.jpg?alt=media&token=t"
        val prod = "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/users%2Fu2%2Fprofile.jpg"
        val reader = FakeFirestoreReader(
            documents = mapOf("publicProfiles/u2" to AppResult.Ok(publicProfile("u2", "displayName" to "そら", "photoURL" to prod))),
            streams = mapOf("users/me" to flowOf(AppResult.Ok(RawDocument("me", mapOf("photoURL" to emu))))),
        )
        val emulator = repository(reader, imageUrls = RemoteImageUrlPolicy.EMULATOR)

        assertEquals(
            listOf(AppResult.Ok(OwnProfile(me, displayName = null, photoUrl = emu, bio = null, postsCount = 0L))),
            emulator.observeOwn().toList(),
        )
        assertEquals(AppResult.Ok(PublicProfileView(Uid("u2"), AuthorDisplay.Named("そら", null), null, 0L)), emulator.fetchPublic(Uid("u2")))
    }

    @Test
    fun `自分のプロフィールの名前は、表示名があればそれを、無いか空なら代替表示にし、どちらもアイコンは使う`() {
        val named = OwnProfile(me, displayName = "そら", photoUrl = "https://example.com/me.jpg", bio = null, postsCount = 0L)
        val blank = named.copy(displayName = "  ")
        val missing = named.copy(displayName = null)

        assertEquals(AuthorDisplay.Named("そら", "https://example.com/me.jpg"), named.display)
        // uid などを名前に使わない（要件 10.3）
        assertEquals(AuthorDisplay.Fallback("https://example.com/me.jpg"), blank.display)
        assertEquals(AuthorDisplay.Fallback("https://example.com/me.jpg"), missing.display)
    }

    @Test
    fun `自分のユーザー文書の監視の失敗は、同じ種類のErrで流す`() = runBlocking {
        val reader = FakeFirestoreReader(streams = mapOf("users/me" to flowOf(AppResult.Err(AppError.PermissionDenied))))

        assertEquals(listOf<AppResult<OwnProfile>>(AppResult.Err(AppError.PermissionDenied)), repository(reader).observeOwn().toList())
    }

    @Test
    fun `ログインしていなければ、監視せずにPermissionDeniedを1回流して終わる`() = runBlocking {
        val reader = FakeFirestoreReader()

        assertEquals(listOf<AppResult<OwnProfile>>(AppResult.Err(AppError.PermissionDenied)), repository(reader, signedIn = null).observeOwn().toList())
        assertEquals(emptyList(), reader.observed)
    }
}
