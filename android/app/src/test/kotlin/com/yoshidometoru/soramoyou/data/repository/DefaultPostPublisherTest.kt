// ⭐️ 投稿の公開（検証・アップロード・後片付け・進捗・二重送信）の単体テスト（タスク 23.2・要件 7.3・7.6・7.8・7.9・7.14・7.18・7.21）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.document.UploadedImage
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.model.FilterId
import com.yoshidometoru.soramoyou.contract.model.TimeOfDay
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.data.image.CapturedAt
import com.yoshidometoru.soramoyou.data.image.CapturedAtSource
import com.yoshidometoru.soramoyou.data.image.ImagePipeline
import com.yoshidometoru.soramoyou.data.image.JpegSpec
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import com.yoshidometoru.soramoyou.data.image.PreparedImage
import com.yoshidometoru.soramoyou.data.image.PreparedPostImage
import com.yoshidometoru.soramoyou.data.remote.write.DefaultStorageGateway
import com.yoshidometoru.soramoyou.data.remote.write.FakeStorageWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FixedWriteGate
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics
import com.yoshidometoru.soramoyou.data.remote.write.StorageGateway
import com.yoshidometoru.soramoyou.data.remote.write.StorageWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.StorageWriteFailure
import java.io.File
import java.time.Instant
import java.time.ZoneId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/**
 * 投稿の公開が、iOS の savePost・uploadImages・rollbackUploadedImages（PostViewModel.swift:502-760, 976-994）と同じ順序で
 * 写真を上げ、途中か文書の保存で失敗したら上げようとしたパスを全て消すことを確かめる（設計書 :341-372・:862-870）。
 *
 * Storage は本物の入口（可否 → 大きさ → 実行 → 記録）を偽物の継ぎ目の上で動かす。偽物にするのは、Storage の SDK への継ぎ目・
 * 写真の変換・文書の保存の継ぎ目（タスク 23.3 が中身を作る）だけ。
 *
 * 後片付けの削除の上限（レビュー R07）は、:app のテストに仮想の時計（kotlinx-coroutines-test）が無いので、兄弟の DefaultPostDeleterTest と
 * 同じく上限を短く差し替えて実際の時間で確かめ、本番の 30 秒はソースの書き方で固定する。陽性対照は手元の台本（git の外）。
 */
class DefaultPostPublisherTest {

    private val uid = Uid("UID-1")
    private val analytics = RecordingAnalytics()
    private val storageClient = FakeStorageWriteClient()
    private val pipeline = FakePostPipeline()
    private val saver = RecordingSaver()

    /** 偽物が呼ばれたときの進み具合（呼ばれた順）。 */
    private val observed = mutableListOf<Pair<String, PublishState>>()

    /** 投稿と画像の ID は ID-1・ID-2… の順に作る（投稿の ID が先）。 */
    private var lastId = 0

    private lateinit var publisher: DefaultPostPublisher

    private fun publisher(
        signedIn: Uid? = uid,
        zone: ZoneId = TOKYO,
        client: StorageWriteClient = storageClient,
        rollbackDeleteTimeout: Duration = 30.seconds,
    ): DefaultPostPublisher = DefaultPostPublisher(
        storage = storage(client),
        pipeline = pipeline,
        saver = saver,
        analytics = analytics,
        currentUid = { signedIn },
        deviceZone = { zone },
        newId = { "ID-${++lastId}" },
        rollbackDeleteTimeout = rollbackDeleteTimeout,
    ).also { publisher = it }

    private fun storage(client: StorageWriteClient): StorageGateway =
        DefaultStorageGateway(FixedWriteGate(ALL_WRITES_ENABLED), client, analytics, wait = {})

    private fun photos(count: Int) = List(count) { PickedPhoto("content://photo/$it", it) }

