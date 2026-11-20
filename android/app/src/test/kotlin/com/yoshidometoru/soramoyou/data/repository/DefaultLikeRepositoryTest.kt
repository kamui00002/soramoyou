// ⭐️ 「押した結果どうなってほしいか」を指定する、いいねの書き込みの単体テスト（タスク 18.2・要件 9.2〜9.6・9.8）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.FsValue
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.write.FakeFirestoreWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteFailure
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * いいねの書き込みが、1 つのトランザクションで「自分のいいね文書」と「投稿」を読んでから、望む状態と違うときだけ
 * いいね文書の作成・削除と `likesCount` の ±1 を書くことを確かめる（設計書 :796-818・iOS FirestoreService.swift:1536-1582）。
 * 本物の書き込みの入口と本物の契約の上で動かし、偽物にするのは Firestore の SDK への継ぎ目だけ。
 */
class DefaultLikeRepositoryTest {

    private val uid = Uid("UID-1")
    private val postId = PostId("POST-1")
    private val now: Instant = Instant.parse("2026-10-09T05:00:00Z")
    private val analytics = RecordingAnalytics()

    private val likePath = "likes/UID-1_POST-1"
    private val postPath = "posts/POST-1"

    private fun post(likesCount: Any? = 7L) =
        postPath to RawDocument("POST-1", mapOf("userId" to "OTHER", "likesCount" to likesCount, "updatedAt" to "x"))

    private fun like() = likePath to RawDocument("UID-1_POST-1", mapOf("userId" to "UID-1", "postId" to "POST-1"))

    private fun repository(
        client: FakeFirestoreWriteClient = FakeFirestoreWriteClient(),
        reader: FakeFirestoreReader = FakeFirestoreReader(),
        enabled: Set<WriteCapability> = ALL_WRITES_ENABLED,
        signedInUid: Uid? = uid,
    ) = DefaultLikeRepository(
        gateway = realWriteGateway(client, analytics, enabled, signedInUid = signedInUid),
        reader = reader,
        analytics = analytics,
        currentUid = { signedInUid },
        clock = Clock.fixed(now, ZoneOffset.UTC),
    )

    /** トランザクションの中の操作を、操作名とパスの組で順に。 */
    private fun FakeFirestoreWriteClient.txOps(): List<Pair<String, String>> =
        calls.filter { it.operation.startsWith("tx.") }.map { it.operation to it.paths.single() }

    // ── 4 通りの分岐：望む状態と違うときだけ書く ──

    @Test
    fun `いいねしていない投稿にいいねすると、いいね文書を作り、数を1増やし、増やした後の数を返す`() = runBlocking {
        val client = FakeFirestoreWriteClient(mapOf(post()))

        val result = repository(client).setLike(postId, desired = true)

        assertEquals(AppResult.Ok(8L), result)
        assertEquals(
            listOf("tx.get" to likePath, "tx.get" to postPath, "tx.set" to likePath, "tx.update" to postPath),
            client.txOps(),
        )
        assertEquals(listOf(FakeFirestoreWriteClient.TxOutcome.COMMITTED), client.transactionOutcomes)
    }

    @Test
    fun `いいね済みの投稿を取り消すと、いいね文書を消し、数を1減らし、減らした後の数を返す`() = runBlocking {
        val client = FakeFirestoreWriteClient(mapOf(post(), like()))

        val result = repository(client).setLike(postId, desired = false)

        assertEquals(AppResult.Ok(6L), result)
        assertEquals(
            listOf("tx.get" to likePath, "tx.get" to postPath, "tx.delete" to likePath, "tx.update" to postPath),
            client.txOps(),
        )
        assertEquals(
            mapOf<String, FsValue>("likesCount" to FsValue.Increment(-1L)),
            client.calls.single { it.operation == "tx.update" }.data,
        )
    }

    @Test
    fun `既にいいね済みの投稿にいいねしても、何も書かずにいまの数を返す`() = runBlocking {
        val client = FakeFirestoreWriteClient(mapOf(post(), like()))

        val result = repository(client).setLike(postId, desired = true)

        assertEquals(AppResult.Ok(7L), result)
        assertEquals(listOf("tx.get" to likePath, "tx.get" to postPath), client.txOps())
    }

    @Test
    fun `いいねしていない投稿を取り消しても、何も書かずにいまの数を返す`() = runBlocking {
        val client = FakeFirestoreWriteClient(mapOf(post()))

        val result = repository(client).setLike(postId, desired = false)

        assertEquals(AppResult.Ok(7L), result)
        assertEquals(listOf("tx.get" to likePath, "tx.get" to postPath), client.txOps())
    }

    // ── 書く中身：いいね文書は 3 項目だけ、投稿は likesCount の +1 だけ ──

    @Test
    fun `いいね文書は3項目だけで、投稿にはlikesCountの加算だけを書く（更新日時を書かない）`() = runBlocking {
        val client = FakeFirestoreWriteClient(mapOf(post()))

        repository(client).setLike(postId, desired = true)

        assertEquals(
            mapOf<String, FsValue>(
                "userId" to FsValue.Str("UID-1"),
                "postId" to FsValue.Str("POST-1"),
                "createdAt" to FsValue.Time(now),
            ),
            client.calls.single { it.operation == "tx.set" }.data,
        )
        assertEquals(
            mapOf<String, FsValue>("likesCount" to FsValue.Increment(1L)),
            client.calls.single { it.operation == "tx.update" }.data,
        )
    }

