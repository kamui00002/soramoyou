// ⭐️ iOS 版の Swift と Android の strings.xml から、画面の文言を読み出す補助（タスク 5.2 のテスト用）
package com.yoshidometoru.soramoyou.ui

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.w3c.dom.Element

/**
 * [UiStringsTest] で使う読み出し器。iOS 版のソースは同じリポジトリの直下の `Soramoyou/` にある。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、そこからの相対パスで読む（PostHogSetupTest と同じやり方）。
 *
 * Swift の読み方は、そらもようの iOS のソースの書き方（`switch self { case .x: return "…" }` と、return を省いた
 * `switch self { case .x: "…" }`）だけを想定した文字列の走査である。2 つの書き方は [withoutCaseReturns] で同じに読む
 * （2026-11-06 に main を取り込んだら、LoadingStateView・Visibility・EmptyStateView が return を省く書き方になっていた）。
 * 書き方が変わって読めなくなったときは、空の結果で黙って通らないよう、呼び出し側で「空でない」「宣言と一致する」を確かめる。
 */
internal object UiTextSources {

    /** android/app から見た、iOS 版のソースの根。 */
    val iosSourceRoot = File(System.getProperty("user.dir"), "../../Soramoyou/Soramoyou")

    /** :app の既定の文字列リソース。 */
    val stringsXml = File("src/main/res/values/strings.xml")

    /** iOS 版のソースを読む。無ければ、どのパスを探したかを添えて失敗させる。 */
    fun iosSource(relativePath: String): String {
        val file = File(iosSourceRoot, relativePath)
        check(file.isFile) { "iOS 版のソースが見つからない: ${file.canonicalPath}" }
        return file.readText()
    }

    /**
     * strings.xml の `<string name="…">` を全て読み、名前 → 値の対応にする（並びはファイルの順）。
     * この中で使っている文字はエスケープの要らないものだけなので、値は XML の文字列をそのまま返す。
     */
    fun readStrings(file: File = stringsXml): Map<String, String> {
        check(file.isFile) { "strings.xml が見つからない: ${file.absolutePath}" }
        val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
            .documentElement.getElementsByTagName("string")
        return (0 until nodes.length).associate { i ->
            val element = nodes.item(i) as Element
            element.getAttribute("name") to element.textContent
        }
    }

    /**
     * strings.xml の文言を iOS の書き方に入れた文字列が、[iosFiles] のそれぞれのソースに現れることを確かめる
     * （画面の文言を iOS と 1 文字も違えないテスト〔*StringsTest〕が、同じ突き合わせを 4 か所で書いていたのをここに寄せた。レビュー F07）。
     *
     * @param expectations リソース名 → 文言を `%s` に置いた iOS の書き方（例 `".alert(\"%s\", isPresented: …)"`）の並び。
     *   同じリソース名が何度出てもよい（iOS で別の場所に出る書き方を、別々に確かめるため）
     * @param iosFiles `Soramoyou/Soramoyou/` からの相対パス。複数なら、それぞれのファイルに全ての書き方が現れなければならない
     *   （投稿詳細のように、iOS が同じ文言を 2 つの画面に持つ場合）
     */
    fun assertIosHasStrings(expectations: List<Pair<String, String>>, vararg iosFiles: String) {
        // 何も突き合わせないまま通ると「iOS と同じ」を確かめたことにならないので、空の呼び出しは書き間違いとして止める
        require(expectations.isNotEmpty() && iosFiles.isNotEmpty()) { "突き合わせる書き方か iOS のファイルが空" }
        val strings = readStrings()
        iosFiles.forEach { file ->
            val source = iosSource(file)
            expectations.forEach { (name, pattern) ->
                val value = assertNotNull(strings[name], "strings.xml に $name が無い")
                val expected = pattern.replace("%s", value)
                assertTrue(expected in source, "iOS の $file に「$expected」が無い（$name）")
            }
        }
    }

