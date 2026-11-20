// ⭐️ 入力の上限・書記素の数え方・空白だけの判定の単体テスト（タスク 13.1・23.2・要件 2.6・7.6・10.10）
package com.yoshidometoru.soramoyou.contract.rules

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * 書記素のテストを流してよい JDK の版の下限。JDK の `BreakIterator` が拡張書記素クラスタ（UAX #29）に対応したのは JDK 20 から
 * （[TextLimits.graphemeCount] の KDoc）。`:contract` はテストの JDK を固定していない（toolchain なし）ので、テストの側で確かめる。
 */
private const val GRAPHEME_JDK_MIN = 20

/**
 * [TextLimits] の定数・書記素クラスタの数え方・空白だけかどうかの判定を、iOS 版と rules の値に固定する。
 *
 * 根拠（読んだ現物）:
 * - パスワード 6 文字：Soramoyou/Soramoyou/Services/AuthService.swift:51（`password.count >= 6`。Swift の `count` は書記素クラスタの数）
 * - 表示名 50・自己紹介 200：Soramoyou/Soramoyou/ViewModels/ProfileViewModel.swift:743-744（`editingDisplayName.count <= 50`・`editingBio.count <= 200`）
 * - キャプション 2000・ハッシュタグ 30・画像 1〜10：firestore.rules の `isValidCaption`・`isValidHashtags`・`isValidPost`
 * - フィードバック 1000：firestore.rules の feedback の create、Soramoyou/Soramoyou/Models/Feedback.swift:62
 * - 空白だけの判定：iOS は `trimmingCharacters(in: .whitespacesAndNewlines)` で判定する（Feedback.swift:62、PostViewModel.swift:859）
 *
 * 書記素の期待値は、同じ文字列を Swift 6.4（macOS 27）の `String.count` に流して実測した値である（実装の出力ではない）。
 * 空白の集合は、`CharacterSet.whitespacesAndNewlines` に全 Unicode スカラー値（0〜0x10FFFF）を 1 つずつ当てて実測した。
 *
 * 絵文字・結合文字・各種の空白は、読みやすさと取り違えの防止のため、ソースに直書きせずコードポイント（[cps]）で組み立てる。
 *
 * ZWJ・肌色・国旗のベクタを含むテストは、先頭で [requireGraphemeJdk] を呼ぶ。JDK 19 以前の `BreakIterator` はそれらを 1 つに数えないので、
 * 本体の誤りと見分けのつく文で落とす（JDK 17〜19 では流していない。そこでの赤は推定）。
 */
class TextLimitsTest {

    /** コードポイントの並びから文字列を作る。対にならない代用対（0xD800〜0xDFFF）も、そのまま 1 文字として入れる。 */
    private fun cps(vararg codePoints: Int): String = buildString { codePoints.forEach { appendCodePoint(it) } }

    /**
     * テストの JVM が [GRAPHEME_JDK_MIN] 以上でなければ、「JDK を替えて流すこと」と分かる文で落とす。
     * Assume で飛ばさないのは、飛ばすと緑に見えて、数え方を確かめていないことに気づけないため。
     */
    private fun requireGraphemeJdk() {
        val feature = Runtime.version().feature()
        if (feature < GRAPHEME_JDK_MIN) {
            fail(
                "書記素のテストは JDK $GRAPHEME_JDK_MIN 以上で流すこと（いまの JDK は $feature）。" +
                    "それより前の JDK の BreakIterator は拡張書記素クラスタ（UAX #29）に対応していない",
            )
        }
    }

    private val thumbsUpWithSkinTone = cps(0x1F44D, 0x1F3FD)                                     // 肌色の修飾つきの親指（UTF-16 で 4 文字・書記素 1）
    private val familyZwj = cps(0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466)       // ZWJ で連結した家族（UTF-16 で 11・書記素 1）
    private val flagJapan = cps(0x1F1EF, 0x1F1F5)                                                  // 国旗（UTF-16 で 4・書記素 1）
    private val eAcuteDecomposed = cps(0x65, 0x301)                                                // e + 結合アクセント（UTF-16 で 2・書記素 1）
    private val ideographicSpace = cps(0x3000)                                                     // 全角空白

