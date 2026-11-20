// ⭐️ Firestore・Storage のインスタンスを得るコードをソースから探す走査器（タスク 5.1 のテスト用）
package com.yoshidometoru.soramoyou.di

import java.io.File

/**
 * [FirebaseInstanceCreationSiteTest] で使う走査器。`.kt` のファイルを全て読み、インスタンスを得る書き方を探す。
 * 探すのは文字列なので、コメントの中の一致も数える（説明には完全な呼び出しの形を書かない）。
 */
internal object FirebaseInstanceCreationScanner {

    /** インスタンスを得てよい唯一のファイル（ソースの根からの相対パス）。 */
    const val ALLOWED_PATH = "com/yoshidometoru/soramoyou/di/AppContainer.kt"

    /** 見つけた 1 か所。[path] はソースの根からの相対パス、[line] は 1 始まりの行番号、[text] は一致した文字列（空白を除いたもの）。 */
    data class Hit(val path: String, val line: Int, val text: String)

    /** インスタンスを得る書き方。どれも、間に空白・改行を挟んでも一致する。 */
    private val PATTERNS = listOf(
        // getInstance（引数の有無を問わない）。`import ….FirebaseFirestore.getInstance` の直接の import もこれで一致する
        Regex("""\bFirebase(Firestore|Storage)\s*\.\s*getInstance\b"""),
        // Firebase の拡張プロパティ・拡張関数（Firebase.firestore・Firebase.storage(app) など）
        Regex("""\bFirebase\s*\.\s*(firestore|storage)\b"""),
        // 上の拡張の import（別名で import されると、使う所では見分けられないため import 自体を数える）
        Regex("""\bimport\s+com\s*\.\s*google\s*\.\s*firebase\s*\.\s*(firestore\s*\.\s*firestore|storage\s*\.\s*storage)\b"""),
    )

    /**
     * [root] の下の `.kt` を全て走査し、[allowedPath]（根からの相対パス。null なら許可なし）以外での一致を返す。
     * 1 行に複数の書き方が重なっても、1 件として数える。並びはパス・行番号の順。
     */
    fun scan(root: File, allowedPath: String?): List<Hit> =
        root.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .map { it to it.relativeTo(root).invariantSeparatorsPath }
            .filter { (_, path) -> path != allowedPath }
            .flatMap { (file, path) -> hitsIn(path, file.readText()) }
            .sortedWith(compareBy({ it.path }, { it.line }))
            .toList()

    private fun hitsIn(path: String, source: String): List<Hit> =
        PATTERNS.flatMap { it.findAll(source) }
            .map { match -> Hit(path, lineOf(source, match.range.first), match.value.replace(WHITESPACE, "")) }
            .distinctBy { it.line }

    /** [index] の文字が何行目か（1 始まり）。 */
    private fun lineOf(source: String, index: Int): Int = source.substring(0, index).count { it == '\n' } + 1

    private val WHITESPACE = Regex("""\s+""")
}
