// ⭐️ 投稿数の数え直しの単体テスト（タスク 23.1・要件 7.19・7.20）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.FsValue
import com.yoshidometoru.soramoyou.data.remote.read.CountSpec
import com.yoshidometoru.soramoyou.data.remote.write.FakeFirestoreWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteFailure
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlinx.coroutines.runBlocking

/**
 * 投稿数の数え直しが、iOS の recountPostsCount（FirestoreService.swift:678-700）と同じ順序で
 * 「全投稿数 → 公開投稿数 → users → publicProfiles」を行い、publicProfiles の失敗だけは記録して続行することを確かめる（設計書 :869）。
 * 書き込みは本物の入口と本物の契約の上で動かし、偽物にするのは Firestore の SDK への継ぎ目と読み取り口だけ。
 */
class DefaultPostsCountSynchronizerTest {

    private val uid = Uid("UID-1")
    private val analytics = RecordingAnalytics()

    private val usersPath = "users/UID-1"
    private val publicProfilesPath = "publicProfiles/UID-1"

    /** 全投稿数 [all]・公開投稿数 [public] を返す読み取り口（どちらも結果ごと差し替えられる）。 */
    private fun reader(
        all: AppResult<Long> = AppResult.Ok(5L),
        public: AppResult<Long> = AppResult.Ok(3L),
    ) = FakeFirestoreReader(countResults = mapOf(CountSpec.OwnPosts(uid) to all, CountSpec.OwnPublicPosts(uid) to public))

    private fun synchronizer(
        reader: FakeFirestoreReader,
        client: FakeFirestoreWriteClient = FakeFirestoreWriteClient(),
        enabled: Set<WriteCapability> = ALL_WRITES_ENABLED,
    ) = DefaultPostsCountSynchronizer(
        reader = reader,
        gateway = realWriteGateway(client, analytics, enabled, signedInUid = uid),
        analytics = analytics,
    )

    private fun postsCount(count: Long) = mapOf("postsCount" to FsValue.Int64(count))

    // ── 成功 ──

    @Test
    fun `全投稿数と公開投稿数をサーバーで数え、usersに全投稿数を、publicProfilesに公開投稿数を、この順に書いて全投稿数を返す`() = runBlocking {
        val reader = reader()
        val client = FakeFirestoreWriteClient()

        val result = synchronizer(reader, client).recount(uid)

        assertEquals(AppResult.Ok(5L), result)
        assertEquals(listOf(CountSpec.OwnPosts(uid), CountSpec.OwnPublicPosts(uid)), reader.counts)
        assertEquals(
            listOf(
                FakeFirestoreWriteClient.Call("update", listOf(usersPath), postsCount(5L)),
                FakeFirestoreWriteClient.Call("update", listOf(publicProfilesPath), postsCount(3L)),
            ),
            client.calls,
        )
        assertEquals(emptyList<RecordingAnalytics.LoggedError>(), analytics.errors)
    }

    // ── 集計の失敗：何も書かずに失敗を返す ──

    @Test
    fun `全投稿数の集計に失敗したら、公開投稿数を数えず何も書かずに失敗を返し、集計の段階として記録する`() = runBlocking {
        val reader = reader(all = AppResult.Err(AppError.Network))
        val client = FakeFirestoreWriteClient()

        val result = synchronizer(reader, client).recount(uid)

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(listOf<CountSpec>(CountSpec.OwnPosts(uid)), reader.counts)
        assertEquals(emptyList<FakeFirestoreWriteClient.Call>(), client.calls)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.Network, "PostsCountSynchronizer.recount.countAll")), analytics.errors)
    }

    @Test
    fun `公開投稿数の集計に失敗したら、usersも書かずに失敗を返し、集計の段階として記録する`() = runBlocking {
        // 片方だけ書くと、全投稿数と公開投稿数が別の時点の値になる
        val reader = reader(public = AppResult.Err(AppError.Unknown("FAILED_PRECONDITION")))
        val client = FakeFirestoreWriteClient()

        val result = synchronizer(reader, client).recount(uid)

        assertEquals(AppResult.Err(AppError.Unknown("FAILED_PRECONDITION")), result)
        assertEquals(emptyList<FakeFirestoreWriteClient.Call>(), client.calls)
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.Unknown("FAILED_PRECONDITION"), "PostsCountSynchronizer.recount.countPublic")),
            analytics.errors,
        )
    }

    // ── 書き込みの失敗 ──

    @Test
    fun `usersの更新に失敗したら、publicProfilesを書かずに失敗を返し、usersの段階として記録する`() = runBlocking {
        // 継ぎ目は全ての update を失敗させる。publicProfiles まで進んでいれば、その失敗の記録が 2 件目として残る
        val client = FakeFirestoreWriteClient().apply {
            failOn = "update"
            failure = FirestoreWriteFailure(AppError.Network, RuntimeException("偽物の通信断"))
        }

        val result = synchronizer(reader(), client).recount(uid)

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.Network, "PostsCountSynchronizer.recount.users")), analytics.errors)
    }

    @Test
    fun `publicProfilesの更新に失敗しても、usersは書けているので全投稿数を返し、publicProfilesの段階として記録する`() = runBlocking {
        // iOS の移行前のユーザーは publicProfiles が無く、更新は NotFound になる（iOS もログに残して続行する）
        val client = FakeFirestoreWriteClient().apply {
            failOn = "update"
            failAfter = 1
            failure = FirestoreWriteFailure(AppError.NotFound, RuntimeException("偽物の不在"))
        }

        val result = synchronizer(reader(), client).recount(uid)

        assertEquals(AppResult.Ok(5L), result)
        assertEquals(listOf(FakeFirestoreWriteClient.Call("update", listOf(usersPath), postsCount(5L))), client.calls)
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.NotFound, "PostsCountSynchronizer.recount.publicProfiles")),
            analytics.errors,
        )
    }

    // ── 入口が断ったものは記録し直さない ──

    @Test
    fun `可否が無効なビルドでは、書き込みの入口が断って記録し、この部品は記録し直さない`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = synchronizer(reader(), client, enabled = ALL_WRITES_ENABLED - WriteCapability.POSTS_COUNT_SYNC).recount(uid)

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.POSTS_COUNT_SYNC)), result)
        assertEquals(emptyList<FakeFirestoreWriteClient.Call>(), client.calls)
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.WriteBlocked(WriteCapability.POSTS_COUNT_SYNC), "FirestoreWriteGateway.update")),
            analytics.errors,
        )
    }

    @Test
    fun `publicProfilesに書く値を契約が止めたときも、入口の記録だけを残して続行する`() = runBlocking {
        // 集計が負の数を返すことは無いが、来ても書かずに止まり（契約の NON_NEGATIVE）、二重に記録しないことを確かめる
        val client = FakeFirestoreWriteClient()

        val result = synchronizer(reader(public = AppResult.Ok(-1L)), client).recount(uid)

        assertEquals(AppResult.Ok(5L), result)
        assertEquals(listOf(FakeFirestoreWriteClient.Call("update", listOf(usersPath), postsCount(5L))), client.calls)
        val logged = analytics.errors.single()
        assertIs<AppError.ShapeViolation>(logged.error)
        assertEquals("FirestoreWriteGateway.update", logged.context)
    }
}