    /** 失敗メッセージ用。 */
    private fun describe(text: String): String = text.map { "<U+%04X>".format(it.code) }.joinToString("")

    // ---- 定数 ----

    @Test
    fun `定数はiOSとrulesの値と一致する`() {
        assertEquals(6, TextLimits.PASSWORD_MIN)          // AuthService.swift:51
        assertEquals(50, TextLimits.DISPLAY_NAME_MAX)     // ProfileViewModel.swift:743
        assertEquals(200, TextLimits.BIO_MAX)             // ProfileViewModel.swift:744
        assertEquals(2000, TextLimits.CAPTION_MAX)        // firestore.rules の isValidCaption
        assertEquals(30, TextLimits.HASHTAGS_MAX)         // firestore.rules の isValidHashtags
        assertEquals(1000, TextLimits.FEEDBACK_MAX)       // firestore.rules の feedback の create
        assertEquals(1, TextLimits.IMAGES_MIN)            // firestore.rules の isValidPost
        assertEquals(10, TextLimits.IMAGES_MAX)           // firestore.rules の isValidPost
    }

    // ---- 書記素クラスタの数え方（iOS の String.count と一致すること） ----

    @Test
    fun `書記素の数はSwiftのStringのcountと一致する`() {
        requireGraphemeJdk()
        // （文字列, 期待する書記素の数）。期待値は Swift 6.4 の String.count の実測
        val vectors = listOf(
            "" to 0,
            "abc" to 3,
            "あいう" to 3,
            "空の😀写真" to 5,
            eAcuteDecomposed to 1,                                       // 結合文字
            cps(0x304B, 0x3099) to 1,                                    // か + 濁点（結合）
            cps(0x61, 0x300, 0x301) to 1,                                // 結合文字が 2 つ続く
            cps(0x1F44D) to 1,                                           // 親指
            thumbsUpWithSkinTone to 1,                                   // 肌色の修飾
            familyZwj to 1,                                              // ZWJ で連結した家族
            cps(0x1F469, 0x1F3FD, 0x200D, 0x1F4BB) to 1,                 // 肌色の修飾 + ZWJ（女性技術者）
            cps(0x1F3F3, 0xFE0F, 0x200D, 0x1F308) to 1,                  // 異体字セレクタ + ZWJ（虹の旗）
            cps(0x2764, 0xFE0F, 0x200D, 0x1F525) to 1,                   // 燃えるハート
            cps(0x1F91D, 0x200D, 0x1F91D) to 1,                          // ZWJ で絵文字どうしを連結
            cps(0x1F3F4, 0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F) to 1, // タグ列の国旗（イングランド）
            flagJapan to 1,                                              // 国旗（地域指示子 2 つ）
            flagJapan + cps(0x1F1FA, 0x1F1F8) to 2,                      // 国旗 2 つ
            flagJapan + cps(0x1F1FA) to 2,                               // 国旗 + 対にならない地域指示子 1 つ
            cps(0x1F1EF, 0x1F1F5, 0x1F1FA, 0x1F1F8, 0x61) to 3,          // 国旗 2 つ + a
            cps(0x31, 0xFE0F, 0x20E3) to 1,                              // キーキャップ
            "\r\n" to 1,                                                 // CRLF は 1 つ
            "\n\r" to 2,                                                 // LF CR は 2 つ
            cps(0x1112, 0x1161, 0x11AB) to 1,                            // ハングルの字母（L V T）
            cps(0xAC00, 0x11A8) to 1,                                    // ハングルの音節 + 終声
            cps(0x0E01, 0x0E33) to 1,                                    // タイ文字（SARA AM は広がる結合記号）
            cps(0x61, 0x200D) to 1,                                      // 末尾の ZWJ は直前に付く
            cps(0x61, 0x200D, 0x62) to 2,                                // 文字どうしの間の ZWJ は連結しない
            cps(0x200B) to 1,                                            // ゼロ幅スペース
            cps(0x0600, 0x31) to 1,                                      // 前置される記号（アラビアの数字記号）
        )
        for ((text, expected) in vectors) {
            assertEquals(expected, TextLimits.graphemeCount(text), "書記素の数が違う: ${describe(text)}")
        }
    }

