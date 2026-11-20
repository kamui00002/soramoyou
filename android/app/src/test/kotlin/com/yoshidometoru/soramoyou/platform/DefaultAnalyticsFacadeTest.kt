// ⭐️ 分析イベントの単一の送信窓口（DefaultAnalyticsFacade）の単体テスト（タスク 4.1・要件 15.1・15.5・15.7・15.9）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.contract.Uid
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 送信先（PostHog・Firebase Analytics）を記録用の偽物に差し替え、窓口の判断だけを確かめる。
 *
 * 根拠（読んだ現物。iOS の LoggingService.swift）:
 * - `logEvent`（:118-130）：浄化したパラメータを Firebase と PostHog の両方へ送る
 * - `logScreen`（:47-50）：PostHog の `screen` だけを呼ぶ（Firebase は呼ばない）
 * - `setUserID`（:200-225）：nil か空文字なら未識別。PostHog の `reset()` は「identify 済み → 未識別」の実遷移でだけ呼ぶ
 */
class DefaultAnalyticsFacadeTest {

    // ---- 記録用の偽物 ----

    private class FakePostHog(private val failing: Boolean = false) : PostHogClient {
        val calls = mutableListOf<String>()
        val captured = mutableListOf<Pair<String, Map<String, Any>>>()

        override fun capture(event: String, properties: Map<String, Any>) {
            calls += "capture:$event"
            captured += event to properties
            if (failing) throw IllegalStateException("PostHog の偽物の失敗")
        }

        override fun screen(title: String) {
            calls += "screen:$title"
            if (failing) throw IllegalStateException("PostHog の偽物の失敗")
        }

        override fun identify(distinctId: String) {
            calls += "identify:$distinctId"
            if (failing) throw IllegalStateException("PostHog の偽物の失敗")
        }

        override fun reset() {
            calls += "reset"
            if (failing) throw IllegalStateException("PostHog の偽物の失敗")
        }

        fun count(call: String) = calls.count { it == call }
    }

    private class FakeFirebase(private val failing: Boolean = false) : FirebaseAnalyticsClient {
        val calls = mutableListOf<String>()
        val logged = mutableListOf<Pair<String, Map<String, Any>>>()
        val userIds = mutableListOf<String?>()

        override fun logEvent(name: String, params: Map<String, Any>) {
            calls += "logEvent:$name"
            logged += name to params
            if (failing) throw IllegalStateException("Firebase の偽物の失敗")
        }

        override fun setUserId(id: String?) {
            calls += "setUserId:$id"
            userIds += id
            if (failing) throw IllegalStateException("Firebase の偽物の失敗")
        }
    }

    private class FailureLog {
        val entries = mutableListOf<Pair<String, Exception>>()
        val report: (String, Exception) -> Unit = { where, e -> entries += where to e }
    }

    // ---- logEvent ----

    @Test
    fun `logEventは浄化した同じ値をPostHogとFirebaseの両方へ送る`() {
        val postHog = FakePostHog()
        val firebase = FakeFirebase()
        val facade = DefaultAnalyticsFacade(postHog, firebase, FakeCrashReporter())

        facade.logEvent(
            EventName.ERROR_OCCURRED,
            mapOf(
                "error_category" to ParamValue.S("system_error"),
                "error_description" to ParamValue.S("送信先 a@example.com で失敗"),
                "auth_state" to ParamValue.S("signed_in"),
                "attempt" to ParamValue.L(2L),
                "success" to ParamValue.B(false),
            ),
        )

        assertEquals(
            listOf(
                "error_occurred" to mapOf<String, Any>(
                    "error_category" to "system_error",
                    "error_description" to "送信先 [EMAIL_REDACTED] で失敗",
                    "auth_state" to "[REDACTED]",
                    "attempt" to 2L,
                    "success" to false,
                ),
            ),
            postHog.captured,
        )
        assertEquals(
            listOf(
                "error_occurred" to mapOf<String, Any>(
                    "error_category" to "system_error",
                    "error_description" to "送信先 [EMAIL_REDACTED] で失敗",
                    "auth_state" to "[REDACTED]",
                    "attempt" to 2L,
                    "success" to 0L,
                ),
            ),
            firebase.logged,
        )
    }

