// ⭐️ Android の投稿が iOS 版で読めることの単体テスト（タスク 20.5・要件 7.10・7.11・17.7）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.model.TimeOfDay
import com.yoshidometoru.soramoyou.contract.model.Visibility
import java.time.Instant
import kotlin.math.nextDown
import kotlin.math.nextUp
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

/**
 * (1) [DocumentBuilders.postCreate] の出力が、iOS の読み取りの失敗条件（[IosPostReaderContract]）に当たらないこと、
 * (2) 判定そのものが、iOS が失敗する入力を失敗と判定すること（陽性対照）を確かめる。
 *
 * 期待値の根拠：`as? Int`・`as? [[String: Any]]` の挙動は Swift 6.4（macOS 27）で実測した（手元（git の外）の `20.5-nsnumber_as_int.tsv`。
 * -2^63 より小さい小数・2^63 の 1 つ外・`false`・null（iOS の SDK では NSNull）を含む配列は同じ置き場の `rv4-B7-swift.tsv`）。
 * 陽性対照（判定を壊して赤を確かめたもの）の手順は手元の台本（git の外）。
 */
class IosPostReaderContractTest {

    private val uid = Uid("USER-UID-1")
    private val postId = PostId("EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")
    private val now = Instant.parse("2026-10-09T01:02:03.456Z")

    /** 本番の Storage のダウンロード URL の形（画像の `url`・`thumbnail` の契約が通す形。名前の `/` は `%2F` に符号化する）。 */
    private fun downloadUrl(encodedName: String) =
        "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$encodedName?alt=media&token=abc-123"

    private fun image(order: Int, visibility: Visibility) = UploadedImage(
        url = downloadUrl("full-$order.jpg"),
        thumbnailUrl = downloadUrl("thumb-$order.jpg"),
        widthPx = 1536,
        heightPx = 2048,
        order = order,
        storagePath = StoragePath("posts/${uid.value}/${visibility.raw}/IMG-$order.jpg"),
        thumbnailStoragePath = StoragePath("thumbnails/${uid.value}/${visibility.raw}/IMG-${order}_thumb.jpg"),
    )

    /**
     * Firestore に保存された後の生のマップに直す（Android SDK で読み戻したときの Kotlin の型：整数は Long・配列は List・マップは Map）。
     * 時刻は iOS の判定が見ないので、[Instant] のまま置く。サーバー側で値が決まる種類は、組み立ての出力に現れないので扱わない。
     */
    private fun stored(doc: FsDocument): Map<String, Any?> = doc.mapValues { (_, value) -> storedValue(value) }

    private fun storedValue(value: FsValue): Any? = when (value) {
        is FsValue.Str -> value.value
        is FsValue.Int64 -> value.value
        is FsValue.Bool -> value.value
        is FsValue.Time -> value.instant
        is FsValue.StrList -> value.values
        is FsValue.MapList -> value.values.map(::stored)
        FsValue.ServerTime, is FsValue.Increment, is FsValue.ArrayUnion, is FsValue.ArrayRemove, FsValue.DeleteField ->
            error("投稿の作成の出力に現れない種類: ${value.kind}")
    }

    private fun judge(doc: Map<String, Any?>) = IosPostReaderContract.judge(doc)

    private val allReadable = IosPostReadResult.Readable(emptyList())

    /** 組み立てた 2 枚の投稿を保存した形。 */
    private fun storedPost(): Map<String, Any?> = stored(
        DocumentBuilders.postCreate(
            NewPost(postId, uid, listOf(image(0, Visibility.PUBLIC), image(1, Visibility.PUBLIC)), Visibility.PUBLIC, null, emptyList(), null, null, now),
        ),
    )

    /** 保存した形の [index] 番目の画像の [key] を [value] にする（null なら取り除く）。 */
    @Suppress("UNCHECKED_CAST")
    private fun withImage(index: Int, key: String, value: Any?, remove: Boolean = false): Map<String, Any?> {
        val doc = storedPost()
        val images = (doc["images"] as List<Map<String, Any?>>).toMutableList()
        images[index] = if (remove) images[index] - key else images[index] + (key to value)
        return doc + ("images" to images)
    }

    // ============================================================
    // 組み立ての全ての出力が iOS で読める
    // ============================================================

    @Test
    fun `組み立ての出力は、公開範囲・枚数・任意項目の全ての組み合わせでiOSが全画像を読める`() {
        var checked = 0
        for (visibility in Visibility.entries) {
            for (count in listOf(1, 2, 10)) {
                for (withOptional in listOf(false, true)) {
                    val input = NewPost(
                        postId = postId,
                        userId = uid,
                        images = (0 until count).map { image(it, visibility) },
                        visibility = visibility,
                        caption = if (withOptional) "夕焼け #夕焼け" else null,
                        hashtags = if (withOptional) listOf("夕焼け") else emptyList(),
                        capturedAt = if (withOptional) now else null,
                        timeOfDay = if (withOptional) TimeOfDay.EVENING else null,
                        createdAt = now,
                    )
                    val doc = DocumentBuilders.postCreate(input)
                    // 書き込みの契約にも合格する出力であること（契約の外の出力を iOS 判定だけで通さない）
                    assertEquals(emptyList(), AllowListShapeValidator.validate(ShapeContracts.POST_CREATE, doc, WriteTarget(postId.value, uid)))
                    assertEquals(allReadable, judge(stored(doc)), "${visibility.raw} / $count 枚 / 任意項目 $withOptional")
                    checked++
                }
            }
        }
        assertEquals(18, checked)
    }

