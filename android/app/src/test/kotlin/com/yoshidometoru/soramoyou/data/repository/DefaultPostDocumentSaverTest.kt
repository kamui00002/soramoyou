// ⭐️ 投稿の文書の保存（作成・投稿数の数え直し・post_completed・一覧への知らせ）の単体テスト（タスク 23.3・要件 7.10〜7.14・7.18〜7.20・7.22・15.3）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.DocumentBuilders
import com.yoshidometoru.soramoyou.contract.document.NewPost
import com.yoshidometoru.soramoyou.contract.document.UploadedImage
import com.yoshidometoru.soramoyou.contract.model.TimeOfDay
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.data.image.CapturedAtSource
import com.yoshidometoru.soramoyou.data.model.PostImageView
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.DefaultPostDocumentReader
import com.yoshidometoru.soramoyou.data.remote.read.PostDocumentReader
import com.yoshidometoru.soramoyou.data.remote.read.ReadOutcome
import com.yoshidometoru.soramoyou.data.remote.read.RemoteImageUrlPolicy
import com.yoshidometoru.soramoyou.data.remote.write.FakeFirestoreWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteFailure
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics
import com.yoshidometoru.soramoyou.platform.EventName
import com.yoshidometoru.soramoyou.platform.ParamValue
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/**
 * 文書の保存が iOS と同じ順序（作成 → 投稿数の数え直し → `post_completed` → 知らせ）で進み、作成の失敗だけを `Err` にすることを確かめる。
 * 書き込みは本物の入口と本物の契約の上で動かし（形の違反は本当に止まる）、偽物にするのは Firestore の SDK への継ぎ目と数え直しの部品だけ。
 * 知らせる投稿は本物の読み取りの部品で作る（フィードが同じ文書を読み返したときと同じ形になることを見る）。
 */
class DefaultPostDocumentSaverTest {

    private val uid = Uid("UID-1")
    private val now = Instant.parse("2026-10-10T01:02:03.456Z")
    private val captured = Instant.parse("2026-10-09T08:30:00Z")
    private val analytics = RecordingAnalytics()
    private val client = FakeFirestoreWriteClient()
    private val counter = FakePostsCountSynchronizer { client.calls.size to analytics.events.size }
    private val createdPosts = CreatedPosts()

    /** 知らせを受け取った投稿と、受け取った時点で送られていたイベントの数（順序を確かめるため）。 */
    private val received = mutableListOf<Pair<PostView, Int>>()
    private val collector: Job = CoroutineScope(Dispatchers.Unconfined).launch {
        createdPosts.events.collect { received += it to analytics.events.size }
    }

    @AfterTest
    fun stopCollecting() = collector.cancel()

    private fun saver(
        enabled: Set<WriteCapability> = ALL_WRITES_ENABLED,
        signedInUid: Uid? = uid,
        reader: PostDocumentReader = DefaultPostDocumentReader(RemoteImageUrlPolicy.PRODUCTION),
    ) = DefaultPostDocumentSaver(
        gateway = realWriteGateway(client, analytics, enabled, signedInUid),
        countSynchronizer = counter,
        reader = reader,
        createdPosts = createdPosts,
        analytics = analytics,
        clock = Clock.fixed(now, ZoneOffset.UTC),
    )

    private fun prepared(
        visibility: Visibility = Visibility.PUBLIC,
        caption: String? = "夕焼け #空 #sky",
        hashtags: List<String> = listOf("空", "sky"),
        capturedAt: Instant? = captured,
        timeOfDay: TimeOfDay? = TimeOfDay.EVENING,
        source: CapturedAtSource = CapturedAtSource.EXIF,
    ) = PreparedPost(
        postId = PostId("POST-1"),
        uid = uid,
        visibility = visibility,
        caption = caption,
        hashtags = hashtags,
        capturedAt = capturedAt,
        timeOfDay = timeOfDay,
        capturedAtSource = source,
    )

    /** 本番の Storage のダウンロード URL の形（[name] は `/o/` の後ろの名前）。書き込みの契約は、この形の画像 URL だけを通す。 */
    private fun downloadUrl(name: String) =
        "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$name?alt=media&token=t"

    /** [visibility] のフォルダに上げた [order] 枚目の画像（本体の寸法は [width]×[height]）。 */
    private fun image(order: Int, width: Int, height: Int, visibility: Visibility = Visibility.PUBLIC) = UploadedImage(
        url = downloadUrl("IMG-$order.jpg"),
        thumbnailUrl = downloadUrl("IMG-${order}_thumb.jpg"),
        widthPx = width,
        heightPx = height,
        order = order,
        storagePath = StoragePath("posts/UID-1/${visibility.raw}/IMG-$order.jpg"),
        thumbnailStoragePath = StoragePath("thumbnails/UID-1/${visibility.raw}/IMG-${order}_thumb.jpg"),
    )