    @Test
    fun `logEventはパラメータ無しでも両方へ空のパラメータで送る`() {
        val postHog = FakePostHog()
        val firebase = FakeFirebase()
        DefaultAnalyticsFacade(postHog, firebase, FakeCrashReporter()).logEvent(EventName.POST_COMPLETED)

        assertEquals(listOf("post_completed" to emptyMap<String, Any>()), postHog.captured)
        assertEquals(listOf("post_completed" to emptyMap<String, Any>()), firebase.logged)
    }

    // ---- logScreen ----

    @Test
    fun `logScreenはPostHogにだけ送りFirebaseは呼ばない`() {
        val postHog = FakePostHog()
        val firebase = FakeFirebase()
        DefaultAnalyticsFacade(postHog, firebase, FakeCrashReporter()).logScreen(ScreenName.HOME)

        assertEquals(listOf("screen:ホーム"), postHog.calls)
        assertEquals(emptyList<String>(), firebase.calls)
    }

    // ---- 失敗の握りつぶし（15.9） ----

    @Test
    fun `PostHogが例外を投げてもFirebaseには届き、呼び出し元に例外が出ず、失敗が報告される`() {
        val firebase = FakeFirebase()
        val failures = FailureLog()
        val facade = DefaultAnalyticsFacade(FakePostHog(failing = true), firebase, FakeCrashReporter(), failures.report)

        facade.logEvent(EventName.RETRY_OPERATION, mapOf("attempt" to ParamValue.L(1L)))

        assertEquals(listOf("retry_operation" to mapOf<String, Any>("attempt" to 1L)), firebase.logged)
        assertEquals(1, failures.entries.size)
        assertTrue(failures.entries.single().first.startsWith("PostHog"), "失敗の報告に送信先の名前が無い")
    }

    @Test
    fun `Firebaseが例外を投げてもPostHogには届き、呼び出し元に例外が出ず、失敗が報告される`() {
        val postHog = FakePostHog()
        val failures = FailureLog()
        val facade = DefaultAnalyticsFacade(postHog, FakeFirebase(failing = true), FakeCrashReporter(), failures.report)

        facade.logEvent(EventName.RETRY_OPERATION, mapOf("attempt" to ParamValue.L(1L)))

        assertEquals(listOf("retry_operation" to mapOf<String, Any>("attempt" to 1L)), postHog.captured)
        assertEquals(1, failures.entries.size)
        assertTrue(failures.entries.single().first.startsWith("Firebase"), "失敗の報告に送信先の名前が無い")
    }

    @Test
    fun `両方が例外を投げても呼び出し元に例外が出ず、送信先ごとに1回ずつ報告される`() {
        val failures = FailureLog()
        val facade = DefaultAnalyticsFacade(FakePostHog(failing = true), FakeFirebase(failing = true), FakeCrashReporter(), failures.report)

        facade.logEvent(EventName.POST_DECODE_FAILED, mapOf("source" to ParamValue.S("home_feed")))
        facade.logScreen(ScreenName.EDIT)
        facade.setUserId(Uid("uid-1"))
        facade.setUserId(null)

        // logEvent で 2、logScreen で 1、識別で 2、解除で 2（Firebase の setUserId(null) と PostHog の reset）。
        // 呼ぶ順は iOS と同じく Firebase が先（LoggingService.swift:123→126、:203→210、:216→220）
        assertEquals(7, failures.entries.size)
        assertEquals(
            listOf("Firebase", "PostHog", "PostHog", "Firebase", "PostHog", "Firebase", "PostHog"),
            failures.entries.map { it.first.substringBefore('.') },
        )
    }

