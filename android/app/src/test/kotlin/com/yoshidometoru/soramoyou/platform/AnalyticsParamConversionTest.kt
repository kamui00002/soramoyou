// ⭐️ パラメータの値を送信先ごとの型に変換する単体テスト（タスク 4.1・要件 15.2）
package com.yoshidometoru.soramoyou.platform

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Firebase Analytics（Android）の Bundle に載せられる値は、公式には String・long・double である。
 * そのため真偽値は 1／0 の Long にして送る。iOS は Swift の Bool が NSNumber として渡るため、
 * 数値で記録されているはず（要確認：11.3 で GA4 の実データを見て確かめる）。
 * PostHog へは iOS と同じく真偽値のまま送る（iOS の Bool は JSON の true/false になる）。
 */
class AnalyticsParamConversionTest {

    @Test
    fun `Firebaseへは真偽値を1と0のLongにする`() {
        assertEquals(1L, ParamValue.B(true).toFirebaseValue())
        assertEquals(0L, ParamValue.B(false).toFirebaseValue())
    }

    @Test
    fun `Firebaseへは文字列と整数と小数をそのままの型で渡す`() {
        assertEquals("public", ParamValue.S("public").toFirebaseValue())
        assertEquals(3L, ParamValue.L(3L).toFirebaseValue())
        assertEquals(0.25, ParamValue.D(0.25).toFirebaseValue())
    }

    @Test
    fun `PostHogへは4種類ともそのままの型で渡す`() {
        assertEquals("public", ParamValue.S("public").toPostHogValue())
        assertEquals(3L, ParamValue.L(3L).toPostHogValue())
        assertEquals(true, ParamValue.B(true).toPostHogValue())
        assertEquals(false, ParamValue.B(false).toPostHogValue())
        assertEquals(0.25, ParamValue.D(0.25).toPostHogValue())
    }
}
