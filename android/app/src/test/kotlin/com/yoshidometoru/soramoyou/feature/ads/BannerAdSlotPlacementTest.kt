// ⭐️ バナー広告の枠が、本文と重ならない置き方になっていることのソース検査（タスク 32.2・要件 14.5・16.6）
package com.yoshidometoru.soramoyou.feature.ads

import com.yoshidometoru.soramoyou.feature.root.AccountDeletionRoute
import com.yoshidometoru.soramoyou.feature.root.BlockListRoute
import com.yoshidometoru.soramoyou.feature.root.FeedRoute
import com.yoshidometoru.soramoyou.feature.root.FeedbackRoute
import com.yoshidometoru.soramoyou.feature.root.PostComposeRoute
import com.yoshidometoru.soramoyou.feature.root.PostDetailRoute
import com.yoshidometoru.soramoyou.feature.root.ProfileEditRoute
import com.yoshidometoru.soramoyou.feature.root.ProfileRoute
import com.yoshidometoru.soramoyou.feature.root.SettingsRoute
import com.yoshidometoru.soramoyou.feature.root.UserProfileRoute
import com.yoshidometoru.soramoyou.feature.root.showsBannerAt
import java.io.File
import kotlin.reflect.KClass
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 画面の描画は JVM の単体テストでは確かめられない（端末の文字サイズ 200% での見え方は端末で確かめる）。
 * そこで「重ならない」を、置き方の構造として検査する。
 *
 * - 枠は、いちばん外側の画面の Scaffold の bottomBar に置く。Scaffold は bottomBar の高さの分だけ本文の領域を縮めるので、
 *   本文（画像・操作ボタン）の上に重なる経路が無い。本文の中や、ログイン前の画面には置かない。
 *   枠の呼び出しは src/main/kotlin の全部のファイルで数える（本文やログイン前の画面のファイルに置く形も拾う・レビュー 4 回目 Q26）
 * - 枠の中は、広告を他の部品の上へ動かす書き方（offset・zIndex・Popup・Dialog）を使わない
 * - 枠の高さは、広告 SDK が求める px（AdSize の getHeightInPixels）から決め、dp の規格のまま Compose に渡さない。
 *   Compose は dp を四捨五入で px にするので、密度によっては 1px 欠け、広告 SDK が足りないと言う（2026-11-08・32.2）
 * - 設定の画面には出さない（iOS 版と同じ。投稿の画面には出す）。出さない行き先は SoramoyouApp.kt の ROUTES_WITHOUT_BANNER の
 *   1 か所で決め、bottomBar はその判定（[showsBannerAt]）を通す。判定そのものは純関数なので、ここで直接確かめる
 *
 * 見るのは文字列なので、コメントの中の一致も数える（説明には、点と丸括弧を付けた呼び出しの形を書かない。
 * src/main/kotlin のどのファイルの説明にも、丸括弧を付けた枠の呼び出しの形を書かない）。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class BannerAdSlotPlacementTest {

    private val appSource = File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/root/SoramoyouApp.kt")
    private val slotSource = File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/ads/BannerAdSlot.kt")
    private val mainSources = File("src/main/kotlin")

    /** 枠の呼び出し（宣言の `fun BannerAdSlot(` は除く）。 */
    private val bannerCall = Regex("""(?<!fun )\bBannerAdSlot\(""")

    /** [sources]（ファイルの場所→中身）のうち、枠の呼び出しがあるファイルと、その数。 */
    private fun bannerCallSites(sources: Map<String, String>): Map<String, Int> =
        sources.mapValues { (_, text) -> bannerCall.findAll(text).count() }.filterValues { it > 0 }

    /** [source] のうち、[marker] の後に最初に現れる `{` から、対応する `}` までの塊（波括弧を含む）。 */
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

    /** 広告を他の部品の上へ動かす書き方の一致した行。 */
    private fun overlapHits(source: String): List<String> =
        Regex("""\.\s*(offset|absoluteOffset|zIndex)\s*\(|\b(Popup|Dialog|AlertDialog)\s*\(""")
            .findAll(source).map { it.value.replace(Regex("""\s+"""), "") }.toList()

    /** 枠の高さを dp の規格のまま決める書き方の一致（広告の規格の dp を読む・高さに dp の値をそのまま渡す）。 */
    private fun dpFrameHeightHits(source: String): List<String> =
        Regex("""BANNER_SIZE\.height\b|\.height\(\s*[\w.]+\.dp\s*\)""").findAll(source).map { it.value }.toList()

    /** 行き先をルートの型そのもので表したときの、行き先がそのルートかの判定（本物の NavDestination.hasRoute の代わり）。 */
    private fun showsBannerAtRoute(current: KClass<*>?): Boolean = showsBannerAt(current) { destination, route -> destination == route }

    @Test
    fun `枠はいちばん外側のScaffoldのbottomBarにあり、ログイン済みで出す行き先のときだけ置く`() {
        assertTrue(appSource.isFile, "SoramoyouApp.kt が見つからない: ${appSource.absolutePath}")

        val bottomBar = blockAfter(appSource.readText(), "bottomBar =")

        assertTrue("BannerAdSlot(" in bottomBar, "bottomBar に BannerAdSlot が無い: $bottomBar")
        assertTrue("RootScreen.SIGNED_IN" in bottomBar, "ログイン済みのときだけ、という条件が無い: $bottomBar")
        assertTrue("showsBannerAt(" in bottomBar, "出さない行き先の判定（showsBannerAt）を通していない: $bottomBar")
        // 行き先の判定は、Navigation の本物の hasRoute で行う（純関数の単体テストは比較を差し替えるので、本番の配線はここで見る。
        // 実際に設定で消えるかは端末で確かめる・33.2）
        assertTrue("hasRoute(" in bottomBar, "行き先の判定に Navigation の hasRoute を使っていない: $bottomBar")
    }

    @Test
    fun `設定の画面ではバナーを出さない`() {
        assertFalse(showsBannerAtRoute(SettingsRoute::class))
    }

    @Test
    fun `設定の下のブロック中のユーザーの画面でもバナーを出さない`() {
        // 32.2 の判断（設定の下に足す画面にも出さない）。タスク 29.2 で ROUTES_WITHOUT_BANNER に足した
        assertFalse(showsBannerAtRoute(BlockListRoute::class))
    }

    @Test
    fun `設定の下のご意見・ご要望の画面でもバナーを出さない`() {
        // 32.2 の判断（設定の下に足す画面にも出さない）。タスク 30 で ROUTES_WITHOUT_BANNER に足した
        assertFalse(showsBannerAtRoute(FeedbackRoute::class))
    }

    @Test
    fun `設定の下のアカウントの削除の画面でもバナーを出さない`() {
        // 32.2 の判断（設定の下に足す画面にも出さない。退会の確認画面）。タスク 31.5 で ROUTES_WITHOUT_BANNER に足した
        assertFalse(showsBannerAtRoute(AccountDeletionRoute::class))
    }

    @Test
    fun `設定のほかの行き先では、投稿の画面を含めてバナーを出す`() {
        listOf(
            FeedRoute::class,
            PostComposeRoute::class,
            PostDetailRoute::class,
            ProfileRoute::class,
            ProfileEditRoute::class,
            UserProfileRoute::class,
        ).forEach { route ->
            assertTrue(showsBannerAtRoute(route), "$route でバナーを出していない")
        }
    }

    @Test
    fun `行き先がまだ分からないあいだはバナーを出さない`() {
        // NavHost がグラフを置く前の最初の描画。出さない行き先で、一瞬だけ広告を要求して捨てることにならないように
        assertFalse(showsBannerAtRoute(null))
    }

    @Test
    fun `枠の呼び出しはbottomBarの1か所だけで、本文やログイン前の画面には無い`() {
        val source = appSource.readText()
        val bottomBar = blockAfter(source, "bottomBar =")
        // SoramoyouApp.kt だけを数えると、本文やログイン前の画面のファイルに置いた呼び出しを見逃す（レビュー 4 回目 Q26）
        val sources = mainSources.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .associate { it.relativeTo(mainSources).invariantSeparatorsPath to it.readText() }
        val app = appSource.relativeTo(mainSources).invariantSeparatorsPath

        assertEquals(mapOf(app to 1), bannerCallSites(sources), "BannerAdSlot の呼び出しが SoramoyouApp.kt の 1 か所でない")
        assertTrue("BannerAdSlot(" !in source.replace(bottomBar, ""), "bottomBar の外に BannerAdSlot の呼び出しがある")
    }

    @Test
    fun `枠の中は、広告を他の部品の上へ動かす書き方をしない`() {
        assertTrue(slotSource.isFile, "BannerAdSlot.kt が見つからない: ${slotSource.absolutePath}")

        assertEquals(emptyList(), overlapHits(slotSource.readText()), "BannerAdSlot.kt が広告を重ねうる書き方をしている")
    }

    @Test
    fun `枠の高さは広告SDKのpxから決め、dpの規格のまま渡さない`() {
        assertTrue(slotSource.isFile, "BannerAdSlot.kt が見つからない: ${slotSource.absolutePath}")
        val source = slotSource.readText()

        assertTrue("getHeightInPixels(" in source, "枠の高さに広告 SDK の px（getHeightInPixels）を使っていない")
        assertEquals(emptyList(), dpFrameHeightHits(source), "枠の高さを dp の規格のまま決めている")
    }

    @Test
    fun `陽性対照：dpの規格のまま決める書き方を検出する`() {
        // 直す前の BannerAdSlot.kt の書き方と、数字を直に書いた形
        val bad = """
            val frameHeightDp = bannerFrameHeightDp(slot, BANNER_SIZE.height, rememberImeVisible())
            Box(modifier = modifier.fillMaxWidth().height(frameHeightDp.dp).clipToBounds())
            Box(modifier = Modifier.height( 50.dp ))
        """.trimIndent()

        assertEquals(listOf("BANNER_SIZE.height", ".height(frameHeightDp.dp)", ".height( 50.dp )"), dpFrameHeightHits(bad))
    }

    @Test
    fun `陽性対照：重ねる書き方を検出する`() {
        val bad = """
            val a = Modifier.offset(y = (-48).dp)
            val b = Modifier
                .zIndex(1f)
            val c = Modifier.absoluteOffset(x = 1.dp)
            Popup(onDismissRequest = {}) { }
            Dialog(onDismissRequest = {}) { }
        """.trimIndent()

        assertEquals(listOf(".offset(", ".zIndex(", ".absoluteOffset(", "Popup(", "Dialog("), overlapHits(bad))
    }

    @Test
    fun `陽性対照：置き場所の検査は、本文の側に置いた呼び出しを見逃さない`() {
        val source = """
            Scaffold(
                bottomBar = { if (screen == RootScreen.SIGNED_IN) BannerAdSlot(container.adsController) },
            ) { padding ->
                BannerAdSlot(container.adsController)
            }
        """.trimIndent()

        val bottomBar = blockAfter(source, "bottomBar =")

        assertEquals(2, Regex("""BannerAdSlot\(""").findAll(source).count())
        assertTrue("BannerAdSlot(" in source.replace(bottomBar, ""), "本文の側の呼び出しを検出できていない")
    }

    @Test
    fun `陽性対照：呼び出しの数え上げは、ほかのファイルの呼び出しを拾い、宣言と括弧の無い名前は数えない`() {
        val sources = mapOf(
            "feature/root/SoramoyouApp.kt" to "bottomBar = { BannerAdSlot(container.adsController) }",
            "feature/feed/FeedScreen.kt" to "com.yoshidometoru.soramoyou.feature.ads.BannerAdSlot(adsController)",
            "feature/ads/BannerAdSlot.kt" to "fun BannerAdSlot(adsController: AdsController, modifier: Modifier = Modifier) { }",
            "feature/auth/LoginScreen.kt" to "// 枠（BannerAdSlot）はここに置かない",
        )

        assertEquals(mapOf("feature/root/SoramoyouApp.kt" to 1, "feature/feed/FeedScreen.kt" to 1), bannerCallSites(sources))
    }
}
