// ⭐️ 編集ツールの内部の名前・表示名・並びの単体テスト（Kiro android-edit-tools タスク 5・C2・要件 1.3）
package com.yoshidometoru.soramoyou.contract.edit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame

/**
 * [EditTool] の 11 個が iOS の `EditTool.swift`（origin/main 9bed5a4a の
 * `Soramoyou/Soramoyou/Models/EditTool.swift`）と 1 文字も違わないことを確かめる。
 * 期待値は iOS のファイルを読んで **ここに文字で書いた**（本体の定義から作っていない）。
 * iOS の `case` の並び（12-38 行）から範囲外の 16 個を抜いた順、`displayName`（41-69 行）の文字列。
 */
class EditToolTest {

    /** (内部の名前, 表示名, スライダーか)。iOS の並び順 */
    private val expected = listOf(
        Triple("exposure", "露出", true),
        Triple("brightness", "明るさ", true),
        Triple("contrast", "コントラスト", true),
        Triple("blackPoint", "ブラックポイント", true),
        Triple("saturation", "彩度", true),
        Triple("warmth", "暖かみ", true),
        Triple("tint", "色合い", true),
        Triple("colorTemperature", "色温度", true),
        Triple("whiteBalance", "ホワイトバランス", true),
        Triple("fade", "フェード", true),
        Triple("cropAndRotate", "トリミング・回転", false),
    )

    /** iOS の EditTool にあって、本仕様の範囲外の 16 個（iOS の case の名前そのまま） */
    private val outOfScope = listOf(
        "tone", "brilliance", "highlight", "shadow", "naturalSaturation", "sharpness", "vignette",
        "texture", "clarity", "dehaze", "grain", "noiseReduction", "curves", "hsl", "lensCorrection", "doubleExposure",
    )

    @Test
    fun `ツールは 11 個`() {
        assertEquals(11, EditTool.entries.size)
        assertEquals(16, outOfScope.size)
    }

    @Test
    fun `内部の名前・表示名・スライダーかどうかと並びは iOS と同じ`() {
        assertEquals(expected, EditTool.entries.map { Triple(it.raw, it.displayName, it.isSlider) })
    }

    @Test
    fun `内部の名前から同じツールが引ける`() {
        for ((raw, _, _) in expected) {
            assertEquals(raw, EditTool.fromRaw(raw)?.raw, raw)
        }
        // 引いたものは列挙の同じ位置のもの
        expected.forEachIndexed { i, (raw, _, _) -> assertSame(EditTool.entries[i], EditTool.fromRaw(raw), raw) }
    }

    @Test
    fun `範囲外の 16 個の名前は引けない`() {
        for (raw in outOfScope) assertNull(EditTool.fromRaw(raw), raw)
    }

    @Test
    fun `知らない名前・null・大文字小文字違い・空白付きは引けない`() {
        assertNull(EditTool.fromRaw(null))
        assertNull(EditTool.fromRaw(""))
        assertNull(EditTool.fromRaw("unknown"))
        assertNull(EditTool.fromRaw("Exposure"))
        assertNull(EditTool.fromRaw("EXPOSURE"))
        assertNull(EditTool.fromRaw("exposure "))
        assertNull(EditTool.fromRaw(" exposure"))
        assertNull(EditTool.fromRaw("colortemperature"))
        // 表示名では引けない
        assertNull(EditTool.fromRaw("露出"))
    }

    @Test
    fun `スライダーの範囲は百分の 1 で ±100`() {
        assertEquals(-100, EditTool.MIN)
        assertEquals(100, EditTool.MAX)
    }

    @Test
    fun `スライダーでないのはトリミング・回転だけ`() {
        assertEquals(listOf("cropAndRotate"), EditTool.entries.filter { !it.isSlider }.map { it.raw })
    }
}
