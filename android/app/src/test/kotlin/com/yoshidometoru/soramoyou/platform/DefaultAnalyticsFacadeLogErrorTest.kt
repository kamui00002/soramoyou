// ⭐️ エラーの記録（logError）・Crashlytics のユーザー識別・投稿の変換の失敗の記録の単体テスト（タスク 4.2・要件 15.2・15.8・15.9）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.contract.ErrorCategory
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.Violation
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 送信先（PostHog・Firebase Analytics・Crashlytics）を記録用の偽物に差し替え、窓口の判断だけを確かめる。
 *
 * 根拠（読んだ現物）:
 * - iOS の ErrorHandler.swift `logError`（:133-161）：分類が systemError なら `recordError`（:149-152）、
 *   businessError なら `recordNonFatalError`（:153-156）で Crashlytics に記録し、userError は記録しない（:147-148）。
 *   分類にかかわらず、最後に `logErrorEvent` で `error_occurred` を送る（:159-160）
 * - iOS の LoggingService.swift `logErrorEvent`（:133-150）：パラメータは `error_category`（分類の rawValue）・
 *   `error_description`（浄化した説明）・`error_context`（浄化した発生箇所）の 3 つ（:139-146）。送るのは `logEvent`（:149）
 * - iOS の LoggingService.swift `setUserID`（:200-225）：Firebase → Crashlytics → PostHog の順に識別・解除する（:203-204・:216-220）
 * - iOS の PostDocumentDecoder.swift `report`（origin/main :78-88）：投稿の変換の失敗は `post_decode_failed`（`source`・`path`・`error`）を
 *   `logEvent` で送るだけで、Crashlytics には送らない（:76-77 の注記）
 */
class DefaultAnalyticsFacadeLogErrorTest {

    // ---- 記録用の偽物（PostHog・Firebase Analytics） ----

    private class FakePostHog : PostHogClient {
        val captured = mutableListOf<Pair<String, Map<String, Any>>>()
        val calls = mutableListOf<String>()
        override fun capture(event: String, properties: Map<String, Any>) {
            calls += "capture:$event"
            captured += event to properties
        }
        override fun screen(title: String) {
            calls += "screen:$title"
        }
        override fun identify(distinctId: String) {
            calls += "identify:$distinctId"
        }
        override fun reset() {
            calls += "reset"
        }
    }

    private class FakeFirebase : FirebaseAnalyticsClient {
        val logged = mutableListOf<Pair<String, Map<String, Any>>>()
        val userIds = mutableListOf<String?>()
        override fun logEvent(name: String, params: Map<String, Any>) {
            logged += name to params
        }
        override fun setUserId(id: String?) {
            userIds += id
        }
    }

    private class FailureLog {
        val entries = mutableListOf<Pair<String, Exception>>()
        val report: (String, Exception) -> Unit = { where, e -> entries += where to e }
    }

    private val postHog = FakePostHog()
    private val firebase = FakeFirebase()
    private val crash = FakeCrashReporter()
    private val facade = DefaultAnalyticsFacade(postHog, firebase, crash)

    // ---- error_occurred のパラメータ（15.2） ----

    @Test
    fun `user_errorはerror_occurredだけを両方へ送り、Crashlyticsには記録しない`() {
        facade.logError(AppError.NotFound, "PostDetailViewModel.loadAuthor")

        val expected = mapOf<String, Any>(
            "error_category" to "user_error",
            "error_description" to "NotFound",
            "error_context" to "PostDetailViewModel.loadAuthor",
        )
        assertEquals(listOf("error_occurred" to expected), postHog.captured)
        assertEquals(listOf("error_occurred" to expected), firebase.logged)
        assertEquals(emptyList(), crash.nonFatals)
    }

