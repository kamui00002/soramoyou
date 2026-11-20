// ⭐️ マイルストーンごとの有効な書き込みの集合（設計書の表）の単体テスト（タスク 6.1・要件 2.2）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.WriteCapability
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * [writeCapabilitiesOf] が、設計書「マイルストーンと有効化の範囲」（design.md:260-267）の表のとおりの集合を返すことを確かめる。
 * 期待値は表から書き写したもので、実装の書き方（前のマイルストーンに足していく）には頼らない。
 */
class WriteCapabilitiesOfTest {

    @Test
    fun `M1では書き込みの集合が空（本番への書き込みゼロ）`() {
        assertEquals(emptySet(), writeCapabilitiesOf(Milestone.M1))
    }

    @Test
    fun `各マイルストーンの集合は設計書の表のとおり`() {
        val m2 = setOf(WriteCapability.ACCOUNT_CREATE, WriteCapability.ACCOUNT_REPAIR, WriteCapability.PROFILE_EDIT)
        val m3 = m2 + WriteCapability.LIKE
        // POST_DELETE は「Q8の承認時」の注記つき。Q8 は設計書 :51 で「MVP に含める」と決まっている
        val m4 = m3 + setOf(WriteCapability.POST_CREATE, WriteCapability.POSTS_COUNT_SYNC, WriteCapability.POST_DELETE)
        val m5 = m4 + setOf(WriteCapability.REPORT, WriteCapability.BLOCK, WriteCapability.FEEDBACK, WriteCapability.ACCOUNT_DELETE)
        val expected = mapOf(
            Milestone.M1 to emptySet(),
            Milestone.M2 to m2,
            Milestone.M3 to m3,
            Milestone.M4 to m4,
            Milestone.M5 to m5,
            // M6（クローズドテスト・本番公開）は M5 と同じ
            Milestone.M6 to m5,
        )

        // 表の行がマイルストーンの全てを覆っていること（マイルストーンを足したのに表を足し忘れたら失敗させる）
        assertEquals(Milestone.entries.toSet(), expected.keys)
        for (milestone in Milestone.entries) {
            assertEquals(expected.getValue(milestone), writeCapabilitiesOf(milestone), "$milestone の集合が設計書の表と違う")
        }
    }

    @Test
    fun `M5までに全ての書き込みの種類が有効になる（どのマイルストーンにも入らない種類を作らない）`() {
        // WriteCapability に種類を足したのに、どのマイルストーンにも入れ忘れると、その書き込みは永久に遮断される。
        // 上の表のテストは表に書いた種類しか見ないので、列挙の全体と突き合わせてこれを検出する
        assertEquals(WriteCapability.entries.toSet(), writeCapabilitiesOf(Milestone.M5))
    }

    @Test
    fun `返す集合は変更できない`() {
        for (milestone in Milestone.entries) {
            assertUnmodifiable(writeCapabilitiesOf(milestone), "$milestone の集合")
        }
    }

    @Test
    fun `isEnabledは有効な集合に含まれるかどうかを答える`() {
        // インターフェースの既定の実装を確かめる。製品のゲートは M1 で全てが無効なので、有効の側をここで見る
        val gate = object : WriteGate {
            override val enabled: Set<WriteCapability> = setOf(WriteCapability.LIKE)
        }

        assertTrue(gate.isEnabled(WriteCapability.LIKE))
        for (capability in WriteCapability.entries - WriteCapability.LIKE) {
            assertFalse(gate.isEnabled(capability), "$capability は有効な集合に無いのに有効と答えた")
        }
    }
}

/**
 * [set] が変更できない集合であることを確かめる。
 * 中身を変えない操作（自分自身の要素だけを残す retainAll）を使う。変更できる集合はこれを例外なく受け付け、
 * 変更できない集合（Collections.unmodifiableSet・Kotlin の emptySet など）は中身にかかわらず例外を投げる。
 * 中身を変えないので、検査に失敗しても [set] を壊さない（同じ集合を持つ object を、ほかのテストと共有していても安全）。
 */
internal fun assertUnmodifiable(set: Set<WriteCapability>, what: String) {
    assertFailsWith<UnsupportedOperationException>("$what を変更できてしまう") {
        (set as MutableSet<WriteCapability>).retainAll(set.toList())
    }
}