    /**
     * 投稿の入力（形は Kiro android-edit-tools K0：design.md:609-615）。
     * 写真ごとの編集は [edits] の i 番目を i 枚目に付ける（[edits] が null なら、どの写真にも [filter] だけの編集を付ける）。
     * 撮影日時は入力の値 [capturedAt]（A2 から、投稿の時に写真から読み直さずこれを使う）。
     */
    private fun draft(
        count: Int = 2,
        caption: String = "",
        visibility: Visibility = Visibility.PUBLIC,
        filter: FilterId? = null,
        edits: List<PhotoEdit>? = null,
        capturedAt: CapturedAt? = null,
    ) = PostDraft(
        photos = photos(count).mapIndexed { i, photo -> PostPhoto(photo, edits?.get(i) ?: PhotoEdit(filter = filter)) },
        caption = caption,
        visibility = visibility,
        firstPhotoCapturedAt = capturedAt,
    )

    private fun body(imageId: String, folder: String = "public") = "posts/UID-1/$folder/$imageId.jpg"
    private fun thumb(imageId: String, folder: String = "public") = "thumbnails/UID-1/$folder/${imageId}_thumb.jpg"

    private fun puts() = storageClient.calls.filter { it.operation == "put" }.map { it.path }
    private fun deletes() = storageClient.calls.filter { it.operation == "delete" }.map { it.path }

    // ── 成功 ──

    @Test
    fun `写真を選択順に変換して本体とサムネイルを上げ、検証した投稿と上げた画像で文書を保存して投稿のIDを返す`() = runBlocking {
        val result = publisher().publish(
            draft(
                count = 2,
                caption = " \n夕焼け #空 #sky" + "　",
                capturedAt = CapturedAt(Instant.parse("2026-10-09T22:30:00Z"), CapturedAtSource.EXIF),
            ),
        )

        assertEquals(AppResult.Ok(PostId("ID-1")), result)
        // 本体 → サムネイルの順に 1 枚ずつ。どれも JPEG として送る
        assertEquals(listOf(body("ID-2"), thumb("ID-2"), body("ID-3"), thumb("ID-3")), puts())
        assertEquals(setOf<String?>("image/jpeg"), storageClient.calls.filter { it.operation == "put" }.map { it.contentType }.toSet())
        assertEquals(listOf<Int?>(100, 10, 101, 10), storageClient.calls.filter { it.operation == "put" }.map { it.size })
        assertEquals(photos(2), pipeline.photos)
        assertEquals(listOf(PhotoEdit.NONE, PhotoEdit.NONE), pipeline.edits)

        val (post, images) = saver.calls.single()
        assertEquals(
            PreparedPost(
                postId = PostId("ID-1"),
                uid = uid,
                visibility = Visibility.PUBLIC,
                caption = "夕焼け #空 #sky",
                hashtags = listOf("空", "sky"),
                capturedAt = Instant.parse("2026-10-09T22:30:00Z"),
                timeOfDay = TimeOfDay.MORNING, // 東京で 7:30
                capturedAtSource = CapturedAtSource.EXIF,
            ),
            post,
        )
        assertEquals(
            listOf(
                uploaded(order = 0, imageId = "ID-2", height = 1536),
                uploaded(order = 1, imageId = "ID-3", height = 1537),
            ),
            images,
        )
        assertEquals(emptyList<String>(), deletes())
        assertEquals(emptyList<RecordingAnalytics.LoggedError>(), analytics.errors)
        assertEquals(PublishState.Succeeded(PostId("ID-1")), publisher.state.value)
    }

    @Test
    fun `進捗は検証の直後から0枚目を出し、1枚上げるたびに進み、文書の保存の間は保存中になる`() = runBlocking {
        // 写真の変換は数秒かかりうるので、その間も送信を受け付けない状態にしておく（撮影日時はもう読み取らない＝A2）
        publisher().publish(draft(count = 3))

        assertEquals(
            listOf(
                "pipeline" to PublishState.Uploading(0, 3),
                "pipeline" to PublishState.Uploading(1, 3),
                "pipeline" to PublishState.Uploading(2, 3),
                "saver" to PublishState.Saving,
            ),
            observed,
        )
    }

