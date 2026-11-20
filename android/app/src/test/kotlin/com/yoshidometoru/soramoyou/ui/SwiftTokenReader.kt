// ⭐️ iOS 版のデザイントークンのソースを、入れ子の型ごとに読む補助（タスク 3.2・要件 4.3・5.9）
package com.yoshidometoru.soramoyou.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import java.io.File
import kotlin.math.abs

/**
 * iOS との突き合わせのテスト（IosDesignTokensTest など）が、`DesignTokens.swift` の値を読むための補助。
 *
 * `enum 名前` の後の最初の `{` から、`{}` の深さが 0 に戻るまでを、その型の本体として切る。
 * `Spacing` と `Radius` は `sm`・`md` などの名前が重なるので、本体ごとに読まないと値を取り違える
 * （[UiTextSources] の行頭の `}` までを切る読み方は、字下げした `}` で閉じる入れ子の型を切れない。そちらは触らない）。
 *
 * 読み方は、そらもようの iOS のソースの書き方（`static let 名前: CGFloat = 数`・`Color(red:green:blue:)`・
 * `Color.white.opacity(数)`）だけを想定した文字列の走査である。文字列やコメントの中の `{}` は数えない前提で、
 * 今のソースにはそれが無い。書き方が変わって読めないときは、空の結果や一部だけを返さず、読んだパスと名前を出して失敗させる。
 */
