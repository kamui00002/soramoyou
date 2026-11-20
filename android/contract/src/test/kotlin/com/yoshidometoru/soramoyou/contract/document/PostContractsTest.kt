// ⭐️ 投稿と投稿数の書き込みの契約・組み立ての単体テスト（タスク 20.4・要件 7.3・7.10〜7.14・7.17・8.1・8.2）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.model.TimeOfDay
import com.yoshidometoru.soramoyou.contract.model.Visibility
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 投稿の作成（POST_CREATE・POST_IMAGE）と投稿数の更新（USER_POSTS_COUNT・PUBLIC_PROFILE_POSTS_COUNT）の契約と組み立てを確かめる。
 *
 * 陽性対照（実装を壊して赤を確かめたもの。改変の手順は手元の台本・git の外）：
 * いいね数の必須を外す・画像の幅に文字列を許す・Storage のパスの制約を外す・許可リストに `editSettings` を足す、の 4 つ。
 *
 * 「小数の幅」は、この層では作れない。[FsValue] に小数の種類が無いので、`width` に小数を入れた文書はコンパイルが通らない
 * （FsValue.kt の説明）。ここでは代わりに、整数でない値（文字列）が WrongKind になることを確かめる。
 * 「小数だと iOS で画像が落ちる」ことの判定は、生のマップを受けるタスク 20.5 の IosPostReaderContract が受け持つ。
 */
class PostContractsTest {

    private val uid = Uid("USER-UID-1")
    private val postId = PostId("EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")
    private val now = Instant.parse("2026-10-09T01:02:03.456Z")
    private val capturedAt = Instant.parse("2026-10-08T08:30:00Z")
    private val target = WriteTarget(documentId = postId.value, authUid = uid)

    /** 本番の Storage のダウンロード URL の形（画像の `url`・`thumbnail` の契約が通す形。名前の `/` は `%2F` に符号化する）。 */
    private fun downloadUrl(encodedName: String) =
        "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$encodedName?alt=media&token=abc-123"

    private fun image(order: Int, visibility: Visibility = Visibility.PUBLIC, owner: String = uid.value) = UploadedImage(
        url = downloadUrl("full-$order.jpg"),
        thumbnailUrl = downloadUrl("thumb-$order.jpg"),
        widthPx = 1536,
        heightPx = 2048,
        order = order,
        storagePath = StoragePath("posts/$owner/${visibility.raw}/IMG-$order.jpg"),
        thumbnailStoragePath = StoragePath("thumbnails/$owner/${visibility.raw}/IMG-${order}_thumb.jpg"),
    )

    private fun newPost(
        visibility: Visibility = Visibility.PUBLIC,
        images: List<UploadedImage> = listOf(image(0, visibility), image(1, visibility)),
        caption: String? = "夕焼け #夕焼け #空",
        hashtags: List<String> = listOf("夕焼け", "空"),
        capturedAt: Instant? = this.capturedAt,
        timeOfDay: TimeOfDay? = TimeOfDay.EVENING,
    ) = NewPost(postId, uid, images, visibility, caption, hashtags, capturedAt, timeOfDay, now)

    private fun validate(doc: FsDocument, writeTarget: WriteTarget = target): List<Violation> =
        AllowListShapeValidator.validate(ShapeContracts.POST_CREATE, doc, writeTarget)

    /** 違反の（種類, キー）。 */
    private fun shapeOf(violations: List<Violation>): List<Pair<String, String>> = violations.map {
        when (it) {
            is Violation.MissingKey -> "MissingKey" to it.key
            is Violation.UnexpectedKey -> "UnexpectedKey" to it.key
            is Violation.WrongKind -> "WrongKind" to it.key
            is Violation.OutOfRange -> "OutOfRange" to it.key
        }
    }

    /** 組み立てた正しい文書の、トップレベルの [key] を [value] に差し替える。 */
    private fun validDocWith(key: String, value: FsValue): FsDocument = DocumentBuilders.postCreate(newPost()) + (key to value)

