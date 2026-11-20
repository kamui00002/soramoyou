// ⭐️ 高さを固定する Modifier と、文言の行数を縛る書き方をソースから探す走査器（タスク 5.2 のテスト用）
package com.yoshidometoru.soramoyou.ui

import java.io.File

/**
 * [FixedHeightInUiTest] で使う走査器。`.kt` のファイルを全て読み、高さ（または縦横）を固定・上限で縛る書き方と、
 * 文言の行数を縛る書き方を探す。
 * 文字を大きくしたとき（要件 16.6）に、固定の高さの中で文言が切れたり重なったり、行数の上限で文言が省略されたりするのを防ぐためのもの。
 *
 * 探すのは文字列なので、コメントの中の一致も数える（説明には、丸括弧を付けた呼び出しの形（前の点の有無に依らない）や、
 * 引数に値を渡す形を書かない）。
 * 最小の高さ（heightIn の min だけ）・幅の上限・親いっぱいに広げる書き方は、文字が増えても伸びられるので対象にしない。
 */
internal object FixedHeightScanner {

    /** 見つけた 1 か所。[path] は根からの相対パス、[line] は 1 始まりの行番号、[text] は一致した文字列（空白を除いたもの）。 */
    data class Hit(val path: String, val line: Int, val text: String)

    /** 高さを固定する書き方と、文言の行数を縛る書き方。どれも、間に空白・改行を挟んでも一致する。 */
    private val PATTERNS = listOf(
        // 高さ・大きさの固定（size は縦横の両方を固定する）。前に点の無い呼び出し（Modifier の拡張の本体の中など）も数える
        Regex("""\b(height|requiredHeight|size|requiredSize)\s*\("""),
        // 文言の行数の上限（maxLines = …。どんな値でも数える）
        Regex("""\bmaxLines\s*="""),
        // 文言を 1 行に限る書き方（singleLine = true）
        Regex("""\bsingleLine\s*=\s*true\b"""),
        // 文言を折り返さない書き方（softWrap = false。1 行に収まらない分は切れる）
        Regex("""\bsoftWrap\s*=\s*false\b"""),
        // 収まらない文言を「…」で省略する書き方
        Regex("""\bTextOverflow\s*\.\s*Ellipsis\b"""),
    )

    /**
     * 上限を引数で渡せる Modifier の名前と、高さの上限の引数（名前と、名前を付けずに渡すときの 0 始まりの位置）。
     * heightIn は (min, max)、sizeIn は (minWidth, minHeight, maxWidth, maxHeight) の順に受け取る
     * （名前の並びは手元の foundation-layout の jar のメタデータで見た。引数の順そのものは Compose の文書からの理解）。
     */
    private val UPPER_BOUNDS = mapOf(
        "heightIn" to UpperBound("max", 1),
        "requiredHeightIn" to UpperBound("max", 1),
        "sizeIn" to UpperBound("maxHeight", 3),
        "requiredSizeIn" to UpperBound("maxHeight", 3),
    )

    private data class UpperBound(val name: String, val position: Int)

    /** 上限を渡せる Modifier の呼び出しの始まり。前に点の無い呼び出しも数える。 */
    private val BOUNDED_CALL = Regex("""\b(heightIn|requiredHeightIn|sizeIn|requiredSizeIn)\s*\(""")

    /** 名前を付けて渡す引数の、名前（`==` の比較は名前と読まない）。 */
    private val ARGUMENT_NAME = Regex("""^\s*(\w+)\s*=(?!=)""")

    /** [root] の下の `.kt` を全て走査し、一致した場所を返す。1 行に複数が重なっても 1 件。並びはパス・行番号の順。 */
    fun scan(root: File): List<Hit> =
        root.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { file -> hitsIn(file.relativeTo(root).invariantSeparatorsPath, file.readText()) }
            .sortedWith(compareBy({ it.path }, { it.line }))
            .toList()

    private fun hitsIn(path: String, source: String): List<Hit> =
        (PATTERNS.flatMap { it.findAll(source) } + upperBoundCalls(source))
            .map { match -> Hit(path, lineOf(source, match.range.first), match.value.replace(WHITESPACE, "")) }
            .distinctBy { it.line }

    /**
     * 高さの上限を渡している呼び出し。上限の引数を名前で渡すか、名前を付けずに上限の位置（またはその後ろ）まで渡したもの。
     * 名前を付けた引数の後ろに名前の無い引数を置く形（heightIn の min を名前で渡し、2 つ目を名前なしで渡す）も数える。
     * 閉じ括弧が見つからないときは、拾い損ねない側に倒して数える。
     */
    private fun upperBoundCalls(source: String): List<MatchResult> =
        BOUNDED_CALL.findAll(source).filter { match ->
            val bound = UPPER_BOUNDS.getValue(match.groupValues[1])
            val arguments = argumentsFrom(source, match.range.last + 1) ?: return@filter true
            arguments.withIndex().any { (index, argument) ->
                val name = ARGUMENT_NAME.find(argument)?.groupValues?.get(1)
                if (name != null) name == bound.name else index >= bound.position
            }
        }.toList()

    /**
     * [start]（開き括弧の次の文字）から、対応する閉じ括弧までの引数を、どの括弧の中でもないカンマで分けて返す。
     * 丸括弧・角括弧・波括弧の入れ子を数えるので、引数の中の関数の呼び出しやラムダのカンマでは分けない。
     * 行コメントは読み飛ばし（コメントの中のカンマ・括弧で分けない）、空の引数（最後のカンマの後ろ）は除く。
     * 文字列とブロックコメントの中の括弧・カンマは扱わない（今の ui/ には無い）。閉じ括弧が無ければ null を返す。
     */
    private fun argumentsFrom(source: String, start: Int): List<String>? {
        val arguments = mutableListOf<String>()
        val current = StringBuilder()
        var depth = 0
        var i = start
        while (i < source.length) {
            if (source.startsWith("//", i)) {
                // 行コメントは行の終わりまで読み飛ばす（改行そのものは次の文字として読む）
                i = source.indexOf('\n', i).let { if (it < 0) source.length else it }
                continue
            }
            val c = source[i]
            when {
                c in "([{" -> depth++
                c in ")]}" && depth > 0 -> depth--
                c == ')' -> return (arguments + current.toString()).filter { it.isNotBlank() }
                c == ',' && depth == 0 -> {
                    arguments += current.toString()
                    current.clear()
                    i++
                    continue
                }
            }
            current.append(c)
            i++
        }
        return null
    }

    /** [index] の文字が何行目か（1 始まり）。 */
    private fun lineOf(source: String, index: Int): Int = source.substring(0, index).count { it == '\n' } + 1

    private val WHITESPACE = Regex("""\s+""")
}
