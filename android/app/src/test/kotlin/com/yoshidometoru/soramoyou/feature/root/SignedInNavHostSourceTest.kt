// ⭐️ ログイン後のナビゲーションの、二度押しの守り（戻る・閉じる・開く）と、ログアウトで画面の ViewModel を捨てる owner のソース検査（レビュー R04・R23）
package com.yoshidometoru.soramoyou.feature.root

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 二度押し（出ていく画面がフェードの間も押せる）で戻る履歴が空になることと、ログアウトの後に画面の ViewModel が残ることは、
 * JVM の単体テストでは再現できない（:app に Compose の UI テストは無い。端末では「投稿完了の OK を連打」「詳細の戻るを連打」と、
 * ログアウトしてログインし直す流れを見る）。そこで SoramoyouApp.kt の書き方を固定する（AccountDeletionScreenLayoutTest と同じ考え方）。
 *
 * - 利用者が押す戻る・閉じるは守り（popFrom）を通す。守りを通さずに戻すのは、LaunchedEffect の中の自動の閉じる 3 か所だけ
 * - 利用者が押す開くは守り（navigateFrom）を通す。守りを通さない開くは無い
 * - 守りは「その画面がまだ戻る履歴の一番上か」を id で比べてから戻す・開く
 * - 本文で NavController（navController）に触るのは、守り・自動の閉じる 3 か所・NavHost に渡す引数だけ。navigateUp()・
 *   関数の参照（::popBackStack）・別の名前に入れる、のような `popBackStack(`・`navigate(` の文字列に当たらない書き方も、
 *   名前の出現を許すものだけに限ることで拾う（レビュー 4 回目 Q19）
 * - NavHost は、ログイン中だけの ViewModelStoreOwner の下に置く
 *
 * 守りを通す数（戻る・閉じる 9・開く 12）は、本文から計算せずに数で書く。0 件だけを見ると、守りごと消しても通ってしまうため。
 * 押す操作のある画面を足したら、この数を直す。
 *
 * 見るのは文字列なので、コメントの中の一致も数える（SignedInNavHost の本文のコメントには、戻す・開く呼び出しの形と
 * navController の名前を書かない）。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class SignedInNavHostSourceTest {

    private val appSource = File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/root/SoramoyouApp.kt")

    /** 自動の閉じる（消し終えた・投稿者をブロックできた・保存できた）。状態で 1 回に限られているので守りを通さずに残す。 */
    private val autoCloses = listOf(
        "LaunchedEffect(deleteState.deleted) { if (deleteState.deleted) navController.popBackStack() }",
        "LaunchedEffect(moderation.blockedAuthor) { if (moderation.blockedAuthor != null) navController.popBackStack() }",
        "LaunchedEffect(state.saved) { if (state.saved) navController.popBackStack() }",
    )

    /** 本文で NavController に触ってよいもの（NavHost に渡す引数・守り・自動の閉じる）。 */
    private val allowedNavUses = listOf("NavHost(navController = navController", "navController.popFrom(", "navController.navigateFrom(") + autoCloses

    /** NavController の名前（ほかの名前の一部には当たらない）。 */
    private val navControllerName = Regex("""\bnavController\b""")

    /** [source] のうち、[marker] の後に最初に現れる `{` から、対応する `}` までの塊（AccountDeletionScreenLayoutTest の同名の補助と同じ）。 */
    private fun blockAfter(source: String, marker: String): String {
        val markerAt = source.indexOf(marker)
        check(markerAt >= 0) { "$marker が見つからない" }
        val begin = source.indexOf('{', markerAt)
        check(begin >= 0) { "$marker の後に { が無い" }
        var depth = 0
        for (i in begin until source.length) {
            when (source[i]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return source.substring(begin, i + 1)
            }
        }
        error("$marker の後の { に対応する } が無い")
    }

    private fun source(): String {
        assertTrue(appSource.isFile, "SoramoyouApp.kt が見つからない: ${appSource.absolutePath}")
        return appSource.readText()
    }

    /** SignedInNavHost の本文（関数の `{` から `}` まで）。 */
    private fun navHostBody(): String = blockAfter(source(), "private fun SignedInNavHost(")

    /** [needle] が重ならずに現れる数。 */
    private fun String.countOf(needle: String): Int = split(needle).size - 1

    /**
     * [body] のうち、NavController に守りを通さずに触る行（触ってよいものを除いても、名前が残る行）。
     * 行ごとに見るので、触ってよいものを途中で折り返して書くと、それも拾う（赤になる側に倒れる）。
     */
    private fun unguardedNavUses(body: String): List<String> =
        body.lines().filter { line ->
            navControllerName.containsMatchIn(allowedNavUses.fold(line) { rest, use -> rest.replace(use, "") })
        }

    @Test
    fun `押す戻る・閉じるは守りを通し、守りを通さずに戻すのはLaunchedEffectの中の自動の閉じる3か所だけ`() {
        val body = navHostBody()
        val bare = body.lines().filter { "popBackStack(" in it }

        assertEquals(3, bare.size, "守りを通さない戻すが、自動の閉じる 3 か所と合わない:\n${bare.joinToString("\n")}")
        assertTrue(
            bare.all { "LaunchedEffect(" in it },
            "LaunchedEffect の外に守りを通さない戻すがある（二度押しで戻る履歴が空になる）:\n${bare.joinToString("\n")}",
        )
        autoCloses.forEach { effect -> assertTrue(effect in body, "自動の閉じるが無い: $effect") }
        assertEquals(9, body.countOf("navController.popFrom("), "守りを通す戻る・閉じるの数が合わない（押す戻る・閉じるを守りから外した？）")
    }

    @Test
    fun `押す開くは守りを通し、守りを通さない開くは無い`() {
        val body = navHostBody()
        val bare = body.lines().filter { "navigate(" in it }

        assertEquals(emptyList(), bare, "守りを通さない開くがある（二度押しで同じ画面を 2 枚積む）")
        assertEquals(12, body.countOf("navController.navigateFrom("), "守りを通す開くの数が合わない（押す開くを守りから外した？）")
    }

    @Test
    fun `本文でNavControllerに触るのは、守り・LaunchedEffectの中の自動の閉じる3か所・NavHostの引数だけ`() {
        // 画面を足すときに navigateUp()・::popBackStack・popBackStack<型>・別の名前に入れる、で書くと、上の 2 本の文字列の検査に
        // 当たらず、守りの数も減らないので緑のまま守りを通さない戻る・開くが入る（レビュー 4 回目 Q19）
        assertEquals(emptyList(), unguardedNavUses(navHostBody()), "守りを通さずに NavController に触っている（二度押しで戻る履歴が空になる・同じ画面を 2 枚積む）")
    }

    @Test
    fun `陽性対照：守りを通さない触り方を検出し、触ってよいものは拾わない`() {
        val body = """
            NavHost(navController = navController, startDestination = FeedRoute, modifier = modifier) {
                onBack = { navController.popFrom(entry) },
                onOpenPost = { postId -> navController.navigateFrom(entry, PostDetailRoute(postId)) },
                LaunchedEffect(state.saved) { if (state.saved) navController.popBackStack() }
                onBack = { navController.navigateUp() },
                onBack = navController::popBackStack,
                onBack = { navController.popBackStack<FeedRoute>(inclusive = false) },
                val nav = navController
                onBack = { navController.popFrom(entry); navController.navigateUp() },
            }
        """.trimIndent()

        assertEquals(
            listOf(
                "onBack = { navController.navigateUp() },",
                "onBack = navController::popBackStack,",
                "onBack = { navController.popBackStack<FeedRoute>(inclusive = false) },",
                "val nav = navController",
                "onBack = { navController.popFrom(entry); navController.navigateUp() },",
            ),
            unguardedNavUses(body).map { it.trim() },
        )
    }

    @Test
    fun `守りは、その画面がまだ戻る履歴の一番上かをidで比べてから戻す・開く`() {
        val source = source()
        val pop = blockAfter(source, "private fun NavHostController.popFrom(entry: NavBackStackEntry)")
        val open = blockAfter(source, "private fun <T : Any> NavHostController.navigateFrom(entry: NavBackStackEntry, route: T)")

        assertTrue("if (currentBackStackEntry?.id == entry.id) popBackStack()" in pop, "戻るの守りが一番上の画面かを id で比べていない: $pop")
        assertTrue("if (currentBackStackEntry?.id == entry.id) navigate(route)" in open, "開くの守りが一番上の画面かを id で比べていない: $open")
    }

    @Test
    fun `NavHostはログイン中だけのViewModelStoreOwnerの下に置き、ログアウトで画面のViewModelを捨てる`() {
        val body = navHostBody()
        val provider = "CompositionLocalProvider(LocalViewModelStoreOwner provides rememberViewModelStoreOwner())"
        val navHost = "NavHost(navController = navController"

        val providerAt = body.indexOf(provider)
        val navHostAt = body.indexOf(navHost)
        assertTrue(providerAt >= 0, "ログイン中だけの ViewModelStoreOwner を置いていない（ログアウトしても画面の ViewModel が残る）")
        assertTrue(navHostAt >= 0, "SignedInNavHost に NavHost が無い")
        assertTrue(providerAt < navHostAt, "ViewModelStoreOwner を NavHost より後に置いている")
        assertTrue(navHost in blockAfter(body, provider), "NavHost がログイン中だけの ViewModelStoreOwner の下に無い")
    }
}
