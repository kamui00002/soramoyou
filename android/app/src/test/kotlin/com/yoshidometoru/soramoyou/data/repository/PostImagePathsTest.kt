// ⭐️ 投稿を消すときに消す画像のパスの解決（ダウンロード URL からの解決・消してよい形の検査）の単体テスト（タスク 24・要件 10.11）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * iOS の `deletePostImages`（StorageService.swift:332-388）と同じく、`storagePath` を優先し、無ければダウンロード URL から解決すること、
 * 元画像（`originalImages`）は本体だけを消すこと、投稿の画像の形でないパスは消さないことを確かめる。
 */
class PostImagePathsTest {

    private val uid = Uid("UID-1")

    /** 本番の形のダウンロード URL（パスは符号化して最後の区切りに入る）。 */
    private fun prodUrl(encodedPath: String) =
        "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$encodedPath?alt=media&token=abc-123"

    // ── ダウンロード URL からの解決 ──

    @Test
    fun `本番の形のURLから、最後の区切りの符号を戻したパスを取り出す`() {
        assertEquals("posts/UID-1/public/IMG-1.jpg", storagePathFromDownloadUrl(prodUrl("posts%2FUID-1%2Fpublic%2FIMG-1.jpg")))
    }

    @Test
    fun `エミュレータの形のURLも同じ形なので取り出せる`() {
        val url = "http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/thumbnails%2FUID-1%2Ffollowers%2FIMG-1_thumb.jpg?alt=media&token=t"
        assertEquals("thumbnails/UID-1/followers/IMG-1_thumb.jpg", storagePathFromDownloadUrl(url))
    }

    @Test
    fun `プラスは空白に戻さず、符号化したプラスと日本語は戻す`() {
        assertEquals("posts/UID-1/public/a+b.jpg", storagePathFromDownloadUrl(prodUrl("posts%2FUID-1%2Fpublic%2Fa+b.jpg")))
        assertEquals("posts/UID-1/public/a+b.jpg", storagePathFromDownloadUrl(prodUrl("posts%2FUID-1%2Fpublic%2Fa%2Bb.jpg")))
        assertEquals("posts/UID-1/public/空.jpg", storagePathFromDownloadUrl(prodUrl("posts%2FUID-1%2Fpublic%2F%E7%A9%BA.jpg")))
    }

    @Test
    fun `バケット名がoでも、形の位置で取り違えない`() {
        assertEquals("posts/UID-1/public/x.jpg", storagePathFromDownloadUrl("https://h/v0/b/o/o/posts%2FUID-1%2Fpublic%2Fx.jpg"))
    }

    @Test
    fun `v0・b・バケット・oの形でないURLと、戻せない符号は解決しない`() {
        val rejected = listOf(
            "https://example.com/IMG-1.jpg",
            "https://h/v0/b/bucket/o/",
            "https://h/v0/b/bucket/o/posts%2Fx/extra",
            "https://h/v1/b/bucket/o/posts%2Fx",
            "https://h/v0/x/bucket/o/posts%2Fx",
            "https://h/v0/b//o/posts%2Fx",
            "https://h/prefix/v0/b/bucket/o/posts%2Fx",
            // 方式もホストも無い相対の形（先頭の区切りが空でない）
            "x/v0/b/bucket/o/posts%2Fx",
            prodUrl("posts%2FUID-1%2Fpublic%2F%G1.jpg"),
            prodUrl("posts%2FUID-1%2Fpublic%2Fx%"),
            "空白 を 含む",
            "",
        )
        rejected.forEach { assertNull(storagePathFromDownloadUrl(it), it) }
    }

    // ── 消してよいパスの形 ──

    @Test
    fun `投稿の画像の3つの置き場と3つの公開範囲の、自分のパスは消してよい`() {
        listOf("posts", "thumbnails", "originals").forEach { root ->
            listOf("public", "followers", "private").forEach { visibility ->
                assertTrue(isDeletablePostImagePath("$root/UID-1/$visibility/IMG.jpg", uid), "$root/$visibility")
            }
        }
    }

    @Test
    fun `アイコン・他人・別の置き場・未知の公開範囲・区切りの数の違うパスは消さない`() {
        val rejected = listOf(
            "users/UID-1/profile/profile.jpg",
            "posts/UID-2/public/IMG.jpg",
            "drafts/UID-1/public/IMG.jpg",
            "posts/UID-1/secret/IMG.jpg",
            "posts/UID-1/public/",
            "posts/UID-1/public",
            "posts/UID-1/public/a/b.jpg",
            "/posts/UID-1/public/IMG.jpg",
            "",
        )
        rejected.forEach { assertFalse(isDeletablePostImagePath(it, uid), it) }
    }

    // ── 文書からパスを集める ──