    /** 組み立てた正しい文書の、1 枚目の画像の [key] を差し替える（[value] が null なら取り除く）。 */
    private fun validDocWithFirstImage(key: String, value: FsValue?): FsDocument {
        val doc = DocumentBuilders.postCreate(newPost())
        val images = (doc["images"] as FsValue.MapList).values
        val first = if (value == null) images[0] - key else images[0] + (key to value)
        return doc + ("images" to FsValue.MapList(listOf(first) + images.drop(1)))
    }

    @Test
    fun `契約のIDは操作ごとに正しい`() {
        assertEquals(ContractId.POST_CREATE, ShapeContracts.POST_CREATE.id)
        assertEquals(ContractId.POST_IMAGE, ShapeContracts.POST_IMAGE.id)
        assertEquals(ContractId.USER_POSTS_COUNT, ShapeContracts.USER_POSTS_COUNT.id)
        assertEquals(ContractId.PUBLIC_PROFILE_POSTS_COUNT, ShapeContracts.PUBLIC_PROFILE_POSTS_COUNT.id)
    }

    // ============================================================
    // 組み立て
    // ============================================================

    @Test
    fun `全ての項目があるとiOSと同じ形の文書を作り、契約に合格する`() {
        val doc = DocumentBuilders.postCreate(newPost(images = listOf(image(0))))
        val expected: FsDocument = mapOf(
            "postId" to FsValue.Str(postId.value),
            "userId" to FsValue.Str(uid.value),
            "images" to FsValue.MapList(
                listOf(
                    mapOf(
                        "url" to FsValue.Str(downloadUrl("full-0.jpg")),
                        "width" to FsValue.Int64(1536L),
                        "height" to FsValue.Int64(2048L),
                        "order" to FsValue.Int64(0L),
                        "thumbnail" to FsValue.Str(downloadUrl("thumb-0.jpg")),
                        "storagePath" to FsValue.Str("posts/USER-UID-1/public/IMG-0.jpg"),
                        "thumbnailStoragePath" to FsValue.Str("thumbnails/USER-UID-1/public/IMG-0_thumb.jpg"),
                    ),
                ),
            ),
            "visibility" to FsValue.Str("public"),
            "likesCount" to FsValue.Int64(0L),
            "commentsCount" to FsValue.Int64(0L),
            "createdAt" to FsValue.Time(now),
            "updatedAt" to FsValue.Time(now),
            "caption" to FsValue.Str("夕焼け #夕焼け #空"),
            "hashtags" to FsValue.StrList(listOf("夕焼け", "空")),
            "capturedAt" to FsValue.Time(capturedAt),
            "timeOfDay" to FsValue.Str("evening"),
        )
        assertEquals(expected, doc)
        assertEquals(emptyList(), validate(doc))
    }

    @Test
    fun `任意の項目が無ければキーごと省略し、必須の8キーだけで契約に合格する`() {
        val doc = DocumentBuilders.postCreate(newPost(caption = null, hashtags = emptyList(), capturedAt = null, timeOfDay = null))
        assertEquals(
            setOf("postId", "userId", "images", "visibility", "likesCount", "commentsCount", "createdAt", "updatedAt"),
            doc.keys,
        )
        assertEquals(emptyList(), validate(doc))
    }

    @Test
    fun `公開範囲ごとに、その公開範囲のパスの画像で契約に合格する`() {
        for (visibility in Visibility.entries) {
            val doc = DocumentBuilders.postCreate(newPost(visibility = visibility))
            assertEquals(FsValue.Str(visibility.raw), doc["visibility"])
            assertEquals(emptyList(), validate(doc), visibility.raw)
        }
    }

    @Test
    fun `画像は10枚まで並びのまま書き、幅・高さ・表示順は整数`() {
        val images = (0 until 10).map { image(it) }
        val doc = DocumentBuilders.postCreate(newPost(images = images))
        val written = (doc["images"] as FsValue.MapList).values
        assertEquals((0 until 10).map { FsValue.Int64(it.toLong()) }, written.map { it["order"] })
        assertTrue(written.all { it["width"] is FsValue.Int64 && it["height"] is FsValue.Int64 })
        assertEquals(emptyList(), validate(doc))
    }

