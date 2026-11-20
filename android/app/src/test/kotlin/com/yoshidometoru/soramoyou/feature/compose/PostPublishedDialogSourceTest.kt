// ⭐️ 投稿完了の知らせを、iOS と同じく見出し無しで出すことのソース検査（main の取り込みの後の直し・2026-11-06 の利用者の決定）
package com.yoshidometoru.soramoyou.feature.compose

import com.yoshidometoru.soramoyou.ui.UiTextSources
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * iOS は投稿完了を、見出し（「投稿完了」）付きの alert から、見出しの無い重ね表示（`PostCompletionOverlay(message:onFinish:)`。
 * チェックマークを描いて約 1.2 秒で自動で閉じる）に替えた（PostInfoView.swift:220-233）。Android は OK で閉じるダイアログのまま、
 * 見出しだけを外す（自動で閉じる演出は合わせない。2026-11-06 の利用者の決定）。文言（compose_published_message）の一致は
 * SessionScreensStringsTest が見るので、ここでは Android のダイアログと iOS の重ね表示の両方に見出しが無いことだけを見る。
 *
 * :app に Compose の UI テストは無いので、PostComposerScreen.kt の書き方を固定する（ScreenNameOncePerEntrySourceTest と同じ考え方）。
 * コメントの除き方も同じ（文字列の中の `//` も消し、入れ子のブロックコメントも扱わない）。Swift のコメントも同じ書き方なので同じに除く。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class PostPublishedDialogSourceTest {

    private val screenSource = File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/compose/PostComposerScreen.kt")

    @Test
    fun `投稿完了のダイアログは見出しを持たない`() {
        assertTrue(screenSource.isFile, "PostComposerScreen.kt が見つからない: ${screenSource.absolutePath}")
        val dialog = blockAfter(withoutComments(screenSource.readText()), "if (state.published)", '{', '}')
        assertTrue(
            "R.string.compose_published_message" in dialog,
            "投稿完了のダイアログが compose_published_message を出していない（塊を読み違えた可能性）",
        )
        assertFalse(TITLE.containsMatchIn(dialog), "投稿完了のダイアログに見出し（title）がある（iOS は見出しを出さない）")
    }

    @Test
    fun `iOSの投稿完了は見出しの無い重ね表示で出す`() {
        val ios = withoutComments(UiTextSources.iosSource("Views/PostInfoView.swift"))
        val call = blockAfter(ios, "PostCompletionOverlay(", '(', ')')
        assertTrue(SWIFT_MESSAGE.containsMatchIn(call), "iOS の PostCompletionOverlay の呼び出しに message が無い（塊を読み違えた可能性）")
        assertFalse(SWIFT_TITLE.containsMatchIn(call), "iOS の投稿完了に見出し（title）がある（Android のダイアログの見出しを考え直す）")
    }

    private companion object {
        /** Compose の AlertDialog の見出しの引数。 */
        val TITLE = Regex("""\btitle\s*=""")

        /** Swift の呼び出しの引数のラベル。 */
        val SWIFT_MESSAGE = Regex("""\bmessage\s*:""")
        val SWIFT_TITLE = Regex("""\btitle\s*:""")

        /** ブロックコメント（KDoc を含む）。行コメントより先に消す（KDoc の中に `//` があると、行コメントとしてブロックの閉じまで消してしまうため）。 */
        val BLOCK_COMMENT = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)

        /** 行コメント（`//` から行末まで）。 */
        val LINE_COMMENT = Regex("""//[^\n]*""")

        fun withoutComments(source: String): String = source.replace(BLOCK_COMMENT, "").replace(LINE_COMMENT, "")

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