    // ============================================================
    // 陽性対照（タスク 20.5 の 2 項目）
    // ============================================================

    @Test
    fun `投稿IDが無い投稿はiOSで読めない`() {
        assertIs<IosPostReadResult.Unreadable>(judge(storedPost() - "postId"))
    }

    @Test
    fun `小数部のある幅の画像はiOSで読み飛ばされる`() {
        assertEquals(IosPostReadResult.Readable(listOf(0)), judge(withImage(0, "width", 1536.5)))
        assertEquals(IosPostReadResult.Readable(listOf(1)), judge(withImage(1, "height", 2048.5)))
        assertEquals(IosPostReadResult.Readable(listOf(0)), judge(withImage(0, "order", 0.5)))
    }

    // ============================================================
    // 投稿ごと読めない条件
    // ============================================================

    @Test
    fun `投稿IDか投稿者が文字列でなければ読めない`() {
        assertIs<IosPostReadResult.Unreadable>(judge(storedPost() - "userId"))
        assertIs<IosPostReadResult.Unreadable>(judge(storedPost() + ("postId" to 123L)))
        assertIs<IosPostReadResult.Unreadable>(judge(storedPost() + ("userId" to null)))
    }

    @Test
    fun `画像がマップの配列でなければ読めない`() {
        assertIs<IosPostReadResult.Unreadable>(judge(storedPost() - "images"))
        assertIs<IosPostReadResult.Unreadable>(judge(storedPost() + ("images" to "not an array")))
        assertIs<IosPostReadResult.Unreadable>(judge(storedPost() + ("images" to mapOf("url" to "u"))))
        // マップでない要素・null が 1 つでも混ざると、配列ごと読めない（Swift の `as? [[String: Any]]` が nil。
        // マップでない要素は 20.5-nsnumber_as_int.tsv、null（NSNull）を混ぜた配列と null だけの配列は rv4-B7-swift.tsv で実測）
        val images = storedPost()["images"] as List<*>
        assertIs<IosPostReadResult.Unreadable>(judge(storedPost() + ("images" to images + "not a map")))
        assertIs<IosPostReadResult.Unreadable>(judge(storedPost() + ("images" to images + listOf(null))))
        assertIs<IosPostReadResult.Unreadable>(judge(storedPost() + ("images" to listOf(null))))
    }

    @Test
    fun `空の画像の配列は読めるが画像の無い投稿になる`() {
        assertEquals(allReadable, judge(storedPost() + ("images" to emptyList<Any>())))
    }

    // ============================================================
    // 画像が読み飛ばされる条件
    // ============================================================

    @Test
    fun `URLが文字列でない画像は読み飛ばされる`() {
        assertEquals(IosPostReadResult.Readable(listOf(0)), judge(withImage(0, "url", null, remove = true)))
        assertEquals(IosPostReadResult.Readable(listOf(1)), judge(withImage(1, "url", 1L)))
    }

    @Test
    fun `幅・高さ・表示順が無いか文字列なら読み飛ばされる`() {
        for (key in listOf("width", "height", "order")) {
            assertEquals(IosPostReadResult.Readable(listOf(0)), judge(withImage(0, key, null, remove = true)), key)
            assertEquals(IosPostReadResult.Readable(listOf(0)), judge(withImage(0, key, "1536")), key)
            assertEquals(IosPostReadResult.Readable(listOf(0)), judge(withImage(0, key, null)), key)
        }
    }

    @Test
    fun `iOSのas Intが読む値は読み飛ばさない`() {
        // 実測：小数部が 0 の小数・真偽値（true は 1・false は 0）・-2^63 と 2^63 の小数は `as? Int` で読める
        for (value in listOf(1536.0, -0.0, true, false, -9.223372036854775808E18, 9.223372036854775808E18, Long.MAX_VALUE, 7)) {
            assertEquals(allReadable, judge(withImage(0, "width", value)), "$value")
        }
        // 実測：無限大（正・負）・NaN・±1e300・最も小さい有限の小数・-2^63 と 2^63 の 1 つ外は読まない
        val outside = listOf(
            Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.NaN, 1e300, -1e300, -Double.MAX_VALUE,
            (-9.223372036854775808E18).nextDown(), 9.223372036854775808E18.nextUp(),
        )
        for (value in outside) {
            assertEquals(IosPostReadResult.Readable(listOf(0)), judge(withImage(0, "width", value)), "$value")
        }
    }

    @Test
    fun `読み飛ばすのは条件に当たる画像だけ`() {
        val doc = withImage(0, "width", 1536.5)
        @Suppress("UNCHECKED_CAST")
        val images = (doc["images"] as List<Map<String, Any?>>).toMutableList()
        images[1] = images[1] + ("order" to "1")
        assertEquals(IosPostReadResult.Readable(listOf(0, 1)), judge(doc + ("images" to images)))
    }

    @Test
    fun `任意の項目の欠落や未知の値では読めなくならない`() {
        // iOS は既定値か nil に倒す（Post.swift:291-333）。判定は見ない
        val doc = storedPost() - "visibility" - "likesCount" - "createdAt" +
            ("timeOfDay" to "noon") + ("caption" to 1L) + ("hashtags" to "not a list")
        assertEquals(allReadable, judge(doc))
    }
}