    @Test
    fun `system_errorはCrashlyticsにも非致命エラーとして記録し、error_occurredも送る`() {
        facade.logError(AppError.Network, "HomeViewModel.fetchPosts")

        assertEquals(
            listOf(FakeCrashReporter.NonFatal(AppError.Network, "HomeViewModel.fetchPosts", emptyMap())),
            crash.nonFatals,
        )
        assertEquals(
            listOf(
                "error_occurred" to mapOf<String, Any>(
                    "error_category" to "system_error",
                    "error_description" to "Network",
                    "error_context" to "HomeViewModel.fetchPosts",
                ),
            ),
            postHog.captured,
        )
    }

    @Test
    fun `business_errorはCrashlyticsにも非致命エラーとして記録し、error_occurredも送る`() {
        val error = AppError.WriteBlocked(WriteCapability.POST_CREATE)
        facade.logError(error, "FirestoreWriteGateway.create")

        assertEquals(listOf(FakeCrashReporter.NonFatal(error, "FirestoreWriteGateway.create", emptyMap())), crash.nonFatals)
        assertEquals(
            listOf(
                "error_occurred" to mapOf<String, Any>(
                    "error_category" to "business_error",
                    "error_description" to "WriteBlocked.POST_CREATE",
                    "error_context" to "FirestoreWriteGateway.create",
                ),
            ),
            firebase.logged,
        )
    }

    // ---- Crashlytics に送る分類の判断（15.8） ----

    @Test
    fun `AppErrorの全ての種類で、分類がsystem_errorとbusiness_errorのものだけをCrashlyticsに記録する`() {
        val samples = listOf(
            AppError.Auth(AuthErrorKind.NETWORK),
            AppError.Network,
            AppError.PermissionDenied,
            AppError.NotFound,
            AppError.WriteBlocked(WriteCapability.LIKE),
            AppError.ShapeViolation(listOf(Violation.MissingKey("likesCount"))),
            AppError.Validation(ValidationReason.NO_IMAGES),
            AppError.ImageUnreadable(0),
            AppError.ImageTooLarge(0, 6_000_000L),
            AppError.StageFailed(DeletionStage.LIKES, AppError.Network),
            AppError.StageFailed(DeletionStage.LIKES, AppError.NotFound),
            AppError.Unknown("想定外"),
        )

        samples.forEach { error -> facade.logError(error, "Test.sample") }

        val expectedRecorded = samples.filter { it.category != ErrorCategory.USER }
        assertEquals(expectedRecorded, crash.nonFatals.map { it.error })
        // 段階で止まった失敗は原因の分類を引き継ぐ（原因が system_error なら記録し、user_error なら記録しない）
        assertTrue(AppError.StageFailed(DeletionStage.LIKES, AppError.Network) in expectedRecorded)
        assertTrue(AppError.StageFailed(DeletionStage.LIKES, AppError.NotFound) !in expectedRecorded)
        // error_occurred は分類にかかわらず毎回送る（iOS ErrorHandler.swift:159-160）
        assertEquals(samples.size, postHog.captured.count { it.first == "error_occurred" })
        assertEquals(samples.size, firebase.logged.count { it.first == "error_occurred" })
    }

    @Test
    fun `形の契約違反は、違反したキーをshape_violationsとしてCrashlyticsの同じイベントに載せる`() {
        val error = AppError.ShapeViolation(listOf(Violation.MissingKey("likesCount"), Violation.UnexpectedKey("fcmToken")))
        facade.logError(error, "FirestoreWriteGateway.update")

        assertEquals(
            mapOf("shape_violations" to "missing:likesCount, unexpected:fcmToken"),
            crash.nonFatals.single().extra,
        )
    }

    @Test
    fun `段階で止まった原因が形の契約違反なら、違反したキーを載せる`() {
        val error = AppError.StageFailed(
            DeletionStage.USER,
            AppError.ShapeViolation(listOf(Violation.UnexpectedKey("fcmToken"))),
        )
        facade.logError(error, "AccountDeletionService.delete.users")

        assertEquals(mapOf("shape_violations" to "unexpected:fcmToken"), crash.nonFatals.single().extra)
    }

    // ---- 浄化（15.5） ----

