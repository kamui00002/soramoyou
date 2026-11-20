// ⭐️ Firestore の自動 ID と同じ形の ID の単体テスト（タスク 29.1・要件 11.2）
package com.yoshidometoru.soramoyou.data.repository

import java.util.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 通報の文書の ID が、iOS の `addDocument` が付ける Firestore の自動 ID と同じ形（62 文字から 20 文字）であることを確かめる。
 * 期待する文字の集合と長さは SDK の自動 ID の仕様から書き写したもので、実装の定数には頼らない。
 */
class FirestoreAutoIdTest {

    /** 添字を固定で返す乱数。`nextInt(bound)` が呼ばれた bound を控える（62 通りから選んでいることを確かめるため）。 */
    private class FixedIndexRandom(private val index: Int) : Random() {
        val bounds = mutableListOf<Int>()
        override fun nextInt(bound: Int): Int {
            bounds += bound
            return index
        }
    }

    private val expectedAlphabet: Set<Char> = ('A'..'Z').toSet() + ('a'..'z').toSet() + ('0'..'9').toSet()

    @Test
    fun `文字の集合は英大文字と英小文字と数字の62文字で、重複しない`() {
        assertEquals(62, expectedAlphabet.size)
        assertEquals(expectedAlphabet, FirestoreAutoId.ALPHABET.toSet())
        assertEquals(62, FirestoreAutoId.ALPHABET.length)
    }

    @Test
    fun `20文字で、62文字の集合の文字だけでできている`() {
        repeat(200) {
            val id = FirestoreAutoId.next()
            assertEquals(20, id.length, "長さが違う: $id")
            assertTrue(id.all { it in expectedAlphabet }, "集合の外の文字がある: $id")
        }
    }

    @Test
    fun `乱数の返した添字がそのまま文字の位置になり、62通りから20回選ぶ`() {
        val first = FixedIndexRandom(0)
        assertEquals("A".repeat(20), FirestoreAutoId.next(first))
        assertEquals(List(20) { 62 }, first.bounds)

        // 最後の添字（61）は数字の 9。先頭の添字 26 は英小文字の a（A〜Z の次）、52 は数字の 0（a〜z の次）
        assertEquals("9".repeat(20), FirestoreAutoId.next(FixedIndexRandom(61)))
        assertEquals("a".repeat(20), FirestoreAutoId.next(FixedIndexRandom(26)))
        assertEquals("0".repeat(20), FirestoreAutoId.next(FixedIndexRandom(52)))
    }

    @Test
    fun `既定の乱数で続けて作ったIDは重ならない`() {
        val ids = List(1000) { FirestoreAutoId.next() }

        assertEquals(1000, ids.toSet().size)
    }
}