    @Test
    fun `書記素の数はUTF16の長さと違う入力で区別できる`() {
        requireGraphemeJdk()
        // この 3 件は、UTF-16 の長さ（length）で数えると期待値と食い違う。「書記素で数えている」ことの証拠になる
        assertEquals(1, TextLimits.graphemeCount(familyZwj))
        assertEquals(11, familyZwj.length)
        assertEquals(1, TextLimits.graphemeCount(thumbsUpWithSkinTone))
        assertEquals(4, thumbsUpWithSkinTone.length)
        assertEquals(1, TextLimits.graphemeCount(eAcuteDecomposed))
        assertEquals(2, eAcuteDecomposed.length)
    }

    @Test
    fun `対にならない代用対でも例外を投げず1個として数える`() {
        // Swift の String には対にならない代用対は存在せず、iOS と比べられない。Android では端末の IME・貼り付けで
        // 作れてしまうので、落とさないことだけを固定する（JDK 25 の BreakIterator で 1 と実測）
        assertEquals(1, TextLimits.graphemeCount(cps(0xD83D)))
        assertEquals(1, TextLimits.graphemeCount(cps(0xDC4D)))
    }

    // ---- 古い数え方の端末の判定（全体レビュー 4 回目 R21） ----

    @Test
    fun `古い数え方の判定は燃えるハートを数えて1にならないときだけ立つ`() {
        val fireHeart = cps(0x2764, 0xFE0F, 0x200D, 0x1F525)

        // 燃えるハートだけを 2 と数える数え方（API 26 で測った形）なら立つ。燃えるハートだけを 1 と数えるなら立たない
        assertTrue(TextLimits.detectsLegacyGraphemeBreaking { text -> if (text == fireHeart) 2 else 1 })
        assertFalse(TextLimits.detectsLegacyGraphemeBreaking { text -> if (text == fireHeart) 1 else 2 })
    }

    @Test
    fun `開発機のJDKの数え方は古い数え方と判定しない`() {
        requireGraphemeJdk()
        assertFalse(TextLimits.isLegacyGraphemeBreaking)
    }

    // ---- 表示名 50・自己紹介 200（書記素クラスタの数。iOS と同じ） ----

    @Test
    fun `表示名は50個の書記素まで通り51個で通らない`() {
        requireGraphemeJdk()
        val limit = TextLimits.DISPLAY_NAME_MAX
        for (unit in listOf("あ", "a", thumbsUpWithSkinTone, familyZwj, flagJapan, eAcuteDecomposed)) {
            assertTrue(TextLimits.isDisplayNameWithinLimit(unit.repeat(limit)), "50 個は通るはず: ${unit.length} 文字の単位")
            assertFalse(TextLimits.isDisplayNameWithinLimit(unit.repeat(limit + 1)), "51 個は通らないはず: ${unit.length} 文字の単位")
        }
    }

    @Test
    fun `表示名はUTF16の長さが50を超えても書記素が50個なら通る`() {
        requireGraphemeJdk()
        val name = thumbsUpWithSkinTone.repeat(50)
        assertEquals(200, name.length)                    // UTF-16 では 200 文字。length で数える実装は、ここで弾いてしまう
        assertTrue(TextLimits.isDisplayNameWithinLimit(name))
    }

    @Test
    fun `自己紹介は200個の書記素まで通り201個で通らない`() {
        requireGraphemeJdk()
        val limit = TextLimits.BIO_MAX
        for (unit in listOf("あ", "a", thumbsUpWithSkinTone, familyZwj, flagJapan, eAcuteDecomposed)) {
            assertTrue(TextLimits.isBioWithinLimit(unit.repeat(limit)), "200 個は通るはず: ${unit.length} 文字の単位")
            assertFalse(TextLimits.isBioWithinLimit(unit.repeat(limit + 1)), "201 個は通らないはず: ${unit.length} 文字の単位")
        }
    }

