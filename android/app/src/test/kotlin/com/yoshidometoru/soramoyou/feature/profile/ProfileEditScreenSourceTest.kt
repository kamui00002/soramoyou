// ⭐️ プロフィール編集の画面の書き方の検査：表示名の欄が 1 行・オフラインの間は保存を押せず理由を出す・前の保存の間の理由（レビュー R19・R09・全体レビュー 4 回目 Q04・Q17）
package com.yoshidometoru.soramoyou.feature.profile

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 画面の描画は JVM の単体テストでは確かめられない（Robolectric も Compose の UI テストも無い。欄が 1 行で、確定のキーで次の欄へ進むことと、
 * オフラインの案内の見え方は端末で確かめる）。そこで、画面のソースの書き方を固定する（AccountDeletionScreenLayoutTest と同じ考え方）。
 * :app の単体テストの作業ディレクトリは android/app なので、`src/main` を直接読む。
 *
 * 表示名の欄の検査は、`OutlinedTextField(` の呼び出しを引数の丸括弧ごと切り出し、値が表示名の入力のもの（ちょうど 1 つ）だけを見る。
 * ほかの欄（自己紹介）の書き方で緑に化けないようにするため。見るのは文字列なので、コメントの中の一致も数える。
 * 入力の欄の案内（オフライン・前の保存）の検査は、コメントを除いたソースで見る（コメントに正しい式を残したまま分岐を壊しても、緑に化けないように）。
 */
class ProfileEditScreenSourceTest {

    private val screenSource = File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/profile/ProfileEditScreen.kt")

    private fun source(): String {
        assertTrue(screenSource.isFile, "ProfileEditScreen.kt が見つからない: ${screenSource.absolutePath}")
        return screenSource.readText()
    }

    /** [source] のうち、[from] より後に最初に現れる [open] から、対応する [close] までの塊。 */
    private fun enclosed(source: String, from: Int, open: Char, close: Char): String {
        val begin = source.indexOf(open, from)
        check(begin >= 0) { "$from 文字目より後に $open が無い" }
        var depth = 0
        for (i in begin until source.length) {
            when (source[i]) {
                open -> depth++
                close -> if (--depth == 0) return source.substring(begin, i + 1)
            }
        }
        error("$begin 文字目の $open に対応する $close が無い")
    }

    /** [source] のうち、[marker] の後に最初に現れる `{` から、対応する `}` までの塊（AccountDeletionScreenLayoutTest の blockAfter と同じ）。 */
    private fun blockAfter(source: String, marker: String): String {
        val markerAt = source.indexOf(marker)
        check(markerAt >= 0) { "$marker が見つからない" }
        return enclosed(source, markerAt, '{', '}')
    }

    /** 表示名の欄（値が表示名の入力の `OutlinedTextField(` の呼び出し）。ちょうど 1 つであることも確かめる。 */
    private fun displayNameField(): String {
        val source = source()
        val fields = mutableListOf<String>()
        var at = source.indexOf(TEXT_FIELD_CALL)
        while (at >= 0) {
            fields += enclosed(source, at, '(', ')')
            at = source.indexOf(TEXT_FIELD_CALL, at + TEXT_FIELD_CALL.length)
        }
        val displayName = fields.filter { "value = state.displayName," in it }
        assertEquals(1, displayName.size, "表示名の欄がちょうど 1 つ見つからない（欄は ${fields.size} 個）")
        return displayName.single()
    }

    // ── 表示名の欄（レビュー R19）──

    @Test
    fun `表示名の欄は1行にして、確定のキーで改行を入れない`() {
        val field = displayNameField()

        assertTrue("singleLine = true" in field, "表示名の欄が 1 行になっていない: $field")
    }

    @Test
    fun `表示名の欄の確定のキーは次の欄へ進む`() {
        val field = displayNameField()

        assertTrue("imeAction = ImeAction.Next" in field, "表示名の欄の確定のキーが次の欄へ進まない: $field")
    }

    // ── オフライン（レビュー R09）──

    @Test
    fun `保存のボタンはオフラインの間は押せない`() {
        assertTrue(
            "TextButton(onClick = onSave, enabled = state.canSave && isOnline)" in source(),
            "保存のボタンが接続の有無を見ていない",
        )
    }

    @Test
    fun `入力の欄はオフラインの間、保存できない理由を出し、保存の書き込みの途中でだけ接続が戻ると続けることを出す`() {
        val form = blockAfter(code(source()), "private fun EditForm(")
        val offline = blockAfter(form, "if (!isOnline)").replace(WHITESPACE, " ")

        // 条件と文言を 1 つの文字列で固定する（2 つのリソース名が塊にあるかだけを見ると、分岐を入れ替えても緑になる：全体レビュー 4 回目 Q17）。
        // アイコンの送信中に切れると送信は失敗して保存が終わるので、続けると出すのは書き込みの途中だけ（Q05）
        assertTrue(OFFLINE_MESSAGE in offline, "オフラインの案内が、保存の書き込みの途中でだけ「接続が戻ると保存を続けます」を出す分岐になっていない: $offline")
    }

    // ── 前に開いた画面で始めた保存（全体レビュー 4 回目 Q04）──

    @Test
    fun `前に開いた画面で始めた保存が走っている間は、保存できない理由を出す`() {
        val form = blockAfter(code(source()), "private fun EditForm(")
        val othersSaving = blockAfter(form, "if (state.isOthersSaving)")

        assertTrue("R.string.profile_edit_previous_saving" in othersSaving, "前の保存が走っている間に、保存できない理由を出していない: $othersSaving")
    }

    /** [source] からコメントを除く（除き方は LegalLinkSources と同じ。ブロックコメントを先に、行コメントを後に消す）。 */
    private fun code(source: String): String = source.replace(BLOCK_COMMENT, "").replace(LINE_COMMENT, "")

    private companion object {
        const val TEXT_FIELD_CALL = "OutlinedTextField("

        /** オフラインの案内の分岐（全体レビュー 4 回目 Q05・Q17）。空白の続きを 1 つにした塊の中に、この形のまま現れること。 */
        const val OFFLINE_MESSAGE =
            "if (state.saveStage == ProfileSaveStage.SAVING) R.string.compose_saving_offline else R.string.offline_title"

        /** ブロックコメント（KDoc を含む）。行コメントより先に消す（KDoc の中に `//` があると、行コメントとしてブロックの閉じまで消してしまうため）。 */
        val BLOCK_COMMENT = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)

        /** 行コメント（`//` から行末まで）。 */
        val LINE_COMMENT = Regex("""//[^\n]*""")

        /** 空白の続き（改行を含む）。 */
        val WHITESPACE = Regex("""\s+""")
    }
}
