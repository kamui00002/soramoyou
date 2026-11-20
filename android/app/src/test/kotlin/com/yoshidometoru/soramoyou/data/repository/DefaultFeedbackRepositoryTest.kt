// ⭐️ アプリ内フィードバックの書き込みの単体テスト（タスク 30・要件 13.2・13.3・13.4・13.6）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.FeedbackInput
import com.yoshidometoru.soramoyou.contract.document.FsValue
import com.yoshidometoru.soramoyou.contract.model.FeedbackCategory
import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.data.remote.write.FakeFirestoreWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteFailure
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * フィードバックが `feedback/{大文字の UUID}` に、`userId`・`message`・`createdAt`（サーバー時刻）を常に、種別・アプリのバージョン・
 * 端末情報を値があるときだけ書くこと、メールアドレスと表示名を含めないこと、空白だけ・1000 を超える本文を書かずに断ることを確かめる
 * （設計書の ModerationRepository・FeedbackRepository の節・iOS：Feedback.swift:44・70-86、FeedbackViewModel.swift:35-69）。
 * 本物の書き込みの入口・契約の上で動かし、偽物にするのは Firestore の SDK への継ぎ目だけ。
 */
class DefaultFeedbackRepositoryTest {

    private val me = Uid("UID-1")
    private val analytics = RecordingAnalytics()

    /**
     * @param newFeedbackId null なら製品と同じ既定（大文字の UUID）を使う。
     * 入口の書き手（signedInUid）と、入力の `userId`（[input] の既定）は同じ uid にそろえる（契約の `EqualsAuthUid` が入口の書き手と比べるため）。
     */
    private fun repository(
        client: FakeFirestoreWriteClient = FakeFirestoreWriteClient(),
        enabled: Set<WriteCapability> = ALL_WRITES_ENABLED,
        signedInUid: Uid? = me,
        newFeedbackId: (() -> String)? = { FEEDBACK_ID },
    ): DefaultFeedbackRepository {
        val gateway = realWriteGateway(client, analytics, enabled, signedInUid)
        return if (newFeedbackId != null) DefaultFeedbackRepository(gateway, analytics, newFeedbackId) else DefaultFeedbackRepository(gateway, analytics)
    }

    private fun input(
        message: String = "空がきれいでした",
        category: FeedbackCategory? = FeedbackCategory.BUG,
        appVersion: String? = "1.0.0 (1)",
        deviceInfo: String? = "Android 14 / Pixel 8",
        userId: Uid = me,
    ) = FeedbackInput(userId, message, category, appVersion, deviceInfo)

    // ── 書く中身（要件 13.2・13.4） ──

    @Test
    fun `feedbackに、ユーザーID・本文・サーバー時刻の作成日時と、種別・バージョン・端末情報を書く`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repository(client).submit(input())