    @Test
    fun `本体とサムネイルはstoragePathを優先し、無い画像だけURLから解決する。並びは文書の順`() {
        val data = mapOf(
            "images" to listOf(
                mapOf(
                    "url" to prodUrl("posts%2FUID-1%2Fpublic%2FIGNORED.jpg"),
                    "thumbnail" to prodUrl("thumbnails%2FUID-1%2Fpublic%2FIGNORED_thumb.jpg"),
                    "storagePath" to "posts/UID-1/public/A.jpg",
                    "thumbnailStoragePath" to "thumbnails/UID-1/public/A_thumb.jpg",
                ),
                // 旧データ（パスが無い・空・文字列でない）
                mapOf(
                    "url" to prodUrl("posts%2FUID-1%2Fpublic%2FB.jpg"),
                    "thumbnail" to prodUrl("thumbnails%2FUID-1%2Fpublic%2FB_thumb.jpg"),
                    "storagePath" to "",
                    "thumbnailStoragePath" to 42L,
                ),
            ),
        )

        assertEquals(
            listOf("posts/UID-1/public/A.jpg", "thumbnails/UID-1/public/A_thumb.jpg", "posts/UID-1/public/B.jpg", "thumbnails/UID-1/public/B_thumb.jpg")
                .map(::StoragePath),
            postImagePathsOf(data, uid),
        )
    }

    @Test
    fun `元画像は本体だけを、画像の後に集める（iOSもサムネイルは消さない）`() {
        val data = mapOf(
            "originalImages" to listOf(
                mapOf("storagePath" to "originals/UID-1/private/O1.jpg", "thumbnailStoragePath" to "thumbnails/UID-1/private/O1_thumb.jpg"),
                mapOf("url" to prodUrl("originals%2FUID-1%2Fprivate%2FO2.jpg")),
            ),
            "images" to listOf(mapOf("storagePath" to "posts/UID-1/private/A.jpg")),
        )

        assertEquals(
            listOf("posts/UID-1/private/A.jpg", "originals/UID-1/private/O1.jpg", "originals/UID-1/private/O2.jpg").map(::StoragePath),
            postImagePathsOf(data, uid),
        )
    }

    @Test
    fun `投稿の画像の形でないパスは捨て、同じパスは1回だけにする`() {
        val data = mapOf(
            "images" to listOf(
                mapOf("storagePath" to "users/UID-1/profile/profile.jpg", "thumbnailStoragePath" to "thumbnails/UID-2/public/X_thumb.jpg"),
                mapOf("storagePath" to "posts/UID-1/public/A.jpg"),
                mapOf("storagePath" to "posts/UID-1/public/A.jpg"),
            ),
            "originalImages" to listOf(mapOf("storagePath" to "posts/UID-1/public/A.jpg")),
        )

        assertEquals(listOf(StoragePath("posts/UID-1/public/A.jpg")), postImagePathsOf(data, uid))
    }

    @Test
    fun `画像が無い・リストでない・地図でない要素・解決できないURLは飛ばす`() {
        assertEquals(emptyList(), postImagePathsOf(emptyMap(), uid))
        assertEquals(emptyList(), postImagePathsOf(mapOf("images" to "壊れた値", "originalImages" to 1L), uid))
        val data = mapOf(
            "images" to listOf(
                "地図でない",
                null,
                mapOf("url" to "https://example.com/IMG.jpg"),
                mapOf("storagePath" to "posts/UID-1/public/A.jpg"),
            ),
        )
        assertEquals(listOf(StoragePath("posts/UID-1/public/A.jpg")), postImagePathsOf(data, uid))
    }

    // ── 退会で一覧するフォルダ（タスク 31.6）──

    @Test
    fun `退会で一覧するのは、投稿の画像の3つの置き場と3つの公開範囲の9つと、アイコンのフォルダ`() {
        // 消してよい画像の形（isDeletablePostImagePath）の 1 つ上と、アイコンの 1 つ上。iOS の古いアイコン users/{uid}/profile.jpg は rules が断るので入れない
        assertEquals(
            listOf(
                "posts/UID-1/public", "posts/UID-1/followers", "posts/UID-1/private",
                "thumbnails/UID-1/public", "thumbnails/UID-1/followers", "thumbnails/UID-1/private",
                "originals/UID-1/public", "originals/UID-1/followers", "originals/UID-1/private",
                "users/UID-1/profile",
            ).map(::StoragePath),
            ownImageFolders(uid),
        )
    }

    @Test
    fun `退会で一覧するフォルダは、空や区切りを含むuidを断る`() {
        assertFailsWith<IllegalArgumentException> { ownImageFolders(Uid("")) }
        assertFailsWith<IllegalArgumentException> { ownImageFolders(Uid("UID-1/../UID-2")) }
    }
}
