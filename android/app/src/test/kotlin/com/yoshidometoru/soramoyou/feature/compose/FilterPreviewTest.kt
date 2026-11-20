// ⭐️ フィルターの選択肢の並びの単体テスト（タスク 21.2・要件 6.6〜6.8）
package com.yoshidometoru.soramoyou.feature.compose

import com.yoshidometoru.soramoyou.contract.model.FilterId
import com.yoshidometoru.soramoyou.data.image.PreviewImage
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * フィルターの選択肢が「なし」を先頭に iOS と同じ並びであることと、見本の絵を受け取る形の FilterOptions の中身（並び・選択中・足りない見本の扱い）を確かめる。
 * 色は ViewModel が作った見本の絵で受け取るので、この部品は色の変換を持たない。
 */
class FilterPreviewTest {

    @Test
    fun `選択肢は「なし」が先頭で、続けてiOSと同じ並びの10種`() {
        assertEquals(
            listOf(
                null,
                FilterId.NATURAL,
                FilterId.CLEAR,
                FilterId.DRAMA,
                FilterId.SOFT,
                FilterId.WARM,
                FilterId.COOL,
                FilterId.VINTAGE,
                FilterId.MONOCHROME,
                FilterId.PASTEL,
                FilterId.VIVID,
            ),
            FILTER_OPTIONS,
        )
    }

    // ── 見本の絵を受け取る新しい形の FilterOptions（Kiro android-edit-tools タスク 13・A3・design.md:998・要件 2.5・13.8）──
    // :app に Compose の UI テストは無いので、並べる中身は純粋な関数（filterSampleOptions）で確かめ、
    // 部品がその関数を使い、選択中を枠と太字で示し、色を計算しないことは、FilterPreview.kt の書き方で確かめる

    /** 見本の絵を [count] 個（どれも別の実体。画素の値で見分けられる）。 */
    private fun sampleImages(count: Int): List<PreviewImage?> = List(count) { i -> PreviewImage(IntArray(1) { i }, 1, 1) }

    @Test
    fun `新しい形は、11個の見本をFILTER_OPTIONSの並びで1つずつ受け持つ`() {
        val samples = sampleImages(11)

        val options = filterSampleOptions(samples, selected = null)

        assertEquals(11, options.size)
        assertEquals(FILTER_OPTIONS, options.map { it.filter }, "並びは「なし」が先頭で、続けて iOS と同じ 10 種")
        options.forEachIndexed { i, option -> assertSame(samples[i], option.sample, "${option.filter} の見本は同じ位置の絵") }
    }

    @Test
    fun `新しい形の選択中は、選んだフィルターの1つだけ`() {
        val samples = sampleImages(11)
        FILTER_OPTIONS.forEach { selected ->
            assertEquals(
                listOf(selected),
                filterSampleOptions(samples, selected).filter { it.isSelected }.map { it.filter },
                "$selected を選んだとき",
            )
        }
    }

    @Test
    fun `新しい形は、見本が足りない所をnullにし、多すぎる分を使わない`() {
        assertTrue(filterSampleOptions(emptyList(), FilterId.VIVID).all { it.sample == null }, "まだ 1 つも描けていない")
        assertEquals(11, filterSampleOptions(emptyList(), FilterId.VIVID).size, "見本が無くても 11 個を並べる")

        val few = sampleImages(5)
        val fewOptions = filterSampleOptions(few, null)
        assertEquals(11, fewOptions.size)
        (0 until 5).forEach { assertSame(few[it], fewOptions[it].sample) }
        assertTrue(fewOptions.drop(5).all { it.sample == null }, "足りない所は null")

        val many = sampleImages(13)
        val manyOptions = filterSampleOptions(many, null)
        assertEquals(11, manyOptions.size, "多すぎる分は使わない")
        (0 until 11).forEach { assertSame(many[it], manyOptions[it].sample) }
    }

    @Test
    fun `新しい形の部品は、並べる中身を純粋な関数から取り、選択中を枠と太字で示し、色を計算しない`() {
        val source = File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/compose/FilterPreview.kt")
        assertTrue(source.isFile, "FilterPreview.kt が見つからない: ${source.absolutePath}")
        val code = source.readText().replace(BLOCK_COMMENT, "").replace(LINE_COMMENT, "")
        // 見本の絵を受け取る形（最初の 2 つの引数が selected と samples）はちょうど 1 つ
        val signatures = NEW_FORM_SIGNATURE.findAll(code).toList()
        assertEquals(1, signatures.size, "見本の絵を受け取る形の FilterOptions がちょうど 1 つではない")
        val body = blockFrom(code, signatures.single().range.last + 1)

        // 並べる中身は filterSampleOptions から（テストで確かめた関数と画面が切れていない）
        assertTrue("filterSampleOptions(samples, selected)" in body, "並べる中身を filterSampleOptions から取っていない")
        // 1 つだけを選ぶ組（ラジオボタン）として読ませる
        assertTrue(".selectableGroup()" in body, "選択肢の組になっていない")
        assertTrue("role = Role.RadioButton" in body, "選択肢をラジオボタンとして読ませていない")
        // 選択中は枠と太字（色だけに頼らない：要件 13.8）
        assertTrue(".border(" in body && "option.isSelected" in body, "選択中に枠を描いていない")
        assertTrue("FontWeight.Bold" in body, "選択中の名前を太字にしていない")
        // 色を計算しない・写真を自分で読まない（受け取った見本の絵を描くだけ）
        listOf("colorFilter", "ColorKernel", "AsyncImage").forEach {
            assertFalse(it in body, "新しい形の部品が $it を使っている（色は ViewModel が作った見本の絵だけ）")
        }
    }

    private companion object {
        /** 見本の絵を受け取る形の FilterOptions の宣言の始まり。 */
        val NEW_FORM_SIGNATURE = Regex("""fun\s+FilterOptions\s*\(\s*selected\s*:\s*FilterId\?\s*,\s*samples\s*:""")

        /** ブロックコメント（KDoc を含む）。行コメントより先に消す（PostPublishedDialogSourceTest と同じ除き方）。 */
        val BLOCK_COMMENT = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)

        /** 行コメント（`//` から行末まで）。 */
        val LINE_COMMENT = Regex("""//[^\n]*""")

        /** [code] の [start] より後に最初に現れる `{` から、対応する `}` までの塊（関数の本体）。 */
        fun blockFrom(code: String, start: Int): String {
            val begin = code.indexOf('{', start)
            check(begin >= 0) { "関数の本体の { が無い" }
            var depth = 0
            for (i in begin until code.length) {
                when (code[i]) {
                    '{' -> depth++
                    '}' -> if (--depth == 0) return code.substring(begin, i + 1)
                }
            }
            error("関数の本体の { に対応する } が無い")
        }
    }
}