    @Test
    fun `画像のパスの公開範囲は投稿の公開範囲と同じフォルダにする`() = runBlocking {
        publisher().publish(draft(count = 1, visibility = Visibility.FOLLOWERS))
        publisher().publish(draft(count = 1, visibility = Visibility.PRIVATE))

        assertEquals(
            listOf(body("ID-2", "followers"), thumb("ID-2", "followers"), body("ID-4", "private"), thumb("ID-4", "private")),
            puts(),
        )
        assertEquals(listOf(Visibility.FOLLOWERS, Visibility.PRIVATE), saver.calls.map { it.first.visibility })
    }

    @Test
    fun `時間帯は撮影日時を投稿する端末のタイムゾーンの時にして決める`() = runBlocking {
        // 同じ瞬間（UTC 22:30）でも、東京の端末では 7:30＝朝、ニューヨークの端末（夏時間 UTC-4）では 18:30＝夕方
        val captured = CapturedAt(Instant.parse("2026-10-09T22:30:00Z"), CapturedAtSource.ASSET)

        publisher(zone = ZoneId.of("America/New_York")).publish(draft(count = 1, capturedAt = captured))

        assertEquals(TimeOfDay.EVENING, saver.calls.single().first.timeOfDay)
        assertEquals(CapturedAtSource.ASSET, saver.calls.single().first.capturedAtSource)
    }

    @Test
    fun `撮影日時が無ければ撮影日時と時間帯を両方とも無しにし、出所はnoneにする`() = runBlocking {
        publisher().publish(draft(count = 1, capturedAt = null))

        val post = saver.calls.single().first
        assertNull(post.capturedAt)
        assertNull(post.timeOfDay)
        assertEquals(CapturedAtSource.NONE, post.capturedAtSource)
    }

    @Test
    fun `写真ごとの編集は、その写真の変換に選択順のまま渡る（全部の写真に1枚目の編集を渡さない）`() = runBlocking {
        val first = PhotoEdit(filter = FilterId.DRAMA)
        val second = PhotoEdit(filter = FilterId.SOFT)
        val third = PhotoEdit.NONE

        publisher().publish(draft(count = 3, edits = listOf(first, second, third)))

        assertEquals(photos(3), pipeline.photos)
        assertEquals(listOf(first, second, third), pipeline.edits)
    }

    @Test
    fun `撮影日時と出所は入力の値をそのまま使い、時間帯は端末のタイムゾーンの時で決める`() = runBlocking {
        val captured = CapturedAt(Instant.parse("2026-10-09T22:30:00Z"), CapturedAtSource.ASSET)

        publisher().publish(draft(count = 2, capturedAt = captured))

        val post = saver.calls.single().first
        assertEquals(Instant.parse("2026-10-09T22:30:00Z"), post.capturedAt)
        assertEquals(TimeOfDay.MORNING, post.timeOfDay, "東京で 7:30")
        assertEquals(CapturedAtSource.ASSET, post.capturedAtSource)
        // 変換が呼ばれたのは写真の数だけ（撮影日時のために写真を読みに行く呼び出しは無い。読む部品は引数から無くなった）
        assertEquals(photos(2), pipeline.photos)
    }

    @Test
    fun `空白だけのキャプションは無しにし、ハッシュタグも無い`() = runBlocking {
        publisher().publish(draft(count = 1, caption = " 　\n​"))

        assertNull(saver.calls.single().first.caption)
        assertEquals(emptyList<String>(), saver.calls.single().first.hashtags)
    }

    // ── 入力の検証：何も上げずに断る ──