    @Test
    fun `likesCountが欠けているか整数でなければ0として数える`() = runBlocking {
        for (broken in listOf(null, "7", 7.5)) {
            val client = FakeFirestoreWriteClient(mapOf(post(likesCount = broken)))
            assertEquals(AppResult.Ok(1L), repository(client).setLike(postId, desired = true), "likesCount=$broken")
        }
    }

    // ── 断る・失敗する ──

    @Test
    fun `いいねの書き込みが無効なビルドでは、Firebaseに届かずにWriteBlockedを返す`() = runBlocking {
        val client = FakeFirestoreWriteClient(mapOf(post()))

        val result = repository(client, enabled = ALL_WRITES_ENABLED - WriteCapability.LIKE).setLike(postId, desired = true)

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.LIKE)), result)
        assertTrue(client.calls.isEmpty(), "Firebase に届いている: ${client.calls}")
        // 入口が記録済みなので、この部品は記録し直さない（1 件だけ）
        assertEquals(1, analytics.errors.size)
    }

    @Test
    fun `ログインしていなければ、Firebaseに届かずにPermissionDeniedを返して記録する`() = runBlocking {
        val client = FakeFirestoreWriteClient(mapOf(post()))

        val result = repository(client, signedInUid = null).setLike(postId, desired = true)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertTrue(client.calls.isEmpty())
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "LikeRepository.setLike")), analytics.errors)
    }

    @Test
    fun `投稿の閲覧権限を失っていたら、何も書かずに権限拒否を返して記録する`() = runBlocking {
        val client = FakeFirestoreWriteClient(mapOf(post())).apply {
            // 1 回目の tx.get（いいね文書）は通り、2 回目（投稿）が rules に拒まれる
            failOn = "tx.get"
            failAfter = 1
            failure = FirestoreWriteFailure(AppError.PermissionDenied, RuntimeException("偽物の権限拒否"))
        }

        val result = repository(client).setLike(postId, desired = true)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertTrue(client.calls.none { it.operation in setOf("tx.set", "tx.update", "tx.delete") })
        assertEquals(listOf(FakeFirestoreWriteClient.TxOutcome.ABORTED), client.transactionOutcomes)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "LikeRepository.setLike")), analytics.errors)
    }

    // ── いいね済みかどうかの確認 ──

    @Test
    fun `表示中の投稿ごとに自分のいいね文書をサーバーから読み、あるものだけを返す`() = runBlocking {
        val reader = FakeFirestoreReader(
            documents = mapOf(
                "likes/UID-1_A" to AppResult.Ok(RawDocument("UID-1_A", mapOf("userId" to "UID-1"))),
                "likes/UID-1_B" to AppResult.Ok(null),
                "likes/UID-1_C" to AppResult.Ok(RawDocument("UID-1_C", mapOf("userId" to "UID-1"))),
            ),
        )

        val result = repository(reader = reader).likedAmong(listOf(PostId("A"), PostId("B"), PostId("C"), PostId("A")))

        assertEquals(AppResult.Ok(setOf(PostId("A"), PostId("C"))), result)
        // 重なった ID は 1 回だけ読み、全てサーバーから読む
        assertEquals(listOf("likes/UID-1_A", "likes/UID-1_B", "likes/UID-1_C"), reader.gets.map { it.first.path }.sorted())
        assertTrue(reader.gets.all { it.second == ReadSource.SERVER })
    }

    @Test
    fun `確認する投稿が無ければ読まずに空を返す`() = runBlocking {
        val reader = FakeFirestoreReader()

        assertEquals(AppResult.Ok(emptySet()), repository(reader = reader).likedAmong(emptyList()))
        assertTrue(reader.gets.isEmpty())
    }

    @Test
    fun `1件でも読めなければ、一部の結果でなく失敗を返す`() = runBlocking {
        val reader = FakeFirestoreReader(
            documents = mapOf(
                "likes/UID-1_A" to AppResult.Ok(RawDocument("UID-1_A", mapOf("userId" to "UID-1"))),
                "likes/UID-1_B" to AppResult.Err(AppError.Network),
            ),
        )

        val result = repository(reader = reader).likedAmong(listOf(PostId("A"), PostId("B")))

        assertIs<AppResult.Err>(result)
        assertEquals(AppError.Network, result.error)
    }

    @Test
    fun `ログインしていなければ、読まずにPermissionDeniedを返し、記録はしない`() = runBlocking {
        val reader = FakeFirestoreReader()

        val result = repository(reader = reader, signedInUid = null).likedAmong(listOf(PostId("A")))

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertTrue(reader.gets.isEmpty())
        // ログアウト直後に表示中の投稿を確かめても、記録を出さない（扱いは LikeStateStore が決める）
        assertTrue(analytics.errors.isEmpty(), "記録されている: ${analytics.errors}")
    }
}