    @Test
    fun `組み立ては空のキャプションや31個のハッシュタグを直さず、契約が止める`() {
        assertEquals(
            listOf("OutOfRange" to "caption"),
            shapeOf(validate(DocumentBuilders.postCreate(newPost(caption = "")))),
        )
        assertEquals(
            listOf("OutOfRange" to "hashtags"),
            shapeOf(validate(DocumentBuilders.postCreate(newPost(hashtags = List(31) { "空" })))),
        )
    }

    // ============================================================
    // 陽性対照（タスク 20.4 の 4 項目）
    // ============================================================

    @Test
    fun `いいね数やコメント数が無い投稿は違反になる`() {
        val doc = DocumentBuilders.postCreate(newPost())
        assertEquals(listOf("MissingKey" to "likesCount"), shapeOf(validate(doc - "likesCount")))
        assertEquals(listOf("MissingKey" to "commentsCount"), shapeOf(validate(doc - "commentsCount")))
    }

    @Test
    fun `画像の幅・高さ・表示順が整数でなければ違反になる`() {
        // 小数は FsValue で作れないので、整数でない値の代表として文字列を入れる（クラスの説明を参照）
        for (key in listOf("width", "height", "order")) {
            assertEquals(
                listOf("WrongKind" to "images[0].$key"),
                shapeOf(validate(validDocWithFirstImage(key, FsValue.Str("1536.5")))),
                key,
            )
        }
    }

    @Test
    fun `画像のパスの公開範囲が投稿の公開範囲と違えば違反になる`() {
        // 公開の投稿なのに、画像は非公開の場所にある
        val doc = DocumentBuilders.postCreate(newPost(visibility = Visibility.PUBLIC, images = listOf(image(0, Visibility.PRIVATE))))
        assertEquals(
            listOf("OutOfRange" to "images[0].storagePath", "OutOfRange" to "images[0].thumbnailStoragePath"),
            shapeOf(validate(doc)),
        )
    }

    @Test
    fun `編集情報など書かないキーを含む投稿は違反になる`() {
        val forbidden = listOf(
            "editSettings", "editRecipeV1", "originalImages",
            "mood", "frameId", "frameCaption", "frameTextColorHex", "frameFontStyle", "postKind", "collageLayout", "panelLabels",
            "location", "skyType", "skyColors", "colorTemperature",
        )
        for (key in forbidden) {
            assertEquals(listOf("UnexpectedKey" to key), shapeOf(validate(validDocWith(key, FsValue.Str("x")))), key)
        }
        assertEquals(
            listOf("UnexpectedKey" to "images[0].externalEditInfo"),
            shapeOf(validate(validDocWithFirstImage("externalEditInfo", FsValue.Str("x")))),
        )
    }

    // ============================================================
    // 値の範囲
    // ============================================================

    @Test
    fun `画像は1枚から10枚まで`() {
        assertEquals(listOf("OutOfRange" to "images"), shapeOf(validate(DocumentBuilders.postCreate(newPost(images = emptyList())))))
        assertEquals(
            listOf("OutOfRange" to "images"),
            shapeOf(validate(DocumentBuilders.postCreate(newPost(images = (0 until 11).map { image(it % 10) })))),
        )
    }

    @Test
    fun `キャプションはUTF16で2000まで`() {
        assertEquals(emptyList(), validate(validDocWith("caption", FsValue.Str("あ".repeat(2000)))))
        assertEquals(listOf("OutOfRange" to "caption"), shapeOf(validate(validDocWith("caption", FsValue.Str("あ".repeat(2001))))))
        // 絵文字は 1 個で 2（rules の size() と同じ数え方）
        assertEquals(listOf("OutOfRange" to "caption"), shapeOf(validate(validDocWith("caption", FsValue.Str("😀".repeat(1001))))))
    }