internal class SwiftTokenReader private constructor(
    /** 失敗の文言に出す、読んだファイルのパス。 */
    val origin: String,
    private val text: String,
) {

    /** iOS の `Color(red:green:blue:)` の 3 つの数（0〜1）。 */
    data class SwiftColor(val red: Double, val green: Double, val blue: Double) {

        /**
         * Kotlin の不透明の色 [color] と等しいか。Kotlin の色の各成分（0〜255）と、iOS の値×255 の差が 0.5 以下なら等しいとみなす
         * （0.90×255＝229.5 のような半端な値でも、229 と 230 のどちらで写しても結果が決まる）。
         * 赤・緑・青だけを比べるので、半透明の色を渡されたら失敗する。
         */
        fun matches(color: Color): Boolean {
            require(color.alpha == 1f) { "比べる色 #%08X が半透明。iOS の Color(red:green:blue:) は不透明".format(color.toArgb()) }
            val argb = color.toArgb()
            val kotlin = listOf(argb shr 16 and 0xFF, argb shr 8 and 0xFF, argb and 0xFF)
            return kotlin.zip(listOf(red, green, blue)).all { (component, ios) -> abs(component - ios * 255) <= TOLERANCE }
        }
    }

    /** 切り出した本体。[label] は失敗の文言に出す名前（`enum Spacing` など）。 */
    inner class Body(val label: String, private val source: String) {

        /**
         * 本体の中の `static let 名前: CGFloat = 数` を、宣言の順に名前 → 値にする。
         * 本体の `static let` の全てが、この書き方で読めなければ失敗する（読めない宣言を黙って落とすと、名前の集合の突き合わせが狂うため）。
         */
        fun numbers(): Map<String, Double> {
            val declared = DECLARATION.findAll(source).map { it.groupValues[1] }.toList()
            check(declared.isNotEmpty()) { "$origin の $label に static let が 1 つも無い（書き方が変わって読めない）" }
            val read = CGFLOAT.findAll(source).associate { it.groupValues[1] to it.groupValues[2].toDouble() }
            check(read.keys.toList() == declared) {
                "$origin の $label に、static let 名前: CGFloat = 数 として読めない宣言がある: ${declared - read.keys}"
            }
            return read
        }

        /** 本体の中の `static let [name] = Color(red:green:blue:)`。後ろに `.opacity` などが続くものは読まない。 */
        fun color(name: String): SwiftColor {
            val match = Regex("""(?m)\bstatic\s+let\s+${Regex.escape(name)}\s*(?::\s*Color\s*)?=\s*$COLOR_LITERAL$LINE_END""")
                .find(source)
            return checkNotNull(match) { "$origin の $label に、Color(red:green:blue:) だけの static let $name が無い" }.toSwiftColor()
        }

        /**
         * 本体の中の `static let [name]: [Color] = [ … ]` の色を、並びの順に読む。
         * 型の `[Color]` の括弧でなく、`= [` から `[]` の深さで切る。要素の全てが `Color(red:green:blue:)` でなければ失敗する。
         */
        fun colors(name: String): List<SwiftColor> {
            val head = Regex("""\bstatic\s+let\s+${Regex.escape(name)}\s*:\s*\[\s*Color\s*]\s*=\s*\[""").find(source)
            checkNotNull(head) { "$origin の $label に static let $name: [Color] = [ が無い" }
            val elements = splitTopLevel(cut(source, head.range.last, '[', ']', "$label の $name").replace(COMMENT, ""))
            check(elements.isNotEmpty()) { "$origin の $label の $name の配列が空" }
            return elements.map { element ->
                val match = Regex("""^$COLOR_LITERAL$""").matchEntire(element)
                checkNotNull(match) { "$origin の $label の $name に、Color(red:green:blue:) として読めない要素がある: $element" }
                    .toSwiftColor()
            }
        }

        /** 本体の中の `static let [name] = Color.white.opacity(数)` の数。 */
        fun whiteOpacity(name: String): Double {
            val match = Regex(
                """(?m)\bstatic\s+let\s+${Regex.escape(name)}\s*(?::\s*Color\s*)?=\s*Color\.white\.opacity\(\s*($NUMBER)\s*\)$LINE_END""",
            ).find(source)
            return checkNotNull(match) { "$origin の $label に、Color.white.opacity(数) の static let $name が無い" }
                .groupValues[1].toDouble()
        }

        /**
         * 本体の中の `.white.opacity(数)` の数を、現れる順に読む（雲の `.fill(.white.opacity(0.5))` のように、名前の無いもの）。
         * 白でない色の `.opacity(` が混ざっていれば失敗する（黙って飛ばすと、雲の数の突き合わせが狂うため）。
         */
        fun whiteOpacities(): List<Double> {
            val white = WHITE_OPACITY.findAll(source).map { it.groupValues[1].toDouble() }.toList()
            check(white.isNotEmpty()) { "$origin の $label に .white.opacity(数) が 1 つも無い" }
            val all = OPACITY_CALL.findAll(source).count()
            check(white.size == all) { "$origin の $label に、.white.opacity(数) として読めない .opacity( が ${all - white.size} 個ある" }
            return white
        }

        private fun MatchResult.toSwiftColor() =
            SwiftColor(groupValues[1].toDouble(), groupValues[2].toDouble(), groupValues[3].toDouble())
    }

    /** ソースの中の `enum [enumName]` の本体。 */
    fun enumBody(enumName: String): Body = block(Regex("""\benum\s+${Regex.escape(enumName)}\b"""), "enum $enumName")

    /**
     * ソースの中で [header] に一致する宣言の後の、最初の `{` から `{}` の深さが 0 に戻るまでの本体（両端の括弧は含まない）。
     * 宣言が無い・2 か所以上ある（どれを読むか決まらない）・括弧が閉じない・本体が空のときは失敗する。
     */
    fun block(header: Regex, label: String): Body {
        val found = header.findAll(text).toList()
        check(found.isNotEmpty()) { "$origin に $label が見つからない" }
        check(found.size == 1) { "$origin に $label が ${found.size} か所ある（どれを読むか決まらない）" }
        val open = text.indexOf('{', found.single().range.last + 1)
        check(open >= 0) { "$origin の $label の後に { が無い" }
        val body = cut(text, open, '{', '}', label)
        check(body.isNotBlank()) { "$origin の $label の本体が空" }
        return Body(label, body)
    }

    /** [source] の [openAt] にある [open] から、[open] と [close] の深さが 0 に戻るまでの中身。 */
    private fun cut(source: String, openAt: Int, open: Char, close: Char, label: String): String {
        var depth = 0
        for (i in openAt until source.length) {
            when (source[i]) {
                open -> depth++
                close -> if (--depth == 0) return source.substring(openAt + 1, i)
            }
        }
        error("$origin の $label の $open が閉じていない")
    }

    /** 配列の中身を、括弧の外のコンマで分ける（`Color(red: …, green: …)` の中のコンマでは分けない）。最後のコンマの後の空は捨てる。 */
    private fun splitTopLevel(inner: String): List<String> {
        val elements = mutableListOf<String>()
        var depth = 0
        var start = 0
        inner.forEachIndexed { i, c ->
            when (c) {
                '(', '[' -> depth++
                ')', ']' -> depth--
                ',' -> if (depth == 0) {
                    elements += inner.substring(start, i)
                    start = i + 1
                }
            }
        }
        elements += inner.substring(start)
        return elements.map { it.trim() }.filter { it.isNotEmpty() }
    }

    companion object {

        /** iOS 版のソースの根（[UiTextSources.iosSourceRoot]）から読む。無ければ、探したパスを出して失敗する（[UiTextSources.iosSource] と同じ）。 */
        fun ios(relativePath: String): SwiftTokenReader {
            val text = UiTextSources.iosSource(relativePath)
            return SwiftTokenReader(File(UiTextSources.iosSourceRoot, relativePath).canonicalPath, text)
        }

        /** 任意のファイルから読む（陽性対照の写し）。無ければ、探したパスを出して失敗する。 */
        fun of(file: File): SwiftTokenReader {
            check(file.isFile) { "Swift のソースが見つからない: ${file.canonicalPath}" }
            return SwiftTokenReader(file.canonicalPath, file.readText())
        }

        /**
         * 色の比べ方の許容幅。0.5 ちょうどの境目（229.5 と 230 の差）が、小数の 2 進の丸めで 0.5 をわずかに超えて
         * 結果が揺れないよう、丸めの誤差の分だけ足す。iOS の値は小数第 2 位までなので、正しい写しと 1 つ違いの写しの差（0.1 以上）は変わらない。
         */
        private const val TOLERANCE = 0.5 + 1e-9

        /** 数（`4`・`0.85`・`1.0`・`-2`）。 */
        private const val NUMBER = """-?\d+(?:\.\d+)?"""

        /** 行の終わり。後ろのコメントは許す。 */
        private const val LINE_END = """[ \t]*(?://[^\n]*)?$"""

        /** `Color(red: 数, green: 数, blue: 数)`。 */
        private const val COLOR_LITERAL =
            """Color\(\s*red:\s*($NUMBER)\s*,\s*green:\s*($NUMBER)\s*,\s*blue:\s*($NUMBER)\s*\)"""

        private val DECLARATION = Regex("""\bstatic\s+let\s+(\w+)""")
        private val CGFLOAT = Regex("""(?m)\bstatic\s+let\s+(\w+)\s*:\s*CGFloat\s*=\s*($NUMBER)$LINE_END""")
        private val WHITE_OPACITY = Regex("""\.white\.opacity\(\s*($NUMBER)\s*\)""")
        private val OPACITY_CALL = Regex("""\.opacity\(""")
        private val COMMENT = Regex("""//[^\n]*""")
    }
}