    @Test
    fun `自己紹介はUTF16の長さが200を超えても書記素が200個なら通る`() {
        val bio = eAcuteDecomposed.repeat(200)
        assertEquals(400, bio.length)
        assertTrue(TextLimits.isBioWithinLimit(bio))
    }

    @Test
    fun `空の表示名と自己紹介は上限の判定では通る（iOSのisValidProfileEdit）`() {
        // 空かどうかの判定は上限の判定とは別（iOS も `count <= 50` だけで、空は通す。ProfileViewModel.swift:743）
        assertTrue(TextLimits.isDisplayNameWithinLimit(""))
        assertTrue(TextLimits.isBioWithinLimit(""))
    }

    @Test
    fun `上限の判定は前後の空白を取り除かずに数える`() {
        // iOS は trim せず生の文字列で count する。空白も 1 文字に数える
        assertTrue(TextLimits.isDisplayNameWithinLimit(ideographicSpace.repeat(50)))
        assertFalse(TextLimits.isDisplayNameWithinLimit(ideographicSpace.repeat(51)))
        assertFalse(TextLimits.isDisplayNameWithinLimit("a".repeat(49) + "  "))
    }

    // ---- パスワード 6 文字以上（iOS は書記素クラスタの数。AuthService.swift:51） ----

    @Test
    fun `パスワードは6文字から通り5文字は通らない`() {
        assertFalse(TextLimits.isPasswordLongEnough(""))
        assertFalse(TextLimits.isPasswordLongEnough("12345"))
        assertTrue(TextLimits.isPasswordLongEnough("123456"))
        assertTrue(TextLimits.isPasswordLongEnough("1234567"))
    }

    @Test
    fun `パスワードの文字数は書記素で数える`() {
        requireGraphemeJdk()
        // UTF-16 では 6 文字以上でも、書記素では 3 つ（iOS の password.count は 3 → weakPassword）
        val threeAccents = eAcuteDecomposed.repeat(3)
        assertEquals(6, threeAccents.length)
        assertFalse(TextLimits.isPasswordLongEnough(threeAccents))
        // 書記素 5 つ（UTF-16 では 20）は通らず、6 つで通る
        assertFalse(TextLimits.isPasswordLongEnough(thumbsUpWithSkinTone.repeat(5)))
        assertTrue(TextLimits.isPasswordLongEnough(thumbsUpWithSkinTone.repeat(6)))
        assertTrue(TextLimits.isPasswordLongEnough("ab" + cps(0x1F642).repeat(4)))
    }

    @Test
    fun `パスワードは空白だけでも6文字あれば通る（iOSは取り除かない）`() {
        // AuthService.swift:51 は password.count >= 6 だけで trim しない。パスワードの空白は意味のある文字として扱う
        assertTrue(TextLimits.isPasswordLongEnough("      "))
        assertTrue(TextLimits.isPasswordLongEnough(ideographicSpace.repeat(6)))
    }

    // ---- 空白だけかどうか（iOS の trimmingCharacters(in: .whitespacesAndNewlines) と同じ集合） ----

    @Test
    fun `空と空白だけの文字列は空白だけと判定する`() {
        assertTrue(TextLimits.isBlank(""))
        assertTrue(TextLimits.isBlank(" "))
        assertTrue(TextLimits.isBlank("\t\n\r"))
        assertTrue(TextLimits.isBlank(" " + cps(0x0B, 0x0C) + " "))   // 垂直タブ・改ページ
    }

    @Test
    fun `全角空白だけの文字列は空白だけと判定する`() {
        assertTrue(TextLimits.isBlank(ideographicSpace))
        assertTrue(TextLimits.isBlank(ideographicSpace.repeat(2)))
        assertTrue(TextLimits.isBlank(" " + ideographicSpace + " " + ideographicSpace))
    }

