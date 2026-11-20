// ⭐️ 時間帯の文字列値と表示名を iOS 版に固定する単体テスト（タスク 3.2・要件 4.11・5.4・7.13・16.1）
package com.yoshidometoru.soramoyou.contract.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * 時間帯の文字列値は Firestore の `timeOfDay` にそのまま書かれ、表示名は投稿詳細にそのまま出る（要件 5.4）。
 * iOS 版と 1 文字でも違うと、OS をまたいで読み違える・言葉が揃わない。そのため値は、実装の定数を参照せず
 * このテストへ iOS の値を直に書いて固定する。
 *
 * 根拠（読んだ現物）:
 * - Soramoyou/Soramoyou/Models/TimeOfDay.swift:12-15（文字列値 `morning`・`afternoon`・`evening`・`night`。並び順もここ）
 * - Soramoyou/Soramoyou/Models/TimeOfDay.swift:18-25（表示名 朝・昼・夕方・夜）
 *
 * 時刻から時間帯を決める規則（iOS の `TimeOfDay.from(date:)`、同 :38-51）は、この enum の担当ではない
 * （タスク 20.2 の rules/TimeOfDayResolver）。ここでは値と表示名だけを固定する。
 */
class TimeOfDayTest {

    @Test
    fun `時間帯は4種類だけである`() {
        // iOS の TimeOfDay も 4 ケースだけ（TimeOfDay.swift:12-15）。増減したらここで気づく
        assertEquals(4, TimeOfDay.entries.size)
    }

    @Test
    fun `並び順はiOSと同じ朝_昼_夕方_夜である`() {
        assertEquals(
            listOf(TimeOfDay.MORNING, TimeOfDay.AFTERNOON, TimeOfDay.EVENING, TimeOfDay.NIGHT),
            TimeOfDay.entries,
        )
    }

    @Test
    fun `rawと表示名の全組がiOSと一致する`() {
        // iOS の値を直書きする（TimeOfDay.swift:12-15 と :20-23）
        assertEquals("morning", TimeOfDay.MORNING.raw)
        assertEquals("朝", TimeOfDay.MORNING.displayName)

        assertEquals("afternoon", TimeOfDay.AFTERNOON.raw)
        assertEquals("昼", TimeOfDay.AFTERNOON.displayName)

        assertEquals("evening", TimeOfDay.EVENING.raw)
        assertEquals("夕方", TimeOfDay.EVENING.displayName)

        assertEquals("night", TimeOfDay.NIGHT.raw)
        assertEquals("夜", TimeOfDay.NIGHT.displayName)
    }

    @Test
    fun `rawの並びと表示名の並びが並び順どおりである`() {
        assertEquals(listOf("morning", "afternoon", "evening", "night"), TimeOfDay.entries.map { it.raw })
        assertEquals(listOf("朝", "昼", "夕方", "夜"), TimeOfDay.entries.map { it.displayName })
    }

    @Test
    fun `全ケースでfromRawに自分のrawを渡すと自分が返る`() {
        TimeOfDay.entries.forEach { case ->
            assertEquals(case, TimeOfDay.fromRaw(case.raw), "往復できない: ${case.name}")
        }
    }

    @Test
    fun `未知の文字列と空文字とnullはnullになり例外を投げない`() {
        // 未知の列挙値は失敗ではなく「値なし」（要件 4.11・設計書の未知の列挙値の扱い）
        assertNull(TimeOfDay.fromRaw("unknown"))
        assertNull(TimeOfDay.fromRaw(""))
        assertNull(TimeOfDay.fromRaw(null))
    }

    @Test
    fun `大文字小文字を区別する`() {
        // Swift の `init(rawValue:)` は完全一致。"Morning" や列挙子名の "MORNING" は別の値として null にする
        assertNull(TimeOfDay.fromRaw("Morning"))
        assertNull(TimeOfDay.fromRaw("MORNING"))
        assertNull(TimeOfDay.fromRaw("Afternoon"))
        assertNull(TimeOfDay.fromRaw("EVENING"))
        assertNull(TimeOfDay.fromRaw("Night"))
    }

    @Test
    fun `前後に空白があるとnullになる`() {
        // 空白の除去はしない（Swift の `init(rawValue:)` と同じ）
        assertNull(TimeOfDay.fromRaw(" morning"))
        assertNull(TimeOfDay.fromRaw("morning "))
        assertNull(TimeOfDay.fromRaw("morning\n"))
    }

    @Test
    fun `表示名はrawとして受け付けない`() {
        // 表示名は画面用で、Firestore に書く値ではない。取り違えて読み込まないことを固定する
        TimeOfDay.entries.forEach { case ->
            assertNull(TimeOfDay.fromRaw(case.displayName), "表示名を raw として受け付けた: ${case.displayName}")
        }
    }

    @Test
    fun `rawは重複しない`() {
        assertEquals(TimeOfDay.entries.size, TimeOfDay.entries.map { it.raw }.toSet().size)
    }

    @Test
    fun `表示名は重複しない`() {
        assertEquals(TimeOfDay.entries.size, TimeOfDay.entries.map { it.displayName }.toSet().size)
    }
}