    @Test
    fun `失敗の報告にはパラメータの値を含めない`() {
        val failures = FailureLog()
        val facade = DefaultAnalyticsFacade(FakePostHog(failing = true), FakeFirebase(failing = true), FakeCrashReporter(), failures.report)

        facade.logEvent(EventName.POST_DECODE_FAILED, mapOf("path" to ParamValue.S("posts/SECRET-DOC-ID")))

        assertTrue(failures.entries.none { it.first.contains("SECRET-DOC-ID") }, "失敗の報告にパラメータの値が入っている")
    }

    @Test
    fun `失敗の報告の差し込み口を渡さなくても例外は呼び出し元に出ない`() {
        val facade = DefaultAnalyticsFacade(FakePostHog(failing = true), FakeFirebase(failing = true), FakeCrashReporter())

        facade.logEvent(EventName.POST_COMPLETED)
        facade.logScreen(ScreenName.POST)
        facade.setUserId(Uid("uid-1"))
        facade.setUserId(null)
    }

    @Test
    fun `失敗の報告の差し込み口自体が例外を投げても呼び出し元に例外が出ず、もう片方には届く`() {
        // Firebase が先に呼ばれて失敗し、その報告も失敗する。それでも後の PostHog には届く
        val postHog = FakePostHog()
        val facade = DefaultAnalyticsFacade(postHog, FakeFirebase(failing = true), FakeCrashReporter()) { _, _ ->
            throw IllegalStateException("報告の失敗")
        }

        facade.logEvent(EventName.POST_COMPLETED)
        facade.setUserId(Uid("uid-1"))

        assertEquals(listOf("post_completed" to emptyMap<String, Any>()), postHog.captured)
        assertEquals(listOf("capture:post_completed", "identify:uid-1"), postHog.calls)
    }

    // ---- setUserId（15.5・15.7） ----

    @Test
    fun `識別ではuidだけをFirebaseとPostHogに渡す`() {
        val postHog = FakePostHog()
        val firebase = FakeFirebase()
        DefaultAnalyticsFacade(postHog, firebase, FakeCrashReporter()).setUserId(Uid("uid-1"))

        assertEquals(listOf<String?>("uid-1"), firebase.userIds)
        assertEquals(listOf("identify:uid-1"), postHog.calls)
    }

    @Test
    fun `初期状態でnullを渡してもPostHogはresetされずFirebaseの識別は解除される`() {
        val postHog = FakePostHog()
        val firebase = FakeFirebase()
        DefaultAnalyticsFacade(postHog, firebase, FakeCrashReporter()).setUserId(null)

        assertEquals(0, postHog.count("reset"))
        assertEquals(listOf<String?>(null), firebase.userIds)
    }

    @Test
    fun `識別済みからnullへ変わるときだけresetが1回呼ばれ、続けてnullを渡してもresetされない`() {
        val postHog = FakePostHog()
        val firebase = FakeFirebase()
        val facade = DefaultAnalyticsFacade(postHog, firebase, FakeCrashReporter())

        facade.setUserId(Uid("uid-1"))
        facade.setUserId(null)
        assertEquals(1, postHog.count("reset"))

        facade.setUserId(null)
        assertEquals(1, postHog.count("reset"))
        // Firebase の解除は毎回呼ぶ（iOS :203 と同じ）
        assertEquals(listOf<String?>("uid-1", null, null), firebase.userIds)
    }

    @Test
    fun `空文字のuidは未識別として扱う`() {
        val postHog = FakePostHog()
        val firebase = FakeFirebase()
        val facade = DefaultAnalyticsFacade(postHog, firebase, FakeCrashReporter())

        facade.setUserId(Uid(""))
        assertTrue(postHog.calls.none { it.startsWith("identify") }, "空文字で identify された")
        assertEquals(0, postHog.count("reset"))
        assertEquals(listOf<String?>(null), firebase.userIds)

        facade.setUserId(Uid("uid-1"))
        facade.setUserId(Uid(""))
        assertEquals(1, postHog.count("reset"))
        assertEquals(listOf<String?>(null, "uid-1", null), firebase.userIds)
    }

