// ⭐️ ハッシュタグ抽出の単体テスト（タスク 20.1・要件 7.7・7.8）
package com.yoshidometoru.soramoyou.contract.rules

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * [HashtagExtractor] が、iOS 版の `#(\w+)`（NSRegularExpression＝ICU）と同じ結果を返すことを確かめる。
 *
 * 根拠（読んだ現物）:
 * - iOS 版：Soramoyou/Soramoyou/ViewModels/PostViewModel.swift:194-207（`#(\w+)` の 1 番目の捕獲を、出現順・重複込みで配列にする）
 * - rules：firestore.rules:34-37（`hashtags.size() <= 30`）
 *
 * 期待値の作り方：下の全ベクタを Swift 6.4（macOS 27）で iOS と同じコードに流して実測した（推測ではない）。
 * 実測の結果と使ったコードは手元（git の外）の `20.1-golden_swift64.tsv`・`20.1-golden.swift`
 * （BMP の外の漢字の 3 本は `rv4-B7-swift.tsv`・`rv4-B7-swift.swift`。同じ書き方の `#(\w+)`）。
 * 絵文字は直感と違う結果になる（キーキャップはタグになり、晴れマーク・国旗・肌色はならない）ので、特に推測で書かない。
 *
 * 目に見えない文字（ZWJ・異体字セレクタ・結合文字・NBSP・全角空白など）は、取り違えの防止のため
 * ソースに直書きせずコードポイント（[cps]）で組み立てる。
 */
class HashtagExtractorTest {

    private val extractor: HashtagExtractor = HashtagExtractor.Default

    /** コードポイントの並びから文字列を作る。 */
    private fun cps(vararg codePoints: Int): String = buildString { codePoints.forEach { appendCodePoint(it) } }

    private fun assertExtracts(caption: String, vararg expected: String) =
        assertEquals(expected.toList(), extractor.extract(caption), "入力: $caption")

    // ---- 日本語 ----

    @Test
    fun `ひらがな・カタカナ・漢字・長音記号をタグに含める`() {
        assertExtracts("#そら きれい", "そら")
        assertExtracts("#ソラモヨウ", "ソラモヨウ")
        assertExtracts("今日の#夕焼け空。", "夕焼け空")
        assertExtracts("#ブルーアワー", "ブルーアワー")              // 長音記号 U+30FC は Alphabetic
        assertExtracts("#空sky123_夕", "空sky123_夕")
    }

    @Test
    fun `全角の数字・英字・アンダースコアをタグに含める`() {
        assertExtracts("#１２３", "１２３")
        assertExtracts("#ＳＫＹ", "ＳＫＹ")
        assertExtracts("#a＿b", "a＿b")                            // 全角アンダースコア U+FF3F は Connector_Punctuation
        assertExtracts("#blue_sky", "blue_sky")
    }

    @Test
    fun `結合濁点はタグの一部になり、元の文字列のまま返す`() {
        // か + 結合濁点（U+3099）。合成済みの「が」に正規化しない
        assertExtracts(cps('#'.code, 0x304B, 0x3099), cps(0x304B, 0x3099))
    }

    // ---- 区切り ----

    @Test
    fun `句読点・記号でタグが終わる`() {
        assertExtracts("#夕焼け。", "夕焼け")
        assertExtracts("#夕焼け、#朝焼け", "夕焼け", "朝焼け")
        assertExtracts("#空!", "空")
        assertExtracts("#sky.blue", "sky")
        assertExtracts("#sky-blue", "sky")
        assertExtracts("#空・雲", "空")                             // 中黒 U+30FB は単語文字でない
        assertExtracts("#a\$b", "a")
    }

    @Test
    fun `空白・改行・全角空白・NBSPでタグが終わる`() {
        assertExtracts("#a #b  #c", "a", "b", "c")
        assertExtracts("#空\n#雲", "空", "雲")
        assertExtracts(cps('#'.code, 0x7A7A, 0x3000, '#'.code, 0x96F2), "空", "雲")
        assertExtracts(cps('#'.code, 0x7A7A, 0x00A0, '#'.code, 0x96F2), "空", "雲")
    }

    @Test
    fun `連続したタグを別々に取る`() {
        assertExtracts("#夕焼け#朝焼け", "夕焼け", "朝焼け")
    }

    // ---- # の扱い ----

    @Test
    fun `二重のシャープは2つ目からタグになる`() {
        assertExtracts("##abc", "abc")
    }