        assertEquals(AppResult.Ok(Unit), result)
        val call = client.calls.single()
        assertEquals("set", call.operation)
        assertEquals(listOf("feedback/$FEEDBACK_ID"), call.paths)
        assertEquals(
            mapOf<String, FsValue>(
                "userId" to FsValue.Str("UID-1"),
                "message" to FsValue.Str("空がきれいでした"),
                "createdAt" to FsValue.ServerTime,
                "category" to FsValue.Str("bug"),
                "appVersion" to FsValue.Str("1.0.0 (1)"),
                "deviceInfo" to FsValue.Str("Android 14 / Pixel 8"),
            ),
            call.data,
        )
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `メールアドレスと表示名は書かない（書く項目は6つだけ）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        repository(client).submit(input())

        // 入力の型に無いので、書き込みにも出ない。項目の集合そのものを固定して、後から足されたら気づけるようにする
        assertEquals(
            setOf("userId", "message", "createdAt", "category", "appVersion", "deviceInfo"),
            client.calls.single().data?.keys,
        )
    }

    @Test
    fun `種別・バージョン・端末情報が無ければ、そのキーを書かない（空文字も無いものとする）`() = runBlocking {
        for ((appVersion, deviceInfo) in listOf<Pair<String?, String?>>(null to null, "" to "")) {
            val client = FakeFirestoreWriteClient()

            val result = repository(client).submit(input(category = null, appVersion = appVersion, deviceInfo = deviceInfo))

            assertEquals(AppResult.Ok(Unit), result, "$appVersion / $deviceInfo")
            assertEquals(setOf("userId", "message", "createdAt"), client.calls.single().data?.keys, "$appVersion / $deviceInfo")
        }
    }

    @Test
    fun `種別は3つの文字列をそのまま書く`() = runBlocking {
        val written = FeedbackCategory.entries.map { category ->
            val client = FakeFirestoreWriteClient()
            assertEquals(AppResult.Ok(Unit), repository(client).submit(input(category = category)), "$category")
            (client.calls.single().data?.get("category") as FsValue.Str).value
        }

        assertEquals(listOf("bug", "request", "other"), written)
    }

    // ── ドキュメント ID（iOS：Feedback.swift:44 の UUID().uuidString） ──

    @Test
    fun `既定のドキュメントIDは大文字のUUIDで、送るたびに変わる`() = runBlocking {
        val client = FakeFirestoreWriteClient()
        val repository = repository(client, newFeedbackId = null)

        repository.submit(input())
        repository.submit(input())

        val ids = client.calls.map { it.paths.single().removePrefix("feedback/") }
        assertEquals(2, ids.toSet().size, "同じ文書を指している: $ids")
        for (id in ids) {
            assertTrue(Regex("[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}").matches(id), "大文字の UUID の形でない: $id")
            // 形だけでなく UUID として読める値（iOS の uuidString と同じ。小文字に直しても同じ UUID）
            assertEquals(id, UUID.fromString(id).toString().uppercase(), id)
        }
    }

    // ── 本文の検査（要件 13.3） ──

    @Test
    fun `前後の空白を取り除いた本文を書く（全角の空白と改行も。中の改行は残す）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repository(client).submit(input(message = "　\n 空が\nきれい \t\n　"))

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(FsValue.Str("空が\nきれい"), client.calls.single().data?.get("message"))
    }

    @Test
    fun `空白だけの本文は、書かずに断る（半角・全角の空白・改行・タブ）`() = runBlocking {
        for (message in listOf("", " ", "　", "\n\t ", "  　\n　  ")) {
            val client = FakeFirestoreWriteClient()

            val result = repository(client).submit(input(message = message))

            assertEquals(AppResult.Err(AppError.Validation(ValidationReason.FEEDBACK_BLANK)), result, "「$message」")
            assertTrue(client.calls.isEmpty(), "Firebase に届いている: ${client.calls}")
        }
        // 入力の不備は、画面が先に止める操作なので記録しない（他の入力の不備と同じ）
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `1000文字ちょうどは書き、1001文字は書かずに断る`() = runBlocking {
        val ok = FakeFirestoreWriteClient()
        assertEquals(AppResult.Ok(Unit), repository(ok).submit(input(message = "あ".repeat(TextLimits.FEEDBACK_MAX))))
        assertEquals(1, ok.calls.size)

        val tooLong = FakeFirestoreWriteClient()
        val result = repository(tooLong).submit(input(message = "あ".repeat(TextLimits.FEEDBACK_MAX + 1)))

        assertEquals(AppResult.Err(AppError.Validation(ValidationReason.FEEDBACK_TOO_LONG)), result)
        assertTrue(tooLong.calls.isEmpty(), "Firebase に届いている: ${tooLong.calls}")
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `前後の空白は1000文字に数えない（取り除いた後で数える）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repository(client).submit(input(message = "　" + "あ".repeat(TextLimits.FEEDBACK_MAX) + "\n "))

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(TextLimits.FEEDBACK_MAX, (client.calls.single().data?.get("message") as FsValue.Str).value.length)
    }

    @Test
    fun `1000文字はrulesと同じUTF-16の単位で数える（絵文字は1つで2）`() = runBlocking {
        // 見た目の 501 文字（書記素）でも UTF-16 では 1002 で、rules が断る。送る前に断る
        val tooLong = FakeFirestoreWriteClient()
        assertEquals(
            AppResult.Err(AppError.Validation(ValidationReason.FEEDBACK_TOO_LONG)),
            repository(tooLong).submit(input(message = "😀".repeat(501))),
        )
        assertTrue(tooLong.calls.isEmpty())

        val ok = FakeFirestoreWriteClient()
        assertEquals(AppResult.Ok(Unit), repository(ok).submit(input(message = "😀".repeat(500))))
        assertEquals(1, ok.calls.size)
    }

    @Test
    fun `本文の検査の関数は、空白だけ・超過・範囲内を見分ける`() {
        assertEquals(ValidationReason.FEEDBACK_BLANK, feedbackMessageProblem(" 　\n"))
        assertEquals(ValidationReason.FEEDBACK_TOO_LONG, feedbackMessageProblem("あ".repeat(1001)))
        assertNull(feedbackMessageProblem("あ"))
        assertNull(feedbackMessageProblem("あ".repeat(1000)))
    }

    // ── 書き込みの入口（可否・書き手・形）と失敗（要件 13.6） ──

    @Test
    fun `フィードバックの書き込みが無効なビルドでは、Firebaseに届かずにWriteBlockedを返す（記録は入口の1件だけ）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repository(client, enabled = ALL_WRITES_ENABLED - WriteCapability.FEEDBACK).submit(input())

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.FEEDBACK)), result)
        assertTrue(client.calls.isEmpty(), "Firebase に届いている: ${client.calls}")
        // 入口が記録済みなので、この部品は記録し直さない（1 件だけ）
        assertEquals(1, analytics.errors.size)
    }

    @Test
    fun `フィードバックはほかの書き込みの可否に左右されない（FEEDBACKだけで決まる）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repository(client, enabled = setOf(WriteCapability.FEEDBACK)).submit(input())

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(1, client.calls.size)
    }

    @Test
    fun `ログインしていなければ、Firebaseに届かずにPermissionDeniedを返す`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repository(client, signedInUid = null).submit(input())

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertTrue(client.calls.isEmpty(), "Firebase に届いている: ${client.calls}")
        // 入口が「未ログイン」で断って記録し、権限の拒否はこの部品も記録する（二重でも監視の件数には影響しない：WriteFailureRecording.kt）
        assertTrue(analytics.errors.isNotEmpty())
    }

    @Test
    fun `入力のユーザーIDが書き手と違えば、契約が止めて何も書かない`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repository(client).submit(input(userId = Uid("SOMEONE-ELSE")))

        assertIs<AppResult.Err>(result)
        assertIs<AppError.ShapeViolation>(result.error)
        assertTrue(client.calls.isEmpty(), "Firebase に届いている: ${client.calls}")
        // 入口が記録済みなので、この部品は記録し直さない（1 件だけ）
        assertEquals(1, analytics.errors.size)
    }

    @Test
    fun `書き込みが失敗したら、失敗を返して発生箇所つきで記録する`() = runBlocking {
        for (failure in listOf<AppError>(AppError.PermissionDenied, AppError.Network)) {
            analytics.errors.clear()
            val client = FakeFirestoreWriteClient().apply {
                failOn = "set"
                this.failure = FirestoreWriteFailure(failure, RuntimeException("偽物の失敗"))
            }

            val result = repository(client).submit(input())

            assertEquals(AppResult.Err(failure), result, "$failure")
            assertEquals(listOf(RecordingAnalytics.LoggedError(failure, "FeedbackRepository.submit")), analytics.errors, "$failure")
        }
    }

    private companion object {
        /** 決まった文書 ID（既定の ID の生成を確かめるテスト以外で使う）。 */
        const val FEEDBACK_ID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    }
}