    @Test
    fun `別のuidへ切り替えるときはresetせずidentifyし直す`() {
        val postHog = FakePostHog()
        val facade = DefaultAnalyticsFacade(postHog, FakeFirebase(), FakeCrashReporter())

        facade.setUserId(Uid("uid-1"))
        facade.setUserId(Uid("uid-2"))

        assertEquals(listOf("identify:uid-1", "identify:uid-2"), postHog.calls)
    }

    @Test
    fun `identifyが例外を投げても識別済みとして扱い、後のnullでresetされる`() {
        // 後のログアウトで reset が確実に走る方を優先する（identify が途中まで効いていた場合に匿名へ戻せるように）
        val throwingOnIdentify = object : PostHogClient {
            var resets = 0
            override fun capture(event: String, properties: Map<String, Any>) = Unit
            override fun screen(title: String) = Unit
            override fun identify(distinctId: String) {
                throw IllegalStateException("identify の失敗")
            }
            override fun reset() {
                resets++
            }
        }
        val facade = DefaultAnalyticsFacade(throwingOnIdentify, FakeFirebase(), FakeCrashReporter())

        facade.setUserId(Uid("uid-1"))
        facade.setUserId(null)

        assertEquals(1, throwingOnIdentify.resets)
    }

    @Test
    fun `resetが例外を投げても未識別として扱い、続けてnullを渡してもresetし直さない`() {
        // iOS は reset() の後で無条件に lastIdentifiedUserID = nil にする（:209-212）。それに揃える。
        // reset を繰り返すと distinct_id が作り直され、同じ人が別人として数えられる（iOS :206-208 の注記）
        val throwingOnReset = object : PostHogClient {
            var resets = 0
            override fun capture(event: String, properties: Map<String, Any>) = Unit
            override fun screen(title: String) = Unit
            override fun identify(distinctId: String) = Unit
            override fun reset() {
                resets++
                throw IllegalStateException("reset の失敗")
            }
        }
        val facade = DefaultAnalyticsFacade(throwingOnReset, FakeFirebase(), FakeCrashReporter())

        facade.setUserId(Uid("uid-1"))
        facade.setUserId(null)
        facade.setUserId(null)

        assertEquals(1, throwingOnReset.resets)
    }

    @Test
    fun `別スレッドから同時にnullが来ても識別済みから未識別への遷移は1回でresetも1回だけ`() {
        // 認証の監視は別スレッドから来うる。reset を遅くして「判定と更新の間」を広げ、判定と更新が原子的でなければ
        // 複数のスレッドが「識別済み」を読んで reset を重ねて呼ぶようにしてある
        // （@Synchronized を外すと reset が複数回呼ばれて落ちることを 2026-10-03 に確かめた。そのときの実測は 8 回）
        val slowReset = object : PostHogClient {
            val resets = AtomicInteger(0)
            override fun capture(event: String, properties: Map<String, Any>) = Unit
            override fun screen(title: String) = Unit
            override fun identify(distinctId: String) = Unit
            override fun reset() {
                Thread.sleep(50)
                resets.incrementAndGet()
            }
        }
        val facade = DefaultAnalyticsFacade(slowReset, FakeFirebaseThreadSafe(), FakeCrashReporter())
        facade.setUserId(Uid("uid-1"))

        val start = CountDownLatch(1)
        val threads = List(8) { Thread { start.await(); facade.setUserId(null) } }
        threads.forEach { it.start() }
        start.countDown()
        threads.forEach { it.join() }

        assertEquals(1, slowReset.resets.get())
    }

    /** 別スレッドから呼ばれても壊れない、何も記録しない Firebase の偽物。 */
    private class FakeFirebaseThreadSafe : FirebaseAnalyticsClient {
        override fun logEvent(name: String, params: Map<String, Any>) = Unit
        override fun setUserId(id: String?) = Unit
    }
}
