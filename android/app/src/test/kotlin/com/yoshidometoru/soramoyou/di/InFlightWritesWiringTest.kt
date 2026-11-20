// ⭐️ AppContainer が、走っている取り消さない書き込みの数を 1 つだけ作り、保存・削除・ログアウトに同じものを渡す結線の検査（全体レビュー 4 回目 Q03）
package com.yoshidometoru.soramoyou.di

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * ログアウト（DefaultAuthRepository）は、プロフィールの保存（DefaultProfileEditor）・投稿の削除（DefaultPostDeleter）が数えた
 * 書き込みの終わりを待つ。3 つが別々の数え上げを持つと、待つ側は自分の数え上げ（いつも 0）を見て待たずに進むが、
 * 単体テストはそれぞれ自分で数え上げを作るので気づかない。本物の AppContainer は作れないので、ソースの文字列で確かめる：
 * - 数え上げ（`InFlightWrites()`）を作るのは 1 か所だけ
 * - 3 つの部品の組み立ての引数に、その 1 つ（`inFlightWrites`）がある
 *
 * 探す前にコメント（ブロックコメントと、行コメントの `//` から行末まで）を除く（StorageRetryLimitWiringTest と同じ除き方。
 * 文字列の中の `//` も消し、入れ子のブロックコメントも扱わない）。
 *
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class InFlightWritesWiringTest {

    private val appContainer = File("src/main/kotlin", FirebaseInstanceCreationScanner.ALLOWED_PATH)

    private fun appContainerCode(): String {
        assertTrue(appContainer.isFile, "AppContainer が見つからない: ${appContainer.absolutePath}")
        return withoutComments(appContainer.readText())
    }

    /** [code] の中で `<name>(` の組み立ての引数（対応する閉じ括弧まで）。ちょうど 1 か所であることも確かめる（空振りで通らないように）。 */
    private fun argumentsOf(code: String, name: String): String {
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

    /** [code] が数え上げを 1 か所だけで作り、3 つの部品にその 1 つを渡しているか。 */
    private fun sharesOneCounter(code: String): Boolean =
        Regex("""\bInFlightWrites\(\)""").findAll(code).count() == 1 &&
            CONSUMERS.all { USES_COUNTER.containsMatchIn(argumentsOf(code, it)) }

    @Test
    fun `数え上げを1つだけ作り、保存・削除・ログアウトに同じものを渡す`() {
        assertTrue(sharesOneCounter(appContainerCode()), "AppContainer が InFlightWrites を 1 つだけ作って 3 つの部品に渡していない")
    }

    @Test
    fun `陽性対照：ログアウトに別の数え上げを渡すと検出する`() {
        // 写しのままなら通る（下の false が、置き換えによるものだと言えるように）
        assertTrue(sharesOneCounter(FIXTURE))
        val line = "    inFlightWrites,\n"
        assertEquals(1, Regex.fromLiteral(line).findAll(FIXTURE).count(), "陽性対照の写しに「${line.trim()}」が 1 か所ではない")

        assertFalse(sharesOneCounter(FIXTURE.replace(line, "    InFlightWrites(),\n")))
    }

    @Test
    fun `陽性対照：プロフィールの保存への受け渡しを行コメントにすると検出する`() {
        assertTrue(sharesOneCounter(FIXTURE))
        val line = "inFlight = inFlightWrites, // 保存"
        assertEquals(1, Regex.fromLiteral(line).findAll(FIXTURE).count(), "陽性対照の写しに「$line」が 1 か所ではない")

        assertFalse(sharesOneCounter(withoutComments(FIXTURE.replace(line, "// $line"))))
    }

    private companion object {
        /** 数え上げを受け取る 3 つの部品の組み立て。 */
        val CONSUMERS = listOf("DefaultAuthRepository", "DefaultProfileEditor", "DefaultPostDeleter")

        /** 組み立ての引数に、AppContainer の数え上げ（`inFlightWrites`）がある。 */
        val USES_COUNTER = Regex("""\binFlightWrites\b""")

        /** 陽性対照の写し（本物の組み立てと同じ形。本物の AppContainer に頼らない）。 */
        val FIXTURE = """
            val inFlightWrites: InFlightWrites = InFlightWrites()
            val authRepository: AuthRepository = DefaultAuthRepository(
                FirebaseAuthClient(FirebaseAuth.getInstance(firebaseApp).also { it.useEmulator(HOST, PORT) }),
                sessionManager,
                inFlightWrites,
            )
            val profileEditor: ProfileEditor = DefaultProfileEditor(
                gateway = firestoreWriteGateway,
                analytics = analytics,
                inFlight = inFlightWrites, // 保存
            )
            val postDeleter: PostDeleter = DefaultPostDeleter(
                currentUid = { (authRepository.session.value as? SessionState.SignedIn)?.uid },
                inFlight = inFlightWrites,
            )
        """.trimIndent() + "\n"

        /** ブロックコメント（KDoc を含む）。行コメントより先に消す（KDoc の中に `//` があると、行コメントとしてブロックの閉じまで消してしまうため）。 */
        val BLOCK_COMMENT = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)

        /** 行コメント（`//` から行末まで）。 */
        val LINE_COMMENT = Regex("""//[^\n]*""")

        fun withoutComments(source: String): String = source.replace(BLOCK_COMMENT, "").replace(LINE_COMMENT, "")
    }
}
