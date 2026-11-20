// ⭐️ 下書き・編集の途中・装備の文書の変換の単体テスト（Kiro android-edit-tools タスク 6・C3・design.md:1027-1051）
package com.yoshidometoru.soramoyou.contract.edit

import com.yoshidometoru.soramoyou.contract.model.FilterId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * [EditDocumentCodec] の往復・読み込みの検査・書く鍵の集合を確かめる。
 *
 * 陽性対照（壊す場所は EditDocumentCodec.kt）：
 * - 版の検査（`isReadableVersion` の `v in 1..VERSION`）を外す → 「版が新しすぎる文書は null」が赤
 * - `isSafeRelativePath` の `..` の検査を外す → 「.. の場所を読まない」が赤
 */
class EditDocumentCodecTest {

    private fun photo(
        file: String = "drafts/ABC/photo-0",
        edit: PhotoEdit = PhotoEdit.NONE,
        capturedAt: Long? = null,
        source: String = "none",
    ) = EditWorkPhoto(file, capturedAt, source, edit)

    private fun doc(photos: List<EditWorkPhoto>, draftId: String? = "D1", sessionId: String = "S1") = EditWorkDocument(
        sessionId = sessionId,
        draftId = draftId,
        savedAtEpochMillis = 1_794_400_000_000L,
        caption = "夕焼け #sky\n二行目",
        visibilityRaw = "public",
        enteredInfo = true,
        photos = photos,
    )

    /** 全部入りの編集 */
    private val fullEdit = PhotoEdit(
        filter = FilterId.WARM,
        tools = ToolValues.NONE.with(EditTool.EXPOSURE, 25).with(EditTool.FADE, -100).with(EditTool.TINT, 7),
        geometry = EditGeometry(quarterTurns = 3, crop = NormalizedRect(0.1, 0.1, 0.9, 0.95)),
    )

    /** 正しい最小の文書（写真 1 枚・編集なし） */
    private fun minimalMap(): MutableMap<String, String> = mutableMapOf(
        "version" to "1",
        "savedAt" to "123",
        "caption" to "",
        "visibility" to "public",
        "enteredInfo" to "false",
        "photo.count" to "1",
        "photo.0.file" to "drafts/A/photo-0",
    )

    // ---- 装備 ----

    @Test
    fun `装備の往復で等しい`() {
        val loadout = Loadout(listOf(EditTool.FADE, EditTool.EXPOSURE, EditTool.CROP_AND_ROTATE))
        assertEquals(loadout, EditDocumentCodec.decodeLoadout(EditDocumentCodec.encodeLoadout(loadout)))
        assertEquals(Loadout.DEFAULT, EditDocumentCodec.decodeLoadout(EditDocumentCodec.encodeLoadout(Loadout.DEFAULT)))
    }

    @Test
    fun `装備の文書は version と tools だけ`() {
        val map = EditDocumentCodec.encodeLoadout(Loadout(listOf(EditTool.EXPOSURE, EditTool.TINT)))
        assertEquals(setOf("version", "tools"), map.keys)
        assertEquals("1", map["version"])
        assertEquals("exposure,tint", map["tools"])
    }

    @Test
    fun `装備が読めなければ既定`() {
        assertEquals(Loadout.DEFAULT, EditDocumentCodec.decodeLoadout(emptyMap()))
        assertEquals(Loadout.DEFAULT, EditDocumentCodec.decodeLoadout(mapOf("tools" to "exposure")))            // 版なし
        assertEquals(Loadout.DEFAULT, EditDocumentCodec.decodeLoadout(mapOf("version" to "2", "tools" to "exposure")))  // 新しすぎる
        assertEquals(Loadout.DEFAULT, EditDocumentCodec.decodeLoadout(mapOf("version" to "x", "tools" to "exposure")))
        assertEquals(Loadout.DEFAULT, EditDocumentCodec.decodeLoadout(mapOf("version" to "1")))                  // tools なし
        assertEquals(Loadout.DEFAULT, EditDocumentCodec.decodeLoadout(mapOf("version" to "1", "tools" to "")))
        assertEquals(Loadout.DEFAULT, EditDocumentCodec.decodeLoadout(mapOf("version" to "1", "tools" to "a,b")))
    }

