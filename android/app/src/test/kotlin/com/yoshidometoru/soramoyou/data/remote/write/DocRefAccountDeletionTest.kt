// ⭐️ 退会で消す文書のパスの factory の単体テスト（タスク 31.2・31.3）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * 退会（タスク 31.2）で足した `follows`・`drafts`・`users/{uid}/favorites` と、タスク 31.3 で足した `likes`（取った ID のまま）・`comments` の
 * factory が、iOS と同じ綴りのパスを作り、
 * 空や `/` を含む ID を断ることを確かめる。
 *
 * [DocRefTest] とは別のファイルにした。同じ時期に別のタスク（フィードバックの文書など）も [DocRef] に factory を足すので、
 * 既存のテストの同じ行の並びに足すと、まとめるときに同じ場所の書き換えがぶつかるため。
 */
class DocRefAccountDeletionTest {

    @Test
    fun `退会で消す文書のfactoryはiOSと同じ綴りのパスを作る`() {
        // 綴りは iOS の FirestoreService.swift の followsCollection・draftsCollection・favoritesCollection と同じ
        assertEquals("follows/U1_U2", DocRef.follow("U1_U2").path)
        assertEquals("drafts/D1", DocRef.draft("D1").path)
        assertEquals("users/U1/favorites/P1", DocRef.favorite(Uid("U1"), "P1").path)
        // 読み取り口が退会で全件を取るお気に入りのコレクション（DefaultFirestoreReader の計画）と同じ親を指す
        assertEquals("${DocRef.user(Uid("U1")).path}/favorites", DocRef.favorite(Uid("U1"), "P1").path.substringBeforeLast('/'))
        assertEquals("P1", DocRef.favorite(Uid("U1"), "P1").documentId)
    }

    @Test
    fun `空のIDや、スラッシュを含むIDでは作れない`() {
        assertFailsWith<IllegalArgumentException> { DocRef.follow("") }
        assertFailsWith<IllegalArgumentException> { DocRef.follow("U1_U2/x") }
        assertFailsWith<IllegalArgumentException> { DocRef.draft("") }
        assertFailsWith<IllegalArgumentException> { DocRef.draft("D1/x") }
        // お気に入りは持ち主の uid と ID の両方を検査する
        assertFailsWith<IllegalArgumentException> { DocRef.favorite(Uid("U1/x"), "P1") }
        assertFailsWith<IllegalArgumentException> { DocRef.favorite(Uid(""), "P1") }
        assertFailsWith<IllegalArgumentException> { DocRef.favorite(Uid("U1"), "") }
        assertFailsWith<IllegalArgumentException> { DocRef.favorite(Uid("U1"), "P1/x") }
    }

    @Test
    fun `退会でいいね・コメントを消すfactoryは、取った文書のIDのままiOSと同じ綴りのパスを作る（タスク31_3）`() {
        // 綴りは iOS の FirestoreService.swift の likesCollection・commentsCollection と同じ
        assertEquals("likes/U1_P1", DocRef.likeById("U1_P1").path)
        assertEquals("comments/C1", DocRef.comment("C1").path)
        // 形の正しいいいねなら、組み立てる factory と同じ文書を指す
        assertEquals(DocRef.like(Uid("U1"), PostId("P1")), DocRef.likeById("U1_P1"))
        // 組み立て直さないので、形の違う旧データの ID もそのまま指せる
        assertEquals("likes/OLD-LIKE", DocRef.likeById("OLD-LIKE").path)
        assertEquals("C1", DocRef.comment("C1").documentId)
    }

    @Test
    fun `いいね・コメントのfactoryも、空のIDやスラッシュを含むIDでは作れない（タスク31_3）`() {
        assertFailsWith<IllegalArgumentException> { DocRef.likeById("") }
        assertFailsWith<IllegalArgumentException> { DocRef.likeById("U1_P1/x") }
        assertFailsWith<IllegalArgumentException> { DocRef.comment("") }
        assertFailsWith<IllegalArgumentException> { DocRef.comment("C1/x") }
    }
}