    @Test
    fun `単語の途中のシャープからもタグになる`() {
        // iOS の正規表現には単語境界の条件が無い
        assertExtracts("abc#def", "def")
    }

    @Test
    fun `シャープの後に単語文字が無ければ取らない`() {
        assertExtracts("#")
        assertExtracts("空 #")
        assertExtracts("# 空")
        assertExtracts("")
        assertExtracts("空がきれい")
    }

    @Test
    fun `全角のシャープはタグの始まりにならない`() {
        assertExtracts("＃空")
    }

    // ---- 正規化しない・重複を残す ----

    @Test
    fun `重複を除かず出現順に返す`() {
        assertExtracts("#空 #空 #雲 #空", "空", "空", "雲", "空")
    }

    @Test
    fun `大文字小文字を区別して元のまま返す`() {
        assertExtracts("#Sky #sky", "Sky", "sky")
    }

    // ---- 絵文字（iOS の実測どおり） ----

    @Test
    fun `絵文字は単語文字でないのでタグを終わらせる`() {
        assertExtracts("#😀")
        assertExtracts("#空😀", "空")
        assertExtracts("#😀空")
        assertExtracts(cps('#'.code, 0x2600, 0xFE0F))               // ☀️（U+2600 は記号。異体字セレクタだけでは始まらない）
        assertExtracts(cps('#'.code, 0x2600, 0xFE0F, 0x7A7A))
        assertExtracts(cps('#'.code, 0x1F1EF, 0x1F1F5))             // 🇯🇵（地域指示記号は単語文字でない）
        assertExtracts(cps('#'.code, 0x1F44D, 0x1F3FD))             // 👍🏽
    }

    @Test
    fun `キーキャップの絵文字はタグになる`() {
        // 1（Decimal_Number）＋U+FE0F（Mark）＋U+20E3（Mark）がすべて単語文字
        assertExtracts(cps('#'.code, 0x31, 0xFE0F, 0x20E3), cps(0x31, 0xFE0F, 0x20E3))
    }

    @Test
    fun `ゼロ幅接合子はタグの一部になる`() {
        assertExtracts(cps('#'.code, 0x61, 0x200D, 0x62), cps(0x61, 0x200D, 0x62))
    }

    // ---- 他の文字体系・数字 ----

    @Test
    fun `他の文字体系と10進数字をタグに含め、丸数字は含めない`() {
        assertExtracts("#하늘", "하늘")
        assertExtracts("#café", "café")
        assertExtracts(cps('#'.code, 0x0661, 0x0662), cps(0x0661, 0x0662))   // アラビア・インド数字（Decimal_Number）
        assertExtracts("#Ⅻ", "Ⅻ")                                  // ローマ数字 U+216B は Alphabetic
        assertExtracts("#①")                                        // 丸数字 U+2460 は Other_Number で単語文字でない
    }

    @Test
    fun `BMPの外の漢字（CJK拡張B）をタグに含め、代用対の途中で切らない`() {
        // 𠮷（U+20BB7）・𩸽（U+29E3D）は UTF-16 で 2 つの Char（代用対）。Char ずつ見ると代用対の半分で止まり、タグを取り損ねる
        assertExtracts(cps('#'.code, 0x20BB7, 0x91CE, 0x5BB6), cps(0x20BB7, 0x91CE, 0x5BB6))            // #𠮷野家
        assertExtracts(cps('#'.code, 0x7A7A, 0x20BB7, 0x1F600), cps(0x7A7A, 0x20BB7))                    // #空𠮷😀（絵文字で終わる）
        assertExtracts(cps('#'.code, 0x29E3D, 0x20, '#'.code, 0x20BB7), cps(0x29E3D), cps(0x20BB7))      // #𩸽 #𠮷（1 字のタグが 2 つ）
    }

    // ---- 30 個の判定 ----

    @Test
    fun `ハッシュタグは30個までなら投稿を確定できる`() {
        assertTrue(TextLimits.isHashtagCountWithinLimit(emptyList()))
        assertTrue(TextLimits.isHashtagCountWithinLimit(List(30) { "空$it" }))
        assertFalse(TextLimits.isHashtagCountWithinLimit(List(31) { "空$it" }))
    }

    @Test
    fun `30個の判定は重複も数える`() {
        // rules の size() は配列の長さなので、同じタグの重複も 1 個ずつ数える
        val caption = (1..31).joinToString(" ") { "#空" }
        val tags = extractor.extract(caption)
        assertEquals(31, tags.size)
        assertFalse(TextLimits.isHashtagCountWithinLimit(tags))
    }
}
