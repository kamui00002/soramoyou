// ⭐️ 非致命エラーを Crashlytics に記録する窓口（DefaultCrashReporter）の単体テスト（タスク 4.2・要件 15.8・15.9）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.Uid
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Crashlytics の SDK を記録用の偽物（[FakeCrashlyticsClient]）に差し替え、SDK に渡る中身だけを確かめる。
 *
 * 根拠（読んだ現物。iOS の LoggingService.swift）:
 * - `recordError`（:55-73）・`recordNonFatalError`（:76-95）：発生箇所を浄化し（:57・:78）、
 *   カスタムキー `error_context` に載せる（:63-65・:85-87）
 * - `setUserID`（:200-225）：nil か空文字なら Crashlytics の識別を解除し（:204）、そうでなければ uid を渡す（:217）
 *
 * Crashlytics（Android）の識別の解除は、空文字を渡すことで行う（公式文書「ユーザー ID を設定する」）。
 */
class DefaultCrashReporterTest {

    private class FailureLog {
        val entries = mutableListOf<Pair<String, Exception>>()
        val report: (String, Exception) -> Unit = { where, e -> entries += where to e }
    }

    // ---- recordNonFatal ----

    @Test
    fun `非致命エラーを、説明を本文にした例外とerror_contextのキーで記録する`() {
        val client = FakeCrashlyticsClient()
        DefaultCrashReporter(client).recordNonFatal(AppError.Network, "HomeViewModel.load")

        val recorded = client.recorded.single()
        assertIs<NonFatalAppError>(recorded.throwable)
        assertEquals("Network", recorded.throwable.message)
        assertEquals(mapOf("error_context" to "HomeViewModel.load"), recorded.keys)
    }

    @Test
    fun `extraのキーも同じイベントに載せ、error_contextはextraの同名のキーで上書きされない`() {
        val client = FakeCrashlyticsClient()
        DefaultCrashReporter(client).recordNonFatal(
            AppError.Network,
            "HomeViewModel.load",
            extra = mapOf("shape_violations" to "missing:likesCount", "error_context" to "偽の発生箇所"),
        )

        assertEquals(
            mapOf("shape_violations" to "missing:likesCount", "error_context" to "HomeViewModel.load"),
            client.recorded.single().keys,
        )
    }

    @Test
    fun `発生箇所・説明・extraの値は浄化してから載せる`() {
        // iOS は発生箇所を浄化してからカスタムキーに載せる（LoggingService.swift:57・:63-65）。
        // 例外の本文と extra は Android で自分で組み立てる文字列なので、同じ規則で浄化する
        val client = FakeCrashlyticsClient()
        DefaultCrashReporter(client).recordNonFatal(
            // password=… の直後に空白を置く（iOS の規則は空白までを伏せるので、直後が「)」だと括弧ごと伏せられる）
            AppError.Unknown("送信先 a@example.com で password=hunter2 で失敗"),
            "AuthViewModel.signIn mail=b@example.com",
            extra = mapOf("detail" to "token: abc123"),
        )

        val recorded = client.recorded.single()
        assertEquals("Unknown(送信先 [EMAIL_REDACTED] で [PASSWORD_REDACTED] で失敗)", recorded.throwable.message)
        assertEquals("AuthViewModel.signIn mail=[EMAIL_REDACTED]", recorded.keys["error_context"])
        assertEquals("[TOKEN_REDACTED]", recorded.keys["detail"])
    }

    @Test
    fun `例外のスタックトレースは呼び出し元から始まり、記録の仕組みの中のフレームを含まない`() {
        // Crashlytics はスタックトレースで issue をまとめる。記録の仕組みの中で例外を作ったままだと、
        // 全ての非致命エラーの先頭のフレームが同じになり、1 つの issue に潰れてしまう
        val client = FakeCrashlyticsClient()
        DefaultCrashReporter(client).recordNonFatal(AppError.Network, "HomeViewModel.load")

        val frames = client.recorded.single().throwable.stackTrace
        assertEquals(DefaultCrashReporterTest::class.java.name, frames.first().className)
        // このテストのクラス名も DefaultCrashReporter で始まるので、前方一致ではなく完全一致（と内部クラスの $）で見る
        val reporter = DefaultCrashReporter::class.java.name
        assertTrue(
            frames.none { it.className == reporter || it.className.startsWith("$reporter\$") },
            "記録の仕組みの中のフレームが残っている: ${frames.take(3)}",
        )
    }

    // ---- 失敗の握りつぶし（15.9） ----

    @Test
    fun `記録が例外を投げても呼び出し元に例外が出ず、失敗が報告される`() {
        val failures = FailureLog()
        DefaultCrashReporter(FakeCrashlyticsClient(failing = true), failures.report)
            .recordNonFatal(AppError.Network, "HomeViewModel.load")

        assertEquals(listOf("Crashlytics.recordException"), failures.entries.map { it.first })
    }

    @Test
    fun `失敗の報告の差し込み口自体が例外を投げても呼び出し元に例外が出ない`() {
        val reporter = DefaultCrashReporter(FakeCrashlyticsClient(failing = true)) { _, _ ->
            throw IllegalStateException("報告の失敗")
        }

        reporter.recordNonFatal(AppError.Network, "HomeViewModel.load")
        reporter.setUserId(Uid("uid-1"))
    }

    // ---- setUserId ----

    @Test
    fun `setUserIdはuidを渡し、nullと空文字は空文字を渡して識別を解除する`() {
        val client = FakeCrashlyticsClient()
        val reporter = DefaultCrashReporter(client)

        reporter.setUserId(Uid("uid-1"))
        reporter.setUserId(null)
        reporter.setUserId(Uid(""))

        assertEquals(listOf("uid-1", "", ""), client.userIds)
    }

    @Test
    fun `setUserIdが例外を投げても呼び出し元に例外が出ず、失敗が報告される`() {
        val failures = FailureLog()
        DefaultCrashReporter(FakeCrashlyticsClient(failing = true), failures.report).setUserId(Uid("uid-1"))

        assertEquals(listOf("Crashlytics.setUserId"), failures.entries.map { it.first })
    }
}
