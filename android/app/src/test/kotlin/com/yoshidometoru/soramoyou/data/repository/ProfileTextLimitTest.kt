// ⭐️ 表示名・自己紹介の上限で保存を止めるかの判断の単体テスト（要件 10.10・全体レビュー 4 回目 R21）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * [exceedsProfileTextLimit] が、変えた値（[profileTextChangeOf] が Set と決めた値）だけを上限で見て、
 * 古い端末（`enforce = false`）では変えた値でも止めないことを確かめる（利用者の決定・2026-11-08）。
 *
 * 古い端末の道は、本番では既定の値（[TextLimits.isLegacyGraphemeBreaking]）でしか通らない。開発機の JDK 20 以上では既定が「止める」側に
 * なるので、ここで `enforce = false` を渡して写す（既定の値が端末の版どおりに決まることは、端末テスト TextLimitsDeviceTest が見る）。
 */
class ProfileTextLimitTest {

    private val longName = "あ".repeat(TextLimits.DISPLAY_NAME_MAX + 1)
    private val longBio = "い".repeat(TextLimits.BIO_MAX + 1)

    @Test
    fun `変えた値が上限を超えていれば止める`() {
        assertTrue(exceedsProfileTextLimit(longName, "そら", TextLimits::isDisplayNameWithinLimit, enforce = true))
        assertTrue(exceedsProfileTextLimit(longBio, null, TextLimits::isBioWithinLimit, enforce = true))
    }

    @Test
    fun `変えた値が上限ちょうどなら止めない`() {
        val fifty = "あ".repeat(TextLimits.DISPLAY_NAME_MAX)

        assertFalse(exceedsProfileTextLimit(fifty, "そら", TextLimits::isDisplayNameWithinLimit, enforce = true))
    }

    @Test
    fun `いまの値から変えていなければ上限を超えていても止めない`() {
        assertFalse(exceedsProfileTextLimit(longName, longName, TextLimits::isDisplayNameWithinLimit, enforce = true))
        assertFalse(exceedsProfileTextLimit(longBio, longBio, TextLimits::isBioWithinLimit, enforce = true))
    }

    @Test
    fun `空や空白だけにして消すのは止めない`() {
        assertFalse(exceedsProfileTextLimit("", longName, TextLimits::isDisplayNameWithinLimit, enforce = true))
        // 上限より長い空白だけの値も、保存では「消す」になるので数えない
        assertFalse(exceedsProfileTextLimit("　".repeat(TextLimits.DISPLAY_NAME_MAX + 1), "そら", TextLimits::isDisplayNameWithinLimit, enforce = true))
    }

    @Test
    fun `古い端末を写すと変えた値が上限を超えていても止めない`() {
        assertFalse(exceedsProfileTextLimit(longName, "そら", TextLimits::isDisplayNameWithinLimit, enforce = false))
        assertFalse(exceedsProfileTextLimit(longBio, null, TextLimits::isBioWithinLimit, enforce = false))
    }

    @Test
    fun `開発機の数え方では既定で止める側になる`() {
        // 開発機の JDK 20 以上は古い規則でない（TextLimitsTest）。既定の値で古い端末の道に入っていないことを確かめる
        assertFalse(TextLimits.isLegacyGraphemeBreaking)
        assertTrue(exceedsProfileTextLimit(longName, "そら", TextLimits::isDisplayNameWithinLimit))
    }
}