    @Test
    fun `装備の知らない名前と重複を捨てて知らない鍵を読み飛ばす`() {
        val map = mapOf("version" to "1", "tools" to "tint,zzz,exposure,tint", "future" to "1")
        assertEquals(Loadout(listOf(EditTool.TINT, EditTool.EXPOSURE)), EditDocumentCodec.decodeLoadout(map))
    }

    // ---- 文書の往復 ----

    @Test
    fun `文書の往復で等しい`() {
        val original = doc(
            listOf(
                photo("drafts/D1/photo-0", fullEdit, capturedAt = 1_700_000_000_000L, source = "exif"),
                photo("drafts/D1/photo-1", PhotoEdit.NONE, capturedAt = null, source = "none"),
                photo("session/photo-2", PhotoEdit(filter = FilterId.VIVID), capturedAt = 5L, source = "asset"),
            ),
        )
        assertEquals(original, EditDocumentCodec.decodeWork(EditDocumentCodec.encodeWork(original)))
    }

    @Test
    fun `新しい編集は draftId が null のまま往復する`() {
        val original = doc(listOf(photo()), draftId = null)
        val back = EditDocumentCodec.decodeWork(EditDocumentCodec.encodeWork(original))
        assertNotNull(back)
        assertNull(back.draftId)
        assertEquals(original, back)
    }

    @Test
    fun `十枚まで往復できる`() {
        val original = doc((0 until 10).map { photo("session/photo-$it") })
        assertEquals(original, EditDocumentCodec.decodeWork(EditDocumentCodec.encodeWork(original)))
    }

    // ---- 書く鍵 ----

    @Test
    fun `編集なしの写真は file と capturedAtSource の鍵だけを書く`() {
        val map = EditDocumentCodec.encodeWork(doc(listOf(photo())))
        assertEquals(
            setOf(
                "version", "sessionId", "draftId", "savedAt", "caption", "visibility", "enteredInfo",
                "photo.count", "photo.0.file", "photo.0.capturedAtSource",
            ),
            map.keys,
        )
    }

    @Test
    fun `全部入りの写真の鍵は設計の表のとおり`() {
        val map = EditDocumentCodec.encodeWork(doc(listOf(photo(edit = fullEdit, capturedAt = 9L, source = "exif"))))
        assertEquals("1", map["version"])
        assertEquals("exif", map["photo.0.capturedAtSource"])
        assertEquals("9", map["photo.0.capturedAt"])
        assertEquals("warm", map["photo.0.filter"])
        assertEquals("25", map["photo.0.tool.exposure"])
        assertEquals("-100", map["photo.0.tool.fade"])
        assertEquals("7", map["photo.0.tool.tint"])
        assertEquals("3", map["photo.0.turns"])
        assertEquals("0.1,0.1,0.9,0.95", map["photo.0.crop"])
    }

    @Test
    fun `0のツールは書かない`() {
        val edit = PhotoEdit(tools = ToolValues.NONE.with(EditTool.EXPOSURE, 10).with(EditTool.EXPOSURE, 0))
        val map = EditDocumentCodec.encodeWork(doc(listOf(photo(edit = edit))))
        assertTrue(map.keys.none { it.startsWith("photo.0.tool.") }, map.keys.toString())
    }

    @Test
    fun `ハッシュタグと履歴の鍵を書かない`() {
        val map = EditDocumentCodec.encodeWork(doc(listOf(photo(edit = fullEdit))))
        val lower = map.keys.map { it.lowercase() }
        assertTrue(lower.none { "hashtag" in it || "history" in it || "undo" in it || "redo" in it }, lower.toString())
        // 装備の文書にも入らない
        assertEquals(setOf("version", "tools"), EditDocumentCodec.encodeLoadout(Loadout.DEFAULT).keys)
    }

    // ---- 読めない文書は null ----

