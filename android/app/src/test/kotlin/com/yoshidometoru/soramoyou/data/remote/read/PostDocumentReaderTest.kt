// ⭐️ 投稿ドキュメントの 1 件単位の変換の単体テスト（タスク 7.2・要件 4.7・4.8・4.10・4.11）
package com.yoshidometoru.soramoyou.data.remote.read

import com.google.firebase.Timestamp
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.model.SkyType
import com.yoshidometoru.soramoyou.contract.model.TimeOfDay
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.data.model.PostImageView
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.EventName
import com.yoshidometoru.soramoyou.platform.ParamValue
import com.yoshidometoru.soramoyou.platform.PostDecodeSource
import com.yoshidometoru.soramoyou.platform.ScreenName
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 投稿ドキュメントの変換が、必須の 2 点（`userId` の文字列・URL が文字列の画像 1 件以上）だけで可否を決め、
 * それ以外の欠落・型違い・未知の値・iOS だけが持つ項目では失敗しないことを確かめる（設計書 PostDocumentReader 節 :713-721）。
 * ページ単位の変換では、飛ばした 1 件だけを `post_decode_failed` で記録し、Crashlytics への経路（logError）を使わないことも確かめる。
 */
class PostDocumentReaderTest {

    private val reader = DefaultPostDocumentReader(RemoteImageUrlPolicy.PRODUCTION)