    private val images = listOf(image(0, 2048, 1365), image(1, 1152, 2048))

    // ── 成功 ──

    @Test
    fun `文書を作ってから投稿数を数え直し、post_completedを送り、作った投稿を知らせてOkを返す`() = runBlocking {
        val post = prepared()

        val result = saver().save(post, images)

        assertEquals(AppResult.Ok(Unit), result)
        val expected = DocumentBuilders.postCreate(
            NewPost(PostId("POST-1"), uid, images, Visibility.PUBLIC, "夕焼け #空 #sky", listOf("空", "sky"), captured, TimeOfDay.EVENING, now),
        )
        assertEquals(listOf(FakeFirestoreWriteClient.Call("set", listOf("posts/POST-1"), expected)), client.calls)
        // 数え直しは作成の後・post_completed の前、知らせは post_completed の後
        assertEquals(listOf(FakePostsCountSynchronizer.Recount(uid, writesBefore = 1, eventsBefore = 0)), counter.calls)
        assertEquals(listOf(RecordingAnalytics.LoggedEvent(EventName.POST_COMPLETED, postCompletedParams(post, 2))), analytics.events)
        assertEquals(listOf(1), received.map { it.second })
        assertEquals(emptyList<RecordingAnalytics.LoggedError>(), analytics.errors)
    }

    @Test
    fun `知らせる投稿は書いた文書を読み取りの部品に通した形で、作成日時は端末の時刻、いいね数は0`() = runBlocking {
        saver().save(prepared(visibility = Visibility.FOLLOWERS), listOf(image(0, 2048, 1365, Visibility.FOLLOWERS)))

        val expected = PostView(
            postId = PostId("POST-1"),
            userId = uid,
            images = listOf(
                PostImageView(downloadUrl("IMG-0.jpg"), downloadUrl("IMG-0_thumb.jpg"), width = 2048, height = 1365, order = 0),
            ),
            caption = "夕焼け #空 #sky",
            hashtags = listOf("空", "sky"),
            visibility = Visibility.FOLLOWERS,
            likesCount = 0,
            createdAt = now,
            capturedAt = captured,
            timeOfDay = TimeOfDay.EVENING,
            skyType = null,
        )
        assertEquals(listOf(expected), received.map { it.first })
    }

    @Test
    fun `キャプションもハッシュタグも撮影日時も無い投稿は、それらのキーを書かずに作る`() = runBlocking {
        val post = prepared(caption = null, hashtags = emptyList(), capturedAt = null, timeOfDay = null, source = CapturedAtSource.NONE)

        saver().save(post, images)

        val written = client.calls.single().data!!
        assertEquals(
            setOf("postId", "userId", "images", "visibility", "likesCount", "commentsCount", "createdAt", "updatedAt"),
            written.keys,
        )
    }

    // ── post_completed（要件 15.3・設計書 :985）──

    @Test
    fun `post_completedはiOSと同じキーで、Androidに無い機能はiOSで使わなかったときの値にする`() {
        val params = postCompletedParams(prepared(visibility = Visibility.FOLLOWERS, source = CapturedAtSource.ASSET), imageCount = 3)

        assertEquals(
            mapOf(
                "post_kind" to ParamValue.S("single"),
                "is_reedit" to ParamValue.B(false),
                "image_count" to ParamValue.L(3),
                "visibility" to ParamValue.S("followers"),
                "has_mood" to ParamValue.B(false),
                "mood" to ParamValue.S("none"),
                "has_caption" to ParamValue.B(true),
                "has_location" to ParamValue.B(false),
                "saved_original_images" to ParamValue.B(false),
                "has_captured_at" to ParamValue.B(true),
                "captured_at_source" to ParamValue.S("asset"),
                "colors_from_sky" to ParamValue.B(false),
                "photo_source" to ParamValue.S("library"),
                "edit_scope_sky_only" to ParamValue.B(false),
            ),
            params,
        )
    }

    @Test
    fun `キャプションが無ければhas_captionはfalse、撮影日時が無ければ出所によらずcaptured_at_sourceはnone`() {
        // 出所が EXIF のまま撮影日時だけが無い（食い違った）入力でも、iOS の capturedAtSourceForEvent と同じく none にする
        val params = postCompletedParams(prepared(caption = null, capturedAt = null, timeOfDay = null, source = CapturedAtSource.EXIF), 1)

        assertEquals(ParamValue.B(false), params["has_caption"])
        assertEquals(ParamValue.B(false), params["has_captured_at"])
        assertEquals(ParamValue.S("none"), params["captured_at_source"])
        assertEquals(ParamValue.S("public"), params["visibility"])
    }