    @Test
    fun `空のハッシュタグの配列は書かない`() {
        assertEquals(listOf("OutOfRange" to "hashtags"), shapeOf(validate(validDocWith("hashtags", FsValue.StrList(emptyList())))))
    }

    @Test
    fun `公開範囲と時間帯は列挙値だけ`() {
        // 公開範囲が変わると、画像のパス（public の下）とも食い違うので、2 枚の画像のパスも違反になる。
        // 違反の並びは契約の宣言順（images が visibility より前）
        assertEquals(
            (0..1).flatMap {
                listOf("OutOfRange" to "images[$it].storagePath", "OutOfRange" to "images[$it].thumbnailStoragePath")
            } + ("OutOfRange" to "visibility"),
            shapeOf(validate(validDocWith("visibility", FsValue.Str("Public")))),
        )
        assertEquals(listOf("OutOfRange" to "timeOfDay"), shapeOf(validate(validDocWith("timeOfDay", FsValue.Str("noon")))))
    }

    @Test
    fun `投稿IDはドキュメントIDと同値で、投稿者は自分のuid`() {
        val otherTarget = WriteTarget(documentId = "OTHER-POST-ID", authUid = uid)
        assertEquals(listOf("OutOfRange" to "postId"), shapeOf(validate(DocumentBuilders.postCreate(newPost()), otherTarget)))
        // 他人の uid で書こうとすると、userId の不一致になる（パスは文書の userId から作るので、パスの違反にはならない）
        val otherUser = WriteTarget(documentId = postId.value, authUid = Uid("OTHER-UID"))
        assertEquals(listOf("OutOfRange" to "userId"), shapeOf(validate(DocumentBuilders.postCreate(newPost()), otherUser)))
    }

    @Test
    fun `作成時のいいね数とコメント数は0だけ`() {
        assertEquals(listOf("OutOfRange" to "likesCount"), shapeOf(validate(validDocWith("likesCount", FsValue.Int64(1L)))))
        assertEquals(listOf("OutOfRange" to "commentsCount"), shapeOf(validate(validDocWith("commentsCount", FsValue.Int64(1L)))))
        // 加算で書く（作成でカウンタを動かす）書き方も許さない
        assertEquals(listOf("WrongKind" to "likesCount"), shapeOf(validate(validDocWith("likesCount", FsValue.Increment(1L)))))
    }

    @Test
    fun `画像の幅と高さは正、表示順は0から9`() {
        assertEquals(listOf("OutOfRange" to "images[0].width"), shapeOf(validate(validDocWithFirstImage("width", FsValue.Int64(0L)))))
        assertEquals(listOf("OutOfRange" to "images[0].height"), shapeOf(validate(validDocWithFirstImage("height", FsValue.Int64(-1L)))))
        assertEquals(listOf("OutOfRange" to "images[0].order"), shapeOf(validate(validDocWithFirstImage("order", FsValue.Int64(10L)))))
        assertEquals(listOf("OutOfRange" to "images[0].order"), shapeOf(validate(validDocWithFirstImage("order", FsValue.Int64(-1L)))))
    }

    @Test
    fun `画像のURLとサムネイルのURLはStorageのダウンロードURLの形だけ`() {
        // 契約の画像の URL の形（レビュー R14）。形の細かい境界は ValueConstraintTest が確かめる
        for (key in listOf("url", "thumbnail")) {
            assertEquals(
                listOf("OutOfRange" to "images[0].$key"),
                shapeOf(validate(validDocWithFirstImage(key, FsValue.Str("https://example.com/full-0.jpg")))),
                key,
            )
        }
    }

    @Test
    fun `画像のサムネイルと2つのパスは必須`() {
        for (key in listOf("url", "width", "height", "order", "thumbnail", "storagePath", "thumbnailStoragePath")) {
            assertEquals(listOf("MissingKey" to "images[0].$key"), shapeOf(validate(validDocWithFirstImage(key, null))), key)
        }
    }

