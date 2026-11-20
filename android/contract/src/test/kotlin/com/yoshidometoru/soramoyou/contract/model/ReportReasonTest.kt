// ⭐️ 通報理由の文字列値と表示名を iOS 版に固定する単体テスト（タスク 28・要件 11.2・11.3）
package com.yoshidometoru.soramoyou.contract.model

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * 通報理由の文字列値は Firestore の `reports.reason` にそのまま書かれ、表示名は選択肢にそのまま出る。
 * iOS 版と 1 文字でも違うと、運営が通報を見るときに OS ごとに違う値が混ざる（要件 11.3）。そのため値は、
 * 実装の定数を参照せず、このテストへ iOS の値を直に書いて固定する。
 *
 * 根拠（読んだ現物）:
 * - Soramoyou/Soramoyou/Models/ReportReason.swift:11-16（文字列値 `inappropriate`・`spam`・`harassment`・`copyright`・`other`。並び順もここ）
 * - 同 :19-32（表示名 不適切なコンテンツ・スパム・迷惑行為・嫌がらせ・誹謗中傷・著作権侵害・その他）
 */
class ReportReasonTest {

    @Test
    fun `通報理由は5種類だけである`() {
        // iOS の ReportReason も 5 ケースだけ（ReportReason.swift:11-16）。増減したらここで気づく
        assertEquals(5, ReportReason.entries.size)
    }

    @Test
    fun `並び順はiOSと同じである`() {
        assertEquals(
            listOf(
                ReportReason.INAPPROPRIATE,
                ReportReason.SPAM,
                ReportReason.HARASSMENT,
                ReportReason.COPYRIGHT,
                ReportReason.OTHER,
            ),
            ReportReason.entries,
        )
    }

    @Test
    fun `rawと表示名の全組がiOSと一致する`() {
        // iOS の値を直書きする（ReportReason.swift:12-16 と :21-30）
        assertEquals("inappropriate", ReportReason.INAPPROPRIATE.raw)
        assertEquals("不適切なコンテンツ", ReportReason.INAPPROPRIATE.displayName)

        assertEquals("spam", ReportReason.SPAM.raw)
        assertEquals("スパム・迷惑行為", ReportReason.SPAM.displayName)

        assertEquals("harassment", ReportReason.HARASSMENT.raw)
        assertEquals("嫌がらせ・誹謗中傷", ReportReason.HARASSMENT.displayName)

        assertEquals("copyright", ReportReason.COPYRIGHT.raw)
        assertEquals("著作権侵害", ReportReason.COPYRIGHT.displayName)

        assertEquals("other", ReportReason.OTHER.raw)
        assertEquals("その他", ReportReason.OTHER.displayName)
    }

    @Test
    fun `rawの並びと表示名の並びが並び順どおりである`() {
        assertEquals(
            listOf("inappropriate", "spam", "harassment", "copyright", "other"),
            ReportReason.entries.map { it.raw },
        )
        assertEquals(
            listOf("不適切なコンテンツ", "スパム・迷惑行為", "嫌がらせ・誹謗中傷", "著作権侵害", "その他"),
            ReportReason.entries.map { it.displayName },
        )
    }

    @Test
    fun `rawは全ケースで重複しない`() {
        // 契約の OneOf はこの raw の集合で判定する。重複があると、別の理由が同じ値で書かれてしまう
        assertEquals(ReportReason.entries.size, ReportReason.entries.map { it.raw }.toSet().size)
    }
}
