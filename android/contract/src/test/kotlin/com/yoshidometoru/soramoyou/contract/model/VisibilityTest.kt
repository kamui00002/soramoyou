// ⭐️ 公開範囲の文字列値と表示名を iOS 版に固定する単体テスト（タスク 3.2・要件 4.11・7.13・16.1）
package com.yoshidometoru.soramoyou.contract.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * 公開範囲の文字列値は Firestore の `visibility` にそのまま書かれ、表示名は画面にそのまま出る。
 * iOS 版と 1 文字でも違うと、片方の OS で書いた投稿をもう片方が読み違える（要件 7.13）、
 * または同じ公開範囲が OS ごとに違う言葉で見える（要件 16.1）。そのため値は、実装の定数を参照せず
 * このテストへ iOS の値を直に書いて固定する。
 *
 * 根拠（読んだ現物）:
 * - Soramoyou/Soramoyou/Models/Visibility.swift:12-14（文字列値 `public`・`followers`・`private`。並び順もここ）
 * - Soramoyou/Soramoyou/Models/Visibility.swift:17-23（表示名 公開・フォロワーのみ・非公開）
 */
class VisibilityTest {

    @Test
    fun `公開範囲は3種類だけである`() {
        // iOS の Visibility も 3 ケースだけ（Visibility.swift:12-14）。増減したらここで気づく
        assertEquals(3, Visibility.entries.size)
    }

    @Test
    fun `並び順はiOSと同じ公開_フォロワー_非公開である`() {
        assertEquals(
            listOf(Visibility.PUBLIC, Visibility.FOLLOWERS, Visibility.PRIVATE),
            Visibility.entries,
        )
    }

    @Test
    fun `rawと表示名の全組がiOSと一致する`() {
        // iOS の値を直書きする（Visibility.swift:12-14 と :19-21）
        assertEquals("public", Visibility.PUBLIC.raw)
        assertEquals("公開", Visibility.PUBLIC.displayName)

        assertEquals("followers", Visibility.FOLLOWERS.raw)
        assertEquals("フォロワーのみ", Visibility.FOLLOWERS.displayName)

        assertEquals("private", Visibility.PRIVATE.raw)
        assertEquals("非公開", Visibility.PRIVATE.displayName)
    }

    @Test
    fun `rawの並びと表示名の並びが並び順どおりである`() {
        assertEquals(listOf("public", "followers", "private"), Visibility.entries.map { it.raw })
        assertEquals(listOf("公開", "フォロワーのみ", "非公開"), Visibility.entries.map { it.displayName })
    }

    @Test
    fun `全ケースでfromRawに自分のrawを渡すと自分が返る`() {
        Visibility.entries.forEach { case ->
            assertEquals(case, Visibility.fromRaw(case.raw), "往復できない: ${case.name}")
        }
    }

    @Test
    fun `未知の文字列と空文字とnullはnullになり例外を投げない`() {
        // 未知の列挙値は失敗ではなく「値なし」（要件 4.11・設計書の未知の列挙値の扱い）
        assertNull(Visibility.fromRaw("unknown"))
        assertNull(Visibility.fromRaw(""))
        assertNull(Visibility.fromRaw(null))
    }

    @Test
    fun `大文字小文字を区別する`() {
        // Swift の `init(rawValue:)` は完全一致。"Public" や列挙子名の "PUBLIC" は別の値として null にする
        assertNull(Visibility.fromRaw("Public"))
        assertNull(Visibility.fromRaw("PUBLIC"))
        assertNull(Visibility.fromRaw("Followers"))
        assertNull(Visibility.fromRaw("PRIVATE"))
    }

    @Test
    fun `前後に空白があるとnullになる`() {
        // 空白の除去はしない（Swift の `init(rawValue:)` と同じ）
        assertNull(Visibility.fromRaw(" public"))
        assertNull(Visibility.fromRaw("public "))
        assertNull(Visibility.fromRaw("public\n"))
    }

    @Test
    fun `表示名はrawとして受け付けない`() {
        // 表示名は画面用で、Firestore に書く値ではない。取り違えて読み込まないことを固定する
        Visibility.entries.forEach { case ->
            assertNull(Visibility.fromRaw(case.displayName), "表示名を raw として受け付けた: ${case.displayName}")
        }
    }

    @Test
    fun `rawは重複しない`() {
        assertEquals(Visibility.entries.size, Visibility.entries.map { it.raw }.toSet().size)
    }

    @Test
    fun `表示名は重複しない`() {
        assertEquals(Visibility.entries.size, Visibility.entries.map { it.displayName }.toSet().size)
    }
}