    @Test
    fun `最小の文書は読める`() {
        val back = EditDocumentCodec.decodeWork(minimalMap())
        assertNotNull(back)
        assertEquals("", back.sessionId)            // sessionId の鍵は必須でない
        assertNull(back.draftId)
        assertEquals("none", back.photos[0].capturedAtSourceRaw)
        assertEquals(PhotoEdit.NONE, back.photos[0].edit)
    }

    @Test
    fun `版が新しすぎる文書は null`() {
        assertNull(EditDocumentCodec.decodeWork(minimalMap().apply { put("version", (EditDocumentCodec.VERSION + 1).toString()) }))
    }

    @Test
    fun `版が無い・読めない・0以下の文書は null`() {
        assertNull(EditDocumentCodec.decodeWork(minimalMap().apply { remove("version") }))
        assertNull(EditDocumentCodec.decodeWork(minimalMap().apply { put("version", "abc") }))
        assertNull(EditDocumentCodec.decodeWork(minimalMap().apply { put("version", "0") }))
    }

    @Test
    fun `必須の鍵が無い文書は null`() {
        for (key in listOf("savedAt", "caption", "visibility", "enteredInfo", "photo.count", "photo.0.file")) {
            assertNull(EditDocumentCodec.decodeWork(minimalMap().apply { remove(key) }), "鍵 $key が無い")
        }
    }

    @Test
    fun `必須の鍵の値が読めない文書は null`() {
        assertNull(EditDocumentCodec.decodeWork(minimalMap().apply { put("savedAt", "x") }))
        assertNull(EditDocumentCodec.decodeWork(minimalMap().apply { put("enteredInfo", "yes") }))
        assertNull(EditDocumentCodec.decodeWork(minimalMap().apply { put("photo.count", "x") }))
    }

    @Test
    fun `写真が0枚・範囲の外の文書は null`() {
        assertNull(EditDocumentCodec.decodeWork(minimalMap().apply { put("photo.count", "0") }))
        assertNull(EditDocumentCodec.decodeWork(minimalMap().apply { put("photo.count", "-1") }))
        assertNull(EditDocumentCodec.decodeWork(minimalMap().apply { put("photo.count", "11") }))
        // encode でも 0 枚の文書は読み戻せない
        assertNull(EditDocumentCodec.decodeWork(EditDocumentCodec.encodeWork(doc(emptyList()))))
    }

    @Test
    fun `写真の数より少ない file しか無い文書は null`() {
        assertNull(EditDocumentCodec.decodeWork(minimalMap().apply { put("photo.count", "2") }))
    }

    @Test
    fun `知らない鍵は読み飛ばす`() {
        val map = minimalMap().apply {
            put("future.key", "1")
            put("photo.0.future", "x")
            put("photo.0.tool.unknownTool", "10")
            put("photo.0.tool.cropAndRotate", "10")   // スライダーでないツールの鍵も知らない鍵と同じ
            put("photo.5.file", "a")                  // 枚数の外の写真
        }
        val back = EditDocumentCodec.decodeWork(map)
        assertNotNull(back)
        assertEquals(1, back.photos.size)
        assertEquals(PhotoEdit.NONE, back.photos[0].edit)
    }

    // ---- file の検査 ----

    @Test
    fun `dotdot の場所を読まない`() {
        for (bad in listOf("../x", "a/../b", "drafts/..", "..", "a/../../b")) {
            assertNull(
                EditDocumentCodec.decodeWork(minimalMap().apply { put("photo.0.file", bad) }),
                "読んではいけない場所: $bad",
            )
        }
    }

    @Test
    fun `絶対の場所を読まない`() {
        for (bad in listOf("/etc/passwd", "/data/x", "C:\\x", "C:/x", "a\\b", "", "   ")) {
            assertNull(
                EditDocumentCodec.decodeWork(minimalMap().apply { put("photo.0.file", bad) }),
                "読んではいけない場所: $bad",
            )
        }
    }

    @Test
    fun `2枚目の file が危なくても文書ぜんたいを読まない`() {
        val map = minimalMap().apply {
            put("photo.count", "2")
            put("photo.1.file", "../escape")
        }
        assertNull(EditDocumentCodec.decodeWork(map))
    }

