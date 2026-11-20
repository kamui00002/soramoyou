// ⭐️ 自分の投稿の削除（読み直し・持ち主の確認・文書の削除・数え直し・画像の削除・知らせ）の単体テスト（タスク 24・要件 7.20・10.11）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.write.DefaultStorageGateway
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FakeFirestoreWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FakeStorageWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteFailure
import com.yoshidometoru.soramoyou.data.remote.write.FixedWriteGate
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics
import com.yoshidometoru.soramoyou.data.remote.write.StorageWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.StorageWriteFailure
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * 削除が iOS と同じ順序（読み直して持ち主を確かめる → 文書の削除 → 投稿数の数え直し → 画像の削除）で進み、知らせを最後に流すことを確かめる。
 * 書き込みは本物の入口（Firestore・Storage）の上で動かし、偽物にするのは SDK への継ぎ目と、読み取り口・数え直しの部品だけ。
 */
class DefaultPostDeleterTest {

    private val uid = Uid("UID-1")
    private val postId = PostId("POST-1")
    private val analytics = RecordingAnalytics()
    private val firestore = FakeFirestoreWriteClient()
    private val storage = FakeStorageWriteClient()
    private val counter = RecordingCountSynchronizer { firestore.calls.size to storage.calls.size }
    private val deletedPosts = DeletedPosts()
    private val inFlight = InFlightWrites()

    /** 知らせを受け取った投稿と、受け取った時点で Storage に届いていた操作の数（順序を確かめるため）。 */
    private val received = mutableListOf<Pair<PostId, Int>>()
    private val collector: Job = CoroutineScope(Dispatchers.Unconfined).launch {
        deletedPosts.events.collect { received += it to storage.calls.size }
    }

    @AfterTest
    fun stopCollecting() = collector.cancel()

    /** 自分の投稿の文書（画像 2 枚。1 枚目はパスあり、2 枚目はパスの無い旧データ。元画像 1 枚）。 */
    private val ownDocument = RawDocument(
        "POST-1",
        mapOf(
            "userId" to "UID-1",
            "visibility" to "followers",
            "images" to listOf(
                mapOf(
                    "url" to "https://example.com/A.jpg",
                    "storagePath" to "posts/UID-1/followers/A.jpg",
                    "thumbnailStoragePath" to "thumbnails/UID-1/followers/A_thumb.jpg",
                ),
                mapOf(
                    "url" to downloadUrl("posts%2FUID-1%2Ffollowers%2FB.jpg"),
                    "thumbnail" to downloadUrl("thumbnails%2FUID-1%2Ffollowers%2FB_thumb.jpg"),
                ),
            ),
            "originalImages" to listOf(mapOf("storagePath" to "originals/UID-1/followers/O.jpg")),
        ),
    )

    private val expectedPaths = listOf(
        "posts/UID-1/followers/A.jpg",
        "thumbnails/UID-1/followers/A_thumb.jpg",
        "posts/UID-1/followers/B.jpg",
        "thumbnails/UID-1/followers/B_thumb.jpg",
        "originals/UID-1/followers/O.jpg",
    )

    private fun downloadUrl(encoded: String) = "https://firebasestorage.googleapis.com/v0/b/bucket/o/$encoded?alt=media&token=t"

    private fun reader(document: AppResult<RawDocument?> = AppResult.Ok(ownDocument)) =
        FakeFirestoreReader(documents = mapOf("posts/POST-1" to document))

    private fun deleter(
        reader: FakeFirestoreReader = reader(),
        enabled: Set<WriteCapability> = ALL_WRITES_ENABLED,
        signedIn: Uid? = uid,
        storageClient: StorageWriteClient = storage,
        imageDeleteTimeout: Duration = 30.seconds,
    ) = DefaultPostDeleter(
        reader = reader,
        gateway = realWriteGateway(firestore, analytics, enabled, signedIn),
        storage = DefaultStorageGateway(FixedWriteGate(enabled), storageClient, analytics, wait = {}),
        countSynchronizer = counter,
        deletedPosts = deletedPosts,
        analytics = analytics,
        currentUid = { signedIn },
        inFlight = inFlight,
        imageDeleteTimeout = imageDeleteTimeout,
    )

    private fun storageDeletes() = storage.calls.filter { it.operation == "delete" }.map { it.path }

    // ── 成功 ──