    @Test
    fun `error_descriptionとerror_contextは送る前に浄化される`() {
        facade.logError(AppError.Unknown("送信先 a@example.com で失敗"), "AuthViewModel.signIn mail=b@example.com")

        val params = postHog.captured.single().second
        assertEquals("Unknown(送信先 [EMAIL_REDACTED] で失敗)", params["error_description"])
        assertEquals("AuthViewModel.signIn mail=[EMAIL_REDACTED]", params["error_context"])
        assertEquals(params, firebase.logged.single().second)
    }

    // ---- 失敗の握りつぶし（15.9） ----

    @Test
    fun `Crashlyticsへの記録が例外を投げてもerror_occurredは両方へ送られ、呼び出し元に例外が出ず、失敗が報告される`() {
        val failures = FailureLog()
        val facade = DefaultAnalyticsFacade(postHog, firebase, FakeCrashReporter(failing = true), failures.report)

        facade.logError(AppError.Network, "HomeViewModel.fetchPosts")

        assertEquals(listOf("error_occurred"), postHog.captured.map { it.first })
        assertEquals(listOf("error_occurred"), firebase.logged.map { it.first })
        assertEquals(listOf("Crashlytics.recordNonFatal"), failures.entries.map { it.first })
    }

    // ---- Crashlytics に載る例外の位置（15.8） ----

    @Test
    fun `Crashlyticsに載る例外のスタックトレースはlogErrorの呼び出し元から始まる`() {
        val client = FakeCrashlyticsClient()
        val facade = DefaultAnalyticsFacade(postHog, firebase, DefaultCrashReporter(client))

        facade.logError(AppError.Network, "HomeViewModel.fetchPosts")

        val frames = client.recorded.single().throwable.stackTrace
        assertEquals(DefaultAnalyticsFacadeLogErrorTest::class.java.name, frames.first().className)
        assertEquals(mapOf("error_context" to "HomeViewModel.fetchPosts"), client.recorded.single().keys)
    }

    // ---- Crashlytics のユーザー識別（15.5・15.7） ----

    @Test
    fun `setUserIdはCrashlyticsの識別にもuidを渡し、nullと空文字では解除する`() {
        facade.setUserId(Uid("uid-1"))
        facade.setUserId(null)
        facade.setUserId(Uid(""))

        assertEquals(listOf(Uid("uid-1"), null, null), crash.userIds.toList())
    }

    @Test
    fun `Crashlyticsの識別が例外を投げてもFirebaseとPostHogの識別は行われ、失敗が報告される`() {
        val failures = FailureLog()
        val facade = DefaultAnalyticsFacade(postHog, firebase, FakeCrashReporter(failing = true), failures.report)

        facade.setUserId(Uid("uid-1"))
        facade.setUserId(null)

        assertEquals(listOf<String?>("uid-1", null), firebase.userIds)
        assertEquals(listOf("identify:uid-1", "reset"), postHog.calls)
        assertEquals(listOf("Crashlytics.setUserId", "Crashlytics.setUserId"), failures.entries.map { it.first })
    }

    // ---- 投稿の変換の失敗（Crashlytics へは送らない） ----

    @Test
    fun `投稿の変換の失敗はpost_decode_failedとして両方へ送り、Crashlyticsには記録しない`() {
        facade.logPostDecodeFailed(PostDecodeSource.HOME_FEED, "posts/abc123", "userId が無い")

        val expected = mapOf<String, Any>("source" to "home_feed", "path" to "posts/abc123", "error" to "userId が無い")
        assertEquals(listOf("post_decode_failed" to expected), postHog.captured)
        assertEquals(listOf("post_decode_failed" to expected), firebase.logged)
        assertEquals(emptyList(), crash.nonFatals)
    }

    @Test
    fun `投稿の変換の失敗の取得元はiOSと同じ値を使う`() {
        // iOS: FirestoreService.swift（origin/main）:291 home_feed・:393 user_posts・:268 public_posts
        assertEquals(
            listOf("home_feed", "user_posts", "public_posts"),
            PostDecodeSource.entries.map { it.raw },
        )
    }
}
