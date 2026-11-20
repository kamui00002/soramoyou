// ⭐️ 処理結果の型の単体テスト（タスク 3.1）
package com.yoshidometoru.soramoyou.contract

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

class AppResultTest {

    @Test
    fun `成功は同じ値なら等しい`() {
        assertEquals(AppResult.Ok(1), AppResult.Ok(1))
        assertNotEquals(AppResult.Ok(1), AppResult.Ok(2))
    }

    @Test
    fun `失敗は同じエラーなら等しい`() {
        assertEquals(AppResult.Err(AppError.NotFound), AppResult.Err(AppError.NotFound))
        assertNotEquals(AppResult.Err(AppError.NotFound), AppResult.Err(AppError.Network))
    }

    @Test
    fun `成功と失敗は等しくならない`() {
        val ok: AppResult<Int> = AppResult.Ok(1)
        val err: AppResult<Int> = AppResult.Err(AppError.Unknown("x"))
        assertNotEquals(ok, err)
    }

    @Test
    fun `失敗はどの成功の型の結果としても扱える`() {
        // AppResult<out T> が共変で、Err が AppResult<Nothing> であることの確認（コンパイルが通ること自体が検証）
        val asInt: AppResult<Int> = AppResult.Err(AppError.Network)
        val asString: AppResult<String> = AppResult.Err(AppError.Network)
        assertEquals(describe(asInt), describe(asString))
    }

    @Test
    fun `成功と失敗を網羅したwhenで分岐できる`() {
        assertEquals("ok:7", describe(AppResult.Ok(7)))
        assertEquals("err:system_error", describe(AppResult.Err(AppError.Network)))
    }

    // sealed なので else なしの when が成立する（分岐の漏れがコンパイルエラーになる）
    private fun <T> describe(result: AppResult<T>): String = when (result) {
        is AppResult.Ok -> "ok:${result.value}"
        is AppResult.Err -> "err:${result.error.category.raw}"
    }
}
