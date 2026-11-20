// ⭐️ AppContainer の Firestore の入れ物が、メモリだけの設定を当てているかをソースから読む走査器（タスク 5.1 のテスト用）
package com.yoshidometoru.soramoyou.di

import java.io.File

/**
 * [FirestoreMemoryCacheWiringTest] で使う走査器。AppContainer のソースから、Firestore の入れ物
 * （`ResettableInstance<FirebaseFirestore>` を作る呼び出し）の丸括弧の中身だけを切り出し、次の 2 つを読む。
 * - configure が、得たインスタンス（`it` か名前を付けた引数）に FirestoreSettingsFactory の memoryOnly の設定を当てているか
 * - release の中で、terminate を clearPersistence より前に書いているか（ソースの並び。実行の順は ResettableInstanceTest が確かめる）
 *
 * 探すのは文字列で、どの書き方も間に空白・改行を挟んでも一致する。読む範囲を入れ物の丸括弧の中に限るので、
 * ファイルのほかの場所（コメント・別の入れ物）に同じ書き方があっても数えない。
 * 丸括弧の中身は、半角の丸括弧の対応で切り出す。その範囲の文字列やコメントに半角の丸括弧が片方だけあると切り出しを誤る
 * （いまの AppContainer には無い）。
 */
internal object FirestoreMemoryCacheWiringScanner {

    /** Firestore の入れ物から読んだ結線。 */
    data class Wiring(
        /** configure が memoryOnly の設定を当てている。 */
        val configuresMemoryOnly: Boolean,
        /** release の中で terminate を clearPersistence より前に書いている。 */
        val terminatesBeforeClearPersistence: Boolean,
    )

    /**
     * Firestore の入れ物を作る呼び出しの、開きの丸括弧まで。
     * `ResettableInstance<FirebaseFirestore> = ResettableInstance(`（型を書いた宣言）と `ResettableInstance<FirebaseFirestore>(` の両方に一致する。
     */
    private val CONTAINER_CALL =
        Regex("""\bResettableInstance\s*<\s*FirebaseFirestore\s*>\s*(?:=\s*ResettableInstance\s*(?:<\s*FirebaseFirestore\s*>\s*)?)?\(""")

    /** configure の引数で、得たインスタンスに memoryOnly の設定を当てる書き方（プロパティへの代入と setter の呼び出しの両方）。 */
    private val CONFIGURE_MEMORY_ONLY = Regex(
        """\bconfigure\s*=\s*\{\s*(?:it|(\w+)\s*->\s*\1)\s*\.\s*(?:firestoreSettings\s*=|setFirestoreSettings\s*\()""" +
            """\s*FirestoreSettingsFactory\s*\.\s*memoryOnly\s*\(\s*\)""",
    )

    private val RELEASE = Regex("""\brelease\s*=""")
    private val TERMINATE = Regex("""\.\s*terminate\s*\(\s*\)""")
    private val CLEAR_PERSISTENCE = Regex("""\.\s*clearPersistence\s*\(\s*\)""")

    /** [file] の中の Firestore の入れ物を読む。入れ物が見つからない（閉じの丸括弧が無い場合を含む）なら null。 */
    fun inspect(file: File): Wiring? {
        val arguments = containerArguments(file.readText()) ?: return null
        return Wiring(
            configuresMemoryOnly = CONFIGURE_MEMORY_ONLY.containsMatchIn(arguments),
            terminatesBeforeClearPersistence = terminatesBeforeClearPersistence(arguments),
        )
    }

    /** Firestore の入れ物を作る呼び出しの、丸括弧の中身。最初に見つかった入れ物だけを読む。 */
    private fun containerArguments(source: String): String? {
        val open = CONTAINER_CALL.find(source) ?: return null
        val start = open.range.last + 1
        var depth = 1
        for (index in start until source.length) {
            when (source[index]) {
                '(' -> depth++
                ')' -> if (--depth == 0) return source.substring(start, index)
            }
        }
        return null
    }

    /** release の引数より後で、terminate が clearPersistence より前に現れるか。どちらかが無ければ false。 */
    private fun terminatesBeforeClearPersistence(arguments: String): Boolean {
        val release = RELEASE.find(arguments) ?: return false
        val rest = arguments.substring(release.range.last + 1)
        val terminate = TERMINATE.find(rest) ?: return false
        val clear = CLEAR_PERSISTENCE.find(rest) ?: return false
        return terminate.range.first < clear.range.first
    }
}
