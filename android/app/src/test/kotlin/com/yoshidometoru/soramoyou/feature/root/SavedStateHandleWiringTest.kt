// ⭐️ 入力を打つ 3 つの画面の ViewModel に、戻る履歴の 1 枚の保存の箱（createSavedStateHandle）を渡す結線の検査（全体レビュー 4 回目 Q09・Q10）
package com.yoshidometoru.soramoyou.feature.root

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 投稿の作成・プロフィール編集・ご意見の画面は、プロセスが落ちても打った入力が残るよう、ViewModel に保存の箱を渡す。
 * 箱は、その画面の戻る履歴の 1 枚から作ったもの（initializer の中の `createSavedStateHandle()`）でなければ残らない。
 * `SavedStateHandle()` をその場で作って渡しても型は合い、単体テストは自分で箱を作るので気づかない。
 * 本物の factory は JVM で動かせないので、SoramoyouApp.kt のソースの文字列で確かめる：3 つの ViewModel の組み立ての引数に
 * `createSavedStateHandle()` がある。
 *
 * 探す前にコメント（ブロックコメントと、行コメントの `//` から行末まで）を除く（InFlightWritesWiringTest と同じ除き方。
 * 文字列の中の `//` も消し、入れ子のブロックコメントも扱わない）。
 *
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class SavedStateHandleWiringTest {

    private val appSource = File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/root/SoramoyouApp.kt")

    private fun appCode(): String {
        assertTrue(appSource.isFile, "SoramoyouApp.kt が見つからない: ${appSource.absolutePath}")
        return withoutComments(appSource.readText())
    }

    /** [code] の中で `<name>(` の組み立ての引数（対応する閉じ括弧まで）。ちょうど 1 か所であることも確かめる（空振りで通らないように）。 */
    private fun argumentsOf(code: String, name: String): String {
        val head = "$name("
        assertEquals(1, Regex("""\b${Regex.escape(head)}""").findAll(code).count(), "$head が 1 か所ではない")
        val start = code.indexOf(head)
        var depth = 0
        var i = start + head.length - 1 // 開き括弧の位置
        while (i < code.length) {
            when (code[i]) {
                '(' -> depth++
                ')' -> {
                    depth--
                    if (depth == 0) return code.substring(start, i + 1)
                }
            }
            i++
        }
        error("$head の閉じ括弧が見つからない")
    }

    /** [code] で、3 つの ViewModel の組み立ての引数に、戻る履歴の 1 枚から作った保存の箱があるか。 */
    private fun passesEntryHandle(code: String): Boolean = VIEW_MODELS.all { ENTRY_HANDLE in argumentsOf(code, it) }

    @Test
    fun `入力を打つ3つの画面のViewModelに、戻る履歴の1枚から作った保存の箱を渡す`() {
        assertTrue(passesEntryHandle(appCode()), "3 つの ViewModel のどれかに createSavedStateHandle() を渡していない（プロセスが落ちると打った入力が消える）")
    }

    @Test
    fun `陽性対照：その場で作った箱を渡すと検出する`() {
        // 写しのままなら通る（下の false が、置き換えによるものだと言えるように）
        assertTrue(passesEntryHandle(FIXTURE))
        val line = "createSavedStateHandle(), // 投稿"
        assertEquals(1, Regex.fromLiteral(line).findAll(FIXTURE).count(), "陽性対照の写しに「$line」が 1 か所ではない")

        assertFalse(passesEntryHandle(withoutComments(FIXTURE.replace(line, "SavedStateHandle(), // 投稿"))))
    }

    @Test
    fun `陽性対照：ご意見への受け渡しを行コメントにすると検出する`() {
        assertTrue(passesEntryHandle(FIXTURE))
        val line = "createSavedStateHandle(), // ご意見"
        assertEquals(1, Regex.fromLiteral(line).findAll(FIXTURE).count(), "陽性対照の写しに「$line」が 1 か所ではない")

        assertFalse(passesEntryHandle(withoutComments(FIXTURE.replace(line, "// $line"))))
    }

    private companion object {
        /** 保存の箱を受け取る 3 つの ViewModel の組み立て。 */
        val VIEW_MODELS = listOf("PostComposerViewModel", "ProfileEditViewModel", "FeedbackViewModel")

        /** 戻る履歴の 1 枚（initializer の CreationExtras）から作った保存の箱。 */
        const val ENTRY_HANDLE = "createSavedStateHandle()"

        /** 陽性対照の写し（本物の組み立てと同じ形。本物の SoramoyouApp.kt に頼らない）。 */
        val FIXTURE = """
            val viewModel: PostComposerViewModel = viewModel(
                factory = viewModelFactory {
                    initializer {
                        PostComposerViewModel(
                            container.photoProbe,
                            container.networkMonitor.isOnline,
                            createSavedStateHandle(), // 投稿
                            mainScope(),
                        )
                    }
                },
            )
            val viewModel: ProfileEditViewModel = viewModel(
                factory = viewModelFactory {
                    initializer {
                        ProfileEditViewModel(container.profileRepository, container.networkMonitor.isOnline, createSavedStateHandle(), mainScope())
                    }
                },
            )
            val viewModel: FeedbackViewModel = viewModel(
                factory = viewModelFactory {
                    initializer {
                        FeedbackViewModel(
                            container.feedbackRepository,
                            FeedbackMetadata.currentAppVersion(),
                            createSavedStateHandle(), // ご意見
                            mainScope(),
                        )
                    }
                },
            )
        """.trimIndent() + "\n"

        /** ブロックコメント（KDoc を含む）。行コメントより先に消す（KDoc の中に `//` があると、行コメントとしてブロックの閉じまで消してしまうため）。 */
        val BLOCK_COMMENT = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)

        /** 行コメント（`//` から行末まで）。 */
        val LINE_COMMENT = Regex("""//[^\n]*""")

        fun withoutComments(source: String): String = source.replace(BLOCK_COMMENT, "").replace(LINE_COMMENT, "")
    }
}
