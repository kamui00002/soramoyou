// ⭐️ 書記素の端末テストのベクタが、:contract の TextLimitsTest の写しのままであることのソース検査（全体レビュー 4 回目 R21）
package com.yoshidometoru.soramoyou.contract.rules

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 端末テスト TextLimitsDeviceTest（androidTestEmulator）は、:contract の TextLimitsTest の黄金ベクタ（Swift の `String.count` の実測値）を
 * 写して端末の ICU で数える。:contract のテストのソースは :app の端末テストから参照できない（testFixtures は使っていない）ので、
 * 写しが離れないよう、2 つのファイルの `val vectors = listOf(` の塊・その中で名前で呼ぶ値（`eAcuteDecomposed` など）の定義・
 * 文字列を組み立てる `cps` の定義が、文字どおり同じかを見る（片方だけ直すと赤）。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、:contract は `../contract` から読む。
 */
class TextLimitsDeviceVectorsSourceTest {

    private val jvmTest = File("../contract/src/test/kotlin/com/yoshidometoru/soramoyou/contract/rules/TextLimitsTest.kt")
    private val deviceTest = File("src/androidTestEmulator/kotlin/com/yoshidometoru/soramoyou/contract/rules/TextLimitsDeviceTest.kt")

    @Test
    fun `端末テストのベクタはTextLimitsTestの写しと文字どおり同じ`() {
        assertTrue(jvmTest.isFile, "TextLimitsTest.kt が見つからない: ${jvmTest.absolutePath}")
        assertTrue(deviceTest.isFile, "TextLimitsDeviceTest.kt が見つからない: ${deviceTest.absolutePath}")
        val jvm = jvmTest.readText()
        val device = deviceTest.readText()

        val vectors = blockAfter(jvm, VECTORS, '(', ')')
        assertEquals(vectors, blockAfter(device, VECTORS, '(', ')'), "端末テストのベクタの並びが TextLimitsTest と違う（両方を同じに直す）")

        assertEquals(single(CPS, jvm), single(CPS, device), "端末テストの cps の定義が TextLimitsTest と違う")

        val jvmDefinitions = definitions(jvm)
        val deviceDefinitions = definitions(device)
        val named = jvmDefinitions.keys.filter { name -> Regex("""\b$name\b""").containsMatchIn(vectors) }
        assertTrue(named.isNotEmpty(), "ベクタの中で名前で呼ぶ値が 1 つも見つからない（定義の読み方を読み違えた可能性）")
        for (name in named) {
            assertEquals(jvmDefinitions[name], deviceDefinitions[name], "ベクタが使う $name の定義が TextLimitsTest と違う")
        }
    }

    private companion object {
        /** ベクタの並びの書き出し。行の頭と字下げまで含める（KDoc が同じ文字を書いても拾わないため）。 */
        const val VECTORS = "\n        val vectors = listOf("

        /** 文字列を組み立てる道具の定義（1 行）。 */
        val CPS = Regex("""private fun cps\([^\n]*""")

        /** `private val 名前 = cps(…)` の定義（名前 → 右辺）。 */
        val DEFINITION = Regex("""private val (\w+) = (cps\([^)\n]*\))""")

        fun definitions(source: String): Map<String, String> =
            DEFINITION.findAll(source).associate { it.groupValues[1] to it.groupValues[2] }

        /** [pattern] がちょうど 1 か所であることを確かめて、その文字列を返す。 */
        fun single(pattern: Regex, source: String): String {
            val found = pattern.findAll(source).map { it.value }.toList()
            assertEquals(1, found.size, "${pattern.pattern} が 1 か所ではない")
            return found.single()
        }

        /** [code] のうち、[marker] の後に最初に現れる [open] から、対応する [close] までの塊。[marker] がちょうど 1 か所であることも確かめる。 */
        fun blockAfter(code: String, marker: String, open: Char, close: Char): String {
            assertEquals(1, Regex.fromLiteral(marker).findAll(code).count(), "$marker が 1 か所ではない")
            val begin = code.indexOf(open, code.indexOf(marker))
            check(begin >= 0) { "$marker の後に $open が無い" }
            var depth = 0
            for (i in begin until code.length) {
                when (code[i]) {
                    open -> depth++
                    close -> if (--depth == 0) return code.substring(begin, i + 1)
                }
            }
            error("$marker の後の $open に対応する $close が無い")
        }
    }
}
