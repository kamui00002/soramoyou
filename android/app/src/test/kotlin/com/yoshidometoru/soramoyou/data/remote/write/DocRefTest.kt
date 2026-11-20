// ⭐️ 書き込み先のパスの factory の単体テスト（タスク 6.2）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/** コレクション名の綴りと ID の組み立て方が、設計書の表（design.md:709）のとおりであることを確かめる。 */
class DocRefTest {

    @Test
    fun `factoryは設計書のパスの形を作る`() {
        assertEquals("users/U1", DocRef.user(Uid("U1")).path)
        assertEquals("publicProfiles/U1", DocRef.publicProfile(Uid("U1")).path)
        assertEquals("posts/P1", DocRef.post(PostId("P1")).path)
        assertEquals("likes/U1_P1", DocRef.like(Uid("U1"), PostId("P1")).path)
        assertEquals("reports/R1", DocRef.report("R1").path)
        assertEquals("feedback/BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", DocRef.feedback("BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB").path)
    }

    @Test
    fun `documentIdはパスの最後の区切り`() {
        assertEquals("P1", DocRef.post(PostId("P1")).documentId)
        assertEquals("U1_P1", DocRef.like(Uid("U1"), PostId("P1")).documentId)
        assertEquals("R1", DocRef.report("R1").documentId)
        assertEquals("F1", DocRef.feedback("F1").documentId)
    }

    @Test
    fun `空のIDや、スラッシュを含むIDでは作れない`() {
        assertFailsWith<IllegalArgumentException> { DocRef.user(Uid("a/b/c")) }
        assertFailsWith<IllegalArgumentException> { DocRef.publicProfile(Uid("")) }
        assertFailsWith<IllegalArgumentException> { DocRef.post(PostId("")) }
        assertFailsWith<IllegalArgumentException> { DocRef.like(Uid("U1"), PostId("P1/x")) }
        assertFailsWith<IllegalArgumentException> { DocRef.report("") }
        assertFailsWith<IllegalArgumentException> { DocRef.report("R1/x") }
        assertFailsWith<IllegalArgumentException> { DocRef.feedback("") }
        assertFailsWith<IllegalArgumentException> { DocRef.feedback("F1/x") }
    }
}