    /** 表示に必須の項目だけを持つ投稿。 */
    private fun minimal(id: String = "P1"): RawDocument =
        RawDocument(id, mapOf("userId" to "u-1", "images" to listOf(mapOf("url" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$id.jpg"))))

    private fun image(url: Any?, order: Any?, width: Any? = 1080L, height: Any? = 1440L): Map<String, Any?> =
        mapOf("url" to url, "width" to width, "height" to height, "order" to order)

    private fun readOk(raw: RawDocument): PostView = assertIs<ReadOutcome.Ok>(reader.read(raw)).post

    // ---- 必須の 2 点 ----

    @Test
    fun `userIdと、URLが文字列の画像1件だけの投稿は表示でき、ほかの項目は値なしになる`() {
        val post = readOk(minimal())

        assertEquals(Uid("u-1"), post.userId)
        assertEquals(listOf("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/P1.jpg"), post.images.map { it.url })
        assertNull(post.caption)
        assertNull(post.hashtags)
        assertNull(post.visibility)
        assertNull(post.createdAt)
        assertNull(post.capturedAt)
        assertNull(post.timeOfDay)
        assertNull(post.skyType)
    }

    @Test
    fun `userIdが無いか文字列でない投稿は、posts付きのパスとiOSと同じ理由で飛ばす`() {
        val images = listOf(mapOf("url" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg"))
        assertEquals(
            ReadOutcome.Skipped("posts/NO-USER", DefaultPostDocumentReader.REASON_MISSING_REQUIRED_FIELDS),
            reader.read(RawDocument("NO-USER", mapOf("images" to images))),
        )
        assertEquals(
            ReadOutcome.Skipped("posts/NUM-USER", DefaultPostDocumentReader.REASON_MISSING_REQUIRED_FIELDS),
            reader.read(RawDocument("NUM-USER", mapOf("userId" to 42L, "images" to images))),
        )
    }

    @Test
    fun `imagesが無いか配列でない投稿は、iOSと同じ理由で飛ばす`() {
        assertEquals(
            ReadOutcome.Skipped("posts/NO-IMAGES", DefaultPostDocumentReader.REASON_INVALID_IMAGES),
            reader.read(RawDocument("NO-IMAGES", mapOf("userId" to "u-1"))),
        )
        assertEquals(
            ReadOutcome.Skipped("posts/MAP-IMAGES", DefaultPostDocumentReader.REASON_INVALID_IMAGES),
            reader.read(RawDocument("MAP-IMAGES", mapOf("userId" to "u-1", "images" to mapOf("url" to "x")))),
        )
    }

    @Test
    fun `URLが文字列の画像が1件も無い投稿は飛ばす`() {
        val images = listOf(mapOf("url" to 123L, "order" to 0L), mapOf("thumbnail" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/t.jpg"), "文字列の要素")
        assertEquals(
            ReadOutcome.Skipped("posts/NO-URL", DefaultPostDocumentReader.REASON_NO_IMAGE_WITH_URL),
            reader.read(RawDocument("NO-URL", mapOf("userId" to "u-1", "images" to images))),
        )
        assertEquals(
            ReadOutcome.Skipped("posts/EMPTY", DefaultPostDocumentReader.REASON_NO_IMAGE_WITH_URL),
            reader.read(RawDocument("EMPTY", mapOf("userId" to "u-1", "images" to emptyList<Any>()))),
        )
    }

    @Test
    fun `本番のStorageの形でない画像のURLは使わず、形に合う画像が1件も無ければ飛ばす`() {
        val images = listOf(
            image("file:///data/data/com.yoshidometoru.soramoyou/files/secret.jpg", order = 0L),
            image("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/ok.jpg", order = 1L) + ("thumbnail" to "https://example.com/ok_thumb.jpg"),
            image("https://example.com/other.jpg", order = 2L),
            image("http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/emu.jpg", order = 3L),
        )
        val post = readOk(RawDocument("MIXED", mapOf("userId" to "u-1", "images" to images)))
        assertEquals(listOf(PostImageView(url = "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/ok.jpg", thumbnail = null, width = 1080L, height = 1440L, order = 1L)), post.images)
        assertEquals("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/ok.jpg", post.coverImage.listUrl)

        // https でも別のホストの画像だけの投稿は、形に合う画像が無いので飛ばす
        val noStorage = listOf(image("content://media/external/images/media/1", order = 0L), image("https://example.com/a.jpg", order = 1L))
        assertEquals(
            ReadOutcome.Skipped("posts/LOCAL", DefaultPostDocumentReader.REASON_NO_IMAGE_WITH_URL),
            reader.read(RawDocument("LOCAL", mapOf("userId" to "u-1", "images" to noStorage))),
        )
    }

    @Test
    fun `検証用の形を渡すと、エミュレータのStorageの画像だけを読む`() {
        val emulatorReader = DefaultPostDocumentReader(RemoteImageUrlPolicy.EMULATOR)
        val emu = "http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/posts%2Fu-1%2Fa.jpg?alt=media&token=t"
        val prod = "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/posts%2Fu-1%2Fb.jpg"
        val images = listOf(image(prod, order = 0L), image(emu, order = 1L) + ("thumbnail" to prod))
        val post = assertIs<ReadOutcome.Ok>(emulatorReader.read(RawDocument("EMU", mapOf("userId" to "u-1", "images" to images)))).post
        assertEquals(listOf(PostImageView(url = emu, thumbnail = null, width = 1080L, height = 1440L, order = 1L)), post.images)
    }

    // ---- 画像 ----

    @Test
    fun `URLが文字列でない画像だけを落とし、幅・高さ・順番が読めない画像は値なしで残す`() {
        val images = listOf(
            image(url = 999L, order = 0L),
            image(url = "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/b.jpg", order = 1L, width = "1080", height = null),
            mapOf("url" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/c.jpg", "thumbnail" to 5L, "order" to 2L),
        )
        val post = readOk(RawDocument("P1", mapOf("userId" to "u-1", "images" to images)))

        assertEquals(
            listOf(
                PostImageView(url = "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/b.jpg", thumbnail = null, width = null, height = null, order = 1L),
                PostImageView(url = "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/c.jpg", thumbnail = null, width = null, height = null, order = 2L),
            ),
            post.images,
        )
    }

    @Test
    fun `画像は表示順の昇順に並べ、表示順が読めない画像は元の並びのまま末尾に置く`() {
        val images = listOf(
            image("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/no-order-1.jpg", order = null),
            image("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/2.jpg", order = 2L),
            image("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/0.jpg", order = 0L),
            image("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/no-order-2.jpg", order = 1.0),
            image("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/1.jpg", order = 1L),
        )
        val post = readOk(RawDocument("P1", mapOf("userId" to "u-1", "images" to images)))

        assertEquals(
            listOf("0", "1", "2", "no-order-1", "no-order-2").map { "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$it.jpg" },
            post.images.map { it.url },
        )
    }

    @Test
    fun `一覧ではorderが最小の画像のサムネイルを優先し、無ければ本体のURLを使い、複数枚かが分かる`() {
        val single = readOk(minimal())
        assertEquals("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/P1.jpg", single.coverImage.listUrl)
        assertFalse(single.hasMultipleImages)

        val images = listOf(
            image("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/second.jpg", order = 1L) + ("thumbnail" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/second_thumb.jpg"),
            image("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/first.jpg", order = 0L) + ("thumbnail" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/first_thumb.jpg"),
        )
        val multi = readOk(RawDocument("P2", mapOf("userId" to "u-1", "images" to images)))
        assertEquals("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/first_thumb.jpg", multi.coverImage.listUrl)
        assertTrue(multi.hasMultipleImages)
    }

    // ---- 必須でない項目 ----

    @Test
    fun `いいね数は欠けているか整数でなければ0にし、整数ならその値を使う`() {
        fun likes(value: Any?): Long =
            readOk(RawDocument("P1", minimal().data + ("likesCount" to value))).likesCount

        assertEquals(0L, readOk(minimal()).likesCount)
        assertEquals(0L, likes("7"))
        assertEquals(0L, likes(null))
        assertEquals(7L, likes(7L))
    }

    @Test
    fun `投稿IDはドキュメント内のpostIdよりドキュメントIDを優先する`() {
        val post = readOk(RawDocument("DOC-ID", minimal().data + ("postId" to "FIELD-ID")))

        assertEquals(PostId("DOC-ID"), post.postId)
    }

    @Test
    fun `型の合った項目はそのまま読み、日時はナノ秒まで保つ`() {
        val created = Instant.parse("2026-09-01T06:30:15.123456789Z")
        val captured = Instant.parse("2026-08-31T19:05:00Z")
        val data = minimal().data + mapOf(
            "caption" to "夕焼け",
            "hashtags" to listOf("空", "夕焼け"),
            "visibility" to "followers",
            "createdAt" to Timestamp(created.epochSecond, created.nano),
            "capturedAt" to Timestamp(captured.epochSecond, captured.nano),
            "timeOfDay" to "evening",
            "skyType" to "sunset",
        )
        val post = readOk(RawDocument("P1", data))

        assertEquals("夕焼け", post.caption)
        assertEquals(listOf("空", "夕焼け"), post.hashtags)
        assertEquals(Visibility.FOLLOWERS, post.visibility)
        assertEquals(created, post.createdAt)
        assertEquals(captured, post.capturedAt)
        assertEquals(TimeOfDay.EVENING, post.timeOfDay)
        assertEquals(SkyType.SUNSET, post.skyType)
    }

    @Test
    fun `型の違う項目は値なしにし、ハッシュタグは文字列でない要素が1つでもあれば全体を値なしにする`() {
        val data = minimal().data + mapOf(
            "caption" to 12L,
            "hashtags" to listOf("空", 3L),
            "visibility" to 1L,
            "createdAt" to "2026-09-01T06:30:15Z",
            "capturedAt" to 1_700_000_000L,
            "timeOfDay" to listOf("evening"),
            "skyType" to mapOf("raw" to "sunset"),
        )
        val post = readOk(RawDocument("P1", data))

        assertNull(post.caption)
        assertNull(post.hashtags)
        assertNull(post.visibility)
        assertNull(post.createdAt)
        assertNull(post.capturedAt)
        assertNull(post.timeOfDay)
        assertNull(post.skyType)
    }

    @Test
    fun `未知の列挙値は値なしにして表示しない（公開範囲も公開に倒さない）`() {
        val data = minimal().data + mapOf("visibility" to "secret", "timeOfDay" to "midnight", "skyType" to "rainbow")
        val post = readOk(RawDocument("P1", data))

        assertNull(post.visibility)
        assertNull(post.timeOfDay)
        assertNull(post.skyType)
    }

    @Test
    fun `iOS版だけが持つ項目と未知のキーを含む投稿でも失敗せず、読む項目だけを読む`() {
        // キーの出典（iOS origin/main の現物）：Post.swift:118-205 の toFirestoreData、ImageInfo.swift:54-74、
        // ExternalEditInfo.swift:118-139、Location.swift:48-65、EditRecipe.swift:481・516（schemaVersion・appliedFilter）、
        // 列挙値は Mood.swift:27-32・:112-116、CollageModels.swift:22-25・:46-48
        val externalEditInfo = mapOf(
            "hasAdjustments" to true, "isHDR" to false, "isLivePhoto" to true, "isPanorama" to false,
            "formatIdentifier" to "com.apple.photo", "exifCapturedAt" to Timestamp(1_756_660_000L, 0),
        )
        val imageMap = mapOf(
            "url" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/ios.jpg", "thumbnail" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/ios_thumb.jpg",
            "width" to 3024L, "height" to 4032L, "order" to 0L,
            "storagePath" to "posts/u-ios/public/IMG.jpg", "thumbnailStoragePath" to "thumbnails/u-ios/public/IMG_thumb.jpg",
            "externalEditInfo" to externalEditInfo,
        )
        val data = mapOf(
            "postId" to "IOS-POST", "userId" to "u-ios", "images" to listOf(imageMap),
            "visibility" to "public", "likesCount" to 3L, "commentsCount" to 1L,
            "createdAt" to Timestamp(1_756_700_000L, 0), "updatedAt" to Timestamp(1_756_700_000L, 0),
            "caption" to "iOS から", "hashtags" to listOf("空"),
            "mood" to "wistful", "frameId" to "frame-01", "frameCaption" to "ある日の空", "frameTextColorHex" to "#FFFFFF",
            "frameFontStyle" to "serif", "postKind" to "collage", "collageLayout" to "grid2x2",
            "panelLabels" to listOf("朝", "昼", "夜", "雨"),
            "location" to mapOf("latitude" to 35.68, "longitude" to 139.76, "city" to "千代田区", "prefecture" to "東京都"),
            "skyColors" to listOf("#87CEEB", "#FFA07A"), "colorTemperature" to 5600L,
            "timeOfDay" to "morning", "skyType" to "clear", "capturedAt" to Timestamp(1_756_660_000L, 0),
            "originalImages" to listOf(imageMap - "externalEditInfo"),
            "editSettings" to mapOf("appliedFilter" to "warm", "brightness" to 0.1),
            "editRecipeV1" to mapOf("schemaVersion" to 1L, "appliedFilter" to "warm"),
            "未来のキー" to mapOf("何か" to listOf(1L, 2L)),
        )
        val post = readOk(RawDocument("IOS-POST", data))

        assertEquals(PostId("IOS-POST"), post.postId)
        assertEquals(Uid("u-ios"), post.userId)
        assertEquals(
            listOf(PostImageView("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/ios.jpg", "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/ios_thumb.jpg", 3024L, 4032L, 0L)),
            post.images,
        )
        assertEquals("iOS から", post.caption)
        assertEquals(Visibility.PUBLIC, post.visibility)
        assertEquals(TimeOfDay.MORNING, post.timeOfDay)
        assertEquals(SkyType.CLEAR, post.skyType)
    }

    // ---- ページ単位の変換と記録 ----

    /** 窓口の記録用の偽物。logError（Crashlytics へ届く唯一の経路）が呼ばれたかも残す。 */
    private class RecordingAnalytics : AnalyticsFacade {
        val events = mutableListOf<Pair<EventName, Map<String, ParamValue>>>()
        val errors = mutableListOf<Pair<AppError, String>>()
        override fun logEvent(name: EventName, params: Map<String, ParamValue>) { events += name to params }
        override fun logScreen(name: ScreenName) = Unit
        override fun logError(error: AppError, context: String) { errors += error to context }
        override fun setUserId(uid: Uid?) = Unit
    }

    @Test
    fun `ページ単位では飛ばした1件だけを除き、元の順で返して、取得元とパスと理由をpost_decode_failedで送る`() {
        val analytics = RecordingAnalytics()
        val documents = listOf(minimal("A"), RawDocument("BROKEN", mapOf("images" to listOf<Any>())), minimal("C"))

        val posts = reader.readAll(documents, PostDecodeSource.USER_POSTS, analytics)

        assertEquals(listOf(PostId("A"), PostId("C")), posts.map { it.postId })
        assertEquals(
            listOf<Pair<EventName, Map<String, ParamValue>>>(
                EventName.POST_DECODE_FAILED to mapOf(
                    "source" to ParamValue.S("user_posts"),
                    "path" to ParamValue.S("posts/BROKEN"),
                    "error" to ParamValue.S(DefaultPostDocumentReader.REASON_MISSING_REQUIRED_FIELDS),
                ),
            ),
            analytics.events,
        )
    }

    @Test
    fun `ページ単位の変換は、飛ばした投稿をCrashlyticsへの経路（logError）で記録しない`() {
        val analytics = RecordingAnalytics()

        reader.readAll(listOf(RawDocument("BROKEN", emptyMap())), PostDecodeSource.HOME_FEED, analytics)

        assertEquals(emptyList<Pair<AppError, String>>(), analytics.errors)
    }
}