    @Test
    fun `サーバーから読み直して文書を消し、数え直してから画像を全て消し、最後に知らせてOkを返す`() = runBlocking {
        val reader = reader()

        val result = deleter(reader).delete(postId)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf(DocRef.post(postId) to ReadSource.SERVER), reader.gets)
        assertEquals(listOf(FakeFirestoreWriteClient.Call("delete", listOf("posts/POST-1"))), firestore.calls)
        // 数え直しは文書の削除の後・画像の削除の前
        assertEquals(listOf(RecordingCountSynchronizer.Recount(uid, firestoreCallsBefore = 1, storageCallsBefore = 0)), counter.calls)
        assertEquals(expectedPaths.sorted(), storageDeletes().sorted())
        // 知らせは画像を全て消した後に 1 回
        assertEquals(listOf(postId to expectedPaths.size), received)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `数え直しに失敗しても削除の成功は覆さず、画像を消して知らせ、記録し直さない`() = runBlocking {
        counter.result = AppResult.Err(AppError.Network)

        val result = deleter().delete(postId)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(expectedPaths.size, storageDeletes().size)
        assertEquals(listOf(postId), received.map { it.first })
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `画像の削除は1つ失敗しても残りを消し、無いものは記録せず、ほかの失敗だけを記録してOkを返す`() = runBlocking {
        storage.failWhen = { call ->
            when (call.path) {
                "posts/UID-1/followers/A.jpg" -> StorageWriteFailure(AppError.NotFound, RuntimeException("偽物の不在"))
                "thumbnails/UID-1/followers/B_thumb.jpg" -> StorageWriteFailure(AppError.PermissionDenied, RuntimeException("偽物の拒否"))
                else -> null
            }
        }

        val result = deleter().delete(postId)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(expectedPaths.sorted(), storageDeletes().sorted())
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "PostDeleter.delete.images")), analytics.errors)
        assertEquals(listOf(postId), received.map { it.first })
    }

    @Test
    fun `返事の無い画像の削除は上限で打ち切ってNetworkで記録し、残りを消して知らせ、Okを返す`() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val hanging = HangingStorageWriteClient(storage, hang = setOf("thumbnails/UID-1/followers/A_thumb.jpg"), gate)
        // 見張り：上限が効かない改変を当てても、5 秒で待ちを外してテストを赤で終わらせる（削除の後半は取り消さないので外からは止められない）
        val watchdog = launch {
            delay(5.seconds)
            gate.complete(Unit)
        }
        try {
            val result = deleter(storageClient = hanging, imageDeleteTimeout = 50.milliseconds).delete(postId)

            assertEquals(AppResult.Ok(Unit), result)
            assertEquals(expectedPaths.sorted(), storageDeletes().sorted())
            assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.Network, "PostDeleter.delete.images")), analytics.errors)
            assertEquals(listOf(postId), received.map { it.first })
        } finally {
            watchdog.cancel()
            gate.complete(Unit)
        }
    }

    @Test
    fun `文書の削除を送った後で取り消されても、数え直し・画像の削除・知らせを最後まで行う`() = runBlocking {
        val recountGate = CompletableDeferred<Unit>()
        counter.beforeReturn = { recountGate.await() }
        val job = launch(Dispatchers.Unconfined) { deleter().delete(postId) }
        try {
            // 数え直しの途中で止まっている（文書は消した・画像はまだ）
            assertEquals(1, firestore.calls.size)
            assertEquals(emptyList(), storageDeletes())
            job.cancel()
        } finally {
            // 上の確かめが失敗しても待ちを外す（削除の後半は取り消さないので、外さないと runBlocking が子を待ち続けて止まる）
            recountGate.complete(Unit)
        }
        job.join()

        assertEquals(expectedPaths.sorted(), storageDeletes().sorted())
        assertEquals(listOf(postId), received.map { it.first })
    }

    @Test
    fun `文書の削除から画像の削除までを、走っている書き込みとして数える（ログアウトが終わりを待つ）`() = runBlocking {
        // ログアウトはこの数が 0 になるのを待ってからセッションを破棄する（全体レビュー 4 回目 Q03）。数える範囲が取り消さない範囲より
        // 狭いと、その外の段（数え直し・画像の削除）がログアウトの後に断られ、投稿数が古いまま・画像が残る。止めるのは最後の段（画像の削除）
        val gate = CompletableDeferred<Unit>()
        val hanging = HangingStorageWriteClient(storage, hang = setOf(expectedPaths.first()), gate = gate)
        val job = launch(Dispatchers.Unconfined) { deleter(storageClient = hanging).delete(postId) }
        try {
            // 文書は消して数え直した。画像の削除の 1 本が返事を待っている
            assertEquals(1, firestore.calls.size)
            assertEquals(1, counter.calls.size)
            assertTrue(expectedPaths.first() in storageDeletes())
            assertTrue(inFlight.isBusy())
        } finally {
            // 上の確かめが失敗しても待ちを外す（削除の後半は取り消さないので、外さないと runBlocking が子を待ち続けて止まる）
            gate.complete(Unit)
        }
        job.join()

        assertFalse(inFlight.isBusy())
        assertEquals(listOf(postId), received.map { it.first })
    }

    // ── 先へ進まない失敗 ──

    @Test
    fun `未ログインなら読まずにPermissionDeniedを記録して返す`() = runBlocking {
        val reader = reader()

        val result = deleter(reader, signedIn = null).delete(postId)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "PostDeleter.delete")), analytics.errors)
        assertEquals(emptyList(), reader.gets)
        assertNothingWritten()
    }

    @Test
    fun `文書IDに使えない投稿IDは読まずにNotFoundを記録して返す`() = runBlocking {
        val reader = reader()

        val result = deleter(reader).delete(PostId("a/b"))

        assertEquals(AppResult.Err(AppError.NotFound), result)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.NotFound, "PostDeleter.delete.read")), analytics.errors)
        assertEquals(emptyList(), reader.gets)
        assertNothingWritten()
    }

    @Test
    fun `読み直しに失敗したら、その失敗を記録して返し、何も消さない`() = runBlocking {
        val result = deleter(reader(AppResult.Err(AppError.Network))).delete(postId)

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.Network, "PostDeleter.delete.read")), analytics.errors)
        assertNothingWritten()
    }

    @Test
    fun `文書が無ければNotFoundを記録して返し、何も消さない`() = runBlocking {
        val result = deleter(reader(AppResult.Ok(null))).delete(postId)

        assertEquals(AppResult.Err(AppError.NotFound), result)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.NotFound, "PostDeleter.delete.read")), analytics.errors)
        assertNothingWritten()
    }

    @Test
    fun `いまのユーザーの投稿でなければPermissionDeniedを記録して返し、何も消さない`() = runBlocking {
        val others = RawDocument("POST-1", ownDocument.data + ("userId" to "UID-2"))

        val result = deleter(reader(AppResult.Ok(others))).delete(postId)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "PostDeleter.delete.owner")), analytics.errors)
        assertNothingWritten()
    }

    @Test
    fun `文書の削除に失敗したら記録して返し、数え直しも画像の削除も知らせもしない`() = runBlocking {
        firestore.failOn = "delete"
        firestore.failure = FirestoreWriteFailure(AppError.PermissionDenied, RuntimeException("偽物の拒否"))

        val result = deleter().delete(postId)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "PostDeleter.delete.document")), analytics.errors)
        assertEquals(emptyList(), counter.calls)
        assertEquals(emptyList(), storage.calls)
        assertEquals(emptyList(), received)
    }

    @Test
    fun `削除の書き込みが無効なビルドでは、入口の記録だけでFirestoreにもStorageにも届かない`() = runBlocking {
        val result = deleter(enabled = ALL_WRITES_ENABLED - WriteCapability.POST_DELETE).delete(postId)

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.POST_DELETE)), result)
        // 入口が自分で断って記録した 1 件だけ（削除の部品は記録し直さない）
        assertEquals(listOf(AppError.WriteBlocked(WriteCapability.POST_DELETE)), analytics.errors.map { it.error })
        assertEquals(emptyList(), firestore.calls)
        assertEquals(emptyList(), counter.calls)
        assertEquals(emptyList(), storage.calls)
        assertEquals(emptyList(), received)
    }

    /** 文書も画像も消しておらず、数え直しも知らせもしていない。 */
    private fun assertNothingWritten() {
        assertEquals(emptyList(), firestore.calls)
        assertEquals(emptyList(), counter.calls)
        assertEquals(emptyList(), storage.calls)
        assertEquals(emptyList(), received)
    }
}

