// ⭐️ コントラスト比を計算する補助（ContrastMath）が、読めない組み合わせを本当に見つけることの単体テスト（タスク 3.1・要件 4.1・4.3）
package com.yoshidometoru.soramoyou.ui.theme

import androidx.compose.ui.graphics.Color
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * 層の表のテスト（SkyContrastTest）が使う前に、補助そのものが効いていることを確かめる（設計書の「陽性対照の手順」の 1）。
 *
 * ここに書く色は、画面の色ではなく対照のための値である（タスク 3.1）。画面の色は SkyContrastTest が画面と同じ所から読む。
 * 比の期待値は設計書の「コントラスト比の表」と同じ概算（小数第 2 位）で、許容幅はその丸めの分だけにする。
 */
class ContrastMathTest {

    /** 昼の空のいちばん上（iOS の daySkyGradient の 1 色目）。 */
    private val daySkyTop = Color(0xFFADD9E6)

    /** 昼の空のいちばん下（同じく 3 色目）。 */
    private val daySkyBottom = Color(0xFF6394ED)

    /** 夜の空のいちばん上（iOS の nightSkyGradient の 1 色目）。 */
    private val nightSkyTop = Color(0xFF263359)

    /** 今の主色。昼の空の上では本文の基準 4.5 に届かない（要件 4.3 の例）。 */
    private val currentPrimary = Color(0xFF2F5FA8)

    /** 今のいいね済みの色。昼の空の下ではアイコンの基準 3.0 に届かない。 */
    private val currentLiked = Color(0xFFD6336C)

    @Test
    fun `基準に届かない3組が違反として出て、比が設計書の表と同じになる`() {
        val checks = listOf(
            ContrastMath.Check("主色 #2F5FA8 / 昼の空の上", currentPrimary, daySkyTop, minimum = 4.5),
            ContrastMath.Check(
                "白 / 夜の空の上に白50%を重ねた色",
                Color.White,
                ContrastMath.over(Color.White.copy(alpha = 0.5f), nightSkyTop),
                minimum = 4.5,
            ),
            ContrastMath.Check("いいね済み #D6336C / 昼の空の下", currentLiked, daySkyBottom, minimum = 3.0),
        )

        val violations = ContrastMath.violations(checks)
        println("陽性対照の 3 組: " + violations.joinToString(" ／ "))

        assertEquals(checks, violations.map { it.check }, "3 組の全てが違反として出ていない: $violations")
        // 全てを違反と返す壊れた補助でも上は通るので、比の値そのものも設計書の概算と比べる
        listOf(4.17, 2.84, 1.54).zip(violations).forEach { (expected, violation) ->
            assertTrue(
                abs(violation.ratio - expected) < 0.01,
                "${violation.check.label} の比 ${violation.ratio} が設計書の $expected と違う",
            )
        }
    }

    @Test
    fun `基準に届く組は違反として出ない`() {
        // 陰性対照：白 / #2F5FA8 は 6.32（設計書の「両方に共通」の表）。違反の一覧に何でも入れる補助ではないことを見る
        val passing = ContrastMath.Check("白 / #2F5FA8", Color.White, currentPrimary, minimum = 4.5)
        val failing = ContrastMath.Check("主色 #2F5FA8 / 昼の空の上", currentPrimary, daySkyTop, minimum = 4.5)

        val ratio = ContrastMath.contrastRatio(Color.White, currentPrimary)
        println("陰性対照: 白 / #2F5FA8 = $ratio")

        assertTrue(abs(ratio - 6.32) < 0.01, "白 / #2F5FA8 の比 $ratio が設計書の 6.32 と違う")
        assertEquals(listOf(failing), ContrastMath.violations(listOf(passing, failing)).map { it.check })
    }

    @Test
    fun `半透明の色をそのまま比の計算に渡すと失敗する`() {
        // ガラスの面（白8%）を背景に重ね忘れて渡す書き間違いで、表が空振りして通るのを防ぐ
        val glass = Color.White.copy(alpha = 0.08f)

        val asBackground = assertFailsWith<IllegalArgumentException> { ContrastMath.contrastRatio(Color.White, glass) }
        val asForeground = assertFailsWith<IllegalArgumentException> { ContrastMath.contrastRatio(glass, nightSkyTop) }
        println("半透明の拒否: ${asBackground.message} ／ ${asForeground.message}")

        // 違反の一覧を通しても同じく失敗する（一覧の側で黙って飛ばさない）
        assertFailsWith<IllegalArgumentException> {
            ContrastMath.violations(listOf(ContrastMath.Check("白 / 白8%", Color.White, glass, minimum = 4.5)))
        }
    }

    @Test
    fun `重ねた色は背景のsRGBの値のまま混ぜた不透明の色になる`() {
        // 白50%を #263359 に重ねると、各成分は 255×a + 元の値×(1−a)。Compose は不透明度を 8 ビット（128/255）で持つので約 #9399AC
        val layered = ContrastMath.over(Color.White.copy(alpha = 0.5f), nightSkyTop)
        val expected = Color(0xFF9399AC)

        assertEquals(1f, layered.alpha, "重ねた色が不透明でない")
        listOf(
            "赤" to (layered.red to expected.red),
            "緑" to (layered.green to expected.green),
            "青" to (layered.blue to expected.blue),
        ).forEach { (name, pair) ->
            val (actual, wanted) = pair
            assertTrue(abs(actual - wanted) * 255 <= 0.5f, "$name の成分 ${actual * 255} が ${wanted * 255} と違う")
        }

        // 半透明の背景に重ねると、結果も半透明になって比の表が意味を失うので失敗させる
        assertFailsWith<IllegalArgumentException> {
            ContrastMath.over(Color.White.copy(alpha = 0.5f), Color.White.copy(alpha = 0.08f))
        }
    }