    @Test
    fun `画像のパスは投稿者のuidの下で、ファイル名は1区切りで決まった接尾辞`() {
        val bad = listOf(
            "posts/OTHER-UID/public/IMG-0.jpg",          // 他人の uid
            "thumbnails/USER-UID-1/public/IMG-0.jpg",    // 本体の場所でない
            "posts/USER-UID-1/public/sub/IMG-0.jpg",     // 2 区切り
            "posts/USER-UID-1/public/.jpg",              // ファイル名が空
            "posts/USER-UID-1/public/IMG-0.png",         // 接尾辞が違う
            "posts/USER-UID-1/public/",
            "/posts/USER-UID-1/public/IMG-0.jpg",        // 先頭のスラッシュ
        )
        for (path in bad) {
            assertEquals(
                listOf("OutOfRange" to "images[0].storagePath"),
                shapeOf(validate(validDocWithFirstImage("storagePath", FsValue.Str(path)))),
                path,
            )
        }
        assertEquals(
            listOf("OutOfRange" to "images[0].thumbnailStoragePath"),
            shapeOf(validate(validDocWithFirstImage("thumbnailStoragePath", FsValue.Str("thumbnails/USER-UID-1/public/IMG-0.jpg")))),
        )
    }

    @Test
    fun `投稿者や公開範囲が読めないときはパスも違反にする`() {
        val doc = DocumentBuilders.postCreate(newPost(images = listOf(image(0)))) - "userId"
        assertEquals(
            listOf(
                "MissingKey" to "userId",
                "OutOfRange" to "images[0].storagePath",
                "OutOfRange" to "images[0].thumbnailStoragePath",
            ),
            shapeOf(validate(doc)),
        )
    }

    @Test
    fun `違反の説明にuidやパスを含めない`() {
        val doc = DocumentBuilders.postCreate(newPost(images = listOf(image(0, Visibility.PRIVATE, owner = "OTHER-UID"))))
        val details = validate(doc).filterIsInstance<Violation.OutOfRange>().map { it.detail }
        assertEquals(2, details.size)
        for (detail in details) {
            assertFalse("USER-UID-1" in detail || "OTHER-UID" in detail || "IMG-0" in detail, detail)
        }
    }

    // ============================================================
    // 投稿数
    // ============================================================

    @Test
    fun `投稿数はpostsCountだけを値で書き、両方の契約に合格する`() {
        val profileTarget = WriteTarget(documentId = uid.value, authUid = uid)
        val doc = DocumentBuilders.postsCount(12L)
        assertEquals(mapOf("postsCount" to FsValue.Int64(12L)), doc)
        assertEquals(emptyList(), AllowListShapeValidator.validate(ShapeContracts.USER_POSTS_COUNT, doc, profileTarget))
        assertEquals(emptyList(), AllowListShapeValidator.validate(ShapeContracts.PUBLIC_PROFILE_POSTS_COUNT, doc, profileTarget))
        assertEquals(emptyList(), AllowListShapeValidator.validate(ShapeContracts.USER_POSTS_COUNT, DocumentBuilders.postsCount(0L), profileTarget))
    }

    @Test
    fun `投稿数は負の値・加算・他のキーを許さない`() {
        val profileTarget = WriteTarget(documentId = uid.value, authUid = uid)
        for (contract in listOf(ShapeContracts.USER_POSTS_COUNT, ShapeContracts.PUBLIC_PROFILE_POSTS_COUNT)) {
            assertEquals(
                listOf("OutOfRange" to "postsCount"),
                shapeOf(AllowListShapeValidator.validate(contract, DocumentBuilders.postsCount(-1L), profileTarget)),
            )
            assertEquals(
                listOf("WrongKind" to "postsCount"),
                shapeOf(AllowListShapeValidator.validate(contract, mapOf("postsCount" to FsValue.Increment(1L)), profileTarget)),
            )
            assertEquals(
                listOf("UnexpectedKey" to "updatedAt"),
                shapeOf(AllowListShapeValidator.validate(contract, DocumentBuilders.postsCount(1L) + ("updatedAt" to FsValue.Time(now)), profileTarget)),
            )
        }
    }
}
