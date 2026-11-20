// ⭐️ フィードバックの種別の文字列値と表示名を iOS 版に固定する単体テスト（タスク 28・要件 13.2）
package com.yoshidometoru.soramoyou.contract.model

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * 種別の文字列値は Firestore の `feedback.category` にそのまま書かれ、表示名は選択肢にそのまま出る。
 * iOS 版と 1 文字でも違うと、運営が集計するときに OS ごとに違う種別が混ざる。そのため値は、
 * 実装の定数を参照せず、このテストへ iOS の値を直に書いて固定する。
 *
 * 根拠（読んだ現物）:
 * - Soramoyou/Soramoyou/Models/Feedback.swift:14-18（文字列値 `bug`・`request`・`other`。並び順もここ）
 * - 同 :21-28（表示名 不具合・要望・その他）
 */
class FeedbackCategoryTest {

    @Test
    fun `種別は3種類だけである`() {
        // iOS の FeedbackCategory も 3 ケースだけ（Feedback.swift:14-18）。増減したらここで気づく
        assertEquals(3, FeedbackCategory.entries.size)
    }

    @Test
    fun `並び順はiOSと同じ不具合_要望_その他である`() {
        assertEquals(
            listOf(FeedbackCategory.BUG, FeedbackCategory.REQUEST, FeedbackCategory.OTHER),
            FeedbackCategory.entries,
        )
    }

    @Test
    fun `rawと表示名の全組がiOSと一致する`() {
        // iOS の値を直書きする（Feedback.swift:15-17 と :23-26）
        assertEquals("bug", FeedbackCategory.BUG.raw)
        assertEquals("不具合", FeedbackCategory.BUG.displayName)

        assertEquals("request", FeedbackCategory.REQUEST.raw)
        assertEquals("要望", FeedbackCategory.REQUEST.displayName)

        assertEquals("other", FeedbackCategory.OTHER.raw)
        assertEquals("その他", FeedbackCategory.OTHER.displayName)
    }

    @Test
    fun `rawの並びと表示名の並びが並び順どおりである`() {
        assertEquals(listOf("bug", "request", "other"), FeedbackCategory.entries.map { it.raw })
        assertEquals(listOf("不具合", "要望", "その他"), FeedbackCategory.entries.map { it.displayName })
    }
}