    @Test
    fun `名前に dot を含むだけの場所は読める`() {
        val back = EditDocumentCodec.decodeWork(minimalMap().apply { put("photo.0.file", "drafts/a..b/photo.0") })
        assertNotNull(back)
        assertEquals("drafts/a..b/photo.0", back.photos[0].file)
    }

    // ---- 壊れた編集は NONE で写真を残す ----

    private fun brokenKeepsPhoto(key: String, value: String) {
        // 壊れていない別の写真（1 枚目）の編集は生きたまま、壊れた 2 枚目だけ NONE になる
        val map = minimalMap().apply {
            put("photo.count", "2")
            put("photo.0.filter", "drama")
            put("photo.1.file", "drafts/A/photo-1")
            put("photo.1.capturedAt", "42")
            put("photo.1.capturedAtSource", "exif")
            // 壊れていない値を同じ写真に混ぜて、一部が生きたままにならないことも見る
            put("photo.1.tool.exposure", "30")
            put("photo.1.$key", value)
        }
        val back = EditDocumentCodec.decodeWork(map)
        assertNotNull(back, "$key=$value")
        assertEquals(2, back.photos.size, "$key=$value")
        assertEquals(PhotoEdit(filter = FilterId.DRAMA), back.photos[0].edit, "1 枚目は生きる")
        assertEquals(PhotoEdit.NONE, back.photos[1].edit, "$key=$value")
        assertEquals("drafts/A/photo-1", back.photos[1].file, "写真は残る")
        assertEquals(42L, back.photos[1].capturedAtEpochMillis)
        assertEquals("exif", back.photos[1].capturedAtSourceRaw)
    }

    @Test
    fun `壊れた編集は NONE にして写真を残す`() {
        brokenKeepsPhoto("filter", "nonexistent")
        brokenKeepsPhoto("tool.contrast", "abc")
        brokenKeepsPhoto("tool.contrast", "101")
        brokenKeepsPhoto("tool.contrast", "-101")
        brokenKeepsPhoto("turns", "4")
        brokenKeepsPhoto("turns", "-1")
        brokenKeepsPhoto("turns", "x")
        brokenKeepsPhoto("crop", "0.1,0.1,0.9")
        brokenKeepsPhoto("crop", "a,b,c,d")
        brokenKeepsPhoto("crop", "0.5,0.1,0.4,0.9")     // 左 > 右
        brokenKeepsPhoto("crop", "0.1,0.5,0.9,0.5")     // 上 = 下
        brokenKeepsPhoto("crop", "-0.1,0.0,1.0,1.0")    // 範囲の外
        brokenKeepsPhoto("crop", "0.0,0.0,1.1,1.0")
        brokenKeepsPhoto("crop", "NaN,0.0,1.0,1.0")
    }

    @Test
    fun `読めない撮影日時は撮影日時なしで写真を残す`() {
        val back = EditDocumentCodec.decodeWork(minimalMap().apply { put("photo.0.capturedAt", "x") })
        assertNotNull(back)
        assertNull(back.photos[0].capturedAtEpochMillis)
    }

    @Test
    fun `範囲の中の編集の鍵は読む`() {
        val map = minimalMap().apply {
            put("photo.0.filter", "monochrome")
            put("photo.0.tool.saturation", "-100")
            put("photo.0.tool.blackPoint", "100")
            put("photo.0.turns", "2")
            put("photo.0.crop", "0.0,0.25,1.0,0.75")
        }
        val back = EditDocumentCodec.decodeWork(map)
        assertNotNull(back)
        val expected = PhotoEdit(
            filter = FilterId.MONOCHROME,
            tools = ToolValues.NONE.with(EditTool.SATURATION, -100).with(EditTool.BLACK_POINT, 100),
            geometry = EditGeometry(2, NormalizedRect(0.0, 0.25, 1.0, 0.75)),
        )
        assertEquals(expected, back.photos[0].edit)
    }
}