    @Test
    fun `その他のUnicodeの空白だけの文字列も空白だけと判定する`() {
        assertTrue(TextLimits.isBlank(cps(0x00A0)))        // NBSP
        assertTrue(TextLimits.isBlank(cps(0x0085)))        // NEL
        assertTrue(TextLimits.isBlank(cps(0x1680)))        // オガム文字の空白
        assertTrue(TextLimits.isBlank(cps(0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A)))
        assertTrue(TextLimits.isBlank(cps(0x2028, 0x2029)))  // 行区切り・段落区切り
        assertTrue(TextLimits.isBlank(cps(0x202F, 0x205F)))
        assertTrue(TextLimits.isBlank(cps(0x200B)))        // ゼロ幅スペース（Unicode の White_Space ではないが、Apple の集合には入っている）
    }

    @Test
    fun `空白以外が1文字でもあれば空白だけとは判定しない`() {
        assertFalse(TextLimits.isBlank("a"))
        assertFalse(TextLimits.isBlank(" a "))
        assertFalse(TextLimits.isBlank(ideographicSpace + "あ" + ideographicSpace))
        assertFalse(TextLimits.isBlank(ideographicSpace + ideographicSpace + "."))
        assertFalse(TextLimits.isBlank(cps(0x1F600)))      // 絵文字
    }

    @Test
    fun `iOSの集合に入っていない空白に似た文字は空白と判定しない`() {
        // Swift 6.4 の CharacterSet.whitespacesAndNewlines に入っていないことを実測した文字
        assertFalse(TextLimits.isBlank(cps(0xFEFF)))       // BOM（ゼロ幅の改行しない空白）
        assertFalse(TextLimits.isBlank(cps(0x2060)))       // 単語結合子
        assertFalse(TextLimits.isBlank(cps(0x180E)))       // モンゴル語の母音区切り
        assertFalse(TextLimits.isBlank(cps(0x200C)))       // ZWNJ
        assertFalse(TextLimits.isBlank(cps(0x200D)))       // ZWJ
        assertFalse(TextLimits.isBlank(cps(0x001C)))       // 情報区切り（Java の Character.isWhitespace は空白と見なすが、iOS は見なさない）
        assertFalse(TextLimits.isBlank(cps(0x001F)))
    }

    @Test
    fun `空白の集合は全Unicodeスカラー値でiOSの実測と一致する`() {
        // Swift 6.4 の CharacterSet.whitespacesAndNewlines に 0〜0x10FFFF を 1 つずつ当てて実測した、含まれる範囲の全て
        val iosWhitespaceRanges = listOf(
            0x0009..0x000D, 0x0020..0x0020, 0x0085..0x0085, 0x00A0..0x00A0, 0x1680..0x1680,
            0x2000..0x200B, 0x2028..0x2029, 0x202F..0x202F, 0x205F..0x205F, 0x3000..0x3000,
        )
        val mismatches = mutableListOf<String>()
        for (codePoint in 0..0x10FFFF) {
            if (codePoint in 0xD800..0xDFFF) continue      // 代用対の半分だけでは文字列として成立しない
            val expected = iosWhitespaceRanges.any { codePoint in it }
            val actual = TextLimits.isBlank(cps(codePoint))
            if (expected != actual) mismatches += "U+%04X(期待=%b)".format(codePoint, expected)
        }
        assertEquals(emptyList<String>(), mismatches.take(20), "iOS の集合と食い違うコードポイント（先頭 20 件）")
    }

    // ---- キャプション（タスク 23.2・要件 7.6） ----

    @Test
    fun `キャプションの前後の空白はiOSの集合で取り除き、中の空白と改行は残す`() {
        val inner = "空\n" + ideographicSpace + "青"
        val text = cps(0x3000, 0x20, 0x0A, 0x2028) + inner + cps(0x200B, 0x09, 0x0D, 0x00A0)

        assertEquals(inner, TextLimits.trimWhitespace(text), describe(TextLimits.trimWhitespace(text)))
    }

    @Test
    fun `iOSの集合に入っていない空白に似た文字は前後にあっても取り除かない`() {
        // 情報区切り（U+001C）は Kotlin の trim（Char.isWhitespace）だと取り除かれてしまう。BOM はどちらでも残る
        val text = cps(0xFEFF) + "空" + cps(0x001C)

        assertEquals(text, TextLimits.trimWhitespace(text))
    }

