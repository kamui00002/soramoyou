// ⭐️ 画面名「ホーム」「プロフィール」を、戻る履歴の 1 枚ごとに 1 回だけ送る書き方のソース検査（全体レビュー 4 回目 Q13）
package com.yoshidometoru.soramoyou.feature.root

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * ホームとプロフィールの画面名は、戻る履歴の 1 枚ごとに 1 回だけ送る（回転・ダークモードの切り替えで Activity が作り直されても、
 * 上に開いた画面から戻っても送り直さない）。印は rememberSaveable で持つ（戻る履歴の 1 枚ごとに残り、作り直しでも消えない）。
 * 作り直しと戻りは JVM の単体テストでは再現できない（:app に Compose の UI テストは無い）ので、SoramoyouApp.kt の書き方を固定する
 * （SignedInNavHostSourceTest と同じ考え方）。ViewModel の onScreenShown は呼ぶたびに送る（FeedViewModelTest・ProfileViewModelTest）。
 *
 * 見るのは `composable<FeedRoute>`・`composable<ProfileRoute>` の塊。コメントを除いて空白をそろえ、次の形がちょうど 1 つあり、
 * `viewModel.onScreenShown()` がその 1 か所だけであることを確かめる：
 * `var 印 by rememberSaveable { mutableStateOf(false) }` に続く `LaunchedEffect(Unit) { if (!印) { 印 = true; 送る } }`
 * （印を立てるのと送るのは、どちらが先でもよい。印の名前も問わない）。
 *
 * コメントの除き方は SavedStateHandleWiringTest と同じ（文字列の中の `//` も消し、入れ子のブロックコメントも扱わない）。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class ScreenNameOncePerEntrySourceTest {

    private val appSource = File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/root/SoramoyouApp.kt")

    private fun appCode(): String {
        assertTrue(appSource.isFile, "SoramoyouApp.kt が見つからない: ${appSource.absolutePath}")
        return withoutComments(appSource.readText())
    }

    /** [code] のうち、[marker] の後に最初に現れる `{` から、対応する `}` までの塊。[marker] がちょうど 1 か所であることも確かめる。 */
    private fun blockAfter(code: String, marker: String): String {
        assertEquals(1, Regex.fromLiteral(marker).findAll(code).count(), "$marker が 1 か所ではない")
        val begin = code.indexOf('{', code.indexOf(marker))
        check(begin >= 0) { "$marker の後に { が無い" }
        var depth = 0
        for (i in begin until code.length) {
            when (code[i]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return code.substring(begin, i + 1)
            }
        }
        error("$marker の後の { に対応する } が無い")
    }

    /** [code] の [route] の画面が、画面名を rememberSaveable の印で戻る履歴の 1 枚ごとに 1 回だけ送るか。 */
    private fun logsOncePerEntry(code: String, route: String): Boolean {
        val block = blockAfter(code, "composable<$route>").replace(WHITESPACE, " ")
        return ONCE.findAll(block).count() == 1 && block.split(SEND).size - 1 == 1
    }

    @Test
    fun `ホームとプロフィールは、画面名を戻る履歴の1枚ごとに1回だけ送る（回転・戻りで送り直さない）`() {
        val code = appCode()
        ROUTES.forEach { route ->
            assertTrue(logsOncePerEntry(code, route), "$route の画面名が rememberSaveable の印で 1 回に止まっていない（回転・戻りのたびに送り直す）")
        }
    }

    @Test
    fun `陽性対照：印を外した形（直す前の形）と、印をrememberにした形を検出する`() {
        // 写しのままなら通る（下の false が、置き換えによるものだと言えるように）
        assertTrue(ROUTES.all { logsOncePerEntry(FIXTURE, it) })
        val guarded = FEED_GUARDED.trimEnd()
        assertEquals(1, Regex.fromLiteral(guarded).findAll(FIXTURE).count(), "陽性対照の写しにホームの印が 1 か所ではない")
        val saveable = "var logged by rememberSaveable {"
        assertEquals(1, Regex.fromLiteral(saveable).findAll(FIXTURE).count(), "陽性対照の写しにプロフィールの印が 1 か所ではない")

        assertFalse(logsOncePerEntry(FIXTURE.replace(guarded, "LaunchedEffect(Unit) { viewModel.onScreenShown() }"), "FeedRoute"))
        assertFalse(logsOncePerEntry(FIXTURE.replace(saveable, "var logged by remember {"), "ProfileRoute"))
    }

    @Test
    fun `陽性対照：印を立てる行をコメントにした形と、印の外でもう一度送る形を検出する`() {
        assertTrue(ROUTES.all { logsOncePerEntry(FIXTURE, it) })
        val raise = "screenLogged = true\n"
        assertEquals(1, Regex.fromLiteral(raise).findAll(FIXTURE).count(), "陽性対照の写しに「$raise」が 1 か所ではない")
        val screen = "ProfileScreen(header = header)"
        assertEquals(1, Regex.fromLiteral(screen).findAll(FIXTURE).count(), "陽性対照の写しに「$screen」が 1 か所ではない")

        assertFalse(logsOncePerEntry(withoutComments(FIXTURE.replace(raise, "// $raise")), "FeedRoute"))
        assertFalse(logsOncePerEntry(FIXTURE.replace(screen, "LaunchedEffect(Unit) { viewModel.onScreenShown() }\n    $screen"), "ProfileRoute"))
    }

    private companion object {
        /** 画面名を 1 枚ごとに 1 回だけ送る画面。 */
        val ROUTES = listOf("FeedRoute", "ProfileRoute")

        /** 画面名を送る呼び出し。 */
        const val SEND = "viewModel.onScreenShown()"

        /** 空白（改行を含む）の並び。1 つの空白にそろえる。 */
        val WHITESPACE = Regex("""\s+""")

        /** 空白をそろえた塊の中の、rememberSaveable の印で 1 回に止める形（印を立てるのと送るのはどちらが先でもよい）。 */
        val ONCE = Regex(
            """\bvar (\w+) by rememberSaveable \{ mutableStateOf\(false\) \} LaunchedEffect\(Unit\) \{ if \(!\1\) \{ """ +
                """(?:\1 = true;? viewModel\.onScreenShown\(\)|viewModel\.onScreenShown\(\);? \1 = true) \} \}""",
        )

        /** 陽性対照の写しの、ホームの印の部分。 */
        val FEED_GUARDED = """
            |    LaunchedEffect(Unit) {
            |        if (!screenLogged) {
            |            screenLogged = true
            |            viewModel.onScreenShown()
            |        }
            |    }
        """.trimMargin() + "\n"

        /** 陽性対照の写し（本物と同じ形。本物の SoramoyouApp.kt に頼らない。プロフィールは 1 行で、送るのを先に書く）。 */
        val FIXTURE = """
            |composable<FeedRoute> { entry ->
            |    val viewModel: FeedViewModel = viewModel(factory = viewModelFactory { initializer { FeedViewModel(mainScope()) } })
            |    var screenLogged by rememberSaveable { mutableStateOf(false) }
            |
        """.trimMargin() + FEED_GUARDED + """
            |    FeedScreen(state = state)
            |}
            |composable<ProfileRoute> { entry ->
            |    var logged by rememberSaveable { mutableStateOf(false) }
            |    LaunchedEffect(Unit) { if (!logged) { viewModel.onScreenShown(); logged = true } }
            |    ProfileScreen(header = header)
            |}
        """.trimMargin() + "\n"

        /** ブロックコメント（KDoc を含む）。行コメントより先に消す（KDoc の中に `//` があると、行コメントとしてブロックの閉じまで消してしまうため）。 */
        val BLOCK_COMMENT = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)

        /** 行コメント（`//` から行末まで）。 */
        val LINE_COMMENT = Regex("""//[^\n]*""")

        fun withoutComments(source: String): String = source.replace(BLOCK_COMMENT, "").replace(LINE_COMMENT, "")
    }
}
