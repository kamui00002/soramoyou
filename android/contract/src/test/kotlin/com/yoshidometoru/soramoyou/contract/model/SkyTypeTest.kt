// ⭐️ 空の種類の文字列値と表示名を iOS 版に固定する単体テスト（タスク 3.2・要件 4.11・5.4・7.13・16.1）
package com.yoshidometoru.soramoyou.contract.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * 空の種類の文字列値は Firestore の `skyType` にそのまま書かれ、表示名は投稿詳細にそのまま出る（要件 5.4）。
 * iOS 版と 1 文字でも違うと、OS をまたいで読み違える・言葉が揃わない。そのため値は、実装の定数を参照せず
 * このテストへ iOS の値を直に書いて固定する。
 *
 * 根拠（読んだ現物）:
 * - Soramoyou/Soramoyou/Models/SkyType.swift:12-16（文字列値 `clear`・`cloudy`・`sunset`・`sunrise`・`storm`。並び順もここ）
 * - Soramoyou/Soramoyou/Models/SkyType.swift:19-27（表示名 晴れ・曇り・夕焼け・朝焼け・嵐）
 */
class SkyTypeTest {

    @Test
    fun `空の種類は5種類だけである`() {
        // iOS の SkyType も 5 ケースだけ（SkyType.swift:12-16）。増減したらここで気づく
        assertEquals(5, SkyType.entries.size)
    }

    @Test
    fun `並び順はiOSと同じ晴れ_曇り_夕焼け_朝焼け_嵐である`() {
        assertEquals(
            listOf(SkyType.CLEAR, SkyType.CLOUDY, SkyType.SUNSET, SkyType.SUNRISE, SkyType.STORM),
            SkyType.entries,
        )
    }

    @Test
    fun `rawと表示名の全組がiOSと一致する`() {
        // iOS の値を直書きする（SkyType.swift:12-16 と :21-25）
        assertEquals("clear", SkyType.CLEAR.raw)
        assertEquals("晴れ", SkyType.CLEAR.displayName)

        assertEquals("cloudy", SkyType.CLOUDY.raw)
        assertEquals("曇り", SkyType.CLOUDY.displayName)

        assertEquals("sunset", SkyType.SUNSET.raw)
        assertEquals("夕焼け", SkyType.SUNSET.displayName)

        assertEquals("sunrise", SkyType.SUNRISE.raw)
        assertEquals("朝焼け", SkyType.SUNRISE.displayName)

        assertEquals("storm", SkyType.STORM.raw)
        assertEquals("嵐", SkyType.STORM.displayName)
    }

    @Test
    fun `rawの並びと表示名の並びが並び順どおりである`() {
        assertEquals(listOf("clear", "cloudy", "sunset", "sunrise", "storm"), SkyType.entries.map { it.raw })
        assertEquals(listOf("晴れ", "曇り", "夕焼け", "朝焼け", "嵐"), SkyType.entries.map { it.displayName })
    }

    @Test
    fun `全ケースでfromRawに自分のrawを渡すと自分が返る`() {
        SkyType.entries.forEach { case ->
            assertEquals(case, SkyType.fromRaw(case.raw), "往復できない: ${case.name}")
        }
    }

    @Test
    fun `未知の文字列と空文字とnullはnullになり例外を投げない`() {
        // 未知の列挙値は失敗ではなく「値なし」（要件 4.11・設計書の未知の列挙値の扱い）
        assertNull(SkyType.fromRaw("unknown"))
        assertNull(SkyType.fromRaw(""))
        assertNull(SkyType.fromRaw(null))
    }

    @Test
    fun `大文字小文字を区別する`() {
        // Swift の `init(rawValue:)` は完全一致。"Clear" や列挙子名の "CLEAR" は別の値として null にする。
        // "sunRise" のように 1 文字だけ大文字が混ざった綴りも、別の値として null にする
        assertNull(SkyType.fromRaw("Clear"))
        assertNull(SkyType.fromRaw("CLEAR"))
        assertNull(SkyType.fromRaw("Cloudy"))
        assertNull(SkyType.fromRaw("SUNSET"))
        assertNull(SkyType.fromRaw("sunRise"))
        assertNull(SkyType.fromRaw("Storm"))
    }

    @Test
    fun `前後に空白があるとnullになる`() {
        // 空白の除去はしない（Swift の `init(rawValue:)` と同じ）
        assertNull(SkyType.fromRaw(" clear"))
        assertNull(SkyType.fromRaw("clear "))
        assertNull(SkyType.fromRaw("clear\n"))
    }

    @Test
    fun `表示名はrawとして受け付けない`() {
        // 表示名は画面用で、Firestore に書く値ではない。取り違えて読み込まないことを固定する
        SkyType.entries.forEach { case ->
            assertNull(SkyType.fromRaw(case.displayName), "表示名を raw として受け付けた: ${case.displayName}")
        }
    }

    @Test
    fun `rawは重複しない`() {
        assertEquals(SkyType.entries.size, SkyType.entries.map { it.raw }.toSet().size)
    }

    @Test
    fun `表示名は重複しない`() {
        assertEquals(SkyType.entries.size, SkyType.entries.map { it.displayName }.toSet().size)
    }
}