    @Test
    fun `空白だけのキャプションは取り除くと空になる`() {
        assertEquals("", TextLimits.trimWhitespace(cps(0x20, 0x3000, 0x0A, 0x200B)))
    }

    @Test
    fun `前後の空白の取り除きは全Unicodeスカラー値でiOSの集合と一致する`() {
        // 空白の集合のテストと同じ実測値。ある文字 c で「c + x + c」を挟み、iOS の集合の文字だけが取り除かれることを確かめる
        val iosWhitespaceRanges = listOf(
            0x0009..0x000D, 0x0020..0x0020, 0x0085..0x0085, 0x00A0..0x00A0, 0x1680..0x1680,
            0x2000..0x200B, 0x2028..0x2029, 0x202F..0x202F, 0x205F..0x205F, 0x3000..0x3000,
        )
        val mismatches = mutableListOf<String>()
        for (codePoint in 0..0x10FFFF) {
            if (codePoint in 0xD800..0xDFFF) continue
            val text = cps(codePoint) + "x" + cps(codePoint)
            val expected = if (iosWhitespaceRanges.any { codePoint in it }) "x" else text
            if (TextLimits.trimWhitespace(text) != expected) mismatches += "U+%04X".format(codePoint)
        }
        assertEquals(emptyList<String>(), mismatches.take(20), "iOS の集合と食い違うコードポイント（先頭 20 件）")
    }

    @Test
    fun `キャプションはUTF16の長さで2000まで通り2001で通らない`() {
        assertTrue(TextLimits.isCaptionWithinLimit("a".repeat(2000)))
        assertFalse(TextLimits.isCaptionWithinLimit("a".repeat(2001)))
        assertTrue(TextLimits.isCaptionWithinLimit(""))
    }

    @Test
    fun `キャプションの上限は書記素でなくUTF16で数える`() {
        // rules の caption.size() は UTF-16 の単位。UTF-16 で 2 文字の絵文字なら 1000 個で 2000、1001 個で 2002 になって断られる
        val sunBehindCloud = cps(0x1F324)
        assertEquals(2, sunBehindCloud.length)
        assertTrue(TextLimits.isCaptionWithinLimit(sunBehindCloud.repeat(1000)))
        assertFalse(TextLimits.isCaptionWithinLimit(sunBehindCloud.repeat(1001)))
    }

    // ---- フィードバックの本文（タスク 28・要件 13.3） ----

    @Test
    fun `フィードバックの本文はUTF16の長さで1000まで通り1001で通らない`() {
        assertTrue(TextLimits.isFeedbackWithinLimit("a".repeat(1000)))
        assertFalse(TextLimits.isFeedbackWithinLimit("a".repeat(1001)))
        assertTrue(TextLimits.isFeedbackWithinLimit(""))
    }

    @Test
    fun `フィードバックの上限は書記素でなくUTF16で数える`() {
        // rules の message.size() は UTF-16 の単位。iOS の message.count（書記素）なら 501 個でも通るが、rules は 1002 で断る。
        // Android は送る前に rules と同じ数え方で止める
        val grinning = cps(0x1F600)
        assertEquals(2, grinning.length)
        assertTrue(TextLimits.isFeedbackWithinLimit(grinning.repeat(500)))
        assertFalse(TextLimits.isFeedbackWithinLimit(grinning.repeat(501)))
    }

    @Test
    fun `フィードバックの空白だけの判定は全角空白を含む`() {
        // 要件 13.3「空白だけ」。全角空白だけの本文は空白だけである。前後に空白があっても、中に文字があれば空白だけではない
        assertTrue(TextLimits.isBlank(cps(0x3000, 0x3000)))
        assertFalse(TextLimits.isBlank(ideographicSpace + "あ" + ideographicSpace))
        assertEquals("あ", TextLimits.trimWhitespace(ideographicSpace + "あ" + ideographicSpace))
    }
}