/** [hang] のパスの削除だけ、記録した後で [gate] が開くまで返事をしない Storage の継ぎ目（返事の無い要求の再現）。ほかは [inner] に任せる。 */
private class HangingStorageWriteClient(
    private val inner: FakeStorageWriteClient,
    private val hang: Set<String>,
    private val gate: CompletableDeferred<Unit>,
) : StorageWriteClient {
    override suspend fun put(path: String, bytes: ByteArray, contentType: String) = inner.put(path, bytes, contentType)
    override suspend fun downloadUrl(path: String): String = inner.downloadUrl(path)
    override suspend fun delete(path: String) {
        inner.delete(path)
        if (path in hang) gate.await()
    }
    override suspend fun list(path: String): List<String> = inner.list(path)
}

/**
 * 呼ばれた uid と、呼ばれた時点で Firestore・Storage に届いていた操作の数を記録する数え直しの偽物（順序を確かめるため）。
 * [beforeReturn] で返す前に待たせられる（取り消しのテスト用）。
 */
private class RecordingCountSynchronizer(private val progress: () -> Pair<Int, Int>) : PostsCountSynchronizer {

    data class Recount(val uid: Uid, val firestoreCallsBefore: Int, val storageCallsBefore: Int)

    val calls = mutableListOf<Recount>()
    var result: AppResult<Long> = AppResult.Ok(3L)
    var beforeReturn: suspend () -> Unit = {}

    override suspend fun recount(uid: Uid): AppResult<Long> {
        val (firestoreCalls, storageCalls) = progress()
        calls += Recount(uid, firestoreCalls, storageCalls)
        beforeReturn()
        return result
    }
}
