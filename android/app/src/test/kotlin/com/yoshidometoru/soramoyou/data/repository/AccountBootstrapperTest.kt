// ⭐️ アカウントの作成直後のアカウント文書の作成の単体テスト（タスク 14.2・要件 2.3・2.4・2.10・2.11・3.1〜3.4）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.DocumentBuilders
import com.yoshidometoru.soramoyou.data.remote.RawDocument
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
 * アカウントの作成直後の部品が、`users` → `publicProfiles` の順に、それぞれ「無ければ作る」トランザクションで作ることを確かめる
 * （設計書 :749「bootstrap」）。本物の書き込みの入口（可否・形の検証・記録）と本物の契約の上で動かし、
 * 偽物にするのは Firestore の SDK への継ぎ目だけ（[FakeFirestoreWriteClient]）。
 */
class AccountBootstrapperTest {

    private val uid = Uid("UID-1")
    private val email = "sora@example.com"
    private val now: Instant = Instant.parse("2026-10-05T01:02:03Z")
    private val analytics = RecordingAnalytics()

    private val userPath = "users/UID-1"
    private val profilePath = "publicProfiles/UID-1"

    private fun bootstrapper(
        client: FakeFirestoreWriteClient,
        enabled: Set<WriteCapability> = ALL_WRITES_ENABLED,
    ) = DefaultAccountBootstrapper(
        realWriteGateway(client, analytics, enabled, signedInUid = uid),
        analytics,
        Clock.fixed(now, ZoneOffset.UTC),
    )

    /** 書き込み（tx.set）が行われた先のパスを順に。 */
    private fun FakeFirestoreWriteClient.writtenPaths(): List<String> =
        calls.filter { it.operation == "tx.set" }.map { it.paths.single() }

    private fun existing(path: String) = mapOf(path to RawDocument(path.substringAfterLast('/'), mapOf("id" to uid.value)))

    // ── 作る順と、読んでから書くこと ──

    @Test
    fun `どちらも無ければ、usersを読んで作り、次にpublicProfilesを読んで作る（それぞれ別のトランザクション）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = bootstrapper(client).bootstrap(uid, email)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(
            listOf(
                "runTransaction" to emptyList<String>(),
                "tx.get" to listOf(userPath),
                "tx.set" to listOf(userPath),
                "runTransaction" to emptyList<String>(),
                "tx.get" to listOf(profilePath),
                "tx.set" to listOf(profilePath),
            ),
            client.calls.map { it.operation to it.paths },
        )
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `作る内容は、契約に合格する組み立てそのもので、fcmTokenを含まない（時刻は注入した端末の時刻）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        bootstrapper(client).bootstrap(uid, email)

