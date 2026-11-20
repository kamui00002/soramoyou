// ⭐️ エラーの分類の文字列を iOS 版に固定する単体テスト（タスク 3.1・要件 15.2）
package com.yoshidometoru.soramoyou.contract

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * 分類の文字列は、分析イベント `error_occurred` のパラメータ `error_category` にそのまま載る。
 * iOS 版と 1 文字でも違うと、PostHog 上で両 OS を同じ物差しで並べられなくなる。
 *
 * 根拠（読んだ現物）:
 * - Soramoyou/Soramoyou/Services/LoggingService.swift:308-318（`ErrorCategory.rawValue`）
 * - Soramoyou/Soramoyou/Services/LoggingService.swift:140（`"error_category": category.rawValue`）
 */
class ErrorCategoryTest {

    @Test
    fun `ユーザー起因の分類はuser_errorである`() {
        assertEquals("user_error", ErrorCategory.USER.raw)
    }

    @Test
    fun `システム起因の分類はsystem_errorである`() {
        assertEquals("system_error", ErrorCategory.SYSTEM.raw)
    }

    @Test
    fun `業務規則の違反の分類はbusiness_errorである`() {
        assertEquals("business_error", ErrorCategory.BUSINESS.raw)
    }

    @Test
    fun `分類は3種類だけで文字列は重複しない`() {
        // iOS の ErrorCategory も 3 ケースだけ（ErrorHandler.swift:11-16）。増減したらここで気づく
        assertEquals(3, ErrorCategory.entries.size)
        assertEquals(3, ErrorCategory.entries.map { it.raw }.toSet().size)
    }
}