    @Test
    fun `撮影日時があれば出所をそのまま送り、EXIFから取れた投稿はcaptured_at_sourceがexif`() {
        // 上の 2 件は asset と none しか固定していない（成功のテストは postCompletedParams 自身と比べるので値を固定しない）
        val params = postCompletedParams(prepared(source = CapturedAtSource.EXIF), 1)

        assertEquals(ParamValue.B(true), params["has_captured_at"])
        assertEquals(ParamValue.S("exif"), params["captured_at_source"])
    }

    // ── 作成の失敗（要件 7.18）──

    @Test
    fun `文書の作成がFirestoreで失敗したら、発生箇所つきで記録してErrを返し、数え直しも計測も知らせもしない`() = runBlocking {
        client.failOn = "set"
        client.failure = FirestoreWriteFailure(AppError.PermissionDenied, RuntimeException("偽物の rules の拒否"))

        val result = saver().save(prepared(), images)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "PostDocumentSaver.save")), analytics.errors)
        assertEquals(emptyList(), counter.uids)
        assertEquals(emptyList<RecordingAnalytics.LoggedEvent>(), analytics.events)
        assertEquals(emptyList(), received)
    }

    @Test
    fun `書き込みの入口が断った失敗は記録し直さない（可否の無効）`() = runBlocking {
        val result = saver(enabled = ALL_WRITES_ENABLED - WriteCapability.POST_CREATE).save(prepared(), images)

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.POST_CREATE)), result)
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.WriteBlocked(WriteCapability.POST_CREATE), "FirestoreWriteGateway.create")),
            analytics.errors,
        )
        assertEquals(emptyList(), client.calls)
        assertEquals(emptyList(), counter.uids)
    }

    @Test
    fun `書き込みの入口が断った失敗は記録し直さない（形の違反：投稿者がログイン中のユーザーと違う）`() = runBlocking {
        val result = saver(signedInUid = Uid("SOMEONE-ELSE")).save(prepared(), images)

        assertIs<AppError.ShapeViolation>((result as AppResult.Err).error)
        val logged = analytics.errors.single()
        assertIs<AppError.ShapeViolation>(logged.error)
        assertEquals("FirestoreWriteGateway.create", logged.context)
        assertEquals(emptyList(), client.calls)
        assertEquals(emptyList(), received)
    }

    // ── 作成の後の失敗は投稿の成功を覆さない（要件 7.20）──

    @Test
    fun `投稿数の数え直しに失敗してもOkを返し、post_completedと知らせを行い、記録し直さない`() = runBlocking {
        counter.result = AppResult.Err(AppError.Network)

        val result = saver().save(prepared(), images)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf(uid), counter.uids)
        assertEquals(listOf(EventName.POST_COMPLETED), analytics.events.map { it.name })
        assertEquals(1, received.size)
        assertEquals(emptyList<RecordingAnalytics.LoggedError>(), analytics.errors)
    }

    @Test
    fun `書いた文書を読み取りの部品が読めなければ知らせないが、Okを返してpost_completedは送る`() = runBlocking {
        val skipping = object : PostDocumentReader {
            override fun read(raw: RawDocument): ReadOutcome = ReadOutcome.Skipped("posts/${raw.id}", "偽物の読めない文書")
        }

        val result = saver(reader = skipping).save(prepared(), images)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf(EventName.POST_COMPLETED), analytics.events.map { it.name })
        assertEquals(emptyList(), received)
    }
}

/**
 * 数え直しの偽物。呼ばれた uid と、呼ばれた時点で済んでいた書き込みとイベントの数（[progress] で読む）を残し、[result] を返す。
 * 本物と違って記録はしない（保存の部品が記録し直さないことを見るため）。
 */
private class FakePostsCountSynchronizer(private val progress: () -> Pair<Int, Int>) : PostsCountSynchronizer {

    data class Recount(val uid: Uid, val writesBefore: Int, val eventsBefore: Int)

    var result: AppResult<Long> = AppResult.Ok(1L)
    val calls = mutableListOf<Recount>()
    val uids: List<Uid> get() = calls.map { it.uid }

    override suspend fun recount(uid: Uid): AppResult<Long> {
        val (writes, events) = progress()
        calls += Recount(uid, writes, events)
        return result
    }
}
