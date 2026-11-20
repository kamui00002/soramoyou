// ⭐️ uid・投稿 ID・Storage のパスの型の単体テスト（タスク 3.1・23.2・要件 7.3・15.2 の下支え）
package com.yoshidometoru.soramoyou.contract

import com.yoshidometoru.soramoyou.contract.model.Visibility
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * [Uid]・[PostId]・[StoragePath] が「同じ文字列でも別の型」であることを確かめる。
 *
 * 取り違えの防止そのもの（`fun f(uid: Uid)` に [PostId] を渡すとコンパイルが通らない）は、
 * コンパイル時にだけ効く性質なので、このテストでは検査しない。型の宣言（@JvmInline value class）が根拠である。
 * ここでは、実行時の等価性・文字列化・ハッシュが期待どおりであることだけを固定する。
 */
class IdentifiersTest {

    @Test
    fun `同じ文字列のUidは等しい`() {
        assertEquals(Uid("user-1"), Uid("user-1"))
        assertEquals(Uid("user-1").hashCode(), Uid("user-1").hashCode())
    }

    @Test
    fun `違う文字列のUidは等しくない`() {
        assertNotEquals(Uid("user-1"), Uid("user-2"))
    }

    @Test
    fun `valueで元の文字列を取り出せる`() {
        assertEquals("user-1", Uid("user-1").value)
        assertEquals("CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC", PostId("CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC").value)
        assertEquals("posts/user-1/public/img.jpg", StoragePath("posts/user-1/public/img.jpg").value)
    }

    @Test
    fun `Uid・PostId・StoragePathは同じ文字列でも互いに等しくならない`() {
        val raw = "same-text"
        // equals(Any?) へ渡して実行時の等価性を確かめる（型が混ざっても true にならないこと）
        val uid: Any = Uid(raw)
        val postId: Any = PostId(raw)
        val path: Any = StoragePath(raw)
        assertNotEquals(uid, postId)
        assertNotEquals(uid, path)
        assertNotEquals(postId, path)
    }

    @Test
    fun `文字列化では型名と値の両方が出る`() {
        // ログで「これは uid か投稿 ID か」が読めるようにするため、型名を含む表示のままにしておく
        val uidText = Uid("abc").toString()
        val postIdText = PostId("abc").toString()
        assertTrue(uidText.contains("Uid") && uidText.contains("abc"), uidText)
        assertTrue(postIdText.contains("PostId") && postIdText.contains("abc"), postIdText)
        assertNotEquals(uidText, postIdText)
    }

    @Test
    fun `Mapのキーや集合の要素として値で引ける`() {
        val likes = mapOf(PostId("P1") to 3L)
        assertEquals(3L, likes[PostId("P1")])
        assertEquals(setOf(Uid("a"), Uid("b")), listOf(Uid("a"), Uid("b"), Uid("a")).toSet())
    }

    @Test
    fun `アイコンのパスはiOSと同じusers_uid_profile_profile_jpg`() {
        assertEquals("users/UID-1/profile/profile.jpg", StoragePath.profileIcon(Uid("UID-1")).value)
    }

    @Test
    fun `アイコンのパスは空のuidを断る`() {
        assertFailsWith<IllegalArgumentException> { StoragePath.profileIcon(Uid("")) }
    }

    @Test
    fun `アイコンのパスはスラッシュを含むuidを断る`() {
        // 別の人のフォルダ（users/other/...）を指すパスを作らせない
        assertFailsWith<IllegalArgumentException> { StoragePath.profileIcon(Uid("other/profile")) }
    }

    @Test
    fun `投稿の本体とサムネイルのパスはiOSと同じ形で、公開範囲ごとのフォルダに分かれる`() {
        // storage.rules の match は posts・thumbnails の下に public・followers・private の 3 つ
        val expected = mapOf(
            Visibility.PUBLIC to "public",
            Visibility.FOLLOWERS to "followers",
            Visibility.PRIVATE to "private",
        )
        for ((visibility, folder) in expected) {
            assertEquals("posts/UID-1/$folder/IMG-1.jpg", StoragePath.postImage(Uid("UID-1"), visibility, "IMG-1").value)
            assertEquals("thumbnails/UID-1/$folder/IMG-1_thumb.jpg", StoragePath.postThumbnail(Uid("UID-1"), visibility, "IMG-1").value)
        }
    }

    @Test
    fun `投稿の画像のパスは空かスラッシュを含むuidと画像IDを断る`() {
        for (build in listOf(StoragePath.Companion::postImage, StoragePath.Companion::postThumbnail)) {
            assertFailsWith<IllegalArgumentException> { build(Uid(""), Visibility.PUBLIC, "IMG-1") }
            assertFailsWith<IllegalArgumentException> { build(Uid("other/x"), Visibility.PUBLIC, "IMG-1") }
            assertFailsWith<IllegalArgumentException> { build(Uid("UID-1"), Visibility.PUBLIC, "") }
            // 画像 ID の / は、別の公開範囲のフォルダ（例：private の下に public/…）を指すパスを作れてしまう
            assertFailsWith<IllegalArgumentException> { build(Uid("UID-1"), Visibility.PRIVATE, "../public/IMG-1") }
        }
    }
}