    @Test
    fun `写真が0枚か11枚以上なら何も上げずに断り、記録しない`() = runBlocking {
        assertEquals(AppResult.Err(AppError.Validation(ValidationReason.NO_IMAGES)), publisher().publish(draft(count = 0)))
        assertEquals(PublishState.Failed(AppError.Validation(ValidationReason.NO_IMAGES)), publisher.state.value)
        assertEquals(AppResult.Err(AppError.Validation(ValidationReason.TOO_MANY_IMAGES)), publisher().publish(draft(count = 11)))

        assertEquals(emptyList<FakeStorageWriteClient.Call>(), storageClient.calls)
        assertEquals(emptyList<PickedPhoto>(), pipeline.photos, "検証で断ったときは写真の変換もしない")
        assertEquals(0, saver.calls.size)
        assertEquals(emptyList<RecordingAnalytics.LoggedError>(), analytics.errors)
    }

    @Test
    fun `キャプションは前後の空白を取り除いてからUTF16で2000まで通し、2001で断る`() = runBlocking {
        val padded = " \n" + "a".repeat(2000) + "　"
        assertEquals(AppResult.Ok(PostId("ID-1")), publisher().publish(draft(count = 1, caption = padded)))
        assertEquals("a".repeat(2000), saver.calls.single().first.caption)

        val tooLong = publisher().publish(draft(count = 1, caption = "a".repeat(2001)))

        assertEquals(AppResult.Err(AppError.Validation(ValidationReason.CAPTION_TOO_LONG)), tooLong)
        assertEquals(1, saver.calls.size)
        assertEquals(2, puts().size, "2 回目は何も上げない")
    }

    @Test
    fun `ハッシュタグが30個までなら通し、31個なら何も上げずに断る`() = runBlocking {
        val thirty = (1..30).joinToString(" ") { "#t$it" }
        assertEquals(AppResult.Ok(PostId("ID-1")), publisher().publish(draft(count = 1, caption = thirty)))

        val result = publisher().publish(draft(count = 1, caption = "$thirty #t31"))

        assertEquals(AppResult.Err(AppError.Validation(ValidationReason.TOO_MANY_HASHTAGS)), result)
        assertEquals(1, saver.calls.size)
        assertEquals(2, puts().size)
    }

