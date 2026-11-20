// ⭐️ 通報・ブロックの書き込みと、ブロック中のユーザーの取得の単体テスト（タスク 29.1・要件 11.2・11.4・11.5・11.6）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.FsValue
import com.yoshidometoru.soramoyou.contract.model.ReportReason
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.BlockedUserView
import com.yoshidometoru.soramoyou.data.model.PostImageView
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.RemoteImageUrlPolicy
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FakeFirestoreWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteFailure
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics
import com.yoshidometoru.soramoyou.platform.SessionManager
import com.yoshidometoru.soramoyou.platform.SessionScopedState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * 通報が `reports` に 5 項目だけを自動 ID で作ること、ブロックと解除が `users/{自分}` の `blockedUserIds` への 1 要素の
 * 追加・削除だけであること、ブロック中のユーザーを公開プロフィールの表示名とアイコン（読めなければ代替表示）で返すことを確かめる
 * （設計書 :945-962・iOS：FirestoreService.swift:1143-1194）。
 * 本物の書き込みの入口・契約・ブロック一覧・投稿者の表示の上で動かし、偽物にするのは Firestore の SDK への継ぎ目だけ。
 */
class DefaultModerationRepositoryTest {

    private val me = Uid("UID-1")
    private val analytics = RecordingAnalytics()

    /** 登録された状態を捨てない SessionManager の偽物（投稿者の表示の部品が作られるときに登録するための受け口）。 */
    private object IgnoringSessionManager : SessionManager {
        override fun register(state: SessionScopedState) = Unit
        override suspend fun clearLocalUserData() = Unit
    }

    /**
     * @param newReportId null なら製品と同じ既定（Firestore の自動 ID と同じ形）を使う。
     * 入口の書き手（signedInUid）と部品の書き手（currentUid）は同じ uid にそろえる（契約の `EqualsAuthUid` が入口の書き手と比べるため）。
     */
    private fun repository(
        client: FakeFirestoreWriteClient = FakeFirestoreWriteClient(),
        reader: FakeFirestoreReader = FakeFirestoreReader(),
        enabled: Set<WriteCapability> = ALL_WRITES_ENABLED,
        signedInUid: Uid? = me,
        newReportId: (() -> String)? = { REPORT_ID },
    ): DefaultModerationRepository {
        val gateway = realWriteGateway(client, analytics, enabled, signedInUid)
        val blockList = DefaultBlockListRepository(reader, { signedInUid }, analytics)
        val authors = DefaultAuthorProfileCache(reader, IgnoringSessionManager, RemoteImageUrlPolicy.PRODUCTION)
        return if (newReportId != null) {
            DefaultModerationRepository(gateway, blockList, authors, analytics, { signedInUid }, newReportId)
        } else {
            DefaultModerationRepository(gateway, blockList, authors, analytics, { signedInUid })
        }
    }

    private fun post(postId: String = "POST-1", author: String = "AUTHOR-1") = PostView(
        postId = PostId(postId),
        userId = Uid(author),
        images = listOf(PostImageView("https://example.com/$postId.jpg", null, 1L, 1L, 0L)),
        caption = null,
        hashtags = null,
        visibility = null,
        likesCount = 0L,
        createdAt = null,
        capturedAt = null,
        timeOfDay = null,
        skyType = null,
    )

    // ── 通報（要件 11.2・11.3） ──