    /**
     * Swift のソース [source] の中の、トップレベルの `enum [enumName]` を読み、文字列値 → `displayName` の対応にする。
     * 並びは iOS の case の宣言の順。
     *
     * - 文字列値は `case x = "y"` の y。`case bug` のように値を書いていない case は、Swift の規則どおり case 名を値とする
     * - 表示名は `var displayName` の中の `case .x: return "…"` か、return を省いた `case .x: "…"`（`case .x:` の後の改行も許す）
     * - 宣言した case と、表示名を返す case の集合が食い違えば失敗させる（読み落としを「一致した」と誤らないため）
     */
    fun readEnumDisplayNames(source: String, enumName: String): Map<String, String> {
        val body = topLevelBlock(source, Regex("""\benum\s+$enumName\b"""), "enum $enumName")
        val displayNameAt = body.indexOf("var displayName")
        check(displayNameAt >= 0) { "enum $enumName に var displayName が無い" }

        // case の宣言は displayName より前にだけある（後ろの case は switch の分岐）
        val rawByCase = CASE_DECLARATION.findAll(body.substring(0, displayNameAt))
            .associate { match -> match.groupValues[1] to match.groups[2]?.value.orEmpty().ifEmpty { match.groupValues[1] } }
        val displayByCase = switchReturns(body, "displayName")

        check(rawByCase.isNotEmpty()) { "enum $enumName の case の宣言を 1 つも読めない" }
        check(rawByCase.keys == displayByCase.keys) {
            "enum $enumName の case の宣言 ${rawByCase.keys} と、表示名を返す case ${displayByCase.keys} が一致しない"
        }
        return rawByCase.entries.associate { (case, raw) -> raw to displayByCase.getValue(case) }
    }

    /**
     * [source] の中の `var [property]` の本体にある `case .x: return "…"`（return を省いた `case .x: "…"` も）を読み、case 名 → 文字列にする。
     * 本体の終わりは、次の `var`・`func`・`static` の宣言か、[source] の終わりとする（同じ型の iconName などを読まないため）。
     * 文字列を返さない分岐（`case .custom(let title): return title` など）は読まない。
     */
    fun switchReturns(source: String, property: String): Map<String, String> {
        val start = Regex("""\bvar\s+$property\b""").find(source)
        checkNotNull(start) { "var $property が見つからない" }
        val rest = source.substring(start.range.last + 1)
        val end = NEXT_DECLARATION.find(rest)?.range?.first ?: rest.length
        return CASE_STRING.findAll(withoutCaseReturns(rest.substring(0, end))).associate { it.groupValues[1] to it.groupValues[2] }
    }

    /**
     * [text] の中の、switch の分岐の `case .x:` の直後の `return` を除く。`case .x: return "…"` と、return を省いた
     * `case .x: "…"` を同じ文字列にそろえるため（突き合わせる側と iOS のソースの両方に通す）。`case .x:` と `return` の間の改行は残す。
     */
    fun withoutCaseReturns(text: String): String = CASE_RETURN.replace(text) { it.groupValues[1] }

    /** [source] の中の、[header] で始まるトップレベルの型の本体（次の行頭の `}` まで）。 */
    private fun topLevelBlock(source: String, header: Regex, label: String): String {
        val start = checkNotNull(header.find(source)) { "$label が見つからない" }.range.first
        val end = source.indexOf("\n}", start)
        check(end >= 0) { "$label の終わり（行頭の閉じ括弧）が見つからない" }
        return source.substring(start, end)
    }

    /** case の宣言。`case \`public\` = "public"`・`case morning = "morning"`・`case bug      // 不具合` に一致する。 */
    private val CASE_DECLARATION = Regex("""(?m)^\s*case\s+`?(\w+)`?(?:\s*=\s*"([^"]*)")?""")

    /** switch の分岐の `case .x:` と、その直後の `return`（[withoutCaseReturns] が除く）。 */
    private val CASE_RETURN = Regex("""(case\s+\.\w+\s*:\s*)return\s+""")

    /** switch の分岐で文字列を返すもの（[withoutCaseReturns] を通した後）。`case .x:` と `"…"` の間の改行も許す。 */
    private val CASE_STRING = Regex("""case\s+\.(\w+)\s*:\s*"([^"]*)"""")

    /** 次の宣言の始まり。 */
    private val NEXT_DECLARATION = Regex("""\n\s*(var|func|static)\s""")
}