        val writes = client.calls.filter { it.operation == "tx.set" }
        assertEquals(DocumentBuilders.userCreate(uid, email, now), writes[0].data)
        assertEquals(DocumentBuilders.publicProfileCreate(uid, source = null, now = now), writes[1].data)
        val keys = writes.flatMap { it.data.orEmpty().keys }
        assertTrue(keys.none { it.startsWith("fcmToken") }, "fcmToken 系のキーを書いた: $keys")
    }

    @Test
    fun `メールアドレスが無ければ（匿名など）、usersにemailのキー自体を書かない`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        bootstrapper(client).bootstrap(uid, email = null)

        val userDoc = client.calls.first { it.operation == "tx.set" }.data.orEmpty()
        assertEquals(DocumentBuilders.userCreate(uid, null, now), userDoc)
        assertTrue("email" !in userDoc, "email のキーを書いた: ${userDoc.keys}")
    }

    // ── 「無ければ作る」：再試行しても既存の値を上書きしない ──

    @Test
    fun `usersが既にあれば、usersを上書きせず、無いpublicProfilesだけを作る`() = runBlocking {
        val client = FakeFirestoreWriteClient(documents = existing(userPath))

        val result = bootstrapper(client).bootstrap(uid, email)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf(profilePath), client.writtenPaths())
    }

    @Test
    fun `publicProfilesが既にあれば、publicProfilesを上書きせず、無いusersだけを作る`() = runBlocking {
        val client = FakeFirestoreWriteClient(documents = existing(profilePath))

        val result = bootstrapper(client).bootstrap(uid, email)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf(userPath), client.writtenPaths())
    }

    @Test
    fun `どちらも既にあれば（再試行）、何も書かずに成功する`() = runBlocking {
        val client = FakeFirestoreWriteClient(documents = existing(userPath) + existing(profilePath))

        val result = bootstrapper(client).bootstrap(uid, email)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(emptyList(), client.writtenPaths())
        assertEquals(emptyList(), analytics.errors)
    }

    // ── 失敗：返して記録する。セッションは維持する（認証の部品を持たないので、サインアウトの経路が無い）──

    @Test
    fun `usersの作成に失敗したら、publicProfilesには進まず、失敗を返して発生箇所つきで記録する`() = runBlocking {
        val client = FakeFirestoreWriteClient().apply {
            failOn = "tx.set"
            failAfter = 0
            failure = FirestoreWriteFailure(AppError.Network, RuntimeException("偽物の通信断"))
        }

        val result = bootstrapper(client).bootstrap(uid, email)

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(emptyList(), client.writtenPaths())
        assertTrue(client.calls.none { it.paths == listOf(profilePath) }, "usersの失敗の後で publicProfiles に触れた")
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.Network, "AccountBootstrapper.bootstrap.users")),
            analytics.errors,
        )
    }

    @Test
    fun `publicProfilesの作成に失敗したら、握りつぶさず失敗を返して記録する（usersは作られたまま）`() = runBlocking {
        val client = FakeFirestoreWriteClient().apply {
            failOn = "tx.set"
            failAfter = 1
            failure = FirestoreWriteFailure(AppError.Network, RuntimeException("偽物の通信断"))
        }

        val result = bootstrapper(client).bootstrap(uid, email)

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(listOf(userPath), client.writtenPaths())
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.Network, "AccountBootstrapper.bootstrap.publicProfiles")),
            analytics.errors,
        )
    }

    @Test
    fun `権限の拒否は、入口が断った未ログインと区別できないので、記録する側に倒す`() = runBlocking {
        val client = FakeFirestoreWriteClient().apply {
            failOn = "tx.set"
            failAfter = 0
            failure = FirestoreWriteFailure(AppError.PermissionDenied, RuntimeException("偽物の権限の拒否"))
        }

        val result = bootstrapper(client).bootstrap(uid, email)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "AccountBootstrapper.bootstrap.users")),
            analytics.errors,
        )
    }

    @Test
    fun `入口が断った形の違反は入口が記録済みなので、ここでは記録し直さない（監視する件数を二重にしない）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        // 空のメールアドレスは組み立てがそのまま出し、契約の長さの検査（1〜254）が止める
        val result = bootstrapper(client).bootstrap(uid, email = "")

        val error = assertIs<AppResult.Err>(result).error
        assertIs<AppError.ShapeViolation>(error)
        assertEquals(emptyList(), client.writtenPaths())
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(error, "FirestoreWriteGateway.transaction")),
            analytics.errors,
        )
    }

    // ── 書き込みの可否：アカウントの作成（ACCOUNT_CREATE）で判定する ──

    @Test
    fun `ACCOUNT_CREATEだけが有効でも作れる（作成の可否はACCOUNT_CREATE）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = bootstrapper(client, enabled = setOf(WriteCapability.ACCOUNT_CREATE)).bootstrap(uid, email)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf(userPath, profilePath), client.writtenPaths())
    }

    @Test
    fun `ACCOUNT_CREATEが無効なら、Firebaseに届かずWriteBlockedを返し、記録は入口の1件だけ（M1の保証）`() = runBlocking {
        val client = FakeFirestoreWriteClient()
        val others = ALL_WRITES_ENABLED - WriteCapability.ACCOUNT_CREATE

        val result = bootstrapper(client, enabled = others).bootstrap(uid, email)

        val blocked = AppError.WriteBlocked(WriteCapability.ACCOUNT_CREATE)
        assertEquals(AppResult.Err(blocked), result)
        assertEquals(emptyList(), client.calls, "可否が無効なのに Firebase に届いた")
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(blocked, "FirestoreWriteGateway.transaction")),
            analytics.errors,
        )
    }
}