    @Test
    fun `ログインしていなければ何も上げずに権限の拒否を返し、記録する`() = runBlocking {
        val result = publisher(signedIn = null).publish(draft())

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(emptyList<FakeStorageWriteClient.Call>(), storageClient.calls)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "PostPublisher.publish")), analytics.errors)
    }

    // ── 途中の失敗：上げようとしたパスを全て消す ──

    @Test
    fun `途中のアップロードが失敗したら、失敗した1枚を含めて上げようとしたパスを全て消し、無いパスの削除は記録しない`() = runBlocking {
        // 2 枚目のサムネイルの送信が失敗する。そのパスには何も無いので、削除は NotFound になる
        storageClient.failWhen = { call ->
            when {
                call.operation == "put" && call.path == thumb("ID-3") -> StorageWriteFailure(AppError.Network, RuntimeException("偽物の通信断"))
                call.operation == "delete" && call.path == thumb("ID-3") -> StorageWriteFailure(AppError.NotFound, RuntimeException("偽物の不在"))
                else -> null
            }
        }

        val result = publisher().publish(draft(count = 3))

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(listOf(body("ID-2"), thumb("ID-2"), body("ID-3"), thumb("ID-3")), deletes())
        assertEquals(listOf(body("ID-2"), thumb("ID-2"), body("ID-3"), thumb("ID-3")), puts(), "3 枚目には進まない")
        assertEquals(0, saver.calls.size)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.Network, "PostPublisher.publish.upload")), analytics.errors)
        assertEquals(PublishState.Failed(AppError.Network), publisher.state.value)
    }

    @Test
    fun `送信は成功してURLの取得だけが失敗した画像も消す`() = runBlocking {
        // 送信は成功して URL の取得だけが失敗した画像も、Android は消す（2026-10-10 ユーザー判断）
        storageClient.failWhen = { call ->
            if (call.operation == "downloadUrl" && call.path == body("ID-2")) StorageWriteFailure(AppError.Network, RuntimeException("偽物")) else null
        }

        val result = publisher().publish(draft(count = 2))

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(3, storageClient.calls.count { it.operation == "downloadUrl" }, "URL の取得は入口が 3 回まで試す")
        assertEquals(listOf(body("ID-2")), deletes())
    }

    @Test
    fun `写真の変換が失敗したら、それまでに上げた画像を消し、変換の段階として記録する`() = runBlocking {
        pipeline.failures = mapOf(1 to AppError.ImageUnreadable(1))

        val result = publisher().publish(draft(count = 3))

        assertEquals(AppResult.Err(AppError.ImageUnreadable(1)), result)
        assertEquals(listOf(body("ID-2"), thumb("ID-2")), deletes())
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.ImageUnreadable(1), "PostPublisher.publish.image")), analytics.errors)
    }

    @Test
    fun `大きすぎる画像は入口が断って記録するので、この部品は記録し直さずに後片付けする`() = runBlocking {
        pipeline.bodySize = { index -> if (index == 1) StorageGateway.MAX_UPLOAD_BYTES else 100 + index }

        val result = publisher().publish(draft(count = 2))

        val tooLarge = AppError.ImageTooLarge(1, StorageGateway.MAX_UPLOAD_BYTES.toLong())
        assertEquals(AppResult.Err(tooLarge), result)
        assertEquals(listOf(body("ID-2"), thumb("ID-2")), puts(), "大きすぎる本体は送らない")
        assertEquals(listOf(body("ID-2"), thumb("ID-2"), body("ID-3")), deletes())
        assertEquals(listOf(RecordingAnalytics.LoggedError(tooLarge, "StorageGateway.uploadJpeg")), analytics.errors)
    }

    @Test
    fun `文書の保存に失敗したら、上げた画像を全て消して保存の失敗を返し、記録は保存の継ぎ目に任せる`() = runBlocking {
        saver.result = AppResult.Err(AppError.PermissionDenied)

        val result = publisher().publish(draft(count = 2))

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(listOf(body("ID-2"), thumb("ID-2"), body("ID-3"), thumb("ID-3")), deletes())
        assertEquals(emptyList<RecordingAnalytics.LoggedError>(), analytics.errors)
        assertEquals(PublishState.Failed(AppError.PermissionDenied), publisher.state.value)
    }

    @Test
    fun `後片付けの削除が1つ失敗しても残りを消し続け、削除の失敗を記録して元の失敗を返す`() = runBlocking {
        saver.result = AppResult.Err(AppError.Network)
        storageClient.failWhen = { call ->
            if (call.operation == "delete" && call.path == body("ID-2")) StorageWriteFailure(AppError.PermissionDenied, RuntimeException("偽物")) else null
        }

        val result = publisher().publish(draft(count = 2))

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(listOf(body("ID-2"), thumb("ID-2"), body("ID-3"), thumb("ID-3")), deletes())
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "PostPublisher.publish.rollback")), analytics.errors)
    }

    // ── 後片付けの削除の上限（レビュー R07）──

    @Test
    fun `後片付けの削除が返事をしないときは、上限の時間で打ち切ってNetworkとして記録し、残りを消して失敗にする`() = runBlocking {
        // 文書の保存の失敗で、上げた 4 つのパスを全て消す。そのうち 1 つ（1 枚目のサムネイル）の削除が返事をしない
        saver.result = AppResult.Err(AppError.PermissionDenied)
        val gate = CompletableDeferred<Unit>()
        val hanging = object : StorageWriteClient by storageClient {
            override suspend fun delete(path: String) {
                // 先に偽物へ届けてから止まる（届いた削除の並びに残し、打ち切った後も残りへ進んだことを並びで見る）
                storageClient.delete(path)
                if (path == thumb("ID-2")) gate.await()
            }
        }
        // 見張り：上限が効かない改変を当てても、5 秒で待ちを外してテストを赤で終わらせる（後片付けは NonCancellable の中なので、
        // 外からは止められず、待ちを外さないと runBlocking ごと止まる：タスク 24 の記録の罠）
        val watchdog = launch {
            delay(5.seconds)
            gate.complete(Unit)
        }
        try {
            // 本番の上限は 30 秒（下のソースの検査で固定する）。ここでは短くして、打ち切った後の流れを確かめる
            val result = publisher(client = hanging, rollbackDeleteTimeout = 50.milliseconds).publish(draft(count = 2))

            assertEquals(AppResult.Err(AppError.PermissionDenied), result)
            assertEquals(listOf(body("ID-2"), thumb("ID-2"), body("ID-3"), thumb("ID-3")), deletes(), "打ち切った後も残りのパスを消す")
            // 打ち切った 1 つだけを Network として記録する（文書の保存の失敗は保存の継ぎ目が記録するので、ここには出ない）
            assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.Network, "PostPublisher.publish.rollback")), analytics.errors)
            assertEquals(PublishState.Failed(AppError.PermissionDenied), publisher.state.value)
        } finally {
            watchdog.cancel()
            gate.complete(Unit)
        }
    }

    @Test
    fun `後片付けの削除の上限は、本番では兄弟のPostDeleterと同じ30秒にする`() {
        // 仮想の時計が無いので、本番の値はソースの書き方で固定する（:app の単体テストの作業ディレクトリは android/app）
        val file = File("src/main/kotlin/com/yoshidometoru/soramoyou/data/repository/PostPublisher.kt")
        assertTrue(file.isFile, "PostPublisher.kt が見つからない: ${file.absolutePath}")
        val source = file.readText()

        assertTrue("private val rollbackDeleteTimeout: Duration = ROLLBACK_DELETE_TIMEOUT," in source, "コンストラクタの既定が本番の上限でない")
        assertTrue("val ROLLBACK_DELETE_TIMEOUT: Duration = 30.seconds" in source, "本番の上限が 30 秒でない")
    }

    // ── 二重送信 ──

    @Test
    fun `処理中にもう一度呼ばれたら状態を変えずにすぐ断り、終わった後は次の投稿を受け付ける`() = runBlocking {
        val release = CompletableDeferred<Unit>()
        pipeline.waitAt = mapOf(0 to release)
        publisher()

        val first = launch { assertEquals(AppResult.Ok(PostId("ID-1")), publisher.publish(draft(count = 1))) }
        pipeline.reached.await()
        val second = publisher.publish(draft(count = 1))

        assertEquals(AppResult.Err(AppError.Validation(ValidationReason.PUBLISH_IN_PROGRESS)), second)
        assertEquals(PublishState.Uploading(0, 1), publisher.state.value, "処理中の状態を書き換えない")
        assertEquals(1, pipeline.photos.size, "2 回目は何もしない")
        assertEquals(emptyList<RecordingAnalytics.LoggedError>(), analytics.errors)

        release.complete(Unit)
        first.join()
        pipeline.waitAt = emptyMap()
        assertEquals(AppResult.Ok(PostId("ID-3")), publisher.publish(draft(count = 1)))
    }

    // ── 取り消し ──

    @Test
    fun `アップロード中に取り消されたら、上げた画像を消し切ってから状態を待機に戻し、次の投稿を受け付ける`() = runBlocking {
        // 本番の削除は中断できる待ちを含む。取り消された後もそれが最後まで走ることを確かめるため、削除の前で取り消しを確かめる
        val cancellable = object : StorageWriteClient by storageClient {
            override suspend fun delete(path: String) {
                currentCoroutineContext().ensureActive()
                storageClient.delete(path)
            }
        }
        pipeline.waitAt = mapOf(1 to CompletableDeferred())
        publisher(client = cancellable)

        val job = launch { publisher.publish(draft(count = 2)) }
        pipeline.reached.await()
        job.cancel()
        job.join()

        assertEquals(listOf(body("ID-2"), thumb("ID-2")), deletes())
        assertEquals(PublishState.Idle, publisher.state.value)
        assertEquals(0, saver.calls.size)

        // 2 枚目は変換を待っている間に取り消したので、画像の ID を作っていない（ID-1・ID-2 だけを使った）
        pipeline.waitAt = emptyMap()
        assertEquals(AppResult.Ok(PostId("ID-3")), publisher.publish(draft(count = 1)))
    }

    @Test
    fun `文書の保存中に取り消されても保存を最後まで行い、保存できたら画像を消さずに成功にする`() = runBlocking {
        // 保存の途中で止めると、文書ができたか分からないまま画像を消して、画像の無い投稿を残しうる
        val release = CompletableDeferred<Unit>()
        saver.waitFor = release
        publisher()

        val job = launch { publisher.publish(draft(count = 1)) }
        saver.reached.await()
        job.cancel()
        release.complete(Unit)
        job.join()

        assertEquals(1, saver.calls.size)
        assertEquals(emptyList<String>(), deletes())
        assertEquals(PublishState.Succeeded(PostId("ID-1")), publisher.state.value)
    }

    // ── 下ごしらえ ──

    private fun uploaded(order: Int, imageId: String, height: Int): UploadedImage {
        val bodyPath = body(imageId)
        val thumbnailPath = thumb(imageId)
        return UploadedImage(
            url = FakeStorageWriteClient.urlOf(bodyPath),
            thumbnailUrl = FakeStorageWriteClient.urlOf(thumbnailPath),
            widthPx = 2048,
            heightPx = height,
            order = order,
            storagePath = StoragePath(bodyPath),
            thumbnailStoragePath = StoragePath(thumbnailPath),
        )
    }

    /**
     * 写真の変換の偽物。本体は [bodySize] バイト・幅 2048・高さ 1536＋何枚目か、サムネイルは 10 バイト。
     * [failures] の写真は失敗を返し、[waitAt] の写真では、[reached] を完了させてから待つ。
     */
    private inner class FakePostPipeline : ImagePipeline {
        val photos = mutableListOf<PickedPhoto>()
        val edits = mutableListOf<PhotoEdit>()
        var failures: Map<Int, AppError> = emptyMap()
        var bodySize: (Int) -> Int = { index -> 100 + index }
        var waitAt: Map<Int, CompletableDeferred<Unit>> = emptyMap()
        var reached = CompletableDeferred<Unit>()

        override suspend fun prepare(photo: PickedPhoto, spec: JpegSpec): AppResult<PreparedImage> = error("投稿では使わない")

        override suspend fun preparePost(photo: PickedPhoto, edit: PhotoEdit): AppResult<PreparedPostImage> {
            observed += "pipeline" to publisher.state.value
            photos += photo
            edits += edit
            waitAt[photo.index]?.let { gate ->
                reached.complete(Unit)
                gate.await()
            }
            failures[photo.index]?.let { return AppResult.Err(it) }
            return AppResult.Ok(PreparedPostImage(ByteArray(bodySize(photo.index)), 2048, 1536 + photo.index, ByteArray(10)))
        }
    }

    /** 文書の保存の継ぎ目の偽物。渡されたものを記録して [result] を返す。[waitFor] があれば、[reached] を完了させてから待つ。 */
    private inner class RecordingSaver : PostDocumentSaver {
        val calls = mutableListOf<Pair<PreparedPost, List<UploadedImage>>>()
        var result: AppResult<Unit> = AppResult.Ok(Unit)
        var waitFor: CompletableDeferred<Unit>? = null
        val reached = CompletableDeferred<Unit>()

        override suspend fun save(post: PreparedPost, images: List<UploadedImage>): AppResult<Unit> {
            observed += "saver" to publisher.state.value
            calls += post to images
            waitFor?.let { gate ->
                reached.complete(Unit)
                gate.await()
            }
            return result
        }
    }

    private companion object {
        val TOKYO: ZoneId = ZoneId.of("Asia/Tokyo")
    }
}