    @Test
    fun `通報はreportsに5項目だけを書く（作成日時はサーバー時刻）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repository(client).report(post(), ReportReason.SPAM)

        assertEquals(AppResult.Ok(Unit), result)
        val call = client.calls.single()
        assertEquals("set", call.operation)
        assertEquals(listOf("reports/$REPORT_ID"), call.paths)
        assertEquals(
            mapOf<String, FsValue>(
                "postId" to FsValue.Str("POST-1"),
                "reporterId" to FsValue.Str("UID-1"),
                "reportedUserId" to FsValue.Str("AUTHOR-1"),
                "reason" to FsValue.Str("spam"),
                "createdAt" to FsValue.ServerTime,
            ),
            call.data,
        )
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `理由は5種の文字列をそのまま書く`() = runBlocking {
        val written = ReportReason.entries.map { reason ->
            val client = FakeFirestoreWriteClient()
            assertEquals(AppResult.Ok(Unit), repository(client).report(post(), reason), "$reason")
            (client.calls.single().data?.get("reason") as FsValue.Str).value
        }

        assertEquals(listOf("inappropriate", "spam", "harassment", "copyright", "other"), written)
    }

    @Test
    fun `通報の文書のIDは投稿のIDとは別で、既定ではFirestoreの自動IDと同じ形になり、通報ごとに変わる`() = runBlocking {
        val client = FakeFirestoreWriteClient()
        val repository = repository(client, newReportId = null)

        repository.report(post(postId = "POST-1"), ReportReason.OTHER)
        repository.report(post(postId = "POST-1"), ReportReason.OTHER)

        val ids = client.calls.map { it.paths.single().removePrefix("reports/") }
        assertEquals(2, ids.toSet().size, "同じ投稿の 2 回の通報が同じ文書を指している: $ids")
        for (id in ids) {
            assertEquals(20, id.length, id)
            assertTrue(id.all { it in FirestoreAutoId.ALPHABET }, id)
        }
    }

    @Test
    fun `通報の書き込みが無効なビルドでは、Firebaseに届かずにWriteBlockedを返す（記録は入口の1件だけ）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repository(client, enabled = ALL_WRITES_ENABLED - WriteCapability.REPORT).report(post(), ReportReason.SPAM)

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.REPORT)), result)
        assertTrue(client.calls.isEmpty(), "Firebase に届いている: ${client.calls}")
        // 入口が記録済みなので、この部品は記録し直さない（1 件だけ）
        assertEquals(1, analytics.errors.size)
    }

    @Test
    fun `通報はブロックの可否に左右されない（通報の書き込みはREPORTだけで決まる）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repository(client, enabled = setOf(WriteCapability.REPORT)).report(post(), ReportReason.SPAM)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(1, client.calls.size)
    }

    @Test
    fun `ログインしていなければ、Firebaseに届かずにPermissionDeniedを返して記録する`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repository(client, signedInUid = null).report(post(), ReportReason.SPAM)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertTrue(client.calls.isEmpty())
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "ModerationRepository.report")),
            analytics.errors,
        )
    }

    @Test
    fun `投稿者のuidが空の投稿は通報できず、形の違反を返して何も書かない`() = runBlocking {
        // 投稿の userId が空でも、投稿の変換は文字列として通す（タスク 7.2）。運営が追えない通報を作らない（契約 REPORT_CREATE）
        val client = FakeFirestoreWriteClient()

        val result = repository(client).report(post(author = ""), ReportReason.SPAM)

        assertIs<AppResult.Err>(result)
        assertIs<AppError.ShapeViolation>(result.error)
        assertTrue(client.calls.isEmpty(), "Firebase に届いている: ${client.calls}")
        // 入口が記録済みなので、この部品は記録し直さない（1 件だけ）
        assertEquals(1, analytics.errors.size)
    }

    @Test
    fun `通報の書き込みが失敗したら、失敗を返して発生箇所つきで記録する`() = runBlocking {
        for (failure in listOf<AppError>(AppError.PermissionDenied, AppError.Network)) {
            analytics.errors.clear()
            val client = FakeFirestoreWriteClient().apply {
                failOn = "set"
                this.failure = FirestoreWriteFailure(failure, RuntimeException("偽物の失敗"))
            }

            val result = repository(client).report(post(), ReportReason.SPAM)

            assertEquals(AppResult.Err(failure), result, "$failure")
            assertEquals(listOf(RecordingAnalytics.LoggedError(failure, "ModerationRepository.report")), analytics.errors, "$failure")
        }
    }

    // ── ブロックと解除（要件 11.4・11.5） ──

    @Test
    fun `ブロックは自分のユーザー文書のblockedUserIdsへ、相手のuidの追加だけを書く`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repository(client).block(Uid("B-1"))

        assertEquals(AppResult.Ok(Unit), result)
        val call = client.calls.single()
        assertEquals("update", call.operation)
        assertEquals(listOf("users/UID-1"), call.paths)
        // 更新日時などは書かない（iOS の blockUser と同じ）。一覧を値で上書きしない
        assertEquals(mapOf<String, FsValue>("blockedUserIds" to FsValue.ArrayUnion(listOf("B-1"))), call.data)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `解除は自分のユーザー文書のblockedUserIdsから、相手のuidの削除だけを書く`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repository(client).unblock(Uid("B-1"))

        assertEquals(AppResult.Ok(Unit), result)
        val call = client.calls.single()
        assertEquals("update", call.operation)
        assertEquals(listOf("users/UID-1"), call.paths)
        assertEquals(mapOf<String, FsValue>("blockedUserIds" to FsValue.ArrayRemove(listOf("B-1"))), call.data)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `ブロックと解除の書き込みが無効なビルドでは、Firebaseに届かずにWriteBlockedを返す（記録は入口の1件ずつ）`() = runBlocking {
        val client = FakeFirestoreWriteClient()
        val repository = repository(client, enabled = ALL_WRITES_ENABLED - WriteCapability.BLOCK)

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.BLOCK)), repository.block(Uid("B-1")))
        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.BLOCK)), repository.unblock(Uid("B-1")))

        assertTrue(client.calls.isEmpty(), "Firebase に届いている: ${client.calls}")
        assertEquals(2, analytics.errors.size)
    }

    @Test
    fun `ブロックと解除はREPORTの可否に左右されない（ブロックの書き込みはBLOCKだけで決まる）`() = runBlocking {
        val client = FakeFirestoreWriteClient()
        val repository = repository(client, enabled = setOf(WriteCapability.BLOCK))

        assertEquals(AppResult.Ok(Unit), repository.block(Uid("B-1")))
        assertEquals(AppResult.Ok(Unit), repository.unblock(Uid("B-1")))
        assertEquals(2, client.calls.size)
    }

    @Test
    fun `ログインしていなければ、ブロックも解除もFirebaseに届かずにPermissionDeniedを返して記録する`() = runBlocking {
        val client = FakeFirestoreWriteClient()
        val repository = repository(client, signedInUid = null)

        assertEquals(AppResult.Err(AppError.PermissionDenied), repository.block(Uid("B-1")))
        assertEquals(AppResult.Err(AppError.PermissionDenied), repository.unblock(Uid("B-1")))

        assertTrue(client.calls.isEmpty())
        assertEquals(
            listOf(
                RecordingAnalytics.LoggedError(AppError.PermissionDenied, "ModerationRepository.block"),
                RecordingAnalytics.LoggedError(AppError.PermissionDenied, "ModerationRepository.unblock"),
            ),
            analytics.errors,
        )
    }

    @Test
    fun `ブロックと解除の書き込みが失敗したら、失敗を返して発生箇所つきで記録する`() = runBlocking {
        // ユーザー文書が無いときの更新は NotFound になる
        val client = FakeFirestoreWriteClient().apply {
            failOn = "update"
            failure = FirestoreWriteFailure(AppError.NotFound, RuntimeException("偽物の不在"))
        }
        val repository = repository(client)

        assertEquals(AppResult.Err(AppError.NotFound), repository.block(Uid("B-1")))
        assertEquals(AppResult.Err(AppError.NotFound), repository.unblock(Uid("B-1")))

        assertEquals(
            listOf(
                RecordingAnalytics.LoggedError(AppError.NotFound, "ModerationRepository.block"),
                RecordingAnalytics.LoggedError(AppError.NotFound, "ModerationRepository.unblock"),
            ),
            analytics.errors,
        )
    }

    // ── ブロック中のユーザーの取得（要件 11.5） ──

    private fun userDocument(blocked: List<String>): Pair<String, AppResult<RawDocument?>> =
        DocRef.user(me).path to AppResult.Ok(RawDocument(me.value, mapOf("blockedUserIds" to blocked)))

    private fun publicProfile(uid: String, vararg fields: Pair<String, Any?>): Pair<String, AppResult<RawDocument?>> =
        "publicProfiles/$uid" to AppResult.Ok(RawDocument(uid, mapOf<String, Any?>("id" to uid) + fields))

    @Test
    fun `ブロック中のユーザーを、公開プロフィールの表示名とアイコンで、ブロックした順に返す`() = runBlocking {
        val reader = FakeFirestoreReader(
            documents = mapOf(
                userDocument(listOf("b-2", "b-1")),
                publicProfile("b-1", "displayName" to "そら", "photoURL" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/1.jpg"),
                publicProfile("b-2", "displayName" to "くも"),
            ),
        )

        val result = repository(reader = reader).blockedProfiles()

        assertEquals(
            AppResult.Ok(
                listOf(
                    BlockedUserView(Uid("b-2"), AuthorDisplay.Named("くも", null)),
                    BlockedUserView(Uid("b-1"), AuthorDisplay.Named("そら", "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/1.jpg")),
                ),
            ),
            result,
        )
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `公開プロフィールを取得できないユーザーは代替表示にし、一覧からは落とさない`() = runBlocking {
        val reader = FakeFirestoreReader(
            documents = mapOf(
                userDocument(listOf("b-missing", "b-other-id", "b-error", "b-blank")),
                // b-missing は文書が無い。b-other-id は中の id が別人。b-error は取得に失敗。b-blank は表示名が空
                "publicProfiles/b-other-id" to AppResult.Ok(RawDocument("b-other-id", mapOf("id" to "someone-else", "displayName" to "なりすまし"))),
                "publicProfiles/b-error" to AppResult.Err(AppError.Network),
                publicProfile("b-blank", "displayName" to "  ", "photoURL" to "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/blank.jpg"),
            ),
        )

        val result = repository(reader = reader).blockedProfiles()

        assertEquals(
            AppResult.Ok(
                listOf(
                    BlockedUserView(Uid("b-missing"), AuthorDisplay.Fallback(null)),
                    BlockedUserView(Uid("b-other-id"), AuthorDisplay.Fallback(null)),
                    BlockedUserView(Uid("b-error"), AuthorDisplay.Fallback(null)),
                    // 表示名が無いだけなら、アイコンは出す（投稿者の表示と同じ）
                    BlockedUserView(Uid("b-blank"), AuthorDisplay.Fallback("https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/blank.jpg")),
                ),
            ),
            result,
        )
        for (view in assertIs<AppResult.Ok<List<BlockedUserView>>>(result).value) assertEquals(AuthorDisplay.FALLBACK_NAME, view.author.name)
        // 個々のプロフィールが読めなかったことは、投稿者の表示と同じく記録しない（画面の一覧は代替表示で続く）
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `ブロック中のユーザーがいなければ、プロフィールを読まずに空の一覧を返す`() = runBlocking {
        val reader = FakeFirestoreReader(documents = mapOf(userDocument(emptyList())))

        assertEquals(AppResult.Ok(emptyList()), repository(reader = reader).blockedProfiles())
        assertEquals(listOf(DocRef.user(me)), reader.gets.map { it.first })
    }

    @Test
    fun `ログインしていなければ、何も読まずに空の一覧を返す`() = runBlocking {
        val reader = FakeFirestoreReader()

        assertEquals(AppResult.Ok(emptyList()), repository(reader = reader, signedInUid = null).blockedProfiles())
        assertTrue(reader.gets.isEmpty())
    }

    @Test
    fun `ブロック中のuidの一覧を読めなければ、失敗を返し、プロフィールは読まない（記録はブロック一覧の1件だけ）`() = runBlocking {
        val reader = FakeFirestoreReader(documents = mapOf(DocRef.user(me).path to AppResult.Err(AppError.Network)))

        val result = repository(reader = reader).blockedProfiles()

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(listOf(DocRef.user(me)), reader.gets.map { it.first })
        // 読み取りの失敗は BlockListRepository が記録済み。この部品は記録し直さない
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.Network, "BlockListRepository.blockedIds")),
            analytics.errors,
        )
    }

    private companion object {
        /** 通報の文書の ID として注入する決まった値。 */
        const val REPORT_ID = "REPORT-1"
    }
}