    @Test
    fun `重ねる層を順に重ねた色は、1枚ずつ重ねた色と同じになる`() {
        // 空＋雲10%＋ガラス8% のように、下から順に重ねる
        val cloud = Color.White.copy(alpha = 0.1f)
        val glass = Color.White.copy(alpha = 0.08f)
        val stacked = ContrastMath.stack(nightSkyTop, listOf(cloud, glass))

        // 両方が何も重ねない壊れた補助でも等しくなるので、重ねた色が背景から変わったことも見る
        assertNotEquals(nightSkyTop, stacked, "層を重ねても背景の色のまま")
        assertEquals(ContrastMath.over(glass, ContrastMath.over(cloud, nightSkyTop)), stacked)
        assertEquals(nightSkyTop, ContrastMath.stack(nightSkyTop, emptyList()), "重ねる層が無いときは背景のまま")
    }

    @Test
    fun `グラデーションの間の色は、赤・緑・青のsRGBの値を直線で混ぜた色になる`() {
        // 黒と白の真ん中は、各成分 255×0.5 を丸めた #808080（Oklab で混ぜると、これより暗い灰色になる）
        assertEquals(Color(0xFF808080), ContrastMath.between(Color.Black, Color.White, 0.5f))
        assertEquals(daySkyTop, ContrastMath.between(daySkyTop, daySkyBottom, 0f), "0 の所が始まりの色でない")
        assertEquals(daySkyBottom, ContrastMath.between(daySkyTop, daySkyBottom, 1f), "1 の所が終わりの色でない")

        // 半透明の色を混ぜると不透明の色になって、重ね忘れが比の計算で見つからなくなるので失敗させる
        assertFailsWith<IllegalArgumentException> {
            ContrastMath.between(Color.White.copy(alpha = 0.5f), daySkyTop, 0.5f)
        }
    }

    @Test
    fun `端の2色が基準を満たしても、間の色が基準に届かないグラデーションを見つける`() {
        // 色相が回る 2 色（橙→青）。暗い文字 #262633 との比は端で 6.52 と 4.53 だが、輝度は凸な関数なので途中が暗くなり、
        // 11/16 の所（#508FAF）で 4.18 まで下がる（設計書の「3色と白・黒だけを確かめればよい根拠」が成り立たない組）
        val orange = Color(red = 1.00f, green = 0.56f, blue = 0.00f)
        val blue = Color(red = 0.00f, green = 0.56f, blue = 1.00f)
        val text = Color(0xFF262633)
        val ends = listOf(orange, blue).map { ContrastMath.Check("端", text, it, minimum = 4.5) }
        val middles = (1 until 16).map { k ->
            ContrastMath.Check("$k/16", text, ContrastMath.between(orange, blue, k / 16f), minimum = 4.5)
        }

        val violations = ContrastMath.violations(ends + middles)
        println("間の色の違反: " + violations.joinToString(" ／ "))

        assertEquals(emptyList(), ContrastMath.violations(ends), "端の色がもう基準に届いていない（対照の組になっていない）")
        assertTrue(violations.isNotEmpty(), "間の色の違反が見つからない")
        val lowest = violations.minBy { it.ratio }
        assertEquals("11/16", lowest.check.label, "最も比の低い所が違う: $violations")
        assertTrue(abs(lowest.ratio - 4.18) < 0.01, "11/16 の比 ${lowest.ratio} が 4.18 と違う")
    }

    @Test
    fun `色相は0以上360未満の度で求まり、差は360をまたいで測る`() {
        assertEquals(0.0, ContrastMath.hueDegrees(Color(0xFFFF0000)), 1e-9)
        assertEquals(120.0, ContrastMath.hueDegrees(Color(0xFF00FF00)), 1e-9)
        assertEquals(240.0, ContrastMath.hueDegrees(Color(0xFF0000FF)), 1e-9)
        // 赤が最大で、緑が青より小さいときは負の側から 360 未満へ戻す（60×(6 − 64/255)）
        assertEquals(60.0 * (6 - 64.0 / 255), ContrastMath.hueDegrees(Color(0xFFFF0040)), 1e-4)
        // 設計書の「216°」：(47−95)/(168−47) から 60×(4 − 48/121)
        assertEquals(60.0 * (4 - 48.0 / 121), ContrastMath.hueDegrees(currentPrimary), 1e-4)

        assertEquals(20.0, ContrastMath.hueDistance(350.0, 10.0), 1e-9)
        assertEquals(20.0, ContrastMath.hueDistance(10.0, 350.0), 1e-9)
        assertEquals(180.0, ContrastMath.hueDistance(0.0, 180.0), 1e-9)
    }

    @Test
    fun `無彩色の色相は求めず失敗する`() {
        // 灰色を色相 0° と返すと、赤（エラーの色）との比較が黙って通るため
        assertFailsWith<IllegalArgumentException> { ContrastMath.hueDegrees(Color(0xFF808080)) }
        assertFailsWith<IllegalArgumentException> { ContrastMath.hueDegrees(Color.White) }
    }
}
