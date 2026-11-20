// ⭐️ 編集機能の後始末と部品が、AppContainer と SoramoyouApp で正しくつながっている結線の検査（Kiro android-edit-tools 19.2・設計への問い 20）
package com.yoshidometoru.soramoyou.di

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 本物の AppContainer・画面は単体テストで作れないので、ソースの文字列で結線を確かめる（InFlightWritesWiringTest と同じ書き方）：
 * - ログアウト（DefaultAuthRepository）と退会（DefaultAccountDeletionService）の組み立てが、それぞれ `purger` を受け取る。
 *   2 つは別々に確かめる（ファイルのどこかに purger があるだけでは、片方を消しても通ってしまうため）。
 * - 後始末（DefaultUserEditDataPurger）を作るのは 1 か所。置き場（EditFileStore.forApp）を作るのも 1 か所。
 *   置き場の根が `noBackupFilesDir` であることは、組み立ての源には出ない（EditFileStore.forApp の中の 1 行。端末の EditFilesDeviceTest が見る）。
 * - 画面側の PostComposerViewModel の組み立てに、アプリの寿命のスコープと編集の各部品が渡る。
 *
 * 探す前にコメントを除く（コメントの中の文字に当たって通らないように。InFlightWritesWiringTest と同じ除き方）。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class EditWiringTest {

    private val appContainer = File("src/main/kotlin", FirebaseInstanceCreationScanner.ALLOWED_PATH)
    private val soramoyouApp = File("src/main/kotlin", "com/yoshidometoru/soramoyou/feature/root/SoramoyouApp.kt")

    private fun codeOf(file: File): String {
        assertTrue(file.isFile, "${file.name} が見つからない: ${file.absolutePath}")
        return withoutComments(file.readText())
    }

    @Test
    fun `ログアウトの組み立てが後始末を受け取る`() {
        assertTrue(passesPurger(codeOf(appContainer), "DefaultAuthRepository"), "DefaultAuthRepository の組み立てに purger が無い")
    }

    @Test
    fun `退会の組み立てが後始末を受け取る`() {
        assertTrue(passesPurger(codeOf(appContainer), "DefaultAccountDeletionService"), "DefaultAccountDeletionService の組み立てに purger が無い")
    }

    @Test
    fun `後始末を作るのは1か所`() {
        assertEquals(1, Regex.fromLiteral("DefaultUserEditDataPurger(").findAll(codeOf(appContainer)).count())
    }

    @Test
    fun `編集の置き場を作るのは1か所`() {
        assertEquals(1, Regex.fromLiteral("EditFileStore.forApp(").findAll(codeOf(appContainer)).count())
    }

    @Test
    fun `画面の編集の ViewModel の組み立てに、アプリのスコープと編集の各部品が渡る`() {
        val args = argumentsOf(codeOf(soramoyouApp), "PostComposerViewModel")
        val missing = SCREEN_PARTS.filterNot { Regex("""\bcontainer\.$it\b""").containsMatchIn(args) }
        assertTrue(missing.isEmpty(), "PostComposerViewModel の組み立てに渡っていない: $missing")
    }

    @Test
    fun `陽性対照：片方の purger を消すと、その片方だけ検出する`() {
        assertTrue(passesPurger(FIXTURE, "DefaultAuthRepository"))
        assertTrue(passesPurger(FIXTURE, "DefaultAccountDeletionService"))
        val line = "purger = editDataPurger,\n"
        // 先頭（ログアウト）の 1 つだけを消す
        val withoutAuth = FIXTURE.replaceFirst(line, "")
        assertEquals(FIXTURE.length - line.length, withoutAuth.length, "陽性対照の写しから purger の行を消せていない")
        assertFalse(passesPurger(withoutAuth, "DefaultAuthRepository"))
        assertTrue(passesPurger(withoutAuth, "DefaultAccountDeletionService"))
        // 最後（退会）の 1 つだけを消す
        val withoutDeletion = FIXTURE.reversed().replaceFirst(line.reversed(), "").reversed()
        assertTrue(passesPurger(withoutDeletion, "DefaultAuthRepository"))
        assertFalse(passesPurger(withoutDeletion, "DefaultAccountDeletionService"))
    }

    @Test
    fun `陽性対照：purger を行コメントにすると検出する`() {
        assertTrue(passesPurger(FIXTURE, "DefaultAuthRepository"))
        val commented = FIXTURE.replaceFirst("purger = editDataPurger,", "// purger = editDataPurger,")
        assertFalse(passesPurger(withoutComments(commented), "DefaultAuthRepository"))
    }

    private companion object {
        /** 画面の組み立てに渡るはずの container の部品（SoramoyouApp の PostComposerViewModel の引数のうち、編集機能のもの）。 */
        val SCREEN_PARTS = listOf(
            "appScope",
            "editSessionStore",
            "localDraftRepository",
            "loadoutStore",
            "workingPhotoImporter",
            "editPreviewRenderer",
        )

        /** [code] の `<name>(` の組み立ての引数に、`purger` の受け渡し（`purger = `）があるか。 */
        fun passesPurger(code: String, name: String): Boolean =
            Regex("""\bpurger\s*=\s*editDataPurger\b""").containsMatchIn(argumentsOf(code, name))

        /** [code] の中で `<name>(` の組み立ての括弧の中だけ（対応する閉じ括弧まで）。ちょうど 1 か所であることも確かめる。 */
        fun argumentsOf(code: String, name: String): String {
            val head = "$name("
            assertEquals(1, Regex.fromLiteral(head).findAll(code).count(), "$head が 1 か所ではない")
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

        /** 陽性対照の写し（本物の組み立てと同じ形。本物の AppContainer に頼らない）。 */
        val FIXTURE = """
            val authRepository: AuthRepository = DefaultAuthRepository(
                FirebaseAuthClient(FirebaseAuth.getInstance(firebaseApp).also { it.useEmulator(HOST, PORT) }),
                sessionManager,
                inFlightWrites,
                purger = editDataPurger,
            )
            val accountDeletionService: AccountDeletionService = DefaultAccountDeletionService(
                auth = authRepository,
                currentUid = { (authRepository.session.value as? SessionState.SignedIn)?.uid },
                purger = editDataPurger,
            )
        """.trimIndent() + "\n"

        /** ブロックコメント（KDoc を含む）。行コメントより先に消す。 */
        val BLOCK_COMMENT = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)

        /** 行コメント（`//` から行末まで）。 */
        val LINE_COMMENT = Regex("""//[^\n]*""")

        fun withoutComments(source: String): String = source.replace(BLOCK_COMMENT, "").replace(LINE_COMMENT, "")
    }
}
